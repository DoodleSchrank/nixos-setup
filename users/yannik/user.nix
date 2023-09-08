{ pkgs, config, lib, stdenv, environment, ... }:
 {
    home.username = "yannik";
    home.stateVersion = "23.05";

    nixpkgs.config.allowUnfree = true;
    home.packages = with pkgs; [
      discord element-desktop thunderbird betterdiscordctl zoom-us teams-for-linux telegram-desktop

      steam steamtinkerlaunch lutris yuzu-mainline vulkan-tools prismlauncher protonup-ng
      wineWowPackages.stagingFull
      #nix-gaming.packages.${system}.proton-ge
      linuxKernel.packages.linux_xanmod.xone

      konsole
      feh okular vlc yt-dlp vimv
      libmediainfo #tmm


      jetbrains.webstorm
      jetbrains.idea-ultimate jdk
      #jetbrains.rider
      #jetbrains.pycharm-community
      jetbrains.clion cmake gcc gnumake python310Packages.pip
      (import ./python.nix { pkgs = pkgs; })
      alejandra
      dbeaver sshuttle

      btop htop nvtop tree hddtemp linuxKernel.packages.linux_xanmod_stable.cpupower thefuck dig jq
      redshift mcron ranger
      nix-tree nix-output-monitor
      pavucontrol unzip unar

      libreoffice rustdesk android-file-transfer
      zsh-command-time zsh-autocomplete zsh-syntax-highlighting #zsh-completions conflicting with trash-cli
      vimPlugins.vim-nix

      xclip maim
      chromium firefox

      btrfs-progs smartmontools parted
      chroma # syntax highlighter needed for zsh stuff
    ];
    programs = {
      home-manager.enable = true;
      git = {
          enable = true;
          userName  = "Yannik Könneker";
          userEmail = "y.koenneker@web.de";
        };
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
      ./redshift.nix
      ../../programs/zsh.nix
      ./i3.nix
      ../../programs/alacritty.nix
      ./chromium-extensions.nix
    ];
    home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";
    /*home.file.".config/BetterDiscord" = {
      source = ./programs/configs/betterdiscord;
      recursive = true;
    };*/
  }
