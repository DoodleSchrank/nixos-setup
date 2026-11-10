# mautrix-whatsapp: the nixpkgs module with the nixpkgs package built with goolm (pure-Go Olm, no
# libolm, so no permittedInsecurePackages). Decisions: tickets 19 and 31.
#
#   * Database `mautrix-whatsapp` (= role = Unix user) over the PostgreSQL socket, peer auth, no password.
#   * The carried appservice registration comes from sops (secrets/optiplex/mautrix-whatsapp.yaml, key
#     `registration`) and is installed by a root oneshot BEFORE Synapse and the bridge start, because
#     Synapse reads it at start and the module would otherwise generate a new one (new tokens).
#     The separate as_token/hs_token keys of ticket 25 are NOT used: the module copies the tokens out
#     of the registration, so a second copy could only disagree.
#   * `pickle_key` (the live upstream default) and the double puppeting token reach the bridge through a
#     sops-rendered environment file. Double puppeting is the shared `doublepuppet` appservice
#     (synapse.nix); the secret is `as_token:<token>`.
#   * File State: none. /var/lib/mautrix-whatsapp holds only the rendered config.yaml and the registration
#     (both rewritten on every start), so it stays on the System disk.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  secretsFile = cfg.secretsDir + "/mautrix-whatsapp.yaml";
  haveSecrets = builtins.pathExists secretsFile && builtins.pathExists (cfg.secretsDir + "/doublepuppet.yaml");
  enable = !cfg.restoreMode;

  dataDir = "/var/lib/mautrix-whatsapp";
  registrationFile = "${dataDir}/whatsapp-registration.yaml";
  registrationUnit = "mautrix-whatsapp-registration.service";
  sopsRegistration = "/run/secrets/mautrix-whatsapp/registration";
  mx = import ../../../tests/optiplex/matrix-helpers.nix {inherit pkgs;};
  envFile = "/run/secrets/rendered/mautrix-whatsapp.env";
