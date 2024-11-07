{pkgs, ...}:
{
  home.packages = with pkgs; [
    #gaming
    steamtinkerlaunch
    lutris
    gamemode
    wineWowPackages.waylandFull
    prismlauncher
    linuxKernel.packages.linux_xanmod.xone
    r2mod_cli
    flatpak
  ];
  systemd.user.services.steam = {
    Unit = {
      Description = "Open Steam in the background at boot";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.steam}/bin/steam -nochatui -nofriendsui -silent %U";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}

