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
    ../../modules/darkmode.nix
    #../../modules/i3.nix
    ../../modules/sway.nix
    #../../modules/redshift.nix
    ../../modules/vim.nix
    ../../modules/zsh.nix
  ];

  nixpkgs.config.allowUnfree = true;
  home.packages = with pkgs; [
    steamtinkerlaunch
    lutris
    prismlauncher
    linuxKernel.packages.linux_xanmod.xone
    r2mod_cli
    gamemode
    wineWowPackages.waylandFull

    nix-diff
    age
    (pkgs.discord.override {
      withOpenASAR = true;
      withVencord = true;
    })
    element-desktop
    betterbird
    zoom-us
    telegram-desktop
    parsec-bin
    mattermost-desktop

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

    tree
    linuxKernel.packages.linux_xanmod_stable.cpupower
    dig
    redshift
    nix-tree
    nix-output-monitor
    pavucontrol

    libreoffice
    rustdesk
    android-file-transfer
    # localsend alternative
    warpinator

    firefox

    smartmontools
    parted

    amdvlk
    vulkan-tools
    dxvk

    udiskie
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


  xdg.mimeApps = {
    enable                              =  true;
    defaultApplications = {
        "default-web-browser"           = [ "firefox.desktop" ];
        "text/html"                     = [ "firefox.desktop" ];
        "x-scheme-handler/http"         = [ "firefox.desktop" ];
        "x-scheme-handler/https"        = [ "firefox.desktop" ];
        "x-scheme-handler/about"        = [ "firefox.desktop" ];
        "x-scheme-handler/unknown"      = [ "firefox.desktop" ];
    };
  };
}
