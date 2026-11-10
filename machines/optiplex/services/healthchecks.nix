# healthchecks (http://healthchecks.opti.plex, LAN only): the dead-man's switch of the Optiplex. The
# nightly Backup, the weekly restic check, the LAN probes and a failed-units heartbeat ping it; when a
# ping is missing it alerts through ntfy (an `ntfy` integration in its project, kept in place below).
#
#   * services.healthchecks, SQLite in /state/healthchecks (Backup takes a `sqlite3 .backup` copy, the
#     live file is excluded, see restic.nix), listening on 127.0.0.1:25582 behind a LAN-only Caddy vhost.
#     uid/gid 965 pinned. Off in restoreMode (State).
#   * One-time human step, on the host: `healthchecks-manage createsuperuser` (password to
#     Vaultwarden). That also creates the project. healthchecks-ensure (below) then sets the
#     project's ping key from sops, creates the ntfy integration and the checks with their periods, and
#     repeats that daily and on every boot, so a rotated ping key or token is applied by itself.
#     `systemctl start healthchecks-ensure` applies it at once.
#   * Pings come from the host over loopback with `optiplex-hc-ping <slug> [fail]`.
#   * LAN probes (every 5 min): Paperless and Home Assistant through Caddy (loopback with a Host header);
#     2xx/3xx pings the check, anything else pings /fail. `units-ok` (every 5 min): no failed unit.
#
# Secrets (secrets/optiplex/healthchecks.yaml): `secret_key` (Django, fresh) and `ping_key` (any random
# string of letters and digits, fresh; healthchecks.io's own are 22 characters). If the file is missing
# the service stays off and the pings fail loudly.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  hcSecrets = cfg.secretsDir + "/healthchecks.yaml";
  haveSecrets = builtins.pathExists hcSecrets;

  port = 25582;
  host = "healthchecks.opti.plex";
  stateDir = "/state/healthchecks";
  hcManage = "healthchecks-manage";
  topic = config.optiplex.monitoring.ntfy.topic;
  pkg = config.services.healthchecks.package;
  manage = "${pkg}/opt/healthchecks/manage.py";
  svcUnits = ["healthchecks-migration" "healthchecks" "healthchecks-sendalerts" "healthchecks-sendreports"];

  pingKeyPath = "/run/secrets/healthchecks/ping_key";
  # The integration points at the real local ntfy (not at optiplex.monitoring.ntfy.url, which a VM test
  # replaces by a stub) and carries the publisher token.
  ntfyOn = config.services.ntfy-sh.enable;
  ntfyUrl = lib.optionalString ntfyOn "http://${config.services.ntfy-sh.settings.listen-http}";
  ntfyTopic = config.optiplex.monitoring.ntfy.topic;
  ntfyTokenPath = lib.optionalString ntfyOn config.sops.secrets."ntfy/publisher_token".path;

  # The checks: slug, period, grace.
  checks = [
    {
      slug = "backup-nightly";
      timeout = "timedelta(days=1)";
      grace = "timedelta(hours=3)";
    }
    {
      slug = "backup-check";
      timeout = "timedelta(days=7)";
      grace = "timedelta(days=1)";
    }
    {
      slug = "lan-paperless";
      timeout = "timedelta(minutes=5)";
      grace = "timedelta(minutes=10)";
    }
    {
      slug = "lan-homeassistant";
      timeout = "timedelta(minutes=5)";
      grace = "timedelta(minutes=10)";
    }
    {
      slug = "units-ok";
      timeout = "timedelta(minutes=5)";
      grace = "timedelta(minutes=10)";
    }
  ];

  wrapPy = name: body: "def ${name}():\n" + lib.concatMapStringsSep "\n" (l: "    " + l) (lib.splitString "\n" body) + "\n${name}()\n";

  # optiplex-hc-ping <slug> [fail|start]: the ping key is a sops file, read as root.
  hcPing = pkgs.writeShellApplication {
    name = "optiplex-hc-ping";
    runtimeInputs = [pkgs.curl pkgs.coreutils];
    text = ''
      slug="$1"
      suffix=""
      case "''${2:-}" in
        fail) suffix="/fail" ;;
        start) suffix="/start" ;;
        "") ;;
        *) echo "usage: optiplex-hc-ping <slug> [fail|start]" >&2; exit 2 ;;
      esac
      key="$(cat ${pingKeyPath})"
      # create=1: the check is created on its first ping if healthchecks-ensure has not done it yet
      curl --fail --silent --show-error --max-time 20 --retry 3 --retry-connrefused --retry-delay 2 \
        --output /dev/null "http://127.0.0.1:${toString port}/ping/$key/$slug$suffix?create=1"
      echo "pinged $slug$suffix"
    '';
  };

  # One probe through Caddy: <slug> <host name>
  lanProbe = pkgs.writeShellApplication {
    name = "optiplex-lan-probe";
    runtimeInputs = [pkgs.curl pkgs.coreutils hcPing];
    text = ''
      slug="$1"
      name="$2"
      code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 20 \
        --header "Host: $name" http://127.0.0.1/ || true)"
      case "$code" in
        2* | 3*) optiplex-hc-ping "$slug" ;;
        *)
          echo "$name answered '$code'"
          optiplex-hc-ping "$slug" fail
          ;;
      esac
    '';
  };

  unitsOk = pkgs.writeShellApplication {
    name = "optiplex-units-ok";
    runtimeInputs = [pkgs.systemd pkgs.coreutils hcPing];
    text = ''
      failed="$(systemctl --failed --no-legend --plain | cut -d' ' -f1)"
      if [ -z "$failed" ]; then
        optiplex-hc-ping units-ok
      else
        echo "failed units: $failed"
        optiplex-hc-ping units-ok fail
      fi
    '';
  };

  # Runs in manage.py shell as the healthchecks user. Idempotent. A missing project (nobody ran
  # createsuperuser yet) is not an error.
  ensurePy = pkgs.writeText "healthchecks-ensure.py" ''
    import json, os, sys
    from datetime import timedelta
    from hc.accounts.models import Project
    from hc.api.models import Channel, Check

    cred = os.environ["CREDENTIALS_DIRECTORY"]
    ping_key = open(cred + "/ping_key").read().strip()
    token = open(cred + "/ntfy_token").read().strip() if os.path.exists(cred + "/ntfy_token") else ""

    project = Project.objects.filter(ping_key=ping_key).first()
    if project is None:
        projects = list(Project.objects.all())
        if len(projects) != 1:
            print(f"healthchecks-ensure: {len(projects)} projects and none has the ping key: nothing to do yet "
                  "(run `healthchecks-manage createsuperuser` first)")
            sys.exit(0)
        project = projects[0]
        project.ping_key = ping_key
        project.save()
        print("ping key set on project", project.code)

    channel = None
    if ${
      if ntfyOn
      then "True"
      else "False"
    }:
        conf = {"topic": "${ntfyTopic}", "url": "${ntfyUrl}", "priority": 4, "priority_up": 3, "token": token}
        channel = Channel.objects.filter(project=project, kind="ntfy", name="optiplex-ntfy").first()
        if channel is None:
            channel = Channel(project=project, kind="ntfy", name="optiplex-ntfy")
            print("ntfy integration created")
        channel.value = json.dumps(conf)
        channel.save()

    for slug, timeout, grace in [
    ${lib.concatMapStringsSep "\n" (c: "    (\"${c.slug}\", ${c.timeout}, ${c.grace}),") checks}
    ]:
        check = Check.objects.filter(project=project, slug=slug).first()
        if check is None:
            check = Check(project=project, slug=slug, name=slug)
            print("check created:", slug)
        check.timeout = timeout
        check.grace = grace
        if check.last_ping:
            check.alert_after = check.going_down_after()
        check.save()
        if channel is not None:
            check.channel_set.add(channel)
    print("healthchecks-ensure: done")
  '';
