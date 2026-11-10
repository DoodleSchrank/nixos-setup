# EteSync: the Etebase server (etesync.nnik.dev) and etesync-dav (dav.nnik.dev), both native from nixpkgs.
#
#   * Etebase server  services.etebase-server, SQLite, uvicorn on 0.0.0.0:25567 (the module has no
#                     option to bind elsewhere; only nftables keeps it off the LAN, nothing opens it).
#                     State in /state/etesync: db.sqlite3 and media/.
#   * etesync-dav     services.etesync-dav on localhost:37358, State in /state/etesync-dav:
#                     etesync_creds (a saved Etebase session with serverUrl http://localhost:25567,
#                     rewritten by the app) and etebase_data.db (a cache a re-sync rebuilds).
#                     Runs as the static user etesync-dav, no longer as root.
#   * Secrets         secrets/optiplex/etesync.yaml, placed by sops-nix under /run/secrets/etesync/:
#                       secret_key    = the content of secret.txt (Django SECRET_KEY), owner etebase-server
#                       dav_htpasswd  = the content of htpaswd ("<user>:<password>"), owner etesync-dav
#   * Public vhosts   etesync.nnik.dev (everything proxied, Etebase serves /static itself) and dav.nnik.dev.
#                     On dav.nnik.dev only /.web (the admin UI) is LAN-only (decision of the review round);
#                     the DAV paths are public (Thunderbird, DAVx5 and so on).
#
# Deviations from the ticket text (reasons in the Answer of ticket 38):
#   * dataDir stays at the module default /var/lib/etebase-server (it only holds `src-version` and the
#     regenerable `static/`), while database.name and media_root point into /state/etesync. The module
#     adds a tmpfiles `d` rule for dataDir, and a `d` on /state/<x> breaks systemd-tmpfiles-setup while
#     the Data disk is missing (/state is then an immutable empty directory).
#   * No tmpfiles rules at all on /state: a root-run ExecStartPre creates the directories, chowns them
#     (so a restored copy owned by root or by an old uid is fixed on every start) and links the htpasswd.
#
#   * nixpkgs-unstable's etesync-dav and etebase-server do not work together with its own peewee, Radicale,
#     FastAPI and Python 3.14 (details at `nixpkgs.overlays` below): this file carries a small overlay
#     (etesync-dav 0.36.0 + etesync-dav-compat.patch, etebase-py 0.32.0, a one-line router fix for
#     etebase-server). Those packages are not in the binary cache: build them on the PC
#     (`nixos-rebuild --build-host localhost`) rather than on the Optiplex.
#
# htpasswd is read-only: etesync-dav only reads it from $ETESYNC_DATA_DIR/htpaswd (that spelling; upstream
# has no setting to move it). The file is the sops secret, linked into /state/etesync-dav by the
# ExecStartPre below, so adding or removing a DAV user in the web UI (which writes the file) fails. A new
# DAV password means editing sops (`sops secrets/optiplex/etesync.yaml`) and deploying: fine with one user.
#
# Restore of State from Arch (steps for the Cutover runbook, downtime only; originals stay untouched):
#   1. On Arch:  systemctl stop etesync etesync-caldav
#      (the SQLite file is then consistent; from a Backup instead, take the `sqlite3 .backup` copy of
#      db.sqlite3 that the Backup job writes under /var/backup/sqlite/, not the live file)
#   2. As root, with the Data disk mounted (on Arch or on the Optiplex in restore mode):
#        install -d -m 0755 /mnt/tbssd/state/etesync /mnt/tbssd/state/etesync-dav
#        cp -a /srv/etesync/etebase/db.sqlite3 /mnt/tbssd/state/etesync/db.sqlite3
#        cp -a /srv/etesync/media /mnt/tbssd/state/etesync/
#        cp -a /root/.local/share/etesync-dav/etesync_creds /root/.local/share/etesync-dav/etebase_data.db \
#          /mnt/tbssd/state/etesync-dav/
#      Not copied: secret.txt and htpaswd (sops-nix provides both), static/ (collectstatic regenerates it).
#      If etebase_data.db turns out not to open with etesync-dav 0.36.0 (Arch runs 0.34.0), delete it: the service re-syncs.
#   3. Before the Cutover, the key and the DAV password go into sops (never in clear on disk), see the
#      warning below. They must equal the live ones:
#        ssh <arch> 'sudo tr -d "\n" < /srv/etesync/etebase/secret.txt | sha256sum'
#        sops -d --extract '["secret_key"]' secrets/optiplex/etesync.yaml | tr -d '\n' | sha256sum
#        ssh <arch> 'sudo cat /root/.local/share/etesync-dav/htpaswd' | sha256sum   (and the same for dav_htpasswd)
#   4. Ownership: nothing to do. Both units chown their /state directory on every start.
#   5. After the normal deploy the module's preStart runs `migrate` (Django 4.2 -> 5) and `collectstatic`.
#   Rollback needs no reverse migration: the original files are still on Arch's System disk.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  etesyncSecrets = cfg.secretsDir + "/etesync.yaml";
  haveSecret = builtins.pathExists etesyncSecrets;

  ebPort = 25567; # the live port, kept: the stored etesync-dav session has http://localhost:25567 in it
  davPort = 37358;
  ebState = "/state/etesync";
  davState = "/state/etesync-dav";
  secretKeyPath = "/run/secrets/etesync/secret_key";
  htpasswdPath = "/run/secrets/etesync/dav_htpasswd";
  ebPkg = config.services.etebase-server.package;
  davPkg = pkgs.etesync-dav;
  caCert = pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem"; # pebble's WFE certificate CA

  # --- VM test pieces ------------------------------------------------------------------------
  # What a restored copy looks like: root-owned, the packaged Etebase server created the schema, one
  # Django superuser, one media chunk. The schema is the current one; the live database is at
  # django_etebase 0037 (and the test asserts that this is also the newest migration here, so the
  # module's migrate in the deployed unit is a no-op on it, as it will be live).
  fixtureIni = pkgs.writeText "etesync-fixture.ini" ''
    [global]
    secret_file = /tmp/etesync-fixture-secret
    debug = false
    static_root = /tmp/etesync-fixture-static
    media_root = ${ebState}/media
    [allowed_hosts]
    allowed_host1 = localhost
    [database]
    engine = django.db.backends.sqlite3
    name = ${ebState}/db.sqlite3
  '';
  signup = pkgs.writeText "etesync-signup.py" ''
    import sys
    import etebase

    client = etebase.Client("vmtest", "http://localhost:${toString ebPort}")
    etebase.Account.signup(client, etebase.User("testuser", "testuser@example.com"), "testpassword-etebase")
    print("signed up")
  '';
  signupPython = pkgs.python3.withPackages (ps: [ps.etebase]);
