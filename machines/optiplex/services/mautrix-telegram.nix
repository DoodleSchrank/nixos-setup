# mautrix-telegram: the Go (bridgev2) bridge from custom-pkgs/mautrix-telegram, run by the local module
# machines/optiplex/modules/mautrix-telegram.nix (nixpkgs still has only the Python bridge).
# Built with goolm (pure-Go Olm). Decisions: tickets 19 and 31. Same shape as mautrix-whatsapp.nix:
#
#   * Database `mautrix-telegram` (= role = Unix user) over the PostgreSQL socket, peer auth.
#   * The carried registration comes from sops (secrets/optiplex/mautrix-telegram.yaml, key `registration`),
#     installed by a root oneshot before Synapse and the bridge start. The module copies as_token/hs_token
#     out of it (the separate as_token/hs_token keys of ticket 25 are not used).
#   * api_id, api_hash, pickle_key (live default `mautrix.bridge.e2ee`) and the double puppeting secret
#     (`as_token:<doublepuppet token>`) come from a sops-rendered environment file.
#   * File State: none (rendered config.yaml and the registration only, both rewritten on every start).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  secretsFile = cfg.secretsDir + "/mautrix-telegram.yaml";
  haveSecrets = builtins.pathExists secretsFile && builtins.pathExists (cfg.secretsDir + "/doublepuppet.yaml");
  enable = !cfg.restoreMode;

  dataDir = "/var/lib/mautrix-telegram";
  registrationUnit = "mautrix-telegram-registration.service";
  sopsRegistration = "/run/secrets/mautrix-telegram/registration";
  mx = import ../../../tests/optiplex/matrix-helpers.nix {inherit pkgs;};
  envFile = "/run/secrets/rendered/mautrix-telegram.env";
