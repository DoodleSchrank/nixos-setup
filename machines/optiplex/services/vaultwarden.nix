# Vaultwarden (pw.nnik.dev): native services.vaultwarden on SQLite, State in /state/vaultwarden.
#
#   * The vault (db.sqlite3 + attachments/ + sends/) lives in /state/vaultwarden (Data disk, Backup).
#   * rsa_key.pem comes from sops (secrets/optiplex/vaultwarden.yaml, key `rsa_key`) and stays under
#     /run/secrets, which is read-only for the service. A missing key therefore stops Vaultwarden
#     from starting; it can never silently generate a fresh one (that would log everyone out).
#   * Public vhost pw.nnik.dev through Caddy (the wildcard cert comes from the base, see caddy.nix).
#   * Sign-ups are closed (decision of the review round). There is no admin page (no ADMIN_TOKEN) and
#     no SMTP, so new accounts only come through an organisation invitation.
#
# Restore of State from the Docker volume (steps for the Cutover runbook):
#   1. On Arch:   docker stop vaultwarden    (db.sqlite3 and its -wal are then one consistent pair)
#   2. On Arch/Optiplex, as root, with the Data disk mounted (the volume itself stays untouched):
#        install -d /mnt/tbssd/state/vaultwarden
#        rsync -a --exclude icon_cache/ --exclude tmp/ --exclude 'rsa_key*.pem' \
#          /mnt/tbssd/docker/volumes/vaultwarden_data/_data/ /mnt/tbssd/state/vaultwarden/
#   3. Before the wipe: the key in sops must equal the live one
#        sudo sha256sum /mnt/tbssd/docker/volumes/vaultwarden_data/_data/rsa_key.pem
#        sops -d --extract '["rsa_key"]' secrets/optiplex/vaultwarden.yaml | sha256sum
#   4. Ownership: nothing to do. The unit's root-run ExecStartPre chowns /state/vaultwarden to
#      vaultwarden on every start (so also after the first normal deploy and after reinstalls).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  vwSecrets = cfg.secretsDir + "/vaultwarden.yaml";
  haveSecret = builtins.pathExists vwSecrets;

  port = 25566; # the live port, kept
  stateDir = "/state/vaultwarden";
  keyPath = "/run/secrets/vaultwarden/rsa_key"; # Vaultwarden appends ".pem" itself
  vwPkg = config.services.vaultwarden.package;
  caCert = pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem"; # pebble's WFE certificate CA
