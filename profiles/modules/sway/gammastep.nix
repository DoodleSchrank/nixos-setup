{
  services.gammastep = {
    enable = true;
    dawnTime = "7:00-8:00";
    duskTime = "22:00-22:30";
    latitude = 55.0;
    longitude = 10.0;
    temperature.day = 6500;
    temperature.night = 3000;
    tray = true;
    settings = {
      general = {
        brightness-night = 0.7;
      };
    };
  };
  systemd.user.services.gammastep-indicator.unit.after = "graphical.target";
}