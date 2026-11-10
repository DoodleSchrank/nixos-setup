# Backup: the nightly restic job to the Scaleway bucket (one client-side encrypted repository, off-site
# only, no local copy for now), the consistent database and SQLite copies it takes first, and the weekly
# check. Alerts: a failed job posts to ntfy through notify-failure@ (monitoring.nix), a successful one
# pings healthchecks (healthchecks.nix).
#
# What the job does, in order (backupPrepareCommand = optiplex-backup-prepare, all blocking):
#   1. pg_dump -Fc -Z0 of the five PostgreSQL databases into /var/backup/postgresql/<db>.sql
#      (services.postgresqlBackup, without its own timer). Uncompressed so restic can deduplicate: a
#      compressed 10 GB Synapse dump would be uploaded in full every night. The files are named .sql but
#      hold custom format, restore uses pg_restore.
#   2. mariadb-dump --single-transaction of Seafile's three databases into /var/backup/mysql/<db>.gz
#      (services.mysqlBackup, without its own timer).
#   3. `sqlite3 .backup` of the live SQLite databases into /var/backup/sqlite/<name>.sqlite3, each copy
#      checked with PRAGMA integrity_check. The live files (and their -wal/-shm) are excluded.
#   The dumps come before the file backup on purpose: Seafile's blocks are write-once and its database
#   points at them, so a database older than the block store is safe and the reverse is not.
# Then restic backs up /state, /var/backup, /mnt/tbssd/archive, the host keys and the initrd host key,
# and forgets and prunes (7 daily, 4 weekly, 6 monthly, grouped by host).
#
# The lists of paths and excludes are keyed by service in optiplex.backup.{paths,excludes,sqlite}, so a
# service file can add its own; this file sets them for every Kept service. The D&D follow-up of the
# Cutover appends its lines under `seafile` in `excludes` below.
#
# Guards: the job requires /state and /mnt/tbssd mounted (a missing Data disk fails the run instead of
# backing up the empty immutable mountpoint). In restoreMode both timers are gone (no snapshot of
# half-restored databases, no alert noise), the units stay for a manual run.
#
# The repository is NOT initialised by the job (`initialize = false`): a typo in the URL must never
# silently create a second repository. The gate run from Arch (infra/scaleway/arch-gate.sh) does it.
#
# Restore: optiplex-backup-restore (services/restic/optiplex-backup-restore.sh); `--help` is the procedure.
# Secrets: secrets/optiplex/restic.yaml (repository_password, s3_endpoint, s3_region, s3_bucket,
# s3_access_key_id, s3_secret_access_key).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  bk = cfg.backup;
  resticSecrets = cfg.secretsDir + "/restic.yaml";
  sec = n: config.sops.secrets."restic/${n}";

  sqliteDir = "/var/backup/sqlite";

  # Live files that the SQLite copies replace: the database and its sidecar files.
  liveSqliteExcludes = lib.concatMap (p: [p "${p}-wal" "${p}-shm" "${p}-journal"]) (lib.attrValues bk.sqlite);

  flatten = attrs: lib.concatLists (lib.attrValues attrs);

  # --- the pre-run copies --------------------------------------------------------------------------
  prepare = pkgs.writeShellApplication {
    name = "optiplex-backup-prepare";
    runtimeInputs = with pkgs; [systemd sqlite coreutils util-linux];
    text = ''
      # 1. PostgreSQL (one unit per database)
      ${lib.concatMapStrings (db: "systemctl start postgresqlBackup-${db}.service\n") cfg.databases.postgresql}
      # 2. MariaDB (one unit, all databases)
      systemctl start mysql-backup.service

      # 3. SQLite: an online copy, as the file's owner (a root-run sqlite3 could leave root-owned -wal/-shm
      #    files behind that the service then cannot open), then moved into the root-only dump tree
      install -d -m 0700 ${sqliteDir}
      sqlite_copy() { # <name> <live path>
        local name="$1" live="$2" owner tmp
        if [ ! -f "$live" ]; then
          echo "SQLite database $live is missing: refusing to back up without its copy" >&2
          return 1
        fi
        owner="$(stat -c %U "$live")"
        tmp="$(mktemp -d)"
        chown "$owner" "$tmp"
        chmod 0700 "$tmp"
        runuser -u "$owner" -- sqlite3 -cmd '.timeout 60000' "$live" ".backup '$tmp/copy'"
        if [ "$(sqlite3 "$tmp/copy" 'PRAGMA integrity_check')" != ok ]; then
          echo "the copy of $live fails PRAGMA integrity_check" >&2
          rm -rf "$tmp"
          return 1
        fi
        install -m 0600 "$tmp/copy" "${sqliteDir}/$name.sqlite3.new"
        mv -f "${sqliteDir}/$name.sqlite3.new" "${sqliteDir}/$name.sqlite3"
        rm -rf "$tmp"
        echo "SQLite copy: $name"
      }
      ${lib.concatStrings (lib.mapAttrsToList (name: live: "sqlite_copy ${lib.escapeShellArg name} ${lib.escapeShellArg live}\n") bk.sqlite)}
    '';
  };

  restore = pkgs.writeShellApplication {
    name = "optiplex-backup-restore";
    runtimeInputs = with pkgs; [coreutils findutils util-linux rsync sqlite];
    text =
      ''
        declare -A SQLITE=(${lib.concatStrings (lib.mapAttrsToList (n: p: " [${lib.escapeShellArg n}]=${lib.escapeShellArg p}") bk.sqlite)} )
        PG_DBS=(${lib.escapeShellArgs cfg.databases.postgresql})
        MARIADB_DBS=(${lib.escapeShellArgs cfg.databases.mariadb})
      ''
      + builtins.readFile ./restic/optiplex-backup-restore.sh;
  };