in {
  imports = [../modules/mautrix-telegram.nix];

  config = {
    users.users.mautrix-telegram = {
      isSystemUser = true;
      group = "mautrix-telegram";
    };
    users.groups.mautrix-telegram = {};

    services.mautrix-telegram = {
      inherit enable;
      environmentFile = envFile;
      settings = {
        homeserver = {
          address = "http://127.0.0.1:8008";
          domain = "nnik.dev";
        };
        appservice = {
          hostname = "127.0.0.1";
          port = 29317;
          id = "telegram";
          bot = {
            username = "telegram";
            displayname = "Telegram Bridge";
            avatar = "";
          };
          ephemeral_events = false;
        };
        database = {
          type = "postgres";
          uri = "postgres://mautrix-telegram@/mautrix-telegram?host=/run/postgresql&sslmode=disable";
          max_open_conns = 10;
          max_idle_conns = 1;
        };
        bridge = {
          command_prefix = "!tg";
          personal_filtering_spaces = true;
          private_chat_portal_meta = true;
          # live: nnik.dev may use the bridge, @ya is admin, no "*": relay entry
          permissions = {
            "nnik.dev" = "user";
            "@ya:nnik.dev" = "admin";
          };
        };
        network = {
          member_list = {
            max_initial_sync = 1000;
            sync_broadcast_channels = true;
          };
          sync = {
            update_limit = 0;
            create_limit = 0;
          };
        };
        matrix.sync_direct_chat_list = false;
        encryption = {
          allow = true;
          default = true;
          require = false;
          pickle_key = "$ENCRYPTION_PICKLE_KEY";
        };
      };
    };

    systemd.services.mautrix-telegram = lib.mkIf enable {
      requires = ["postgresql.target" registrationUnit];
      after = ["postgresql.target" registrationUnit];
    };
    systemd.services.mautrix-telegram-registration = lib.mkIf enable {
      description = "Install the carried mautrix-telegram appservice registration";
      before = ["matrix-synapse.service" "mautrix-telegram.service"];
      requiredBy = ["matrix-synapse.service" "mautrix-telegram.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0755 -o mautrix-telegram -g mautrix-telegram ${dataDir}
        install -m 0640 -o mautrix-telegram -g mautrix-telegram ${sopsRegistration} ${config.services.mautrix-telegram.registrationFile}
      '';
    };

    # --- secrets ----------------------------------------------------------------------------------
    sops.secrets = lib.mkIf haveSecrets {
      "mautrix-telegram/api_id" = {
        sopsFile = secretsFile;
        key = "api_id";
      };
      "mautrix-telegram/api_hash" = {
        sopsFile = secretsFile;
        key = "api_hash";
      };
      "mautrix-telegram/pickle_key" = {
        sopsFile = secretsFile;
        key = "pickle_key";
      };
      "mautrix-telegram/registration" = {
        sopsFile = secretsFile;
        key = "registration";
        restartUnits = lib.optional enable registrationUnit;
      };
    };
    sops.templates."mautrix-telegram.env" = lib.mkIf haveSecrets {
      restartUnits = lib.optional enable "mautrix-telegram.service";
      content = ''
        MAUTRIX_TELEGRAM_API_ID=${config.sops.placeholder."mautrix-telegram/api_id"}
        MAUTRIX_TELEGRAM_API_HASH=${config.sops.placeholder."mautrix-telegram/api_hash"}
        ENCRYPTION_PICKLE_KEY=${config.sops.placeholder."mautrix-telegram/pickle_key"}
        MAUTRIX_TELEGRAM_BRIDGE_LOGIN_SHARED_SECRET=as_token:${config.sops.placeholder."doublepuppet/as_token"}
      '';
    };
    warnings = lib.optional (!haveSecrets) ''
      secrets/optiplex/mautrix-telegram.yaml (and doublepuppet.yaml) does not exist (looked in ${toString cfg.secretsDir}): the Telegram bridge has no registration, API credentials and pickle key and will not start.
      Keys of mautrix-telegram.yaml: api_id, api_hash (from the live config.yaml, `network:`), pickle_key (the live encryption.pickle_key, upstream default `mautrix.bridge.e2ee`),
      registration (the whole /etc/synapse/appservices/telegram.yaml as a multi-line value). See the Answer of ticket 31.
    '';

    optiplex.vmTest.checks.matrix-6-telegram-restore = {
      phase = "restore";
      script = ''
        optiplex.fail("systemctl cat mautrix-telegram.service")
        optiplex.succeed("getent passwd mautrix-telegram")
        optiplex.succeed("test -s /run/secrets/rendered/mautrix-telegram.env")
        optiplex.succeed("grep -q '^id: telegram$' /run/secrets/mautrix-telegram/registration")
      '';
    };

    # Hermetic: a fresh database (the bridge creates its schema). Rehearsal: the restored database with the
    # live logins and E2EE pickles - then the encrypted reply below is the goolm proof for restored pickles.
    optiplex.vmTest.checks.matrix-6-telegram = {
      tiers = ["hermetic" "rehearsal"];
      script = ''
        ${mx.helpers}
        import yaml as _yaml
        optiplex.wait_for_unit("mautrix-telegram.service")
        optiplex.wait_for_unit("matrix-synapse.service")
        optiplex.wait_until_succeeds("ss -H -ltn 'sport = :29317' | grep -q 127.0.0.1:29317", timeout=120)
        optiplex.succeed("systemctl show -p Restart mautrix-telegram.service | grep -q on-failure")

        # rendered config: what the Inputs of ticket 31 ask for
        c = _yaml.safe_load(optiplex.succeed("cat ${dataDir}/config.yaml"))
        reg = _yaml.safe_load(optiplex.succeed("cat ${dataDir}/telegram-registration.yaml"))
        assert c["appservice"]["id"] == "telegram" and c["appservice"]["bot"]["username"] == "telegram", c["appservice"]
        assert c["appservice"]["port"] == 29317 and reg["url"].endswith(":29317"), (c["appservice"], reg["url"])
        assert (c["appservice"]["as_token"], c["appservice"]["hs_token"]) == (reg["as_token"], reg["hs_token"])
        assert c["homeserver"]["address"] == "http://127.0.0.1:8008" and c["homeserver"]["domain"] == "nnik.dev"
        assert c["database"]["type"] == "postgres" and c["database"]["uri"].startswith("postgres://mautrix-telegram@/mautrix-telegram?host=/run/postgresql"), c["database"]
        assert ":" not in c["database"]["uri"].split("@")[0].split("//")[1], "password in the database URI"
        assert c["double_puppet"]["secrets"]["nnik.dev"].startswith("as_token:"), c["double_puppet"]
        assert c["encryption"]["allow"] is True and c["encryption"]["default"] is True
        assert c["encryption"]["require"] is False, c["encryption"]
        assert c["encryption"]["pickle_key"] and "$" not in str(c["encryption"]["pickle_key"])
        perms = c["bridge"]["permissions"]
        assert perms["nnik.dev"] == "user" and perms["@ya:nnik.dev"] == "admin", perms
        assert '*' not in perms, perms
        assert c["bridge"]["personal_filtering_spaces"] is True and c["bridge"]["private_chat_portal_meta"] is True
        optiplex.succeed("test \"$(stat -c %a ${dataDir}/config.yaml)\" = 600")

        # Synapse knows the registration (ghost users are exclusive to it) and the shared doublepuppet one
        mx_ensure_user()

        # goolm: no olm/unpickle problems on start, then an encrypted DM with the bot gets an encrypted reply
        jlog = optiplex.succeed("journalctl -u mautrix-telegram.service --no-pager")
        for bad in ("unpickle", "olm", "panic", "fatal"):
            assert bad not in jlog.lower().replace("goolm", ""), (bad, jlog[-3000:])
        out = mx_dm("telegram")
        assert "encrypted reply from @telegram:nnik.dev" in out, out

        # no State outside /state: only the rendered config and the registration are written
        files = optiplex.succeed("find ${dataDir} -mindepth 1 -printf '%P\\n' | sort").split()
        print("${dataDir}:", files)
        assert sorted(files) == ["config.yaml", "telegram-registration.yaml"], files
        print(optiplex.succeed("ls -lR ${dataDir}"))
        optiplex.fail("systemctl is-failed mautrix-telegram.service")
      '';
    };
  };
}
