# Research: Synapse + mautrix bridges on NixOS, migrating existing State

Ticket: `.scratch/optiplex-nixos-migration/issues/08-research-matrix.md`. Researched 2026-11-06.
nixpkgs citations are pinned to master commit
[`0734212d`](https://github.com/NixOS/nixpkgs/tree/0734212d269c1ccfb74ab571b930b3a210555680).
Statements marked **(live)** come from read-only commands over `ssh optiplex` on 2026-11-06. No secrets
are reproduced here.

## Question

How do the Optiplex's Synapse (`/var/lib/synapse`, Postgres DB `synapse` 10 GB, federation on :8448,
`.well-known` served for `nnik.dev`) and the mautrix-whatsapp, mautrix-telegram and mautrix-signal bridges
(configs/registrations in `/srv/matrix-services`, Postgres DBs `whatsapp`, `telegram`, `signal`) move onto the
NixOS modules (`services.matrix-synapse`, `services.mautrix-*`) without losing rooms, puppets or bridge logins?
Cover: signing key and media store, appservice registration files, mautrix-telegram's Python vs Go (megabridge)
status in nixpkgs, mautrix-signal without signald, coturn integration, and whether the cron restarts every 4–6 h
were masking a real problem.

## Short answer

- **Synapse moves cleanly.** Live 1.156.0 → nixpkgs 1.164.2 is a forward-only upgrade with no blocking upgrade
  notes. State = Postgres DB `synapse` (collation `C`, must stay `C`), signing key `nnik.dev.signing.key`, media
  store (**25 GB**, not in the DB), plus the config secrets `macaroon_secret_key`, `form_secret`,
  `registration_shared_secret` and `turn_shared_secret`. The signing key must be in place **before** the first
  start, because the NixOS unit runs `--generate-keys` and would otherwise make a new key.
- **Registrations:** copy each `/etc/synapse/appservices/<bridge>.yaml` to
  `/var/lib/mautrix-<bridge>/<bridge>-registration.yaml` before the first start. The modules generate a new file
  only if none exists, then copy its tokens into the bridge config. Keep `id` and the bot usernames as they are
  (`whatsapp`, `telegram`, `signalbot`). The nixpkgs default is `whatsappbot`, so WhatsApp needs an override.
