# services.mautrix-telegram for the Go (bridgev2) bridge. Local module, modelled on the nixpkgs
# `services.mautrix-whatsapp` module (nixos/modules/services/matrix/mautrix-whatsapp.nix), because
# the nixpkgs module is still the Python one (config.json, alembic, `appservice.database`).
# Drop this file and custom-pkgs/mautrix-telegram once nixpkgs ships a Go-based module
# (NixOS/nixpkgs#510662, #581772).
#
# How it runs (same as the WhatsApp module):
#   * `settings` is rendered to JSON in the store, `envsubst`ed with the unit's environment (the
#     secrets come from `environmentFile`, never from the store) to dataDir/config.yaml on every start.
#   * The appservice registration is NOT generated here: it must already exist at `registrationFile`
#     (the service file installs the carried one from sops before the first start). The `as_token` and
#     `hs_token` in config.yaml are then copied from it, so the two can never disagree.
#   * Environment variables with a special meaning (set them in `environmentFile`):
#       MAUTRIX_TELEGRAM_API_ID, MAUTRIX_TELEGRAM_API_HASH     -> network.api_id (as an integer), network.api_hash
#       MAUTRIX_TELEGRAM_BRIDGE_LOGIN_SHARED_SECRET           -> double_puppet.secrets.<homeserver domain>
#     Any other `$VAR` in `settings` is substituted from the environment too (e.g. the pickle key).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.mautrix-telegram;
  dataDir = "/var/lib/mautrix-telegram";
  registrationFile = "${dataDir}/telegram-registration.yaml";
  settingsFile = "${dataDir}/config.yaml";
  settingsFormat = pkgs.formats.json {};
  settingsFileUnsubstituted = settingsFormat.generate "mautrix-telegram-config-unsubstituted.json" cfg.settings;
  appservicePort = 29317;

  defaultConfig = {
    network = {
      # api_id and api_hash come from the environment (see above)
      device_info = {
        device_model = "auto";
        system_version = "auto";
        app_version = "auto";
      };
    };
    bridge = {
      command_prefix = "!tg";
    };
    database = {
      type = "sqlite3-fk-wal";
      uri = "file:${dataDir}/mautrix-telegram.db?_txlock=immediate";
    };
    homeserver.address = "http://localhost:8008";
    appservice = {
      hostname = "127.0.0.1";
      port = appservicePort;
      id = "telegram";
      bot = {
        username = "telegrambot";
        displayname = "Telegram bridge bot";
      };
      # replaced by the values of the registration file in preStart
      as_token = "";
      hs_token = "";
      username_template = "telegram_{{.}}";
    };
    double_puppet = {
      servers = {};
      secrets = {};
    };
    # Upstream sets these to `generate`, which the bridge would then rewrite on every start.
    # Set them through `environmentFile` where the feature is used.
    encryption.pickle_key = "";
    provisioning.shared_secret = "disable";
    public_media.signing_key = "";
    direct_media.server_key = "";
    logging = {
      min_level = "info";
      writers = lib.singleton {
        type = "stdout";
        format = "pretty-colored";
        time_format = " ";
      };
    };
  };
