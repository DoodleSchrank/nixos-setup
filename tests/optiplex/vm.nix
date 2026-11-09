# Hermetic full-config test: checks.x86_64-linux.optiplex-vm
#
# The real machines/optiplex (via the module list of nixosConfigurations.optiplex) plus
# overlay-hermetic.nix, booted in restoreMode with synthetic State, then switched to the
# normal configuration the way a deploy does. Service tickets add their checks and fixtures
# through optiplex.vmTest.* (machines/optiplex/vm-test.nix); this file runs whatever is there.
#
# Nodes: optiplex (the host), lan (192.168.178.50 + ULA), outside (203.0.113.10 + 2001:db8:2::10),
# optiplexnodisk (the same host booted without the Data disk, started late).
{
  pkgs,
  inputs,
  optiplexModules,
}: let
  inherit (pkgs) lib;
  tl = import ./lib.nix {inherit lib;};
  sshKeys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  overlay = import ./overlay-hermetic.nix;

  # The decided public and LAN-only ports (tickets 15, 16, 19, 21), only printed against the
  # config, so a gap shows up as a note until the service tickets have landed.
  decidedPublicTcp = [80 443 8448 3478 51413];
  decidedPublicUdp = [443 3478 51413];
  decidedLanOnlyTcp = [25560 53 8123 25580];

  hostNode = {withDataDisk, restore}: {
    imports =
      optiplexModules
      ++ [(overlay {inherit withDataDisk;})];
    # restoreMode first; the "normal" specialisation is the deploy that follows.
    optiplex.restoreMode = lib.mkOverride 90 restore;
    specialisation.normal.configuration.optiplex.restoreMode = lib.mkOverride 80 false;
  };

  clientNode = {vlan, v4, v6}: {pkgs, ...}: {
    virtualisation.vlans = lib.mkForce [];
    virtualisation.interfaces.eth1.vlan = vlan;
    networking.interfaces.eth1 = {
      ipv4.addresses = [{address = v4; prefixLength = 24;}];
      ipv6.addresses = [{address = v6; prefixLength = 64;}];
    };
    environment.systemPackages = [pkgs.python3 pkgs.openssh pkgs.curl pkgs.openssl];
    security.pki.certificateFiles = [(pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem")];
  };
in
  (import (pkgs.path + "/nixos/lib") {}).runTest ({config, ...}: {
    hostPkgs = pkgs;
    name = "optiplex-vm";
    node.specialArgs = {inherit inputs;};
    # nixpkgs.overlays comes from ./custom-pkgs, so the nodes bring their own pkgs
    node.pkgs = null;
    defaults.nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;

    nodes.optiplex = hostNode {withDataDisk = true; restore = true;};
    nodes.optiplexnodisk = hostNode {withDataDisk = false; restore = false;};
    # Fake CA (pebble) and its DNS challenge server, on the LAN. Trusted by every node.
    nodes.acme = {...}: {
      imports = [(pkgs.path + "/nixos/tests/common/acme/server")];
      virtualisation.vlans = lib.mkForce [];
      virtualisation.interfaces.eth1.vlan = 1;
      networking.interfaces.eth1.ipv4.addresses = [{address = "192.168.178.60"; prefixLength = 24;}];
      networking.nameservers = lib.mkForce ["127.0.0.1"];
      networking.firewall.allowedTCPPorts = [53 8055];
      networking.firewall.allowedUDPPorts = [53];
      systemd.services.pebble-challtestsrv = {
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          # TXT records come from the DNS-01 hook (port 8055); everything else resolves to the host
          ExecStart = "${pkgs.pebble}/bin/pebble-challtestsrv -dns01 ':53' -defaultIPv6 '' -defaultIPv4 '192.168.178.20'";
          AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
        };
      };
    };
    nodes.lan = clientNode {vlan = 1; v4 = "192.168.178.50"; v6 = "fd65:c1a5:7d2b::50";};
    nodes.outside = clientNode {vlan = 2; v4 = "203.0.113.10"; v6 = "2001:db8:2::10";};

    testScript = {nodes, ...}: let
      cfg = nodes.optiplex;
      portsOf = ranges: ports: lib.unique (ports ++ lib.concatMap (r: [r.from ((r.from + r.to) / 2) r.to]) ranges);
      publicTcp = portsOf cfg.networking.firewall.allowedTCPPortRanges cfg.networking.firewall.allowedTCPPorts;
      publicUdp = portsOf cfg.networking.firewall.allowedUDPPortRanges cfg.networking.firewall.allowedUDPPorts;
      lanTcp = cfg.optiplex.firewall.lanOnly.tcp;
      lanUdp = cfg.optiplex.firewall.lanOnly.udp;
      canary = 4444;
      missingPublic =
        (lib.subtractLists publicTcp decidedPublicTcp)
        ++ (map (p: "udp/${toString p}") (lib.subtractLists publicUdp decidedPublicUdp));
      missingLan = lib.subtractLists lanTcp decidedLanOnlyTcp;
    in ''
      LAN4, LAN6 = "192.168.178.20", "fd65:c1a5:7d2b::20"
      OUT4, OUT6 = "203.0.113.1", "2001:db8:2::1"
      probe = "${pkgs.python3}/bin/python3 ${./probe.py}"

      def reachable(client, proto, host, port):
          return client.execute(f"{probe} {proto} {host} {port}")[0] == 0

      acme.start()
      acme.wait_for_unit("pebble.service")
      acme.wait_for_unit("pebble-challtestsrv.service")
      acme.wait_for_open_port(443)
      optiplex.start()
      lan.start()
      outside.start()
      for m in (optiplex, lan, outside):
          m.wait_for_unit("multi-user.target")

      with subtest("host base: booted in restoreMode, addresses as in the real config"):
          optiplex.succeed("test \"$(cat /etc/optiplex-restore-mode)\" = 1")
          ip = optiplex.succeed("ip -br addr show")
          print(ip)
          for a in ("192.168.178.20/24", "fd65:c1a5:7d2b::20/64", "203.0.113.1/24"):
              assert a in ip, a

      with subtest("sops: only the test mirror is used and decrypts with the test age key (host.yaml: console password)"):
          src = "${cfg.sops.secrets.yannik_password_hash.sopsFile}"
          optiplex.succeed(f"grep -q age1ccq3cgfghg9wctx5ulgzfdx57505pakhnyq8mg972w79uaflsq3s8pxquj {src}")
          optiplex.fail(f"grep -q 'age17pp73lun70gl0gyuqeg6grk4mq3zcm76gfz3d0tltcdg7a02npqqhfdy9k\\|age1af8w3qyudp' {src}")
          optiplex.succeed("test -s /run/secrets-for-users/yannik_password_hash")
          optiplex.succeed("grep -q '^yannik:\\$6\\$' /etc/shadow")

      # --- fixtures, then the restoreMode checks ---
      ${tl.renderFixtures {inherit pkgs; config = cfg;}}
      ${tl.renderChecks {tier = "hermetic"; phase = "restore"; config = cfg;}}

      # --- the normal deploy: the specialisation with restoreMode off, via switch-to-configuration ---
      with subtest("switch from restoreMode to the normal configuration"):
          before = optiplex.succeed("readlink /run/current-system")
          # exit 4: some unit failed to (re)start, e.g. smartd in a VM. The failed-units subtest below
          # decides whether that is acceptable.
          rc, out = optiplex.execute("/run/current-system/specialisation/normal/bin/switch-to-configuration test 2>&1")
          print(out)
          assert rc in (0, 4), rc
          assert optiplex.succeed("readlink /run/current-system") != before

      ${tl.subtest "systemctl --failed is empty apart from offlineUnits" (tl.failedUnitsCheck {config = cfg;})}

      ${tl.renderChecks {tier = "hermetic"; phase = "normal"; config = cfg;}}

      with subtest("sshd: 25560 answers from lan, not from outside"):
          lan.succeed("install -m600 ${sshKeys.snakeOilPrivateKey} /root/id")
          ssh = "ssh -i /root/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -p 25560"
          lan.wait_until_succeeds(f"{ssh} yannik@{LAN4} true", timeout=60)
          lan.succeed(f"{ssh} yannik@{LAN6} true")
          lan.succeed(f"{ssh} yannik@{LAN4} 'sudo -n true'")
          lan.fail(f"{ssh} root@{LAN4} true")
          outside.succeed("install -m600 ${sshKeys.snakeOilPrivateKey} /root/id")
          outside.fail(f"{ssh} yannik@{OUT4} true")
          outside.fail(f"{ssh} yannik@{OUT6} true")

      with subtest("firewall: public ports open to everyone, LAN-only ports to the LAN only"):
          public_tcp = ${builtins.toJSON publicTcp}
          public_udp = ${builtins.toJSON publicUdp}
          lan_tcp = ${builtins.toJSON lanTcp}
          lan_udp = ${builtins.toJSON lanUdp}
          canary = ${toString canary}   # listens on tcp+udp, allowed nowhere
          listen = ([f"tcp:{p}" for p in public_tcp + lan_tcp + [canary]] + [f"udp:{p}" for p in public_udp + lan_udp + [canary]])
          listeners = "${pkgs.python3}/bin/python3 ${./listeners.py}"
          optiplex.succeed("systemd-run --unit=listeners " + listeners + " " + " ".join(listen))
          optiplex.wait_until_succeeds("journalctl -u listeners | grep -q ready")
          # Ports that a real service of the config holds (sshd 25560, Caddy 443, blocky 53, ...) are
          # skipped by the listeners. Stop the owner so the echo listener can take its place:
          # the firewall verdict is what is tested here, not the service.
          skipped = [l.split()[1].rstrip(":") for l in optiplex.succeed("journalctl -u listeners --no-pager -o cat").splitlines() if l.startswith("skip ")]
          for spec in skipped:
              proto, port = spec.split(":")
              flag = "-ltnp" if proto == "tcp" else "-lunp"
              pids = optiplex.succeed(f"ss -H {flag} 'sport = :{port}' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true").split()
              for pid in pids:
                  unit = optiplex.succeed(f"basename $(cut -d: -f3 /proc/{pid}/cgroup)").strip()
                  print(f"{spec} is held by {unit}; stopping it for the matrix")
                  optiplex.succeed(f"systemctl stop {unit}")
          if skipped:
              optiplex.succeed("systemctl stop listeners")
              optiplex.succeed("systemd-run --unit=listeners2 " + listeners + " " + " ".join(listen))
              optiplex.wait_until_succeeds("journalctl -u listeners2 | grep -q ready")
              assert not [l for l in optiplex.succeed("journalctl -u listeners2 --no-pager -o cat").splitlines() if l.startswith("skip ")]
          print(optiplex.succeed("nft list chain inet nixos-fw input-allow"))
          # LAN-side client: public ports and LAN-only ports, v4 and v6
          for proto, ports in (("tcp", public_tcp + lan_tcp), ("udp", public_udp + lan_udp)):
              for p in ports:
                  for a in (LAN4, LAN6):
                      assert reachable(lan, proto, a, p), f"lan -> {proto}/{p} on {a} should be open"
          # outside client: public open on both families, LAN-only closed on both
          for proto, ports in (("tcp", public_tcp), ("udp", public_udp)):
              for p in ports:
                  for a in (OUT4, OUT6):
                      assert reachable(outside, proto, a, p), f"outside -> {proto}/{p} on {a} should be open"
          for proto, ports in (("tcp", lan_tcp), ("udp", lan_udp)):
              for p in ports:
                  for a in (OUT4, OUT6):
                      assert not reachable(outside, proto, a, p), f"outside -> {proto}/{p} on {a} must be closed"
          # the canary stays closed for both clients
          for proto in ("tcp", "udp"):
              for a in (LAN4, LAN6):
                  assert not reachable(lan, proto, a, canary), f"canary {proto} open from lan on {a}"
              for a in (OUT4, OUT6):
                  assert not reachable(outside, proto, a, canary), f"canary {proto} open from outside on {a}"
          optiplex.succeed("systemctl stop listeners listeners2 || true")
          print("decided public ports not yet opened by any service file: ${toString missingPublic}")
          print("decided LAN-only ports not yet opened by any service file: ${toString missingLan}")

      with subtest("notify-failure@ fires for a deliberately failing unit"):
          optiplex.wait_for_unit("ntfy-stub.service")
          optiplex.fail("systemctl start failing.service")
          optiplex.wait_until_succeeds("grep -q 'failing.service failed on optiplex' /tmp/ntfy.log")
          optiplex.succeed("grep -q 'about-to-fail-marker' /tmp/ntfy.log; grep -q 'PATH=/test' /tmp/ntfy.log; grep -q 'PRIO=high' /tmp/ntfy.log")
          optiplex.succeed("systemctl reset-failed failing.service")

      # --- the Data disk absent ---
      stateUnits = ${builtins.toJSON cfg.optiplex.stateUnits}
      optiplex.shutdown()
      optiplexnodisk.start()
      # Without the Data disk the boot waits for the by-uuid device until systemd's 90 s device
      # timeout (the nofail mounts are not required, but their pending jobs delay multi-user.target).
      optiplexnodisk.wait_for_unit("multi-user.target", timeout=600)
      with subtest("Data disk absent: /state is an empty immutable directory and no State service runs"):
          optiplexnodisk.fail("findmnt /state")
          optiplexnodisk.fail("findmnt /mnt/tbssd")
          optiplexnodisk.succeed("lsattr -d /state | cut -c5 | grep -q i")
          optiplexnodisk.succeed("test -z \"$(ls -A /state)\"")
          optiplexnodisk.fail("touch /state/x")
          for u in stateUnits:
              u = u if u.endswith(".service") else u + ".service"
              optiplexnodisk.fail(f"systemctl is-active {u}")
              optiplexnodisk.fail(f"timeout 20 systemctl start {u}")
          # nothing was written to the System disk's bare mountpoint
          optiplexnodisk.succeed("test -z \"$(ls -A /state)\"")
    '';
  })
