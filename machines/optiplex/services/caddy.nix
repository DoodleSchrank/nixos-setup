# The edge: Caddy base, the lego wildcard certificate, the static sites and the
# LAN dashboard. Per-service vhosts are NOT here: every service file declares its own
# `services.caddy.virtualHosts.<host>` and imports the snippets below.
#
# What a service file gets for free
#   * Any vhost whose host is `nnik.dev` or `*.nnik.dev` (port suffix allowed, e.g.
#     "nnik.dev:8448") and does not start with `http://` gets
#     `useACMEHost = "nnik.dev"` (the lego wildcard cert). Nothing to add.
#   * `import security`  response-header snippet for every public site.
#   * `import lan_only`  for every LAN site (`http://<name>.opti.plex`): aborts the
#     connection unless the client is in 192.168.178.0/24, fd65:c1a5:7d2b::/64 or on
#     loopback. Deliberately not `private_ranges`: that would admit the runner VMs.
#     Note: `abort` sorts after `redir`/`rewrite` and before `reverse_proxy`/`file_server`.
#   * Ports 80/tcp, 443/tcp+udp are open on v4 and v6. A vhost on another public port
#     (Synapse's 8448) opens it itself with networking.firewall.allowedTCPPorts.
#   * Caddy never issues certificates (`auto_https disable_certs`), the HTTP->HTTPS
#     redirects stay.
#
# Static sites live in /state/www/<site> (Data disk, in the Backup, rsynced by hand).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  caddySecrets = cfg.secretsDir + "/caddy.yaml";
  haveSecrets = builtins.pathExists caddySecrets;

  lan = "192.168.178.0/24 fd65:c1a5:7d2b::/64 127.0.0.1/8 ::1";

  # --- the useACMEHost helper -------------------------------------------------
  # All names of the vhost (hostName and serverAliases, each may hold several
  # whitespace-separated addresses) must be [*.]nnik.dev[:port], without `http://`.
  nnikName = a: lib.match "(https://)?([a-z0-9*-]+\\.)*nnik\\.dev(:[0-9]+)?" a != null;
  names = vh: lib.concatMap (lib.splitString " ") ([vh.hostName] ++ vh.serverAliases);
  coveredByCert = vh: let
    ns = lib.filter (n: n != "") (names vh);
  in
    ns != [] && lib.all nnikName ns;

  # Static site: root + compression + security headers (public) .
  staticSite = dir: extra: ''
    root * /state/www/${dir}
    encode zstd gzip
    import security
    ${extra}
    file_server
  '';

  # The Flutter CSP of koke and immo, verbatim from today's nginx.
  flutterCsp = "script-src 'self' 'unsafe-eval' 'wasm-unsafe-eval' 'unsafe-inline' https://www.gstatic.com/flutter-canvaskit/; font-src 'self' https://fonts.gstatic.com *.nnik.dev; style-src 'unsafe-inline'";
