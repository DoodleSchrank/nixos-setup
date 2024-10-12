{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    ./custom-hw-conf.nix
    ../modules/avahi.nix
    ../modules/samba.nix
    ../gui.nix
    ../ci.nix
    ../gaming.nix
    ../user.nix
  ];
}
