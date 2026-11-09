# Data disk and the State folder. disko never touches the Data disk (see disko.nix).
{
  config,
  lib,
  pkgs,
  ...
}: let
  dataFileSystems = {
    "/mnt/tbssd" = {
      device = "/dev/disk/by-uuid/70ca9b25-a1cd-46fa-bcbd-66780935c999"; # Samsung 870 EVO 4 TB
      fsType = "ext4";
      # nofail: boot continues without the Data disk (State services then refuse to start).
      # The SATA SSD appears within a second; without it, wait 15 s instead of systemd's 90 s+.
      options = ["nofail" "noatime" "x-systemd.device-timeout=15s"];
    };

    # /state is the State folder: /mnt/tbssd/state/<service> is /state/<service>.
    "/state" = {
      device = "/mnt/tbssd/state";
      fsType = "none";
      options = ["bind" "nofail"];
      depends = ["/mnt/tbssd"];
    };
  };
in {
  # Test seam: qemu-vm.nix replaces every fileSystems entry, so the VM tests re-add these
  # through `virtualisation.fileSystems = config.optiplex.dataFileSystems`.
  options.optiplex.dataFileSystems = lib.mkOption {
    type = lib.types.attrs;
    internal = true;
    readOnly = true;
    default = dataFileSystems;
    description = "The Data disk and /state entries of fileSystems, for the VM tests.";
  };

  config = {
    fileSystems = dataFileSystems;

    # While the Data disk is missing, /state stays an empty directory on the System
    # disk that nothing can write to. Activation runs before systemd mounts it, and
    # skips a /state that is already a mountpoint (switch on a running system).
    system.activationScripts.stateMountpoint = ''
      if ! ${pkgs.util-linux}/bin/mountpoint -q /state; then
        mkdir -p /state
        ${pkgs.e2fsprogs}/bin/chattr +i /state
      fi
    '';

    # State-dependent services do not start without the Data disk. A drop-in package (as in
    # monitoring.nix) instead of systemd.services.<n>, because a unit that restoreMode switches off
    # must not turn into an empty, invalid unit file just for this one setting.
    systemd.packages = [
      (pkgs.runCommand "state-units-dropins" {} ''
        d=$out/etc/systemd/system
        ${lib.concatMapStrings (n: ''
          mkdir -p $d/${n}.service.d
          printf '[Unit]\nRequiresMountsFor=/state\n' > $d/${n}.service.d/10-state.conf
        '') (map (lib.removeSuffix ".service") config.optiplex.stateUnits)}
        mkdir -p $d
      '')
    ];
  };
}