in {
  imports = [./restic/vm-checks.nix];

  options.optiplex.backup = {
    paths = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      description = "Paths of the nightly restic job, keyed by service (the key is only for the reader).";
    };
    excludes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      description = ''
        restic exclude patterns (anchored paths, `*` allowed), keyed by service. Regenerable caches and
        logs, and the live database directories.
      '';
    };
    sqlite = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {vaultwarden = "/state/vaultwarden/db.sqlite3";};
      description = ''
        Live SQLite databases under /state. Name to path. Each night `sqlite3 .backup` writes a copy to
        /var/backup/sqlite/<name>.sqlite3 (and fails the run if the copy is not `ok`); the live file and
        its -wal/-shm are excluded automatically. The restore puts the copy back at the live path.
      '';
    };
  };

  config = lib.mkMerge [
    # ---- what to back up ---------------------------------------------------------------------------------
    {
      optiplex.backup.paths = {
        state = ["/state"];
        dumps = ["/var/backup"]; # dump staging: postgresql/, mysql/, sqlite/
        archive = ["/mnt/tbssd/archive"]; # .zsh_history and the final elabFTW export
        host-keys = [
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_ed25519_key.pub"
          "/etc/ssh/ssh_host_rsa_key"
          "/etc/ssh/ssh_host_rsa_key.pub"
          "/etc/secrets/initrd/ssh_host_ed25519_key" # initrd SSH host key (networking.nix)
        ];
      };

      optiplex.backup.sqlite = {
        vaultwarden = "/state/vaultwarden/db.sqlite3";
        etesync = "/state/etesync/db.sqlite3";
        homeassistant = "/state/homeassistant/home-assistant_v2.db";
        healthchecks = "/state/healthchecks/healthchecks.sqlite";
      };

      # One plain list per service. Patterns are anchored at /.
      optiplex.backup.excludes = {
        # the live database directories (the dumps replace them)
        postgresql = ["/state/postgresql"];
        mariadb = ["/state/mariadb"];
        # dumps: the module keeps the previous run as <db>.prev.sql, in-progress files are unfinished
        dumps = [
          "/var/backup/postgresql/*.prev.sql"
          "/var/backup/postgresql/*.in-progress.sql"
          "/var/backup/mysql/*.tmp"
        ];
        gitea = [
          "/state/gitea/data/packages" # registry packages (decided: not backed up)
          "/state/gitea/data/sessions"
          "/state/gitea/data/indexers"
          "/state/gitea/data/queues"
          "/state/gitea/data/tmp"
          "/state/gitea/data/repo-archive"
          "/state/gitea/log"
          "/state/gitea/dump"
          "/state/gitea/custom" # generated app.ini and symlinks into /run/secrets
          "/state/gitea/conf"
        ];
        gitea-runners = ["/state/gitea-runners"]; # VM disks and caches, all regenerable by re-registering
        seafile = [
          "/state/seafile/seahub-data/thumbnail"
          "/state/seafile/logs"
          "/state/seafile/conf/__pycache__"
          # D&D library (Cutover execution appends here, before the import):
          #   "/state/seafile/seafile-data/storage/blocks/<library-id>"
          #   "/state/seafile/seafile-data/storage/fs/<library-id>"
          #   "/state/seafile/seafile-data/storage/commits/<library-id>"
        ];
        synapse = [
          "/state/synapse/media_store/url_cache"
          "/state/synapse/media_store/url_cache_thumbnails"
          "/state/synapse/media_store/remote_content"
          "/state/synapse/media_store/remote_thumbnail"
          "/state/synapse/media_store/local_thumbnails"
        ];
        paperless = [
          "/state/paperless/index" # document_index reindex rebuilds it
          "/state/paperless/log"
          "/state/paperless/nixos-paperless-secret-key.env"
        ];
        vaultwarden = ["/state/vaultwarden/icon_cache" "/state/vaultwarden/tmp"];
        homeassistant = [
          "/state/homeassistant/home-assistant.log*"
          "/state/homeassistant/.cache"
          "/state/homeassistant/.ha_run.lock"
          "/state/homeassistant/deps"
          "/state/homeassistant/tts"
        ];
        etesync = [
          "/state/etesync-dav/etebase_data.db*" # a cache the service re-syncs
        ];
        healthchecks = ["/state/healthchecks/static"]; # collectstatic rebuilds it on every start
        sqlite-live = liveSqliteExcludes; # replaced by the copies in /var/backup/sqlite
      };
    }

    # ---- the dumps (no timers of their own: the job starts them) -----------------------------------------------
    {
      services.postgresqlBackup = {
        enable = true;
        databases = cfg.databases.postgresql;
        pgdumpOptions = "-Fc -Z0";
        compression = "none";
        startAt = [];
      };
      services.mysqlBackup = {
        enable = true;
        databases = cfg.databases.mariadb;
        singleTransaction = true;
        # gzip with the module's default --rsyncable
      };
      systemd.timers.mysql-backup.enable = lib.mkForce false; # the module always makes a timer
      environment.systemPackages = [prepare restore];
    }

    # ---- secrets -----------------------------------------------------------------------------------------------------
    {
      sops.secrets = lib.listToAttrs (map (n:
        lib.nameValuePair "restic/${n}" {
          sopsFile = resticSecrets;
          key = n;
          owner = "root";
          mode = "0400";
        }) ["repository_password" "s3_endpoint" "s3_region" "s3_bucket" "s3_access_key_id" "s3_secret_access_key"]);
      sops.templates."restic-repository".content = "s3:${config.sops.placeholder."restic/s3_endpoint"}/${config.sops.placeholder."restic/s3_bucket"}";
      sops.templates."restic-env".content = ''
        AWS_ACCESS_KEY_ID=${config.sops.placeholder."restic/s3_access_key_id"}
        AWS_SECRET_ACCESS_KEY=${config.sops.placeholder."restic/s3_secret_access_key"}
        AWS_DEFAULT_REGION=${config.sops.placeholder."restic/s3_region"}
      '';
    }

    # ---- the jobs ----------------------------------------------------------------------------------------------------------
    {
      services.restic.backups = let
        common = {
          passwordFile = (sec "repository_password").path;
          repositoryFile = config.sops.templates."restic-repository".path;
          environmentFile = config.sops.templates."restic-env".path;
          # Scaleway's default class STANDARD is Multi-AZ at twice the price
          extraOptions = ["s3.storage-class=ONEZONE_IA"];
          initialize = false;
        };
      in {
        optiplex =
          common
          // {
            paths = flatten bk.paths;
            exclude = flatten bk.excludes;
            extraBackupArgs = ["--tag nightly"];
            backupPrepareCommand = "${lib.getExe prepare}";
            pruneOpts = ["--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" "--group-by host"];
            timerConfig =
              if cfg.restoreMode
              then null
              else {
                OnCalendar = "03:00";
                Persistent = true;
                RandomizedDelaySec = "15m";
              };
          };
        # Weekly check of a tenth of the data. A check-only job: no paths, so the module only runs `check`.
        optiplex-check =
          common
          // {
            paths = [];
            checkOpts = ["--read-data-subset=10%"];
            createWrapper = false;
            timerConfig =
              if cfg.restoreMode
              then null
              else {
                OnCalendar = "Sun 05:00";
                Persistent = true;
              };
          };
      };

      systemd.services.restic-backups-optiplex = {
        unitConfig.RequiresMountsFor = ["/state" "/mnt/tbssd"];
        onSuccess = ["optiplex-hc-ping@backup-nightly.service"];
      };
      systemd.services.restic-backups-optiplex-check.onSuccess = ["optiplex-hc-ping@backup-check.service"];

      # The VM tests must never run the timers (restic would back synthetic or restored State up into the
      # real bucket), so both are offline timers. offline.nix also removes the services of that list; the
      # tests run the job by hand against a local repository, so the units are put back (a higher
      # priority than its mkForce). The timers stay off.
      optiplex.vmTest.offlineTimers = ["restic-backups-optiplex" "restic-backups-optiplex-check"];
      systemd.services.restic-backups-optiplex.enable = lib.mkOverride 40 true;
      systemd.services.restic-backups-optiplex-check.enable = lib.mkOverride 40 true;
    }

    # ---- the ping unit (the script is in healthchecks.nix) ---------------------------------------------------------------
    {
      systemd.services."optiplex-hc-ping@" = {
        description = "Ping the healthchecks check %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "/run/current-system/sw/bin/optiplex-hc-ping %i";
        };
      };
    }
  ];
}
