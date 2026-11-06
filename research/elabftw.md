# elabFTW on NixOS

Researched 2026-11-06. nixpkgs facts are pinned to master commit `b88bbad3` and elabFTW facts to tag `6.0.9`, the latest stable release at the time.

## Question

Can elabFTW, currently Docker `elabftw/elabimg:4.3.10` with MySQL 8.0 and uploads in a Docker volume, run natively on NixOS? Specifically:

- Is it packaged in nixpkgs or anywhere else?
- What does a native install need: PHP version and extensions, web server, cron and worker?
- Is MariaDB an acceptable substitute for MySQL 8?
- What is the upgrade path from 4.3.10 to a current release?

## Short answer

- **No package exists anywhere.** elabFTW is not in nixpkgs, NUR or community flakes, and not in other distros either (AUR and Repology return nothing). A native install means writing our own derivation and NixOS module.
- **Upstream does not support native installs.** The docs say elabFTW is "supported only on GNU/Linux, and only in containers". The only thing upstream ships is the `elabimg` container.
- **A native install is technically feasible, but it is real porting work.** It needs:
  - PHP ≥ 8.4 with about 20 extensions, including imagick, ldap, gd, redis and apcu.
  - A frontend build with Yarn 4 in PnP mode and Node 24.
  - php-fpm and a web server that reproduces elabimg's nginx rules.
  - Two Go helper daemons: `chronos`, a cron replacement, and `invoker`, a socket job runner.
  - `obabel` (Open Babel), ghostscript and imagemagick.
  - Several hard-coded absolute paths (`/var/lib/elabftw/uploads`, `/var/cache/elabftw`, `/run/elabftw/invoker.sock`) that the NixOS module must create.
- **MariaDB: upstream says no.** "it must be MySQL (not MariaDB)". Modern MariaDB, nixpkgs `mariadb_114` = 11.4.13, now understands the `utf8mb4_0900_ai_ci` collation that elabFTW's schema uses. Running elabFTW on it would still be unsupported and untested.
- **MySQL in nixpkgs is 8.4 only.** `mysql80` was removed on 2026-04-08 (EOL). `mysql84` (8.4.11) is available and is the version elabFTW 6 officially targets.
- **NixOS can't run MySQL and MariaDB together with the stock module.** `services.mysql` is a single instance that runs either MySQL or MariaDB. elabFTW therefore conflicts with the standing decision "one shared MariaDB server". See Options.
- **Upgrade path:** 4.3.10 is at schema 91, and 6.0.9 requires schema 224. `bin/console db:update` applies every schema file in sequence, with no mandatory intermediate release after 3.x. In practice:
  - PHP 8.0 (which 4.3.10 runs on) and MySQL 8.0 no longer exist in nixpkgs, so the app and the database must both be upgraded anyway. Do it on Arch/Docker before the cutover, or as part of it.
  - The live MySQL runs with `--default-authentication-plugin=mysql_native_password`. MySQL 8.4 disables that plugin by default, so the `elabftw` DB user must be migrated to `caching_sha2_password`.
- **State is small.** Uploads are 25 MB and the MySQL datadir is 152 MB. `SECRET_KEY` must be carried over; it encrypts the stored SMTP and TSA passwords.

## Details

### 1. Packaging status

