{
  services.samba-wsdd.enable = true;
  networking.firewall.allowedTCPPorts = [
    5357 # wsdd
  ];
  networking.firewall.allowedUDPPorts = [
    3702 # wsdd
  ];
  services.samba = {
    enable = true;
    enableWinbindd = true;
    openFirewall = true;
    securityType = "user";
    extraConfig = ''
      workgroup = WORKGROUP
      server string = homepc
      netbios name = homepc
      security = user
      use sendfile = yes
      hosts allow = 192.168.0. 127.0.0.1 localhost
      hosts deny = 0.0.0.0/0
      guest account = nobody
      map to guest = bad user
      usershare allow guests = yes
      server role = standalone server
      dns proxy = no

      disable netbios = false
      dns proxy = yes
      ntlm auth = yes

      deadtime = 30
      use sendfile = yes

      wins support = yes
      local master = no
      preferred master = no
      os level = 0

      follow symlinks = yes
      wide links = yes
      unix extensions = no

      usershare path = /var/lib/samba/usershare
      usershare max shares = 100
      usershare owner only = yes
      passwd program = /usr/bin/passwd %u
      passwd chat = *New*UNIX*password* %n\n *ReType*new*UNIX*password* %n\n *passwd:*all*authentication*tokens*updated*successfully*
      passdb backend = tdbsam
      obey pam restrictions = yes
      unix password sync = yes
      browseable = yes
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
        writeable = "no";
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