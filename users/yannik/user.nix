{ pkgs, config, lib, stdenv, environment, ... }:
let
  unstable = import <nixos-unstable> { config = { allowUnfree = true; }; };
in {
    home.username = "yannik";
    home.stateVersion = "22.11";

    nixpkgs.config.allowUnfree = true;
    home.packages = with pkgs; [
      discord element-desktop thunderbird betterdiscordctl zoom-us unstable.teams-for-linux

      steam lutris yuzu-mainline vulkan-tools prismlauncher protonup-ng
      wineWowPackages.stagingFull
      linuxKernel.packages.linux_xanmod.xone

      feh okular gimp vlc
      #jetbrains.webstorm
      unstable.jetbrains.idea-community maven unstable.jdk  gcc12
      #jetbrains.rider
      #jetbrains.pycharm-community
      #jetbrains.jdk
      #jetbrains.clion
      alejandra
      dbeaver sshuttle

      bpytop htop hddtemp linuxKernel.packages.linux_xanmod_stable.cpupower
      nix-tree nix-output-monitor pavucontrol unzip unar

      redshift mcron ranger trash-cli dig
      zsh-completions zsh-command-time zsh-autocomplete zsh-syntax-highlighting
      vimPlugins.vim-nix
      chroma # syntax highlighter needed for zsh stuff
    ];
    programs.home-manager.enable = true;
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
      #"${nix-gaming}/modules/pipewireLowLatency.nix"
      #<sops-nix/modules/home-manager/sops.nix>
      ./programs/redshift.nix
      ./programs/zsh.nix
      ./programs/i3.nix
      ./programs/alacritty.nix
      ./programs/chromium-extensions.nix
    ];
    home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";
    /*home.file.".config/BetterDiscord" = {
      source = ./programs/configs/betterdiscord;
      recursive = true;
    };*/
  }
