# Research: Seafile on NixOS

Researched 2026-11-06 against NixOS/nixpkgs `master` and the Seafile manual. Ticket: `.scratch/optiplex-nixos-migration/issues/04-research-seafile.md`.

## Question

Can Seafile 12 (server + SeaDoc, currently Docker `seafileltd/seafile-mc:12.0-latest`, MariaDB 10.11, memcached) run natively on current nixpkgs-unstable? Is there a maintained package/NixOS module, what's its status/version, and if not, what are the realistic native options (package it ourselves, or a native alternative that can import Seafile libraries)? Note the migration path for existing libraries and the MariaDB database.

## Short answer

- **No Seafile server in nixpkgs today.** `seafile-server`, `seahub` and `services.seafile` were removed in Aug/Sep 2025 (NixOS 25.11) as "unmaintained and outdated"; the last packaged version was 11.0.12, i.e. *older* than what the Optiplex runs (12.0.14).
- The removal was triggered by upstream: since Seafile 13, the **binary (non-Docker) deployment is no longer supported for the community edition**; SeaDoc and the notification server are officially Docker-only since 12.0.
- **There is an open, unmerged nixpkgs PR #523494** (`seafile-server: init at 13.0.28 and add NixOS module`, opened 2026-05-24, last updated 2026-10-20, labelled `llm-assisted`, no human review yet). Its x86_64-linux build and NixOS test pass in CI. It packages seafile-server + seahub 13.0.28 and a ~940-line `services.seafile` module (MariaDB via `services.mysql`, memcached or Redis). It has **no SeaDoc and no notification server**.
- Upstream is already at 13.0.29 / 14.0.9, so even the PR lags; whoever runs it is effectively its maintainer.
- **SeaDoc's server is open source** (`haiwen/sdoc-server`, Apache-2.0, Node.js/Express, talks to `seahub_db`), so it *could* be packaged with `buildNpmPackage`; nobody has done so in nixpkgs.
- Moving to native Seafile means a **forced major upgrade 12 → 13** (the only native candidate is 13.0.x). The DB upgrade script `upgrade_12.0_13.0.sh` must be run manually; the PR's module refuses to start if the stored version doesn't match the package.
- State on the Optiplex: library blocks are on the Data disk (`/mnt/tbssd/filesync/seafile/seafile-data`, storage ≈ 22 GB), the MariaDB data dir (`ccnet_db`, `seafile_db`, `seahub_db`) is on the System disk (`/opt/seafile/mysql/db`) and must be dumped; SeaDoc data lives in a Docker volume on the Data disk. Public URL `https://filesync.nnik.dev`.
- **Exit path if leaving Seafile:** `seaf-fsck --export` turns libraries back into plain files without needing the database (unencrypted libraries only). Native alternatives in nixpkgs (Nextcloud, OpenCloud, oCIS) cannot import Seafile libraries directly — only those exported files; history, shares, users and SeaDoc docs would be lost.

## Details

### nixpkgs status

