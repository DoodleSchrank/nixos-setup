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
    ../../modules/i3.nix
#../../modules/sway.nix
    #../../modules/redshift.nix
    ../../modules/vim.nix
    ../../modules/zsh.nix
  ];

  nixpkgs.config.allowUnfree = true;
  home.packages = with pkgs; [
    nix-diff
    age
    (pkgs.discord.override {
      withOpenASAR = true;
      withVencord = true;
    })
    element-desktop
    thunderbird
    zoom-us
    telegram-desktop

    feh
    okular
    vlc

    jetbrains.idea-ultimate
    jdk
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
    mcron
    nix-tree
    nix-output-monitor
    pavucontrol

    libreoffice
    rustdesk
    localsend

    firefox
    smartmontools
    parted
  ];


  programs = {
    home-manager.enable = true;
    git = {
      enable = true;
      userName = "Yannik Könneker";
      userEmail = "yannik.koenneker@ovgu.de";
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

  home.sessionVariables = {
    XDG_ACTIVATION_TOKEN = "1";
  };
  home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";
}