in {
  options.optiplex.edge = {
    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "y.koenneker@web.de";
      description = "ACME account email (expiry notices from Let's Encrypt).";
    };
    porkbun = {
      apiKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/secrets/porkbun_api_key";
        description = "File with the Porkbun API key. Shared by lego (ACME) and the DDNS updater.";
      };
      secretApiKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/secrets/porkbun_secret_api_key";
        description = "File with the Porkbun secret API key.";
      };
    };
  };

  # Extends the vhost submodule of the stock module.
  options.services.caddy.virtualHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({config, ...}: {
      config.useACMEHost = lib.mkIf (coveredByCert config) (lib.mkDefault "nnik.dev");
    }));
  };

  config = {
    services.caddy = {
      enable = true; # stays on in restoreMode: no State, and it answers during the restore window
      openFirewall = true; # TCP 80/443 and UDP 443 (HTTP/3), v4 and v6

      globalConfig = ''
        # Reloads (every deploy) must not wait for open connections for ever.
        grace_period 10s
        # Certificates come from lego (security.acme below) for every nnik.dev name,
        # and the LAN sites are plain http://. Caddy must never order one itself.
        auto_https disable_certs
      '';

      # Rendered before the vhosts, so `import` works in all of them.
      extraConfig = ''
        (security) {
          header ?X-Content-Type-Options nosniff
          header ?Referrer-Policy strict-origin-when-cross-origin
          header ?Content-Security-Policy "frame-ancestors 'self'"
          header ?Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()"
          header Strict-Transport-Security "max-age=31536000"
        }

        (lan_only) {
          @outside not remote_ip ${lan}
          abort @outside
        }
      '';

      virtualHosts = {
        # Unknown names under nnik.dev (every retired name, www.<sub>, scanners) are dropped.
        # (Scanner noise, so no access log for the two catch-alls.)
        "*.nnik.dev" = {
          logFormat = lib.mkForce "output discard";
          extraConfig = "abort";
        };
        "www.nnik.dev".extraConfig = ''
          import security
          redir https://nnik.dev{uri} 308
        '';
        # Anything else on :80 (the bare public IP, retired *.opti.plex names) is
        # dropped. Caddy's own HTTP->HTTPS redirects do NOT take precedence over a
        # catch-all (VM test), so the nnik.dev names are redirected here.
        "http://" = {
          logFormat = lib.mkForce "output discard";
          extraConfig = ''
            @nnik host nnik.dev *.nnik.dev
            redir @nnik https://{host}{uri} 308
            abort
          '';
        };

        "ya.nnik.dev".extraConfig = staticSite "ya" "";
        "koke.nnik.dev".extraConfig = staticSite "koke" ''header Content-Security-Policy "${flutterCsp}"'';
        "immo.nnik.dev".extraConfig = staticSite "immo" ''header Content-Security-Policy "${flutterCsp}"'';

        # LAN dashboard: http://opti.plex, http://www.opti.plex and the bare LAN address.
        # The frame-ancestors CSP lets it embed the LAN services.
        "http://opti.plex" = {
          serverAliases = ["http://www.opti.plex" "http://192.168.178.20"];
          extraConfig = ''
            import lan_only
            header Content-Security-Policy "frame-ancestors 'self' http://opti.plex"
            root * /state/www/opti.plex
            file_server
          '';
        };
      };
    };

    # --- State: /state/www ---------------------------------------------------
    # A oneshot, not a tmpfiles rule: a tmpfiles `d` on the immutable empty /state
    # (Data disk missing) would fail the whole systemd-tmpfiles-setup.
    optiplex.stateUnits = ["caddy" "state-www"];
    systemd.services.caddy.wants = ["state-www.service"];
    systemd.services.caddy.after = ["state-www.service"];
    systemd.services.state-www = {
      description = "Create /state/www for the static sites";
      before = ["caddy.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/install -d -m 0755 -o yannik -g users /state/www";
      };
    };

    # --- ACME: one wildcard cert via lego + Porkbun DNS-01 -------------------
    security.acme = {
      acceptTerms = true;
      defaults.email = cfg.edge.acmeEmail;
      # defaults.server stays unset (Let's Encrypt production): VM tests override it.
      certs."nnik.dev" = {
        extraDomainNames = ["*.nnik.dev"];
        dnsProvider = "porkbun";
        credentialFiles = {
          PORKBUN_API_KEY_FILE = cfg.edge.porkbun.apiKeyFile;
          PORKBUN_SECRET_API_KEY_FILE = cfg.edge.porkbun.secretApiKeyFile;
        };
        # lego's zone and propagation lookups bypass blocky's split horizon.
        dnsResolver = "9.9.9.9:53";
        # group = caddy and reloadServices = caddy come from useACMEHost (caddy module).
      };
    };

    # --- secrets (shared by ACME and DDNS) -----------------------------------
    sops.secrets = lib.mkIf haveSecrets {
      porkbun_api_key.sopsFile = caddySecrets;
      porkbun_secret_api_key.sopsFile = caddySecrets;
    };
    warnings = lib.optional (!haveSecrets) ''
      secrets/optiplex/caddy.yaml does not exist (looked in ${toString cfg.secretsDir}): ACME and DDNS have no Porkbun credentials.
      Create it with `sops secrets/optiplex/caddy.yaml` (keys: porkbun_api_key, porkbun_secret_api_key,
      values from /home/yannik/.certbot-creds.ini on the Arch box) and `git add` it.
    '';
  };
}
