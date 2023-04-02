{ pkgs, config, lib, stdenv, ... }:
  {
    home.username = "yannik";
    home.stateVersion = "22.11";

    nixpkgs.config.allowUnfree = true;
    home.packages = with pkgs; [
      discord element-desktop parsec-bin thunderbird betterdiscordctl

      steam lutris yuzu-mainline

      feh okular gimp vlc
      jetbrains.webstorm
      jetbrains.idea-community
      jetbrains.rider
      jetbrains.pycharm-community
      jetbrains.jdk
      jetbrains.clion
      alejandra

      bpytop htop hddtemp linuxKernel.packages.linux_xanmod_stable.cpupower

      redshift mcron
      chroma # syntax highlighter needed for zsh stuff
    ];
    programs.home-manager.enable = true;

    imports = [
      ./programs/redshift.nix
      ./programs/zsh.nix
      ./programs/i3.nix
      ./programs/alacritty.nix
      ./programs/chromium-extensions.nix
    ];
    home.file.".config/BetterDiscord" = {
      source = ./programs/configs/betterdiscord;
      recursive = true;
    };
  }
