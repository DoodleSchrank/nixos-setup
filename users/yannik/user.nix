{ pkgs, config, lib, stdenv, ... }:
let
  unstable = import <nixos-unstable> { config = { allowUnfree = true; }; };
in {
    home.username = "yannik";
    home.stateVersion = "22.11";

    nixpkgs.config.allowUnfree = true;
    home.packages = with pkgs; [
      discord element-desktop unstable.parsec-bin thunderbird betterdiscordctl zoom-us unstable.teams-for-linux

      steam lutris yuzu-mainline vulkan-tools
      #inputs.nix-gaming.packages.${pkgs.hostPlatform.system}.wine-tkg
      #inputs.nix-gaming.packages.${pkgs.hostPlatform.system}.wine-ge
      linuxKernel.packages.linux_xanmod_stable.xone

      feh okular gimp vlc
      jetbrains.webstorm
      jetbrains.idea-community
      jetbrains.rider
      jetbrains.pycharm-community
      jetbrains.jdk
      jetbrains.clion
      alejandra

      bpytop htop hddtemp linuxKernel.packages.linux_xanmod_stable.cpupower
      nix-output-monitor pavucontrol

      redshift mcron ranger trash-cli dig
      chroma # syntax highlighter needed for zsh stuff
    ];
    programs.home-manager.enable = true;
    #programs.thunderbird.enable = true;
    programs.chromium.enable = true;
    services = {
      network-manager-applet.enable = true;
      udiskie = {
        enable = true;
        tray = "auto";
        automount = true;
        notify = false;
      };
    };

    imports = [
      #<sops-nix/modules/home-manager/sops.nix>
      ./programs/redshift.nix
      ./programs/zsh.nix
      ./programs/i3.nix
      ./programs/alacritty.nix
      ./programs/chromium-extensions.nix
    ];
    home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";
    nix.settings = {
      substituters = ["https://nix-gaming.cachix.org"];
      trusted-public-keys = ["nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4="];
    };
    /*home.file.".config/BetterDiscord" = {
      source = ./programs/configs/betterdiscord;
      recursive = true;
    };*/
  }
