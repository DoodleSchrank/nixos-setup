{pkgs, ...}:
{

  home.packages = with pkgs; [
    wlsunset
  ];

  services.wlsunset = {
    enable = true;
    sunrise = "7:00";
    sunset = "22:00";
    #latitude = 54.5;
    #longitude = 9.9;
    temperature.day = 6500;
    temperature.night = 3000;
  };
}