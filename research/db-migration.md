# Database migration into the shared PostgreSQL / MariaDB (Optiplex)

Research for ticket 10 of the Optiplex NixOS migration map. Researched 2026-11-06.
Live facts come from read-only queries on `ssh optiplex`. Sources were pinned at nixpkgs `nixos-unstable` @ `1d060086d60c` and Synapse `develop` @ `4787b424e95e`.

## Question

What's the safest way to land all databases in one shared native PostgreSQL server (one database + role per service) and one shared MariaDB server on NixOS? The sources are:

- Arch-native PostgreSQL 18: Synapse (10 GB) and the bridges, with a glibc collation-version mismatch (2.38 → 2.43).
- Gitea's and Paperless's PostgreSQL 14 containers.
- Seafile's MariaDB 10.11 container and elabFTW's MySQL 8.0 container.

The research covers dump/restore vs `pg_upgrade`, Synapse's `C` collation requirement, mapping roles and ownership to users created by the NixOS module (peer auth), MySQL 8 → MariaDB compatibility, and the expected cutover time for a 10 GB dump.

## Short answer

- **Use logical dump/restore for every database.** Don't use `pg_upgrade` or copy data directories. `pg_upgrade` turns one whole cluster into one new, empty cluster, so it can't merge three clusters into one. The Arch cluster is already on major 18, the same major as nixpkgs' default for new installs, so it doesn't need a major upgrade. A dump also rebuilds every index under NixOS's glibc, which removes the 2.38→2.43 collation mismatch for free.
- **Take each dump with the *newer* `pg_dump` (18), in custom format (`-Fc`).** Run it against the PG14 containers too. Restore with `pg_restore --no-owner --no-acl --role=<new role>` into a database the new role already owns.
- **Create the Synapse database by hand with `LC_COLLATE='C' LC_CTYPE='C'` from `template0`.** `ensureDatabases` can't set a locale; it only runs a plain `CREATE DATABASE`. Synapse refuses to start unless `datcollate` and `datctype` are exactly `C`. The live `synapse` DB is already `C`/`C`, so `pg_restore --create` would also carry that over.
- **Role mapping.** The nixpkgs modules expect a role named after the Unix user, authenticated by peer auth over `/run/postgresql`: `matrix-synapse`, `gitea`, `paperless`, `mautrix-whatsapp`, and so on. Today almost everything is owned by `synapse_user`. With `--no-owner --role=X`, the restored objects belong to X. `ensureDBOwnership` only changes the *database* owner and requires the DB name to equal the role name. The mautrix modules default to DB `mautrix_whatsapp` but user `mautrix-whatsapp`, so either rename the DB or set the owner yourself.
- **Never let a service start against an empty database before its restore.** Synapse, Gitea and Paperless would create a fresh schema, and the restore would then collide with it. Restore first, then start the service. Staging the deploys achieves this: DB servers first, then the apps.
- **MySQL 8 → MariaDB is technically feasible, but elabFTW explicitly does not support MariaDB.** Its docs say an external database "must be MySQL (not MariaDB)". The NixOS `services.mysql` module runs only one server, either MariaDB or MySQL. The "one shared MariaDB" decision therefore conflicts with elabFTW, and the user needs to decide (see options).
- **Version availability.** nixpkgs has `mariadb` = 11.4.13 (11.8 also available) and `mysql84` = 8.4.11. `mysql80` was removed when it reached end of life. Seafile supports both MySQL and MariaDB.
- **Measured cutover time.** `pg_dump -Fc synapse` ran in **136 s** and produced 1.9 GB. The restore is not measured. It has to rebuild 3.7 GB of indexes (331 indexes) on top of 6.6 GB of table data, and one table (`state_groups_state`, 5.6 GB) caps parallelism. Estimate about 10–25 min of restore and about 15–30 min for Synapse end to end. Every other database is under 200 MB and takes seconds. Measure the restore in the VM rehearsal.
- **Drop the stale databases.** Only `synapse`, `whatsapp`, `telegram`, `signal`, `gitea`, `paperless`, `ccnet_db`, `seafile_db`, `seahub_db` and `elabftw` hold live State. `discord`, `matrix`, `nextcloud` and `djangodb` have 0 tables, and `invidious` and `maubot` belong to Retired services. They survive only in the Rollback image.

