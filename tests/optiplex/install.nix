# Hermetic install test: checks.x86_64-linux.optiplex-install
#
# The real disko layout and the real LUKS initrd SSH unlock, end to end in qemu:
#   1. `installer` formats a blank disk with the real disko script (LUKS2 + btrfs subvolumes),
#      puts a freshly generated initrd host key and main host key where `nixos-anywhere
#      --extra-files` would, and runs nixos-install of the `optiplex-restore` system (what nixos-anywhere installs).
#      The Data disk is attached throughout and must not change.
#   2. The disk is booted again as an NVMe drive via OVMF and systemd-boot. `client` waits for the
#      initrd sshd on 2222, checks the pinned initrd host key and sends the passphrase.
#   3. The system comes up: subvolumes, mount options, swapfile, host key, /state.
#
# Differences from the real box (all about hardware, none about the layout): the System disk device is
# the install VM's disk (disko.devices.disk.system.device; qemu cannot fake the by-id name of the
# KIOXIA drive), the NIC is matched by a fixed MAC, /nix/store comes from the host over 9p
# (the installed copy is still on @nix), and the test instrumentation is part of the installed system.
{
  pkgs,
  inputs,
  optiplexModules,
}: let
  inherit (pkgs) lib;
  sshKeys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  qemuCommon = import (pkgs.path + "/nixos/lib/qemu-common.nix") {inherit lib; inherit (pkgs) stdenv;};
  qemuPkg = pkgs.qemu_test;
  mac = "52:54:00:ab:cd:20";
  passphrase = "test-passphrase-not-secret";

  installedSystem = inputs.nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs = {inherit inputs;};
    modules =
      optiplexModules
      ++ [
        ./test-secrets.nix
        ./offline.nix
        ({modulesPath, ...}: {
          imports = [
            (modulesPath + "/testing/test-instrumentation.nix")
            (modulesPath + "/profiles/qemu-guest.nix")
          ];
          optiplex.restoreMode = true; # nixos-anywhere installs optiplex-restore
          optiplex.network.mac = mac;
          # the install VM's disk instead of the KIOXIA by-id path; everything else of disko.nix is real
          disko.devices.disk.system.device = lib.mkForce "/dev/disk/by-id/virtio-sysdisk";
          boot.loader.efi.canTouchEfiVariables = lib.mkForce false; # no EFI variables in qemu
          boot.loader.systemd-boot.graceful = true;
          boot.initrd.availableKernelModules = ["9p" "9pnet_virtio" "virtio_pci" "virtio_net" "nvme"];
          fileSystems."/nix/store" = lib.mkForce {
            device = "nix-store";
            fsType = "9p";
            neededForBoot = true;
            options = ["trans=virtio" "version=9p2000.L" "cache=loose"];
          };
          documentation.enable = false;
        })
      ];
  };
  inherit (installedSystem.config.system.build) toplevel diskoScript;

  # ext4 Data disk with the real UUID and a marker file
  dataDisk = pkgs.runCommand "optiplex-data-disk.img" {nativeBuildInputs = [pkgs.e2fsprogs];} ''
    mkdir -p seed/state/marker-dir
    echo data-disk-untouched > seed/state/marker-dir/marker
    truncate -s 1G $out
    mkfs.ext4 -q -F -E root_owner=0:0 -U 70ca9b25-a1cd-46fa-bcbd-66780935c999 -L tbssd -d seed $out
  '';

  clientIP = "192.168.178.50";
  hostIP = "192.168.178.20";
