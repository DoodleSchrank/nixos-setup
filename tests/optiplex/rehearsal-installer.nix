# Throwaway NixOS "target machine" for tests/optiplex/rehearsal.sh: a qemu VM that plays the
# part of the box booted from the NixOS installer, so nixos-anywhere has something to install onto.
# Its root key is the public snakeoil test key (the VM is only reachable through a 127.0.0.1
# port forward and lives for minutes). The blank System disk (NVMe) and the Data disk are attached by
# rehearsal.sh through QEMU_OPTS.
{
  modulesPath,
  pkgs,
  ...
}: let
  sshKeys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
in {
  imports = [(modulesPath + "/virtualisation/qemu-vm.nix")];
  virtualisation = {
    memorySize = 4096;
    cores = 4;
    diskSize = 8192;
    graphics = false;
  };
  networking.hostName = "rehearsal-installer";
  networking.useDHCP = true;
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };
  users.users.root.openssh.authorizedKeys.keys = [sshKeys.snakeOilPublicKey];
  boot.supportedFilesystems = ["btrfs"];
  environment.systemPackages = with pkgs; [parted cryptsetup btrfs-progs e2fsprogs];
  nix.settings.experimental-features = ["nix-command" "flakes"];
  system.stateVersion = "26.11";
}