## Details

### What's on the box today (live, read-only)

Arch-native cluster: `PostgreSQL 18.3`. `pg_hba.conf` is `trust` everywhere. glibc on disk is 2.44, but the running server reports 2.43; it has been up 109 days.

| DB | collate/ctype | collversion | owner (DB / tables) | size | status |
|---|---|---|---|---|---|
| synapse | C / C | – | synapse_user / synapse_user | 10 GB | Kept |
| whatsapp | en_US.UTF-8 | 2.38 | postgres / synapse_user | 161 MB | Kept (bridge) |
| telegram | en_US.UTF-8 | 2.43 | postgres / synapse_user | 79 MB | Kept (bridge) |
| signal | en_US.UTF-8 | 2.38 | postgres / synapse_user | 12 MB | Kept (bridge) |
| maubot, invidious | en_US.UTF-8 | 2.38 | synapse_user, kemal | 16 / 14 MB | Retired |
| discord, matrix, nextcloud, djangodb | en_US.UTF-8 | 2.38 | various | ~8 MB, 0 tables | empty |

Roles: `postgres`, `synapse_user`, `matrix`, `nextcloud`, `kemal` and `djangouser`. **`djangouser` is a superuser.** It should not be carried over.

Synapse's DB holds 6.6 GB of table data and 3.7 GB of indexes in 173 tables and 331 indexes. The largest tables are `state_groups_state` (5.6 GB), `event_json` (1.3 GB) and `events` (584 MB). The only extension is `plpgsql`.

Containers:

- `gitea-db-1`: `postgres:14` (14.23, Debian glibc 2.41). DB `gitea`, owner `gitea` (superuser), en_US.utf8, 132 MB, scram-sha-256.
- `paperless-db-1`: `postgres:14` (14.23). DB `paperless`, owner `paperless`, en_US.utf8, 19 MB.
- `seafile-mysql`: MariaDB 10.11.14. Databases `ccnet_db` (0.4 MB), `seafile_db` (1.5 MB) and `seahub_db` (9.2 MB), all `utf8mb3_general_ci`, InnoDB. User `seafile@%` uses `mysql_native_password`.
- `mysql`: MySQL 8.0.30. DB `elabftw` (4.2 MB), `utf8mb4_0900_ai_ci`, InnoDB, **18 JSON columns**, no routines/triggers/views. User `elabftw@%` uses `mysql_native_password`.

Not in scope here, but worth noting: Vaultwarden runs on **SQLite** today (`/data/db.sqlite3`), even though the stale `machines/server` draft sets `dbBackend = "postgresql"`.

### Dump/restore vs `pg_upgrade` vs copying the data directory

- `pg_upgrade` upgrades *one old cluster* into a freshly `initdb`'d new cluster ("supports upgrades from 9.2.X and later to the current major release") and checks that the two clusters are binary-compatible. [pgupgrade](https://www.postgresql.org/docs/18/pgupgrade.html) It is a cluster-to-cluster tool, so it can't fold the two PG14 container clusters into the Arch cluster. It would also need the Debian PG14 binaries next to the NixOS PG18 binaries.
- Minor releases never change the storage format. Going from 18.3 to nixpkgs' 18.6 by "simply replacing the executables" is therefore supported in principle. [upgrading](https://www.postgresql.org/docs/18/upgrading.html) nixpkgs ships `postgresql_14` … `postgresql_19`, and `postgresql_18` is 18.6. [default.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/servers/sql/postgresql/default.nix#L12-L17), [18.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/servers/sql/postgresql/18.nix#L2) A physical copy of `/var/lib/postgres/data` would bring along the trust `pg_hba`, the superuser `djangouser`, the dead databases, and the en_US indexes built under glibc 2.38/2.43. NixOS unstable ships glibc 2.44. [glibc common.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/development/libraries/glibc/common.nix#L53)
- PostgreSQL recommends the *newer* version's `pg_dump`/`pg_dumpall` for moving data between versions. Current dump programs read from servers back to 9.2. [upgrading](https://www.postgresql.org/docs/18/upgrading.html) The output "can be expected to load into PostgreSQL server versions newer than pg_dump's version", but `pg_dump` refuses to dump from a newer server. [pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html) So use pg_dump 18 against the PG14 containers too, either from the host by connecting to the container's port, or with `docker exec` plus a PG18 client.
- `-Fc` and `-Fd` are compressed and support parallel restore. Only `-Fd` supports parallel *dump* (`-j`). [pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html) `pg_restore -j` works with custom and directory archives, but not together with `--single-transaction`. [pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html)

