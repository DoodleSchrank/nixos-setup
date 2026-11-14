# Stand-in for the live Arch box, for the kexec rehearsal (tests/optiplex/rehearsal.sh up --kexec):
# a qemu VM that is NOT an installer but a running system the way Arch is at step 5 of the Cutover.
#
#   - sshd on 25560 only, root login impossible, `AllowUsers yannik`, key login from ~/.ssh/authorized_keys
#     (not /etc/ssh/authorized_keys.d: nixos-anywhere copies ~/.ssh/authorized_keys to root's for the installer)
#   - yannik has passwordless sudo
#   - the tools nixos-anywhere's fact check wants: tar, cpio, setsid, sudo (no wget/curl dependency: the kexec
#     tarball is passed with --kexec)
#   - NO DNS: the resolver is an address nothing answers on (Pi-hole is stopped at that point of the
#     Cutover), and rehearsal.sh starts it with qemu `restrict=on`, so nothing leaves the VM at all
#   - a NVMe "System disk" and a Data disk are attached by rehearsal.sh through QEMU_OPTS
{
  modulesPath,
  pkgs,
  lib,
  ...
}: let
  sshKeys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  authorizedKeys = pkgs.writeText "authorized_keys" "${sshKeys.snakeOilPublicKey}\n";
in {
  imports = [(modulesPath + "/virtualisation/qemu-vm.nix")];
  virtualisation = {
    memorySize = 4096;
    cores = 4;
    diskSize = 4096;
    graphics = false;
  };
  networking.hostName = "rehearsal-source";
  networking.useDHCP = true;
  networking.dhcpcd.extraConfig = "nohook resolv.conf"; # whatever the DHCP server says, no resolver
  networking.nameservers = ["192.0.2.53"]; # TEST-NET-1: nothing answers
  networking.firewall.enable = false;
  services.openssh = {
    enable = true;
    ports = [25560];
    openFirewall = false;
    authorizedKeysFiles = lib.mkForce [".ssh/authorized_keys"];
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      AllowUsers = ["yannik"];
    };
  };
  users.users.yannik = {
    isNormalUser = true;
    uid = 1001;
    extraGroups = ["wheel"];
  };
  security.sudo.wheelNeedsPassword = false;
  systemd.tmpfiles.rules = [
    "d /home/yannik/.ssh 0700 yannik users -"
    "C /home/yannik/.ssh/authorized_keys 0600 yannik users - ${authorizedKeys}"
  ];
  environment.systemPackages = with pkgs; [cpio gnutar util-linux parted e2fsprogs curl];
  system.stateVersion = "26.11";
}
