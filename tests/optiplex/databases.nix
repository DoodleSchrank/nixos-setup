# Standalone nixosTest of the shared database pieces: checks.x86_64-linux.optiplex-databases
#
# Ticket "Shared PostgreSQL and MariaDB servers". Three nodes:
#   source         PostgreSQL 14 + MariaDB 10.11 holding fixture databases shaped like the live ones
#                  (Synapse C/C owned by synapse_user, en_US bridge DBs owned by postgres with objects of
#                  synapse_user, gitea/paperless owned by superuser-like roles, three utf8mb3 Seafile DBs).
#                  The REAL machines/optiplex/cutover/arch-db-dumps.sh runs on it; only `docker` and
#                  `nsenter` are fakes (containers do not exist here), see fakeBin.
#   optiplex       the real storage.nix + services/databases.nix (postgresql.nix, mariadb.nix) + the vmTest
#                  seam, with a minimal stand-in for the options of machines/optiplex/default.nix, booted in
#                  restoreMode. The Data disk is an ext4 image with the real UUID mounted on /state.
#   seafileclient  an address in the Seafile container subnet, reaches MariaDB over TCP.
# The full-config run (optiplex-vm) runs the same configuration checks through optiplex.vmTest.
{
  pkgs,
  inputs,
}: let
  inherit (pkgs) lib;
  cutover = ../../machines/optiplex/cutover;
  net = {
    lan = "192.168.178";
    seafile = "10.89.29";
  };

  # An ext4 Data disk with the real UUID and an empty state/ directory (as in overlay-hermetic.nix).
  dataDisk = pkgs.runCommand "optiplex-databases-data-disk.img" {nativeBuildInputs = [pkgs.e2fsprogs];} ''
    mkdir -p seed/state
    truncate -s 1G $out
    mkfs.ext4 -q -F -E root_owner=0:0 -U 70ca9b25-a1cd-46fa-bcbd-66780935c999 -L tbssd -d seed $out
  '';

  # `docker` and `nsenter` for the source node: there are no containers, so `docker exec` runs the command
  # on the node (with the container's root password in its environment) and `nsenter --net=...` just drops
  # the namespace argument. Everything the script does with the databases is real.
  fakeBin = pkgs.runCommand "fake-container-tools" {} ''
    mkdir -p $out/bin
    cat > $out/bin/docker <<'EOF'
    #!${pkgs.bash}/bin/bash
    case "$1" in
      inspect) echo 4242 ;;
      ps) cat /run/fake-docker-ps ;;
      exec)
        shift
        [ "$1" = -i ] && shift
        shift # container name
        MYSQL_ROOT_PASSWORD=fixture-root-password exec "$@" ;;
      *) echo "fake docker: $*" >&2; exit 1 ;;
    esac
    EOF
    cat > $out/bin/nsenter <<'EOF'
    #!${pkgs.bash}/bin/bash
    shift # --net=/proc/<pid>/ns/net
    exec "$@"
    EOF
    chmod +x $out/bin/*
  '';

  # Stand-in for the options machines/optiplex/default.nix declares (that file imports the whole host).
  baseShim = {
    config,
    lib,
    pkgs,
    ...
  }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../machines/optiplex/storage.nix
      ../../machines/optiplex/vm-test.nix
      ../../machines/optiplex/services/databases.nix
    ];
    options.optiplex = {
      restoreMode = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      stateUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
      secretsDir = lib.mkOption {
        type = lib.types.path;
        default = ../../secrets/test/optiplex;
      };
    };
    config = {
      # the test mirror decrypts with the public test age key (as tests/optiplex/test-secrets.nix)
      sops.age.keyFile = "/run/test-age-key.txt";
      sops.age.sshKeyPaths = lib.mkForce [];
      sops.gnupg.sshKeyPaths = [];
      sops.defaultSopsFormat = "yaml";
      system.activationScripts.testAgeKey = lib.stringAfter ["specialfs"] ''
        install -m 0400 ${../../secrets/test/age-key.txt} /run/test-age-key.txt
      '';
      system.activationScripts.setupSecrets.deps = ["testAgeKey"];
      system.stateVersion = "26.11";
    };
  };

  vlanNode = {vlan, address}: {
    virtualisation.vlans = lib.mkForce [];
    virtualisation.interfaces.eth1.vlan = vlan;
    networking.interfaces.eth1.ipv4.addresses = [{inherit address; prefixLength = 24;}];
  };
in
  (import (pkgs.path + "/nixos/lib") {}).runTest ({config, ...}: {
    hostPkgs = pkgs;
    name = "optiplex-databases";
    defaults.nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;

    nodes.source = {pkgs, ...}: {
      imports = [(vlanNode {vlan = 1; address = "${net.lan}.30";})];
      networking.firewall.enable = false;
      i18n.supportedLocales = ["en_US.UTF-8/UTF-8" "C.UTF-8/UTF-8"];
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_14;
        # the containers' local trust lines
        authentication = lib.mkForce ''
          local all all trust
          host all all 127.0.0.1/32 trust
        '';
      };
      services.mysql = {
        enable = true;
        package = pkgs.mariadb_1011;
      };
      environment.systemPackages = [pkgs.python3 pkgs.util-linux];
      virtualisation.memorySize = 2048;
    };

    nodes.optiplex = {
      config,
      lib,
      pkgs,
      ...
    }: {
      imports = [baseShim];
      optiplex.restoreMode = lib.mkOverride 90 true;
      # the deploy that follows the restore
      specialisation.normal.configuration.optiplex.restoreMode = lib.mkOverride 80 false;

      virtualisation.fileSystems = config.optiplex.dataFileSystems;
      virtualisation.qemu.drives = [
        {
          name = "data";
          file = "${dataDisk}";
          driveExtraOpts = {
            format = "raw";
            snapshot = "on";
          };
          deviceExtraOpts.serial = "tbssd";
        }
      ];
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;

      # eth1: the LAN, eth2: the Seafile container network (the interface name is the option)
      virtualisation.vlans = lib.mkForce [];
      virtualisation.interfaces = {
        eth1.vlan = 1;
        eth2.vlan = 2;
      };
      networking.interfaces.eth1.ipv4.addresses = [{address = "${net.lan}.20"; prefixLength = 24;}];
      networking.interfaces.eth2.ipv4.addresses = [{address = "${net.seafile}.1"; prefixLength = 24;}];
      networking.nftables.enable = true;
      networking.firewall.enable = true;
      optiplex.databases.seafileNetwork.interface = "eth2";

      # the service users (their own modules are not in this test) and the Unix users of the peer check
      users.users = lib.genAttrs ["matrix-synapse" "mautrix-whatsapp" "mautrix-telegram" "gitea" "paperless"] (name: {
        isSystemUser = true;
        group = name;
      });
      users.groups = lib.genAttrs ["matrix-synapse" "mautrix-whatsapp" "mautrix-telegram" "gitea" "paperless"] (_: {});
      environment.systemPackages = [pkgs.curl pkgs.mariadb_114];
      environment.etc."optiplex-restore-mode".text = if config.optiplex.restoreMode then "1" else "0";
    };

    nodes.seafileclient = {pkgs, ...}: {
      virtualisation.vlans = lib.mkForce [];
      virtualisation.interfaces.eth1.vlan = 2;
      networking.interfaces.eth1.ipv4.addresses = [{address = "${net.seafile}.2"; prefixLength = 24;}];
      environment.systemPackages = [pkgs.mariadb_114 pkgs.netcat];
    };

    testScript = {nodes, ...}: let
      vmChecks = nodes.optiplex.optiplex.vmTest.checks;
      tl = import ./lib.nix {inherit lib;};
      pg18 = pkgs.postgresql_18;
      archEnv = "PATH=${fakeBin}/bin:$PATH PG_DUMP=${pg18}/bin/pg_dump PSQL=${pg18}/bin/psql PG_RESTORE=${pg18}/bin/pg_restore";
      dumpScript = "${pkgs.bash}/bin/bash ${cutover}/arch-db-dumps.sh";
    in ''
      import re

      start_all()
      source.wait_for_unit("postgresql.service")
      source.wait_for_unit("mysql.service")
      optiplex.wait_for_unit("multi-user.target")
      optiplex.wait_for_unit("postgresql.target")
      seafileclient.wait_for_unit("multi-user.target")

      def sudo_psql(machine, db, sql, user="postgres", extra=""):
          return machine.succeed(f"runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -U {user} -d {db} {extra} -tA <<'SQL'\n{sql}\nSQL")

      # ------------------------------------------------------------------------------------------
      # the target side, as installed in restoreMode
      # ------------------------------------------------------------------------------------------
      ${tl.subtest "restoreMode install: PostgreSQL 18 settings, roles and databases" vmChecks.databases-postgresql.script}
      ${tl.subtest "restoreMode install: MariaDB 11.4, Seafile databases and account" vmChecks.databases-mariadb.script}

      with subtest("peer authentication: a role is reachable by its own Unix user only, no TCP"):
          optiplex.succeed("runuser -u gitea -- psql -d gitea -c 'select 1'")
          optiplex.fail("runuser -u paperless -- psql -U gitea -d gitea -c 'select 1'")
          optiplex.fail("psql -h 127.0.0.1 -U gitea -d gitea -c 'select 1'")
          optiplex.fail("runuser -u gitea -- psql -d paperless -c 'create table x (a int)'")

      with subtest("the Synapse oneshot refuses a database with another collation"):
          optiplex.succeed("systemctl is-active postgresql-synapse-db.service")
          sudo_psql(optiplex, "postgres", 'DROP DATABASE "matrix-synapse"')
          sudo_psql(optiplex, "postgres", """CREATE DATABASE "matrix-synapse" OWNER "matrix-synapse" TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER libc LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8'""")
          optiplex.fail("systemctl restart postgresql-synapse-db.service")
          optiplex.succeed("journalctl -u postgresql-synapse-db.service | grep -q 'needs C/C'")
          sudo_psql(optiplex, "postgres", 'DROP DATABASE "matrix-synapse"')
          optiplex.succeed("systemctl restart postgresql-synapse-db.service")
          assert sudo_psql(optiplex, "postgres", "select datcollate || datctype from pg_database where datname = 'matrix-synapse'").strip() == "CC"

      with subtest("MariaDB: TCP only from the container network, only on the container interface"):
          optiplex.succeed("test -s /run/secrets/mariadb_seafile_password")
          pw = optiplex.succeed("cat /run/secrets/mariadb_seafile_password").strip()
          assert re.fullmatch("[A-Za-z0-9]+", pw), "test password is not alphanumeric"
          # listening on all addresses ...
          optiplex.succeed("ss -ltn | grep -E '0\\.0\\.0\\.0:3306'")
          # ... reachable from the container subnet with the account ...
          cli = f"MYSQL_PWD={pw} mariadb -h ${net.seafile}.1 -P 3306 -u seafile"
          seafileclient.succeed(f"{cli} ccnet_db -e 'select 1'")
          seafileclient.succeed(f"{cli} seahub_db -e 'create table t (a int); drop table t'")
          # ... but only its three databases, and only with the right password
          seafileclient.fail(f"{cli} mysql -e 'select 1'")
          seafileclient.fail("MYSQL_PWD=wrong mariadb -h ${net.seafile}.1 -u seafile ccnet_db -e 'select 1'")
          # the account's host part is the subnet: not from loopback on the host
          optiplex.fail(f"MYSQL_PWD={pw} mariadb -h 127.0.0.1 -u seafile ccnet_db -e 'select 1'")
          # the LAN interface drops 3306, while the listener exists
          source.fail("timeout 5 bash -c 'echo > /dev/tcp/${net.lan}.20/3306'")
          seafileclient.succeed("timeout 5 bash -c 'echo > /dev/tcp/${net.seafile}.1/3306'")
          rules = optiplex.succeed("nft list ruleset")
          assert re.search(r'iifname "eth2".*3306', rules), rules
          assert not re.search(r'iifname "eth1".*3306', rules), rules
          assert not re.search(r'(?m)^\s+tcp dport .*3306 accept', rules), rules

      with subtest("password rotation: the setup oneshot re-applies a changed password"):
          optiplex.succeed("systemctl restart mariadb-seafile-setup.service")
          seafileclient.succeed(f"{cli} ccnet_db -e 'select 1'")

      # ------------------------------------------------------------------------------------------
      # the source side: fixtures shaped like the live databases, then the real Arch dump script
      # ------------------------------------------------------------------------------------------
      with subtest("source fixtures"):
          source.succeed("""runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres <<'SQL'
      create role synapse_user login;
      create role gitea superuser login;
      create role paperless superuser login;
      create database synapse owner synapse_user template template0 encoding 'UTF8' lc_collate 'C' lc_ctype 'C';
      create database whatsapp template template0 encoding 'UTF8' lc_collate 'en_US.UTF-8' lc_ctype 'en_US.UTF-8';
      create database telegram template template0 encoding 'UTF8' lc_collate 'en_US.UTF-8' lc_ctype 'en_US.UTF-8';
      create database gitea owner gitea;
      create database paperless owner paperless;
      SQL""")
          source.succeed("""runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -U synapse_user -d synapse <<'SQL'
      create table events (stream_ordering bigserial primary key, room_id text not null, body text, payload bytea);
      insert into events (room_id, body, payload) select '!room' || (g % 50) || ':nnik.dev', 'Grüße ' || g, decode(md5(g::text), 'hex') from generate_series(1, 60000) g;
      create index events_room on events (room_id);
      create table state_groups_state (state_group bigint, type text, state_key text, event_id text);
      insert into state_groups_state select g % 1000, 'm.room.member', '@u' || g || ':nnik.dev', '$e' || g from generate_series(1, 120000) g;
      create table words (w text);
      insert into words values ('a'), ('B'), ('Z'), ('ä');
      create view recent_events as select * from events where stream_ordering > 59000;
      create function room_count() returns bigint language sql as 'select count(distinct room_id) from events';
      SQL""")
          for db in ("whatsapp", "telegram"):
              source.succeed(f"""runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d {db} <<'SQL'
      grant all on schema public to synapse_user;
      SQL""")
              source.succeed(f"""runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -U synapse_user -d {db} <<'SQL'
      create table crypto_account (account_id text primary key, account bytea not null, key_backup_version text);
      insert into crypto_account select 'acc' || g, decode(md5(g::text) || md5(g::text), 'hex'), null from generate_series(1, 200) g;
      create table portal (id bigint generated always as identity primary key, mxid text unique, meta jsonb);
      insert into portal (mxid, meta) select '!p' || g || ':nnik.dev', jsonb_build_object('n', g, 'name', 'Gruppe ' || g) from generate_series(1, 3000) g;
      create type portal_kind as enum ('dm', 'group');
      alter table portal add column kind portal_kind default 'dm';
      SQL""")
          source.succeed("""runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -U gitea -d gitea <<'SQL'
      create table repository (id bigserial primary key, owner text, name text);
      insert into repository (owner, name) select 'Yannik', 'repo' || g from generate_series(1, 500) g;
      create table action_run_job (id bigserial primary key, log text);
      insert into action_run_job (log) select repeat('x', 100) from generate_series(1, 2000);
      SQL""")
          source.succeed("""runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -U paperless -d paperless <<'SQL'
      create extension pg_trgm;
      create table documents_document (id serial primary key, title text, content text);
      insert into documents_document (title, content) select 'Rechnung ' || g, 'Inhalt ' || g from generate_series(1, 300) g;
      create index doc_title_trgm on documents_document using gin (title gin_trgm_ops);
      SQL""")
          source.succeed("""mysql -uroot <<'SQL'
      alter user root@localhost identified via mysql_native_password using password('fixture-root-password');
      flush privileges;
      SQL""")
          source.succeed("""MYSQL_PWD=fixture-root-password mariadb -uroot <<'SQL'
      create database ccnet_db character set utf8mb3 collate utf8mb3_general_ci;
      create database seafile_db character set utf8mb3 collate utf8mb3_general_ci;
      create database seahub_db character set utf8mb3 collate utf8mb3_general_ci;
      use ccnet_db;
      create table EmailUser (id int auto_increment primary key, email varchar(255), passwd varchar(256), is_staff bool) engine=InnoDB;
      insert into EmailUser (email, passwd, is_staff) values ('yannik@nnik.dev', 'x', 1), ('müller@nnik.dev', 'y', 0);
      use seafile_db;
      create table Branch (id int auto_increment primary key, name varchar(10), repo_id char(41), commit_id char(41), unique key (repo_id, name)) engine=InnoDB;
      create table Blobs (id int auto_increment primary key, data blob) engine=InnoDB;
      insert into Blobs (data) values (unhex('00ff10fe')), (repeat(char(200), 100));
      create table Audit (id int auto_increment primary key, note varchar(50)) engine=InnoDB;
      create trigger audit_branch after insert on Branch for each row insert into Audit (note) values (concat('branch ', new.name));
      insert into Branch (name, repo_id, commit_id) select seq, uuid(), uuid() from seq_1_to_500;
      use seahub_db;
      create table auth_user (id int auto_increment primary key, username varchar(150) unique) engine=InnoDB;
      create table profile (id int auto_increment primary key, user_id int, nickname varchar(64), constraint fk_user foreign key (user_id) references auth_user (id)) engine=InnoDB;
      insert into auth_user (username) select concat('u', seq, '@nnik.dev') from seq_1_to_3000;
      insert into profile (user_id, nickname) select id, concat('Nick ', id) from auth_user;
      SQL""")

      with subtest("arch-db-dumps.sh: dry run lists the eight pairs, touches nothing"):
          out = source.succeed("${dumpScript} --dry-run")
          print(out)
          assert len([l for l in out.splitlines() if "->" in l and not l.startswith("#")]) == 8, out
          source.fail("test -e /var/cutover")

      with subtest("arch-db-dumps.sh: --final refuses while a consumer runs, the DB containers do not count"):
          source.succeed("printf 'gitea-db-1\\npaperless-db-1\\nseafile-mysql\\npaperless-redis-1\\ngitea\\n' > /run/fake-docker-ps")
          rc, out = source.execute("${archEnv} ${dumpScript} --final --out-root /var/cutover 2>&1")
          assert rc != 0 and "container gitea" in out, out
          source.fail("test -e /var/cutover")
          source.succeed("printf 'gitea-db-1\\npaperless-db-1\\nseafile-mysql\\npaperless-redis-1\\n' > /run/fake-docker-ps")

      with subtest("arch-db-dumps.sh --final writes the dump layout"):
          out = source.succeed("${archEnv} ${dumpScript} --final --out-root /var/cutover 2>&1")
          print(out)
          ts = source.succeed("ls /var/cutover").strip()
          assert re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", ts), ts
          d = f"/var/cutover/{ts}"
          for n in ("matrix-synapse", "mautrix-whatsapp", "mautrix-telegram", "gitea", "paperless"):
              source.succeed(f"test -s {d}/postgresql/{n}.dump && test -s {d}/counts/{n}.tsv")
              source.succeed(f"${pg18}/bin/pg_restore -l {d}/postgresql/{n}.dump >/dev/null")
          for n in ("ccnet_db", "seafile_db", "seahub_db"):
              source.succeed(f"test -s {d}/mariadb/{n}.sql && test -s {d}/counts/{n}.tsv")
              source.fail(f"grep -E 'CREATE DATABASE|^USE ' {d}/mariadb/{n}.sql")
              source.succeed(f"grep -q 'Dump completed' {d}/mariadb/{n}.sql")
          source.succeed(f"grep -q '^# mode: final' {d}/MANIFEST && grep -q 'matrix-synapse.dump' {d}/MANIFEST")
          source.succeed(f"cd {d} && grep -Ev '^(#|$)' MANIFEST | sha256sum --check --quiet --strict -")
          # the password of the container never reached the output
          source.fail(f"grep -r fixture-root-password {d}")
          print(source.succeed(f"cat {d}/counts/matrix-synapse.tsv {d}/counts/seafile_db.tsv"))
          source.succeed(f"cd /var/cutover && tar cf /tmp/dumps.tar {ts}")
          source.succeed("cd /tmp && (setsid python3 -m http.server 8000 >/dev/null 2>&1 &)")
          source.wait_until_succeeds("curl -fsI http://127.0.0.1:8000/dumps.tar")

      # ------------------------------------------------------------------------------------------
      # the restore
      # ------------------------------------------------------------------------------------------
      with subtest("the dump reaches the host"):
          optiplex.succeed("mkdir -p /var/tmp/cutover && curl -fsS http://${net.lan}.30:8000/dumps.tar | tar -x -C /var/tmp/cutover")
          optiplex.succeed("chmod -R go-rwx /var/tmp/cutover")  # private, as written on Arch: the script must cope
      d = f"/var/tmp/cutover/{ts}"
      restore = f"optiplex-db-restore {d}"

      with subtest("optiplex-db-restore --help is the procedure"):
          out = optiplex.succeed("optiplex-db-restore --help")
          assert "restoreMode" in out and "--reset" in out and "Synapse last" in out, out

      with subtest("refuses a dump whose checksums do not match"):
          optiplex.succeed(f"cp -r {d} /var/tmp/tampered && chmod -R u+w /var/tmp/tampered")
          optiplex.succeed("printf X >> /var/tmp/tampered/postgresql/gitea.dump")
          rc, out = optiplex.execute("optiplex-db-restore /var/tmp/tampered 2>&1")
          assert rc != 0 and "checksums do not match" in out, out
          optiplex.succeed("rm -rf /var/tmp/tampered")
          # nothing was touched
          assert sudo_psql(optiplex, "gitea", "select count(*) from pg_class where relkind = 'r' and relnamespace = 'public'::regnamespace").strip() == "0"

      with subtest("refuses to run while a consumer unit is active"):
          optiplex.succeed("systemd-run --unit=gitea sleep infinity")
          rc, out = optiplex.execute(f"{restore} 2>&1")
          assert rc != 0 and "consumer units are active" in out and "gitea.service" in out, out
          rc, out = optiplex.execute("optiplex-db-restore --reset gitea 2>&1")
          assert rc != 0 and "consumer units are active" in out, out
          optiplex.succeed("systemctl stop gitea.service")

      with subtest("restores every fixture database, verifies it and times it"):
          out = optiplex.succeed(f"{restore} 2>&1")
          print(out)
          assert "pg_restore failed" not in out
          assert len(re.findall("row counts match", out)) == 8, out
          assert len(re.findall("every object is owned by role", out)) == 5, out
          assert "still C/C" in out
          for db in ("matrix-synapse", "mautrix-whatsapp", "mautrix-telegram", "gitea", "paperless", "ccnet_db", "seafile_db", "seahub_db"):
              assert re.search(rf"{db}: restored in [0-9]+ s", out), (db, out)
          assert re.search(r"(?m)^   matrix-synapse +[0-9]+ s$", out), out
          # small databases first, Synapse last of the PostgreSQL ones
          order = [m for m in re.findall(r"([\w-]+): restored in", out)]
          assert order.index("matrix-synapse") == 4 and order[:4] == ["mautrix-whatsapp", "mautrix-telegram", "gitea", "paperless"], order

      def verify_restored():
          assert sudo_psql(optiplex, "matrix-synapse", "select count(*) from events").strip() == "60000"
          assert sudo_psql(optiplex, "matrix-synapse", "select count(*) from state_groups_state").strip() == "120000"
          # C collation survived: byte order, not locale order
          assert sudo_psql(optiplex, "matrix-synapse", "select string_agg(w, ',' order by w) from words").strip() == "B,Z,a,ä"
          assert sudo_psql(optiplex, "matrix-synapse", "select room_count()").strip() == "50"
          assert sudo_psql(optiplex, "matrix-synapse", "select count(*) from recent_events").strip() == "1000"
          assert sudo_psql(optiplex, "mautrix-whatsapp", "select count(*) from crypto_account").strip() == "200"
          assert sudo_psql(optiplex, "mautrix-telegram", "select count(*) from portal where kind = 'dm'").strip() == "3000"
          # the identity sequence continues after the restored rows
          assert sudo_psql(optiplex, "mautrix-telegram", "select last_value from portal_id_seq").strip() == "3000"
          assert sudo_psql(optiplex, "gitea", "select count(*) from repository").strip() == "500"
          assert sudo_psql(optiplex, "paperless", "select count(*) from documents_document where title like '%Rechnung 1%'").strip() == "111"
          assert sudo_psql(optiplex, "paperless", "select extname from pg_extension where extname = 'pg_trgm'").strip() == "pg_trgm"
          # the service role (and nobody else) owns the restored tables
          for db in ("matrix-synapse", "mautrix-whatsapp", "mautrix-telegram", "gitea", "paperless"):
              owners = sudo_psql(optiplex, db, "select distinct tableowner from pg_tables where schemaname = 'public'").split()
              assert owners == [db], (db, owners)
          sql = "mariadb --protocol=socket -uroot -N -B -e"
          assert optiplex.succeed(f"{sql} 'select count(*) from ccnet_db.EmailUser'").strip() == "2"
          assert optiplex.succeed(f"{sql} \"select email from ccnet_db.EmailUser where email like 'm%'\"").strip() == "müller@nnik.dev"
          assert optiplex.succeed(f"{sql} 'select count(*) from seafile_db.Branch'").strip() == "500"
          assert optiplex.succeed(f"{sql} 'select count(*) from seafile_db.Audit'").strip() == "500"
          assert optiplex.succeed(f"{sql} 'select hex(data) from seafile_db.Blobs where id = 1'").strip() == "00FF10FE"
          assert optiplex.succeed(f"{sql} 'select count(*) from seahub_db.profile'").strip() == "3000"
          cs = optiplex.succeed(f"{sql} \"select distinct table_collation from information_schema.tables where table_schema like '%_db'\"").strip()
          assert cs == "utf8mb3_general_ci", cs

      with subtest("restored data is complete"):
          verify_restored()
          # the trigger survived (--triggers): an insert audits
          optiplex.succeed("mariadb --protocol=socket -uroot -e \"insert into seafile_db.Branch (name, repo_id, commit_id) values ('new', 'r', 'c')\"")
          assert optiplex.succeed("mariadb --protocol=socket -uroot -N -B -e 'select count(*) from seafile_db.Audit'").strip() == "501"
          optiplex.succeed("mariadb --protocol=socket -uroot -e \"delete from seafile_db.Branch where name = 'new'; delete from seafile_db.Audit where note = 'branch new'\"")
          # the Seafile account still reaches the restored data
          seafileclient.succeed(f"{cli} seahub_db -e 'select count(*) from profile'")

      with subtest("a second run refuses non-empty targets"):
          rc, out = optiplex.execute(f"{restore} 2>&1")
          assert rc != 0 and "never restore over data" in out, out
          rc, out = optiplex.execute(f"{restore} --only gitea 2>&1")
          assert rc != 0 and "already contains" in out, out
          rc, out = optiplex.execute(f"{restore} --only seafile_db 2>&1")
          assert rc != 0 and "already contains" in out, out

      with subtest("--reset, then --only restores that database again"):
          optiplex.succeed("optiplex-db-restore --reset gitea")
          assert sudo_psql(optiplex, "gitea", "select count(*) from pg_class where relkind = 'r' and relnamespace = 'public'::regnamespace").strip() == "0"
          assert sudo_psql(optiplex, "postgres", "select pg_get_userbyid(datdba) from pg_database where datname = 'gitea'").strip() == "gitea"
          optiplex.succeed(f"{restore} --only gitea")
          optiplex.succeed("optiplex-db-restore --reset matrix-synapse")
          assert sudo_psql(optiplex, "postgres", "select datcollate || datctype from pg_database where datname = 'matrix-synapse'").strip() == "CC"
          optiplex.succeed("optiplex-db-restore --reset seafile_db")
          assert optiplex.succeed("mariadb --protocol=socket -uroot -N -B -e \"select count(*) from information_schema.tables where table_schema = 'seafile_db'\"").strip() == "0"
          out = optiplex.succeed(f"{restore} --only seafile_db 2>&1")
          assert "row counts match" in out
          out = optiplex.succeed(f"{restore} --only matrix-synapse 2>&1")
          assert "still C/C" in out and "row counts match" in out
          optiplex.fail("optiplex-db-restore --reset nonexistent")
          verify_restored()

      with subtest("a Backup-style directory (no counts, no MANIFEST, compressed SQL) is accepted explicitly"):
          optiplex.succeed("optiplex-db-restore --reset seahub_db")
          optiplex.succeed("mkdir -p /var/tmp/backup")
          optiplex.succeed(f"gzip -c {d}/mariadb/seahub_db.sql > /var/tmp/backup/seahub_db.sql.gz")
          rc, out = optiplex.execute("optiplex-db-restore /var/tmp/backup --only seahub_db 2>&1")
          assert rc != 0 and "no MANIFEST" in out, out
          out = optiplex.succeed("optiplex-db-restore /var/tmp/backup --only seahub_db --no-manifest 2>&1")
          assert "row-count check skipped" in out and "restored in" in out, out
          assert optiplex.succeed("mariadb --protocol=socket -uroot -N -B -e 'select count(*) from seahub_db.profile'").strip() == "3000"

      # ------------------------------------------------------------------------------------------
      # the deploy: restoreMode off
      # ------------------------------------------------------------------------------------------
      with subtest("restoreMode off: the servers keep serving the restored data"):
          optiplex.succeed("test \"$(cat /etc/optiplex-restore-mode)\" = 1")
          rc, out = optiplex.execute("/run/current-system/specialisation/normal/bin/switch-to-configuration test 2>&1")
          print(out)
          assert rc == 0, rc
          optiplex.succeed("test \"$(cat /etc/optiplex-restore-mode)\" = 0")
          verify_restored()
          # restart both: the data is on the Data disk, not in memory
          optiplex.succeed("systemctl restart postgresql.service mysql.service")
          optiplex.wait_for_unit("postgresql.target")
          optiplex.wait_for_unit("mariadb-seafile-setup.service")
          verify_restored()
          # --reset is a restoreMode tool: refused on the running system, nothing dropped
          rc, out = optiplex.execute("optiplex-db-restore --reset gitea 2>&1")
          assert rc != 0 and "only allowed on the restoreMode install" in out, out
          assert sudo_psql(optiplex, "gitea", "select count(*) from repository").strip() == "500"
    '';
  })
