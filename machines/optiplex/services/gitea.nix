# Gitea (git.nnik.dev): native services.gitea 28.x on the shared PostgreSQL, State in /state/gitea.
#
#   * Version     nixpkgs' gitea (28.3.0 on the locked input). The live instance runs 1.26.4 (schema 331) and
#                 migrations only go forward, so an assertion refuses anything older than 28.3.0.
#   * User        gitea, uid/gid 950 pinned (State on the Data disk outlives the System disk's uid map).
#                 The user and group exist in restoreMode too, so the restored files can be chowned.
#   * State       everything in /state/gitea: repositories/, custom/conf, data/{packages,attachments,avatars,
#                 repo-avatars,actions_log,home,lfs,...}. The Docker volume is copied, never moved.
#   * Database    the shared PostgreSQL cluster, socket /run/postgresql, peer auth, no password. The role and the
#                 database `gitea` belong to services/postgresql.nix (createDatabase = false here), so they exist
#                 in restoreMode while Gitea is off. Gitea never starts against an empty schema: it is off in
#                 restoreMode, and its start refuses when the `repository` table is missing (see below).
#   * SSH         the built-in SSH server on 25580 (LAN only, opened through optiplex.firewall.lanOnly), user
#                 `git`, advertised as ssh://git@git.nnik.dev:25580. Host sshd (25560) is not touched. The
#                 router does not forward 25580. The container's three host keys are carried through sops.
#   * Secrets     secrets/optiplex/gitea.yaml, placed by sops-nix under /run/secrets/gitea/ (owner gitea, 0400):
#                   secret_key         fresh (the live one was empty, i.e. the public default)
#                   internal_token, lfs_jwt_secret, oauth2_jwt_secret    carried (OAuth2 apps stay valid)
#                   jwt_private_pem    carried, [oauth2] JWT_SIGNING_PRIVATE_KEY_FILE
#                   ssh_host_{ed25519,rsa,ecdsa}_key    carried, [server] SSH_SERVER_HOST_KEYS
#                 The first four are linked into custom/conf/ before the module's preStart, which then finds them
#                 and neither generates nor overwrites anything. (The *_URI variants are not used.)
#   * Caddy       public git.nnik.dev, `import security`, no body limit; websockets (/-/ws) need nothing extra.
#   * Runners     ticket "Gitea runner VMs" registers against https://git.nnik.dev (host 443 through blocky
#                 split-horizon). Seam: [actions] ENABLED = true is set below; a registration token comes from
#                 `optiplex-gitea actions generate-runner-token --scope <owner>` (instance: no --scope).
#
# Deviations from the module (reasons in the Answer of ticket 32):
#   * The module adds tmpfiles `d` rules for stateDir, and a `d` on /state breaks systemd-tmpfiles-setup while the
#     Data disk is missing (/state is then an immutable empty directory). The rules for /state/gitea are dropped
#     by an `apply` on systemd.tmpfiles.rules (further down); a root-run ExecStartPre creates the directories
#     instead, on every start.
#   * TimeoutStartSec is 15m (module: 3m): the first start runs `gitea migrate` over a 1.26.4 schema.
#
# Restore of State from the Docker volume: optiplex-gitea-restore (services/gitea/optiplex-gitea-restore.sh),
# after optiplex-db-restore, before the normal deploy. Its --help is the procedure.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  gc = config.services.gitea;
  giteaSecrets = cfg.secretsDir + "/gitea.yaml";
  haveSecrets = builtins.pathExists giteaSecrets;

  stateDir = "/state/gitea";
  httpPort = 25579; # the live port, kept
  sshPort = 25580;
  minVersion = "28.3.0";
  secretDir = "/run/secrets/gitea";
  exe = lib.getExe gc.package;
  caCert = pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem"; # pebble's WFE certificate CA

  # --- the secrets ---------------------------------------------------------------------------------
  confSecrets = ["secret_key" "internal_token" "lfs_jwt_secret" "oauth2_jwt_secret"]; # linked into custom/conf
  hostKeys = ["ed25519" "rsa" "ecdsa"];
  hostKeyPath = t: "${secretDir}/ssh_host_${t}_key";
  jwtKeyPath = "${secretDir}/jwt_private_pem";
  secretNames = confSecrets ++ ["jwt_private_pem"] ++ map (t: "ssh_host_${t}_key") hostKeys;

  # --- tooling for the Cutover ---------------------------------------------------------------------
  restoreTool = pkgs.writeShellApplication {
    name = "optiplex-gitea-restore";
    runtimeInputs = with pkgs; [coreutils findutils rsync util-linux systemd];
    text = ''
      STATE_DIR=${lib.escapeShellArg stateDir}
      DATA_DIR=${lib.escapeShellArg "${stateDir}/data"}
      GITEA_USER=gitea
    '' + builtins.readFile ./gitea/optiplex-gitea-restore.sh;
  };

  # The gitea CLI as the gitea user with the service's environment, for the runbook and the runner ticket:
  # `optiplex-gitea doctor check`, `optiplex-gitea actions generate-runner-token`, `optiplex-gitea admin ...`.
  cliTool = pkgs.writeShellScriptBin "optiplex-gitea" ''
    exec ${pkgs.util-linux}/bin/runuser -u gitea -- ${pkgs.coreutils}/bin/env \
      PATH=${lib.makeBinPath [pkgs.git pkgs.gnupg pkgs.coreutils]} \
      HOME=${stateDir} GITEA_WORK_DIR=${stateDir} GITEA_CUSTOM=${gc.customDir} \
      ${exe} --config ${gc.customDir}/conf/app.ini "$@"
  '';

  # --- VM test pieces ------------------------------------------------------------------------------
  fixtureDir = "/var/tmp/gitea-fixture";
  volumeDir = "/mnt/tbssd/docker/volumes/gitea_data/_data"; # where the Cutover copies the volume
  dumpDir = "/mnt/tbssd/cutover-dumps/fixture";
  fixturePort = 25598;
  fixturePass = "fixture-pass-1234";
  testPath = lib.makeBinPath (with pkgs; [git curl coreutils gnused gnugrep findutils openssh util-linux systemd gawk]);