### Collation-version mismatch and choosing the new cluster's locale

- With libc collations, PostgreSQL records the glibc version as a proxy for the collation version and warns on mismatch. Changed collation definitions "can lead to corrupt indexes". The fix is to REINDEX and then `ALTER DATABASE … REFRESH COLLATION VERSION`. [ALTER COLLATION](https://www.postgresql.org/docs/18/sql-altercollation.html), [ALTER DATABASE](https://www.postgresql.org/docs/18/sql-alterdatabase.html) The PostgreSQL wiki's background on glibc locale changes: [Locale data changes](https://wiki.postgresql.org/wiki/Locale_data_changes).
- A restore into a fresh database builds every index under the new glibc and records the new version. The mismatch therefore disappears with dump/restore and needs no separate REINDEX step. The Synapse DB uses `C`, which is "stable across all versions for a given database encoding" [collation](https://www.postgresql.org/docs/18/collation.html), so it is unaffected either way.
- **The new cluster's default locale is a decision.**
  - The NixOS module runs `initdb -U postgres <initdbArgs>` with no locale flags. [postgresql.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.nix#L765-L781) The cluster locale therefore comes from the service environment: NixOS writes `LANG` into `locale.conf` and puts `LOCALE_ARCHIVE` in systemd's global environment. [i18n.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/config/i18n.nix#L200-L214)
  - `initdb` sets the template databases' locale, which every `CREATE DATABASE` without options inherits. [initdb](https://www.postgresql.org/docs/18/app-initdb.html)
  - The `builtin` provider (PG17+) supports only `C`, `C.UTF-8` and `PG_UNICODE_FAST`. [locale](https://www.postgresql.org/docs/18/locale.html) Its `PG_C_UTF8`/`PG_UNICODE_FAST` behaviour "is efficient and stable within a Postgres major version". [collation](https://www.postgresql.org/docs/18/collation.html)
  - With `--locale-provider=builtin`, `--locale` or `--builtin-locale` must be `C`, `C.UTF-8` or `PG_UNICODE_FAST`. [initdb](https://www.postgresql.org/docs/18/app-initdb.html)

### Synapse: `C` collation, database name, user

- Synapse's docs create the DB with `createdb --encoding=UTF8 --locale=C --template=template0 --owner=synapse_user synapse`. They say a DB with the wrong COLLATE/CTYPE makes Synapse refuse to start unless `allow_unsafe_locale` is set, and that "the safest way to fix the issue is to dump the database and recreate it". [synapse docs/postgres.md](https://github.com/element-hq/synapse/blob/4787b424e95e9ab1a4f7f364af06d3e3b73f47b0/docs/postgres.md#L28-L50), [L255-L269](https://github.com/element-hq/synapse/blob/4787b424e95e9ab1a4f7f364af06d3e3b73f47b0/docs/postgres.md#L255-L269)
- The code compares `pg_database.datcollate` and `datctype` against the literal `"C"`, so `C.UTF-8` fails too. It also requires PostgreSQL ≥ 14 and server encoding `UTF8`. [synapse/storage/engines/postgres.py](https://github.com/element-hq/synapse/blob/4787b424e95e9ab1a4f7f364af06d3e3b73f47b0/synapse/storage/engines/postgres.py#L121-L157)
- The NixOS Synapse docs ask you to run `CREATE ROLE "matrix-synapse"; CREATE DATABASE "matrix-synapse" WITH OWNER "matrix-synapse" TEMPLATE template0 LC_COLLATE = "C" LC_CTYPE = "C";` once, manually, before starting Synapse. [synapse.md](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/synapse.md#L23-L37) The module's defaults are `database.args.database = "matrix-synapse"` and `database.args.user = "matrix-synapse"`. [synapse.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/synapse.nix#L983-L1020)
- `ensureDatabases` only runs `CREATE DATABASE "<name>"` if the database is missing; it has no locale or template options. [postgresql.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.nix#L914-L918) Two ways to create the Synapse DB correctly:
  - Pre-create it as above. Because `ensureDatabases` skips existing names, adding it there afterwards is harmless.
  - Use `pg_restore --create`, which recreates the database under the name and locale stored in the archive (`synapse`, C/C). [pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html) This keeps the old DB name, so set `services.matrix-synapse.settings.database.args.database = "synapse"`.

### Roles, ownership and peer auth on NixOS

- **Default authentication.** The module's default `pg_hba` is `local all postgres peer map=postgres`, `local all all peer`, and `md5` on 127.0.0.1/::1. [postgresql.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.nix#L688-L703) With peer auth, a system user logs in as the database role of the same name, with no secrets. `identMap` handles names that differ, but should never map `all` roles. [postgresql.md](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.md#L62-L71), [L133-L165](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.md#L133-L165)
- **`ensureUsers`.** It runs `CREATE USER "<name>"` (no password). With `ensureDBOwnership = true` it runs `ALTER DATABASE "<name>" OWNER TO "<name>"`, and an assertion requires a database with the same name in `ensureDatabases`. [postgresql.nix L99-L113](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.nix#L99-L113), [L436-L509](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.nix#L436-L509), [L626-L633](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.nix#L626-L633) It never changes **table** owners, which is why the restore must set them.
- **What each service module creates:**
  - Gitea, with `createDatabase` (default `true`): `ensureDatabases = [ "gitea" ]`, user `gitea` with `ensureDBOwnership`, socket `/run/postgresql`. [gitea.nix L186-L211](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/misc/gitea.nix#L186-L211), [L741-L751](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/misc/gitea.nix#L741-L751)
  - Paperless, with `database.createLocally`: DB `paperless`, user `paperless` with `ensureDBOwnership`, `PAPERLESS_DBHOST=/run/postgresql`. [paperless.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/misc/paperless.nix#L514-L531)
  - mautrix-whatsapp/-signal: their example URIs use DBs `mautrix_whatsapp`/`mautrix_signal` and run as system users `mautrix-whatsapp`/`mautrix-signal` (hyphen ≠ underscore). [mautrix-whatsapp.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/mautrix-whatsapp.nix#L95-L99), [L161](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/mautrix-whatsapp.nix#L161), [mautrix-signal.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/mautrix-signal.nix#L92-L95) Their state questions belong to ticket 08.
- **Restoring onto the new role.**
  - `pg_restore -O/--no-owner` skips `ALTER OWNER`, so "this user will own all the created objects" (the connecting user). `--role=rolename` issues `SET ROLE` after connecting, which lets the `postgres` superuser restore *as* the service role. `-x/--no-acl` skips the GRANTs that reference old roles. [pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html)
  - In PG15+, only the database owner can create in `public` by default. [nixpkgs postgresql.md](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.md#L47-L60) This favours making the service role the DB owner *before* the restore, which is what `ensureDBOwnership` does.
  - Recipe per DB: `pg_restore -U postgres -d <db> --no-owner --no-acl --role=<svc> -j4 <dump>`. Do not dump or restore globals with `pg_dumpall --globals-only`: the new roles come from Nix, and the old roles (`synapse_user`, superuser `djangouser`, ...) should not come back. [pg_dumpall](https://www.postgresql.org/docs/18/app-pg-dumpall.html)
- **Ordering hazard.** `ensure*` runs in `postgresql-setup.service`, and the docs tell consumers to order after `postgresql.target`. [postgresql.md L104-L131](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.md#L104-L131) Nothing stops Synapse, Gitea or Paperless from starting on first boot and migrating an *empty* schema into the new DB. Restore before those units first start, or drop and recreate the DB before restoring.
- **Package version.** The PostgreSQL package defaults by `system.stateVersion`: ≥ 26.11 gives `postgresql_18`, ≥ 25.11 gives `postgresql_17`, and so on. The NixOS docs recommend pinning `services.postgresql.package` explicitly, because major upgrades are manual (`pg_upgrade` script). The default data dir is `/var/lib/postgresql/<psqlSchema>`. [postgresql.nix L655-L686](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.nix#L655-L686), [postgresql.md L15-L45, L167-L232](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.md#L15-L45) The stale `machines/server/services/postgres.nix` draft pins `postgresql_15` with `trust` auth and a `nixcloud` initialScript. All three should go.

### MariaDB / MySQL

- **One server only.** `services.mysql` is a single server; `package` has no default ("MariaDB packages are supported too"). `ensureUsers` creates `'<name>'@'localhost' IDENTIFIED WITH unix_socket` on MariaDB (`auth_socket` on MySQL), with no password, and `ensureDatabases` runs `CREATE DATABASE IF NOT EXISTS`. [mysql.nix L73-L79](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/mysql.nix#L73-L79), [L265-L277](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/mysql.nix#L265-L277), [L700-L715](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/mysql.nix#L700-L715)
- **Available versions.** nixpkgs ships `mariadb_106/1011/114/118` (11.4.13, 11.8.8) with `mariadb = mariadb_114`. [mariadb default.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/servers/sql/mariadb/default.nix#L416-L433), [all-packages.nix L7145](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/top-level/all-packages.nix#L7145) MySQL is `mysql84` 8.4.11 only; `mysql80` "reached end of life on 2026-04-30 and has been removed". [mysql84](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/by-name/my/mysql84/package.nix#L32), [aliases.nix L1884](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/top-level/aliases.nix#L1884)
- **elabFTW needs MySQL.** "If you use an existing database service instead of the bundled container, it must be MySQL (not MariaDB)." [elabFTW prerequisites](https://doc.elabftw.net/docs/install/prerequisites/) Its current compose example uses `mysql:8.4` and links a doc on fixing `mysql_native_password` after the 8.0→8.4 upgrade. [docker-compose.yml-EXAMPLE](https://github.com/elabftw/elabftw/blob/cd78043e2e6cdf7c525e3e5560d2628cff62e114/containers/elabimg/docker-compose.yml-EXAMPLE#L381-L387)
- **MySQL 8.4 changes.** Upgrades from 8.0 are supported. [What's new in 8.4](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html) `mysql_native_password` is disabled by default in 8.4, with the default plugin now `caching_sha2_password`. [Oracle MySQL docs: major version upgrade](https://docs.oracle.com/en-us/iaas/mysql-database/doc/major-version-upgrade.html)
- **Seafile works with either.** Seafile "supports MySQL and MariaDB" and "uses the mysql_native_password plugin for authentication". [Seafile manual](https://manual.seafile.com/latest/setup_binary/installation/)
- **If elabFTW's data went into MariaDB anyway, technically:**
  - MariaDB ≥ 11.4.5 accepts MySQL's `utf8mb4_0900_*` collations as aliases of its `uca1400` collations (MDEV-20912). Before that, imports fail with "Unknown collation utf8mb4_0900_ai_ci". [MDEV-20912](https://jira.mariadb.org/browse/MDEV-20912)
  - MariaDB's `JSON` is an alias for `LONGTEXT COLLATE utf8mb4_bin` with an automatic `JSON_VALID` CHECK, added so MariaDB can read MySQL dumps. [MariaDB JSON](https://mariadb.com/docs/server/reference/data-types/string-data-types/json)
  - MariaDB recommends MariaDB 11.8 LTS (or 12.3) when coming from MySQL 8.0/8.4. Dump with MySQL's own `mysqldump --databases … --single-transaction --routines --events --triggers --hex-blob`, never `--all-databases`, and recreate users rather than copying `mysql.*`. [MariaDB master migration guide](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/migrating-to-mariadb/moving-from-mysql/mysql-to-mariadb-migration-the-master-guide)
- **Seafile 10.11 → 11.x.** About 11 MB of `utf8mb3` InnoDB with no routines. A `mariadb-dump --databases ccnet_db seafile_db seahub_db --single-transaction` loads into a fresh 11.4/11.8 server. The dump carries explicit charsets, so the server's newer defaults don't change existing tables.
- **Passwords vs sockets.** The `seafile@%` and `elabftw@%` users authenticate with passwords over TCP today. Native services running as the same-named Unix user can use socket auth instead. Anything that stays in a container, or connects over TCP, needs a password user, and `ensureUsers` can't create one.

### Cutover time

- **Dump, measured:** `pg_dump -Fc -d synapse` (gzip default) to a pipe took **136 s** and produced **1.9 GB**, on an i5-10500T with a KIOXIA NVMe, under normal load. Dumps must land on the Data disk (`/mnt/tbssd`, ext4, 725 GB free), because the System disk is wiped. All the other databases together are about 450 MB and take seconds.
- **Restore, estimated, not measured:**
  - The restore loads 6.6 GB of table data and then builds 3.7 GB of indexes (331 indexes) and the constraints.
  - `pg_restore -j N` parallelises across tables, but the 5.6 GB `state_groups_state` table and its index form a serial critical path.
  - PostgreSQL's bulk-load advice: raise `maintenance_work_mem` (speeds up `CREATE INDEX` and foreign keys) and `max_wal_size` (fewer checkpoints) temporarily. The live server runs 64 MB and 1 GB. Use `wal_level=minimal` if nothing replicates. [Populating a database](https://www.postgresql.org/docs/18/populate.html)
  - Expect roughly **10–25 min** for Synapse, so about **15–30 min of DB work** in the cutover window.
- **Rehearse.** Run the real `pg_restore` of the 1.9 GB archive in the VM test, or on a scratch NixOS, with the same flags. That turns the estimate into a number and catches role and locale errors before Cutover day.
- **Optional, outside this ticket:** shrinking `state_groups_state` before Cutover (Synapse state compression or history purge) would reduce both numbers. That belongs to ticket 08.

## Options / trade-offs

**A. Default locale of the new PostgreSQL cluster** (Synapse is always explicitly `C`):

1. `en_US.UTF-8` libc, the same as today. Sorting is natural-language for Gitea and Paperless. Each glibc bump on nixos-unstable can trigger mismatch warnings and need REINDEX + REFRESH again; this is the problem being fixed now.
2. `initdbArgs = [ "--encoding=UTF8" "--locale-provider=builtin" "--builtin-locale=C.UTF-8" ]` plus a libc `--locale=C`. Stable across glibc bumps (stable within a PG major). Text sorts by code point, so case and accent ordering in Gitea/Paperless lists may change. This only affects sorting done in SQL.
3. Cluster-wide `--locale=C`. Simplest. Synapse then needs no special handling, but sorting behaves as in option 2.

**B. Creating the Synapse DB:**

1. Rename it to the module default `matrix-synapse`: pre-create it with C locale, then `pg_restore --no-owner --role=matrix-synapse`. Zero non-default Synapse DB settings.
2. Keep the name `synapse`: `pg_restore --create`, then `ALTER DATABASE … OWNER`, and set `database.args.database`. Fewer manual steps, one non-default setting.

**C. Staging the restore so no service sees an empty DB:**

1. Two deploys: (a) DB servers plus the `ensure*` users only, then restore, then (b) the full config.
2. One deploy with the app services' `wantedBy` gated (or units masked) until the restores finish.
3. Restore over whatever the first boot created, using `pg_restore --clean --create`. Riskier with apps already connected.

**D. elabFTW vs "one shared MariaDB":**

1. A single **MySQL 8.4** server (`services.mysql.package = pkgs.mysql84`) for both Seafile and elabFTW. Supported by both apps. This is a change from the "MariaDB" decision, and `mysql_native_password` may need re-enabling for Seafile.
2. A single **MariaDB 11.4/11.8** for both, running elabFTW on an unsupported database. Technically importable (0900 collation aliases, JSON as LONGTEXT), but elabFTW upstream won't help with bugs.
3. MariaDB natively for Seafile, and elabFTW keeps its own MySQL 8.4 in an OCI container next to its app container. elabFTW ships only as a container (ticket 05). This breaks "no Docker" for that one app.
4. A second, hand-written systemd MySQL instance next to `services.mysql`. Possible, but not covered by a module.

**E. Moving the Arch PG18 cluster:** logical (recommended above, fixes collation and role clutter) vs a physical copy of the data dir (same major, faster in theory, keeps every legacy problem). Given 136 s for the dump, speed doesn't argue for the physical copy.

## Open questions

- Option A (cluster locale) and option D (elabFTW's database) need Yannik's decision. D interacts with ticket 05 (how elabFTW runs) and ticket 04 (how Seafile runs).
- The restore time is estimated, not measured. Measure it during the VM-test rehearsal.
- The bridge DB names and roles (`whatsapp` → `mautrix_whatsapp`/`mautrix-whatsapp`?), and whether mautrix-telegram even stays on Postgres in the Go rewrite, depend on ticket 08.
- Vaultwarden is on SQLite today. Keep SQLite (no DB migration at all) or move it to Postgres (needs a third-party conversion)? Not covered here.
- Does anything other than these services read the old Arch PostgreSQL (e.g. Own apps)? The table owners suggest not, but this wasn't verified.

## Sources

- PostgreSQL 18 docs: [pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html), [pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html), [pg_dumpall](https://www.postgresql.org/docs/18/app-pg-dumpall.html), [pg_upgrade](https://www.postgresql.org/docs/18/pgupgrade.html), [Upgrading](https://www.postgresql.org/docs/18/upgrading.html), [initdb](https://www.postgresql.org/docs/18/app-initdb.html), [Locale support](https://www.postgresql.org/docs/18/locale.html), [Collation support](https://www.postgresql.org/docs/18/collation.html), [ALTER COLLATION](https://www.postgresql.org/docs/18/sql-altercollation.html), [ALTER DATABASE](https://www.postgresql.org/docs/18/sql-alterdatabase.html), [Populating a database](https://www.postgresql.org/docs/18/populate.html), [Template databases](https://www.postgresql.org/docs/18/manage-ag-templatedbs.html); [wiki: Locale data changes](https://wiki.postgresql.org/wiki/Locale_data_changes)
- nixpkgs @ 1d060086: [postgresql.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.nix), [postgresql.md](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/postgresql.md), [mysql.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/databases/mysql.nix), [synapse.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/synapse.nix), [synapse.md](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/synapse.md), [gitea.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/misc/gitea.nix), [paperless.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/misc/paperless.nix), [mautrix-whatsapp.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/mautrix-whatsapp.nix), [mautrix-signal.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/services/matrix/mautrix-signal.nix), [i18n.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/nixos/modules/config/i18n.nix), [postgresql default.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/servers/sql/postgresql/default.nix), [mariadb default.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/servers/sql/mariadb/default.nix), [mysql84](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/by-name/my/mysql84/package.nix), [aliases.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/top-level/aliases.nix), [glibc common.nix](https://github.com/NixOS/nixpkgs/blob/1d060086d60cb76a40cf37109f979d88a5bd6396/pkgs/development/libraries/glibc/common.nix)
- Synapse @ 4787b424: [docs/postgres.md](https://github.com/element-hq/synapse/blob/4787b424e95e9ab1a4f7f364af06d3e3b73f47b0/docs/postgres.md), [synapse/storage/engines/postgres.py](https://github.com/element-hq/synapse/blob/4787b424e95e9ab1a4f7f364af06d3e3b73f47b0/synapse/storage/engines/postgres.py)
- MariaDB: [MDEV-20912](https://jira.mariadb.org/browse/MDEV-20912), [JSON data type](https://mariadb.com/docs/server/reference/data-types/string-data-types/json), [MySQL → MariaDB master guide](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/migrating-to-mariadb/moving-from-mysql/mysql-to-mariadb-migration-the-master-guide)
- MySQL: [What is new in 8.4](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html), [Oracle: major version upgrade 8.0→8.4](https://docs.oracle.com/en-us/iaas/mysql-database/doc/major-version-upgrade.html)
- elabFTW: [Prerequisites](https://doc.elabftw.net/docs/install/prerequisites/), [docker-compose.yml-EXAMPLE @ cd78043](https://github.com/elabftw/elabftw/blob/cd78043e2e6cdf7c525e3e5560d2628cff62e114/containers/elabimg/docker-compose.yml-EXAMPLE)
- Seafile: [Admin manual – installation](https://manual.seafile.com/latest/setup_binary/installation/)
- Live facts: read-only `psql`/`mysql`/`docker exec … --version` queries and one timed `pg_dump -Fc synapse | wc -c` on `optiplex`, 2026-11-06.
