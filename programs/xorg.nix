{pkgs, ...}:
{
  services.xserver = {
    enable = true;
    layout = "de";
    videoDrivers = [ "nvidia" ];
    desktopManager.xterm.enable = false;
    # disabling lightdm makes autologin annoying ._. see https://konfou.xyz/posts/nixos-without-display-manager/
    #displayManager.startx.enable = true;
    serverFlagsSection =
      ''
      Option "BlankTime" "0"
      Option "StandbyTime" "0"
      Option "SuspendTime" "0"
      Option "OffTime" "0"
      '';
    displayManager = {
      defaultSession = "none+i3";
      setupCommands = "${pkgs.xorg.xrandr}/bin/xrandr --output DP-2 --mode 2560x1440 --rate 75.0 --left-of DP-0 --mode 2560x1440 --rate 144.0";
      autoLogin = {
        enable = true;
        user = "yannik";
      };
    };
    windowManager.i3 = {
      enable = true;
      extraPackages = with pkgs; [
        dmenu
        i3status
      ];
    };
  };
}
