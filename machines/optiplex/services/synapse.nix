# Synapse (nnik.dev): native services.matrix-synapse on the shared PostgreSQL, State in /state/synapse,
# the public vhosts nnik.dev (443) and nnik.dev:8448 (federation), and the shared `doublepuppet`
# appservice. Decisions: tickets 19, 20, 21 and 31. The bridges are in mautrix-whatsapp.nix and
# mautrix-telegram.nix, TURN in coturn.nix.
#
#   * Moves as-is from Arch (live 1.156.0, forward-only upgrade): database `matrix-synapse` (C/C, made
#     by postgresql.nix), the carried signing key and four config secrets, the 25 GB media store.
#   * Database = role = Unix user `matrix-synapse`, Unix socket, peer auth, no password anywhere.
#   * The signing key is a sops secret (secrets/optiplex/synapse.yaml, key `signing_key`). The module's
#     `--generate-keys` leaves an existing key alone, so Synapse can never invent a new identity.
#   * Secrets in the sops-rendered extra config file: macaroon_secret_key, form_secret,
#     registration_shared_secret, turn_shared_secret and password_config (pepper + policy).
#   * Public registration is off (no reCAPTCHA keys, no `modules:`); users are created with
#     `matrix-synapse-register_new_matrix_user` (registration_shared_secret), over loopback.
#   * /_synapse/admin is not proxied: admin calls go to 127.0.0.1:8008.
#
# State restore (steps for the Cutover runbook, Synapse stopped on Arch):
#   rsync -a --numeric-ids --chown=224:224 /var/lib/synapse/media_store/ /mnt/tbssd/state/synapse/media_store/
#   (224 = config.ids.uids.matrix-synapse = gid; the copy can be pre-synced while Arch runs and
#    delta-synced at downtime. All of local_content, local_thumbnails, remote_content, remote_thumbnail,
#    url_cache* belong to it. The unit's root pre-start only fixes /state/synapse itself, never the tree.)
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  synapseSecrets = cfg.secretsDir + "/synapse.yaml";
  coturnSecrets = cfg.secretsDir + "/coturn.yaml";
  dpSecrets = cfg.secretsDir + "/doublepuppet.yaml";
  haveSecrets = builtins.pathExists synapseSecrets && builtins.pathExists coturnSecrets && builtins.pathExists dpSecrets;
  enable = !cfg.restoreMode;

  stateDir = "/state/synapse";
  mediaStore = "${stateDir}/media_store";
  signingKey = "/run/secrets/synapse/signing_key";
  secretsTemplate = "/run/secrets/rendered/synapse-secrets.yaml";
  doublepuppetRegistration = "/run/secrets/rendered/doublepuppet-registration.yaml";
  upstream = "127.0.0.1:8008";
  ph = name: config.sops.placeholder.${name};

  mx = import ../../../tests/optiplex/matrix-helpers.nix {inherit pkgs;};
  caCert = pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem"; # pebble's WFE certificate CA

  wellKnownServer = ''{"m.server": "nnik.dev:8448"}'';
  wellKnownClient = ''{"m.homeserver": {"base_url": "https://nnik.dev"}}'';
  wellKnown = body: ''
    header Content-Type application/json
    header Access-Control-Allow-Origin *
    respond `${body}` 200
  '';
