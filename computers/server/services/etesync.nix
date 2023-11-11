{
  services.etebase-server = {
    enable = true;
    dataDir = /srv/etesync;
    settings = {
      global.secret_file = "${config.services.etebase-server.dataDir}/secret.txt";
      allowed_hosts.allowed_host1 = "localhost";
      allowed_hosts.allowed_host2 = "etesync.nnik.dev";
      port = 25567;
    };
  };
}
