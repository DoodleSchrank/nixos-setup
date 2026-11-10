# coturn for Matrix calls (TURN relay for Synapse's voip/turnServer). Decisions: tickets 19 and 31.
#
#   * `use-auth-secret`: Synapse hands out HMAC credentials derived from `turn_shared_secret`; coturn
#     checks them with the same secret (secrets/optiplex/coturn.yaml, key `static_auth_secret`). No
#     `no-auth` any more (the Arch coturn was an open relay).
#   * Listens on 3478 (TCP+UDP) only, no TLS/DTLS listener (like the Arch one, and the FritzBox only
#     forwards 3478). Relay ports: UDP 49152-49252 (the router share is added at the Cutover).
#   * Peers: every private, loopback, link-local and special IPv4 range is denied, with no exceptions
#     (IPv6 peers are refused anyway, see deniedPeers). Relays are IPv4 only (decision of the review round): a relay is bound to the host's
#     LAN address and announced as the public IPv4, so an IPv6 relay can never reach the LAN's global
#     addresses. Clients may still talk to coturn over IPv4 or IPv6.
#   * NAT: the relay address is announced as `external-ip=<public>/<LAN address>`. The public IPv4 is
#     dynamic. It is resolved from the A record of nnik.dev (kept current by ddns.nix) through a public
#     resolver (blocky's split horizon answers with the LAN address) every time coturn starts, and a
#     timer restarts coturn when the A record changed (COTURN_DNS_RESOLVER in the unit environment replaces
#     the resolver, the VM tests use that).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  ccfg = cfg.coturn;
  secretsFile = cfg.secretsDir + "/coturn.yaml";
  haveSecrets = builtins.pathExists secretsFile;
  enable = !cfg.restoreMode;
  secretPath = "/run/secrets/coturn/static_auth_secret";

  # IPv4 only, on purpose: relays are IPv4 only, so coturn refuses every IPv6 peer by itself (address
  # family mismatch, tested), and as soon as one IPv6 range is listed here coturn 4.11 denies EVERY
  # IPv4 peer too (found in the VM test: 8.8.8.8 "denied in the range ::-::1").
  deniedPeers = [
    # IPv4
    "0.0.0.0-0.255.255.255" # "this network"
    "10.0.0.0-10.255.255.255"
    "100.64.0.0-100.127.255.255" # CGNAT
    "127.0.0.0-127.255.255.255"
    "169.254.0.0-169.254.255.255"
    "172.16.0.0-172.31.255.255"
    "192.0.0.0-192.0.0.255"
    "192.0.2.0-192.0.2.255"
    "192.88.99.0-192.88.99.255"
    "192.168.0.0-192.168.255.255" # the LAN (192.168.178.0/24) is inside
    "198.18.0.0-198.19.255.255"
    "198.51.100.0-198.51.100.255"
    "203.0.113.0-203.0.113.255"
    "224.0.0.0-239.255.255.255" # multicast
    "240.0.0.0-255.255.255.255"
  ];

  # Prints the current public IPv4 of the host, or nothing. The resolver can be replaced with
  # COTURN_DNS_RESOLVER in the unit environment (the VM test points it at its fake DNS).
  publicIp = pkgs.writeShellScript "coturn-public-ip" ''
    ${pkgs.dig}/bin/dig +short +time=3 +tries=2 A nnik.dev "@''${COTURN_DNS_RESOLVER:-9.9.9.9}" \
      | ${pkgs.gnugrep}/bin/grep -m1 -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true
  '';
  runConfig = "/run/coturn/turnserver.cfg";