in {
  config = {
    # --- users: declared in restoreMode too (sops owners, restored State); ids are nixpkgs' static ones --
    users.users.matrix-synapse = {
      isSystemUser = true;
      group = "matrix-synapse";
      uid = config.ids.uids.matrix-synapse;
      # The module's createHome would mkdir /state/synapse at activation and break it without the Data disk.
      createHome = lib.mkForce false;
    };
    users.groups.matrix-synapse.gid = config.ids.gids.matrix-synapse;

    services.matrix-synapse = {
      inherit enable;
      dataDir = stateDir;
      extraConfigFiles = [secretsTemplate];
      settings = {
        server_name = "nnik.dev";
        public_baseurl = "https://nnik.dev/";
        # One loopback listener behind Caddy. `client` + `federation` also serve media and keys.
        listeners = [
          {
            port = 8008;
            bind_addresses = ["127.0.0.1"];
            type = "http";
            tls = false;
            x_forwarded = true;
            resources = [
              {
                names = ["client"];
                compress = true;
              }
              {
                names = ["federation"];
                compress = false;
              }
            ];
          }
        ];
        database = {
          name = "psycopg2";
          args = {
            host = "/run/postgresql";
            user = "matrix-synapse";
            database = "matrix-synapse";
            cp_min = 5;
            cp_max = 10;
          };
        };
        signing_key_path = signingKey;
        media_store_path = mediaStore;

        # carried from the live homeserver.yaml
        default_room_version = "9";
        presence.enabled = false;
        report_stats = false;
        url_preview_enabled = true; # url_preview_ip_range_blacklist stays the module default
        encryption_enabled_by_default_for_room_type = "all";
        turn_uris = ["turn:nnik.dev?transport=udp" "turn:nnik.dev?transport=tcp"];
        turn_allow_guests = true;
        # (turn_shared_secret is in the secrets template)
        rc_message = {
          per_second = 1000;
          burst_count = 10000;
        };
        rc_joins = {
          local = {
            per_second = 100;
            burst_count = 1000;
          };
          remote = {
            per_second = 100;
            burst_count = 1000;
          };
        };
        background_updates.background_update_duration_ms = 500;
        # password_config (pepper + policy) is NOT here: Synapse merges config files shallowly, so the
        # whole block lives in the sops-rendered extra config file (the pepper is a secret and is part
        # of every stored password hash: losing or changing it locks every user out).

        # Closed: accounts are made by the admin with the registration shared secret.
        enable_registration = false;
        disable_msisdn_registration = true;

        # The bridges add their registrations (registerToSynapse); this one is shared double puppeting.
        app_service_config_files = [doublepuppetRegistration];
      };
    };

    systemd.services.matrix-synapse = lib.mkIf enable {
      requires = ["postgresql.target" "postgresql-synapse-db.service"];
      after = ["postgresql.target" "postgresql-synapse-db.service"];
      serviceConfig = {
        # The first start after the Cutover migrates the restored database from 1.156 to the nixpkgs
        # release (and Type=notify only reports ready afterwards).
        TimeoutStartSec = "30min";
        # Root-run (`+`), before the module's own pre-start: the State directory on the Data disk.
        ExecStartPre = lib.mkBefore [
          "+${pkgs.writeShellScript "synapse-state-dir" ''
            install -d -m 0700 -o matrix-synapse -g matrix-synapse ${stateDir} ${mediaStore}
          ''}"
        ];
      };
    };
    optiplex.stateUnits = ["matrix-synapse"]; # RequiresMountsFor=/state

    # --- secrets ----------------------------------------------------------------------------------
    sops.secrets = lib.mkIf haveSecrets {
      "synapse/signing_key" = {
        sopsFile = synapseSecrets;
        key = "signing_key";
        owner = "matrix-synapse";
        mode = "0400";
        restartUnits = lib.optional enable "matrix-synapse.service";
      };
      "synapse/macaroon_secret_key" = {
        sopsFile = synapseSecrets;
        key = "macaroon_secret_key";
      };
      "synapse/form_secret" = {
        sopsFile = synapseSecrets;
        key = "form_secret";
      };
      "synapse/registration_shared_secret" = {
        sopsFile = synapseSecrets;
        key = "registration_shared_secret";
      };
      "synapse/password_pepper" = {
        sopsFile = synapseSecrets;
        key = "password_pepper";
      };
      # fresh values; "coturn/static_auth_secret" (turn_shared_secret) is declared in coturn.nix
      "doublepuppet/as_token" = {
        sopsFile = dpSecrets;
        key = "as_token";
      };
      "doublepuppet/hs_token" = {
        sopsFile = dpSecrets;
        key = "hs_token";
      };
    };
    sops.templates = lib.mkIf haveSecrets {
      "synapse-secrets.yaml" = {
        owner = "matrix-synapse";
        mode = "0400";
        restartUnits = lib.optional enable "matrix-synapse.service";
        content = ''
          macaroon_secret_key: |-
            ${ph "synapse/macaroon_secret_key"}
          form_secret: |-
            ${ph "synapse/form_secret"}
          registration_shared_secret: |-
            ${ph "synapse/registration_shared_secret"}
          turn_shared_secret: |-
            ${ph "coturn/static_auth_secret"}
          # whole block here (shallow merge of config files); the policy is the live one
          password_config:
            pepper: |-
              ${ph "synapse/password_pepper"}
            policy:
              enabled: true
              minimum_length: 15
              require_digit: true
              require_symbol: true
              require_lowercase: true
              require_uppercase: true
        '';
      };
      # One registration shared by every bridge: no url (Synapse pushes nothing to it), a non-exclusive
      # namespace over every user of the server. A bridge holding the as_token may act as any user.
      # Treat the token like the signing key.
      "doublepuppet-registration.yaml" = {
        owner = "matrix-synapse";
        mode = "0400";
        restartUnits = lib.optional enable "matrix-synapse.service";
        content = ''
          id: doublepuppet
          url: null
          as_token: "${ph "doublepuppet/as_token"}"
          hs_token: "${ph "doublepuppet/hs_token"}"
          sender_localpart: doublepuppet
          rate_limited: false
          namespaces:
            users:
              - regex: '@.*:nnik\.dev'
                exclusive: false
        '';
      };
    };
    warnings = lib.optional (!haveSecrets) ''
      secrets/optiplex/{synapse,coturn,doublepuppet}.yaml are missing in ${toString cfg.secretsDir}: Synapse cannot start (no signing key, secrets, double puppet registration).
        synapse.yaml: signing_key (/etc/synapse/nnik.dev.signing.key, multi-line value; live old_signing_keys is empty), macaroon_secret_key, form_secret, registration_shared_secret, password_pepper (all carried from the live homeserver.yaml)
        coturn.yaml: static_auth_secret   doublepuppet.yaml: as_token, hs_token   (both fresh, `openssl rand -hex 32`)
      See the Answer of ticket 31 for the commands.
    '';

    # --- Caddy: .well-known, the client API on 443, federation on 8448 ----------------------------------
    # useACMEHost = "nnik.dev" comes from the base helper (caddy.nix). Caddy sets no body limit, so
    # Synapse's max_upload_size (default 50M, like live) applies.
    services.caddy.virtualHosts."nnik.dev".extraConfig = ''
      import security
      handle /.well-known/matrix/server {
        ${wellKnown wellKnownServer}
      }
      handle /.well-known/matrix/client {
        ${wellKnown wellKnownClient}
      }
      handle /_matrix/* {
        reverse_proxy ${upstream}
      }
      handle /_synapse/client/* {
        reverse_proxy ${upstream}
      }
      handle {
        respond 404
      }
    '';
    services.caddy.virtualHosts."nnik.dev:8448".extraConfig = ''
      import security
      handle /_matrix/* {
        reverse_proxy ${upstream}
      }
      handle {
        respond 404
      }
    '';
    networking.firewall.allowedTCPPorts = [8448]; # federation; 80/443 are the base's

    # --- VM test: fixture and checks (see machines/optiplex/vm-test.nix) ------------------------------
    # The fixture is what an rsync of the media store looks like after the restore step: owned by the
    # numeric ids of matrix-synapse. The database is the empty matrix-synapse DB of postgresql.nix:
    # Synapse creates its schema on the first start (the real restore of the 10 GB dump, and with it
    # the migration from 1.156, is the rehearsal tier's job, see the Answer of ticket 31).
    optiplex.vmTest.fixtures.synapse.script = ''
      uid=${toString config.ids.uids.matrix-synapse}
      install -d -m 0755 ${mediaStore}/local_content/ab/cd
      echo media-fixture > ${mediaStore}/local_content/ab/cd/efghijklmnop
      chown -R $uid:$uid ${mediaStore}
    '';

    optiplex.vmTest.checks.matrix-1-synapse-restore = {
      phase = "restore";
      script = ''
        # restoreMode: no Matrix unit, but the users, the sops files and the restored State are there
        for unit in ("matrix-synapse", "mautrix-whatsapp", "mautrix-telegram", "coturn"):
            optiplex.fail(f"systemctl cat {unit}.service")
        optiplex.succeed("test \"$(id -u matrix-synapse):$(id -g matrix-synapse)\" = ${toString config.ids.uids.matrix-synapse}:${toString config.ids.gids.matrix-synapse}")
        assert optiplex.succeed("stat -L -c '%U %a' ${signingKey}").strip() == "matrix-synapse 400"
        for f in ("${secretsTemplate}", "${doublepuppetRegistration}"):
            assert optiplex.succeed(f"stat -L -c '%U %a' {f}").strip() == "matrix-synapse 400", f
        optiplex.succeed("grep -q 'ed25519 ' ${signingKey}")
        optiplex.succeed("grep -q '^turn_shared_secret: ' ${secretsTemplate}")
        # the carried media store is in place and untouched, nothing on the System disk
        optiplex.succeed("test \"$(stat -c %u:%g ${mediaStore}/local_content/ab/cd/efghijklmnop)\" = ${toString config.ids.uids.matrix-synapse}:${toString config.ids.gids.matrix-synapse}")
        optiplex.succeed("test -e /mnt/tbssd/state/synapse/media_store/local_content/ab/cd/efghijklmnop")
        optiplex.fail("test -e /var/lib/matrix-synapse")
      '';
    };

    # Runs in the rehearsal tier too (real restored State): the carried identity and the bridges.
    optiplex.vmTest.checks.matrix-2-synapse-identity = {
      tiers = ["hermetic" "rehearsal"];
      script = ''
        ${mx.helpers}
        optiplex.wait_for_unit("matrix-synapse.service")
        optiplex.wait_until_succeeds("curl -fsS http://127.0.0.1:8008/_matrix/client/versions", timeout=120)
        # first-start time of the unit (Type=notify: until it reported ready)
        ts = dict(x.split("=") for x in optiplex.succeed("systemctl show matrix-synapse.service -p InactiveExitTimestampMonotonic -p ActiveEnterTimestampMonotonic").split())
        print("MEASURED: matrix-synapse first start took %.1f s" % ((int(ts["ActiveEnterTimestampMonotonic"]) - int(ts["InactiveExitTimestampMonotonic"])) / 1e6))
        # the carried signing key is the server's identity, no key was generated
        want = optiplex.succeed("cut -d' ' -f1,2 ${signingKey} | tr ' ' ':'").strip()
        got = optiplex.succeed("curl -fsS http://127.0.0.1:8008/_matrix/key/v2/server | ${pkgs.jq}/bin/jq -r '.verify_keys | keys[]'").strip()
        assert want == got and want.startswith("ed25519:"), (want, got)
        print("key id:", got)
        optiplex.fail("ls ${stateDir}/*.key ${stateDir}/*.signing.key")
        optiplex.fail("journalctl -u matrix-synapse.service --no-pager | grep -i 'generat.*key'")
        # settings that matter, as Synapse sees them
        cfgs = optiplex.succeed("systemctl cat matrix-synapse.service | grep -o -- '--config-path [^ ]*' | cut -d' ' -f2").split()
        conf = "\n".join(optiplex.succeed(f"cat {c}") for c in cfgs)
        assert "enable_registration: false" in conf
        assert "recaptcha" not in conf and "shared_secret_authenticator" not in conf and "modules:" not in conf
        # the pepper is a secret: not in any generated config in the store, only in the rendered sops file
        pepper = optiplex.succeed("cat /run/secrets/synapse/password_pepper").strip()
        assert cfgs[0].startswith("/nix/store/") and "password_config" not in optiplex.succeed(f"cat {cfgs[0]}")
        assert pepper and pepper not in optiplex.succeed(f"cat {cfgs[0]}"), "pepper in the store config"
        assert pepper in optiplex.succeed("cat ${secretsTemplate}")
        # State ownership and nothing stray in State or on the System disk
        optiplex.succeed("test \"$(stat -c '%U:%G %a' ${stateDir} ${mediaStore} | sort -u)\" = 'matrix-synapse:matrix-synapse 700'")
        optiplex.succeed("systemctl show -p RequiresMountsFor matrix-synapse.service | grep -q '/state'")
        optiplex.fail("test -e /var/lib/matrix-synapse")
        optiplex.succeed("test \"$(stat -c %U ${mediaStore}/local_content/ab/cd/efghijklmnop)\" = matrix-synapse")
        # admin API lives on loopback only; a user can be made with the shared secret and logs in
        optiplex.succeed("curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8008/_synapse/admin/v1/server_version | grep -q 200")
        mx_ensure_user()
        login = optiplex.succeed(
            "curl -fsS -X POST http://127.0.0.1:8008/_matrix/client/v3/login -H 'Content-Type: application/json' "
            f"-d '{{\"type\":\"m.login.password\",\"identifier\":{{\"type\":\"m.id.user\",\"user\":\"{MX_USER}\"}},\"password\":\"{MX_PASS}\"}}'"
        )
        import json as _json
        token = _json.loads(login)["access_token"]
        # the pepper really is in effect: the stored bcrypt hash is of password+pepper, not of the bare password
        dbhash = optiplex.succeed("runuser -u postgres -- psql -X -d matrix-synapse -tAc \"select password_hash from users where name = '@" + MX_USER + ":nnik.dev'\"").strip()
        optiplex.succeed(f"{MX_PY} -c \"import bcrypt,sys; h=sys.argv[1].encode(); assert bcrypt.checkpw((sys.argv[2]+sys.argv[3]).encode(), h); assert not bcrypt.checkpw(sys.argv[2].encode(), h)\" '{dbhash}' '{MX_PASS}' '{pepper}'")
        # TURN credentials: both URIs, and the HMAC password verifies against the coturn secret
        turn = _json.loads(optiplex.succeed(f"curl -fsS -H 'Authorization: Bearer {token}' http://127.0.0.1:8008/_matrix/client/v3/voip/turnServer"))
        assert turn["uris"] == ["turn:nnik.dev?transport=udp", "turn:nnik.dev?transport=tcp"], turn
        secret = optiplex.succeed("cat /run/secrets/coturn/static_auth_secret")
        expect = optiplex.succeed(f"printf %s '{turn['username']}' | openssl dgst -sha1 -hmac '{secret}' -binary | base64").strip()
        assert turn["password"] == expect, (turn, expect)
        print("turnServer:", turn["username"], turn["uris"])
      '';
    };

    # Caddy in front of Synapse, from the LAN client and the internet client.
    optiplex.vmTest.checks.matrix-3-synapse-caddy = {
      script = ''
        optiplex.wait_for_unit("matrix-synapse.service")
        # pebble's root is random per start: fetch it from pebble's management port (LAN), hand it to outside
        lan.wait_until_succeeds("curl -sS --cacert ${caCert} --resolve acme.test:15000:192.168.178.60 https://acme.test:15000/roots/0 -o /tmp/pebble-root.pem", timeout=60)
        outside.succeed("cat > /tmp/pebble-root.pem <<'PEM'\n" + lan.succeed("cat /tmp/pebble-root.pem") + "PEM")
        def https(client, port, path, opts=""):
            ip = "192.168.178.20" if client is lan else "203.0.113.1"
            return f"curl -sS {opts} --cacert /tmp/pebble-root.pem --resolve nnik.dev:{port}:{ip} https://nnik.dev:{port}{path}"
        lan.wait_until_succeeds(https(lan, 443, "/_matrix/client/versions", "-f -o /dev/null"), timeout=180)
        # both well-known documents: valid JSON, exact content, JSON content type, open CORS
        for path, want in (("/.well-known/matrix/server", {"m.server": "nnik.dev:8448"}),
                           ("/.well-known/matrix/client", {"m.homeserver": {"base_url": "https://nnik.dev"}})):
            for client in (lan, outside):
                body = client.succeed(https(client, 443, path, "-f"))
                import json as _json
                assert _json.loads(body) == want, (path, body)
                client.succeed(f"printf %s '{body}' | ${pkgs.jq}/bin/jq -e . >/dev/null")
                head = client.succeed(https(client, 443, path, "-f -D - -o /dev/null")).lower()
                assert "content-type: application/json" in head, head
                assert "access-control-allow-origin: *" in head, head
                assert "strict-transport-security: max-age=31536000" in head, head
        # client API on 443, federation API on 8448 (from the internet, over IPv4)
        assert "versions" in outside.succeed(https(outside, 443, "/_matrix/client/versions", "-f"))
        assert "version" in outside.succeed(https(outside, 8448, "/_matrix/federation/v1/version", "-f"))
        assert "verify_keys" in outside.succeed(https(outside, 8448, "/_matrix/key/v2/server", "-f"))
        # not on 8448: the well-known documents and the rest
        assert outside.succeed(https(outside, 8448, "/.well-known/matrix/server", "-o /dev/null -w '%{http_code}'")).strip() == "404"
        # `/` and the admin API are 404 from Caddy (empty body), on both ports
        for port in (443, 8448):
            for path in ("/", "/index.html", "/_synapse/admin/v1/server_version", "/_synapse/admin/v1/users", "/_synapse/other"):
                out = outside.succeed(https(outside, port, path, "-o /tmp/body -w '%{http_code}'")).strip()
                assert out == "404", (port, path, out)
                outside.succeed("test ! -s /tmp/body")
        # /_matrix and /_synapse/client reach Synapse (their 404s have a body)
        out = outside.succeed(https(outside, 443, "/_matrix/nonexistent", "-o /tmp/body -w '%{http_code}'")).strip()
        assert out == "404" and "M_UNRECOGNIZED" in outside.succeed("cat /tmp/body"), out
        out = outside.succeed(https(outside, 443, "/_synapse/client/nonexistent", "-o /tmp/body -w '%{http_code}'")).strip()
        assert out == "404"
        outside.succeed("test -s /tmp/body")
        # the upstream is not reachable from outside, nor are the bridges' ports
        for port in (8008, 29317, 29318):
            outside.fail(f"curl -sS --max-time 3 http://203.0.113.1:{port}/")
        # firewall: the ruleset opens 8448 and the TURN ports and nothing for the upstream and the bridges
        rules = optiplex.succeed("nft list ruleset")
        assert "tcp dport { " in rules or "tcp dport" in rules
        for needle in ("8448", "3478", "49152-49252"):
            assert needle in rules, needle
        for needle in ("8008", "29317", "29318"):
            assert needle not in rules, needle
        optiplex.succeed("ss -H -ltn 'sport = :8008' | grep -q '127.0.0.1:8008'")
        optiplex.fail("ss -H -ltn 'sport = :8008' | grep -v '127.0.0.1:8008'")
      '';
    };
  };
}
