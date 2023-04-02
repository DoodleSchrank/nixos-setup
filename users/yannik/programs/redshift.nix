{
  services.redshift = {
    enable = true;
    dawnTime = "6:00-6:30";
    duskTime = "22:00-22:30";
    temperature.night = 3500;
    settings.redshift.brightness-night = 0.7;
  };
}