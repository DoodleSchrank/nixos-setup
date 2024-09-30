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
  home.username = "yannik";
  home.stateVersion = "24.11";


  imports = [
    ../../modules/alacritty.nix
    ../../modules/chromium.nix
    #../../modules/i3.nix
    ../../modules/sway.nix
    ../../modules/redshift.nix
    ../../modules/vim.nix
    ../../modules/zsh.nix
  ];

  nixpkgs.config.allowUnfree = true;
  home.packages = with pkgs; [
    steamtinkerlaunch
    lutris
    prismlauncher
    protonup-ng
    wineWowPackages.stagingFull
    linuxKernel.packages.linux_xanmod.xone
    r2mod_cli
    gamemode

    nix-diff
    age
    (pkgs.discord.override {
      withOpenASAR = true;
      withVencord = true;
    })
    element-desktop
    thunderbird
    betterdiscordctl
    zoom-us
    telegram-desktop
    parsec-bin

    feh
    okular
    vlc
    yt-dlp

    jetbrains.webstorm
    jetbrains.idea-ultimate
    jdk
    mycli
    #jetbrains.rider
    #jetbrains.pycharm-community
    jetbrains.clion
    #cmake
    #gcc

    direnv

    (import ./python.nix {pkgs = pkgs;})
    alejandra
    mono

    alsa-lib
    tree
    hddtemp
    linuxKernel.packages.linux_xanmod_stable.cpupower
    dig
    redshift
    mcron
    nix-tree
    nix-output-monitor
    pavucontrol

    libreoffice
    rustdesk
    android-file-transfer
    localsend

    firefox

    smartmontools
    parted

    amdvlk
    vulkan-tools
    dxvk
  ];


  programs = {
    home-manager.enable = true;
    git = {
      enable = true;
      userName = "Yannik Könneker";
      userEmail = "y.koenneker@web.de";
    };
    zsh.enable = true;
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
  systemd.user.services.steam = {
    Unit = {
      description = "Open Steam in the background at boot";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.steam} -nochatui -nofriendsui -silent %U";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  home.sessionVariables = {
    XDG_ACTIVATION_TOKEN = "1";
  };
  home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";
}