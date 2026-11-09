# Data disk and the State folder. disko never touches the Data disk (see disko.nix).
{
  config,
  lib,
  pkgs,
  ...
}: {
  fileSystems."/mnt/tbssd" = {
    device = "/dev/disk/by-uuid/70ca9b25-a1cd-46fa-bcbd-66780935c999"; # Samsung 870 EVO 4 TB
    fsType = "ext4";
    options = ["nofail" "noatime"];
  };

  # /state is the State folder: /mnt/tbssd/state/<service> is /state/<service>.
  fileSystems."/state" = {
    device = "/mnt/tbssd/state";
    fsType = "none";
    options = ["bind" "nofail"];
    depends = ["/mnt/tbssd"];
  };

  # While the Data disk is missing, /state stays an empty directory on the System
  # disk that nothing can write to. Activation runs before systemd mounts it, and
  # skips a /state that is already a mountpoint (switch on a running system).
  system.activationScripts.stateMountpoint = ''
    if ! ${pkgs.util-linux}/bin/mountpoint -q /state; then
      mkdir -p /state
      ${pkgs.e2fsprogs}/bin/chattr +i /state
    fi
  '';

  # State-dependent services do not start without the Data disk.
  systemd.services = lib.genAttrs (map (lib.removeSuffix ".service") config.optiplex.stateUnits) (_: {
    unitConfig.RequiresMountsFor = ["/state"];
  });
}