- **mautrix-telegram is the problem.** The Optiplex moved to the **Go** bridge (v26.10) on 2026-11-03, so the
  `telegram` DB now uses the bridgev2 schema. nixpkgs master still ships the **Python 0.15.3** package and a
  Python-shaped module. The Go migration PR [#510662](https://github.com/NixOS/nixpkgs/pull/510662) and the
  unified-module draft [#581772](https://github.com/NixOS/nixpkgs/pull/581772) are both open. The Optiplex will
  need a local Go package and service, or one of those PRs, or the PR has to merge before the Cutover.
- **mautrix-signal has nothing to do with signald any more.** The live bridge is Go 0.7.2 (bridgev2), and nixpkgs
  ships 26.10 with libsignal-ffi. An in-place upgrade from ≥0.7.0 is supported. But the live Signal login is
  **already dead**: it gets 401 Unauthorized, and the last bridged message is from 2025-01-27. Expect to re-link,
  and the Signal DB State is close to worthless.
- **Double puppeting is not working today on any bridge.** The configs use a shared secret, not the
  `as_token:` form, and megabridge only supports the appservice method. No user has a stored token. So the
  `shared_secret_authenticator` Synapse module does nothing. The migration can drop it, or replace it with a
  `doublepuppet` appservice registration.
- **E2BE pickle keys** are the well-known defaults: `maunium.net/go/mautrix-whatsapp` for WhatsApp,
  `mautrix.bridge.e2ee` for Telegram and Signal. These exact values must be set explicitly, because the nixpkgs
  modules default `pickle_key` to `""`. Also, nixpkgs marks `olm` as insecure, so the build needs either
  `permittedInsecurePackages` or `withGoolm`.
- **coturn runs as an open relay today** (`no-auth`). Synapse hands out HMAC credentials that coturn ignores, and
  `allowed-peer-ip=192.168.178.21-40` lets relayed traffic reach LAN hosts. On NixOS, use `services.coturn` with
  `use-auth-secret` plus `static-auth-secret-file` (sops), and give Synapse the same secret through
  `extraConfigFiles`.
- **Cron restarts:** root restarts the three bridges every 4 h. Yannik's crontab also tries to restart Synapse
  and signald every 6 h, but those commands run without root and fail: Synapse has been up continuously since
  2026-09-27, and the journal since 2026-10-04 shows no restart events. So nothing was masking a Synapse problem.
  The bridge restarts look like leftovers from the Python/signald era. There is no evidence of a current fault,
  but proving that would need a run without the restarts.

## Details

### Live state (Optiplex, Arch)

| Item | Finding **(live)** |
|---|---|
| Synapse | Arch `matrix-synapse 1.156.0-1`, config `/etc/synapse/homeserver.yaml`, `server_name: nnik.dev`, `default_room_version: "9"`, no workers, redis off |
| Listener | `8008`, `tls: false`, `x_forwarded: true`, `bind_addresses: ['::']` (reachable from the LAN), resources `client, federation, keys, media` |
| Reverse proxy | nginx `nnik.dev` vhost on 443 **and** 8448 (TLS), proxies `^(/_matrix\|/_synapse/client)` to `localhost:8008`, `client_max_body_size 200M`. It serves `.well-known/matrix/server` = `{"m.server": "nnik.dev:8448"}` and `.well-known/matrix/client` = `{"m.homeserver": {"base_url": "https://nnik.dev"}}` from static files in `/srv/matrix-services/` |
| DB | `database.name: psycopg2`, DB `synapse`, owner/role `synapse_user`, TCP `localhost:5432`, collation/ctype `C`/`C`. Size 10 GB. Largest table `state_groups_state` 5.6 GB, then `event_json` 1.3 GB. PostgreSQL 18.3. The whole PG data dir is 12 GB |
| Users/rooms | 13,833 users, of which 10 are not appservice users (9,323 `whatsapp`, 4,494 `telegram`, 6 `signal`); 1,855 rooms |
| Signing key | `signing_key_path: /etc/synapse/nnik.dev.signing.key` (created 2022-07-27); `old_signing_keys` is empty |
| Media | `media_store_path: /var/lib/synapse/media_store`, **25 GB** (`local_content`, `local_thumbnails`, `remote_content`, `remote_thumbnail`, `url_cache*`); 56,133 local and 568 remote media rows |
| Logs | `log_config: /etc/synapse/nnik.dev.log.config` writes to `/var/lib/synapse/homeserver.log`, 60–80 MB per day, rotated daily |
| Module | `modules: shared_secret_authenticator.SharedSecretAuthProvider` (Arch `python-matrix-synapse-shared-secret-auth-git`) |
| Other settings worth keeping | `enable_registration: true` with reCAPTCHA, `url_preview_enabled: true`, `encryption_enabled_by_default_for_room_type: all`, `turn_uris: ["turn:nnik.dev?transport=udp","turn:nnik.dev?transport=tcp"]`, `turn_allow_guests: true`, `turn_shared_secret` set |
| Appservices | `/etc/synapse/appservices/{telegram,whatsapp,signal}.yaml`, ids `telegram`/`whatsapp`/`signal`, URLs `localhost:29317/29318/29328` |
| Bridges | Self-built from git in `/srv/matrix-services/mautrix-*`, each running from its own directory with `config.yaml` and a `logs/` dir |
| mautrix-whatsapp | `v26.07+dev` (built 2026-08-02), DB `whatsapp` 161 MB, schema `version=29`, 2 logins, 488 portals, bot `@whatsapp`, working (last message today) |
| mautrix-telegram | `v26.10+dev` **Go** (built 2026-11-03; the systemd drop-in `90-go-migration.conf` replaced the Python venv), DB `telegram` 79 MB, schema `version=33`/`telegram_version=10`, 3 logins, 261 portals, bot `@telegram`, working |
| mautrix-signal | `0.7.2+dev` (built 2024-11-11), DB `signal` 12 MB, 1 login, 3 portals, bot `@signalbot`. Gets **401 Unauthorized** from Signal; last message 2025-01-27 |
| Bridge DB access | All three bridge DBs are owned by `postgres` and accessed as role `synapse_user` over TCP |
| E2BE | `encryption.allow/default: true` on all three; `require: true` on WhatsApp and Signal; `appservice: false`; pickle keys = public defaults (see Short answer) |
| Double puppet | `double_puppet.secrets` are **not** `as_token:`-prefixed. The Telegram config maps `localhost: https://localhost`, which looks like a leftover. The `user.access_token` column is empty for every user in all three DBs |
| coturn | Arch `coturn 4.11.0`, `turnserver.conf`: `no-auth`, `realm=nnik.dev`, `no-tcp-relay`, LE cert/key set, private ranges denied, but `allowed-peer-ip=192.168.178.21-192.168.178.40` and `10.0.0.1`. Listens on 3478 TCP/UDP only. No relay port range set, so the coturn default applies |
| Leftovers | `signald` and `matrix-register` units have failed. DBs `matrix`, `maubot`, `discord` exist. All of these are Retired per the map |

### Synapse on NixOS

- **Module shape.** `services.matrix-synapse` defaults `dataDir` to `/var/lib/matrix-synapse`.
  `signing_key_path` defaults to `${dataDir}/homeserver.signing.key` and `media_store_path` to
  `${dataDir}/media_store`. Each can be set to any path, and both are added to `ReadWritePaths`
  ([synapse.nix L713–L876](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L713-L876),
  [L1507–L1512](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L1507-L1512)).
  The unit runs as user `matrix-synapse` with `ProtectSystem=strict`, `ProtectHome=true` and `UMask=0077`
  ([L1477–L1530](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L1477-L1530)).
  So restored files must be `chown`ed to `matrix-synapse`, and the 25 GB media store can live on the Data disk
  if ticket 03 decides so.
- **Signing key.** `preStart` runs `synapse_homeserver … --generate-keys`. An `ExecStartPre` then
  `chown`s and `chmod 0600`s `signing_key_path`
  ([L1570–L1586](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L1570-L1586)).
  Synapse creates a new key if the file is missing
  ([config docs: `signing_key_path`](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#signing_key_path)).
  Restore `nnik.dev.signing.key`, either as a sops secret or as a restored file, **before** the first start, and
  point `settings.signing_key_path` at it.
- **Secrets.** Options that must not end up in the Nix store go through `extraConfigFiles`
  ([L418–L428](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L418-L428)).
  Carry over `macaroon_secret_key` and `form_secret` unchanged. Replacing `macaroon_secret_key` invalidates
  guest access tokens and email unsubscribe links
  ([config docs: `macaroon_secret_key`](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#macaroon_secret_key)).
  `registration_shared_secret`, `turn_shared_secret` and the reCAPTCHA keys belong in the same sops-rendered
  YAML.
- **Database.** Synapse refuses to start on a DB whose `COLLATE`/`CTYPE` is not `C` (unless
  `allow_unsafe_locale`). The fix it documents is to dump and recreate the DB with the right locale
  ([Synapse postgres docs](https://element-hq.github.io/synapse/latest/postgres.html#fixing-incorrect-collate-or-ctype)).
  The NixOS chapter tells you to create the DB by hand with `TEMPLATE template0 LC_COLLATE "C" LC_CTYPE "C"`
  ([synapse.md](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.md)).
  `services.postgresql.ensureDatabases` does not set a collation, so ticket 10 has to create the `synapse` DB
  explicitly, for example in a one-shot before the restore. The module defaults to DB and role `matrix-synapse`.
  Keeping the name `synapse` only takes `settings.database.args.database`. Peer auth over the socket can replace
  the `synapse_user`/password-over-TCP setup.
- **Extras and plugins.** The wrapper adds the `postgres` and `url-preview` extras automatically from the
  settings ([L76–L93](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L76-L93)).
  If the shared-secret auth module is kept, it is packaged as
  `matrix-synapse-plugins.matrix-synapse-shared-secret-auth` 2.0.3
  ([plugins/default.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/matrix-synapse-unwrapped/plugins/default.nix))
  and goes in `services.matrix-synapse.plugins`. As shown below, nothing uses it today.
- **Listener.** The default listener is `127.0.0.1:8008` with `client` + `federation` resources
  ([L927–L960](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L927-L960)).
  That is tighter than today's `::`, and it is enough behind Caddy.
- **Logging.** The default log config goes to the journal
  ([L95–L107](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L95-L107)),
  which replaces the 60–80 MB/day `homeserver.log`. The old logs are not State.
- **Version.** nixpkgs ships `matrix-synapse-unwrapped` 1.164.2
  ([package.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/matrix-synapse-unwrapped/package.nix)).
  The upgrade notes between 1.157 and 1.165 cover MSC3861→MAS auth, profile-request settings, MatrixRTC and
  Python 3.11+. None of that applies to this setup
  ([upgrade notes](https://element-hq.github.io/synapse/latest/upgrade.html)).
  The DB schema migrates forward on first start. If the Rollback image is used, the Arch Synapse comes back with
  its own pre-Cutover DB, so the schema bump is not a problem, but messages received after the Cutover are
  lost.
- **Size reduction (optional).** `state_groups_state` is 5.6 GB of the 10 GB. nixpkgs has
  `services.synapse-auto-compressor` (rust-synapse-compress-state on a timer)
  ([synapse-auto-compressor.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse-auto-compressor.nix)).
  Running it is not required for the migration.

### Federation, `.well-known`, Caddy

- Today `m.server` points at `nnik.dev:8448`, and nginx terminates TLS on both 443 and 8448 **(live)**. Synapse's
  reverse-proxy docs include a Caddy v2 example with an `example.com:8448` site block
  ([reverse_proxy.md](https://element-hq.github.io/synapse/latest/reverse_proxy.html#caddy-v2)). Delegation
  lets federation use 443 instead, by changing `m.server` to `nnik.dev:443`
  ([delegate.md](https://element-hq.github.io/synapse/latest/delegate.html)).
- The two `.well-known` bodies are tiny static JSON. Caddy can `respond` them inline (ticket 11). The nixpkgs
  chapter does the same thing for nginx with a `return 200` example
  ([synapse.md](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.md)).
- Keep the 200 MB upload limit in the proxy if `max_upload_size` stays at that value.

### Appservice registration files and bridge config (WhatsApp/Signal modules)

- The nixpkgs whatsapp and signal modules hard-code `dataDir = /var/lib/mautrix-<bridge>`, with the registration
  at `${dataDir}/<bridge>-registration.yaml` and the rendered config at `${dataDir}/config.yaml`. On each start,
  `preStart` (1) `envsubst`s the settings JSON into `config.yaml`, (2) generates a registration **only if the file
  is missing**, and (3) uses `yq` to copy `as_token`/`hs_token` from the registration into the config. It also
  optionally sets `double_puppet.secrets[domain]` from `MAUTRIX_<BRIDGE>_BRIDGE_LOGIN_SHARED_SECRET`
  ([mautrix-whatsapp.nix L195–L246](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-whatsapp.nix#L195-L246),
  [mautrix-signal.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-signal.nix)).
  With `registerToSynapse` (default on), the file is added to `app_service_config_files` and Synapse gets the
  bridge group as a `SupplementaryGroup`
  ([L169–L174](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-whatsapp.nix#L169-L174)).
  - **Restore step:** place the current `/etc/synapse/appservices/whatsapp.yaml` and `signal.yaml` at
    `/var/lib/mautrix-whatsapp/whatsapp-registration.yaml` and `/var/lib/mautrix-signal/signal-registration.yaml`,
    owned by the bridge user and mode 640, before the first start. That keeps the same `id`, namespaces,
    `sender_localpart` and tokens. Synapse already associates the appservice users and stream positions with
    these `id`s (9,323 `whatsapp`, 6 `signal` users **(live)**).
  - The rendered `config.yaml` is overwritten on every start, so values the bridge would `generate` get lost. The
    module docs say to set `pickle_key`, `provisioning.shared_secret`, etc. via `environmentFile`
    ([mautrix-whatsapp.md](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-whatsapp.md)).
- **Overrides needed against the module defaults**
  ([mautrix-whatsapp.nix L19–L60](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-whatsapp.nix#L19-L60)):
  - `homeserver.address`: the default is `http://localhost:8448`, so set it to `http://localhost:8008`.
  - `appservice.bot.username`: the default is `whatsappbot`, so set it to `whatsapp`. The Signal default
    `signalbot` already matches.
  - `database`: the default is SQLite, so set `type = "postgres"` with a socket URI such as
    `postgresql:///whatsapp?host=/run/postgresql`.
  - `encryption.pickle_key`: the default is `""`, so set it to the current public default value. Otherwise the
    bridge cannot decrypt its existing crypto store.
  - `bridge.permissions`: set it to today's `"*": relay`, `nnik.dev: user`, `@ya:nnik.dev: admin`.
  - `bridge.personal_filtering_spaces` and `private_chat_portal_meta`: carry them over.
- **Versions and DB upgrade path.** nixpkgs ships mautrix-whatsapp 26.10 (tag `v0.2610.0`) and mautrix-signal
  26.10, both `buildGoModule` against `olm` unless `withGoolm`
  ([whatsapp package.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/mautrix-whatsapp/package.nix),
  [signal package.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/mautrix-signal/package.nix)).
  WhatsApp v26.07 → v26.10 is a small step; direct upgrades are blocked only from versions before v0.11.0
  ([whatsapp CHANGELOG](https://github.com/mautrix/whatsapp/blob/main/CHANGELOG.md)). Signal 0.7.2 → 26.10 is
  supported, because v0.8.7 removed the legacy migration only for versions before 0.7.0
  ([signal CHANGELOG](https://github.com/mautrix/signal/blob/main/CHANGELOG.md)).
- **olm.** `olm` carries `knownVulnerabilities` (deprecated upstream, side-channel issues), so evaluation fails
  unless it is allowed
  ([olm package.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ol/olm/package.nix),
  [PR #334638](https://github.com/NixOS/nixpkgs/pull/334638)). The live bridges link `libolm.so.3` **(live)**.
  The nixpkgs package comment says goolm "is not recommended by the mautrix developers" for production use
  ([whatsapp package.nix L6–L12](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/mautrix-whatsapp/package.nix#L6-L12)).

### mautrix-telegram: Python vs Go in nixpkgs

- **Upstream.** v26.04 rewrote the bridge in Go (bridgev2), with in-place DB and config migration from Python
  ≥0.15.3. **v26.10 removed that legacy migration**: you have to pass through v26.04–v26.09 first
  ([telegram CHANGELOG](https://github.com/mautrix/telegram/blob/main/CHANGELOG.md)). The Optiplex has already
  done this, and its DB is on the bridgev2 schema **(live)**. The Python bridge would not run against that DB.
- **nixpkgs master:** the `mautrix-telegram` package is still the Python **0.15.3** `buildPythonApplication`
  ([package.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/mautrix-telegram/package.nix)).
  The module is Python-shaped: `config.json`, `appservice.database`, `bridge.login_shared_secret_map`, and an
  `alembic upgrade head` in `preStart`
  ([mautrix-telegram.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-telegram.nix)).
  Overriding `package` with a Go build does not fix that, because the module's config layout is wrong for Go.
- **Open PRs:**
  - [#510662](https://github.com/NixOS/nixpkgs/pull/510662) "mautrix-telegram: migrate to Go-based bridgev2
    bridge": opened 2026-04-16, 1 approval, currently has a merge conflict, targets 0.2604.0.
  - [#581772](https://github.com/NixOS/nixpkgs/pull/581772) "nixos/mautrix: unify bridge modules": a **draft**
    opened 2026-11-01, labelled `llm-assisted`. It supersedes #510662 and replaces the per-bridge modules with
    `services.mautrix.bridges`. If it merges, the WhatsApp/Signal option paths change too.
- **The repo draft is stale.** `machines/server/services/matrix/telegram-bridge.nix` is the nixpkgs Python
  example config. `machines/server/services/matrix/synapse.nix` uses removed options such as
  `services.matrix-synapse.turn_uris`
  ([removed-option shims](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix#L286-L295)).
  Both need rewriting rather than reuse.

### mautrix-signal without signald

- signald is not involved any more. mautrix-signal has been Go since v0.5.0, which migrated in place from the
  Python/signald bridge, and bridgev2 since v0.7.0
  ([signal CHANGELOG](https://github.com/mautrix/signal/blob/main/CHANGELOG.md)). The nixpkgs package links
  `libsignal-ffi`, pinned to the version the bridge expects
  ([package.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/mautrix-signal/package.nix)).
  On NixOS, `signald` is simply not configured; it is already Retired in the map.
- The live login is broken: every startup gets `401 Unauthorized` on prekey checks, and the newest row in
  `message` is from 2025-01-27 **(live)**. The linked device has most likely been dropped by Signal. After the
  Cutover, expect to log in again (`!signal login`, QR-link) whether or not the DB is restored.

### Double puppeting

- Megabridges only support the appservice method: a second registration such as `doublepuppet.yaml` with
  `url: null` and a non-exclusive `@.*:nnik\.dev` user namespace, with `double_puppet.secrets.nnik.dev:
  "as_token:<token>"` in each bridge. One registration can be shared by all bridges. "The older methods are
  deprecated and were completely removed in the megabridge rewrites"
  ([docs.mau.fi double puppeting](https://docs.mau.fi/bridges/general/double-puppeting.html)).
- The code confirms this: `Setup()` uses the secret only if it starts with `as_token:`. Otherwise it falls back
  to a saved per-user token
  ([mautrix-go doublepuppet.go](https://github.com/mautrix/go/blob/main/bridgev2/matrix/doublepuppet.go)).
  The live configs use a non-`as_token:` secret, and `user.access_token` is empty in every bridge DB
  **(live)**. So double puppeting is not active today. The Synapse `shared_secret_authenticator` module and its
  secret serve no bridge.

### coturn

- The nixpkgs `services.coturn` module supports `use-auth-secret` with `static-auth-secret-file`. The secret is
  substituted at runtime, so it stays out of the store. It also supports `min-port`/`max-port`,
  `no-tcp-relay`, `cert`/`pkey` and `extraConfig`
  ([coturn.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/networking/coturn.nix)).
- Synapse's coturn guide uses `use-auth-secret` + `static-auth-secret` = Synapse's `turn_shared_secret`, plus
  `no-tcp-relay` and a list of `denied-peer-ip` ranges that includes IPv6
  ([coturn.md](https://element-hq.github.io/synapse/latest/setup/turn/coturn.html),
  [turn-howto](https://element-hq.github.io/synapse/latest/turn-howto.html)).
- Today's `turnserver.conf` uses `no-auth`, so anyone who can reach 3478 can allocate relays. Its
  `allowed-peer-ip` exceptions also make LAN hosts .21–.40 relay targets **(live)**. There is no relay port range
  in the config, so the router's forwarding (if any) decides what works. The repo's stale draft already sketches
  the Synapse-guide config with ports 49000–50000.

### Were the cron restarts masking a problem?

- Root crontab: `0 */4 * * * sudo systemctl restart mautrix-{telegram,whatsapp,signal}` (plus invidious). Yannik's
  crontab: `0 */6 * * * systemctl restart {mautrix-*,signald,synapse}` **(live)**. The journal shows both sets
  firing at 00:00 today, but only root's commands go through `sudo`.
- Synapse: `ActiveEnterTimestamp` is 2026-09-27, and the journal (which starts 2026-10-04) has no systemd
  start/stop events for `synapse.service`. So the user-level restarts have been failing silently, and Synapse
  has run for more than 5 weeks without trouble, using 470 MB now and 640 MB at peak.
- Bridges: they are restarted every 4 h and use about 30–40 MB each **(live)**. There is no error pattern in
  WhatsApp/Telegram that a restart would fix. The Signal errors come from the dead login, not from uptime. The
  timing (a signald restart in the same crontab) points to the Python/signald era. The NixOS units use
  `Restart=on-failure`
  ([mautrix-whatsapp.nix L246–L268](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-whatsapp.nix#L246-L268)).
  The only real test is to run without the restarts and watch.

## Options / trade-offs

1. **How to run Go mautrix-telegram**
   - (a) **Local package + module** in this repo: `buildGoModule` for `mautrix/telegram` v26.10, plus a module
     copied from `mautrix-whatsapp.nix`, and `disabledModules` for the nixpkgs module. Full control and works now,
     but it has to be maintained until nixpkgs catches up.
   - (b) **Use PR #510662 or #581772 as a flake input**, importing only that module/package. Less code, but it
     depends on an unmerged branch (#581772 is a draft and also renames the WhatsApp/Signal modules).
   - (c) **Wait** for the PR to merge before the Cutover. Zero local code, but the schedule depends on upstream.
   - (d) **Systemd unit only**, without the module: the package plus a hand-written service with the current
     `config.yaml` handled as a sops template. Simplest, but drops the module's registration/token plumbing.
2. **Where Synapse State lives:** keep the NixOS default `/var/lib/matrix-synapse` on the System disk, or put
   `media_store_path` (25 GB, still growing) on the Data disk. That is ticket 03's call. The signing key works
   as a sops secret or as a restored file.
3. **Federation port:** keep `:8448` in Caddy (no `.well-known` change, router forward stays), or switch
   `m.server` to `nnik.dev:443` and close 8448.
4. **Double puppeting:** carry the current (inactive) state over as-is and drop the shared-secret plugin, or add
   a `doublepuppet` appservice so all bridges double-puppet `@ya:nnik.dev` automatically. The second is a new
   feature, not a migration need.
5. **olm:** `permittedInsecurePackages` for `olm` (same crypto as today), or `withGoolm = true` (pure Go,
   flagged by nixpkgs as not recommended upstream).
6. **Signal:** migrate the `signal` DB and re-link, or start Signal fresh. The 3 portals and the dead login
   barely matter. Retiring the Signal bridge is also an option.
7. **coturn:** keep it open (`no-auth`), as today, or switch to `use-auth-secret` with Synapse's secret, the
   standard `denied-peer-ip` list, and a fixed relay port range that matches the router.
8. **Bridge restarts:** drop the cron restarts and rely on `Restart=on-failure` (recommended by the evidence),
   or add a systemd timer as a fallback if something hangs later.
9. **DB compaction:** optionally enable `services.synapse-auto-compressor` after the Cutover, not during it.

## Open questions

- Ticket 03: does the 25 GB media store (and `remote_content`, which could be purged) go to the Data disk?
- Ticket 10: DB and role names on NixOS (`synapse` vs `matrix-synapse`; bridges currently share
  `synapse_user`), and creating the `synapse` DB with `C` collation before `pg_restore`.
- Ticket 11 (Caddy): `:8448` vs delegation to `:443`; inline `.well-known`.
- Does the router forward 8448, 3478 and a UDP relay range to the Optiplex today? That affects the coturn
  port range and the federation-port choice.
- Should public registration (`enable_registration: true` + reCAPTCHA) stay on?
- Is the Signal bridge still a Kept service, given that its login has been dead since January 2025?
- Which `mautrix-telegram` route (1a–1d)? Re-check the status of #510662/#581772 just before writing the
  config.

## Sources

- nixpkgs (pinned 0734212d):
  [synapse.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.nix),
  [synapse.md](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse.md),
  [synapse-auto-compressor.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/synapse-auto-compressor.nix),
  [mautrix-whatsapp.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-whatsapp.nix),
  [mautrix-whatsapp.md](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-whatsapp.md),
  [mautrix-signal.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-signal.nix),
  [mautrix-signal.md](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-signal.md),
  [mautrix-telegram.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/matrix/mautrix-telegram.nix),
  [coturn.nix](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/nixos/modules/services/networking/coturn.nix),
  [matrix-synapse-unwrapped](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/matrix-synapse-unwrapped/package.nix),
  [synapse plugins](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/matrix-synapse-unwrapped/plugins/default.nix),
  [mautrix-whatsapp pkg](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/mautrix-whatsapp/package.nix),
  [mautrix-signal pkg](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/mautrix-signal/package.nix),
  [mautrix-telegram pkg](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ma/mautrix-telegram/package.nix),
  [olm pkg](https://github.com/NixOS/nixpkgs/blob/0734212d269c1ccfb74ab571b930b3a210555680/pkgs/by-name/ol/olm/package.nix)
- nixpkgs PRs: [#510662](https://github.com/NixOS/nixpkgs/pull/510662),
  [#581772](https://github.com/NixOS/nixpkgs/pull/581772), [#334638](https://github.com/NixOS/nixpkgs/pull/334638)
- Synapse docs: [config: signing_key_path](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#signing_key_path),
  [config: macaroon_secret_key](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#macaroon_secret_key),
  [postgres](https://element-hq.github.io/synapse/latest/postgres.html),
  [upgrade notes](https://element-hq.github.io/synapse/latest/upgrade.html),
  [reverse proxy](https://element-hq.github.io/synapse/latest/reverse_proxy.html),
  [delegation](https://element-hq.github.io/synapse/latest/delegate.html),
  [TURN howto](https://element-hq.github.io/synapse/latest/turn-howto.html),
  [coturn](https://element-hq.github.io/synapse/latest/setup/turn/coturn.html)
- mautrix: [double puppeting](https://docs.mau.fi/bridges/general/double-puppeting.html),
  [telegram CHANGELOG](https://github.com/mautrix/telegram/blob/main/CHANGELOG.md),
  [signal CHANGELOG](https://github.com/mautrix/signal/blob/main/CHANGELOG.md),
  [whatsapp CHANGELOG](https://github.com/mautrix/whatsapp/blob/main/CHANGELOG.md),
  [mautrix-go doublepuppet.go](https://github.com/mautrix/go/blob/main/bridgev2/matrix/doublepuppet.go)
- Live server: read-only `ssh optiplex` (systemctl, pacman, psql catalog queries, config key names, journal),
  2026-11-06.
