{
  services.gammastep = {
    enable = true;
    dawnTime = "7:00-8:00";
    duskTime = "22:00-22:30";
    latitude = 54.5;
    longitude = 9.9;
    temperature.day = 6500;
    temperature.night = 3000;
    tray = true;
  };
  systemd.user.services.gammastep-indicator.unit.after = "graphical.target";
}