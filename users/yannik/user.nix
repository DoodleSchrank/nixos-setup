{ pkgs, config, lib, stdenv, environment, ... }:
 {
    home.username = "yannik";
    home.stateVersion = "22.11";

    nixpkgs.config.allowUnfree = true;
    home.packages = with pkgs; [
      discord element-desktop thunderbird betterdiscordctl zoom-us teams-for-linux

      steam lutris yuzu-mainline vulkan-tools prismlauncher protonup-ng
      wineWowPackages.stagingFull
      linuxKernel.packages.linux_xanmod.xone

      konsole
      feh okular gimp vlc
      jetbrains.webstorm
      jetbrains.idea-community jdk
      #jetbrains.rider
      #jetbrains.pycharm-community
      jetbrains.clion cmake gcc gnumake fftwFloat python310Packages.pip
      (import ./programs/python.nix { pkgs = pkgs; })
      alejandra
      dbeaver sshuttle

      btop htop nvtop hddtemp linuxKernel.packages.linux_xanmod_stable.cpupower thefuck
      nix-tree nix-output-monitor
      pavucontrol unzip unar

      redshift mcron ranger trash-cli libreoffice rustdesk android-file-transfer
      zsh-command-time zsh-autocomplete zsh-syntax-highlighting #zsh-completions conflicting with trash-cli
      vimPlugins.vim-nix

      chroma # syntax highlighter needed for zsh stuff
    ];
    programs = {
      home-manager.enable = true;
    };
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
      ./programs/redshift.nix
      ./programs/zsh.nix
      ./programs/i3.nix
      ./programs/alacritty.nix
      ./programs/chromium-extensions.nix
      #./programs/python.nix
    ];
    home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";
    /*home.file.".config/BetterDiscord" = {
      source = ./programs/configs/betterdiscord;
      recursive = true;
    };*/
  }
