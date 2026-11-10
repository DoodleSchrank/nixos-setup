# Paperless-ngx (http://paperless.opti.plex, LAN only): native services.paperless, State in
# /state/paperless, the `paperless` database on the shared PostgreSQL (peer auth over the socket).
#
#   * State       /state/paperless (Data disk): media/ (documents/{originals,archive,thumbnails}),
#                 consume/ (empty), index/ and classification_model.pickle (both regenerable),
#                 celerybeat-schedule.db. Redis is the module's own redis-paperless (cache only, not carried).
#   * Database    the role/database `paperless` is declared in databases.nix / postgresql.nix (so it exists in
#                 restoreMode); database.createLocally adds the same two entries a second time, which is
#                 harmless (checked: the setup oneshot is idempotent) and keeps PAPERLESS_DB*, the ordering on
#                 postgresql.target and PrivateNetwork in the module's hands.
#   * Secret      PAPERLESS_SECRET_KEY comes from sops (secrets/optiplex/paperless.yaml, key `secret_key`) via
#                 a sops template, so it never reaches the Nix store (only the placeholder does). A missing
#                 template makes the units fail instead of silently letting the module generate a key.
#   * Version     the live container is pinned to 3.2.1 (migrations only go forward). nixpkgs-unstable carries
#                 3.3.4 when this was written. An assertion keeps `nix flake update` from ever going below.
#   * OCR         deu+eng (decision of the review round; the live default was eng). Only newly consumed
#                 documents are affected. tesseractLanguages follows the setting.
#   * Time zone   the module sets PAPERLESS_TIME_ZONE from time.timeZone (Europe/Berlin); live was UTC.
#                 Stored timestamps are UTC either way.
#   * Vhost       plain http://paperless.opti.plex behind lan_only. PAPERLESS_URL is set by hand because the
#                 module's `domain` would force https://. X-Frame-Options is removed from the response: the
#                 opti.plex dashboard shows Paperless in an iframe (Facts from Arch in the ticket).
#   * No tmpfiles rules: the module's `d` rules on /state/paperless break systemd-tmpfiles-setup while the
#     Data disk is missing (/state is then an immutable empty directory). A root-run ExecStartPre of
#     paperless-secret-key (which every Paperless unit requires) creates the directories and fixes ownership
#     (so the restore needs no chown), and the units require /state through stateUnits.
#
# Restore of State from the Docker volumes (steps for the Cutover runbook; everything is ~150 MB, no pre-sync):
#   1. On Arch:  stop the Paperless stack (docker compose stop in Portainer), dump paperless-db-1 with
#      machines/optiplex/cutover/arch-db-dumps.sh (ticket 29). Note the document count before the stop.
#   2. As root with the Data disk mounted (on Arch, or on the Optiplex after the restoreMode install);
#      the Docker volumes stay untouched:
#        install -d /mnt/tbssd/state/paperless/media /mnt/tbssd/state/paperless/consume
#        rsync -aHAX --exclude log/ /mnt/tbssd/docker/volumes/paperless_data/_data/ /mnt/tbssd/state/paperless/
#        rsync -aHAX /mnt/tbssd/docker/volumes/paperless_media/_data/ /mnt/tbssd/state/paperless/media/
#        chown -R 315:315 /mnt/tbssd/state/paperless      # optional: the unit does the same on every start
#      media/ must then hold documents/{originals,archive,thumbnails}. There is no export dir to carry.
#   3. The DB restore runs in restoreMode (optiplex-db-restore, ticket 29).
#   4. The first normal deploy: paperless-scheduler's preStart runs `migrate` (3.2.1 -> the nixpkgs version) and
#      `document_index reindex --if-needed` (src-version is missing, the index is rebuilt from the DB).
#   5. Verify: `paperless-manage document_sanity_checker` (no errors), the document count equals the one from
#      step 1, open a document and see its thumbnail, log in again (the new key logs everyone out).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  ppSecrets = cfg.secretsDir + "/paperless.yaml";
  haveSecret = builtins.pathExists ppSecrets;

  host = "paperless.opti.plex";
  port = 25575; # the live port, kept
  stateDir = "/state/paperless";
  minVersion = "3.2.1"; # the live version at the Cutover (pinned in Portainer)
  ppCfg = config.services.paperless;
  ppPkg = ppCfg.package;
  envFile =
    if haveSecret
    then config.sops.templates."paperless.env".path
    else "/run/secrets/rendered/paperless.env"; # missing: the units' EnvironmentFile fails, loudly

  # --- VM test pieces -----------------------------------------------------------------------------
  # A restored copy as the Cutover leaves it: a PostgreSQL dump (made in a scratch database by the packaged
  # Paperless itself, so it has the current schema; the forward migration from 3.2.1 is not exercised),
  # one document with its original and thumbnail under media/, one superuser. The dump is restored by the
  # restore-phase check through optiplex-db-restore, the way the runbook does it.
  fixtureDumps = "/mnt/tbssd/cutover-dumps/paperless-fixture";
  fixtureEnv = {
    PAPERLESS_DATA_DIR = stateDir;
    PAPERLESS_MEDIA_ROOT = "${stateDir}/media";
    PAPERLESS_CONSUMPTION_DIR = "${stateDir}/consume";
    PAPERLESS_DBENGINE = "postgresql";
    PAPERLESS_DBHOST = "/run/postgresql";
    PAPERLESS_DBNAME = "paperless_fixture";
    PAPERLESS_DBUSER = "paperless";
    PAPERLESS_SECRET_KEY = "fixture-secret-key-not-the-real-one";
    PAPERLESS_REDIS = "unix:///tmp/paperless-fixture-redis.sock"; # post_migrate talks to Redis
  };
  fixtureOriginal = "Rechnung 4711 fixture original\n";
  fixtureOrm = pkgs.writeText "paperless-fixture.py" ''
    import datetime, hashlib
    from django.contrib.auth.models import User
    from documents.models import Document

    User.objects.create_superuser("testadmin", "testadmin@example.com", "testpassword-paperless")
    checksum = hashlib.sha256(${builtins.toJSON fixtureOriginal}.encode()).hexdigest()
    Document.objects.bulk_create([
        Document(
            title="Fixture Rechnung",
            content="Rechnung 4711 fixture original",
            mime_type="text/plain",
            checksum=checksum,
            created=datetime.date(2024, 1, 2),
            filename="0000001.txt",
            original_filename="rechnung.txt",
        )
    ])
    print("fixture documents:", Document.objects.count())
  '';
  # What an image with text looks like to tesseract: German and English words, large and black on white.
  ocrImage =
    pkgs.runCommand "paperless-ocr-test.png" {nativeBuildInputs = [pkgs.imagemagick];} ''
      magick -size 1400x300 xc:white -font ${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf \
        -pointsize 64 -fill black -annotate +40+110 "Rechnung Hamburg" -annotate +40+230 "Invoice Zebra 2026" $out
    '';
  caps = ["Rechnung" "Hamburg" "Invoice" "Zebra"];
in {
  config = {
    # --- user: pinned ids (State on the Data disk outlives the System disk's uid map) ----------------
    # The module defines the same user and group (315, from nixpkgs' ids.nix) only when enabled. Declared
    # here regardless of restoreMode, so the sops template and the restored State can be owned by it.
    users.groups.paperless.gid = 315;
    users.users.paperless = {
      uid = 315;
      group = "paperless";
      isSystemUser = true;
      home = stateDir;
      createHome = lib.mkForce false; # /state is immutable without the Data disk: the root pre-start creates it
    };

    services.paperless = {
      enable = !cfg.restoreMode;
      dataDir = stateDir;
      consumptionDirIsPublic = false;
      address = "127.0.0.1";
      inherit port;
      database.createLocally = true;
      configureTika = false;
      settings = {
        PAPERLESS_URL = "http://${host}";
        PAPERLESS_OCR_LANGUAGE = "deu+eng";
      };
      environmentFile = envFile;
    };

    assertions = [
      {
        # The live container runs 3.2.1; Paperless migrations only go forward.
        assertion = lib.versionAtLeast ppPkg.version minVersion;
        message = "paperless-ngx ${ppPkg.version} is older than the live instance (${minVersion}): its migrations cannot be undone, do not downgrade (check before each deploy after `nix flake update`).";
      }
      {
        assertion = config.ids.uids.paperless == 315 && config.ids.gids.paperless == 315;
        message = "nixpkgs changed the paperless uid/gid; /state/paperless is owned by 315:315";
      }
    ];

    # Without the module's tmpfiles rules (see the header); the root pre-start of paperless-secret-key does it.
    systemd.tmpfiles.settings."10-paperless" = lib.mkForce {};
    systemd.services.paperless-secret-key = lib.mkIf ppCfg.enable {
      serviceConfig.ExecStartPre = [
        "+${pkgs.writeShellScript "paperless-state-owner" ''
          install -d -m 0750 -o paperless -g paperless ${stateDir}
          install -d -o paperless -g paperless ${stateDir}/index ${stateDir}/media ${stateDir}/consume
          chown -R paperless:paperless ${stateDir}
        ''}"
      ];
    };
    # RequiresMountsFor=/state (no start without the Data disk); the module's own ones list the sub-paths.
    optiplex.stateUnits = ["paperless-secret-key" "paperless-scheduler" "paperless-task-queue" "paperless-consumer" "paperless-web"];

    # --- the secret ---------------------------------------------------------------------------------
    sops.secrets."paperless/secret_key" = lib.mkIf haveSecret {
      sopsFile = ppSecrets;
      key = "secret_key";
      restartUnits = lib.optionals (!cfg.restoreMode) ["paperless-secret-key.service" "paperless-scheduler.service" "paperless-task-queue.service" "paperless-consumer.service" "paperless-web.service"];
    };
    # Owned by paperless: the paperless-manage wrapper sources this file as that user.
    sops.templates."paperless.env" = lib.mkIf haveSecret {
      content = "PAPERLESS_SECRET_KEY=${config.sops.placeholder."paperless/secret_key"}\n";
      owner = "paperless";
      mode = "0400";
    };
    warnings = lib.optional (!haveSecret) ''
      secrets/optiplex/paperless.yaml does not exist (looked in ${toString cfg.secretsDir}): Paperless has no secret key and its units will fail to start.
      Create it with a fresh value (never in clear on disk), see the Answer of ticket 36:
        python3 -I -c 'import json,secrets,string; a=string.ascii_letters+string.digits; print(json.dumps({"secret_key": "".join(secrets.choice(a) for _ in range(64))}))' | (cd secrets && sops --encrypt --input-type json --output-type yaml --filename-override optiplex/paperless.yaml /dev/stdin > optiplex/paperless.yaml)
      and `git add` it.
    '';

    # --- Caddy: LAN only, plain http -------------------------------------------------------------------
    # The blocky mapping for opti.plex already answers this name. Websocket (/ws/status) needs nothing extra.
    # Django sends X-Frame-Options: SAMEORIGIN; the dashboard on http://opti.plex frames this site.
    services.caddy.virtualHosts."http://${host}".extraConfig = ''
      import lan_only
      reverse_proxy 127.0.0.1:${toString port} {
          header_down -X-Frame-Options
      }
    '';

    # --- VM test: fixture and checks (see machines/optiplex/vm-test.nix) --------------------------------
    optiplex.vmTest.fixtures.paperless.script = ''
      pgq() { runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres "$@"; }
      for _ in $(seq 60); do pgq -tAc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
      pgq -tAc 'select 1' >/dev/null

      # scratch database -> schema + data by the packaged Paperless -> custom-format dump -> dropped
      install -d -m 0755 ${stateDir} ${stateDir}/media/documents/originals ${stateDir}/media/documents/thumbnails ${stateDir}/consume
      chown -R paperless:paperless ${stateDir}
      pgq -c 'DROP DATABASE IF EXISTS paperless_fixture' -c 'CREATE DATABASE paperless_fixture OWNER paperless'
      runuser -u paperless -- ${pkgs.redis}/bin/redis-server --port 0 --unixsocket /tmp/paperless-fixture-redis.sock \
        --save "" --appendonly no --daemonize yes --dir /tmp > /dev/null
      runuser -u paperless -- env ${lib.escapeShellArgs (lib.mapAttrsToList (k: v: "${k}=${v}") fixtureEnv)} \
        sh -c 'cd ${stateDir} && ${lib.getExe ppPkg} migrate --no-input && ${lib.getExe ppPkg} shell < ${fixtureOrm}' > /tmp/paperless-fixture.log 2>&1 \
        || { cat /tmp/paperless-fixture.log; exit 1; }
      grep -q 'fixture documents: 1' /tmp/paperless-fixture.log
      ${pkgs.redis}/bin/redis-cli -s /tmp/paperless-fixture-redis.sock shutdown nosave || true
      install -d -m 0755 ${fixtureDumps}/postgresql
      runuser -u postgres -- pg_dump -Fc -d paperless_fixture > ${fixtureDumps}/postgresql/paperless.dump
      pgq -c 'DROP DATABASE paperless_fixture'

      # the media as the Docker volume copy leaves it: root-owned, no consume dir, no index
      printf %s ${lib.escapeShellArg fixtureOriginal} > ${stateDir}/media/documents/originals/0000001.txt
      echo fixture-thumbnail > ${stateDir}/media/documents/thumbnails/0000001.webp
      rm -rf ${stateDir}/index ${stateDir}/src-version ${stateDir}/consume
      chown -R 0:0 ${stateDir}
    '';

    optiplex.vmTest.checks.paperless-restore = {
      phase = "restore";
      script = ''
        # restoreMode: no Paperless unit at all, but the user, the secret and the copied State are there
        optiplex.fail("systemctl cat paperless-web.service")
        optiplex.fail("systemctl cat paperless-scheduler.service")
        optiplex.fail("systemctl cat paperless-secret-key.service")
        optiplex.fail("systemctl cat redis-paperless.service")
        optiplex.succeed("test \"$(id -u paperless):$(id -g paperless)\" = 315:315")
        owner_mode = optiplex.succeed("stat -L -c '%U %a' ${envFile}").strip()
        assert owner_mode == "paperless 400", owner_mode
        optiplex.succeed("grep -q '^PAPERLESS_SECRET_KEY=test' ${envFile}")
        optiplex.succeed("test -e /mnt/tbssd/state/paperless/media/documents/originals/0000001.txt")

        # the database exists, is owned by paperless, answers over the socket as that role, and is empty
        psql = "runuser -u paperless -- psql -X -d paperless -tAc"
        assert optiplex.succeed(f"{psql} 'select current_user'").strip() == "paperless"
        assert optiplex.succeed(f"{psql} \"select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public'\"").strip() == "0"

        # the restore, the way the runbook does it
        out = optiplex.succeed("optiplex-db-restore ${fixtureDumps} --only paperless --no-manifest 2>&1")
        print(out)
        assert optiplex.succeed(f"{psql} 'select count(*) from documents_document'").strip() == "1"
        assert optiplex.succeed(f"{psql} 'select username from auth_user where is_superuser'").strip() == "testadmin"
        optiplex.fail("systemctl is-active paperless-web.service")
      '';
    };

    optiplex.vmTest.checks.paperless = {
      script = ''
        units = ["paperless-web", "paperless-scheduler", "paperless-task-queue", "paperless-consumer"]
        for u in units + ["paperless-secret-key", "redis-paperless"]:
            optiplex.wait_for_unit(f"{u}.service")
        optiplex.succeed("systemctl is-active " + " ".join(f"{u}.service" for u in units))
        optiplex.wait_until_succeeds("curl -fsS -o /dev/null http://127.0.0.1:${toString port}/", timeout=300)

        # --- the units as built: State required, secret from the sops template, nothing on the System disk
        for u in units + ["paperless-secret-key"]:
            optiplex.succeed(f"systemctl show -p RequiresMountsFor {u}.service | grep -q '/state'")
            ef = optiplex.succeed(f"systemctl show -p EnvironmentFiles {u}.service")
            assert "${envFile}" in ef, (u, ef)
        optiplex.fail("test -e /var/lib/paperless")
        env = optiplex.succeed("systemctl show -p Environment paperless-web.service")
        for want in ("PAPERLESS_DBHOST=/run/postgresql", "PAPERLESS_DBNAME=paperless", "PAPERLESS_DBUSER=paperless",
                     "PAPERLESS_URL=http://${host}", "PAPERLESS_OCR_LANGUAGE=deu+eng", "PAPERLESS_DATA_DIR=${stateDir}",
                     "GRANIAN_HOST=127.0.0.1", "GRANIAN_PORT=${toString port}"):
            assert want in env, (want, env)
        for u in ("paperless-scheduler", "paperless-consumer"):
            assert optiplex.succeed(f"systemctl show -p PrivateNetwork {u}.service").strip() == "PrivateNetwork=yes", u
        optiplex.fail("ss -H -ltn 'sport = :${toString port}' | grep -v 127.0.0.1")

        # --- the secret: the live process has the sops value; the module's generated file is empty
        key = optiplex.succeed("cat /run/secrets/paperless/secret_key").strip()
        assert key.startswith("test") and len(key) > 16, key
        # (/proc/<pid>/environ of a Python service is overwritten by setproctitle, so the process cannot be
        # asked.) By construction: v3 refuses to start without PAPERLESS_SECRET_KEY, the module's generated
        # file stays empty (next line), so the key in the live units can only come from the template.
        optiplex.succeed(f"grep -qx 'PAPERLESS_SECRET_KEY={key}' ${envFile}")
        optiplex.succeed("test -e ${stateDir}/nixos-paperless-secret-key.env && test ! -s ${stateDir}/nixos-paperless-secret-key.env")
        optiplex.succeed(f"! grep -rlF '{key}' /etc /nix/store/*paperless* /nix/store/*sops* 2>/dev/null | grep -q .")
        assert optiplex.succeed("stat -L -c '%U %a' ${envFile}").strip() == "paperless 400"

        # --- State: everything owned by paperless (the fixture made it root-owned), dirs exist, index built
        optiplex.succeed("test -z \"$(find ${stateDir} \\( ! -user paperless -o ! -group paperless \\))\"")
        optiplex.succeed("test -d ${stateDir}/consume -a -d ${stateDir}/index")
        optiplex.succeed("test -s ${stateDir}/src-version && test \"$(cat ${stateDir}/src-version)\" = '${ppPkg.version}'")
        optiplex.succeed("test -e /mnt/tbssd/state/paperless/media/documents/originals/0000001.txt")

        # --- restored data is intact
        manage = "paperless-manage"
        out = optiplex.succeed(f"{manage} document_sanity_checker 2>&1")
        print(out)
        assert "error" not in out.lower().replace("0 error", ""), out
        count = optiplex.succeed(f"{manage} shell -c 'from documents.models import Document; print(Document.objects.count())' 2>/dev/null").strip().splitlines()[-1]
        assert count == "1", count

        # --- through Caddy from the LAN client, and from outside
        base = "curl -sS --max-time 20 -H 'Host: ${host}' http://192.168.178.20"
        head = lan.wait_until_succeeds(f"{base}/ -D - -o /dev/null", timeout=120)
        status = head.splitlines()[0]
        assert " 302 " in status or " 200 " in status, head
        login = lan.succeed(f"{base}/accounts/login/")
        assert "Paperless" in login or "paperless" in login, login[:300]
        # websocket path reaches Paperless (not Caddy's 502/404): it answers 403/401/101, never Caddy's errors
        ws = lan.succeed(
            f"{base}/ws/status/ -i --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' "
            "-H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -m 5 || true"
        )
        assert ws.splitlines()[0].split()[1] in ("101", "401", "403"), ws
        # the dashboard iframe: Django sets X-Frame-Options, the vhost removes it
        direct = optiplex.succeed("curl -sS -i http://127.0.0.1:${toString port}/accounts/login/").lower()
        assert "x-frame-options" in direct, direct
        assert "x-frame-options" not in lan.succeed(f"{base}/accounts/login/ -i").lower()
        # non-private sources: the connection is aborted (v4 and v6); other Hosts never reach Paperless
        for addr in ("203.0.113.1", "[2001:db8:2::1]"):
            rc, _ = outside.execute(f"curl -s --max-time 10 --resolve ${host}:80:{addr} http://${host}/")
            assert rc == 52, (addr, rc)
        outside.fail("curl -sS -m 5 -o /dev/null http://192.168.178.20:${toString port}/")
        rc, _ = lan.execute("curl -s --max-time 10 -H 'Host: evil.example' http://192.168.178.20/")
        assert rc == 52, rc

        # --- upload through the API as the fixture superuser: consumed, OCR'd in German and English
        auth = "-u testadmin:testpassword-paperless"
        lan.succeed("cp ${ocrImage} /tmp/ocr.png")
        lan.succeed(f"{base}/api/documents/post_document/ {auth} -F document=@/tmp/ocr.png -F title=OCRTEST -o /tmp/post.out -w '%{{http_code}}' | grep -q 200")
        task = lan.succeed("cat /tmp/post.out").strip().strip('"')
        lan.wait_until_succeeds(
            f"{base}/api/documents/?title__icontains=OCRTEST {auth} | python3 -c \"import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['count']==1 else 1)\"",
            timeout=300,
        )
        doc = lan.succeed(f"{base}/api/documents/?title__icontains=OCRTEST {auth}")
        import json
        content = json.loads(doc)["results"][0]["content"]
        print("OCR content:", repr(content))
        for w in ${builtins.toJSON caps}:
            assert w.lower() in content.lower(), (w, content)
        optiplex.succeed("systemctl is-active " + " ".join(f"{u}.service" for u in units))
        count = optiplex.succeed(f"{manage} shell -c 'from documents.models import Document; print(Document.objects.count())' 2>/dev/null").strip().splitlines()[-1]
        assert count == "2", count
        out = optiplex.succeed(f"{manage} document_sanity_checker 2>&1")
        assert "error" not in out.lower().replace("0 error", ""), out
        # the media for the new document landed in State, owned by paperless
        optiplex.succeed("test -n \"$(find ${stateDir}/media/documents/originals -newer ${stateDir}/src-version -type f)\"")
        optiplex.succeed("test -z \"$(find ${stateDir} \\( ! -user paperless -o ! -group paperless \\))\"")
      '';
    };
  };
}
