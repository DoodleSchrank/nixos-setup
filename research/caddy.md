# Caddy on NixOS replacing nginx on the Optiplex

Research for ticket 11 of the Optiplex migration map (`.scratch/optiplex-nixos-migration/issues/11-research-caddy.md`).
Researched 2026-11-06 against nixpkgs-unstable `6dadaf4375be35033e1c84395adbd53ff5fded96` (Caddy 2.11.7) and the live nginx config on the Optiplex (read-only, over `ssh optiplex`).

## Question

How should `services.caddy` on NixOS replace the current nginx? Cover:

- TLS for `*.nnik.dev`: HTTP-01, or DNS-01 via Porkbun (which needs a plugin build, `caddy.withPlugins`).
- LAN-only HTTP vhosts under `*.opti.plex`.
- Synapse federation on :8448, plus `.well-known/matrix/*`.
- The Vaultwarden websocket.
- Seafile/seadoc paths.
- Large uploads (Paperless, Seafile).
- How NixOS modules that assume nginx fit in.

## Short answer

- **TLS.** Today there is one Let's Encrypt cert for `*.nnik.dev` + `nnik.dev`. Certbot gets it through the Porkbun DNS-01 plugin (observed in `/etc/letsencrypt/renewal/nnik.dev.conf`). Caddy can do the same: build it with `pkgs.caddy.withPlugins { plugins = [ "github.com/caddy-dns/porkbun@v0.3.1" ]; hash = …; }` and set the global `dns porkbun { … }` option. Since Caddy 2.10, every `foo.nnik.dev` site automatically uses a configured `*.nnik.dev` wildcard cert ([patterns][c-patterns], [auto-https][c-ahttps]).
- **Secrets without an env file.** The porkbun module runs its keys through Caddy's global replacer ([module.go][pb-module]). That replacer resolves `{file./run/secrets/…}` as well as `{env.…}` ([replacer.go][c-replacer], [placeholders][c-conv]). So sops-nix secret files can be referenced directly. `services.caddy.environmentFile` also exists ([module][nix-caddy]).
- **Fallback with no plugin build.** NixOS `security.acme` (lego) supports Porkbun natively. Caddy can then use that cert through `virtualHosts.<n>.useACMEHost` ([vhost-options][nix-caddy-vhost], [lego porkbun][lego-pb], [acme module][nix-acme]).
- **HTTP-01 is possible but changes things.** It needs port 80 reachable from the internet. It can't issue wildcards ([auto-https][c-ahttps]), so you'd get one cert per name.
- **LAN vhosts.** Prefix the address with `http://` (for example `http://paperless.opti.plex`). This turns automatic HTTPS off for that site ([auto-https][c-ahttps]). `.plex` can never get a public cert anyway. Today's nginx `allow 192.168.178.0/24` lines do nothing because there's no `deny` ([nginx access][ngx-access]). Only `pihole` actually restricts access. In Caddy, a real restriction is `@outside not remote_ip private_ranges` → `abort` ([matchers][c-matchers]).
- **Matrix.** Synapse's own docs have a Caddy example. Add a `nnik.dev:8448` site with `reverse_proxy /_matrix/* localhost:8008`, and serve `.well-known` with `respond` plus `header` ([synapse reverse_proxy.md][syn-rp]). Port 8448 must be opened manually, because `openFirewall` only opens 80/443 ([module][nix-caddy]). One finding: today's `/.well-known/matrix/client` file is **invalid JSON** (trailing comma) and has no CORS header. The spec says a client must FAIL_PROMPT on unparsable JSON and that servers SHOULD send CORS headers ([CS API][mx-cs]).
- **Websockets and upload limits mostly disappear.** Caddy proxies websockets automatically ([reverse_proxy][c-rp]). It sets X-Forwarded-For, -Proto and -Host and passes `Host` through by default ([reverse_proxy#defaults][c-rp]). Body size is limited only if you set `request_body max_size` ([request_body][c-reqbody]). The reverse-proxy transport has no read or response-header timeout by default ([reverse_proxy][c-rp]). Most nginx `proxy_set_header`, `client_max_body_size` and `proxy_read_timeout` lines therefore have no Caddy equivalent. The exception is Vaultwarden: it reads `X-Real-IP` by default ([.env.template][vw-env]), so add `header_up X-Real-IP {remote_host}` as in Vaultwarden's Caddy example ([proxy examples][vw-proxy]).
- **NixOS modules that assume nginx.** Only `paperless` and `vaultwarden` have a `configureNginx` option. Synapse, etebase, Gitea/Forgejo, Home Assistant and Transmission don't touch any proxy ([paperless.nix][nix-paperless], [vaultwarden][nix-vw]). Leave `configureNginx` off and write the equivalent Caddy vhost. One pitfall: setting `services.paperless.domain` forces `PAPERLESS_URL = "https://…"` ([paperless.nix L526–527][nix-paperless]). That's wrong for the HTTP-only `paperless.opti.plex`, so set `PAPERLESS_URL` yourself.
- **Seafile.** `seafile-server` was removed from nixpkgs ("unmaintained", 2025-08-21, [aliases.nix][nix-aliases]), and the NixOS module is gone from `module-list.nix`. The Caddy layout depends on ticket 04. If it ends up native, upstream's paths map to Caddy `handle_path` blocks ([seafile nginx][sf-nginx], [seadoc][sf-seadoc], [handle_path][c-handlepath]).
- **Version caveat.** This repo's current `flake.lock` pins nixpkgs `de0fe30` (Mar 2025), which ships Caddy **2.9.1** ([package.nix @ pin][nix-caddy-pin]). The `dns` global option and wildcard reuse need Caddy ≥ 2.10 ([options][c-options], [patterns][c-patterns]). Bump nixpkgs before writing this config.

## Details

### 1. The NixOS `services.caddy` module

Source: [`nixos/modules/services/web-servers/caddy/default.nix`][nix-caddy] and [`vhost-options.nix`][nix-caddy-vhost].

- **Config.** `virtualHosts.<name>` has `hostName`, `serverAliases`, `listenAddresses`, `useACMEHost`, `logFormat` and `extraConfig`. The module renders a Caddyfile from `globalConfig`, `extraConfig` and the vhosts (default.nix L19–39, L43–63). At build time it runs `caddy fmt --overwrite` (L57–61). That **formats** the file but does not **validate** it. Validation only happens on reload: `ExecReload` runs `caddy reload … --force` (L480–483), and a NixOS VM test runs the real binary.
- **Per-vhost access logs.** Each vhost writes `output file /var/log/caddy/access-<host>.log` by default (vhost-options L58–62).
- **Reload, not restart.** `enableReload` defaults to true and uses the admin API. Its description suggests setting `grace_period` so a reload doesn't wait forever for open connections ([module][nix-caddy]; [options#grace_period][c-options]: "By default, the grace period is eternal"). A reload force-closes websockets unless `stream_close_delay` is set ([reverse_proxy#streaming][c-rp]). Vaultwarden, Home Assistant, Gitea and seadoc clients reconnect on every deploy.
- **State.** `dataDir` defaults to `/var/lib/caddy`, a systemd `StateDirectory` (L487) holding certs and the ACME account. Losing it only means re-issuing certs. Hardening: `ProtectHome=true`, `PrivateDevices`, `NoNewPrivileges` (L493–497). Static roots must not live under `/home`. `/srv/http/*` (today's roots) is fine as long as the `caddy` user can read it.
- **Firewall.** `openFirewall` opens TCP 80/443 and UDP 443 for HTTP/3 (L397–410, L527–533). Other ports, such as 8448, must go into `networking.firewall` by hand. The module also raises `net.core.rmem_max`/`wmem_max` for QUIC (L451–452).
- **Secrets.** `environmentFile` passes secrets in without putting them in the store (L363–395).
- **`acmeCA`.** Its description recommends LE staging while testing (L267–285). That matters for VM tests and the first cutover attempts. LE rate limits apply to repeated real issuance.
- **`useACMEHost`.** Uses a cert from `security.acme`. The module adds `wants`/`after` on `acme-<cert>.service`, sets the cert's group to `caddy` and adds `reloadServices = [ "caddy.service" ]` (L16–17, L455–456, L511–524). The option text says it's meant for "DNS challenges but Caddy does not currently support your provider" (vhost-options L44–56).

### 2. TLS for `*.nnik.dev`

**What exists today** (observed on the Optiplex):

- One cert, `CN=*.nnik.dev`, SAN `*.nnik.dev, nnik.dev`.
- Certbot issues it with `authenticator = dns-porkbun` and `pref_challs = dns-01`.
- Every nnik.dev vhost uses `/etc/letsencrypt/live/nnik.dev/`.
- Public DNS has a wildcard: `nnik.dev`, `www.nnik.dev`, `pw.nnik.dev`, `www.pw.nnik.dev` and `randomxyz.nnik.dev` all resolve to the same public IP.
- `certbot-renew.timer` is `disabled`. How renewal runs today wasn't investigated, and it doesn't matter after the cutover.

**Option A: Caddy does DNS-01 itself.**

- **Build.** `pkgs.caddy.withPlugins` ([plugins.nix][nix-caddy-plugins]) runs `xcaddy build v<version> --with <plugins>` and vendors the result into a **fixed-output derivation**. Plugins must carry a tag or pseudo-version (assert, L42–48). The FOD's `version` is the Caddy version (L59–61), so **every Caddy bump in nixpkgs changes the FOD and you must update `hash`**. Until you do, the build fails with a hash mismatch, so plan for this on each `nix flake update`. An install check confirms the plugin version made it into `caddy build-info` (L98–168). Usage example: [plugins.test.nix][nix-caddy-plugins-test].
- **Plugin.** [`caddy-dns/porkbun`][pb-readme], latest tag `v0.3.1` (2025-05-09). Its `go.mod` requires `caddy/v2 v2.10.0` and `libdns/porkbun v1.0.1` (libdns 1.x) ([go.mod][pb-gomod]). Caddy 2.11.7 uses `libdns v1.1.1` ([caddy go.mod][c-gomod]), so the APIs match. The README notes that versions before 0.2.0 use a dead API hostname. Module name: `dns.providers.porkbun`, with fields `api_key` and `api_secret_key`.
- **Credentials.** `Provision` passes both fields through `caddy.NewReplacer().ReplaceAll` ([module.go L26–30][pb-module]). `NewReplacer` includes the env provider and `fileReplacementProvider` ([replacer.go L34–44, L350+][c-replacer]). So both `{env.PORKBUN_API_KEY}` and `{file./run/secrets/porkbun-api-key}` work. Caddy docs recommend `{file.*}` because it keeps the secret out of the process environment ([concepts#environment-variables][c-concepts]).
- **Caddyfile.** Since 2.10 there is a global `dns <provider>` default ([options#dns][c-options]); `acme_dns` also still exists. One `*.nnik.dev` site with `tls { dns porkbun … }` is enough. All `x.nnik.dev` sites then reuse the wildcard. Caddy "will not get certificates for individual subdomains unless explicitly configured to do so" ([auto-https#wildcard-certificates][c-ahttps], [patterns#wildcard-certificates][c-patterns]). `nnik.dev` itself (apex) still needs its own name on a cert. With a global `dns` default, Caddy gets it by DNS-01 too, so port 80 isn't needed for issuance.

  ```caddyfile
  {
  	email <you>
  	dns porkbun {
  		api_key {file./run/secrets/porkbun_api_key}
  		api_secret_key {file./run/secrets/porkbun_secret_key}
  	}
  }
  *.nnik.dev {
  	abort   # fallback for unknown subdomains; real sites below reuse this cert
  }
  ```

  Sketch only, built from the cited docs. Not tested.

**Option B: `security.acme` (lego) issues, Caddy consumes.**

- lego has a built-in `porkbun` provider with env vars `PORKBUN_API_KEY` and `PORKBUN_SECRET_API_KEY` ([porkbun.toml][lego-pb]).
- NixOS `security.acme.certs.<n>` has `dnsProvider`, `environmentFile`/`credentialFiles`, `extraDomainNames` and `reloadServices` ([acme/default.nix L770, L812–870, L966][nix-acme]).
- Each Caddy vhost then sets `useACMEHost = "nnik.dev"`. The module emits `tls <dir>/cert.pem <dir>/key.pem` and wires up the systemd ordering and group ([default.nix L19–39, L511–524][nix-caddy]).
- No custom Caddy build and no FOD hash churn.
- Catch: you must set `useACMEHost` on **every** nnik.dev vhost. Manually loaded certs also disable automation for those names unless `auto_https ignore_loaded_certs` is set ([options#auto_https][c-options], [auto-https][c-ahttps]).

**Option C: HTTP-01 / TLS-ALPN-01.**

- Enabled by default, nothing to configure. Needs ports 80 and 443 reachable from outside ([auto-https#acme-challenges][c-ahttps]).
- Caddy would issue one cert per site name.
- Wildcards need DNS-01 ([patterns][c-patterns]).

**Related: the `www.` aliases.** nginx lists `www.<sub>.nnik.dev` for every vhost. A wildcard only covers one label (`*.*.example.com` doesn't qualify, [auto-https][c-ahttps]), so `www.pw.nnik.dev` etc. are **not covered by today's cert either**. HTTPS to them fails today. Only `www.nnik.dev` is valid.

### 3. LAN-only vhosts under `*.opti.plex`

- **Plain HTTP.** Caddy turns automatic HTTPS off for a site when its address starts with `http://` ([auto-https#activation][c-ahttps]). `.plex` isn't a public suffix, so no public CA would issue for it ([auto-https#hostname-requirements][c-ahttps]). The alternative is `tls internal`, which brings Caddy's local CA and needs its root trusted on every client.
- **Access control.** nginx's `allow`/`deny` rules are checked in order until the first match ([ngx_http_access_module][ngx-access]). With only `allow 192.168.178.0/24` and no `deny`, everyone gets in. The `opti.plex`, `transmission`, `paperless`, `homeassistant` and `portainer` blocks are therefore **not** restricted today. Only `pihole` has `deny all`. In Caddy: `@outside not remote_ip private_ranges` then `abort @outside`. `private_ranges` covers 192.168/16, 172.16/12, 10/8, 127/8, fd00::/8 and ::1 ([matchers#remote_ip][c-matchers]). Whether this matters depends on whether the router forwards port 80 (open question).
- **Default site on :80.** nginx uses `opti.plex` as `default_server` on :80, so `http://192.168.178.20/` shows the dashboard. In Caddy, list `http://192.168.178.20` as another address of that site if you want to keep this.
- **DNS.** Name resolution for `*.opti.plex` moves from Pi-hole to blocky (out of scope here; see the map).

### 4. Matrix: federation on :8448 and `.well-known`

**Today** (observed): the `nnik.dev` vhost listens on 443 and on `8448 ssl default_server`. It proxies `^(/_matrix|/_synapse/client)` to `localhost:8008` with `client_max_body_size 200M`, and serves `.well-known` from files. `/.well-known/matrix/server` = `{"m.server": "nnik.dev:8448"}`. `/.well-known/matrix/client` has a **trailing comma** (invalid JSON), `content-type: application/octet-stream` and no `Access-Control-Allow-Origin`. The spec says that if the content can't be parsed, the client must FAIL_PROMPT, and that servers hosting the file SHOULD offer CORS headers ([CS API #well-known-uri][mx-cs]).

**Caddy, per Synapse's docs** ([reverse_proxy.md "Caddy v2"][syn-rp]):

```caddyfile
nnik.dev {
	header /.well-known/matrix/* Content-Type application/json
	header /.well-known/matrix/* Access-Control-Allow-Origin *
	respond /.well-known/matrix/server `{"m.server": "nnik.dev:8448"}`
	respond /.well-known/matrix/client `{"m.homeserver":{"base_url":"https://nnik.dev"}}`
	reverse_proxy /_matrix/* localhost:8008
	reverse_proxy /_synapse/client/* localhost:8008
}
nnik.dev:8448 {
	reverse_proxy /_matrix/* localhost:8008
}
```

- **Proxy rules.** Synapse requires that the proxy not canonicalise the URI and that it set `X-Forwarded-For`/`-Proto`, with `x_forwarded: true` on the listener ([reverse_proxy.md][syn-rp]). Caddy's defaults do both ([reverse_proxy#defaults][c-rp]).
- **Upload size.** Synapse's `max_upload_size` (default 50M) is what limits uploads. The note about raising the proxy limit applies to nginx ([config docs #max_upload_size][syn-cfg]). Caddy has no default body limit, so there's nothing to raise.
- **Alternatives to hand-written `.well-known`.**
  - Synapse can serve `/.well-known/matrix/server` itself (`serve_server_wellknown`). That file sends federation to **:443**, which lets you drop :8448 ([config docs #serve_server_wellknown][syn-cfg], [delegate.md][syn-deleg]).
  - Synapse also serves `/.well-known/matrix/client` itself when `public_baseurl` is set (`extra_well_known_client_content`, [config docs][syn-cfg]).
  - In both cases Caddy would only proxy `/.well-known/matrix/*` to 8008.
- **Federation port.** A `nnik.dev:8448` site uses the same certificate as `nnik.dev`. Port 8448/TCP must be opened in `networking.firewall` ([module L397–410][nix-caddy]). Federation on 8448 currently answers (`/_matrix/federation/v1/version` → 200).
- **Nothing to switch off.** The NixOS Synapse module itself has no proxy option. The NixOS manual's Synapse chapter just *uses* nginx in its example ([synapse.md L74][nix-synapse-md]).

### 5. Vaultwarden websocket

- **Today.** nginx uses an `upstream` with keepalive, `Upgrade`/`Connection` maps, `client_max_body_size 525M` and `X-Real-IP` (copied from Vaultwarden's nginx example, [proxy examples][vw-proxy]).
- **Caddy.** Websockets are handled automatically ([reverse_proxy#streaming][c-rp]). Vaultwarden's own Caddy example is just `reverse_proxy 127.0.0.1:8000 { header_up X-Real-IP {remote_host} }` ([proxy examples][vw-proxy]). The header matters because `IP_HEADER` defaults to `X-Real-IP` ([.env.template L331–343][vw-env]), and Caddy doesn't set X-Real-IP by default ([reverse_proxy#defaults][c-rp]). The alternative is `IP_HEADER=X-Forwarded-For`.
- **NixOS module.** `services.vaultwarden.configureNginx` sets up nginx locations for `/notifications/hub` and `/notifications/anonymous-hub` with websockets and sets `ENABLE_WEBSOCKET = true` ([vaultwarden/default.nix L161–165, L226–265][nix-vw]). With Caddy, leave it off and set `services.vaultwarden.domain`, which sets `DOMAIN` (L259).

### 6. Seafile / seadoc

**Today.** `filesync.nnik.dev` sends everything to the Docker container's built-in proxy (`:25577`, `client_max_body_size 0`, `proxy_read_timeout 310s`). It also sends `/sdoc-server/` (prefix stripped by `proxy_pass …/`) and `/socket.io` (websocket) to `127.0.0.1:25578`. Nothing listened on 25578 when checked, so seadoc may already be down.

**Native layout.** If Seafile ends up native (ticket 04; nixpkgs dropped it, [aliases.nix L2451][nix-aliases]), upstream's Seafile 12 layout is:

| Path | Backend | Source |
| --- | --- | --- |
| `/` | seahub `:8000`, `client_max_body_size 0`, `proxy_read_timeout 1200s` | [https_with_nginx.md][sf-nginx] |
| `/seafhttp` | fileserver `:8082`, **prefix stripped**, timeouts 36000s | same |
| `/media` | static root `…/seahub` | same |
| `/sdoc-server/` | seadoc, **prefix stripped**, `client_max_body_size 100m` | [setup_seadoc.md][sf-seadoc] |
| `/socket.io` | seadoc, websocket | same |

**In Caddy:**

- `handle_path /seafhttp/* { reverse_proxy 127.0.0.1:8082 }` and `handle_path /sdoc-server/* { … }`. `handle_path` = `handle` + `uri strip_prefix` ([handle_path][c-handlepath]).
- `reverse_proxy /socket.io/* …` for the websocket.
- No timeout or body settings needed: there's no default body limit, and the transport has no read timeout ([reverse_proxy#the-http-transport][c-rp]).
- Caddy's server `read_body_idle` (default 1m) only aborts uploads that *stall* for 1 minute ([options#timeouts][c-options]).

If Seafile stays a container or a self-packaged service with its own internal proxy, today's two-upstream layout carries over unchanged.

### 7. Large uploads

- **nginx.** Default `client_max_body_size` is 1m ([ngx core][ngx-core]), hence the per-vhost overrides today: Synapse 200M, Paperless 200m, Vaultwarden 525M, Gitea/pnp/Seafile 0.
- **Caddy.** No body limit unless `request_body { max_size … }` is used ([request_body][c-reqbody]). So nothing is needed, and limits can be added back where wanted. The application limits still apply: Synapse `max_upload_size` ([syn-cfg][syn-cfg]), and Seafile `max_upload_size` in `seafile.conf` ([sf-nginx][sf-nginx]).
- **Gitea.** Its reverse-proxy docs only ask for `Host`/`X-Forwarded-Proto`, no URI decoding, and Upgrade for `/-/ws` ([Gitea reverse proxies][gitea-rp]). Caddy does all of this by default.

### 8. NixOS modules that assume nginx

| Module | nginx coupling | With Caddy |
| --- | --- | --- |
| `services.paperless` | `configureNginx` (needs `domain`) proxies `/`, serves `/static/` from the package, proxies the websocket `/ws/status` ([paperless.nix L404–509][nix-paperless]). Setting `domain` also forces `PAPERLESS_URL = "https://${domain}"` (L526–527). | Leave `configureNginx` off and `reverse_proxy` everything (today nginx also proxies all of it to the container). For `paperless.opti.plex` over HTTP, set `settings.PAPERLESS_URL = "http://paperless.opti.plex"` instead of `domain` ([PAPERLESS_URL][pl-conf]). |
| `services.vaultwarden` | `configureNginx` (needs `domain`) adds websocket locations and `ENABLE_WEBSOCKET` ([L161–165, L226–265][nix-vw]) | Leave it off; set `domain`; see §5. |
| `services.matrix-synapse` | none in the module; the manual example uses nginx ([synapse.md][nix-synapse-md]) | §4 |
| `services.etebase-server` | none; `static_root` defaults to `${dataDir}/static`; optional `unixSocket` ([etebase-server.nix L62–108][nix-etebase]) | `handle_path /static/* { root * <static_root>; file_server }` plus `reverse_proxy`. If you use the unix socket, `reverse_proxy unix//…` ([reverse_proxy#upstream-addresses][c-rp]); `caddy` must be able to read the socket and the static dir. |
| `services.etesync-dav` | none (host/port options) ([etesync-dav.nix][nix-etesync-dav]) | plain `reverse_proxy` |
| Gitea/Forgejo, Home Assistant, Transmission | none ([gitea.nix][nix-gitea], [forgejo.nix][nix-forgejo], [home-assistant.nix][nix-ha], [transmission.nix][nix-transmission]) | plain `reverse_proxy`; see table below for app-side settings |

### 9. Per-vhost mapping: current nginx → Caddy

Shared nginx snippets today (observed):

- **`nginxconfig.io/security.conf`** adds `X-XSS-Protection`, `X-Content-Type-Options`, `Referrer-Policy no-referrer-when-downgrade`, a permissive `Content-Security-Policy … frame-ancestors 'self'` and `Permissions-Policy`. It also denies dotfiles except `.well-known`.
- **`general.conf`** sets gzip, quiet logging for favicon/robots/static assets, and `Access-Control-Allow-Origin *` on font files.

Two quirks:

- **nginx `add_header` inheritance.** A level only inherits `add_header` from its parent "if and only if there are no `add_header` directives defined on the current level" ([ngx headers][ngx-headers]). So `pnp`/`pnp-backend` (which have their own `add_header` inside `location /`) send **only** their CSP. This is confirmed live.
- **`ya.nnik.dev` sends no security headers.** A missing `;` after `index index.html` turns the following `include …security.conf` line into extra `index` arguments. This is confirmed live too.

Caddy equivalent: a snippet `(security) { header ?X-Content-Type-Options nosniff … }`, imported per site. The `?` prefix sets a header only if the backend didn't, and `-` removes one ([header][c-header]). Use `encode zstd gzip` in each site that wants compression.

| Vhost | Backend today | Special nginx handling | Caddy equivalent |
| --- | --- | --- | --- |
| `nnik.dev`, `www.nnik.dev` (+ :8448) | Synapse `:8008` | 8448 listener, http2; `/_matrix`, `/_synapse/client` proxy, 200M body, XFF/Proto/Host; `.well-known` files; security+general; :80 redirects to `https://www.nnik.dev`; nothing served at `/` (404) | §4 block. `www.nnik.dev { redir https://nnik.dev{uri} }` or keep the 404. HTTP→HTTPS redirects are automatic ([auto-https][c-ahttps]). |
| `ya.nnik.dev` | static `/srv/http/www.ya.nnik.dev` | general.conf; security.conf *not* applied (bug above) | `root * /srv/http/www.ya.nnik.dev` + `file_server`. Note the stale draft uses `/srv/http/ya.nnik.dev`, which is wrong. |
| `koke.nnik.dev`, `immo.nnik.dev` | static `/srv/http/{koke,immo}.nnik.dev` (Flutter web) | `try_files $uri $uri/ =404`; custom CSP for Flutter (`'wasm-unsafe-eval'`, gstatic canvaskit, fonts) | `root` + `file_server` (already 404s on missing files, serves `index.html` for directories) + `header Content-Security-Policy "<same string>"` |
| `dav.nnik.dev` | etesync-dav `127.0.0.1:37358` | security+general | `reverse_proxy localhost:<port>` + `import security` |
| `etesync.nnik.dev` | etebase `127.0.0.1:25567` (`/static/` from `/srv/etesync/static`) | Upgrade/Connection, Host, X-Real-IP, XFF, `X-Forwarded-Host $server_name`, `proxy_redirect off` | `handle_path /static/* { root * <static_root>; file_server }` + `reverse_proxy`. XFH/XFF/Upgrade are defaults. |
| `git.nnik.dev` | Gitea `:25579` (container) | `client_max_body_size 0`, Upgrade, Host, X-Real-IP, XFF, Proto; debug error log | `reverse_proxy localhost:<port>`; nothing else needed ([gitea-rp][gitea-rp]). Gitea SSH (`:25580→22`) doesn't go through the proxy. |
| `elabftw.nnik.dev` | elabimg `127.0.0.1:25569` (container port 443, but proxied as plain http) | Host, X-Real-IP, XFF, Proto; security | `reverse_proxy` + `import security`. The backend shape (native PHP-FPM vs other) is ticket 05. With PHP-FPM it would be `php_fastcgi` instead. |
| `pnp.nnik.dev` / `pnp-backend.nnik.dev` | Own apps `:8088` / `:8087` (containers) | `client_max_body_size 0`, Upgrade, X-Real-IP; CSP `default-src 'self' http: https: data: blob: 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'` (only header sent) | `reverse_proxy` + `header Content-Security-Policy "<same>"`. Backend: ticket 14. |
| `pw.nnik.dev` | Vaultwarden `:25566` | keepalive upstream, websocket map, 525M, X-Real-IP, http2 | `reverse_proxy localhost:<port> { header_up X-Real-IP {remote_host} }` (§5) |
| `filesync.nnik.dev` | Seafile container `:25577`; seadoc `:25578` | `/sdoc-server/` strip prefix, `/socket.io` websocket, body 0 / 100m, read timeout 310s | §6 |
| `opti.plex` (+ `www.`) | static `/srv/http/opti.plex` | default_server :80; `allow` LAN (no-op); CSP `frame-ancestors 'self' http://opti.plex`; `X-Frame-Options ALLOW-FROM http://localhost` | `http://opti.plex, http://www.opti.plex, http://192.168.178.20 { root …; file_server; header … }` + optional `remote_ip` guard (§3) |
| `transmission.opti.plex` | Transmission `:25559` | `/` → `/`, `/rpc` → `/transmission/rpc`; hides upstream `X-Frame-Options` (for iframing in the dashboard); read timeout 300s; passes `X-Transmission-Session-Id` | `http://transmission.opti.plex { header -X-Frame-Options; rewrite /rpc /transmission/rpc; reverse_proxy localhost:9091 }`. Headers pass through by default. Transmission's `rpc-host-whitelist` must allow the vhost name, since Caddy forwards `Host` unchanged ([reverse_proxy#defaults][c-rp]). |
| `paperless.opti.plex` | Paperless `:25575` | 200m body, read timeout 300s, hides `X-Frame-Options` (copy-pasted from the transmission block) | `http://paperless.opti.plex { header -X-Frame-Options; reverse_proxy … }` + `PAPERLESS_URL=http://paperless.opti.plex` (§8) |
| `homeassistant.opti.plex` | HA `:8123` | websocket Upgrade, XFF | `http://homeassistant.opti.plex { reverse_proxy localhost:8123 }`. HA needs `http.use_x_forwarded_for: true` and `trusted_proxies: [127.0.0.1, ::1]`, or it blocks proxied requests ([HA http][ha-http]). |
| `portainer`, `pihole`, `fredy` `.opti.plex`; port 81 `stub_status` | n/a | n/a | Drop. Portainer and Pi-hole are Retired, fredy is a dead leftover (map). Port 81 `stub_status` is nginx-only monitoring. |

Each Caddy line above is a sketch derived from the cited directive docs. None of it has been run yet. A NixOS VM test with `acmeCA` set to staging, or `tls internal`, is the place to validate it.

## Options / trade-offs

1. **Where the cert comes from**
   - **(A) Caddy-native DNS-01 via `withPlugins` + caddy-dns/porkbun.** One config language, wildcard reuse is automatic, and there's no ACME unit ordering. Costs: a custom Go build (an FOD that needs network at build time), the `hash` to update on every Caddy version bump, and reliance on a community plugin (last tag May 2025).
   - **(B) `security.acme` (lego porkbun) + `useACMEHost`.** Stock Caddy package, and lego/NixOS ACME is well-trodden. The cert lives in `/var/lib/acme` and other services can use it too. Costs: `useACMEHost` on every vhost (a small Nix helper can add it), and two systems involved in TLS.
   - **(C) HTTP-01.** No API keys at all. Costs: needs port 80 forwarded and open, one cert per name (every name appears in CT logs), and no wildcard.
2. **Federation port.** Keep `:8448` (today's `m.server`, extra listener and firewall port), or switch `m.server` to `nnik.dev:443` and drop 8448 ([delegate.md][syn-deleg]). Remote servers cache `.well-known` results, so a change takes effect gradually.
3. **Who serves `.well-known/matrix/*`.** Caddy `respond` (static, in Nix), or Synapse (`serve_server_wellknown`, `public_baseurl`/`extra_well_known_client_content`) with Caddy just proxying the path.
4. **LAN vhosts.** Plain `http://` (as today), or `tls internal` (HTTPS, but every LAN device must trust Caddy's root). Separately, whether to add a real `remote_ip private_ranges` guard.
5. **Security headers.** Reproduce today's headers exactly, quirks included (pnp CSP only, ya none), or apply one consistent `(security)` snippet with `?` defaults so app-provided headers win.
6. **Config style.** `virtualHosts.<n>.extraConfig` per host (what the module and the stale draft use), or a single `extraConfig`/`configFile` Caddyfile. Upstream and the module both recommend the Caddyfile over `settings` JSON ([module L342–361][nix-caddy]).

## Open questions

- Does the router forward TCP 80 (and 443, 8448) to the Optiplex? This decides whether HTTP-01 is possible and whether the LAN vhosts are reachable from the internet today.
- Is IPv6 published for `nnik.dev`? nginx listens on `[::]` for some vhosts and not others. Caddy listens on all addresses by default.
- Are the `www.<sub>.nnik.dev` aliases used anywhere? They can't have valid TLS under a single-label wildcard.
- Is the broken `.well-known/matrix/client` JSON a known issue? Fixing it during the cutover changes client behaviour (auto-discovery starts working).
- Which nixpkgs revision will the `optiplex` host build from? Caddy ≥ 2.10 is needed for wildcard reuse and the `dns` global option. That probably belongs to ticket 15.
- Porkbun API access: the API key needs "API Access" enabled for `nnik.dev` in the Porkbun dashboard. That's already true for certbot today, so the same key pair can move into sops.
- Seafile, elabftw, the Own apps (pnp) and Home Assistant backends depend on tickets 04, 05, 14 and 07. The proxy shape follows from those.

## Sources

Primary sources. nixpkgs links are pinned to `6dadaf4375be35033e1c84395adbd53ff5fded96` unless noted. Live-server facts come from read-only commands on the Optiplex on 2026-11-06 (`/etc/nginx/**`, `/etc/letsencrypt/renewal/nnik.dev.conf`, `openssl x509`, `ss -tlnp`, `docker ps`, `curl -I`).

[nix-caddy]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/web-servers/caddy/default.nix
[nix-caddy-vhost]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/web-servers/caddy/vhost-options.nix
[nix-caddy-pkg]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/pkgs/by-name/ca/caddy/package.nix
[nix-caddy-plugins]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/pkgs/by-name/ca/caddy/plugins.nix
[nix-caddy-plugins-test]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/pkgs/by-name/ca/caddy/plugins.test.nix
[nix-caddy-pin]: https://github.com/NixOS/nixpkgs/blob/de0fe301211c267807afd11b12613f5511ff7433/pkgs/by-name/ca/caddy/package.nix
[nix-acme]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/security/acme/default.nix
[nix-paperless]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/misc/paperless.nix
[nix-vw]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/security/vaultwarden/default.nix
[nix-synapse-md]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/matrix/synapse.md
[nix-etebase]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/misc/etebase-server.nix
[nix-etesync-dav]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/misc/etesync-dav.nix
[nix-gitea]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/misc/gitea.nix
[nix-forgejo]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/misc/forgejo.nix
[nix-ha]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/home-automation/home-assistant.nix
[nix-transmission]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/torrent/transmission.nix
[nix-aliases]: https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/pkgs/top-level/aliases.nix#L2451
[pb-readme]: https://github.com/caddy-dns/porkbun
[pb-module]: https://github.com/caddy-dns/porkbun/blob/v0.3.1/module.go#L26-L30
[pb-gomod]: https://github.com/caddy-dns/porkbun/blob/v0.3.1/go.mod
[c-gomod]: https://github.com/caddyserver/caddy/blob/v2.11.7/go.mod
[c-replacer]: https://github.com/caddyserver/caddy/blob/v2.11.7/replacer.go#L34-L44
[c-ahttps]: https://caddyserver.com/docs/automatic-https
[c-patterns]: https://caddyserver.com/docs/caddyfile/patterns#wildcard-certificates
[c-options]: https://caddyserver.com/docs/caddyfile/options
[c-rp]: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
[c-reqbody]: https://caddyserver.com/docs/caddyfile/directives/request_body
[c-header]: https://caddyserver.com/docs/caddyfile/directives/header
[c-handlepath]: https://caddyserver.com/docs/caddyfile/directives/handle_path
[c-matchers]: https://caddyserver.com/docs/caddyfile/matchers#remote-ip
[c-conv]: https://caddyserver.com/docs/conventions#placeholders
[c-concepts]: https://caddyserver.com/docs/caddyfile/concepts#environment-variables
[lego-pb]: https://github.com/go-acme/lego/blob/master/providers/dns/porkbun/porkbun.toml
[syn-rp]: https://github.com/element-hq/synapse/blob/develop/docs/reverse_proxy.md
[syn-deleg]: https://github.com/element-hq/synapse/blob/develop/docs/delegate.md
[syn-cfg]: https://github.com/element-hq/synapse/blob/develop/docs/usage/configuration/config_documentation.md
[mx-cs]: https://spec.matrix.org/latest/client-server-api/#well-known-uri
[vw-proxy]: https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples
[vw-env]: https://github.com/dani-garcia/vaultwarden/blob/main/.env.template
[sf-nginx]: https://github.com/haiwen/seafile-admin-docs/blob/12.0/manual/setup_binary/https_with_nginx.md
[sf-seadoc]: https://github.com/haiwen/seafile-admin-docs/blob/12.0/manual/extension/setup_seadoc.md
[pl-conf]: https://docs.paperless-ngx.com/configuration/#PAPERLESS_URL
[pl-wiki]: https://github.com/paperless-ngx/paperless-ngx/wiki/Using-a-Reverse-Proxy-with-Paperless-ngx
[gitea-rp]: https://docs.gitea.com/administration/reverse-proxies
[ha-http]: https://www.home-assistant.io/integrations/http/#reverse-proxies
[ngx-access]: https://nginx.org/en/docs/http/ngx_http_access_module.html
[ngx-headers]: https://nginx.org/en/docs/http/ngx_http_headers_module.html#add_header
[ngx-core]: https://nginx.org/en/docs/http/ngx_http_core_module.html#client_max_body_size

- nixpkgs Caddy module: <https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/web-servers/caddy/default.nix>
- nixpkgs Caddy vhost options: <https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/services/web-servers/caddy/vhost-options.nix>
- nixpkgs Caddy package / withPlugins / plugin test: <https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/pkgs/by-name/ca/caddy/package.nix>, <https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/pkgs/by-name/ca/caddy/plugins.nix>, <https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/pkgs/by-name/ca/caddy/plugins.test.nix>
- Caddy at the repo's current pin (2.9.1): <https://github.com/NixOS/nixpkgs/blob/de0fe301211c267807afd11b12613f5511ff7433/pkgs/by-name/ca/caddy/package.nix>
- nixpkgs security.acme: <https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/security/acme/default.nix>
- nixpkgs paperless / vaultwarden / synapse manual / etebase / etesync-dav modules (links above)
- nixpkgs `seafile-server` removal: <https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/pkgs/top-level/aliases.nix#L2451>
- caddy-dns/porkbun: <https://github.com/caddy-dns/porkbun>, <https://github.com/caddy-dns/porkbun/blob/v0.3.1/module.go>, <https://github.com/caddy-dns/porkbun/blob/v0.3.1/go.mod>
- Caddy source: <https://github.com/caddyserver/caddy/blob/v2.11.7/replacer.go>, <https://github.com/caddyserver/caddy/blob/v2.11.7/go.mod>
- Caddy docs: automatic HTTPS <https://caddyserver.com/docs/automatic-https>; patterns <https://caddyserver.com/docs/caddyfile/patterns>; global options <https://caddyserver.com/docs/caddyfile/options>; reverse_proxy <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>; request_body <https://caddyserver.com/docs/caddyfile/directives/request_body>; header <https://caddyserver.com/docs/caddyfile/directives/header>; handle_path <https://caddyserver.com/docs/caddyfile/directives/handle_path>; matchers <https://caddyserver.com/docs/caddyfile/matchers>; placeholders <https://caddyserver.com/docs/conventions#placeholders>; env vars <https://caddyserver.com/docs/caddyfile/concepts#environment-variables>
- lego Porkbun provider: <https://github.com/go-acme/lego/blob/master/providers/dns/porkbun/porkbun.toml>
- Synapse: <https://github.com/element-hq/synapse/blob/develop/docs/reverse_proxy.md>, <https://github.com/element-hq/synapse/blob/develop/docs/delegate.md>, <https://github.com/element-hq/synapse/blob/develop/docs/usage/configuration/config_documentation.md>
- Matrix spec, client-server well-known: <https://spec.matrix.org/latest/client-server-api/#well-known-uri>
- Vaultwarden: <https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples>, <https://github.com/dani-garcia/vaultwarden/blob/main/.env.template>
- Seafile 12: <https://github.com/haiwen/seafile-admin-docs/blob/12.0/manual/setup_binary/https_with_nginx.md>, <https://github.com/haiwen/seafile-admin-docs/blob/12.0/manual/extension/setup_seadoc.md>
- Paperless-ngx: <https://docs.paperless-ngx.com/configuration/#PAPERLESS_URL>, <https://github.com/paperless-ngx/paperless-ngx/wiki/Using-a-Reverse-Proxy-with-Paperless-ngx>
- Gitea: <https://docs.gitea.com/administration/reverse-proxies>
- Home Assistant http integration: <https://www.home-assistant.io/integrations/http/#reverse-proxies>
- nginx docs: <https://nginx.org/en/docs/http/ngx_http_access_module.html>, <https://nginx.org/en/docs/http/ngx_http_headers_module.html#add_header>, <https://nginx.org/en/docs/http/ngx_http_core_module.html#client_max_body_size>
