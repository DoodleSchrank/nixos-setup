# The Optiplex installer ISO (nixosConfigurations.optiplex-installer): a minimal NixOS installer with root SSH for
# Yannik's keys and the tools of the Cutover. It is the imaging medium (Rollback image, install) when kexec
# fails, and the rollback medium when the installed NixOS does not boot. The empty USB stick in the Optiplex
# gets it (docs/optiplex-cutover-runbook.md, step 2).
#
#   nix build .#nixosConfigurations.optiplex-installer.config.system.build.isoImage
#
# Root logs in with the same keys as yannik on the Optiplex (machines/user.nix, passed in as `optiplexKeys`).
# `rollback-image` is machines/optiplex/cutover/rollback-image.sh: create, verify and restore the Rollback image
# from the stick, without needing the repository.
{
  lib,
  modulesPath,
  pkgs,
  optiplexKeys,
  ...
}: let
  rollbackImage = pkgs.writeShellApplication {
    name = "rollback-image";
    runtimeInputs = with pkgs; [coreutils util-linux zstd pv gnugrep gnused];
    text = builtins.readFile ../optiplex/cutover/rollback-image.sh;
  };
in {
  imports = [(modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")];

  networking.hostName = "optiplex-installer";
  # DHCP on every NIC (the FritzBox reserves .20 for the Optiplex's MAC). No wifi, no NetworkManager.
  networking.useDHCP = lib.mkForce true;
  networking.wireless.enable = lib.mkForce false;

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = optiplexKeys;

  boot.supportedFilesystems = ["btrfs" "ext4"];

  environment.systemPackages =
    (with pkgs; [
      zstd
      pv
      rsync
      restic
      ssh-to-age
      cryptsetup
      btrfs-progs
      e2fsprogs
      util-linux # sfdisk, lsblk, blockdev
      parted
      gptfdisk
      efibootmgr
      smartmontools
      pciutils
      ethtool
      jq
      sqlite
    ])
    ++ [rollbackImage];

  nix.settings.experimental-features = ["nix-command" "flakes"];
  system.stateVersion = "26.11";
}
