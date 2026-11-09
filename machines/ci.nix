{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {

  imports = [
    modules/sound.nix
    modules/ssh.nix
  ];

  system.stateVersion = "24.11";
  time.timeZone = "Europe/Amsterdam";

  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "de";
  };

  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.android_sdk.accept_license = true;
  nix.settings.experimental-features = ["nix-command" "flakes"];

  environment.localBinInPath = true;

  environment = {
    pathsToLink = ["/libexec"];
    systemPackages = with pkgs; [
      wget
      curl
      trash-cli
      vimv
      ranger
      neovim
      git

      btop
      gparted

      zsh
      zsh-command-time
      zsh-autocomplete
      zsh-syntax-highlighting
      chroma
      vimPlugins.vim-nix

      zip
      unzip
      unar
    ];
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    dejavu_fonts
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    nerd-fonts.dejavu-sans-mono
  ];
  programs.zsh.enable = true;
  services = {
    udisks2.enable = true;
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };
    printing.enable = true;
  };
}
