{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./custom-hw-conf.nix
    ../../modules/sound.nix
    ../../modules/ssh.nix
    ../../modules/xorg.nix
    #../../modules/vim.nix
#../../modules/wayland.nix
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

      btop

      zsh-command-time
      zsh-autocomplete
      zsh-syntax-highlighting
      chroma
      vimPlugins.vim-nix

      zip
      unzip
      unar
      #required to get urls to open in browser
      # https://discourse.nixos.org/t/clicked-links-in-desktop-apps-not-opening-browers/29114/11
      xdg-utils
    ];
  };

  fonts.fonts = with pkgs; [
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
    zsh.enable = true;
    zsh = {
      shellAliases = {
        rebuild = "sudo nixos-rebuild switch --flake '/home/yannik/nixos/nixos-setup#thinkpad' |& sudo nom";
      };
    };
  };

  xdg.portal.enable = true;
  xdg.portal.extraPortals = [pkgs.xdg-desktop-portal-wlr pkgs.xdg-desktop-portal-gtk];
  xdg.portal.wlr.enable = true;
  xdg.portal.xdgOpenUsePortal = true;

  users.users.yannik = {
    isNormalUser = true;
    extraGroups = ["wheel" "adbusers"];
    openssh.authorizedKeys.keyFiles = [ ../../modules/configs/ssh/authorized_keys];
  };
}
