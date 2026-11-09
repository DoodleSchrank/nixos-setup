# Shared PostgreSQL 18: one cluster for Synapse, both bridges, Gitea and Paperless (decided in
# "Shared PostgreSQL layout").
#   - data in /state/postgresql/18 (Data disk, ext4; the /18 leaves room for a side-by-side major upgrade)
#   - builtin C.UTF-8 locale provider, so glibc updates cannot cause collation drift
#   - Unix socket and peer authentication only: no TCP listener, no passwords anywhere
#   - database = role = Unix user, for each of optiplex.databases.postgresql
#   - `matrix-synapse` is created by hand (postgresql-synapse-db.service) with C/C collation, because
#     ensureDatabases cannot set a locale. Anything that starts the Synapse unit must require it.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex.databases;
  pgCfg = config.services.postgresql;
  synapseDb = "matrix-synapse";
  stateDir = "/state/postgresql";
in {
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;
    dataDir = "${stateDir}/${pkgs.postgresql_18.psqlSchema}";
    initdbArgs = ["--encoding=UTF8" "--locale-provider=builtin" "--builtin-locale=C.UTF-8" "--locale=C"];

    # No TCP. The module listens on localhost by default, hence the force.
    enableTCPIP = false;
    settings = {
      listen_addresses = lib.mkForce "";
      # 16 GB host that reserves 7 GB for the runner VMs; revisit after Synapse runs.
      shared_buffers = "1GB";
      effective_cache_size = "4GB";
    };
    # The module default adds md5 host lines; keep only the two local peer lines.
    authentication = lib.mkForce ''
      local all postgres peer map=postgres
      local all all      peer
    '';

    # matrix-synapse is not in ensureDatabases: postgresql-setup would create it with the cluster
    # default before the oneshot below runs. Its role is still ensured here.
    ensureDatabases = lib.remove synapseDb cfg.postgresql;
    ensureUsers =
      map (name: {
        inherit name;
        ensureDBOwnership = name != synapseDb;
      })
      cfg.postgresql;
  };

  # State survives reinstalls: pin the ids (nixpkgs' ids.nix values) so the Data disk stays valid.
  users.users.postgres.uid = 71;
  users.groups.postgres.gid = 71;
  assertions = [
    {
      assertion = config.ids.uids.postgres == 71 && config.ids.gids.postgres == 71;
      message = "nixpkgs changed the postgres uid/gid; /state/postgresql is owned by 71:71";
    }
  ];

  # The module only creates a data directory below /var/lib. Done in a unit that needs the Data disk
  # instead of tmpfiles, which would run (and fail on the immutable /state) when the disk is missing.
  systemd.services.postgresql-state-dir = {
    description = "PostgreSQL data directory in /state";
    requiredBy = ["postgresql.service"];
    before = ["postgresql.service"];
    unitConfig.RequiresMountsFor = ["/state"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -o postgres -g postgres -m 0700 ${stateDir} ${pgCfg.dataDir}
    '';
  };
  systemd.services.postgresql.unitConfig.RequiresMountsFor = ["/state"];

  systemd.services.postgresql-synapse-db = {
    description = "Create the matrix-synapse database with C collation";
    after = ["postgresql-setup.service"];
    requires = ["postgresql-setup.service"];
    wantedBy = ["postgresql.target"];
    before = ["postgresql.target"];
    path = [pgCfg.finalPackage];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      Group = "postgres";
    };
    script = ''
      db=${synapseDb}
      if [ -z "$(psql -d postgres -tAc "select 1 from pg_database where datname = '$db'")" ]; then
        psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$db\" OWNER \"$db\" TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER libc LC_COLLATE 'C' LC_CTYPE 'C'"
      fi
      psql -d postgres -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$db\" OWNER TO \"$db\""
      collation="$(psql -d postgres -tAc "select datcollate || '/' || datctype from pg_database where datname = '$db'")"
      if [ "$collation" != "C/C" ]; then
        echo "FATAL: database $db has collation $collation, Synapse needs C/C. Drop it (empty) and restart this unit." >&2
        exit 1
      fi
    '';
  };

  optiplex.stateUnits = ["postgresql" "postgresql-state-dir" "postgresql-synapse-db"];

  optiplex.vmTest.checks.databases-postgresql = {
    phase = "restore";
    tiers = ["hermetic" "rehearsal"];
    script = ''
      psql = "runuser -u postgres -- psql -X -d postgres -tAc"
      assert optiplex.succeed(f"{psql} 'show server_version_num'").strip().startswith("18"), "not PostgreSQL 18"
      # no TCP listener, only local peer lines
      optiplex.fail("ss -ltn | grep -E ':5432\\b'")
      rules = optiplex.succeed(f"{psql} \"select type || ' ' || auth_method from pg_hba_file_rules\"").split("\n")
      assert sorted(r for r in rules if r) == ["local peer", "local peer"], rules
      # builtin C.UTF-8 as the cluster default
      assert optiplex.succeed(f"{psql} \"select datlocprovider::text || ' ' || datlocale from pg_database where datname = 'template1'\"").strip() == "b C.UTF-8"
      # database = role = owner, Synapse is C/C
      for db in ${builtins.toJSON cfg.postgresql}:
          owner = optiplex.succeed(f"{psql} \"select pg_get_userbyid(datdba) from pg_database where datname = '{db}'\"").strip()
          assert owner == db, (db, owner)
      assert optiplex.succeed(f"{psql} \"select datcollate || datctype from pg_database where datname = 'matrix-synapse'\"").strip() == "CC"
      # data directory on the Data disk
      optiplex.succeed("test -f /state/postgresql/18/PG_VERSION && test -f /mnt/tbssd/state/postgresql/18/PG_VERSION")
    '';
  };
}