in {
  config = lib.mkMerge [
    {
      # Pinned ids (State on the Data disk outlives the System disk's uid map). Declared in restoreMode
      # too, so a restored /state/healthchecks is owned by an existing user.
      users.groups.healthchecks.gid = 965;
      users.users.healthchecks = {
        uid = 965;
        group = "healthchecks";
        isSystemUser = true;
      };

      environment.systemPackages = [hcPing];

      warnings = lib.optional (!haveSecrets) ''
        secrets/optiplex/healthchecks.yaml does not exist (looked in ${toString cfg.secretsDir}): healthchecks stays off and the Backup pings fail.
        Create it with fresh values (keys: secret_key, ping_key):
          (cd secrets && printf 'secret_key: %s\nping_key: %s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 11)" | sops --encrypt --input-type yaml --output-type yaml --filename-override optiplex/healthchecks.yaml /dev/stdin > optiplex/healthchecks.yaml)
        and `git add` it.
      '';
    }

    # The ping client only needs the key; it exists wherever the file does (restoreMode: pings fail, as
    # healthchecks is off there).
    (lib.mkIf haveSecrets {
      sops.secrets."healthchecks/ping_key" = {
        sopsFile = hcSecrets;
        key = "ping_key";
        owner = "root";
        mode = "0400";
        restartUnits = lib.optionals (!cfg.restoreMode) ["healthchecks-ensure.service"];
      };
      sops.secrets."healthchecks/secret_key" = {
        sopsFile = hcSecrets;
        key = "secret_key";
        owner = "healthchecks";
        mode = "0400";
        restartUnits = lib.optionals (!cfg.restoreMode) ["healthchecks.service"];
      };
    })

    (lib.mkIf (haveSecrets && !cfg.restoreMode) {
      services.healthchecks = {
        enable = true;
        dataDir = stateDir;
        listenAddress = "127.0.0.1";
        inherit port;
        settings = {
          SITE_ROOT = "http://${host}";
          SITE_NAME = "Optiplex";
          ALLOWED_HOSTS = [host "127.0.0.1" "localhost"];
          REGISTRATION_OPEN = false;
          SECRET_KEY_FILE = config.sops.secrets."healthchecks/secret_key".path;
          # The ntfy integration points at 127.0.0.1 (alerts must not depend on blocky or Caddy);
          # healthchecks refuses private addresses unless this is set. The only user is the owner.
          INTEGRATIONS_ALLOW_PRIVATE_IPS = "True";
        };
      };

      # The module only makes its StateDirectory for the default path, and a tmpfiles rule would fail
      # on the immutable /state while the Data disk is missing, so a unit that needs it does it.
      systemd.services.healthchecks-state-dir = {
        description = "healthchecks data directory in /state";
        requiredBy = map (n: "${n}.service") svcUnits;
        before = map (n: "${n}.service") svcUnits;
        unitConfig.RequiresMountsFor = ["/state"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "install -d -o healthchecks -g healthchecks -m 0750 ${stateDir}";
      };
      optiplex.stateUnits = svcUnits ++ ["healthchecks-state-dir" "healthchecks-ensure"];

      # --- vhost: LAN only, plain http. blocky already answers *.opti.plex. -------------------------
      services.caddy.virtualHosts."http://${host}".extraConfig = ''
        import lan_only
        reverse_proxy 127.0.0.1:${toString port}
      '';

      # --- the project's integration and checks -----------------------------------------------------
      systemd.services.healthchecks-ensure = {
        description = "Ensure the healthchecks ping key, ntfy integration and checks";
        wantedBy = ["healthchecks.target"];
        after = ["healthchecks.service"];
        requires = ["healthchecks.service"];
        serviceConfig = {
          Type = "oneshot";
          User = "healthchecks";
          Group = "healthchecks";
          WorkingDirectory = stateDir;
          EnvironmentFile = config.systemd.services.healthchecks.serviceConfig.EnvironmentFile;
          LoadCredential =
            ["ping_key:${pingKeyPath}"]
            ++ lib.optional ntfyOn "ntfy_token:${ntfyTokenPath}";
        };
        script = ''
          ${manage} shell -v 0 < ${ensurePy}
        '';
      };
      systemd.timers.healthchecks-ensure = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };

      # --- probes and heartbeats ---------------------------------------------------------------------
      systemd.services.healthchecks-lan-probes = {
        description = "Probe the LAN sites through Caddy and ping healthchecks";
        serviceConfig.Type = "oneshot";
        script = ''
          ${lib.getExe lanProbe} lan-paperless paperless.opti.plex
          ${lib.getExe lanProbe} lan-homeassistant homeassistant.opti.plex
        '';
      };
      systemd.timers.healthchecks-lan-probes = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "3min";
          OnUnitActiveSec = "5min";
        };
      };
      systemd.services.healthchecks-units-ok = {
        description = "Heartbeat: no failed systemd unit";
        serviceConfig.Type = "oneshot";
        script = lib.getExe unitsOk;
      };
      systemd.timers.healthchecks-units-ok = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "3min";
          OnUnitActiveSec = "5min";
        };
      };
    })

    # --- VM check. Not gated on restoreMode: the harness collects checks from the restoreMode node, and the
    # script only runs in the normal phase. Shares the account with the Backup check (whoever runs first
    # creates it).
    (lib.mkIf haveSecrets {
      optiplex.vmTest.checks.healthchecks.script = wrapPy "hc_main" ''
        optiplex.wait_for_unit("healthchecks.service")
        optiplex.wait_until_succeeds("curl -fsS -o /dev/null http://127.0.0.1:${toString port}/")
        # State on the Data disk, pinned ids, nothing on the System disk
        optiplex.succeed("test \"$(id -u healthchecks):$(id -g healthchecks)\" = 965:965")
        optiplex.succeed("test \"$(stat -c '%U:%a' ${stateDir})\" = healthchecks:750")
        optiplex.succeed("test -e /mnt/tbssd/state/healthchecks")
        optiplex.fail("test -e /var/lib/healthchecks")
        for u in ("healthchecks", "healthchecks-sendalerts", "healthchecks-state-dir"):
            optiplex.succeed(f"systemctl show -p RequiresMountsFor {u}.service | grep -q '/state'")
        # only the three Host names are served, and the ping key is checked
        optiplex.succeed("test \"$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' http://127.0.0.1:${toString port}/)\" = 400")
        optiplex.succeed("test \"$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${toString port}/ping/not-the-key/some-check)\" = 404")

        # the vhost: LAN only, plain http. A private address answers, a public one is aborted (v4 and v6).
        def hc_code(client, addr):
            return client.execute(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 10 --resolve healthchecks.opti.plex:80:{addr} http://healthchecks.opti.plex/")
        for addr in ("192.168.178.20", "fd65:c1a5:7d2b::20"):
            rc, out = hc_code(lan, addr)
            assert rc == 0 and out[0] in "23", (addr, rc, out)
        for addr in ("203.0.113.1", "2001:db8:2::1"):
            rc, out = hc_code(outside, addr)
            assert rc != 0, (addr, rc, out)  # connection closed by Caddy's abort

        # the account (the human step), then healthchecks-ensure sets the key, the ntfy integration and the checks
        optiplex.execute("${hcManage} createsuperuser --email test@example.org --password test-password-1234 < /dev/null")
        optiplex.succeed("systemctl start healthchecks-ensure.service")
        optiplex.succeed("systemctl start healthchecks-ensure.service")  # idempotent
        q = lambda code: optiplex.succeed("${hcManage} shell -v 0 -c \"" + code + "\"").strip()
        assert q("from hc.api.models import Channel; print([(c.kind, c.name) for c in Channel.objects.filter(kind='ntfy')])") == "[('ntfy', 'optiplex-ntfy')]"
        assert q("from hc.api.models import Check; print(Check.objects.filter(slug='backup-nightly').count())") == "1"
        assert q("from hc.api.models import Check; print(Check.objects.get(slug='backup-nightly').channel_set.filter(kind='ntfy').count())") == "1"

        # the ping client: success, and /fail
        optiplex.succeed("optiplex-hc-ping lan-paperless")
        assert q("from hc.api.models import Check; print(Check.objects.get(slug='lan-paperless').status)") == "up"
        # the whole alert chain: a failed ping makes healthchecks post to ntfy (loopback, publisher token)
        optiplex.succeed("optiplex-hc-ping units-ok fail")
        optiplex.wait_until_succeeds("curl -fsS -u yannik:test 'http://127.0.0.1:25581/${topic}/json?poll=1&since=all' | grep -i 'units-ok'", timeout=90)
        optiplex.succeed("optiplex-hc-ping units-ok")

        # the LAN probes and the failed-units heartbeat run and ping their checks
        optiplex.succeed("systemctl start healthchecks-lan-probes.service healthchecks-units-ok.service")
        for slug in ("lan-paperless", "lan-homeassistant", "units-ok"):
            assert int(q(f"from hc.api.models import Check; print(Check.objects.get(slug='{slug}').n_pings)")) >= 1, slug
      '';
    })
  ];
}
