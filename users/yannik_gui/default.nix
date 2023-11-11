{
  pkgs,
  config,
  lib,
  stdenv,
  environment,
  ...
}:
{
  services = {
    network-manager-applet.enable = true;
    udiskie = {
      enable = true;
      tray = "auto";
      automount = true;
      notify = false;
    };
    syncthing.enable = true;
  };

  imports = [
    ../yannik_cli
    ../../programs/zsh.nix
    ../../programs/vim.nix
    ../../programs/i3.nix
    ../../programs/alacritty.nix
    ../../programs/redshift.nix
    ../../programs/vscode.nix
  ];
  home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";
  /*
    home.file.".config/BetterDiscord" = {
    source = ./programs/configs/betterdiscord;
    recursive = true;
  };
  */
}
