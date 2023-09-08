{
  services.matrix-synapse = {
    enable = true;
    app_service_config_files = [
      # The registration file is automatically generated after starting the
      # appservice for the first time.
      # cp /var/lib/mautrix-telegram/telegram-registration.yaml \
      #   /var/lib/matrix-synapse/
      # chown matrix-synapse:matrix-synapse \
      #   /var/lib/matrix-synapse/telegram-registration.yaml
      "/var/lib/matrix-synapse/telegram-registration.yaml"
    ];
    # ...
  };

  services.mautrix-telegram = {
    enable = true;

    # file containing the appservice and telegram tokens
    environmentFile = "/etc/secrets/mautrix-telegram.env";

    # The appservice is pre-configured to use SQLite by default.
    # It's also possible to use PostgreSQL.
    settings = {
      homeserver = {
        address = "http://localhost:8008";
        domain = "domain.tld";
      };
      appservice = {
        provisioning.enabled = false;
        id = "telegram";
        public = {
          enabled = true;
          prefix = "/public";
          external = "http://domain.tld:8080/public";
        };

        # The service uses SQLite by default, but it's also possible to use
        # PostgreSQL instead:
        #database = "postgresql:///mautrix-telegram?host=/run/postgresql";
      };
      bridge = {
        relaybot.authless_portals = false;
        permissions = {
          "@someadmin:domain.tld" = "admin";
        };

        # Animated stickers conversion requires additional packages in the
        # service's path.
        # If this isn't a fresh installation, clearing the bridge's uploaded
        # file cache might be necessary (make a database backup first!):
        # delete from telegram_file where \
        #   mime_type in ('application/gzip', 'application/octet-stream')
        animated_sticker = {
          target = "gif";
          args = {
            width = 256;
            height = 256;
            fps = 30;               # only for webm
            background = "020202";  # only for gif, transparency not supported
          };
        };
      };
    };
  };

  systemd.services.mautrix-telegram.path = with pkgs; [
    lottieconverter  # for animated stickers conversion, unfree package
    ffmpeg           # if converting animated stickers to webm (very slow!)
  ];
}