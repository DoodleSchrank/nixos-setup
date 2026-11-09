# VM checks and fixtures of transmission and NFS (the optiplex.vmTest seam, see
# machines/optiplex/vm-test.nix). Imported from transmission.nix; inert outside the tests.
#
# Representative State: one torrent (.torrent, resume file, payload) made by a real transmission in
# the fixture, laid out and owned (169:169) as the Arch copy would be, then put through
# transmission/restore.sh (the Cutover command) in restoreMode. In the normal configuration the
# daemon must pick it up as seeding, without a re-verify (the payload has one flipped byte under
# an unchanged mtime: a re-verify would show < 100 %).
#
# `lan` (192.168.178.50) plays the Shield, a browser and a swarm peer; `outside` the internet.
{
  config,
  lib,
  pkgs,
  ...
}: let
  tr = pkgs.transmission_4;
  # tests/optiplex/probe.py: exit 0 if the port answers within 2 s
  probe = "${pkgs.python3}/bin/python3 ${../../../tests/optiplex/probe.py}";
  jq = "${pkgs.jq}/bin/jq";
  rpcUrl = "http://127.0.0.1:25559/transmission/rpc";

  # the settings of the normal configuration, for the diff-settings check
  generatedSettings = pkgs.writeText "generated-settings.json" (builtins.toJSON config.specialisation.normal.configuration.services.transmission.settings);

  # Session-id handshake + one JSON-RPC call: rpc.sh '<json>'
  rpcSh = pkgs.writeShellScript "rpc.sh" ''
    export PATH=${lib.makeBinPath [pkgs.curl pkgs.gnused pkgs.coreutils]}
    sid=$(curl -s -D - -o /dev/null ${rpcUrl} | tr -d '\r' | sed -n 's/^[Xx]-[Tt]ransmission-[Ss]ession-[Ii]d: //p')
    exec curl -s -H "X-Transmission-Session-Id: $sid" -d "$1" ${rpcUrl}
  '';

  # a stand-in for Arch's settings.json (the facts of ticket 40, plus one setting the config lacks)
  archSettings = pkgs.writeText "arch-settings.json" (builtins.toJSON {
    download-dir = "/trrnt";
    watch-dir = "/trrnt/watch";
    watch-dir-enabled = true;
    incomplete-dir-enabled = false;
    umask = "022";
    dht-enabled = false;
    pex-enabled = false;
    lpd-enabled = false;
    encryption = 1;
    peer-limit-global = 2000;
    peer-limit-per-torrent = 500;
    download-queue-size = 5;
    queue-stalled-minutes = 30;
    preallocation = 1;
    rename-partial-files = true;
    upload-slots-per-torrent = 14;
    cache-size-mb = 4;
    port-forwarding-enabled = true;
    ratio-limit-enabled = false;
    rpc-authentication-required = false;
    rpc-bind-address = "0.0.0.0";
    rpc-port = 25559;
    rpc-host-whitelist = "transmission.opti.plex";
    rpc-host-whitelist-enabled = true;
    rpc-whitelist = "127.0.0.1,::1,192.168.178.21";
    rpc-whitelist-enabled = false;
    rpc-username = "";
    rpc-password = "{not-a-real-hash";
    idle-seeding-limit = 60; # not carried by the config: diff-settings must report it
  });

  fixtureSettings = pkgs.writeText "fixture-settings.json" (builtins.toJSON {
    download-dir = "/trrnt";
    rpc-port = 25999;
    rpc-bind-address = "127.0.0.1";
    rpc-authentication-required = false;
    rpc-whitelist-enabled = false;
    rpc-host-whitelist-enabled = false;
    peer-port = 51999;
    port-forwarding-enabled = false;
    dht-enabled = false;
    pex-enabled = false;
    lpd-enabled = false;
    watch-dir-enabled = false;
    incomplete-dir-enabled = false;
  });

  # lan: tracker (announce answer = the seeder itself) and file server for the .torrent
  trackerPy = pkgs.writeText "tracker.py" ''
    import http.server, socket
    class H(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/announce"):
                body = b"d8:intervali30e5:peers6:" + socket.inet_aton("192.168.178.50") + (51413).to_bytes(2, "big") + b"e"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                super().do_GET()
    http.server.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
  '';
  seederSettings = pkgs.writeText "seeder-settings.json" (builtins.toJSON {
    download-dir = "/srv/seed";
    rpc-port = 9091;
    rpc-bind-address = "127.0.0.1";
    rpc-authentication-required = false;
    rpc-whitelist-enabled = false;
    rpc-host-whitelist-enabled = false;
    peer-port = 51413;
    port-forwarding-enabled = false;
    dht-enabled = false;
    pex-enabled = false;
    lpd-enabled = false;
  });
in {
  optiplex.vmTest.fixtures.transmission.script = ''
    export PATH=${lib.makeBinPath [tr pkgs.coreutils pkgs.util-linux pkgs.gnugrep]}:$PATH
    r=127.0.0.1:25999
    work=$(mktemp -d)

    # The Data disk of the harness has no trrnt/ yet (the bind mount failed at boot, nofail).
    install -d -m 775 /mnt/tbssd/trrnt
    mountpoint -q /trrnt || systemctl start trrnt.mount
    mountpoint -q /trrnt

    # torrents as transmission itself writes them (resume file, copied .torrent) ...
    head -c 1048576 /dev/urandom > /trrnt/fixture.bin
    head -c 2097152 /dev/urandom > /trrnt/watched.bin
    transmission-create -p -o $work/fixture.torrent -t http://tracker.invalid/announce /trrnt/fixture.bin
    install -d -m 755 /mnt/tbssd/fixture-extra
    transmission-create -o /mnt/tbssd/fixture-extra/watched.torrent -t http://tracker.invalid/announce /trrnt/watched.bin
    chmod 644 /mnt/tbssd/fixture-extra/watched.torrent
    mkdir -p $work/cfg
    cp ${fixtureSettings} $work/cfg/settings.json
    chmod 600 $work/cfg/settings.json
    transmission-daemon -f -g $work/cfg --log-level=error &
    dpid=$!
    for i in $(seq 60); do transmission-remote $r -l >/dev/null 2>&1 && break; sleep 1; done
    transmission-remote $r -a $work/fixture.torrent -w /trrnt
    for i in $(seq 60); do transmission-remote $r -l | grep -q ' 100% ' && break; sleep 1; done
    transmission-remote $r -l | grep -q ' 100% '
    transmission-remote $r --exit
    wait $dpid || true
    test -n "$(ls $work/cfg/resume)" -a -n "$(ls $work/cfg/torrents)"

    # ... flip one byte, keep size and mtime: only a re-verify would notice
    touch -r /trrnt/fixture.bin $work/mtime
    printf 'X' | dd of=/trrnt/fixture.bin bs=1 seek=100 conv=notrunc status=none
    touch -r $work/mtime /trrnt/fixture.bin

    # ... laid out as the Arch copy lands on the Data disk (numeric ids of Arch's transmission)
    dst=/mnt/tbssd/state/transmission/.config/transmission-daemon
    mkdir -p $dst
    cp -a $work/cfg/resume $work/cfg/torrents $dst/
    cp ${archSettings} $dst/settings.json
    chown -R 169:169 /mnt/tbssd/state/transmission /trrnt/fixture.bin /trrnt/watched.bin
    chown 169:169 /trrnt
    # yannik's own entries and the old openvpn leftovers, which the chown must leave alone
    install -d -o 1001 -g 1001 -m 755 /trrnt/watch /trrnt/transmit
    head -c 1024 /dev/urandom > /trrnt/transmit/big.bin
    echo mine > /trrnt/stray.txt
    chown -R 1001:1001 /trrnt/transmit /trrnt/stray.txt
    install -d -o 0 -g 0 -m 755 /trrnt/config
    echo secret > /trrnt/config/openvpn-credentials.txt
  '';

  # --- restoreMode: everything off, identity there, the Cutover commands ----------------------
  optiplex.vmTest.checks.transmission-restore-mode = {
    phase = "restore";
    script = ''
      optiplex.fail("systemctl cat transmission.service")
      optiplex.fail("systemctl cat nfs-server.service")
      optiplex.succeed("test \"$(id -u transmission):$(id -g transmission)\" = 70:70")
      optiplex.succeed("id -nG yannik | tr ' ' '\\n' | grep -qx transmission")
      assert optiplex.succeed("id -nG yannik").split() == ["yannik", "wheel", "kvm", "transmission"] or set(optiplex.succeed("id -nG yannik").split()) == {"yannik", "wheel", "kvm", "transmission"}
      optiplex.succeed("mountpoint /trrnt")
      assert optiplex.succeed("findmnt -n -o SOURCE /trrnt").strip().endswith("[/trrnt]"), "bind mount of the trrnt directory"
    '';
  };

  optiplex.vmTest.checks.transmission-restore-chown = {
    phase = "restore";
    script = ''
      def st(path):
          return optiplex.succeed(f"stat -c '%u:%g %a' {path}").strip()
      def owners(*paths):
          return {p: st(p).split()[0] for p in paths}
      cfgdir = "/mnt/tbssd/state/transmission/.config/transmission-daemon"
      mine = ["/trrnt/transmit", "/trrnt/stray.txt"]
      tr_owned = ["/trrnt", "/trrnt/fixture.bin", "/mnt/tbssd/state/transmission", cfgdir + "/settings.json"]
      optiplex.succeed(f"ls {cfgdir}/resume/*.resume {cfgdir}/torrents/*.torrent")
      resume = optiplex.succeed(f"ls {cfgdir}/resume/*.resume").split()[0]
      tr_owned.append(resume)

      def untouched():
          assert owners(*mine) == {p: "1001:1001" for p in mine}, owners(*mine)
          assert st("/trrnt/watch").startswith("1001:"), st("/trrnt/watch")
          assert st("/trrnt/transmit/big.bin").startswith("1001:1001")
          assert st("/trrnt/config") == "0:0 755" and st("/trrnt/config/openvpn-credentials.txt").startswith("0:0")

      restore = "bash ${./transmission/restore.sh}"
      # Arch ids before
      assert set(owners(*tr_owned).values()) == {"169:169"}, owners(*tr_owned)
      watch_before = st("/trrnt/watch")

      optiplex.succeed(f"{restore} forward")
      assert set(owners(*tr_owned).values()) == {"70:70"}, owners(*tr_owned)
      untouched()
      # group write everywhere on the transmission side, nothing opened to others
      for p in tr_owned:
          mode = int(st(p).split()[1], 8)
          assert mode & 0o020, (p, oct(mode))
      assert st("/trrnt/fixture.bin") == "70:70 664", st("/trrnt/fixture.bin")
      # watch/: yannik stays owner, group transmission, group-writable
      assert st("/trrnt/watch") == "1001:70 775", st("/trrnt/watch")
      # nothing was written outside
      optiplex.succeed("test \"$(stat -c %u /trrnt/watched.bin)\" = 70")

      # idempotent
      optiplex.succeed(f"{restore} forward")
      assert st("/trrnt/fixture.bin") == "70:70 664"

      # the rollback: Arch's ids, watch/ as it was
      optiplex.succeed(f"{restore} back")
      assert set(owners("/trrnt", "/trrnt/fixture.bin", "/trrnt/watched.bin").values()) == {"169:169"}
      assert st("/trrnt/watch") == watch_before, (st("/trrnt/watch"), watch_before)
      untouched()
      optiplex.succeed(f"{restore} forward")
      assert set(owners(*tr_owned).values()) == {"70:70"}
      assert st("/trrnt/watch") == "1001:70 775"
      untouched()
    '';
  };

  optiplex.vmTest.checks.transmission-restore-diff-settings = {
    phase = "restore";
    script = ''
      out = optiplex.succeed("PATH=${pkgs.jq}/bin:$PATH PKG=${tr} GEN=${generatedSettings} bash ${./transmission/diff-settings.sh} /mnt/tbssd/state/transmission/.config/transmission-daemon/settings.json")
      print(out)
      import json
      keys = {json.loads(l)["key"]: json.loads(l) for l in out.splitlines() if l.strip()}
      # reported: the setting the config does not carry, and the deliberate changes
      assert "idle_seeding_limit" in keys, keys
      assert "rpc_whitelist_enabled" in keys, keys
      # not reported: carried over unchanged, matches the defaults, or the password hash
      for k in ("peer_limit_global", "dht_enabled", "encryption", "download_dir", "upload_slots_per_torrent", "rpc_password", "umask"):
          assert k not in keys, (k, keys)
      assert "{not-a-real-hash" not in out
    '';
  };

  # --- normal configuration ----------------------------------------------------------------------
  optiplex.vmTest.checks.transmission-1-daemon = {
    script = ''
      import json
      def rpc(method, **args):
          return json.loads(optiplex.succeed("${rpcSh} '" + json.dumps({"method": method, "arguments": args}) + "'"))["arguments"]

      optiplex.wait_for_unit("transmission.service")
      optiplex.wait_until_succeeds("curl -s -o /dev/null http://127.0.0.1:25559/transmission/rpc")
      # settings of the config are what the daemon runs with
      s = {k.replace("-", "_"): v for k, v in rpc("session-get").items()}
      want = {"peer_port": 51413, "dht_enabled": False, "pex_enabled": False, "lpd_enabled": False,
              "utp_enabled": True, "port_forwarding_enabled": False, "peer_limit_global": 2000,
              "peer_limit_per_torrent": 500, "download_queue_enabled": True, "download_queue_size": 5,
              "queue_stalled_enabled": True, "queue_stalled_minutes": 30, "speed_limit_down_enabled": False,
              "speed_limit_up_enabled": False, "download_dir": "/trrnt", "incomplete_dir_enabled": False}
      for k, v in want.items():
          assert s[k] == v, (k, s[k], v)
      assert s["encryption"] in (1, "preferred"), s["encryption"]
      # settings.json was generated from the config, and the module made no /var/lib/transmission
      optiplex.succeed("test \"$(stat -c %U:%G /state/transmission/.config/transmission-daemon/settings.json)\" = transmission:transmission")
      optiplex.fail("test -e /var/lib/transmission")
      optiplex.succeed("test \"$(stat -c %a /state/transmission/.config/transmission-daemon)\" = 700")

      # the restored torrent: 100 %, seeding (idle: nobody to upload to), not verified again
      lst = optiplex.succeed("transmission-remote 127.0.0.1:25559 -l")
      print(lst)
      line = [l for l in lst.splitlines() if "fixture.bin" in l][0]
      assert " 100% " in line, line
      assert not any(w in line for w in ("Verifying", "Queued", "Downloading", "Stopped")), line
      # the daemon runs as uid 70 and a flipped byte under the old mtime stayed unnoticed
      assert optiplex.succeed("ps -o user= -C transmission-daemon").split()[0] == "transmission"
      info = optiplex.succeed("transmission-remote 127.0.0.1:25559 -t 1 -i")
      assert "Percent Done: 100" in info and "Error:" not in info, info
      assert "/trrnt" in info
    '';
  };

  optiplex.vmTest.checks.transmission-2-peer-download = {
    script = ''
      trbin = "${tr}/bin"
      # lan: a seeder with a tiny tracker (its announce answer is the seeder itself)
      lan.succeed("systemctl stop firewall")
      lan.succeed("mkdir -p /srv/seed /srv/seed-cfg && head -c 2097152 /dev/urandom > /srv/seed/dl.bin")
      lan.succeed(f"{trbin}/transmission-create -o /srv/seed/dl.torrent -t http://192.168.178.50:8000/announce /srv/seed/dl.bin")
      lan.succeed("cp ${seederSettings} /srv/seed-cfg/settings.json")
      lan.succeed("systemd-run --unit=tracker -p WorkingDirectory=/srv/seed ${pkgs.python3}/bin/python3 ${trackerPy}")
      lan.succeed(f"systemd-run --unit=seeder {trbin}/transmission-daemon -f -g /srv/seed-cfg --log-level=error")
      lan.wait_until_succeeds(f"{trbin}/transmission-remote 127.0.0.1:9091 -l")
      lan.succeed(f"{trbin}/transmission-remote 127.0.0.1:9091 -a /srv/seed/dl.torrent -w /srv/seed")
      lan.wait_until_succeeds(f"{trbin}/transmission-remote 127.0.0.1:9091 -l | grep -q ' 100% '")
      lan.wait_for_open_port(8000)

      # the peer port of the Optiplex is open for the LAN
      lan.succeed("${pkgs.python3}/bin/python3 -c 'import socket; socket.create_connection((\"192.168.178.20\", 51413), 3)'")
      lan.succeed("${pkgs.python3}/bin/python3 -c 'import socket; socket.create_connection((\"fd65:c1a5:7d2b::20\", 51413), 3)'")

      # the Optiplex downloads it (outgoing peer connection into the LAN)
      optiplex.succeed("curl -fsS -o /tmp/dl.torrent http://192.168.178.50:8000/dl.torrent")
      optiplex.succeed("transmission-remote 127.0.0.1:25559 -a /tmp/dl.torrent")
      optiplex.wait_until_succeeds("transmission-remote 127.0.0.1:25559 -l | grep dl.bin | grep -q ' 100% '", timeout=120)
      optiplex.succeed("cmp /trrnt/dl.bin <(cat /srv/seed/dl.bin 2>/dev/null) || true")
      # a file transmission creates is 70:70 and group-writable (umask 002)
      out = optiplex.succeed("stat -c '%U:%G %a' /trrnt/dl.bin").strip()
      assert out == "transmission:transmission 664", out
      assert optiplex.succeed("stat -c %s /trrnt/dl.bin").strip() == "2097152"
      # yannik can delete it through his group (the directory is 775 and in group transmission)
      optiplex.succeed("sudo -u yannik -g transmission test -w /trrnt")
      optiplex.succeed("sudo -u yannik -g transmission test -w /trrnt/dl.bin")
      # hand the seeder back
      lan.succeed("systemctl stop seeder tracker")
    '';
  };

  optiplex.vmTest.checks.transmission-3-watch-dir = {
    script = ''
      # yannik drops a .torrent into his watch/ (group transmission, g+w after the Cutover chown)
      optiplex.succeed("install -o yannik -g yannik -m 644 /mnt/tbssd/fixture-extra/watched.torrent /trrnt/watch/watched.torrent")
      optiplex.wait_until_succeeds("transmission-remote 127.0.0.1:25559 -l | grep watched.bin | grep -q ' 100% '", timeout=60)
      # added, and renamed by the daemon (it can write to watch/, which stays yannik's)
      optiplex.wait_until_succeeds("test -e /trrnt/watch/watched.torrent.added")
      optiplex.fail("test -e /trrnt/watch/watched.torrent")
      assert optiplex.succeed("stat -c %U /trrnt/watch").strip() == "yannik"
    '';
  };

  optiplex.vmTest.checks.transmission-4-caddy = {
    script = ''
      url = "http://transmission.opti.plex"
      v4 = "--resolve transmission.opti.plex:80:192.168.178.20"
      v6 = "--resolve transmission.opti.plex:80:[fd65:c1a5:7d2b::20]"
      for resolve in (v4, v6):
          for path in ("/transmission/rpc", "/rpc"):
              h = lan.succeed(f"curl -s -i --max-time 10 {resolve} {url}{path}")
              assert h.startswith("HTTP/1.1 409"), (resolve, path, h)
              assert "x-transmission-session-id:" in h.lower(), h
      # a full call through the proxy: session id handshake, then a real answer
      sid = lan.succeed(f"curl -s -D - -o /dev/null {v4} {url}/rpc | tr -d '\\r' | sed -n 's/^[Xx]-[Tt]ransmission-[Ss]ession-[Ii]d: //p'").strip()
      body = lan.succeed(f"curl -s {v4} -H 'X-Transmission-Session-Id: {sid}' -d '{{\"method\":\"session-get\"}}' {url}/rpc")
      assert '"result":"success"' in body.replace(" ", ""), body
      # the dashboard iframe: no X-Frame-Options from the vhost
      assert "x-frame-options" not in lan.succeed(f"curl -s -i {v4} {url}/transmission/rpc").lower()
      # another Host never reaches transmission (Caddy's catch-all aborts) ...
      rc, _ = lan.execute("curl -s --max-time 10 -H 'Host: evil.example' http://192.168.178.20/transmission/rpc")
      assert rc == 52, rc
      # ... and transmission itself refuses an unknown Host (direct, on loopback)
      direct = optiplex.succeed("curl -s -i -H 'Host: evil.example' http://127.0.0.1:25559/transmission/rpc")
      assert direct.startswith("HTTP/1.1 421"), direct
      assert "unrecognized" in direct.lower(), direct
      # RPC is loopback only: not reachable from the LAN or from outside
      lan.fail("curl -s --max-time 4 http://192.168.178.20:25559/transmission/rpc")
      outside.fail("curl -s --max-time 4 http://203.0.113.1:25559/transmission/rpc")
      assert "127.0.0.1:25559" in optiplex.succeed("ss -Hltn 'sport = :25559'")
      optiplex.fail("ss -Hltn 'sport = :25559' | grep -v 127.0.0.1")
      # the peer port is public on both families (the harness firewall matrix only sees the
      # restoreMode config, where transmission is off)
      for a in ("203.0.113.1", "2001:db8:2::1"):
          assert outside.execute(f"${probe} tcp {a} 51413")[0] == 0, a
      # outside the explicit LAN ranges: Caddy aborts the connection (v4 and v6)
      for addr in ("203.0.113.1", "[2001:db8:2::1]"):
          rc, _ = outside.execute(f"curl -s --max-time 10 --resolve transmission.opti.plex:80:{addr} {url}/transmission/rpc")
          assert rc == 52, (addr, rc)
    '';
  };

  optiplex.vmTest.checks.transmission-5-rehearsal = {
    tiers = ["rehearsal"];
    script = ''
      optiplex.wait_for_unit("transmission.service")
      optiplex.wait_until_succeeds("transmission-remote 127.0.0.1:25559 -l")
      out = optiplex.succeed("transmission-remote 127.0.0.1:25559 -l")
      print(out)
      # real State: torrents resume without a re-verify (nothing verifying minutes after the start)
      assert "Verifying" not in out, out
      assert optiplex.succeed("stat -c %U /state/transmission/.config/transmission-daemon").strip() == "transmission"
    '';
  };

  # --- NFS -----------------------------------------------------------------------------------------
  optiplex.vmTest.checks.nfs-export = {
    script = ''
      optiplex.wait_for_unit("nfs-server.service")
      exp = optiplex.succeed("exportfs -v")
      print(exp)
      assert "/mnt/tbssd/trrnt" in exp and "192.168.178.0/24" in exp, exp
      assert ",ro," in exp, exp
      assert "all_squash" in exp and "insecure" in exp and "no_subtree_check" in exp, exp
      # only that one export
      assert len([l for l in optiplex.succeed("exportfs -v").splitlines() if l.startswith("/")]) == 1

      # the client: Shield-like, unprivileged source port, no local rpcbind/statd (nolock)
      lan.succeed("modprobe nfs; modprobe nfsv4")
      lan.succeed("test -e /etc/netconfig || ln -s ${pkgs.libtirpc}/etc/netconfig /etc/netconfig")
      mount = "${pkgs.nfs-utils}/bin/mount.nfs"
      for vers in ("3", "4"):
          mp = f"/mnt/nfs{vers}"
          lan.succeed(f"mkdir -p {mp}")
          lan.succeed(f"{mount} 192.168.178.20:/mnt/tbssd/trrnt {mp} -o vers={vers},noresvport,nolock")
          # reads work (the payload is world-readable, the export squashes everyone to nobody)
          assert lan.succeed(f"wc -c < {mp}/fixture.bin").strip() == "1048576"
          assert "fixture.bin" in lan.succeed(f"ls {mp}")
          # Nothing is writable: not new files, not existing ones, not deletions. A Linux client
          # reports EACCES (the server's ACCESS reply already withholds the write bits of a ro
          # export) and only a raw WRITE would get EROFS.
          for cmd in (f"touch {mp}/new", f"echo x >> {mp}/fixture.bin", f"rm {mp}/stray.txt", f"mkdir {mp}/d"):
              rc, out = lan.execute(f"sh -c '{cmd}' 2>&1")
              assert rc != 0 and ("Read-only file system" in out or "Permission denied" in out), (vers, cmd, rc, out)
          # from an unprivileged source port
          ports = optiplex.succeed("ss -Htn state established '( sport = :2049 )' | awk '{print $4}'")
          print(ports)
          peers = [l.rsplit(":", 1) for l in ports.split() if l.startswith("192.168.178.50")]
          assert peers and all(int(p) >= 1024 for _, p in peers), peers
          lan.succeed(f"umount {mp}")
      # LAN-only: open for the LAN on both families, closed for the internet
      for port in (111, 2049, 4001, 4002, 4003):
          for a in ("192.168.178.20", "fd65:c1a5:7d2b::20"):
              assert lan.execute(f"${probe} tcp {a} {port}")[0] == 0, (a, port)
          for a in ("203.0.113.1", "2001:db8:2::1"):
              assert outside.execute(f"${probe} tcp {a} {port}")[0] != 0, ("outside", a, port)
      # nobody wrote to the Data disk through NFS
      optiplex.fail("test -e /trrnt/new")
    '';
  };

  # The firewall matrix of tests/optiplex/vm.nix binds every opened port itself (today it reads the
  # restoreMode config, where none of these ports is open, so it skips them). NFS holds some of
  # them in the kernel (2049, lockd 4001) or through systemd (rpcbind's socket on 111), which the
  # matrix cannot hand over. So the NFS side is shut down after its checks (checks run in name
  # order, in front of the matrix); the matrix then tests the LAN-only rules on free ports.
  optiplex.vmTest.checks.nfs-zz-release-ports = {
    script = ''
      optiplex.succeed("systemctl stop nfs-server.service nfs-mountd.service nfs-idmapd.service rpc-statd.service rpcbind.service rpcbind.socket")
      print(optiplex.succeed("ss -Hltunp"))
      for p in (111, 2049, 4001, 4002, 4003):
          optiplex.fail(f"ss -Hltun 'sport = :{p}' | grep -q .")
    '';
  };

  optiplex.vmTest.checks.nfs-rehearsal = {
    tiers = ["rehearsal"];
    script = ''
      optiplex.wait_for_unit("nfs-server.service")
      assert "/mnt/tbssd/trrnt" in optiplex.succeed("exportfs -v")
    '';
  };
}
