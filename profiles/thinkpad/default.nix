{
  pkgs,
  config,
  lib,
  stdenv,
  environment,
  specialArgs,
  inputs,
  ...
}: {
  imports = [
    ../ci.nix
    ../gui.nix
    ../programming.nix
  ];

  # overrides of defaults
  programs.git.userEmail = "yannik.koenneker@ovgu.de";
    programs.zsh.shellAliases.rebuild = "sudo nixos-rebuild switch --flake '/home/yannik/nixos-setup#thinkpad' |& sudo nom";

}
