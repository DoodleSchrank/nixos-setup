# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

   boot.loader.systemd-boot.enable = true;
   boot.loader.efi.canTouchEfiVariables = true;
   boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "mpt3sas" "nvme" "usbhid" "sd_mod" "cryptd" ];
   boot.initrd.kernelModules = [ "dm-snapshot" "usb_storage" ];
   boot.kernelPackages = pkgs.linuxPackages_xanmod;
   boot.kernel.sysctl = {
     "abi.vsyscall32" = 0;
  };
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/4ae1033e-153d-4264-9b80-4b63ea99e95a";
      fsType = "ext4";
    };

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/0d5a69b9-0c3d-4537-8391-db9d294ca6f4";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/B756-60A6";
      fsType = "vfat";
    };
    boot.initrd.luks.devices."cryptroot" = {
       device = "/dev/disk/by-uuid/2c565d63-925c-4041-8172-a0e652c3eb6a";
       #https://nixos.wiki/wiki/Full_Disk_Encryption for some future day :(
       #allowDiscards = true;
       #keyFileSize = 4096;
       #keyFile = "/dev/sdf";
     };
   fileSystems."/storage" =
     { device = "/dev/sdc1";
       fsType = "btrfs";
     };

   swapDevices =
     [ { device = "/dev/disk/by-uuid/b47fdd09-e55c-43b3-8160-2f0e1a97ce70"; }
     ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  networking = {
    hostName = "yannik-pc";
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 localhost
    '';
    firewall.enable = true;
    firewall.allowPing = true;
    defaultGateway = "192.168.178.1";
    nameservers = [ "192.168.178.20" ];
    interfaces.enp12s0 = {
      wakeOnLan.enable = true;
      ipv4.addresses = [{
        address = "192.168.178.21";
        prefixLength = 24;
      }];
    };
  };
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
  #nvidia shibizzles
  hardware.opengl.enable = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;
  hardware.nvidia.modesetting.enable = true;
  hardware.nvidia.forceFullCompositionPipeline = true;

   # steam shibizzles
   hardware.opengl.driSupport32Bit = true;
}

