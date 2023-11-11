{
  services.samba-wsdd.enable = true;
  networking.firewall.allowedTCPPorts = [
    445
    139
    5357 # wsdd
  ];
  networking.firewall.allowedUDPPorts = [
    137
    138
    3702 # wsdd
  ];
  services.samba = {
    enable = true;
    enableWinbindd = true;
    openFirewall = true;
    securityType = "user";
    extraConfig = ''
      security = user
      use sendfile = yes
      hosts allow = 192.168.0. 127.0.0.1 localhost
      hosts deny = 0.0.0.0/0
      guest account = nobody
      map to guest = bad user
      usershare allow guests = yes
      server role = standalone server

      use sendfile = yes

      follow symlinks = yes
      wide links = yes
      unix extensions = no
    '';
    shares = {
      global = {
        "server min protocol" = "SMB3";
      };
      movies = {
        path = "/storage/entertainment/movies";
        comment = "Movies";
        browseable = "yes";
        public = "yes";
        writeable = "no";
      };
      series = {
        path = "/storage/entertainment/series";
        comment = "Series";
        browseable = "yes";
        public = "yes";
        writeable = "no";
      };
      music = {
        path = "/storage/entertainment/music";
        comment = "Music";
        browseable = "yes";
        public = "yes";
        writeable = "no";
      };
      todo = {
        path = "/storage/entertainment/todo";
        comment = "Todo";
        browseable = "yes";
        public = "yes";
        writeable = "yes";
      };
      homes = {
        comment = "Home Directories";
        browseable = "yes";
        writable = "yes";
        "valid users" = "%S";
        "guest ok" = "no";
      };
    };
  };
}
