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
    thunderbird
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
  systemd.user.services.udiskie.unit.after = "graphical.target";
  systemd.user.services.network-manager-applet.unit.after = "graphical.target";

  # fix xdg-open
  # https://github.com/NixOS/nixpkgs/issues/189851
  #waitForFullPath = {}:
  #  stdenv.mkDerivation {
  #    name = "wait-for-full-path";
  #    builder = writeShellScript "waitForFullPath.sh" ''
  #      ispresent () {
  #        systemctl --user show-environment | grep -E '^PATH=.*/.nix-profile/bin'
  #      }
  #      while ! ispresent; do
  #        sleep 0.1;
  #      done
  #    '';
  #  };
  #systemd.user.services.wait-for-full-path = {
  #  Unit.Description = "wait for systemd units to have full PATH";
  #  Install = {
  #    WantedBy = [ "xdg-desktop-portal.service" ];
  #    #Before = [ "xdg-desktop-portal.service" ];
  #  };
  #  Service = {
  #  # ExecStart = ''${waitForFullPath}/waitForFullPath.sh'';
  #    Type = "oneshot";
  #    TimeoutStartSec = "60";
  #  };
  #};

  home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";

  home.sessionVariables = {
    XDG_ACTIVATION_TOKEN = "1";
  };
}
