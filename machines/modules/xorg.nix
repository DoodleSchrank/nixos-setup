{pkgs, ...}: {
  services.xserver = {
    enable = true;
    xkb.layout = "de";
    videoDrivers = ["amdgpu"];
    desktopManager.xterm.enable = false;
    # disabling lightdm makes autologin annoying ._. see https://konfou.xyz/posts/nixos-without-display-manager/
    #displayManager.startx.enable = true;
    serverFlagsSection = ''
      Option "BlankTime" "0"
      Option "StandbyTime" "0"
      Option "SuspendTime" "0"
      Option "OffTime" "0"
    '';
    windowManager.i3.enable = true;
    exportConfiguration = true;
  };
  services.libinput = {
    enable = true;
    mouse = {
      middleEmulation = false;
    };
  };
  services.displayManager = {
    defaultSession = "none+i3";
    #setupCommands = "${pkgs.xorg.xrandr}/bin/xrandr --output DP-0 --mode 2560x1440 --rate 75.0 --left-of DP-2 --primary --mode 2560x1440 --rate 144.0";
    autoLogin = {
      enable = true;
      user = "yannik";
    };
  };
}
