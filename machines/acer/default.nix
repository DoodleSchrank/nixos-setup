{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    ./custom-hw-conf.nix
    ../gui.nix
    ../ci.nix
    ../user.nix
    ../laptop.nix
  ];
  services.blueman.enable = true;
}
