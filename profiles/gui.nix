{pkgs, ...}:
{
  imports = [
    modules/alacritty.nix
    modules/chromium.nix
    modules/darkmode.nix
    modules/sway
  ];
  home.packages = with pkgs; [
    #comm
    (pkgs.discord.override {
      withOpenASAR = true;
      withVencord = true;
      nss = nss;
    })
    element-desktop
    betterbird
    zoom-us
    telegram-desktop
    mattermost-desktop
    rustdesk-flutter

    #media
    feh
    okular
    vlc
    yt-dlp

    #other gui tools
    pavucontrol
    libreoffice
    android-file-transfer
    warpinator
    udiskie
    firefox

    #file browser
    nemo
  ];

  # doesnt recognize wayland
  services = {
    network-manager-applet.enable = true;
    udiskie = {
      enable = true;
      tray = "auto";
      automount = false;
      notify = false;
      settings = {
        program_options = {
          file_manager = "${pkgs.alacritty}/bin/alacritty -e ${pkgs.ranger}/bin/ranger";
        };
      };
    };
  };

  # fix xdg-open
  # https://github.com/NixOS/nixpkgs/issues/189851
  systemd.user.services.wait-for-full-path = {
    Unit.Description = "wait for systemd units to have full PATH";
    Install = {
      WantedBy = [ "xdg-desktop-portal.service" ];
      Before = [ "xdg-desktop-portal.service" ];
      Path = with pkgs; [ systemd coreutils gnugrep ];
    };
    Service = {
      ExecStart = ''
        ispresent () {
          systemctl --user show-environment | grep -E '^PATH=.*/.nix-profile/bin'
        }
        while ! ispresent; do
          sleep 0.1;
        done
      '';
      Type = "oneshot";
      TimeoutStartSec = "60";
    };
  };

  home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";

  home.sessionVariables = {
    XDG_ACTIVATION_TOKEN = "1";
  };
}