in {
  config = {
    # Declared in restoreMode too (the module only declares them when enabled).
    users.users.mautrix-whatsapp = {
      isSystemUser = true;
      group = "mautrix-whatsapp";
    };
    users.groups.mautrix-whatsapp = {};

    services.mautrix-whatsapp = {
      inherit enable;
      package = pkgs.mautrix-whatsapp.override {withGoolm = true;};
      environmentFile = envFile;
      settings = {
        homeserver = {
          address = "http://127.0.0.1:8008";
          domain = "nnik.dev";
        };
        appservice = {
          # Bound to loopback only; the registration's url (carried) is http://localhost:29318.
          hostname = "127.0.0.1";
          port = 29318;
          id = "whatsapp";
          bot = {
            username = "whatsapp"; # the module default `whatsappbot` would orphan the live bot user
            displayname = "WhatsApp Bridge";
          };
          ephemeral_events = false;
        };
        database = {
          type = "postgres";
          uri = "postgres://mautrix-whatsapp@/mautrix-whatsapp?host=/run/postgresql&sslmode=disable";
          max_open_conns = 20;
          max_idle_conns = 2;
        };
        bridge = {
          personal_filtering_spaces = false;
          private_chat_portal_meta = true;
          deduplicate_matrix_messages = true;
          resend_bridge_info = true;
          relay.enabled = false;
          permissions = {
            "*" = "relay";
            "nnik.dev" = "user";
            "@ya:nnik.dev" = "admin";
          };
        };
        network = {
          os_name = "WhatsApp bridge";
          displayname_template = "{{or .FullName .PushName .JID}} (WA)";
          identity_change_notices = false;
          url_previews = true;
          history_sync = {
            request_full_sync = true;
            full_sync_config = {
              days_limit = 1000;
              size_mb_limit = 5000;
              storage_quota_mb = 5000;
            };
          };
        };
        backfill = {
          enabled = true;
          max_initial_messages = 1000;
          max_catchup_messages = 5000;
        };
        matrix.message_error_notices = true;
        encryption = {
          allow = true;
          default = true;
          require = true;
          pickle_key = "$ENCRYPTION_PICKLE_KEY";
        };
        provisioning.shared_secret = "disable";
      };
    };

    # The module's Synapse dependency stays on its defaults; this adds the database and the
    # registration, and Synapse needs the registration before it starts.
    systemd.services.mautrix-whatsapp = lib.mkIf enable {
      requires = ["postgresql.target" registrationUnit];
      after = ["postgresql.target" registrationUnit];
    };
    systemd.services.mautrix-whatsapp-registration = lib.mkIf enable {
      description = "Install the carried mautrix-whatsapp appservice registration";
      before = ["matrix-synapse.service" "mautrix-whatsapp.service"];
      requiredBy = ["matrix-synapse.service" "mautrix-whatsapp.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0755 -o mautrix-whatsapp -g mautrix-whatsapp ${dataDir}
        install -m 0640 -o mautrix-whatsapp -g mautrix-whatsapp ${sopsRegistration} ${registrationFile}
      '';
    };

    # --- secrets ----------------------------------------------------------------------------------
    sops.secrets = lib.mkIf haveSecrets {
      "mautrix-whatsapp/pickle_key".sopsFile = secretsFile;
      "mautrix-whatsapp/pickle_key".key = "pickle_key";
      "mautrix-whatsapp/registration" = {
        sopsFile = secretsFile;
        key = "registration";
        restartUnits = lib.optional enable registrationUnit;
      };
    };
    sops.templates."mautrix-whatsapp.env" = lib.mkIf haveSecrets {
      restartUnits = lib.optional enable "mautrix-whatsapp.service";
      content = ''
        ENCRYPTION_PICKLE_KEY=${config.sops.placeholder."mautrix-whatsapp/pickle_key"}
        MAUTRIX_WHATSAPP_BRIDGE_LOGIN_SHARED_SECRET=as_token:${config.sops.placeholder."doublepuppet/as_token"}
      '';
    };
    warnings = lib.optional (!haveSecrets) ''
      secrets/optiplex/mautrix-whatsapp.yaml (and doublepuppet.yaml) does not exist (looked in ${toString cfg.secretsDir}): the WhatsApp bridge has no registration and pickle key and will not start.
      Keys of mautrix-whatsapp.yaml: pickle_key (the live encryption.pickle_key, upstream default `maunium.net/go/mautrix-whatsapp`),
      registration (the whole /etc/synapse/appservices/whatsapp.yaml as a multi-line value). See the Answer of ticket 31.
    '';

    # --- VM test ------------------------------------------------------------------------------------
    optiplex.vmTest.checks.matrix-4-whatsapp-restore = {
      phase = "restore";
      script = ''
        optiplex.fail("systemctl cat mautrix-whatsapp.service")
        optiplex.succeed("getent passwd mautrix-whatsapp")
        optiplex.succeed("test -s /run/secrets/rendered/mautrix-whatsapp.env")
        optiplex.succeed("grep -q '^id: whatsapp$' /run/secrets/mautrix-whatsapp/registration")
      '';
    };

    # Hermetic: a fresh database (the bridge creates its schema). Rehearsal: the restored database with the
    # live logins and E2EE pickles - then the encrypted reply below is the goolm proof for restored pickles.
    optiplex.vmTest.checks.matrix-4-whatsapp = {
      tiers = ["hermetic" "rehearsal"];
      script = ''
        ${mx.helpers}
        import yaml as _yaml
        optiplex.wait_for_unit("mautrix-whatsapp.service")
        optiplex.wait_for_unit("matrix-synapse.service")
        optiplex.wait_until_succeeds("ss -H -ltn 'sport = :29318' | grep -q 127.0.0.1:29318", timeout=120)
        optiplex.succeed("systemctl show -p Restart mautrix-whatsapp.service | grep -q on-failure")

        # rendered config: what the Inputs of ticket 31 ask for
        c = _yaml.safe_load(optiplex.succeed("cat ${dataDir}/config.yaml"))
        reg = _yaml.safe_load(optiplex.succeed("cat ${dataDir}/whatsapp-registration.yaml"))
        assert c["appservice"]["id"] == "whatsapp" and c["appservice"]["bot"]["username"] == "whatsapp", c["appservice"]
        assert c["appservice"]["port"] == 29318 and reg["url"].endswith(":29318"), (c["appservice"], reg["url"])
        assert (c["appservice"]["as_token"], c["appservice"]["hs_token"]) == (reg["as_token"], reg["hs_token"])
        assert c["homeserver"]["address"] == "http://127.0.0.1:8008" and c["homeserver"]["domain"] == "nnik.dev"
        assert c["database"]["type"] == "postgres" and c["database"]["uri"].startswith("postgres://mautrix-whatsapp@/mautrix-whatsapp?host=/run/postgresql"), c["database"]
        assert ":" not in c["database"]["uri"].split("@")[0].split("//")[1], "password in the database URI"
        assert c["double_puppet"]["secrets"]["nnik.dev"].startswith("as_token:"), c["double_puppet"]
        assert c["encryption"]["allow"] is True and c["encryption"]["default"] is True
        assert c["encryption"]["require"] is True, c["encryption"]
        assert c["encryption"]["pickle_key"] and "$" not in str(c["encryption"]["pickle_key"])
        perms = c["bridge"]["permissions"]
        assert perms["nnik.dev"] == "user" and perms["@ya:nnik.dev"] == "admin", perms
        assert perms['*'] == 'relay', perms
        assert c["bridge"]["personal_filtering_spaces"] is False and c["bridge"]["private_chat_portal_meta"] is True
        optiplex.succeed("test \"$(stat -c %a ${dataDir}/config.yaml)\" = 600")

        # Synapse knows the registration (ghost users are exclusive to it) and the shared doublepuppet one
        mx_ensure_user()

        # goolm: no olm/unpickle problems on start, then an encrypted DM with the bot gets an encrypted reply
        jlog = optiplex.succeed("journalctl -u mautrix-whatsapp.service --no-pager")
        for bad in ("unpickle", "olm", "panic", "fatal"):
            assert bad not in jlog.lower().replace("goolm", ""), (bad, jlog[-3000:])
        out = mx_dm("whatsapp")
        assert "encrypted reply from @whatsapp:nnik.dev" in out, out

        # no State outside /state: only the rendered config and the registration are written
        files = optiplex.succeed("find ${dataDir} -mindepth 1 -printf '%P\\n' | sort").split()
        print("${dataDir}:", files)
        assert sorted(files) == ["config.yaml", "whatsapp-registration.yaml"], files
        print(optiplex.succeed("ls -lR ${dataDir}"))
        optiplex.fail("systemctl is-failed mautrix-whatsapp.service")
      '';
    };
  };
}