in {
  config = {
    # --- user: pinned ids (State on the Data disk outlives the System disk's uid map) ----------------
    # Defined regardless of restoreMode, so the sops secret and the restored State can be owned by it.
    users.groups.vaultwarden.gid = 960;
    users.users.vaultwarden = {
      uid = 960;
      group = "vaultwarden";
      isSystemUser = true;
    };

    services.vaultwarden = {
      enable = !cfg.restoreMode;
      dbBackend = "sqlite";
      domain = "pw.nnik.dev"; # sets DOMAIN = https://pw.nnik.dev; configureNginx stays off
      # backupDir stays null: SQLite consistency for the Backup is the Backup ticket's job.
      config = {
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = port;
        # Overrides the module's /var/lib/vaultwarden, independent of its stateVersion switch.
        DATA_FOLDER = stateDir;
        RSA_KEY_FILENAME = keyPath;
        SIGNUPS_ALLOWED = false;
        # ENABLE_WEBSOCKET, IP_HEADER (X-Real-IP) and IP_HEADER_TRUSTED_PROXIES (local) stay default.
      };
    };

    assertions = [
      {
        # The live Docker instance runs 1.37.1; Vaultwarden's DB migrations only go forward.
        assertion = lib.versionAtLeast vwPkg.version "1.37.1";
        message = "vaultwarden ${vwPkg.version} is older than the live instance (1.37.1): its migrations cannot be undone, do not downgrade.";
      }
    ];

    systemd.services.vaultwarden = lib.mkIf config.services.vaultwarden.enable {
      serviceConfig = {
        # The module's StateDirectory would create an empty /var/lib/vaultwarden on the System disk.
        StateDirectory = lib.mkForce "";
        ReadWritePaths = [stateDir]; # ProtectSystem = strict
        # Root-run (`+`): create the directory and fix ownership of everything in it. A restored copy
        # is owned by root (Docker volume), and the uid map of a fresh install differs.
        ExecStartPre = "+${pkgs.writeShellScript "vaultwarden-state-owner" ''
          install -d -m 0700 -o vaultwarden -g vaultwarden ${stateDir}
          chown -R vaultwarden:vaultwarden ${stateDir}
        ''}";
      };
    };
    # RequiresMountsFor=/state (no start without the Data disk)
    optiplex.stateUnits = ["vaultwarden"];

    # --- the carried RSA key ----------------------------------------------------------------------
    # The secret's name is its path under /run/secrets (a `path` option inside /run/secrets would
    # collide with sops-nix's own /run/secrets symlink), hence the ".pem" in the name.
    sops.secrets."vaultwarden/rsa_key.pem" = lib.mkIf haveSecret {
      sopsFile = vwSecrets;
      key = "rsa_key";
      owner = "vaultwarden";
      mode = "0400";
      restartUnits = lib.optional (!cfg.restoreMode) "vaultwarden.service";
    };
    warnings = lib.optional (!haveSecret) ''
      secrets/optiplex/vaultwarden.yaml does not exist (looked in ${toString cfg.secretsDir}): Vaultwarden has no RSA key and will refuse to start.
      Create it from the live key (never in clear on disk), see the Answer of ticket 35:
        ssh <arch> 'sudo cat /mnt/tbssd/docker/volumes/vaultwarden_data/_data/rsa_key.pem' | python3 -c 'import sys,json; print(json.dumps({"rsa_key": sys.stdin.read()}))' | (cd secrets && sops --encrypt --input-type json --output-type yaml --filename-override optiplex/vaultwarden.yaml /dev/stdin > optiplex/vaultwarden.yaml)
      and `git add` it.
    '';

    # --- the public vhost -------------------------------------------------------------------------
    # useACMEHost = "nnik.dev" is set by the base helper for every *.nnik.dev vhost.
    # No body limit (the old nginx 525M is gone), websockets need nothing extra.
    services.caddy.virtualHosts."pw.nnik.dev".extraConfig = ''
      import security
      reverse_proxy 127.0.0.1:${toString port} {
          header_up X-Real-IP {remote_host}
      }
    '';

    # --- VM test: fixture and checks (see machines/optiplex/vm-test.nix) -----------------------------
    # The fixture is what a restored copy of the Docker volume looks like: root-owned, a database with
    # one user, attachments and sends, and no rsa_key.pem (that comes from sops). The database is
    # created by the packaged Vaultwarden itself (a throwaway key outside /state), then one user is
    # inserted. Limitation: it has the current schema, so the forward migration from 1.37.1 is not
    # exercised.
    optiplex.vmTest.fixtures.vaultwarden.script = ''
      install -d -m 0755 ${stateDir} ${stateDir}/attachments/seed ${stateDir}/sends
      echo attachment-fixture > ${stateDir}/attachments/seed/blob
      echo send-fixture > ${stateDir}/sends/blob
      WEB_VAULT_ENABLED=false DATA_FOLDER=${stateDir} RSA_KEY_FILENAME=/tmp/vw-fixture-key \
        ROCKET_ADDRESS=127.0.0.1 ROCKET_PORT=25999 \
        ${lib.getExe vwPkg} > /tmp/vw-fixture.log 2>&1 &
      pid=$!
      for _ in $(seq 60); do
        ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:25999/alive >/dev/null 2>&1 && break
        sleep 1
      done
      ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:25999/alive >/dev/null
      kill $pid
      wait $pid || true
      ${pkgs.sqlite}/bin/sqlite3 ${stateDir}/db.sqlite3 "
        INSERT INTO users (uuid, created_at, updated_at, email, name, password_hash, salt,
                           password_iterations, akey, security_stamp, equivalent_domains, excluded_globals)
        VALUES ('00000000-0000-0000-0000-000000000001', '2024-01-01 00:00:00', '2024-01-01 00:00:00',
                'fixture@example.com', 'Fixture User', x'00', x'00', 600000, 'none', 'stamp', '[]', '[]');"
      test "$(${pkgs.sqlite}/bin/sqlite3 ${stateDir}/db.sqlite3 'select count(*) from users')" = 1
      rm -f /tmp/vw-fixture-key.pem
      test ! -e ${stateDir}/rsa_key.pem
    '';

    optiplex.vmTest.checks.vaultwarden-restore = {
      phase = "restore";
      script = ''
        # restoreMode: Vaultwarden is off, but its user, the key and the restored State are there
        optiplex.fail("systemctl cat vaultwarden.service")
        optiplex.succeed("test \"$(id -u vaultwarden):$(id -g vaultwarden)\" = 960:960")
        print(optiplex.succeed("ls -lR /run/secrets /run/secrets.d 2>&1; id vaultwarden"))
        owner_mode = optiplex.succeed("stat -L -c '%U %a' /run/secrets/vaultwarden/rsa_key.pem").strip()
        assert owner_mode == "vaultwarden 400", owner_mode
        optiplex.succeed("grep -q 'BEGIN' /run/secrets/vaultwarden/rsa_key.pem")
        optiplex.succeed("test -e /mnt/tbssd/state/vaultwarden/db.sqlite3")
      '';
    };

    optiplex.vmTest.checks.vaultwarden = {
      script = ''
        vw_db = "${stateDir}/db.sqlite3"
        users = lambda: optiplex.succeed(f"${pkgs.sqlite}/bin/sqlite3 {vw_db} 'select count(*) from users'").strip()
        mails = lambda: optiplex.succeed(f"${pkgs.sqlite}/bin/sqlite3 {vw_db} 'select email from users'").strip()

        # service up, State required, nothing on the System disk
        optiplex.wait_for_unit("vaultwarden.service")
        optiplex.wait_until_succeeds("curl -fsS http://127.0.0.1:${toString port}/alive")
        optiplex.succeed("systemctl show -p RequiresMountsFor vaultwarden.service | grep -q '/state'")
        optiplex.fail("test -e /var/lib/vaultwarden")
        envfile = optiplex.succeed("systemctl show -p EnvironmentFiles vaultwarden.service").split("=", 1)[1].split()[0]
        envtxt = optiplex.succeed(f"cat {envfile}")
        for want in ("DATA_FOLDER=${stateDir}", "ROCKET_ADDRESS=127.0.0.1", "ROCKET_PORT=${toString port}",
                     "DOMAIN=https://pw.nnik.dev", "SIGNUPS_ALLOWED=false", "RSA_KEY_FILENAME=${keyPath}"):
            assert want in envtxt.splitlines(), (want, envtxt)

        # the fixture database was used and kept
        assert users() == "1", users()
        assert mails() == "fixture@example.com", mails()

        # ownership, and no key generated in State
        optiplex.succeed("test -z \"$(find ${stateDir} \\( ! -user vaultwarden -o ! -group vaultwarden \\))\"")
        optiplex.succeed("test \"$(stat -c %a ${stateDir})\" = 700")
        optiplex.succeed("test -e ${stateDir}/attachments/seed/blob -a -e ${stateDir}/sends/blob")
        optiplex.fail("test -e ${stateDir}/rsa_key.pem")
        optiplex.fail("journalctl -u vaultwarden.service --no-pager | grep -i 'Private key.*created'")

        # through Caddy, from the LAN client (192.168.178.50). The cert comes from pebble, whose root is random per
        # start: the client fetches it from pebble's management port (trusting only the WFE test CA).
        # The public/LAN split of the firewall is the base's test; here only the proxying matters.
        curl = "curl -sS --cacert /tmp/pebble-root.pem --resolve pw.nnik.dev:443:192.168.178.20 https://pw.nnik.dev"
        lan.wait_until_succeeds("curl -sS --cacert ${caCert} --resolve acme.test:15000:192.168.178.60 https://acme.test:15000/roots/0 -o /tmp/pebble-root.pem", timeout=60)
        lan.wait_until_succeeds(f"{curl}/alive -o /dev/null", timeout=120)
        head = lan.succeed(f"{curl}/alive -D - -o /dev/null").lower()
        assert head.startswith("http/2 200") or head.startswith("http/1.1 200"), head
        assert "strict-transport-security: max-age=31536000" in head, head

        # failed login: the log carries the client's address (X-Real-IP), not 127.0.0.1
        lan.succeed(
            f"{curl}/identity/connect/token -X POST -o /dev/null "
            "-d 'grant_type=password&username=nobody@example.com&password=x&scope=api offline_access"
            "&client_id=web&deviceType=10&deviceIdentifier=11111111-2222-3333-4444-555555555555&deviceName=test'"
        )
        optiplex.wait_until_succeeds("journalctl -u vaultwarden.service --no-pager | grep -q 'IP: 192.168.178.50. Username: nobody@example.com'")
        optiplex.fail("journalctl -u vaultwarden.service --no-pager | grep 'Username or password is incorrect' | grep -q 'IP: 127.0.0.1'")

        # websocket upgrade: Vaultwarden answers (401 Invalid claim without a token), not Caddy (502/404)
        ws = lan.succeed(
            f"{curl}/notifications/hub --http1.1 -i -H 'Connection: Upgrade' -H 'Upgrade: websocket' "
            "-H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='"
        )
        assert " 401 " in ws.splitlines()[0] and "Invalid claim" in ws, ws
        optiplex.succeed("journalctl -u vaultwarden.service --no-pager | grep -q 'Accepting Rocket WS connection'")

        # signups are closed, and the state survived all of this
        assert users() == "1", users()
        optiplex.succeed("systemctl is-active vaultwarden.service")
      '';
    };
  };
}
