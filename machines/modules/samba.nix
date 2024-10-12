{pkgs, ...}: {
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
    winbindd.enable = true;
    openFirewall = true;
    /*extraConfig = ''
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
    '';*/
    settings = {
      global = {
        "server min protocol" = "SMB3";
        security = "user";
      };
      todo = {
        path = "/home/yannik/stuff/storage/entertainment/todo";
        comment = "Todo";
        browseable = "yes";
        public = "yes";
        writeable = "yes";
        "guest ok" = "yes";
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
  environment.systemPackages = [ pkgs.cifs-utils ];
    fileSystems."/mnt/shield" = {
      device = "//192.168.178.38/";
      fsType = "cifs";
      options = let
        # this line prevents hanging on network split
        automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";

      in ["${automount_opts},credentials=/etc/nixos/smb-secrets"];
    };
}