in {
  config = {
    # --- nixpkgs fixes: etesync-dav against current peewee and Radicale -------------------------
    # nixpkgs-unstable (2026-11) ships etesync-dav 0.35.1 with peewee 4.4 and Radicale 3.9, and that
    # combination does not work (found by the VM test):
    #   * peewee 4 removed playhouse.sqlite_ext.SqliteExtDatabase (its features moved into
    #     peewee.SqliteDatabase, same arguments). etesync-dav's cache and the `etesync` library import
    #     the old name; the library's own tests fail at build.
    #   * Radicale 3.9 calls rights.authorization(user, user_groups, path); etesync-dav's Rights takes
    #     (user, path), so every DAV request ends in a 500 instead of a login prompt. And its PROPFIND
    #     turns every key of Collection.get_meta() into a property and fails on Etebase's own meta keys
    #     ("name", "mtime"). Its Storage.upload must return (item, replaced_item), the web UI hooks take
    #     the extra (user_groups, request_info) arguments and a 4-tuple answer, and an item needs a
    #     non-empty last_modified.
    #     etesync-dav-compat.patch (next to this file) fixes all of that, plus the peewee import.
    #   * etebase-py 0.31.8 segfaults on Python 3.14; 0.32.0 (what etesync-dav 0.36.0 asks for) is fine.
    #   * 0.35.1 has the idle high-CPU select() loop; 0.36.0 fixes that and the earlier Radicale API
    #     changes (its compat code replaces nixpkgs' radicale-3-6-compat.patch).
    # So: 0.36.0 (the open point of ticket 38) plus the two small patches above. Drop this overlay
    # once nixpkgs carries a working etesync-dav.
    nixpkgs.overlays = [
      (final: prev: {
        pythonPackagesExtensions =
          prev.pythonPackagesExtensions
          ++ [
            (_: pyPrev: {
              etesync = pyPrev.etesync.overridePythonAttrs (old: {
                postPatch =
                  (old.postPatch or "")
                  + ''
                    substituteInPlace etesync/api.py \
                      --replace-fail "from playhouse.sqlite_ext import SqliteExtDatabase" \
                                     "from peewee import SqliteDatabase as SqliteExtDatabase"
                  '';
              });
              # etebase-py 0.31.8 segfaults on Python 3.14 (the first Client() call); 0.32.0 fixes it.
              etebase = pyPrev.etebase.overridePythonAttrs (old: rec {
                version = "0.32.0";
                src = prev.fetchFromGitHub {
                  owner = "etesync";
                  repo = "etebase-py";
                  rev = "v${version}";
                  hash = "sha256-fC/9SFWTtKz9ZxCIPNchriPGyTzTT+iyMPYQ2fmWsjk=";
                };
                cargoDeps = prev.rustPlatform.fetchCargoVendor {
                  inherit src;
                  pname = old.pname;
                  inherit version;
                  hash = "sha256-zlfhTrAt3hZ5S3SJRZD1BgFAUDk0iXMLak78VPSoQks=";
                };
                # 0.32.0 builds with maturin instead of setuptools-rust
                build-system = []; # the maturin hook below builds the wheel
                nativeBuildInputs = [
                  prev.pkg-config
                  prev.rustPlatform.cargoSetupHook
                  prev.rustPlatform.maturinBuildHook
                  prev.cargo
                  prev.rustc
                ];
              });
            })
          ];
        # FastAPI >= 0.14x analyses the parameters of a route against the router's own path, not the
        # prefix given to include_router. etebase-server 0.14.2 puts {collection_uid} only in that
        # prefix, so every /collection/<uid>/item/ and /member/ request fails with 422 "missing query
        # collection_uid" (found by the VM test, with a real client). Moving the placeholder into the
        # routers' own prefix keeps the URLs identical.
        etebase-server = prev.etebase-server.overridePythonAttrs (old: {
          postPatch =
            (old.postPatch or "")
            + ''
              sed -i 's|^item_router = APIRouter(|item_router = APIRouter(prefix="/{collection_uid}", |' etebase_server/fastapi/routers/collection.py
              sed -i 's|^member_router = APIRouter(|member_router = APIRouter(prefix="/{collection_uid}", |' etebase_server/fastapi/routers/member.py
              sed -i 's|prefix=f"{BASE_PATH}/collection/{COLLECTION_UID_MARKER}"|prefix=f"{BASE_PATH}/collection"|' etebase_server/fastapi/main.py
              grep -q 'item_router = APIRouter(prefix=' etebase_server/fastapi/routers/collection.py
              grep -q 'member_router = APIRouter(prefix=' etebase_server/fastapi/routers/member.py
              test "$(grep -c 'prefix=f"{BASE_PATH}/collection"' etebase_server/fastapi/main.py)" = 3
            '';
        });
        etesync-dav = prev.etesync-dav.overridePythonAttrs (old: rec {
          version = "0.36.0";
          src = prev.fetchFromGitHub {
            owner = "etesync";
            repo = "etesync-dav";
            tag = "v${version}";
            hash = "sha256-2m1RrFWVm+5YyRTfYts/ZQuQUD/DNKjoCl5AQEBRSTg=";
          };
          # replaces nixpkgs' radicale-3-6-compat.patch (0.36.0 has that part); our patch: see the comment above
          patches = [./etesync-dav-compat.patch];
        });
      })
    ];

    # --- users: pinned ids (State on the Data disk outlives the System disk's uid map) ----------
    # Defined regardless of restoreMode, so the sops secrets and the restored State can be owned by them.
    users.groups.etebase-server.gid = 940;
    users.users.etebase-server = {
      uid = 940;
      group = "etebase-server";
      isSystemUser = true;
    };
    users.groups.etesync-dav.gid = 941;
    users.users.etesync-dav = {
      uid = 941;
      group = "etesync-dav";
      isSystemUser = true;
    };

    # --- the Etebase server -------------------------------------------------------------------
    services.etebase-server = {
      enable = !cfg.restoreMode;
      port = ebPort;
      openFirewall = false; # binds 0.0.0.0, kept off the LAN by nftables (VM test)
      settings = {
        global = {
          debug = false;
          secret_file = secretKeyPath;
          media_root = "${ebState}/media";
          # static_root stays under dataDir (/var/lib/etebase-server): regenerated, not State.
        };
        # Overrides the module's default 0.0.0.0. `localhost` is for etesync-dav (its stored session).
        allowed_hosts = {
          allowed_host1 = "localhost";
          allowed_host2 = "etesync.nnik.dev";
        };
        database.name = "${ebState}/db.sqlite3";
      };
    };

    systemd.services.etebase-server = lib.mkIf config.services.etebase-server.enable {
      serviceConfig.ExecStartPre = lib.mkBefore [
        # Root-run (`+`), before the module's migrate: directory, ownership of a restored copy.
        "+${pkgs.writeShellScript "etebase-state-owner" ''
          install -d -m 0750 -o etebase-server -g etebase-server ${ebState}
          chown -R etebase-server:etebase-server ${ebState}
        ''}"
      ];
    };

    # --- etesync-dav ---------------------------------------------------------------------------
    services.etesync-dav = {
      enable = !cfg.restoreMode;
      # host = "localhost" and port = 37358 stay default; nothing is opened in the firewall.
      # Only the default for an account added later in the web UI: it then points at this server.
      apiUrl = "http://localhost:${toString ebPort}";
    };

    systemd.services.etesync-dav = lib.mkIf config.services.etesync-dav.enable {
      after = ["etebase-server.service"];
      wants = ["etebase-server.service"];
      environment.ETESYNC_DATA_DIR = lib.mkForce davState;
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "etesync-dav";
        Group = "etesync-dav";
        StateDirectory = lib.mkForce ""; # no /var/lib/private/etesync-dav on the System disk
        # What DynamicUser used to give, kept explicitly:
        ProtectSystem = "strict";
        ReadWritePaths = [davState];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestartSec = lib.mkForce "10s"; # the module's 30min 1s leaves DAV down for half an hour
        ExecStartPre = [
          "+${pkgs.writeShellScript "etesync-dav-state" ''
            # Fails the start (instead of starting without a login) when sops has not placed the file.
            test -e ${htpasswdPath}
            install -d -m 0700 -o etesync-dav -g etesync-dav ${davState}
            # Whatever htpaswd came along with a restore is replaced by the read-only sops file.
            ln -sfn ${htpasswdPath} ${davState}/htpaswd
            chown -R etesync-dav:etesync-dav ${davState}
          ''}"
        ];
      };
    };

    # RequiresMountsFor=/state (no start without the Data disk)
    optiplex.stateUnits = ["etebase-server" "etesync-dav"];

    # --- the secrets ---------------------------------------------------------------------------
    # The secret's name is its path under /run/secrets (a `path` option inside /run/secrets would
    # collide with sops-nix's own /run/secrets symlink). A missing file stops the units from starting;
    # Etebase can never silently generate a fresh key there (the directory is not writable for it).
    sops.secrets = lib.mkIf haveSecret {
      "etesync/secret_key" = {
        sopsFile = etesyncSecrets;
        key = "secret_key";
        owner = "etebase-server";
        mode = "0400";
        restartUnits = lib.optional (!cfg.restoreMode) "etebase-server.service";
      };
      "etesync/dav_htpasswd" = {
        sopsFile = etesyncSecrets;
        key = "dav_htpasswd";
        owner = "etesync-dav";
        mode = "0400";
        restartUnits = lib.optional (!cfg.restoreMode) "etesync-dav.service";
      };
    };
    warnings = lib.optional (!haveSecret) ''
      secrets/optiplex/etesync.yaml does not exist (looked in ${toString cfg.secretsDir}): the Etebase server has no secret key and etesync-dav no htpasswd, so neither will start.
      Create it from the live files (never in clear on disk), see the header of machines/optiplex/services/etesync.nix:
        python3 -I -c 'import json,sys; print(json.dumps({"secret_key": open(sys.argv[1]).read().strip(), "dav_htpasswd": open(sys.argv[2]).read()}))' <(ssh <arch> 'sudo cat /srv/etesync/etebase/secret.txt') <(ssh <arch> 'sudo cat /root/.local/share/etesync-dav/htpaswd') | (cd secrets && sops --encrypt --input-type json --output-type yaml --filename-override optiplex/etesync.yaml /dev/stdin > optiplex/etesync.yaml)
      and `git add` it.
    '';

    # --- the public vhosts ---------------------------------------------------------------------
    # useACMEHost = "nnik.dev" is set by the base helper for every *.nnik.dev vhost.
    services.caddy.virtualHosts = {
      # Everything is proxied, /static included (Etebase's app mounts it). Host stays as it is:
      # Etebase checks it against allowed_hosts. 127.0.0.1 because uvicorn listens on IPv4 only.
      "etesync.nnik.dev".extraConfig = ''
        import security
        reverse_proxy 127.0.0.1:${toString ebPort}
      '';

      "dav.nnik.dev".extraConfig = ''
        import security
        # The admin UI (add/remove accounts) is LAN-only. Flask >= 3.1 accepts only `Host: localhost`
        # there (TRUSTED_HOSTS), so the Host is rewritten for this path. The same address is the target
        # of an SSH tunnel (`ssh -L 37358:localhost:37358 optiplex`, then http://localhost:37358/.web/).
        @web path /.web /.web/*
        handle @web {
          import lan_only
          reverse_proxy localhost:${toString davPort} {
              header_up Host localhost:${toString davPort}
          }
        }
        # The DAV paths are public, behind etesync-dav's own login. Default Host.
        handle {
          reverse_proxy localhost:${toString davPort}
        }
      '';
    };

    # --- VM test: fixture and checks (see machines/optiplex/vm-test.nix) -------------------------
    optiplex.vmTest.fixtures.etesync.script = ''
      install -d -m 0755 ${ebState}/media/user_1 ${davState}
      echo media-chunk-fixture > ${ebState}/media/user_1/chunk
      export ETEBASE_EASY_CONFIG_PATH=${fixtureIni}
      cd /
      ${ebPkg}/bin/etebase-server migrate --no-input > /tmp/etesync-fixture.log 2>&1
      ${ebPkg}/bin/etebase-server createsuperuser --no-input --username fixtureadmin --email fixture@example.com >> /tmp/etesync-fixture.log 2>&1
      rm -rf /tmp/etesync-fixture-secret /tmp/etesync-fixture-static
      test "$(${pkgs.sqlite}/bin/sqlite3 ${ebState}/db.sqlite3 'select count(*) from myauth_user')" = 1
      # etesync-dav: an empty session list, and an htpaswd that came along by mistake (must be replaced)
      echo '{"users": {}}' > ${davState}/etesync_creds
      echo 'stray:stray-password' > ${davState}/htpaswd
    '';

    optiplex.vmTest.checks.etesync-restore = {
      phase = "restore";
      script = ''
        # restoreMode: both off, but users, secrets and the restored State are there
        optiplex.fail("systemctl cat etebase-server.service")
        optiplex.fail("systemctl cat etesync-dav.service")
        optiplex.succeed("test \"$(id -u etebase-server):$(id -g etebase-server)\" = 940:940")
        optiplex.succeed("test \"$(id -u etesync-dav):$(id -g etesync-dav)\" = 941:941")
        assert optiplex.succeed("stat -L -c '%U %a' /run/secrets/etesync/secret_key").strip() == "etebase-server 400"
        assert optiplex.succeed("stat -L -c '%U %a' /run/secrets/etesync/dav_htpasswd").strip() == "etesync-dav 400"
        optiplex.succeed("test -e /mnt/tbssd/state/etesync/db.sqlite3 -a -e /mnt/tbssd/state/etesync-dav/etesync_creds")
        # Etebase is not running in restoreMode: nothing listens on its port
        optiplex.fail("ss -H -ltn 'sport = :${toString ebPort}' | grep -q .")
      '';
    };

    optiplex.vmTest.checks.etesync = {
      script = ''
        eb_db = "${ebState}/db.sqlite3"
        sql = lambda q: optiplex.succeed(f"${pkgs.sqlite}/bin/sqlite3 {eb_db} '{q}'").strip()

        # --- both units up, as non-root, State required, nothing on the System disk
        optiplex.wait_for_unit("etebase-server.service")
        optiplex.wait_for_unit("etesync-dav.service")
        optiplex.wait_until_succeeds("curl -fsS -H 'Host: localhost' http://127.0.0.1:${toString ebPort}/api/v1/authentication/is_etebase/")
        optiplex.wait_until_succeeds("curl -sS http://localhost:${toString davPort}/ -o /dev/null")
        for unit, user in (("etebase-server", "etebase-server"), ("etesync-dav", "etesync-dav")):
            props = dict(l.split("=", 1) for l in optiplex.succeed(f"systemctl show -p User -p MainPID -p DynamicUser -p RequiresMountsFor {unit}.service").splitlines())
            assert props["User"] == user, props
            assert props["DynamicUser"] == "no", props
            assert "/state" in props["RequiresMountsFor"], props
            owner = optiplex.succeed(f"ps -o user= -p {props['MainPID']}").strip()
            assert owner == user, (unit, owner)
        optiplex.fail("test -e /var/lib/private/etesync-dav -o -e /var/lib/etesync-dav")

        # --- the fixture State was used and kept; the root-owned copy was fixed by the unit
        assert sql("select username from myauth_user") == "fixtureadmin", sql("select username from myauth_user")
        optiplex.succeed("test -s ${ebState}/media/user_1/chunk")
        optiplex.succeed("test -z \"$(find ${ebState} \\( ! -user etebase-server -o ! -group etebase-server \\))\"")
        optiplex.succeed("test -z \"$(find ${davState} -not -type l \\( ! -user etesync-dav -o ! -group etesync-dav \\))\"")
        optiplex.succeed("test \"$(stat -c %a ${davState})\" = 700")
        # the stray htpaswd of the restore was replaced by the link to the (read-only) sops file
        assert optiplex.succeed("readlink ${davState}/htpaswd").strip() == "${htpasswdPath}"
        optiplex.succeed("grep -qx 'testuser:testpassword1234' ${davState}/htpaswd")
        optiplex.fail("runuser -u etesync-dav -- sh -c 'echo x >> ${davState}/htpaswd'")
        optiplex.succeed("runuser -u etesync-dav -- sh -c 'test -w ${davState}'")
        # the key from sops is the one Django uses (a missing file would have stopped the unit)
        optiplex.succeed("systemctl show -p ExecStartPre etebase-server.service | grep -q etebase-state-owner")
        optiplex.succeed("test -z \"$(ls -A ${ebState} | grep -x secret.txt)\"")
        # sandbox and restart policy of etesync-dav
        sc = dict(l.split("=", 1) for l in optiplex.succeed("systemctl show -p ProtectSystem -p ProtectHome -p PrivateTmp -p NoNewPrivileges -p ReadWritePaths -p RestartUSec -p StateDirectory etesync-dav.service").splitlines())
        assert sc["ProtectSystem"] == "strict" and sc["ProtectHome"] == "yes" and sc["PrivateTmp"] == "yes" and sc["NoNewPrivileges"] == "yes", sc
        assert sc["ReadWritePaths"] == "${davState}", sc
        assert sc["RestartUSec"] == "10s", sc
        assert sc["StateDirectory"] == "", sc
        optiplex.succeed("systemctl show -p After -p Wants etesync-dav.service | grep -c etebase-server.service | grep -qx 2")

        # --- Etebase: management check, migrations, Host handling (allowed_hosts) on the loopback port
        optiplex.succeed("runuser -u etebase-server -- etebase-server check")
        mig = optiplex.succeed("runuser -u etebase-server -- etebase-server showmigrations django_etebase")
        print(mig)
        assert "[ ] " not in mig and "[X] 0037_auto_20210127_1237" in mig, mig
        isetebase = "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:${toString ebPort}/api/v1/authentication/is_etebase/"
        for host, want in (("localhost", "200"), ("etesync.nnik.dev", "200"), ("evil.example", "400"), ("127.0.0.1", "400")):
            got = optiplex.succeed(f"{isetebase} -H 'Host: {host}'").strip()
            assert got == want, (host, got)

        # --- no firewall hole: Etebase listens on 0.0.0.0, DAV on loopback; the LAN reaches neither
        optiplex.succeed("ss -H -ltn 'sport = :${toString ebPort}' | grep -q '0.0.0.0:${toString ebPort}'")
        optiplex.succeed("curl -fsS -H 'Host: localhost' http://192.168.178.20:${toString ebPort}/api/v1/authentication/is_etebase/")  # local, via lo
        optiplex.fail("nft list ruleset | grep -E '${toString ebPort}|${toString davPort}'")
        for client in (lan, outside):
            for ip, port in (("192.168.178.20", ${toString ebPort}), ("203.0.113.1", ${toString ebPort}), ("192.168.178.20", ${toString davPort}), ("203.0.113.1", ${toString davPort})):
                client.fail(f"curl -sS -m 5 -H 'Host: localhost' http://{ip}:{port}/ -o /dev/null")

        # --- through Caddy. The cert comes from pebble, whose root is random per start: the client
        # fetches it from pebble's management port (trusting only the WFE test CA).
        def https(client, host, ip="192.168.178.20"):
            return f"curl -sS --cacert /tmp/pebble-root.pem --resolve {host}:443:{ip} https://{host}"
        # (pebble is on the LAN only: the internet client gets the same root from the LAN client)
        lan.wait_until_succeeds("curl -sS --cacert ${caCert} --resolve acme.test:15000:192.168.178.60 https://acme.test:15000/roots/0 -o /tmp/pebble-root.pem", timeout=60)
        outside.succeed("cat > /tmp/pebble-root.pem <<'PEM'\n" + lan.succeed("cat /tmp/pebble-root.pem") + "PEM")
        eb = https(lan, "etesync.nnik.dev")
        lan.wait_until_succeeds(f"{eb}/api/v1/authentication/is_etebase/ -o /dev/null", timeout=120)
        head = lan.succeed(f"{eb}/api/v1/authentication/is_etebase/ -D - -o /dev/null").lower()
        assert head.startswith("http/2 200") or head.startswith("http/1.1 200"), head
        assert "strict-transport-security: max-age=31536000" in head, head
        # a /static asset through the proxy (Etebase mounts it itself, no Caddy file_server)
        static = optiplex.succeed("find /var/lib/etebase-server/static -name base.css | head -n1").strip()
        assert static, "collectstatic did not run"
        rel = static.removeprefix("/var/lib/etebase-server/static/")
        code = lan.succeed(f"{eb}/static/{rel} -o /dev/null -w '%{{http_code}}'").strip()
        assert code == "200", code
        # the public side reaches Etebase too, with its own Host
        assert outside.succeed(f"{https(outside, 'etesync.nnik.dev', '203.0.113.1')}/api/v1/authentication/is_etebase/ -o /dev/null -w '%{{http_code}}'").strip() == "200"

        # --- DAV through Caddy: 401 without credentials, 207 with the htpasswd credentials.
        # An Etebase account is signed up on the running server and etesync-dav's own tool writes the
        # session (etesync_creds) for it, in a scratch directory; only that file is put in place, the
        # htpaswd stays the sops file (testuser:testpassword1234).
        dav = https(lan, "dav.nnik.dev")
        lan.wait_until_succeeds(f"{dav}/ -o /dev/null", timeout=60)
        # (GET / is Radicale's redirect to /.web/; the DAV paths ask for a login)
        assert lan.succeed(f"{dav}/ -o /dev/null -w '%{{http_code}}'").strip() == "302"
        assert lan.succeed(f"{dav}/testuser/ -X PROPFIND -H 'Depth: 1' -o /dev/null -w '%{{http_code}}'").strip() == "401"
        # (sign-up is blocked on a server; the admin creates the Django user first, the client then signs up)
        optiplex.succeed("runuser -u etebase-server -- etebase-server shell -c \"from django.contrib.auth import get_user_model; get_user_model().objects.create_user(username='testuser', email='testuser@example.com')\"")
        optiplex.succeed("${signupPython}/bin/python ${signup}")
        optiplex.succeed("install -d -m 0700 /tmp/dav-seed")
        optiplex.succeed("cd /tmp/dav-seed && ETESYNC_DATA_DIR=/tmp/dav-seed ETESYNC_URL=http://localhost:${toString ebPort} ${davPkg}/bin/etesync-dav manage add testuser --password testpassword-etebase")
        optiplex.succeed("install -m 0600 -o etesync-dav -g etesync-dav /tmp/dav-seed/etesync_creds ${davState}/etesync_creds && rm -rf /tmp/dav-seed")
        optiplex.succeed("systemctl restart etesync-dav.service")
        optiplex.wait_until_succeeds("curl -sS http://localhost:${toString davPort}/ -o /dev/null")
        lan.wait_until_succeeds(f"{dav}/ -o /dev/null", timeout=60)
        assert lan.succeed(f"{dav}/testuser/ -X PROPFIND -H 'Depth: 1' -o /dev/null -w '%{{http_code}}'").strip() == "401"
        assert lan.succeed(f"{dav}/testuser/ -X PROPFIND -H 'Depth: 1' -u testuser:wrong -o /dev/null -w '%{{http_code}}'").strip() == "401"
        body = lan.succeed(f"{dav}/testuser/ -X PROPFIND -H 'Depth: 1' -u testuser:testpassword1234 -w '\\n%{{http_code}}'")
        print(body)
        assert body.strip().splitlines()[-1] == "207", body
        # an address book from the listing: create, read and delete a contact (the write path to Etebase)
        import re
        sections = re.split(r"<(?:\w+:)?response>", body)[1:]
        books = [h for sec in sections if "addressbook" in sec for h in re.findall(r"href>(/testuser/[^/<]+/)<", sec)]
        assert books, body
        card = f"{dav}{books[0]}test-contact.vcf"
        vcf = "BEGIN:VCARD\\r\\nVERSION:3.0\\r\\nUID:test-contact\\r\\nFN:Test Contact\\r\\nN:Contact;Test;;;\\r\\nEND:VCARD\\r\\n"
        auth = "-u testuser:testpassword1234"
        put = lan.succeed(f"{card} -X PUT {auth} -H 'Content-Type: text/vcard' --data-binary $'{vcf}' -o /dev/null -w '%{{http_code}}'").strip()
        assert put in ("201", "204"), put
        assert "FN:Test Contact" in lan.succeed(f"{card} {auth}")
        assert lan.succeed(f"{card} -X DELETE {auth} -o /dev/null -w '%{{http_code}}'").strip() in ("200", "204")
        assert lan.succeed(f"{card} {auth} -o /dev/null -w '%{{http_code}}'").strip() == "404"
        # the same from the internet (DAV paths are public)
        out_dav = https(outside, "dav.nnik.dev", "203.0.113.1")
        assert outside.succeed(f"{out_dav}/testuser/ -X PROPFIND -H 'Depth: 1' -o /dev/null -w '%{{http_code}}'").strip() == "401"
        assert outside.succeed(f"{out_dav}/testuser/ -X PROPFIND -H 'Depth: 1' -u testuser:testpassword1234 -o /dev/null -w '%{{http_code}}'").strip() == "207"
        # the session file was written by the unit's user and is still its own after the restart
        optiplex.succeed("test \"$(stat -c %U ${davState}/etesync_creds)\" = etesync-dav")

        # --- /.web (admin UI): LAN only. The LAN gets the page (Flask accepts the rewritten Host), the
        # internet gets its connection dropped.
        web = lan.succeed(f"{dav}/.web/ -D - -o /dev/null -w '%{{http_code}}'")
        print(web)
        assert web.strip().splitlines()[-1] in ("200", "302"), web
        assert "Add User" in lan.succeed(f"{dav}/.web/add/") or "Add" in lan.succeed(f"{dav}/.web/add/")
        outside.fail(f"{out_dav}/.web/ -o /dev/null")
        outside.fail(f"{out_dav}/.web/add/ -o /dev/null")
        outside.fail(f"{out_dav}/.web -o /dev/null")

        # --- idle CPU of etesync-dav (0.35.1 has a reported select() loop, fixed in 0.36.0)
        t0 = int(optiplex.succeed("systemctl show -p CPUUsageNSec --value etesync-dav.service").strip())
        optiplex.succeed("sleep 10")
        t1 = int(optiplex.succeed("systemctl show -p CPUUsageNSec --value etesync-dav.service").strip())
        print(f"etesync-dav idle CPU over 10 s: {(t1 - t0) / 1e9:.2f} s")

        # --- the State survived all of this; both units are still fine
        assert sql("select count(*) from myauth_user where length(username) = 8") == "1"  # testuser
        optiplex.succeed("systemctl is-active etebase-server.service etesync-dav.service")
        optiplex.fail("journalctl -u etebase-server.service -u etesync-dav.service --no-pager | grep -i 'Traceback'")
      '';
    };
  };
}
