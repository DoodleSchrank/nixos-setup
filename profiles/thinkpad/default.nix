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

  home.packages = with pkgs; [
    #drawing
    krita
  ];

  # overrides of defaults
  programs.git.userEmail = "yannik.koenneker@ovgu.de";
  programs.zsh.shellAliases.rebuild = "sudo nixos-rebuild switch --flake '/home/yannik/nixos-setup#thinkpad' |& sudo nom";
  wayland.windowManager.sway.config.startup = lib.mkOptionDefault [
    {command = "mattermost-desktop"; }
  ];
}