- No nixpkgs package, module or PR exists:
  - A GitHub code search for `elabftw repo:NixOS/nixpkgs` and a PR search for `elabftw` in NixOS/nixpkgs both return 0 results (run 2026-11-06 via the GitHub search API).
  - `pkgs/by-name/el/elabftw` does not exist (HTTP 404 at <https://github.com/NixOS/nixpkgs/tree/master/pkgs/by-name/el/elabftw>).
- No community Nix packaging exists. A GitHub code search for `elabftw language:nix` finds one unrelated hit, an auto-update module in `kronberger-droid/nixos`.
- No other distro packages it:
  - AUR RPC search returns `resultcount: 0`: <https://aur.archlinux.org/rpc/v5/search/elabftw>
  - Repology returns `[]`: <https://repology.org/api/v1/project/elabftw>
- Upstream supports containers only:
  - "eLabFTW is supported **only on GNU/Linux**, and **only in containers**. Other operating systems or installations without containers are not supported for production installations." (<https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/intro.md>)
  - The prerequisites list Docker, Podman, Kubernetes "or any other OCI compatible container engine" (<https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/prerequisites.md>).
- The repo's own GitHub topics are `docker` and `mysql` (<https://github.com/elabftw/elabftw>).
- "eLabFTW Lite" (Go/Wails) is not an alternative. Its README says it is "an early experimental preview … not ready for use" (<https://github.com/elabftw/lite>).

### 2. What a native install needs (derived from the elabimg 6.0.9 Dockerfile)

The container image is the de facto install spec: <https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/Dockerfile>.

**PHP**

- `composer.json` requires `php >= 8.4.0` plus these extensions: ctype, curl, exif, fileinfo, filter, gettext, hash, json, ldap, mbstring, openssl, gd, pdo, zip (<https://github.com/elabftw/elabftw/blob/6.0.9/composer.json>).
- The image additionally installs these `php84-*` packages: apcu, bcmath, dom, iconv, intl, opcache, pdo_mysql, imagick, redis, simplexml, session, sodium, xml, xmlwriter. The Dockerfile comments explain some of them: bcmath for Exchange NTLM mail, gd for mpdf, iconv for LdapRecord, xmlwriter for S3 multipart uploads.
- nixpkgs has `php83`, `php84`, `php85` (default) and `php86`, each with matching `phpXXExtensions`. `php82` and `php81` are removed as EOL:
  - <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/top-level/all-packages.nix#L4286>
  - <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/top-level/aliases.nix#L2164>
- PHP dependencies would be built with `php.buildComposerProject2` (<https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/doc/languages-frameworks/php.section.md>).
- The current server runs PHP 8.0.18 inside 4.3.10 (observed live: `docker exec elabftw php -v`). No such PHP exists in nixpkgs, so 4.3.10 itself cannot run natively.

**Frontend build**

- `package.json` pins `"packageManager": "yarn@4.15.0"` and `engines.node ">=24 <25"`. `.yarnrc.yml` uses `nodeLinker: pnp` plus a local Yarn plugin (`src/tools/yarn-plugin-tinymce.js`). Sources:
  - <https://github.com/elabftw/elabftw/blob/6.0.9/package.json>
  - <https://github.com/elabftw/elabftw/blob/6.0.9/.yarnrc.yml>
- The build is `yarn run buildall:prod` followed by `composer dump-autoload --no-dev -a`, because autoloading depends on a generated `Parser.php` (Dockerfile, "build assets" step).
- nixpkgs provides `yarn-berry_4` with `fetchYarnBerryDeps` and `yarnBerryConfigHook`:
  - <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/doc/languages-frameworks/javascript.section.md>
  - <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/top-level/all-packages.nix#L2877>
- PnP plus a custom plugin plus asset generation is the riskiest part of packaging.

**Runtime binaries**

- `nodejs` stays in the runtime image.
- Other runtime binaries: `ghostscript`, `imagemagick` (heic and svg), and `obabel` (Open Babel 3.2.1, built statically in the image, used for compound fingerprinting since v6).
- `openbabel` exists in nixpkgs (<https://github.com/NixOS/nixpkgs/tree/master/pkgs/by-name/op/openbabel>).

**Web server**

- elabimg ships a custom nginx 1.30 build with the `ngx_brotli` and `headers-more` modules (Dockerfile, "NGINX BUILDER").
- `common.conf` holds the routing (<https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/nginx/common.conf>):
  - Document root `/elabftw/web`.
  - An allowlist of PHP entry points, generated at start-up from `find /elabftw/web -name '*.php'`.
  - `/api/v2/*` and `/api/v3/*` rewrite to `app/controllers/ApiController.php` with `fastcgi_param ELABFTW_API_VERSION`.
  - `/api/v1` returns 410.
  - A SAML `acs` rewrite.
  - CSP and caching headers.
  - Optional `/php-status`, `/nginx-status` and `/metrics` behind basic auth.
- Under Caddy, all of this would have to be re-expressed with `php_fastcgi` plus rewrites, or nginx kept behind Caddy.

**php-fpm pool**

- The pool gets its config as `env[...]` entries, and `clear_env = yes` (<https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/php/elabpool.conf>):
  - `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
  - `SECRET_KEY`, `SITE_URL`, `MAX_UPLOAD_SIZE`, `INVOKER_PSK`, and others
- The entrypoint fills in `php.ini` (<https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/entrypoint/docker-entrypoint.sh>):
  - `open_basedir` is `/elabftw/:/var/lib/elabftw/:/var/cache/elabftw/php:/run/elabftw:…`.
  - Sessions are stored in `/run/elabftw/sessions`.
  - It generates a random `INVOKER_PSK` at start-up.
  - It creates the cache tree under `/var/cache/elabftw/{nginx,php/...}`.

**Hard-coded paths in the PHP code**

- `src/Storage/Local.php`: `FOLDER = '/var/lib/elabftw/uploads'` (<https://github.com/elabftw/elabftw/blob/6.0.9/src/Storage/Local.php#L20>)
- `src/Storage/Exports.php`: `/var/lib/elabftw/exports`
- `src/Elabftw/Invoker.php`: `unix:///run/elabftw/invoker.sock` (<https://github.com/elabftw/elabftw/blob/6.0.9/src/Elabftw/Invoker.php#L24>)
- `/var/cache/elabftw` is used in `src/Storage/Tmp.php` and `src/Storage/Cache/*`.
- The app also hard-codes `/elabftw/bin/console` through the helpers below. The code path `/elabftw` is not under `/nix/store`, so a native package must either patch these paths or bind/symlink `/elabftw` (e.g. `systemd.tmpfiles` or `BindReadOnlyPaths=`).

**Background services**

These replace the old cron from the 4.x image:

- **`chronos`** (Go) runs `php /elabftw/bin/console` on a schedule (<https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/helpers/chronos.go>):
  - `notifications:send` every minute
  - `notifications:tsbalance` daily at 13:37
  - `idps:refresh` daily at 03:37
  - `notifications:send-expiration` weekly on Sunday at 01:45

  On NixOS these are four `systemd.timers` and need no Go binary.
- **`invoker`** (Go) listens on `/run/elabftw/invoker.sock`. It authenticates messages with `INVOKER_PSK` and runs one `bin/console` command at a time, used for asynchronous jobs such as exports (<https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/helpers/invoker.go>). It must run as a long-lived systemd service sharing the PSK with php-fpm. It can be built with `buildGoModule` from `containers/elabimg/helpers`.
- **Today (4.3.10)** the container crontab only runs `notifications:send` every minute (observed live in `/etc/crontabs/nginx`).

**Database migrations**

`bin/console db:update` must run after every version bump (<https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/upgrade/update.md>). On NixOS this fits a oneshot `ExecStartPre` or a separate unit. The entrypoint offers `AUTO_DB_UPDATE` as a precedent.

### 3. MariaDB vs MySQL

**Upstream's position**

- The prerequisites say "If you use an existing database service instead of the bundled container, it must be **MySQL (not MariaDB)**" (<https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/prerequisites.md>).
- The docs FAQ says "Only **MySQL** is supported. Not PostgreSQL, not MariaDB, not SQLite." (<https://github.com/elabftw/elabftw/blob/6.0.9/documentation/src/components/HomepageFaq/index.tsx>).

**Required MySQL version**

- The v6 upgrade guide says "eLabFTW version 6 requires running MySQL 8.4 as it uses features available only in this version" (<https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/upgrade/update-6.md>).
- The code and later PRs are looser:
  - #7396 enforced 8.4, #7406 relaxed it to ≥ 8.4, and #7458 ("update: only 8.0 is actually required") relaxed it to ≥ 8.0:
    - <https://github.com/elabftw/elabftw/pull/7396>
    - <https://github.com/elabftw/elabftw/pull/7406>
    - <https://github.com/elabftw/elabftw/pull/7458>
  - Quadlet docs PR #7460 says "MySQL 8.4 is officially supported, while MySQL 8.0 remains functional but is no longer officially supported" (<https://github.com/elabftw/elabftw/pull/7460>).
  - At 6.0.9, `Update.php` only checks that the server's major version is ≥ 8 (<https://github.com/elabftw/elabftw/blob/6.0.9/src/Elabftw/Update.php#L50-L56>).
- MariaDB reports versions like `11.4.13-MariaDB`, so this check would not stop it. Support is a policy question, not a code guard.

**Technical compatibility signals**

- The schema uses `COLLATE utf8mb4_0900_ai_ci` throughout (69 occurrences in `src/sql/structure.sql`), plus `CHECK (...)` constraints and `FULLTEXT` indexes.
- MariaDB added `utf8mb4_0900_*` collations as aliases of its `uca1400` collations in **11.4.5** (MDEV-20912):
  - <https://jira.mariadb.org/browse/MDEV-20912>
  - <https://github.com/MariaDB/server/commit/7fcaab7aaa>
- nixpkgs `mariadb` = `mariadb_114` = **11.4.13**, so a `mysqldump` would at least import:
  - <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/top-level/all-packages.nix#L7144>
  - <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/servers/sql/mariadb/default.nix#L426-L428>
- Whether every query works on MariaDB is untested upstream. JSON handling differs: MariaDB stores JSON as LONGTEXT, and elabFTW uses JSON metadata heavily. The upgrade guide's claim of MySQL-8.4-only features is unverified in either direction.

**nixpkgs**

- `mysql80` has been removed: "`mysql80` has been removed. Please update to `mysql84` or `mariadb`" (26.05 release notes). The alias throws "'mysql80' reached end of life on 2026-04-30":
  - <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/nixos/doc/manual/release-notes/rl-2605.section.md?plain=1#L331>
  - <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/top-level/aliases.nix#L1888>
- `mysql84` is version **8.4.11** (<https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/by-name/my/mysql84/package.nix>).
- `services.mysql` is one instance with one `package`. The option text says "MariaDB packages are supported too", and the module switches behaviour on `isMariaDB` (<https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/nixos/modules/services/databases/mysql.nix#L11>, L73-L78).
- So a NixOS host gets **either** MySQL **or** MariaDB from the stock module, never both.

### 4. Upgrade path 4.3.10 → 6.0.x

**Live facts** (read-only over `ssh optiplex`, 2026-11-06)

- Image `elabftw/elabimg:4.3.10`.
- `bin/console db:check` reports "Current version: 91".
- MySQL `8.0.30`, started with `--default-authentication-plugin=mysql_native_password`.
- Compose file at `/etc/elabftw.yml`, with external volumes `elabftw_uploads` (25 MB) and `elabftw_mysql` (152 MB) under `/mnt/tbssd/docker/volumes/`.
- `SITE_URL=https://elabftw.nnik.dev`, `DISABLE_HTTPS=true`, published on `127.0.0.1:25569`, with host nginx vhost `elabftw.nnik.dev`.
- Secrets in the compose file: `DB_PASSWORD`, `SECRET_KEY`, `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`.
- `~/elabftw/elabftw.yml` is a stale older copy and is not the live config.

**Current releases**

6.0.9 and 5.6.15 were both released on 2026-10-21. 6.1.0 is in alpha (<https://github.com/elabftw/elabftw/releases>).

**Schema migration**

- 6.0.9 requires schema 224 (<https://github.com/elabftw/elabftw/blob/6.0.9/src/Elabftw/SchemaVersionChecker.php#L23>).
- `Update.php` loops `schema{N+1}.sql` up to `REQUIRED_SCHEMA`. It only refuses databases below schema 37 or 41, the 1.x and 2.x branches. All of `schema92.sql` … `schema224.sql` ship in `src/sql/` at 6.0.9 (<https://github.com/elabftw/elabftw/tree/6.0.9/src/sql>). A direct 91 → 224 migration is therefore mechanically supported.
- Every `schema≥116` has a `-down.sql`, so `db:revert` is possible for recent steps.

**Release-note hazards between 4.3 and 6.0**

- 4.4.0: "updating to 4.4.0 from 4.3.0 should not cause any issue during the db:update step" (<https://github.com/elabftw/elabftw/releases/tag/4.4.0>).
- 4.9.0 / 5.0.0 (<https://github.com/elabftw/elabftw/releases/tag/5.0.0>):
  - API v1 is removed, so any scripts using `/api/v1` will break.
  - The default PHP memory goes to 2 GB.
  - Experiments are no longer shared across teams.
- 5.1.0: "nothing particular when it comes to upgrading" (<https://github.com/elabftw/elabftw/releases/tag/5.1.0>).
- 5.2.0: upgrade to PHP 8.4 (<https://github.com/elabftw/elabftw/releases/tag/5.2.0>).
- 6.0.0 (<https://github.com/elabftw/elabftw/releases/tag/6.0.0>, <https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/upgrade/update-6.md>):
  - Container breaking changes only: port 8080, uploads moved to `/var/lib/elabftw/uploads`, a non-root user, and env vars removed.
  - `USE_PERSISTENT_MYSQL_CONN` now defaults to false.
  - The MySQL 8.4 requirement.
  - The container changes are irrelevant natively, apart from the path layout they reveal.

**MySQL 8.0 → 8.4**

- MySQL 8.4 supports upgrades from 8.0. It disables `mysql_native_password` by default and removes `default_authentication_plugin` (<https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html>).
- elabFTW's sysadmin guide documents the fix (<https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/usage/sysadmin-guide.md>, sections "Fix authentication issues after upgrading from MySQL 8.0 to 8.4" and "Fix deprecation warning for old password storage"):
  1. Start once with `--mysql-native-password=ON`.
  2. Run `ALTER USER … IDENTIFIED WITH caching_sha2_password BY '…'` for each affected user.
  3. Restart without the flag.
- The live compose still has `--default-authentication-plugin=mysql_native_password`, so this step applies to us.
- Alternatively, a fresh `mysql84` with a `mysqldump` import and a newly created user avoids the issue entirely. On NixOS, `ensureUsers` uses socket auth and the app would need a password, or a socket connection via `DB_HOST=localhost`.

**State to carry over**

- The DB dump.
- The uploads directory (to wherever the module maps `/var/lib/elabftw/uploads`).
- `SECRET_KEY`. The backup docs say losing it only means re-entering the SMTP and TSA passwords (<https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/backups.md>).
- `SITE_URL`.

## Options and trade-offs

**Runtime**

| Option | What it means | Pros | Cons |
|---|---|---|---|
| A. Native derivation + own NixOS module | Package 6.0.x: composer, yarn-berry PnP build, `/elabftw` path patching, php-fpm pool, Caddy or nginx rules, `invoker` service, 4 systemd timers | Fits "everything native"; declarative | Unsupported upstream; biggest effort; we maintain it on every release (frequent: 9 patch releases in 6 weeks); hard-coded paths and PnP build are fragile |
| B. OCI container via `virtualisation.oci-containers` (podman backend) | Run upstream `elabimg:6.0.x` as a systemd-managed podman container; DB native | Upstream-supported; trivial upgrades; no packaging | Breaks the "no Docker / everything native" decision (podman, but still a container) |
| C. Retire elabFTW | Export data (.eln per team via `bin/console teams:export`, see 5.1.0 notes) and keep it in the Rollback image | Zero effort | Loses the service; only an option if nobody uses it |

**Database** (relevant for A and B)

| Option | Pros | Cons |
|---|---|---|
| D1. `services.mysql.package = mysql84` as the host's only MySQL-family server, and move other MariaDB users onto it | Supported DB for elabFTW; stock module | Breaks "one shared MariaDB". Other services that ask for MariaDB (e.g. Seafile uses `mariadb:10.11` today) would run on MySQL 8.4, which may not be supported for them |
| D2. Shared MariaDB (11.4.13) also hosts elabFTW | Keeps the standing decision; one server | Explicitly unsupported upstream; collation imports since 11.4.5, but JSON and other behaviour untested; risk shows up at runtime, not at import |
| D3. Shared MariaDB plus a second, hand-rolled `mysqld` (mysql84) systemd unit or a NixOS container just for elabFTW | Both supported DBs | Second DB engine to back up and maintain; the stock module can't do it, so custom unit or `containers.<name>` |
| D4. (Only with B) MySQL 8.4 also in a podman container | Mirrors upstream compose exactly | Even more container |

**Upgrade timing**

| Option | Pros | Cons |
|---|---|---|
| U1. Upgrade on Arch/Docker before cutover: 4.3.10 → 6.0.x image and `mysql:8.0` → `mysql:8.4`, fix auth plugin, then dump | De-risks cutover; upstream-tested path; failures are isolated from the NixOS work | Extra pre-cutover step; touches the live server |
| U2. Dump 4.3.10 / MySQL 8.0 and import into NixOS MySQL 8.4 at cutover, then run `db:update` there | One step | Two big jumps (schema 91 → 224 and DB 8.0 → 8.4) happen in the cutover window, which is harder to debug |

## Open questions

- **Is elabFTW still used, and by whom?** Is it worth option A's maintenance burden versus B or C? 25 MB of uploads suggests light use.
- **Is a podman OCI container acceptable** as an exception to "no Docker", or is "everything native" strict? This decides A vs B.
- **Which other Kept services need MariaDB specifically versus "MySQL-compatible"?** This decides D1 vs D2 vs D3 and interacts with ticket 10 (database migration).
- **Is anything using the elabFTW API v1?** It was removed in 5.0.
- **Does `SITE_URL` stay `https://elabftw.nnik.dev`** behind Caddy? Keeping it avoids breaking links, and `SET_REAL_IP` / trusted-proxy handling is needed for correct client IPs.
- **Does elabFTW actually work on MariaDB 11.4?** A test would settle it: import a dump and run `db:update` and the UI in a VM. Upstream won't help if it breaks.

## Sources

- elabFTW install intro (containers only): <https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/intro.md>
- elabFTW prerequisites (MySQL, not MariaDB): <https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/prerequisites.md>
- elabFTW docs FAQ: <https://github.com/elabftw/elabftw/blob/6.0.9/documentation/src/components/HomepageFaq/index.tsx>
- Upgrade docs: <https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/upgrade/update.md>, <https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/upgrade/update-6.md>
- Backups doc: <https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/install/backups.md>
- Sysadmin guide (MySQL 8.4 auth): <https://github.com/elabftw/elabftw/blob/6.0.9/documentation/docs/usage/sysadmin-guide.md>
- elabimg Dockerfile: <https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/Dockerfile>
- elabimg entrypoint: <https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/entrypoint/docker-entrypoint.sh>
- elabimg nginx config: <https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/nginx/common.conf>
- php-fpm pool: <https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/php/elabpool.conf>
- chronos and invoker helpers: <https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/helpers/chronos.go>, <https://github.com/elabftw/elabftw/blob/6.0.9/containers/elabimg/helpers/invoker.go>
- composer.json, package.json, .yarnrc.yml: <https://github.com/elabftw/elabftw/blob/6.0.9/composer.json>, <https://github.com/elabftw/elabftw/blob/6.0.9/package.json>, <https://github.com/elabftw/elabftw/blob/6.0.9/.yarnrc.yml>
- Hard-coded paths: <https://github.com/elabftw/elabftw/blob/6.0.9/src/Storage/Local.php>, <https://github.com/elabftw/elabftw/blob/6.0.9/src/Elabftw/Invoker.php>
- DB update logic and schema files: <https://github.com/elabftw/elabftw/blob/6.0.9/src/Elabftw/Update.php>, <https://github.com/elabftw/elabftw/blob/6.0.9/src/Elabftw/SchemaVersionChecker.php>, <https://github.com/elabftw/elabftw/tree/6.0.9/src/sql>
- MySQL-version PRs: <https://github.com/elabftw/elabftw/pull/7396>, <https://github.com/elabftw/elabftw/pull/7406>, <https://github.com/elabftw/elabftw/pull/7458>, <https://github.com/elabftw/elabftw/pull/7460>
- Releases: <https://github.com/elabftw/elabftw/releases>, plus the tags [4.4.0](https://github.com/elabftw/elabftw/releases/tag/4.4.0), [5.0.0](https://github.com/elabftw/elabftw/releases/tag/5.0.0), [5.1.0](https://github.com/elabftw/elabftw/releases/tag/5.1.0), [5.2.0](https://github.com/elabftw/elabftw/releases/tag/5.2.0) and [6.0.0](https://github.com/elabftw/elabftw/releases/tag/6.0.0)
- eLabFTW Lite: <https://github.com/elabftw/lite>
- nixpkgs (pinned to `b88bbad3`):
  - all-packages.nix (php, mariadb, yarn-berry): <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/top-level/all-packages.nix>
  - aliases.nix (mysql80, php82 removed): <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/top-level/aliases.nix>
  - mysql84: <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/by-name/my/mysql84/package.nix>
  - mariadb versions: <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/pkgs/servers/sql/mariadb/default.nix>
  - services.mysql module: <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/nixos/modules/services/databases/mysql.nix>
  - 26.05 release notes: <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/nixos/doc/manual/release-notes/rl-2605.section.md>
  - PHP and JS packaging docs: <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/doc/languages-frameworks/php.section.md>, <https://github.com/NixOS/nixpkgs/blob/b88bbad379524f67d9aa8ef128ee726e286484e9/doc/languages-frameworks/javascript.section.md>
- MySQL 8.4 "What is new since 8.0": <https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html>
- MariaDB utf8mb4_0900 collations (11.4.5): <https://jira.mariadb.org/browse/MDEV-20912>, <https://github.com/MariaDB/server/commit/7fcaab7aaa>
- AUR / Repology (no packages): <https://aur.archlinux.org/rpc/v5/search/elabftw>, <https://repology.org/api/v1/project/elabftw>
- Live server: read-only `ssh optiplex` (`docker ps`, `docker inspect`, `docker exec elabftw bin/console db:check`, `/etc/elabftw.yml` with secrets filtered), 2026-11-06.
