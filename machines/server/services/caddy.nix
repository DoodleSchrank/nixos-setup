{
  networking.firewall.allowedTCPPorts = [80 443];
  services.caddy = {
    enable = true;
    virtualHosts = {
      "nnik.dev".extraConfig = ''
        encode gzip
        reverse_proxy /_matrix/* localhost:8008
        reverse_proxy /_synapse/client/* localhost:8008
      '';
      "ya.nnik.dev".extraConfig = ''
        root * /srv/http/ya.nnik.dev
        file_server
      '';
      "etesync.nnik.dev".extraConfig = ''
        encode gzip
        root /static /srv/etesync/static
        reverse_proxy * localhost:25567
        file_server
      '';
      "pw.nnik.dev".extraConfig = ''
        encode gzip
        reverse_proxy * localhost:25567
      '';
      "elabftow.nnik.dev".extraConfig = ''
        encode gzip
        reverse_proxy * localhost:25569
      '';
    };
  };
}
