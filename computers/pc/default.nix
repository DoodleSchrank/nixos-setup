{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./custom-hw-conf.nix
    ../../programs/base.nix
    ./avahi.nix
    ./samba.nix
    ../../programs/sound.nix
    ../../programs/ssh.nix
    ./xorg.nix
    ./nfs.nix
    ./chromium-extensions.nix
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
  nix.settings.experimental-features = ["nix-command" "flakes"];

  users.defaultUserShell = pkgs.zsh;
  security.sudo.wheelNeedsPassword = false;
  environment.localBinInPath = true;

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    dejavu_fonts
  ];
  users.users."yannik".openssh.authorizedKeys.keyFiles = [
    ../../programs/configs/ssh/authorized_keys
  ];

  environment = {
    pathsToLink = ["/libexec"];
    systemPackages = with pkgs; [
      steam
      steamtinkerlaunch
      lutris
      yuzu-mainline
      vulkan-tools
      prismlauncher
      protonup-ng
      wineWowPackages.stagingFull
      linuxKernel.packages.linux_xanmod.xone
      r2mod_cli
      gamemode

      nix-diff
      age
      discord
      element-desktop
      thunderbird
      betterdiscordctl
      zoom-us
      teams-for-linux
      telegram-desktop

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
      cargo
      rustc
      rustup
      rustfmt

      gnumake
      python310
      python310Packages.pip
      (import ./python.nix {pkgs = pkgs;})
      python310Packages.setuptools
      alejandra
      dbeaver
      sshuttle
      mono

      alsa-lib
      nvtop
      tree
      hddtemp
      linuxKernel.packages.linux_xanmod_stable.cpupower
      dig
      jq
      redshift
      mcron
      nix-tree
      nix-output-monitor
      pavucontrol
      zip
      unzip
      unar

      libreoffice
      rustdesk
      android-file-transfer

      xclip
      maim
      chromium
      firefox

      btrfs-progs
      smartmontools
      parted
    ];
  };

  programs = {
    zsh.enable = true;
    adb.enable = true;
    zsh = {
      shellAliases = {
        rebuild = "sudo nixos-rebuild switch --flake '/etc/nixos#heimrechner' |& sudo nom";
      };
    };
  };

  services = {
    jellyfin.enable = false;
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
  home-manager.users.yannik = {pkgs, ...}: {
    programs.zsh.enable = true;
    imports = [../../users/yannik_gui];
  };
}