in {
  # The nixpkgs module (Python) defines the same option path.
  disabledModules = ["services/matrix/mautrix-telegram.nix"];

  options.services.mautrix-telegram = {
    enable = lib.mkEnableOption "mautrix-telegram (Go, bridgev2), a Matrix-Telegram puppeting bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.custom-packages.mautrix-telegram;
      defaultText = lib.literalExpression "pkgs.custom-packages.mautrix-telegram";
      description = "The bridge package (custom-pkgs/mautrix-telegram).";
    };

    settings = lib.mkOption {
      apply = lib.recursiveUpdate defaultConfig;
      type = settingsFormat.type;
      default = defaultConfig;
      description = ''
        {file}`config.yaml` as a Nix attribute set (the layout of `mautrix-telegram -e`, with the
        Telegram options below `network:`). Secrets go through {option}`environmentFile`.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File with the environment of the unit (see the header of this module).";
    };

    registrationFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = registrationFile;
      description = "Where the unit expects the appservice registration (installed by the caller).";
    };

    serviceDependencies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optional config.services.matrix-synapse.enable config.services.matrix-synapse.serviceUnit;
      defaultText = lib.literalExpression "optional config.services.matrix-synapse.enable config.services.matrix-synapse.serviceUnit";
      description = "Units to require and wait for when starting the bridge.";
    };

    registerToSynapse = lib.mkOption {
      type = lib.types.bool;
      default = config.services.matrix-synapse.enable;
      defaultText = lib.literalExpression "config.services.matrix-synapse.enable";
      description = ''
        Add the registration file to `services.matrix-synapse.settings.app_service_config_files` and
        the bridge's group to Synapse's `SupplementaryGroups`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.mautrix-telegram = {
      isSystemUser = true;
      group = "mautrix-telegram";
      home = dataDir;
      description = "mautrix-telegram bridge user";
    };
    users.groups.mautrix-telegram = {};

    services.matrix-synapse = lib.mkIf cfg.registerToSynapse {
      settings.app_service_config_files = [registrationFile];
    };
    systemd.services.matrix-synapse = lib.mkIf cfg.registerToSynapse {
      serviceConfig.SupplementaryGroups = ["mautrix-telegram"];
    };

    services.mautrix-telegram.settings.homeserver.domain = lib.mkIf config.services.matrix-synapse.enable (
      lib.mkDefault config.services.matrix-synapse.settings.server_name
    );

    systemd.services.mautrix-telegram = {
      description = "mautrix-telegram, a Matrix-Telegram puppeting bridge";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"] ++ cfg.serviceDependencies;
      after = ["network-online.target"] ++ cfg.serviceDependencies;
      # ffmpeg: sticker and video conversion; lottieconverter: animated (.tgs) stickers -> gif/webp
      path = [pkgs.ffmpeg-headless pkgs.lottieconverter];

      preStart = ''
        # config.yaml = settings with the environment substituted (the file holds secrets: 0600)
        test -f '${settingsFile}' && rm -f '${settingsFile}'
        old_umask=$(umask)
        umask 0177
        ${pkgs.envsubst}/bin/envsubst -o '${settingsFile}' -i '${settingsFileUnsubstituted}'

        # The registration is carried, never generated here: without it the tokens would be new.
        if [ ! -f '${registrationFile}' ]; then
          echo "missing ${registrationFile} (the appservice registration, installed from sops)" >&2
          exit 1
        fi

        # 1. tokens of the registration into the config
        # 2. api_id / api_hash and the double puppeting secret from the environment
        ${pkgs.yq}/bin/yq -s '.[0].appservice.as_token = .[1].as_token
          | .[0].appservice.hs_token = .[1].hs_token
          | .[0]
          | if env.MAUTRIX_TELEGRAM_API_ID then .network.api_id = (env.MAUTRIX_TELEGRAM_API_ID | tonumber) else . end
          | if env.MAUTRIX_TELEGRAM_API_HASH then .network.api_hash = env.MAUTRIX_TELEGRAM_API_HASH else . end
          | if env.MAUTRIX_TELEGRAM_BRIDGE_LOGIN_SHARED_SECRET then .double_puppet.secrets.[.homeserver.domain] = env.MAUTRIX_TELEGRAM_BRIDGE_LOGIN_SHARED_SECRET else . end' \
          '${settingsFile}' '${registrationFile}' > '${settingsFile}.tmp'
        mv '${settingsFile}.tmp' '${settingsFile}'
        umask $old_umask
      '';

      serviceConfig = {
        User = "mautrix-telegram";
        Group = "mautrix-telegram";
        EnvironmentFile = cfg.environmentFile;
        StateDirectory = baseNameOf dataDir;
        WorkingDirectory = dataDir;
        ExecStart = ''
          ${lib.getExe cfg.package} \
          --config='${settingsFile}' \
          --registration='${registrationFile}' \
          --no-update
        '';
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        Restart = "on-failure";
        RestartSec = "30s";
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallErrorNumber = "EPERM";
        SystemCallFilter = ["@system-service"];
        Type = "simple";
        UMask = 27;
      };
      restartTriggers = [settingsFileUnsubstituted];
    };
  };
}
