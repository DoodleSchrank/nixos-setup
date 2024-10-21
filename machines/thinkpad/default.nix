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
  ];
  services.logrotate.checkConfig = false;
}
