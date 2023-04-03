{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./programs/programs.nix
      <home-manager/nixos>
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "yannik-pc"; # Define your hostname.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

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
  # nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment = {
    pathsToLink = [ "/libexec" ];
  };


  environment.systemPackages = with pkgs; [
     vim neovim
     wget curl gitFull
     chromium
     zsh alacritty
     xclip maim
     trash-cli
     nvidia-vaapi-driver
  ];
  services.jellyfin.enable = true;


  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;
  security.sudo.wheelNeedsPassword = false;

  users.users.yannik = {
     isNormalUser = true;
     extraGroups = [ "wheel" ];
  };
  home-manager.users.yannik = { pkgs, ...}: {
    programs.zsh.enable = true;
    imports = [ ./users/yannik/user.nix ];
  };
  fonts.fonts = with pkgs; [
    noto-fonts noto-fonts-cjk noto-fonts-emoji dejavu_fonts
  ];

  networking.firewall.allowedTCPPorts = [ 445 139 ];
  networking.firewall.allowedUDPPorts = [ 137 138 ];
  networking.firewall.enable = true;
  networking.firewall.allowPing = true;
  services.jellyfin.openFirewall = true;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  system.copySystemConfiguration = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?

}

