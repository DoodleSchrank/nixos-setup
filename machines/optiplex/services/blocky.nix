# LAN DNS: blocky replaces Pi-hole. Split horizon for nnik.dev and opti.plex, ad
# blocking with the carried Pi-hole lists, DNS-over-TLS upstreams.
# No State: the lists and every setting are in Nix (blocky/*.txt).
#
# The host resolves through this blocky too (networking.nameservers in networking.nix:
# 127.0.0.1, then 9.9.9.9 as fallback that is not handed to the LAN).
{
  config,
  lib,
  ...
}: let
  # What the split horizon answers with: the host itself, on LAN v4 and the ULA.
  hostAddresses = "192.168.178.20,fd65:c1a5:7d2b::20";

  nonEmptyLines = file:
    lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (lib.splitString "\n" (builtins.readFile file));
in {
  services.blocky = {
    enable = true; # stays on in restoreMode: the LAN needs DNS during the restore window
    settings = {
      # Port 53 on every address: the LAN, loopback, and later the runner VM bridge
      # (Gitea runner VMs adds its own firewall rule for it). The firewall keeps it
      # LAN-only (optiplex.firewall.lanOnly below). The API/DoH port stays on loopback.
      ports = {
        dns = 53;
        http = "127.0.0.1:4000";
      };

      upstreams = {
        # `fast`: start even while the internet is unreachable. The whole LAN depends
        # on this unit, and a power cut brings the host up before the router is online.
        init.strategy = "fast";
        groups.default = [
          "tcp-tls:dns.quad9.net:853"
          "tcp-tls:one.one.one.one:853"
        ];
      };
      # Plain IPs, so blocky never depends on itself (or on any resolver) to find the
      # DoT servers.
      bootstrapDns = [
        {upstream = "9.9.9.9";}
        {upstream = "1.1.1.1";}
      ];

      customDNS = {
        # A mapping also matches every subdomain. Retired names (pihole, portainer,
        # fredy, the hairpin CNAMEs) fall under it and meet Caddy's catch-all.
        mapping = {
          "nnik.dev" = hostAddresses;
          "opti.plex" = hostAddresses;
        };
        # TXT/MX/CAA/SOA for nnik.dev still go upstream (lego's zone lookup, mail
        # checkers); only A/AAAA are answered locally.
        filterUnmappedTypes = false;
      };

      blocking = {
        # The same group name `ads` in both lists: an allowlist-only group would
        # block everything that is not on it.
        denylists.ads = nonEmptyLines ./blocky/adlists.txt ++ [./blocky/deny.txt];
        allowlists.ads = [./blocky/allow.txt];
        clientGroupsBlock.default = ["ads"];
        blockType = "zeroIp"; # Pi-hole's NULL mode
        loading = {
          strategy = "fast"; # start without waiting for (or needing) the list hosts
          refreshPeriod = "48h";
          concurrency = 10;
        };
      };

      caching.prefetching = true;
      log.level = "warn"; # no query log database
    };
  };

  optiplex.firewall.lanOnly = {
    tcp = [53];
    udp = [53];
  };
}