in
  (import (pkgs.path + "/nixos/lib") {}).runTest {
    hostPkgs = pkgs;
    name = "optiplex-install";
    meta.timeout = 1800;

    nodes.installer = {pkgs, ...}: {
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
      virtualisation.diskSize = 4096;
      virtualisation.emptyDiskImages = [
        {
          size = 24 * 1024; # 1 GiB ESP + LUKS/btrfs with the 16 GiB swapfile + the system
          driveConfig.deviceExtraOpts.serial = "sysdisk";
        }
      ];
      virtualisation.qemu.drives = [
        {
          name = "data";
          file = "${dataDisk}";
          driveExtraOpts = {
            format = "raw";
            snapshot = "on";
          };
          deviceExtraOpts.serial = "tbssd";
        }
      ];
      virtualisation.vlans = lib.mkForce [];
      virtualisation.additionalPaths = [toplevel diskoScript]; # registered in the VM's nix db for nixos-install
      boot.supportedFilesystems = ["btrfs"];
      environment.systemPackages = [pkgs.nixos-install-tools pkgs.openssh pkgs.cryptsetup pkgs.btrfs-progs];
      nix.settings.substituters = lib.mkForce [];
    };

    nodes.client = {pkgs, ...}: {
      virtualisation.vlans = lib.mkForce [];
      virtualisation.interfaces.eth1.vlan = 1;
      networking.interfaces.eth1.ipv4.addresses = [{address = clientIP; prefixLength = 24;}];
      environment.systemPackages = [pkgs.openssh pkgs.netcat];
    };

    testScript = ''
      import shlex

      HOST = "${hostIP}"
      SYS = "/dev/disk/by-id/virtio-sysdisk"
      DATA = "/dev/disk/by-id/virtio-tbssd"

      start_all_nodes = (installer, client)
      for m in start_all_nodes:
          m.start()
          m.wait_for_unit("multi-user.target")

      with subtest("install with the real disko script, as nixos-anywhere does"):
          installer.succeed("echo -n '${passphrase}' > /tmp/secret.key")
          data_before = installer.succeed(f"sha256sum {DATA}").split()[0]
          installer.succeed("${diskoScript}")
          # --extra-files: a fresh initrd host key, never the main one, and the main keys
          installer.succeed("mkdir -p /mnt/etc/secrets/initrd /mnt/etc/ssh")
          installer.succeed("ssh-keygen -q -t ed25519 -N ''' -C initrd-test -f /mnt/etc/secrets/initrd/ssh_host_ed25519_key")
          installer.succeed("ssh-keygen -q -t ed25519 -N ''' -C main-test -f /mnt/etc/ssh/ssh_host_ed25519_key")
          installer.succeed("ssh-keygen -q -t rsa -b 4096 -N ''' -C main-test -f /mnt/etc/ssh/ssh_host_rsa_key")
          initrd_pub = installer.succeed("cut -d' ' -f1,2 /mnt/etc/secrets/initrd/ssh_host_ed25519_key.pub").strip()
          main_pub = installer.succeed("cut -d' ' -f1,2 /mnt/etc/ssh/ssh_host_ed25519_key.pub").strip()
          assert initrd_pub != main_pub
          installer.succeed("nixos-install --root /mnt --system ${toplevel} --no-root-passwd --no-channel-copy")
          installer.succeed("test -e /mnt/boot/EFI/systemd/systemd-bootx64.efi")
          installer.succeed("sync; umount -R /mnt; cryptsetup close cryptroot")
          assert installer.succeed(f"sha256sum {DATA}").split()[0] == data_before, "the Data disk changed during the install"
          installer.shutdown()

      # Boot the installed disk again, as an NVMe drive, through OVMF and systemd-boot.
      sysimg = f"{installer.state_dir}/empty0.qcow2"
      flags = [
          "-m", "3072", "-smp", "2",
          "-virtfs", "local,path=/nix/store,security_model=none,mount_tag=nix-store",
          "-drive", f"file={sysimg},id=sys,if=none,format=qcow2,werror=report",
          "-device", "nvme,serial=21LPG2BCQL42,drive=sys,bootindex=1",
          "-drive", "file=${dataDisk},id=data,if=none,format=raw,snapshot=on",
          "-device", "virtio-blk-pci,drive=data,serial=tbssd",
          "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.firmware}",
          "-drive", "if=pflash,format=raw,unit=1,readonly=on,file=${pkgs.OVMF.variables}",
          "-device", "virtio-net-pci,netdev=vlan1,mac=${mac}",
          "-netdev", 'vde,id=vlan1,sock="$QEMU_VDE_SOCKET_1"',
      ]
      target = create_machine(
          start_command=" ".join(shlex.split("${qemuCommon.qemuBinary qemuPkg}") + flags),
          name="target",
      )
      driver.machines_qemu.append(target)
      target.start()

      ssh = "ssh -i /root/id -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes"
      client.succeed("install -m600 ${sshKeys.snakeOilPrivateKey} /root/id")
      client.succeed(f"echo '[{HOST}]:2222 {initrd_pub}' > /root/kh_initrd")
      client.succeed(f"echo '[{HOST}]:25560 {main_pub}' > /root/kh_main")

      with subtest("LUKS unlock over initrd SSH on 2222"):
          client.wait_until_succeeds(f"nc -z {HOST} 2222", timeout=300)
          # the host key of the initrd is the dedicated one, not the main host key
          client.fail(f"{ssh} -o UserKnownHostsFile=/root/kh_main -p 2222 root@{HOST} true")
          client.succeed(f"{ssh} -o UserKnownHostsFile=/root/kh_initrd -p 2222 root@{HOST} 'ls /run/systemd/ask-password'")
          client.succeed(f"echo -n '${passphrase}' | {ssh} -o UserKnownHostsFile=/root/kh_initrd -p 2222 root@{HOST} systemd-tty-ask-password-agent --query")

      target.wait_for_unit("multi-user.target", timeout=300)

      with subtest("booted through systemd-boot from the NVMe drive"):
          target.succeed("test -d /sys/firmware/efi")
          target.succeed("test -e /boot/EFI/systemd/systemd-bootx64.efi")
          target.succeed("lsblk -no NAME,TYPE | grep -q nvme0n1")
          target.succeed("cryptsetup luksDump /dev/disk/by-partlabel/disk-system-luks | grep -q 'Version:.*2'")

      with subtest("subvolumes mounted with compress=zstd,noatime, swapfile active"):
          for mnt, sub in (("/", "@"), ("/nix", "@nix"), ("/var/log", "@log"), ("/swap", "@swap")):
              fs, opts = target.succeed(f"findmnt -n -o FSTYPE,OPTIONS {mnt}").split()
              assert fs == "btrfs", (mnt, fs)
              for o in ("compress=zstd", "noatime", f"subvol=/{sub}"):
                  assert o in opts, (mnt, o, opts)
          swaps = target.succeed("swapon --show=NAME,TYPE,SIZE --noheadings --bytes")
          print(swaps)
          name, _, size = swaps.split()[:3]
          assert name == "/swap/swapfile" and abs(int(size) - 16 * 1024**3) <= 65536, swaps  # 16 GiB minus the swap header

      with subtest("the main host key differs from the initrd key and sshd answers on 25560"):
          keyscan = client.succeed(f"ssh-keyscan -p 25560 -t ed25519 {HOST} 2>/dev/null")
          assert main_pub in keyscan and initrd_pub not in keyscan, keyscan
          client.wait_until_succeeds(f"{ssh} -o UserKnownHostsFile=/root/kh_main -p 25560 yannik@{HOST} true")
          client.fail(f"{ssh} -o UserKnownHostsFile=/root/kh_initrd -p 25560 yannik@{HOST} true")

      with subtest("the Data disk is mounted by UUID, /state is its bind mount, nothing was lost"):
          target.succeed("findmnt -n -o SOURCE,FSTYPE /mnt/tbssd")
          target.succeed("findmnt -n /state")
          target.succeed("grep -qx data-disk-untouched /state/marker-dir/marker")
          target.succeed("blkid -s UUID -o value /dev/disk/by-uuid/70ca9b25-a1cd-46fa-bcbd-66780935c999")
          target.succeed("e2fsck -fn /dev/disk/by-uuid/70ca9b25-a1cd-46fa-bcbd-66780935c999")
    '';
  }