in {
  options.optiplex.coturn = {
    relayAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.178.20";
      description = "The host's IPv4 address that relays are bound to (the LAN address; the router forwards the relay range to it).";
    };
  };

  config = {
    users.users.turnserver = {
      uid = config.ids.uids.turnserver;
      group = "turnserver";
      isSystemUser = true;
    };
    users.groups.turnserver.gid = config.ids.gids.turnserver;

    services.coturn = {
      inherit enable;
      realm = "nnik.dev";
      listening-port = 3478;
      min-port = 49152;
      max-port = 49252;
      relay-ips = [ccfg.relayAddress];
      use-auth-secret = true;
      static-auth-secret-file = secretPath;
      no-tls = true;
      no-dtls = true;
      no-tcp-relay = true;
      no-cli = true;
      extraConfig = ''
        no-multicast-peers
        fingerprint
        user-quota=12
        total-quota=1200
        log-file=stdout
        simple-log
        ${lib.concatMapStringsSep "\n" (r: "denied-peer-ip=${r}") deniedPeers}
      '';
    };

    systemd.services.coturn = lib.mkIf enable {
      # external-ip is appended to the generated config (/run/coturn/turnserver.cfg) at every start
      preStart = lib.mkAfter ''
        ip="$(${publicIp})"
        if [ -n "$ip" ]; then
          echo "external-ip=$ip/${ccfg.relayAddress}" >> ${runConfig}
        else
          echo "WARNING: no public IPv4 found, coturn announces its LAN address as the relay address" >&2
        fi
      '';
    };

    # Restart coturn when the public address changed (the DDNS updater runs every 5 minutes).
    systemd.services.coturn-external-ip = lib.mkIf enable {
      description = "Restart coturn when the public IPv4 address changed";
      serviceConfig = {
        Type = "oneshot";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
      script = ''
        systemctl is-active --quiet coturn.service || exit 0
        now="$(${publicIp})"
        [ -n "$now" ] || exit 0   # a failed lookup is not a change
        have="$(${pkgs.gnused}/bin/sed -n 's|^external-ip=\([^/]*\)/.*|\1|p' ${runConfig})"
        if [ "$now" != "$have" ]; then
          echo "public IPv4 changed: '$have' -> '$now', restarting coturn"
          systemctl restart coturn.service
        fi
      '';
    };
    systemd.timers.coturn-external-ip = lib.mkIf enable {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitInactiveSec = "5min";
      };
    };

    # --- egress filter for the relay sockets ------------------------------------------------------
    # coturn exempts its OWN addresses from denied-peer-ip (found in the VM test: a relay to 192.168.178.20
    # is permitted). From the host's own address a relay could then reach everything bound there, including
    # the LAN-only Caddy vhosts (the source is a LAN address). So whatever leaves a relay port (and only
    # those: replies to clients leave from 3478) towards the host itself or a private range is dropped.
    # (IPv6 never gets that far: relays are IPv4 only.)
    networking.nftables.tables.coturn-egress = lib.mkIf enable {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority 0; policy accept;
          meta skuid ${toString config.ids.uids.turnserver} udp sport ${toString config.services.coturn.min-port}-${toString config.services.coturn.max-port} fib daddr type local counter drop comment "relay to the host itself"
          meta skuid ${toString config.ids.uids.turnserver} udp sport ${toString config.services.coturn.min-port}-${toString config.services.coturn.max-port} ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } counter drop comment "relay to a private range"
        }
      '';
    };

    # --- firewall: public, v4 and v6 --------------------------------------------------------------
    networking.firewall = {
      allowedTCPPorts = [3478];
      allowedUDPPorts = [3478];
      allowedUDPPortRanges = [
        {
          from = 49152;
          to = 49252;
        }
      ];
    };

    # --- secrets ----------------------------------------------------------------------------------
    sops.secrets."coturn/static_auth_secret" = lib.mkIf haveSecrets {
      sopsFile = secretsFile;
      key = "static_auth_secret";
      owner = "turnserver";
      mode = "0400";
      restartUnits = lib.optional enable "coturn.service";
    };
    warnings = lib.optional (!haveSecrets) ''
      secrets/optiplex/coturn.yaml does not exist (looked in ${toString cfg.secretsDir}): coturn has no auth secret and will not start.
      Fresh value, also read by Synapse as turn_shared_secret (see the Answer of ticket 31):
        (cd secrets && printf 'static_auth_secret: %s\n' "$(openssl rand -hex 32)" | sops --encrypt --input-type yaml --output-type yaml --filename-override optiplex/coturn.yaml /dev/stdin > optiplex/coturn.yaml)
      and `git add` it.
    '';

    # --- VM test ------------------------------------------------------------------------------------
    optiplex.vmTest.checks.matrix-5-coturn-restore = {
      phase = "restore";
      script = ''
        optiplex.fail("systemctl cat coturn.service")
        assert optiplex.succeed("stat -L -c '%U %a' ${secretPath}").strip() == "turnserver 400"
      '';
    };

    optiplex.vmTest.checks.matrix-5-coturn = {
      script = ''
        challtest = "http://192.168.178.60:8055"  # the test DNS: pebble-challtestsrv on the acme node
        def set_public_ip(ip):
            optiplex.succeed(f"curl -fsS -d '{{\"host\":\"nnik.dev\"}}' {challtest}/clear-a")
            optiplex.succeed(f"curl -fsS -d '{{\"host\":\"nnik.dev\",\"addresses\":[\"{ip}\"]}}' {challtest}/add-a")
        runcfg = "${runConfig}"

        optiplex.wait_for_unit("coturn.service")
        # the generated config: secret auth, the fixed range, no TLS, every private range denied, no exceptions
        conf = optiplex.succeed(f"cat {runcfg}")
        lines = [l.strip() for l in conf.splitlines() if l.strip()]
        for want in ("use-auth-secret", "realm=nnik.dev", "min-port=49152", "max-port=49252", "no-tls", "no-dtls",
                     "no-tcp-relay", "no-cli", "no-multicast-peers", "relay-ip=${ccfg.relayAddress}", "listening-port=3478"):
            assert want in lines, (want, conf)
        assert "no-auth" not in lines and not [l for l in lines if l.startswith("allowed-peer-ip")], conf
        assert "static-auth-secret=" + optiplex.succeed("cat ${secretPath}") in lines
        denied = [l for l in lines if l.startswith("denied-peer-ip=")]
        for want in ("10.0.0.0-10.255.255.255", "127.0.0.0-127.255.255.255", "169.254.0.0-169.254.255.255",
                     "172.16.0.0-172.31.255.255", "192.168.0.0-192.168.255.255", "100.64.0.0-100.127.255.255"):
            assert "denied-peer-ip=" + want in denied, want
        assert not [l for l in denied if ":" in l], "an IPv6 denied-peer-ip makes coturn deny every IPv4 peer"
        # Synapse and coturn share one secret
        assert optiplex.succeed("grep -A1 '^turn_shared_secret:' /run/secrets/rendered/synapse-secrets.yaml").splitlines()[1].strip() == optiplex.succeed("cat ${secretPath}").strip()
        # no public IPv4 known (no internet in this VM): coturn starts anyway and says so
        optiplex.succeed("journalctl -u coturn.service --no-pager | grep -q 'no public IPv4 found'")
        assert "external-ip" not in conf

        # the NAT mapping follows the A record of nnik.dev: point the lookup at the test DNS
        optiplex.succeed("mkdir -p /run/systemd/system/coturn.service.d /run/systemd/system/coturn-external-ip.service.d")
        for u in ("coturn", "coturn-external-ip"):
            optiplex.succeed(f"printf '[Service]\\nEnvironment=COTURN_DNS_RESOLVER=192.168.178.60\\n' > /run/systemd/system/{u}.service.d/10-test.conf")
        optiplex.succeed("systemctl daemon-reload")
        set_public_ip("203.0.113.1")
        optiplex.succeed("systemctl start coturn-external-ip.service")   # none -> 203.0.113.1: restarts coturn
        optiplex.wait_for_unit("coturn.service")
        optiplex.wait_until_succeeds(f"grep -qx 'external-ip=203.0.113.1/${ccfg.relayAddress}' {runcfg}")

        # the three checks of the ticket, from the internet client (UDP 3478 through the public firewall)
        secret = optiplex.succeed("cat ${secretPath}").strip()
        # a sink on the host: data that a relay manages to send to the host itself must not arrive
        optiplex.succeed("systemd-run --unit=udp-sink --property=StandardOutput=file:/tmp/udp-sink.log python3 -u -c \"import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('0.0.0.0', 9999)); print('ready', flush=True)\nwhile True: print(s.recvfrom(100)[0], flush=True)\"")
        optiplex.wait_until_succeeds("grep -q ready /tmp/udp-sink.log")
        optiplex.succeed("python3 -c \"import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'control', ('${ccfg.relayAddress}', 9999))\"")
        optiplex.wait_until_succeeds("grep -q control /tmp/udp-sink.log")
        print(outside.succeed(f"python3 ${../../../tests/optiplex/matrix-turn.py} 203.0.113.1 '{secret}' 203.0.113.1 49152 49252 ${ccfg.relayAddress} 9999"))
        import time as _time
        _time.sleep(2)
        assert "must-not-arrive" not in optiplex.succeed("cat /tmp/udp-sink.log"), "a relay delivered data to the host itself"
        drops = optiplex.succeed("nft list chain inet coturn-egress output")
        print(drops)
        assert 'comment "relay to the host itself"' in drops
        first = [l for l in drops.splitlines() if "relay to the host itself" in l][0]
        assert "counter packets 0 " not in first, "the egress filter dropped nothing: " + first
        # TURN over TCP answers too (Synapse hands out turn:...?transport=tcp)
        outside.succeed("timeout 5 bash -c '</dev/tcp/203.0.113.1/3478'")

        # an address change restarts coturn exactly once, an unchanged one does not
        stamp = lambda: optiplex.succeed("systemctl show coturn.service -p ActiveEnterTimestampMonotonic").strip()
        before = stamp()
        optiplex.succeed("systemctl start coturn-external-ip.service")
        assert stamp() == before, "coturn restarted without an address change"
        set_public_ip("203.0.113.7")
        optiplex.succeed("systemctl start coturn-external-ip.service")
        optiplex.wait_for_unit("coturn.service")
        optiplex.wait_until_succeeds(f"grep -qx 'external-ip=203.0.113.7/${ccfg.relayAddress}' {runcfg}")
        assert stamp() != before
        # restore the first mapping so the later checks see a normal state
        set_public_ip("203.0.113.1")
        optiplex.succeed("systemctl start coturn-external-ip.service")
        optiplex.wait_until_succeeds(f"grep -qx 'external-ip=203.0.113.1/${ccfg.relayAddress}' {runcfg}")
      '';
    };
  };
}