- `pkgs/top-level/aliases.nix` on master: `seafile-server = throw "'seafile-server' has been removed as it is unmaintained"; # Added 2025-08-21` and the same for `seahub`. — https://github.com/NixOS/nixpkgs/blob/master/pkgs/top-level/aliases.nix
- NixOS 25.11 release notes: "`services.seafile` has been removed, as it is unmaintained and outdated. See the manual … for details and next steps." — https://github.com/NixOS/nixpkgs/blob/master/nixos/doc/manual/release-notes/rl-2511.section.md
- The removal PR #435059 "nixos/seafile: drop" (merged 2025-09-02) quotes upstream: "Deploying Seafile with binary package is no longer supported for community edition." — https://github.com/NixOS/nixpkgs/pull/435059
- The prior maintainer stepped down shortly before (#419249, "seafile: remove myself from maintainers", merged 2025-06-23); an r-ryantm bump to seahub 13.0.9 (#439131) was closed as superseded by the removal. — https://github.com/NixOS/nixpkgs/pull/419249, https://github.com/NixOS/nixpkgs/pull/439131
- Last packaged version (release-25.05): seafile-server 11.0.12, seahub 11.0.12. — https://github.com/NixOS/nixpkgs/blob/release-25.05/pkgs/by-name/se/seafile-server/package.nix, https://github.com/NixOS/nixpkgs/blob/release-25.05/pkgs/by-name/se/seahub/package.nix
- The **client side** is still packaged and maintained: `seafile-client` and `seafile-shared` 9.0.20, `seadrive-gui` (bumps in 2026). — https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/se/seafile-client/package.nix, https://github.com/NixOS/nixpkgs/pull/565133

### Open PR #523494 (seafile-server 13.0.28 + module)

Source: https://github.com/NixOS/nixpkgs/pull/523494 (head `philocalyst/nixpkgs@43057f6`).

- State: open, not draft, author `philocalyst`, labels include `llm-assisted`, `8.has: module (new)`, `8.has: tests`; no reviews besides the docs bot. A reviewer (samestep, 2026-07-27) listed build blockers (wrong fetchpatch hash, vendored oniguruma vs `-std=gnu23`, Python 3.14 vs `future`, test deprecation warnings); the author pushed fixes 2026-10-16.
- CI on the head commit: the x86_64-linux build of `seafile-server`, `seahub`, `python-cas` and their `passthru.tests` (incl. the new `nixosTests.seafile`) concluded **success**; aarch64-linux "neutral"; darwin queued. — check runs on https://github.com/NixOS/nixpkgs/pull/523494/checks
- Files: `pkgs/by-name/se/seafile-server/{package.nix,libevhtp.nix}`, `pkgs/by-name/se/seahub/{package.nix,seahub-frontend.nix}`, `python-cas`, `nixos/modules/services/networking/seafile.nix` (+943 lines), `nixos/tests/seafile.nix`, release-note line for 26.11. — https://github.com/NixOS/nixpkgs/pull/523494/files
- Package: `seafile-server` 13.0.28 from a pinned rev of `haiwen/seafile-server`, using haiwen's libevhtp fork, compiled with `-std=gnu17`. — https://github.com/philocalyst/nixpkgs/blob/43057f65272f41ec0f96d2241d0093750821b08d/pkgs/by-name/se/seafile-server/package.nix
- Module (https://github.com/philocalyst/nixpkgs/blob/43057f65272f41ec0f96d2241d0093750821b08d/nixos/modules/services/networking/seafile.nix):
  - `database.createLocally` (default true) uses a local MariaDB via Unix socket; otherwise `host`/`port`/`user`/`passwordFile`. DB names default to `ccnet_db`, `seafile_db`, `seahub_db` — the same names used on the Optiplex. This fits the map's "one shared MariaDB" decision.
  - `cache.provider` = memcached or redis, `cache.createLocally`.
  - `jwtPrivateKeyFile`, `serverHostname`, `serverProtocol`, `siteRoot`, `workers`, `seahubExtraConf`, `dataDir` (default `/var/lib/seafile/data`; custom paths get `RequiresMountsFor`, so `/mnt/tbssd/...` works), optional scheduled GC, `enableGoFileserver` (requires an externally managed Go fileserver).
  - It asserts that `seafileSettings` doesn't contain the obsolete `[database]`/`[memcached]` sections (Seafile 13 config style).
  - It records the initialized version in a state file and **refuses to start** on mismatch: "Manual upgrade scripts must be run before starting the server." Seahub runs `manage.py migrate` on start.
  - No options for SeaDoc (`sdoc-server`) or the notification server.
- The PR's release note: "The module manages Seafile 13.0.28 and Seahub; it uses the packaged C fileserver by default."

### Upstream support for non-Docker deployments

- Seafile 13.0 upgrade notes, "Important release changes": "Deploying Seafile with binary package is no longer supported for community edition. We recommend you to migrate your existing Seafile deployment to docker based." Database and cache config move to `conf/.env`; Redis is recommended over memcached. — https://manual.seafile.com/13.0/upgrade/upgrade_notes_for_13.0.x/#important-release-changes
- Same page, binary path 12 → 13: stop 12.0, run `upgrade/upgrade_12.0_13.0.sh`, write `.env` (`JWT_PRIVATE_KEY`, `SEAFILE_MYSQL_DB_*`, `CACHE_PROVIDER`), remove `[database]`/`[memcached]`/… from `seafile.conf` and `DATABASES`/`CACHES` from `seahub_settings.py`. — https://manual.seafile.com/13.0/upgrade/upgrade_notes_for_13.0.x/#upgrade-to-130-for-binary-installation
- Same page: "Since seafile 12.0, we use docker to deploy the seadoc server … Deploying SeaDoc and Seafile binary package on the same server is no longer officially supported." Same for the notification server. SeaDoc becomes 2.0 with Seafile 13.
- Seafile 12.0 still has a binary install guide (the version line the Optiplex is on). — https://manual.seafile.com/12.0/setup_binary/installation_ce/
- Docker 12 → 13 path: switch images to `seafile-mc:13.0-latest` and `sdoc-server:2.0-latest`, add cache env vars. — https://manual.seafile.com/13.0/upgrade/upgrade_docker/
- Upstream tags already include `v13.0.29-server` and `v14.0.9-server`. — https://github.com/haiwen/seafile-server/tags

### SeaDoc

- Architecture: the browser loads an sdoc from `sdoc-server`, which fetches the content from Seafile; served behind the reverse proxy at `/sdoc-server/` plus `/socket.io` (websocket). Standalone deployment is documented only as Docker compose. — https://manual.seafile.com/13.0/extension/setup_seadoc/
- Source: https://github.com/haiwen/sdoc-server — Node.js/Express ("A sync op server for sdoc-editor"), Apache-2.0 (`LICENSE.txt`), build `npm run build` / `npm run serve`, config JSON with `seahub_service_url`, `server_port`, `private_key` (JWT), MySQL host/user/password/database. Actively pushed (2026-11). Packaging would be a `buildNpmPackage` + a small systemd service; not in nixpkgs.

### Current Optiplex deployment (read-only inspection over `ssh optiplex`, 2026-11-06)

- Containers: `seafile` (`seafileltd/seafile-mc:12.0-latest`, dir `seafile-server-12.0.14`), `seafile-mysql` (`mariadb:10.11`, 10.11.14), `seafile-memcached` (`memcached:1.6.29`), `seadoc` (`seafileltd/sdoc-server:1.0-latest`); compose project `/opt/seafile` with `COMPOSE_FILE='seafile-server.yml,caddy.yml,seadoc.yml'`, `ENABLE_SEADOC=true`. The notification server is *not* in `COMPOSE_FILE` (only its image variable is set).
- `seafile` mounts `/mnt/tbssd/filesync` → `/shared` (Data disk); `seafile-data/storage` ≈ 22 GB. `seafile.conf` uses `[database] type = mysql`, `db_name = seafile_db`.
- MariaDB data dir `/opt/seafile/mysql/db` (System disk) contains `ccnet_db`, `seafile_db`, `seahub_db`.
- SeaDoc: volume `seadoc_data` at `/mnt/tbssd/docker/volumes/seadoc_data/_data` (Data disk, size unreadable without root); `seadoc.yml` points SeaDoc at `DB_NAME=seahub_db`.
- `seahub_settings.py`: `SERVICE_URL = "https://filesync.nnik.dev"`, `FILE_SERVER_ROOT = 'https://filesync.nnik.dev/seafhttp'`.

### Migration mechanics

- Seafile's library content is content-addressed blocks/commits/fs objects under `seafile-data/storage`, referenced from `seafile_db`; both must move together and match.
- Native Seafile 13 path (any packaging): `mysqldump` the three DBs from the Docker MariaDB 10.11 → import into the NixOS MariaDB → run `upgrade_12.0_13.0.sh` (or upgrade inside Docker to 13 *before* the Cutover so the dump is already 13-shaped) → point `dataDir` at the existing `seafile-data` → reuse the existing `JWT_PRIVATE_KEY` and `seahub-data` (avatars, thumbnails). Upgrading in Docker first is the upstream-documented route (https://manual.seafile.com/13.0/upgrade/upgrade_docker/) and isolates the schema upgrade from the OS change.
- Leaving Seafile: "You can use seaf-fsck to export all the files in libraries to external file system … This procedure doesn't rely on the seafile database … Currently only un-encrypted libraries can be exported." (`./seaf-fsck.sh --export top_export_path [library-id …]`) — https://manual.seafile.com/12.0/administration/seafile_fsck/#exporting-libraries-to-file-system

### Native alternatives available in nixpkgs

None of them read Seafile's storage format; import is "export to plain files, then ingest".

- Nextcloud: `services.nextcloud`, packages `nextcloud33`–`nextcloud35`. — https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/web-apps/nextcloud.nix, https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/nextcloud/default.nix
- OpenCloud: `services.opencloud`, package `opencloud` 8.1.0. — https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/web-apps/opencloud.nix, https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/op/opencloud/package.nix
- ownCloud Infinite Scale: `services.ocis`. — https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/web-apps/ocis.nix

## Options / trade-offs

1. **Vendor PR #523494 into this flake** (add `philocalyst/nixpkgs` at a pinned rev as a flake input, or copy the four package files + module into `custom-pkgs/`/a local module).
   - + Native, MariaDB/memcached fit the shared-DB decision, CI-green build and VM test, DB names already match.
   - − Unreviewed, LLM-assisted code; Yannik becomes the maintainer of a ~1,300-line package+module; Seafile 13 only (upstream is on 14); no SeaDoc/notification server; upstream explicitly does not support this deployment style. Forced 12 → 13 upgrade.
   - Variant: only take the packages and write a smaller own module.
2. **Option 1 + package sdoc-server ourselves** (`buildNpmPackage`, systemd unit, Caddy routes `/sdoc-server/` and `/socket.io`).
   - + Keeps SeaDoc documents working.
   - − More own packaging; SeaDoc 2.0 must match Seafile 13; unsupported upstream combination.
3. **Option 1 without SeaDoc** — accept losing in-browser editing of `.sdoc` files (files remain in libraries, but are only usable via a SeaDoc server or `seadoc-converter`, https://github.com/haiwen/seadoc-converter).
4. **Keep Seafile in a container** on NixOS (`virtualisation.oci-containers` with Podman) — contradicts the "everything native, no Docker" standing decision, listed only because it is the only upstream-supported deployment.
5. **Replace Seafile** with Nextcloud / OpenCloud / oCIS: `seaf-fsck --export` before the Cutover, ingest the files into the new service.
   - + Maintained NixOS modules, no own packaging.
   - − Loses version history, shares/links, users/groups, SeaDoc docs; all sync clients must be re-set up; encrypted libraries can't be exported this way.
6. **Retire Seafile** (keep the exported files as plain files on the Data disk, e.g. shared via something already planned).

## Open questions

- Does Yannik actually use SeaDoc (any `.sdoc` files / the in-browser editor)? Determines whether options 2/3 matter. Needs a root look at `seadoc_data` and `seahub_db` (sdoc tables).
- Are any libraries encrypted? (Matters for `seaf-fsck --export` / option 5.)
- How many users/clients/shares depend on Seafile (desktop sync, mobile, SeaDrive, public links)?
- Should the 12 → 13 upgrade happen in Docker *before* the Cutover (separate, reversible step) or as part of it?
- Willingness to own an unmerged, LLM-assisted package+module long-term (incl. following upstream 14.x), versus switching software.
- Actual size of the three MariaDB databases (the data dir is root-only; ~189 MB was readable under `/opt/seafile/mysql`).

## Sources

- https://github.com/NixOS/nixpkgs/blob/master/pkgs/top-level/aliases.nix
- https://github.com/NixOS/nixpkgs/blob/master/nixos/doc/manual/release-notes/rl-2511.section.md
- https://github.com/NixOS/nixpkgs/pull/435059
- https://github.com/NixOS/nixpkgs/pull/419249
- https://github.com/NixOS/nixpkgs/pull/439131
- https://github.com/NixOS/nixpkgs/pull/523494
- https://github.com/philocalyst/nixpkgs/blob/43057f65272f41ec0f96d2241d0093750821b08d/pkgs/by-name/se/seafile-server/package.nix
- https://github.com/philocalyst/nixpkgs/blob/43057f65272f41ec0f96d2241d0093750821b08d/nixos/modules/services/networking/seafile.nix
- https://github.com/NixOS/nixpkgs/blob/release-25.05/pkgs/by-name/se/seafile-server/package.nix
- https://github.com/NixOS/nixpkgs/blob/release-25.05/pkgs/by-name/se/seahub/package.nix
- https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/se/seafile-client/package.nix
- https://github.com/NixOS/nixpkgs/pull/565133
- https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/web-apps/nextcloud.nix
- https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/nextcloud/default.nix
- https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/web-apps/opencloud.nix
- https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/op/opencloud/package.nix
- https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/web-apps/ocis.nix
- https://manual.seafile.com/13.0/upgrade/upgrade_notes_for_13.0.x/
- https://manual.seafile.com/13.0/upgrade/upgrade_docker/
- https://manual.seafile.com/13.0/extension/setup_seadoc/
- https://manual.seafile.com/12.0/setup_binary/installation_ce/
- https://manual.seafile.com/12.0/administration/seafile_fsck/
- https://github.com/haiwen/seafile-server/tags
- https://github.com/haiwen/sdoc-server
- https://github.com/haiwen/seadoc-converter
- Read-only inspection of the Optiplex via `ssh optiplex` (docker ps/inspect, `/opt/seafile/.env` without secrets, `seafile.conf`, `seahub_settings.py`), 2026-11-06.
