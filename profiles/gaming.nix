{pkgs, ...}:
{
  home.packages = with pkgs; [
    #gaming
    steamtinkerlaunch
    lutris
    gamemode
    wineWowPackages.waylandFull
    winetricks
    prismlauncher
    linuxKernel.packages.linux_xanmod.xone
    r2mod_cli
    flatpak
  ];
}