in {
  # (an `apply` added to the existing option declaration; it sees the merged list) see "tmpfiles" below
  options.systemd.tmpfiles.rules = lib.mkOption {
    apply = lib.filter (r: !(lib.hasInfix stateDir r));
  };

  config = {
    # --- user: pinned ids ----------------------------------------------------------------------------
    # Defined regardless of restoreMode (like vaultwarden), so the sops secrets and the restored State can
    # be owned by gitea in the restore phase. No home directory is created (it is on /state).
    users.groups.gitea.gid = 950;
    users.users.gitea = {
      uid = 950;
      group = "gitea";
      isSystemUser = true;
      home = stateDir;
      createHome = lib.mkForce false;
    };

    # --- the service -------------------------------------------------------------------------------
    services.gitea = {
      enable = !cfg.restoreMode;
      user = "gitea";
      group = "gitea";
      inherit stateDir;
      # customDir (/state/gitea/custom), repositoryRoot (/state/gitea/repositories) and lfs.contentDir
      # (/state/gitea/data/lfs) keep their defaults.
      appName = "Private Repo";
      lfs.enable = true; # the live config has an LFS path and secret (0 objects)
      dump.enable = false; # Backup is dump and file based (ticket 30)

      database = {
        type = "postgres";
        socket = "/run/postgresql";
        name = "gitea";
        user = "gitea";
        createDatabase = false; # services/postgresql.nix owns the role and the database
      };

      settings = {
        server = {
          ROOT_URL = "https://git.nnik.dev/"; # (the module forbids DOMAIN; 28.x no longer reads it)
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = httpPort;
          SSH_DOMAIN = "git.nnik.dev";
          START_SSH_SERVER = true;
          BUILTIN_SSH_SERVER_USER = "git";
          SSH_PORT = sshPort;
          SSH_LISTEN_PORT = sshPort;
          SSH_SERVER_HOST_KEYS = lib.concatMapStringsSep "," hostKeyPath hostKeys;
        };
        # Translated from the live app.ini (ticket 32, assets/app.ini.masked). Paths and secrets are the
        # module's; DOMAIN, sessions/indexers paths and LOG_SQL/SCHEMA defaults are not carried.
        service = {
          DISABLE_REGISTRATION = true;
          REQUIRE_SIGNIN_VIEW = false;
          REGISTER_EMAIL_CONFIRM = false;
          ENABLE_NOTIFY_MAIL = false;
          ALLOW_ONLY_EXTERNAL_REGISTRATION = false;
          ENABLE_CAPTCHA = false;
          DEFAULT_KEEP_EMAIL_PRIVATE = false;
          DEFAULT_ALLOW_CREATE_ORGANIZATION = true;
          DEFAULT_ENABLE_TIMETRACKING = true;
          NO_REPLY_ADDRESS = "noreply.localhost"; # existing commit mappings use it
        };
        openid = {
          ENABLE_OPENID_SIGNIN = true;
          ENABLE_OPENID_SIGNUP = true;
        };
        mailer.ENABLED = false;
        session = {
          PROVIDER = "file"; # PROVIDER_CONFIG defaults to data/sessions
          COOKIE_SECURE = true; # the site is https only
        };
        log.MODE = "console"; # journal
        "repository.pull-request".DEFAULT_MERGE_STYLE = "merge";
        "repository.signing".DEFAULT_TRUST_MODEL = "committer";
        # Only the battle-tracker deploy receiver on this host is a webhook target.
        webhook.ALLOWED_HOST_LIST = "loopback";
        # Not set live (so the default 400 days applied); the Nix config keeps runs forever. app.ini is
        # generated, so the live value would not carry over. (28.x: section [actions], 0 = keep forever.)
        actions = {
          ENABLED = true;
          RUN_RETENTION_DAYS = 0;
        };
        oauth2.JWT_SIGNING_PRIVATE_KEY_FILE = jwtKeyPath;
      };
    };

    assertions = [
      {
        # The live instance runs 1.26.4 (DB schema 331); Gitea's migrations cannot be undone.
        assertion = lib.versionAtLeast gc.package.version minVersion;
        message = "gitea ${gc.package.version} is older than ${minVersion}: the live database (1.26.4) is migrated forward only. Update nixpkgs, do not downgrade.";
      }
    ];

    # --- tmpfiles: no `d` rules on the immutable /state ------------------------------------------------
    # The module's rules (stateDir, conf, custom, data, log, repositories, lfs, dump, .ssh, locale link)
    # are all under /state/gitea. Drop exactly those (the `apply` at the top of this file); the ExecStartPre
    # below creates the directories.
    systemd.services.gitea = lib.mkIf gc.enable {
      requires = ["postgresql.target"]; # (the module only orders itself after it)
      serviceConfig = {
        TimeoutStartSec = lib.mkForce "15m";
        ExecStartPre = lib.mkBefore [
          # Root-run (`+`), before the module's own preStart (which runs as gitea): create the tree, fix the
          # ownership of everything (a copy made by the Cutover is owned by 1000, and a reinstall may change
          # the id map), link the sops secrets into custom/conf and refuse an empty database.
          "+${pkgs.writeShellScript "gitea-state-owner" ''
            set -euo pipefail
            install -d -m 0750 -o gitea -g gitea ${stateDir} ${stateDir}/conf ${gc.customDir} ${gc.customDir}/conf \
              ${stateDir}/data ${stateDir}/log ${gc.repositoryRoot} ${gc.lfs.contentDir} ${gc.dump.backupDir}
            chown -R gitea:gitea ${stateDir}
            ${lib.optionalString haveSecrets ''
              ${lib.concatMapStrings (n: ''
                  ln -sfn ${secretDir}/${n} ${gc.customDir}/conf/${n}
                '')
                confSecrets}
            ''}
            if [ -d ${gc.package.out}/locale ]; then
              ln -sfn ${gc.package.out}/locale ${stateDir}/conf/locale
            fi
            # Gitea must never run `gitea migrate` on an empty database: that would build a fresh schema
            # and make the later restore impossible. The Cutover loads the dump first (optiplex-db-restore).
            have="$(${pkgs.util-linux}/bin/runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/psql -X -d gitea -tAc "select to_regclass('public.repository') is not null")"
            if [ "$have" != t ]; then
              echo "gitea: database 'gitea' has no schema. Restore the dump first (optiplex-db-restore), then optiplex-gitea-restore." >&2
              exit 1
            fi
          ''}"
        ];
      };
    };
    # RequiresMountsFor=/state (no start without the Data disk)
    optiplex.stateUnits = ["gitea" "gitea-state-dir"];

    # In restoreMode Gitea is off, but /state/gitea exists (owned by gitea) for the restore. A oneshot, not a
    # tmpfiles rule, for the reason above. The normal deploy's ExecStartPre does the same on every start.
    systemd.services.gitea-state-dir = lib.mkIf cfg.restoreMode {
      description = "Create /state/gitea for the restore";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/install -d -m 0750 -o gitea -g gitea ${stateDir}";
      };
    };

    # --- secrets ----------------------------------------------------------------------------------
    # The secret's name is its path under /run/secrets, like the other service files.
    sops.secrets = lib.mkIf haveSecrets (lib.listToAttrs (map (n:
      lib.nameValuePair "gitea/${n}" {
        sopsFile = giteaSecrets;
        key = n;
        owner = "gitea";
        mode = "0400";
        restartUnits = lib.optional (!cfg.restoreMode) "gitea.service";
      })
    secretNames));
    warnings = lib.optional (!haveSecrets) ''
      secrets/optiplex/gitea.yaml does not exist (looked in ${toString cfg.secretsDir}): Gitea gets no secrets and will not start.
      Keys: ${lib.concatStringsSep ", " secretNames}.
      secret_key is fresh (`gitea generate secret SECRET_KEY`); the others are carried from the Docker Gitea,
      see the Answer of ticket 32 for the commands. Create it with `sops secrets/optiplex/gitea.yaml` and `git add` it.
    '';

    # --- firewall: the built-in SSH server is LAN only (nothing public, not the runner VMs) ---------------
    optiplex.firewall.lanOnly.tcp = [sshPort];

    # --- Caddy: public, no body limit ---------------------------------------------------------------
    # useACMEHost = "nnik.dev" is set by the base helper for every *.nnik.dev vhost.
    services.caddy.virtualHosts."git.nnik.dev".extraConfig = ''
      import security
      reverse_proxy 127.0.0.1:${toString httpPort}
    '';

    environment.systemPackages = [restoreTool cliTool];

    # --- VM test: fixture and checks (see machines/optiplex/vm-test.nix) -------------------------------
    # The fixture is what the Cutover has in hand: the copied Docker volume (owner 1000, hooks that call
    # /usr/local/bin/gitea with /data paths, the old host keys and jwt key, session/index leftovers) and a
    # dump of the database. Both are made by a throwaway Gitea (the packaged one, on the real PostgreSQL,
    # with the live app.ini's layout), which creates the user Yannik with an SSH key, the organisation
    # AItopia with the repository demo and the registry packages. The database is dumped (pg_dump -Fc) and
    # then dropped and recreated empty, as the restoreMode install has it. Limitation: the schema is the
    # packaged version's own, so the forward migration from 1.26.4 is not exercised (nixpkgs has no older Gitea).
    optiplex.vmTest.fixtures.gitea.script = ''
      export PATH=${testPath}:$PATH
      fix=${fixtureDir}
      v=${volumeDir}
      w=$fix/work
      api=http://127.0.0.1:${toString fixturePort}
      rm -rf $fix
      install -d -m 0755 $fix
      install -d -o gitea -g gitea -m 0750 $w $w/git $w/git/repositories $w/git/lfs $w/gitea $w/gitea/conf $w/git/.ssh
      for s in lfs_jwt_secret oauth2_jwt_secret internal_token; do
        test -s ${secretDir}/$s
      done
      # the live app.ini, translated to the throwaway paths (old-style: DOMAIN, SSH 22)
      cat > $w/gitea/conf/app.ini <<INI
      APP_NAME = Private Repo
      RUN_MODE = prod
      RUN_USER = gitea
      WORK_PATH = $w/gitea
      [repository]
      ROOT = $w/git/repositories
      [server]
      APP_DATA_PATH = $w/gitea
      DOMAIN = git.nnik.dev
      SSH_DOMAIN = git.nnik.dev
      HTTP_ADDR = 127.0.0.1
      HTTP_PORT = ${toString fixturePort}
      ROOT_URL = https://git.nnik.dev/
      DISABLE_SSH = false
      SSH_PORT = 22
      SSH_LISTEN_PORT = 22
      LFS_START_SERVER = true
      LFS_JWT_SECRET = $(cat ${secretDir}/lfs_jwt_secret)
      [database]
      DB_TYPE = postgres
      HOST = /run/postgresql
      NAME = gitea
      USER = gitea
      PASSWD =
      SSL_MODE = disable
      [session]
      PROVIDER = file
      PROVIDER_CONFIG = $w/gitea/sessions
      [picture]
      AVATAR_UPLOAD_PATH = $w/gitea/avatars
      REPOSITORY_AVATAR_UPLOAD_PATH = $w/gitea/repo-avatars
      [attachment]
      PATH = $w/gitea/attachments
      [log]
      MODE = console
      LEVEL = info
      [security]
      INSTALL_LOCK = true
      SECRET_KEY =
      INTERNAL_TOKEN = $(cat ${secretDir}/internal_token)
      [service]
      DISABLE_REGISTRATION = true
      [lfs]
      PATH = $w/git/lfs
      [oauth2]
      JWT_SECRET = $(cat ${secretDir}/oauth2_jwt_secret)
      INI
      chown gitea:gitea $w/gitea/conf/app.ini
      chmod 0640 $w/gitea/conf/app.ini
      env_="HOME=$w/git GITEA_WORK_DIR=$w/gitea GITEA_CUSTOM=$w/gitea PATH=${testPath}"
      cli() { runuser -u gitea -- env $env_ ${exe} --config $w/gitea/conf/app.ini "$@"; }

      for _ in $(seq 60); do
        runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/pg_isready -q -h /run/postgresql && break
        sleep 1
      done
      cli migrate
      cli admin user create --username Yannik --password ${fixturePass} --email yannik@example.com --admin --must-change-password=false
      systemd-run --quiet --collect --unit=gitea-fixture --uid=gitea --gid=gitea \
        -p "Environment=$env_" -p WorkingDirectory=$w/gitea \
        ${exe} web --config $w/gitea/conf/app.ini
      for _ in $(seq 60); do
        curl -fsS $api/api/healthz > /dev/null 2>&1 && break
        sleep 1
      done
      curl -fsS $api/api/healthz > /dev/null
      call() { # call <method> <path> [json | file]
        curl -fsS -u Yannik:${fixturePass} -X "$1" -H 'Content-Type: application/json' "$api$2" ''${3:+-d "$3"}
      }
      call POST /api/v1/orgs '{"username":"AItopia"}' > /dev/null
      call POST /api/v1/orgs/AItopia/repos '{"name":"demo","auto_init":true,"default_branch":"main","readme":"Default"}' > /dev/null
      ssh-keygen -q -t ed25519 -N "" -C yannik-fixture -f $fix/yannik_key
      call POST /api/v1/user/keys "{\"title\":\"fixture\",\"key\":\"$(cat $fix/yannik_key.pub)\"}" > /dev/null
      # the registry: the two kept images, and the two deleted ones before the final dump
      for p in flutter-ci flutter-android-ci battle-tracker-web bt-sync-server; do
        head -c 200000 /dev/urandom | curl -fsS -u Yannik:${fixturePass} -X PUT -H 'Content-Type: application/octet-stream' --data-binary @- \
          $api/api/packages/AItopia/generic/$p/1.0.0/layer.bin > /dev/null
      done
      for p in battle-tracker-web bt-sync-server; do
        call DELETE /api/v1/packages/AItopia/generic/$p/1.0.0 > /dev/null
      done
      pk="$(call GET '/api/v1/packages/AItopia?type=generic')"
      echo "$pk" | grep -q flutter-ci
      echo "$pk" | grep -q flutter-android-ci
      ! echo "$pk" | grep -q battle-tracker-web
      systemctl stop gitea-fixture
      for _ in $(seq 30); do systemctl is-active --quiet gitea-fixture || break; sleep 1; done

      # the database: dump it, then recreate it empty (what the restoreMode install has)
      install -d -m 0755 ${dumpDir}/postgresql
      runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/pg_dump -Fc gitea > ${dumpDir}/postgresql/gitea.dump
      runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/psql -X -d postgres -v ON_ERROR_STOP=1 \
        -c 'DROP DATABASE gitea' -c 'CREATE DATABASE gitea OWNER gitea'

      # the volume, as the Docker volume looks: git/ and gitea/ and ssh/, owner 1000, container paths in the hooks
      install -d -m 0755 $(dirname $v)
      mv $w $v
      n_hooks="$(find $v/git/repositories -path '*/hooks/*.d/gitea' | wc -l)"
      test "$n_hooks" -ge 1
      find $v/git/repositories -path '*/hooks/*.d/gitea' | while read -r h; do
        sed -i -e 's#^[^ ]*/bin/gitea hook#/usr/local/bin/gitea hook#' -e 's#--config=[^ ]*#--config=/data/gitea/conf/app.ini#' "$h"
      done
      grep -rq '/data/gitea/conf/app.ini' $v/git/repositories
      install -d $v/gitea/jwt $v/ssh $v/git/.ssh $v/git/lfs/ab/cd $v/gitea/sessions $v/gitea/indexers $v/gitea/queues $v/gitea/tmp $v/gitea/repo-archive
      echo old-jwt-key > $v/gitea/jwt/private.pem
      ssh-keygen -q -t ed25519 -N "" -C old-container-key -f $v/ssh/ssh_host_ed25519_key
      touch $v/git/.ssh/authorized_keys $v/gitea/sessions/old-session $v/gitea/indexers/old-index $v/gitea/tmp/old-tmp
      echo lfs-object-fixture > $v/git/lfs/ab/cd/object
      test -d $v/gitea/packages
      chown -R 1000:1000 $v
    '';

    optiplex.vmTest.checks.gitea-restore = {
      phase = "restore";
      script = ''
        psql = "runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/psql -X -d gitea -tAc"

        # restoreMode: Gitea is off and has never run, but the user, the secrets and /state/gitea are there
        optiplex.fail("systemctl cat gitea.service")
        optiplex.succeed("test -z \"$(journalctl -u gitea.service --no-pager -q)\"")
        optiplex.succeed("test \"$(id -u gitea):$(id -g gitea)\" = 950:950")
        optiplex.succeed("test -d /state/gitea -a \"$(stat -c %U:%G /state/gitea)\" = gitea:gitea")
        for n in ${builtins.toJSON secretNames}:
            owner_mode = optiplex.succeed(f"stat -L -c '%U %a' ${secretDir}/{n}").strip()
            assert owner_mode == "gitea 400", (n, owner_mode)
        optiplex.fail("ss -H -ltn 'sport = :${toString httpPort}' | grep -q .")
        optiplex.fail("ss -H -ltn 'sport = :${toString sshPort}' | grep -q .")
        # the database exists and is empty
        assert optiplex.succeed(f"{psql} \"select count(*) from information_schema.tables where table_schema = 'public'\"").strip() == "0"

        # the Cutover steps: dump first, then the files
        out = optiplex.succeed("optiplex-db-restore ${dumpDir} --only gitea --no-manifest 2>&1")
        print(out)
        out = optiplex.succeed("optiplex-gitea-restore ${volumeDir} 2>&1")
        print(out)
        assert int(optiplex.succeed(f"{psql} \"select count(*) from repository\"").strip()) >= 1
        assert optiplex.succeed(f"{psql} \"select name from \\\"user\\\" where lower_name = 'yannik'\"").strip() == "Yannik"
        # a second run is refused (one shot)
        optiplex.fail("optiplex-gitea-restore ${volumeDir}")

        # the tree: what is copied, what is not, and the owner
        for p in ("repositories/aitopia/demo.git/HEAD", "data/lfs/ab/cd/object", "data/packages", "data/attachments"):
            optiplex.succeed(f"test -e /state/gitea/{p}")
        for p in ("data/sessions", "data/indexers", "data/queues", "data/tmp", "data/repo-archive", "data/jwt", "ssh", ".ssh",
                  "conf/app.ini", "custom/conf/app.ini", "data/conf", "git"):
            optiplex.fail(f"test -e /state/gitea/{p}")
        optiplex.succeed("test -z \"$(find /state/gitea \\( ! -user gitea -o ! -group gitea \\))\"")
        optiplex.succeed("test -z \"$(find /state/gitea -perm /o+rwx)\"")
        # the volume itself is untouched
        optiplex.succeed("test -e ${volumeDir}/git/repositories/aitopia/demo.git/HEAD -a \"$(stat -c %u ${volumeDir}/git)\" = 1000")
        # still not started
        optiplex.fail("systemctl cat gitea.service")
      '';
    };

    optiplex.vmTest.checks.gitea = {
      script = ''
        curl_ = "curl -sS --cacert /tmp/pebble-root.pem --resolve git.nnik.dev:443:192.168.178.20 https://git.nnik.dev"
        psql = "runuser -u postgres -- ${config.services.postgresql.finalPackage}/bin/psql -X -d gitea -tAc"

        # --- the normal deploy started it, as gitea, State required, the migration ran
        optiplex.wait_for_unit("gitea.service")
        optiplex.wait_until_succeeds("curl -fsS http://127.0.0.1:${toString httpPort}/api/healthz")
        props = dict(l.split("=", 1) for l in optiplex.succeed("systemctl show -p User -p MainPID -p RequiresMountsFor -p TimeoutStartUSec -p ExecMainStartTimestampMonotonic -p ActiveEnterTimestampMonotonic -p InactiveExitTimestampMonotonic gitea.service").splitlines())
        assert props["User"] == "gitea", props
        assert "/state" in props["RequiresMountsFor"], props
        assert props["TimeoutStartUSec"] == "15min", props
        assert optiplex.succeed(f"ps -o user= -p {props['MainPID']}").strip() == "gitea"
        took = (int(props["ActiveEnterTimestampMonotonic"]) - int(props["InactiveExitTimestampMonotonic"])) / 1e6
        print(f"gitea.service start to ready (migrate + hooks + listen): {took:.1f} s")
        optiplex.fail("test -e /var/lib/gitea")
        optiplex.fail("systemctl --failed --no-legend | grep -q gitea")

        # --- the generated config (no DOMAIN, no DB password, the decided values)
        ini = optiplex.succeed("cat /state/gitea/custom/conf/app.ini")
        print(ini)
        sections, cur = {}, None
        for line in ini.splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1]; sections[cur] = {}
            elif "=" in line and cur is not None:
                k, v = line.split("=", 1); sections[cur][k.strip()] = v.strip()
        want = {
            ("server", "ROOT_URL"): "https://git.nnik.dev/", ("server", "START_SSH_SERVER"): "true",
            ("server", "SSH_PORT"): "${toString sshPort}", ("server", "SSH_LISTEN_PORT"): "${toString sshPort}",
            ("server", "BUILTIN_SSH_SERVER_USER"): "git", ("server", "SSH_DOMAIN"): "git.nnik.dev",
            ("server", "HTTP_ADDR"): "127.0.0.1", ("server", "HTTP_PORT"): "${toString httpPort}",
            ("webhook", "ALLOWED_HOST_LIST"): "loopback", ("service", "DISABLE_REGISTRATION"): "true",
            ("actions", "RUN_RETENTION_DAYS"): "0", ("actions", "ENABLED"): "true",
            ("database", "DB_TYPE"): "postgres", ("database", "HOST"): "/run/postgresql", ("database", "PASSWD"): "",
            ("database", "USER"): "gitea", ("database", "NAME"): "gitea",
            ("oauth2", "JWT_SIGNING_PRIVATE_KEY_FILE"): "${jwtKeyPath}",
            ("server", "SSH_SERVER_HOST_KEYS"): "${lib.concatMapStringsSep "," hostKeyPath hostKeys}",
            ("repository", "ROOT"): "/state/gitea/repositories", ("lfs", "PATH"): "/state/gitea/data/lfs",
        }
        for (sec, key), val in want.items():
            assert sections.get(sec, {}).get(key) == val, (sec, key, sections.get(sec, {}).get(key), val)
        assert "DOMAIN" not in sections["server"], sections["server"]
        assert "#" not in sections["database"]["PASSWD"]
        assert "/data" not in "".join(v for s in sections.values() for v in s.values() if v.startswith("/data")), sections
        # the secrets came from sops: custom/conf links point to them, and the values are in the ini
        for n in ${builtins.toJSON confSecrets}:
            assert optiplex.succeed(f"readlink /state/gitea/custom/conf/{n}").strip() == f"${secretDir}/{n}", n
            sops_val = optiplex.succeed(f"cat ${secretDir}/{n}").strip()
            assert sops_val and sops_val in ini, n
        # ... and the module's preStart did not generate a SECRET_KEY of its own
        optiplex.succeed("test \"$(cat /state/gitea/custom/conf/secret_key)\" = \"$(cat ${secretDir}/secret_key)\"")

        # --- version, 28.x, from the API through Caddy. The cert comes from pebble, whose root is random per
        # start: the client fetches it from pebble's management port (trusting only the WFE test CA).
        lan.wait_until_succeeds("curl -sS --cacert ${caCert} --resolve acme.test:15000:192.168.178.60 https://acme.test:15000/roots/0 -o /tmp/pebble-root.pem", timeout=60)
        lan.wait_until_succeeds(f"{curl_}/api/v1/version -o /dev/null", timeout=120)
        ver = lan.succeed(f"{curl_}/api/v1/version")
        print(ver)
        assert '"version":"28.' in ver.replace(" ", ""), ver
        head = lan.succeed(f"{curl_}/api/v1/version -D - -o /dev/null").lower()
        assert head.startswith("http/2 200") or head.startswith("http/1.1 200"), head
        assert "strict-transport-security: max-age=31536000" in head, head

        # --- the restored data is served
        repos = lan.succeed(f"{curl_}/api/v1/repos/search?q=demo")
        assert '"full_name":"AItopia/demo"' in repos.replace(" ", ""), repos
        pk = lan.succeed(f"{curl_}/api/v1/packages/AItopia -u Yannik:${fixturePass}")  # (listing packages needs a login)
        assert "flutter-ci" in pk and "flutter-android-ci" in pk, pk
        assert "battle-tracker-web" not in pk and "bt-sync-server" not in pk, pk
        assert optiplex.succeed(f"{psql} \"select count(*) from package_version\"").strip() == "2"
        # packages are served from /state/gitea/data/packages
        optiplex.succeed("test -n \"$(find /state/gitea/data/packages -type f | head -n1)\"")
        # the sessions are rebuilt, the dropped State is not back
        optiplex.fail("test -e /state/gitea/data/indexers/old-index -o -e /state/gitea/data/sessions/old-session")

        # --- hooks were regenerated by the start
        hooks = optiplex.succeed("cat /state/gitea/repositories/aitopia/demo.git/hooks/pre-receive.d/gitea")
        print(hooks)
        assert "/data" not in hooks and "/usr/local/bin/gitea" not in hooks, hooks
        assert "${gc.package}/bin/gitea" in hooks or "${exe}" in hooks, hooks
        optiplex.fail("grep -rq '/data/gitea\\|/usr/local/bin' /state/gitea/repositories --include=gitea --include=pre-receive --include=update --include=post-receive")

        # --- the built-in SSH server: the carried host keys, key login from the LAN, clone and push
        def pub_fp(path):
            # (a sops literal block has no final newline; ssh-keygen wants one)
            optiplex.succeed(f"install -m 0600 /dev/null /tmp/hostkey && cat {path} > /tmp/hostkey && echo >> /tmp/hostkey")
            return optiplex.succeed("ssh-keygen -y -f /tmp/hostkey | ssh-keygen -lf -; rm -f /tmp/hostkey").split()[1]
        lan.wait_until_succeeds("timeout 5 bash -c 'echo > /dev/tcp/192.168.178.20/${toString sshPort}'", timeout=60)
        for t in ${builtins.toJSON hostKeys}:
            want_fp = pub_fp(f"${secretDir}/ssh_host_{t}_key")
            got_fp = lan.succeed(f"ssh-keyscan -p ${toString sshPort} -t {t} 192.168.178.20 2>/dev/null | ssh-keygen -lf -").split()[1]
            assert want_fp == got_fp, (t, want_fp, got_fp)
        old_fp = optiplex.succeed("ssh-keygen -lf ${volumeDir}/ssh/ssh_host_ed25519_key").split()[1]
        assert old_fp != pub_fp("${secretDir}/ssh_host_ed25519_key")
        optiplex.fail("test -e /state/gitea/ssh")

        key = optiplex.succeed("cat ${fixtureDir}/yannik_key")
        lan.succeed("install -d -m 0700 /root/.ssh && cat > /root/.ssh/yannik_key <<'KEY'\n" + key + "KEY\nchmod 600 /root/.ssh/yannik_key")
        lan.succeed("cp --remove-destination $(readlink -f /etc/hosts) /etc/hosts && echo '192.168.178.20 git.nnik.dev' >> /etc/hosts")
        ssh_ = "ssh -i /root/.ssh/yannik_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts -o BatchMode=yes -p ${toString sshPort}"
        greet = lan.succeed(f"{ssh_} git@git.nnik.dev 2>&1")
        print(greet)
        assert "Hi there, Yannik!" in greet, greet
        # a key the server does not know is refused
        lan.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /root/.ssh/stranger")
        lan.fail("ssh -i /root/.ssh/stranger -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts -o BatchMode=yes -p ${toString sshPort} git@git.nnik.dev true")
        git = "${pkgs.git}/bin/git -c user.name=Yannik -c user.email=yannik@example.com"
        env = f"GIT_SSH_COMMAND='{ssh_}'"
        lan.succeed(f"cd /tmp && rm -rf demo && {env} {git} clone ssh://git@git.nnik.dev:${toString sshPort}/AItopia/demo.git")
        lan.succeed(f"cd /tmp/demo && echo pushed-over-ssh > pushed.txt && {git} add pushed.txt && {git} commit -qm 'push over the built-in ssh server'")
        lan.succeed(f"cd /tmp/demo && {env} {git} push origin HEAD:main 2>&1 | tee /tmp/push.log")
        assert "remote: " not in lan.succeed("cat /tmp/push.log") or "error" not in lan.succeed("cat /tmp/push.log").lower()
        optiplex.succeed("runuser -u gitea -- git -C /state/gitea/repositories/aitopia/demo.git log -1 --format=%s main | grep -q 'built-in ssh server'")
        # a push to a repo the key may not touch / that does not exist fails cleanly
        lan.fail(f"cd /tmp/demo && {env} {git} push ssh://git@git.nnik.dev:${toString sshPort}/nobody/nothing.git HEAD:main")

        # --- HTTPS clone through Caddy, and the websocket
        cainfo = "GIT_SSL_CAINFO=/tmp/pebble-root.pem"
        lan.succeed(f"cd /tmp && rm -rf demo-https && {cainfo} {git} clone https://git.nnik.dev/AItopia/demo.git demo-https")
        lan.succeed("grep -q pushed-over-ssh /tmp/demo-https/pushed.txt")
        lan.succeed("cd /tmp/demo-https && echo https-push > https.txt && " + f"{git} add https.txt && {git} commit -qm https-push && {cainfo} {git} push https://Yannik:${fixturePass}@git.nnik.dev/AItopia/demo.git HEAD:main")
        # websocket: log in (CSRF token from the form), then upgrade /-/ws
        # (28.x has no CSRF form field: the check is header based, so a plain POST logs in)
        lan.succeed(f"rm -f /tmp/jar && {curl_}/user/login -c /tmp/jar -o /dev/null")
        lan.succeed(f"{curl_}/user/login -b /tmp/jar -c /tmp/jar -o /dev/null -d user_name=Yannik --data-urlencode password=${fixturePass}")
        assert "session" in lan.succeed("cat /tmp/jar"), lan.succeed("cat /tmp/jar")
        ws = lan.succeed(
            f"{curl_}/-/ws -b /tmp/jar --http1.1 -m 5 -i -H 'Connection: Upgrade' -H 'Upgrade: websocket' "
            "-H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' || true"
        )
        print(ws)
        assert ws.startswith("HTTP/1.1 101"), ws

        # --- port 25580: LAN only
        outside.fail("timeout 5 bash -c 'echo > /dev/tcp/203.0.113.1/${toString sshPort}'")
        outside.fail("timeout 5 bash -c 'echo > /dev/tcp/2001:db8:2::1/${toString sshPort}'")
        lan.succeed("timeout 5 bash -c 'echo > /dev/tcp/fd65:c1a5:7d2b::20/${toString sshPort}'")
        rules = optiplex.succeed("nft list ruleset")
        assert [l for l in rules.splitlines() if "${toString sshPort}" in l and "saddr" in l and "accept" in l], rules
        assert not [l for l in rules.splitlines() if "${toString sshPort}" in l and "saddr" not in l and "accept" in l], rules
        optiplex.fail("nft list ruleset | grep -q '${toString httpPort}'")

        # --- gitea doctor check, as the runbook runs it
        doctor = optiplex.succeed("optiplex-gitea doctor check --all 2>&1")
        print(doctor)
        assert "All done (checks: 0)" not in doctor and "All done" in doctor, doctor
        assert not [l for l in doctor.splitlines() if "[E]" in l or "[F]" in l or "Failed" in l], doctor

        optiplex.succeed("systemctl is-active gitea.service")
      '';
    };
  };
}
