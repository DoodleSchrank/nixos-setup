# Failure alerts: notify-failure@ (OnFailure for every service) and smartd, both
# pushing to the same ntfy topic. The ntfy server itself is an ordinary service
# file (Backup and monitoring ticket), which sets optiplex.monitoring.ntfy.*.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex.monitoring.ntfy;

  # ntfy-push <title> <priority>   (message body on stdin)
  # Fails softly: without a configured URL, or when the server is down, it logs and exits 0,
  # so the hook can never turn into a failure of its own.
  push = pkgs.writeShellApplication {
    name = "ntfy-push";
    runtimeInputs = [pkgs.curl pkgs.coreutils];
    text = ''
      title="$1"
      priority="''${2:-default}"
      body="$(cat)"
      url=${lib.escapeShellArg (toString cfg.url)}
      if [ -z "$url" ]; then
        echo "ntfy is not configured (optiplex.monitoring.ntfy.url); not sent: $title"
        echo "$body"
        exit 0
      fi
      args=(--silent --show-error --max-time 15 -H "Title: $title" -H "Priority: $priority" -H "Tags: warning")
      ${lib.optionalString (cfg.tokenFile != null) ''
        args+=(-H "Authorization: Bearer $(cat ${lib.escapeShellArg (toString cfg.tokenFile)})")
      ''}
      if ! printf '%s\n' "$body" | curl "''${args[@]}" --data-binary @- "$url/${cfg.topic}" >/dev/null; then
        echo "ntfy push failed (url $url): $title"
      fi
      exit 0
    '';
  };

  notifyFailure = pkgs.writeShellApplication {
    name = "notify-failure";
    runtimeInputs = [push pkgs.systemd pkgs.coreutils pkgs.hostname];
    text = ''
      unit="$1"
      {
        echo "$unit failed on $(hostname)"
        echo
        journalctl -u "$unit" -n 20 --no-pager -o short-iso || true
      } | ntfy-push "$unit failed on $(hostname)" high
    '';
  };

  smartdNotify = pkgs.writeShellScript "smartd-notify" ''
    {
      echo "$SMARTD_FULLMESSAGE"
    } | ${push}/bin/ntfy-push "SMART: $SMARTD_FAILTYPE on $SMARTD_DEVICESTRING ($(${pkgs.hostname}/bin/hostname))" high
  '';

  # A top-level drop-in reaches every .service; the instance unit clears it again
  # (its drop-in sorts after the generic one) so a failing hook cannot loop.
  dropIns = pkgs.runCommand "notify-failure-dropins" {} ''
    d=$out/etc/systemd/system
    mkdir -p $d/service.d $d/notify-failure@.service.d
    printf '[Unit]\nOnFailure=notify-failure@%%n.service\n' > $d/service.d/10-notify-failure.conf
    printf '[Unit]\nOnFailure=\n' > $d/notify-failure@.service.d/20-no-onfailure.conf
  '';

  smartOpts = "-m <nomailer> -M exec ${smartdNotify}";
in {
  options.optiplex.monitoring.ntfy = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://127.0.0.1:2586";
      description = "Base URL of the ntfy server. null: alerts are only logged.";
    };
    topic = lib.mkOption {
      type = lib.types.str;
      default = "optiplex";
      description = "ntfy topic for failed units and SMART alerts.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File with an ntfy access token (a sops secret path, read as root).";
    };
  };

  config = {
    systemd.packages = [dropIns];

    systemd.services."notify-failure@" = {
      description = "Push a failure of %i to ntfy";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${notifyFailure}/bin/notify-failure %i";
      };
    };

    services.smartd = {
      enable = true;
      autodetect = false;
      notifications.wall.enable = false; # only the ntfy exec script below
      defaults.monitored = "-a -o on -s (S/../.././02|L/../01/./04)"; # short daily, long monthly
      devices = [
        {
          device = "/dev/nvme0"; # System disk
          options = smartOpts;
        }
        {
          device = "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_4TB_S758NX0Y400754Z"; # Data disk
          options = smartOpts;
        }
      ];
    };
  };
}
