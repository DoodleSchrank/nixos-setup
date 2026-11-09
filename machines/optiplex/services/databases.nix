# The shared database servers (ticket "Shared PostgreSQL and MariaDB servers") and the tooling that
# fills them. This file holds what both servers share; the servers are in the two files it imports:
#   postgresql.nix   PostgreSQL 18, socket + peer auth only, the five roles/databases
#   mariadb.nix      MariaDB 11.4 for Seafile, the TCP account for the container
#
# Other tickets read two things from here:
#   optiplex.databases.postgresql / .mariadb   the database lists, in exactly one place. The Backup
#       ticket feeds them to services.postgresqlBackup / services.mysqlBackup. Dumps must be
#       custom format (-Fc) for PostgreSQL (pgdumpOptions) and singleTransaction = true for MariaDB,
#       and optiplex-db-restore reads <db>.dump (PostgreSQL) and <db>.sql[.gz|.xz|.zst] (MariaDB).
#   optiplex.databases.seafileNetwork          the podman network the Seafile ticket must create:
#       `podman network create --subnet <subnet> --gateway <first address> --interface-name <interface>`
#       (the Seafile container's database host is the gateway address).
#
# Roles and databases are declared unconditionally, so they exist in restoreMode while the service
# modules that would also declare them (Gitea createDatabase, Paperless database.createLocally, the
# Synapse module) are switched off. Those declarations are harmless duplicates.
#
# `optiplex-db-restore` (machines/optiplex/cutover/) is the restore side of the Cutover; its
# counterpart on Arch is machines/optiplex/cutover/arch-db-dumps.sh.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex.databases;
  synapseDb = "matrix-synapse";

  # Small databases first (fail fast), Synapse last.
  pgOrder = (lib.remove synapseDb cfg.postgresql) ++ lib.optional (lib.elem synapseDb cfg.postgresql) synapseDb;

  # Units that must not run while a database is restored. Globs, as systemctl takes them.
  consumerUnits = [
    "matrix-synapse.service"
    "mautrix-*.service"
    "gitea.service"
    "paperless-*.service"
    "podman-seafile*.service"
  ];

  restore = pkgs.writeShellApplication {
    name = "optiplex-db-restore";
    runtimeInputs = with pkgs; [
      config.services.postgresql.finalPackage # psql, pg_restore, vacuumdb
      config.services.mysql.package # mariadb
      coreutils
      diffutils
      gawk
      gnugrep
      gnused
      gzip
      xz
      zstd
      acl
      util-linux # runuser
      systemd
    ];
    text = ''
      PG_DBS=(${lib.escapeShellArgs pgOrder})
      MARIADB_DBS=(${lib.escapeShellArgs cfg.mariadb})
      SYNAPSE_DB=${lib.escapeShellArg synapseDb}
      CONSUMER_UNITS=(${lib.escapeShellArgs consumerUnits})
      RESTORE_MODE=${if config.optiplex.restoreMode then "1" else "0"}
    ''
    + builtins.readFile ../cutover/optiplex-db-restore.sh;
  };
in {
  imports = [./postgresql.nix ./mariadb.nix];

  options.optiplex.databases = {
    postgresql = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["matrix-synapse" "mautrix-whatsapp" "mautrix-telegram" "gitea" "paperless"];
      description = ''
        PostgreSQL databases. Each is also a role and the Unix user that may connect to it (peer
        authentication). `matrix-synapse` is special: it is created by hand with C/C collation.
      '';
    };
    mariadb = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["ccnet_db" "seafile_db" "seahub_db"];
      description = "MariaDB databases (all Seafile's, utf8mb3 like the source). One TCP account, `seafile`, owns them.";
    };
    seafileNetwork = {
      subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.89.29.0/24";
        description = ''
          Subnet of the Seafile container's podman network. The `seafile` MariaDB account is limited
          to this subnet. Must not overlap the runner VM bridges (10.100.1.0/24, 10.100.2.0/24).
        '';
      };
      gateway = lib.mkOption {
        type = lib.types.str;
        default = "10.89.29.1";
        description = "The host's address in that network: where the container reaches MariaDB (SEAFILE_MYSQL_DB_HOST).";
      };
      interface = lib.mkOption {
        type = lib.types.str;
        default = "podman-seafile";
        description = "Interface name of that network (`--interface-name`); port 3306 is opened on it and nowhere else.";
      };
    };
  };

  config.environment.systemPackages = [restore];
}
