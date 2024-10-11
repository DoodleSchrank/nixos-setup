{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    ./custom-hw-conf.nix
    ../../modules/avahi.nix
    ../../modules/samba.nix
    ../../modules/sound.nix
    ../../modules/ssh.nix
    #../../modules/xorg.nix
    #../../modules/vim.nix
    ../../modules/wayland.nix
    #../../modules/zsh.nix
  ];

  system.stateVersion = "24.11";
  time.timeZone = "Europe/Amsterdam";

  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "de";
  };

  # fuck nvidia
  nixpkgs.config.allowUnfree = true;
  # flakes
  nix.settings.experimental-features = ["nix-command" "flakes"];

  users.defaultUserShell = pkgs.zsh;
  security.sudo.wheelNeedsPassword = false;
  environment.localBinInPath = true;

  environment = {
    pathsToLink = ["/libexec"];
    systemPackages = with pkgs; [
      wget
      curl
      trash-cli
      zsh
      vimv
      ranger
      neovim
      git

      btop
      gparted

      zsh-command-time
      zsh-autocomplete
      zsh-syntax-highlighting
      chroma
      vimPlugins.vim-nix

      zip
      unzip
      unar
      # required to get urls to open in browser
      # https://discourse.nixos.org/t/clicked-links-in-desktop-apps-not-opening-browers/29114/11
      xdg-utils
      inputs.umu.packages.${pkgs.system}.umu
    ];
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    dejavu_fonts
    (nerdfonts.override { fonts = [
            "FiraCode" "DroidSansMono" "SpaceMono"
            "JetBrainsMono"
            "DejaVuSansMono"
          ]; })
  ];

  programs = {
    steam = {
      enable = true;
      extraCompatPackages = [
        pkgs.proton-ge-bin
      ];
      gamescopeSession = {
        enable = true;
      };
    };
    zsh.enable = true;
    dconf.enable = true;
  };
  services = {
    udisks2.enable = true;
  };
  xdg.portal = {
    enable = true;
    extraPortals = [pkgs.xdg-desktop-portal-gtk pkgs.xdg-desktop-portal-wlr];
    wlr.enable = true;
    xdgOpenUsePortal = true;
    config = {
      common.default = ["gtk" "wlr"];
    };
  };

  users.users.yannik = {
    isNormalUser = true;
    extraGroups = ["wheel" "adbusers"];
    openssh.authorizedKeys.keyFiles = [ ../../modules/configs/ssh/authorized_keys];
  };
}
