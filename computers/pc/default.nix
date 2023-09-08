{ config, pkgs, ... }:
{
  imports = [
    ./custom-hw-conf.nix
    ./avahi.nix
    ./samba.nix
    ../../programs/sound.nix
    ../../programs/ssh.nix
    ./xorg.nix
    ./nfs.nix
  ];
  time.timeZone = "Europe/Amsterdam";

  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    #keyMap = "de";
    useXkbConfig = true; # use xkbOptions in tty.
  };

  # fuck nvidia
  nixpkgs.config.allowUnfree = true;
  # flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  users.defaultUserShell = pkgs.zsh;
  security.sudo.wheelNeedsPassword = false;
  environment.localBinInPath = true;

  fonts.fonts = with pkgs; [
    noto-fonts noto-fonts-cjk noto-fonts-emoji dejavu_fonts
  ];
  users.users."yannik".openssh.authorizedKeys.keyFiles = [
    ../../programs/configs/ssh/authorized_keys
  ];

  environment = {
    pathsToLink = [ "/libexec" ];
    systemPackages = with pkgs; [
      nvidia-vaapi-driver
      jellyfin-ffmpeg
      neovim
      wget curl gitFull
      zsh alacritty
      trash-cli
      nix-diff
      age
    ];
  };

  programs = {
    zsh.enable = true;
    adb.enable = true;
    neovim.enable = true;
    neovim.defaultEditor = true;
  };

  services = {
    jellyfin.enable = true;
    jellyfin.openFirewall = true;
    flatpak.enable = true;
  };
  # flatpak shibizzles
  xdg.portal.enable = true;
  xdg.portal.extraPortals = [pkgs.xdg-desktop-portal-gtk];
  users.users.yannik = {
    isNormalUser = true;
    extraGroups = ["wheel" "adbusers"];
  };
  home-manager.users.yannik = { pkgs, ... }: {
    programs.zsh.enable = true;
    imports = [../../users/yannik/user.nix];
  };
}
