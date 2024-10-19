{pkgs, ...}:
{
  home.packages = with pkgs; [
    #gaming
    steamtinkerlaunch
    lutris
    prismlauncher
    linuxKernel.packages.linux_xanmod.xone
    r2mod_cli
    gamemode
    wineWowPackages.waylandFull
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

