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
  ];

  # overrides of defaults
  programs.git.userEmail = "y.koenneker@web.de";
    programs.zsh.shellAliases.rebuild = "sudo nixos-rebuild switch --flake '/home/yannik/nixos-setup#acer' |& sudo nom";

}
