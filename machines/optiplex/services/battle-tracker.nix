# battle-tracker (Own app): pnp.nnik.dev (Flutter web bundle) and pnp-backend.nnik.dev (sync server).
#
# The packaging lives in the app repo (flake input `battle-tracker`: packages.<system>.{web,server} and
# nixosModules.default = services.bt-sync). This file wires it in:
#
#   * Sync server  services.bt-sync on 127.0.0.1:8087, settings at the defaults, State in
#                  /state/battle-tracker (owned by bt-sync, uid/gid 961 from the module). The sync State is
#                  empty, so there is nothing to restore. No firewall ports: everything is loopback.
#   * Profile      /nix/var/nix/profiles/battle-tracker, on the System disk (not State: a reinstall re-seeds
#                  it). Each generation is { web, server, rev } (farm.nix), so a rollback switches the web
#                  bundle and the server together. bt-sync runs <profile>/server/bin/server and Caddy serves
#                  <profile>/web.
#   * Seed         battle-tracker-seed.service fills the profile from the flake input's pinned build when it
#                  is missing (fresh install, Cutover). bt-sync and Caddy are ordered after it. The pin is
#                  built into the system closure by the PC, so the seed needs no network.
#   * Deploy       battle-tracker-deploy.service (oneshot, root, ./battle-tracker/deploy.sh) builds the head
#                  of `main` on the Optiplex, switches the profile, restarts bt-sync, health-checks the sync
#                  server and the web bundle through Caddy, and rolls back by itself on failure (the unit
#                  fails, notify-failure@ reports it). Two triggers: battle-tracker-deploy.timer (hourly, the
#                  safety net) and the webhook receiver (below). The deploy path needs no token and no
#                  runner: the repo is public, and git.nnik.dev is reached through this host's own Caddy.
#   * Receiver     services.webhook on 127.0.0.1:25585 (loopback only). A Gitea push webhook to
#                  http://127.0.0.1:25585/hooks/battle-tracker-deploy (content type JSON, branch filter
#                  main; no secret: it can only trigger a rebuild of public `main`) writes the trigger file
#                  /run/battle-tracker-deploy/trigger when `ref` is refs/heads/main, nothing else. The path
#                  unit battle-tracker-deploy.path starts the deploy from that. Gitea's webhook allow-list is
#                  `loopback`, so this is the only target. The hook itself is created by hand on the new
#                  Gitea (human-todos.md); until then the timer covers deploys.
#   * Caddy        both vhosts are public and carry the pnp CSP (replaces the snippet's frame-ancestors default).
#
# The deploy build uses the app flake's own flake.lock (its nixpkgs may differ from the host's). That is
# deliberate: the app deploys on its own, independent of host bumps.
#
# restoreMode: the sync service, seed, deploy, timer, path and receiver are all off, and so are the vhosts.
{
  config,
  inputs,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  opt = cfg.battleTracker;
  app = inputs.battle-tracker;
  system = pkgs.stdenv.hostPlatform.system;

  profile = "/nix/var/nix/profiles/battle-tracker";
  stateDir = "/state/battle-tracker";
  syncPort = 8087; # the module's default, kept
  triggerDir = "/run/battle-tracker-deploy";
  trigger = "${triggerDir}/trigger";
  webhookId = "battle-tracker-deploy";

  timerConfig = {
    OnCalendar = "hourly";
    Persistent = true;
    RandomizedDelaySec = "5min";
  };

  # Today's pnp CSP (nginx), on both vhosts.
  csp = "default-src 'self' http: https: data: blob: 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'";

  # The pinned baseline: the same { web, server, rev } shape as a deployed generation.
  baseline = pkgs.linkFarm "battle-tracker-baseline" [
    {
      name = "web";
      path = app.packages.${system}.web.override {syncBaseUrl = opt.syncBaseUrl;};
    }
    {
      name = "server";
      path = app.packages.${system}.server;
    }
    {
      name = "rev";
      path = pkgs.writeText "battle-tracker-rev" "${app.rev or "unknown"}\n";
    }
  ];

  deployScript = pkgs.writeShellApplication {
    name = "battle-tracker-deploy";
    runtimeInputs = with pkgs; [config.nix.package git jq curl coreutils systemd];
    text = builtins.readFile ./battle-tracker/deploy.sh;
  };

  seedScript = pkgs.writeShellScript "battle-tracker-seed" ''
    if [ -e ${profile} ]; then
      echo "${profile} exists, leaving it alone"
      exit 0
    fi
    ${config.nix.package}/bin/nix-env --profile ${profile} --set ${baseline}
  '';

  # The receiver's only action: leave a trace for the path unit.
  touchTrigger = pkgs.writeShellScript "battle-tracker-trigger" ''
    date +%s > ${trigger}
  '';

  # --- VM test pieces ------------------------------------------------------------------------------
  # A local git repo with a fake app (fake-app.nix) stands in for git.nnik.dev: the real app is a 40 MB
  # Flutter build and the VM has no internet. The deploy unit is pointed at it with a drop-in.
  fakeServer = pkgs.replaceVars ./battle-tracker/fake-server.py {python = pkgs.python3;};
  fakeApp = pkgs.replaceVars ./battle-tracker/fake-app.nix {
    bash = pkgs.bash;
    coreutils = pkgs.coreutils;
    serverScript = fakeServer;
  };
  # The check scripts of all services share one Python namespace: run each in a function.
  wrapPy = name: body: "def ${name}():\n" + lib.concatMapStringsSep "\n" (l: "    " + l) (lib.splitString "\n" body) + "\n${name}()\n";
  caCert = pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem"; # pebble's WFE certificate CA
  units = ["battle-tracker-state-dir.service" "battle-tracker-seed.service" "battle-tracker-deploy.service" "battle-tracker-deploy.path" "webhook.service" "bt-sync.service"];
in {
  imports = [inputs.battle-tracker.nixosModules.default];

  options.optiplex.battleTracker = {
    source = lib.mkOption {
      type = lib.types.str;
      default = "git+https://git.nnik.dev/AItopia/battle-tracker";
      description = "Flake URL (no ref) of the app repo that battle-tracker-deploy builds `main` from.";
    };
    syncBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://pnp-backend.nnik.dev";
      description = "Compile-time sync URL of the web bundle (BT_SYNC_BASE_URL), for the pinned baseline and every deploy.";
    };
    keepGenerations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Profile generations battle-tracker-deploy keeps.";
    };
    webhookPort = lib.mkOption {
      type = lib.types.port;
      default = 25585;
      description = "Loopback port of the push webhook receiver.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (!cfg.restoreMode) {
      # --- the sync server -----------------------------------------------------------------------------
      services.bt-sync = {
        enable = true;
        package = "${profile}/server";
        dataDir = stateDir;
        port = syncPort;
      };

      # A oneshot, not a tmpfiles rule (a `d` on the immutable /state, with the Data disk missing, breaks
      # systemd-tmpfiles-setup) and not an ExecStartPre (the unit's ReadWritePaths= must exist before any
      # of its processes starts).
      systemd.services.battle-tracker-state-dir = {
        description = "Create /state/battle-tracker for the sync server";
        wantedBy = ["multi-user.target"];
        before = ["bt-sync.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/install -d -m 0750 -o bt-sync -g bt-sync ${stateDir}";
        };
      };
      systemd.services.bt-sync = {
        requires = ["battle-tracker-seed.service" "battle-tracker-state-dir.service"];
        after = ["battle-tracker-seed.service" "battle-tracker-state-dir.service"];
      };
      # RequiresMountsFor=/state (no start without the Data disk)
      optiplex.stateUnits = ["bt-sync" "battle-tracker-state-dir"];

      # --- the profile -----------------------------------------------------------------------------------
      systemd.services.battle-tracker-seed = {
        description = "Seed the battle-tracker profile from the pinned build";
        wantedBy = ["multi-user.target"];
        before = ["bt-sync.service" "caddy.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = seedScript;
        };
      };
      systemd.services.caddy = {
        wants = ["battle-tracker-seed.service"];
        after = ["battle-tracker-seed.service"];
      };

      # --- the deploy ------------------------------------------------------------------------------------
      systemd.services.battle-tracker-deploy = {
        description = "Build the head of main of battle-tracker and switch the profile";
        after = ["network-online.target" "gitea.service" "battle-tracker-seed.service"];
        wants = ["network-online.target"];
        requires = ["battle-tracker-seed.service"];
        environment = {
          BT_SOURCE = opt.source;
          BT_PROFILE = profile;
          BT_FARM = "${./battle-tracker/farm.nix}";
          BT_BASH = "${pkgs.bash}";
          BT_COREUTILS = "${pkgs.coreutils}";
          BT_SYNC_BASE_URL = opt.syncBaseUrl;
          BT_KEEP = toString opt.keepGenerations;
          BT_SERVICE = "bt-sync.service";
          BT_HEALTH_URL = "http://127.0.0.1:${toString syncPort}/health";
          BT_WEB_URL = "https://pnp.nnik.dev";
          BT_WEB_RESOLVE = "pnp.nnik.dev:443:127.0.0.1";
          BT_FAILED_FILE = "/var/cache/battle-tracker-deploy/failed-rev";
          # nix and git want a home and must never prompt
          HOME = "/var/cache/battle-tracker-deploy";
          GIT_TERMINAL_PROMPT = "0";
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe deployScript;
          CacheDirectory = "battle-tracker-deploy";
          TimeoutStartSec = "1h"; # a cold Flutter build
          # the build must not starve the other services
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };

      systemd.timers.battle-tracker-deploy = {
        wantedBy = ["timers.target"];
        inherit timerConfig;
      };

      # --- the receiver ----------------------------------------------------------------------------------
      services.webhook = {
        enable = true;
        ip = "127.0.0.1";
        port = opt.webhookPort;
        verbose = false;
        hooks.${webhookId} = {
          execute-command = "${touchTrigger}";
          response-message = "deploy requested\n";
          trigger-rule.match = {
            type = "value";
            value = "refs/heads/main";
            parameter = {
              source = "payload";
              name = "ref";
            };
          };
        };
      };
      systemd.services.webhook.serviceConfig = {
        RuntimeDirectory = "battle-tracker-deploy";
        RuntimeDirectoryPreserve = true; # the path unit watches inside it
        RuntimeDirectoryMode = "0750";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      };

      systemd.paths.battle-tracker-deploy = {
        wantedBy = ["multi-user.target"];
        pathConfig.PathChanged = trigger;
      };

      # --- Caddy -----------------------------------------------------------------------------------------
      # useACMEHost = "nnik.dev" comes from the base helper.
      services.caddy.virtualHosts."pnp.nnik.dev".extraConfig = ''
        import security
        header Content-Security-Policy "${csp}"
        # Flutter's output file names are not content-hashed.
        header Cache-Control "no-cache"
        root * ${profile}/web
        encode zstd gzip
        # In a route: try_files would otherwise rewrite /healthz to /index.html first.
        route {
            respond /healthz 200
            try_files {path} {path}/ /index.html
            file_server
        }
      '';
      # Caddy's X-Forwarded-For replaces whatever the client sent (no trusted_proxies), and the server
      # keys its rate limits on the first entry.
      services.caddy.virtualHosts."pnp-backend.nnik.dev".extraConfig = ''
        import security
        header Content-Security-Policy "${csp}"
        reverse_proxy 127.0.0.1:${toString syncPort}
      '';
    })

    # The fake app (and so its server script, bash and coreutils) must be valid paths in the test VM's own
    # store: the deploy builds them in the VM's sandbox. Only the qemu-vm module has the option.
    (lib.optionalAttrs (options ? virtualisation && options.virtualisation ? additionalPaths) {
      virtualisation.additionalPaths = [fakeApp];
    })

    {
      # --- VM test ---------------------------------------------------------------------------------------
      # (The real timer would deploy from git.nnik.dev; tests/optiplex/offline.nix switches it off in VMs.)
      optiplex.vmTest.checks.battle-tracker-0-restore = {
        phase = "restore";
        script = wrapPy "bt_restore" ''
          # restoreMode: nothing of battle-tracker runs or even exists as a unit, and the profile is empty
          for u in ${lib.concatStringsSep ", " (map (u: ''"${u}"'') units)}:
              optiplex.fail(f"systemctl cat {u}")
          optiplex.fail("test -e ${profile}")
          optiplex.fail("ss -Hltn 'sport = :${toString syncPort}' | grep -q .")
          optiplex.fail("ss -Hltn 'sport = :${toString opt.webhookPort}' | grep -q .")
          # and the vhosts are gone: the catch-all drops the names
          optiplex.fail("curl -sS --max-time 5 --resolve pnp.nnik.dev:443:127.0.0.1 -k https://pnp.nnik.dev/")
        '';
      };

      optiplex.vmTest.checks.battle-tracker-1-seed = {
        script = wrapPy "bt_seed" ''
          # the profile was empty at first boot (the restoreMode phase asserted it); the seed filled it
          # from the pinned input before bt-sync started
          optiplex.wait_for_unit("battle-tracker-seed.service")
          optiplex.succeed("test -L ${profile}")
          optiplex.succeed("test -x ${profile}/server/bin/server -a -f ${profile}/web/index.html")
          assert optiplex.succeed("cat ${profile}/rev").strip() == "${app.rev or "unknown"}"
          gens = optiplex.succeed("nix-env --profile ${profile} --list-generations").split("\n")
          assert len([l for l in gens if l.strip()]) == 1, gens
          # the sync URL is compiled into the web bundle
          optiplex.succeed("grep -q https://pnp-backend.nnik.dev ${profile}/web/main.dart.js")
          # ordering
          for u in ("bt-sync.service", "caddy.service"):
              after = optiplex.succeed(f"systemctl show -p After {u}")
              assert "battle-tracker-seed.service" in after, (u, after)
          assert "battle-tracker-seed.service" in optiplex.succeed("systemctl show -p Requires bt-sync.service")
          # re-running it leaves the profile alone
          optiplex.succeed("systemctl restart battle-tracker-seed.service")
          assert len([l for l in optiplex.succeed("nix-env --profile ${profile} --list-generations").split("\n") if l.strip()]) == 1
        '';
      };

      optiplex.vmTest.checks.battle-tracker-2-service = {
        script = wrapPy "bt_service" ''
          optiplex.wait_for_unit("bt-sync.service")
          optiplex.wait_until_succeeds("curl -fsS http://127.0.0.1:${toString syncPort}/health")
          assert '"status":"ok"' in optiplex.succeed("curl -fsS http://127.0.0.1:${toString syncPort}/health")
          # the real server runs from the profile, as bt-sync (961), on loopback only
          optiplex.succeed("systemctl show -p ExecStart bt-sync.service | grep -q '${profile}/server/bin/server'")
          pid = optiplex.succeed("systemctl show -p MainPID --value bt-sync.service").strip()
          assert optiplex.succeed(f"ps -o user= -p {pid}").strip() == "bt-sync"
          optiplex.succeed("test \"$(id -u bt-sync):$(id -g bt-sync)\" = 961:961")
          optiplex.succeed("systemctl show -p RequiresMountsFor bt-sync.service | grep -q '/state'")
          optiplex.fail("test -e /var/lib/bt-sync")
          assert optiplex.succeed("stat -c %U:%G:%a ${stateDir}").strip() == "bt-sync:bt-sync:750"
          assert "127.0.0.1:${toString syncPort}" in optiplex.succeed("ss -Hltn 'sport = :${toString syncPort}'")
          optiplex.fail("ss -Hltn 'sport = :${toString syncPort}' | grep -v 127.0.0.1")
          # not reachable from another node
          lan.fail("curl -sS --max-time 4 http://192.168.178.20:${toString syncPort}/health")
          outside.fail("curl -sS --max-time 4 http://203.0.113.1:${toString syncPort}/health")
          # a document lands in /state/battle-tracker (the Data disk) and survives a restart
          key = "0123456789abcdef0123456789abcdef"
          optiplex.succeed(f"curl -fsS -X PUT -d '{{\"groups\": []}}' http://127.0.0.1:${toString syncPort}/v1/groups/{key}")
          optiplex.succeed(f"test \"$(stat -c %U ${stateDir}/{key}.json)\" = bt-sync")
          optiplex.succeed(f"test -e /mnt/tbssd${stateDir}/{key}.json")
          optiplex.succeed("systemctl restart bt-sync.service")
          optiplex.wait_until_succeeds(f"curl -fsS http://127.0.0.1:${toString syncPort}/v1/groups/{key}")
        '';
      };

      optiplex.vmTest.checks.battle-tracker-3-caddy = {
        script = wrapPy "bt_caddy" ''
          pnp = "pnp.nnik.dev"
          back = "pnp-backend.nnik.dev"
          # the cert comes from pebble, whose root is random per start: fetched through its WFE-trusted port
          lan.wait_until_succeeds("curl -sS --cacert ${caCert} --resolve acme.test:15000:192.168.178.60 https://acme.test:15000/roots/0 -o /tmp/pebble-root.pem", timeout=60)
          def get(host, path, extra=""):
              return f"curl -sS --cacert /tmp/pebble-root.pem --resolve {host}:443:192.168.178.20 {extra} https://{host}{path}"
          lan.wait_until_succeeds(get(pnp, "/") + " -o /dev/null", timeout=120)

          def head(host, path):
              return lan.succeed(get(host, path, "-D - -o /dev/null")).lower()

          # the web bundle: index, a deep path (SPA fallback), main.dart.js, wasm
          for path in ("/", "/groups/x", "/deep/er/path"):
              h = head(pnp, path)
              assert h.startswith("http/2 200") or h.startswith("http/1.1 200"), (path, h)
          assert lan.succeed(get(pnp, "/groups/x")) == lan.succeed(get(pnp, "/")), "deep paths serve index.html"
          h = head(pnp, "/main.dart.js")
          assert " 200" in h.splitlines()[0] and "cache-control: no-cache" in h, h
          assert "content-type: text/javascript" in h or "content-type: application/javascript" in h, h
          wasm = optiplex.succeed("find ${profile}/web/ -name '*.wasm' | head -1").strip()
          assert wasm, "the bundle has a wasm file"
          h = head(pnp, wasm.replace("${profile}/web", ""))
          assert "content-type: application/wasm" in h, h
          assert lan.succeed(get(pnp, "/healthz", "-o /dev/null -w '%{http_code}'")) == "200"
          # a file that does not exist but looks like one still falls back to index.html (nginx parity)
          assert lan.succeed(get(pnp, "/nope.js", "-o /dev/null -w '%{http_code}'")) == "200"

          # the sync server, through Caddy
          assert '"status":"ok"' in lan.succeed(get(back, "/health"))
          assert lan.succeed(get(back, "/health", "-o /dev/null -w '%{http_code}'")) == "200"

          # exactly one CSP, equal to the pnp string, plus HSTS and nosniff, on both vhosts
          want = "${csp}"
          for host in (pnp, back):
              hd = lan.succeed(get(host, "/health" if host == back else "/", "-D - -o /dev/null")).splitlines()
              csps = [l for l in hd if l.lower().startswith("content-security-policy:")]
              assert len(csps) == 1, (host, csps)
              assert csps[0].split(":", 1)[1].strip() == want, (host, csps)
              low = [l.lower() for l in hd]
              assert "strict-transport-security: max-age=31536000" in low, (host, hd)
              assert "x-content-type-options: nosniff" in low, (host, hd)

          # Caddy's X-Forwarded-For replaces the client's: 25 share requests with 25 different spoofed
          # addresses are all one client (192.168.178.50) and run into the limit of 20 per window
          codes = []
          for i in range(25):
              codes.append(lan.succeed(get(back, "/v1/share", f"-X POST -H 'X-Forwarded-For: 10.9.8.{i}' -d '{{\"group\": {{}}}}' -o /dev/null -w '%{{http_code}}'")))
          print(codes)
          assert "429" in codes, codes
          assert codes[0] == "201", codes
        '';
      };

      optiplex.vmTest.checks.battle-tracker-4-receiver = {
        script = wrapPy "bt_receiver" ''
          port = ${toString opt.webhookPort}
          optiplex.wait_for_unit("webhook.service")
          optiplex.wait_until_succeeds(f"ss -Hltn 'sport = :{port}' | grep -q 127.0.0.1:{port}")
          optiplex.fail(f"ss -Hltn 'sport = :{port}' | grep -v 127.0.0.1")
          # answers on loopback, not from another node
          assert optiplex.execute(f"curl -sS --max-time 5 http://127.0.0.1:{port}/hooks/nothing")[0] == 0
          lan.fail(f"curl -sS --max-time 4 http://192.168.178.20:{port}/hooks/${webhookId}")
          outside.fail(f"curl -sS --max-time 4 http://203.0.113.1:{port}/hooks/${webhookId}")
          # runs as its own user, and the path unit watches the trigger file it writes
          pid = optiplex.succeed("systemctl show -p MainPID --value webhook.service").strip()
          assert optiplex.succeed(f"ps -o user= -p {pid}").strip() == "webhook"
          optiplex.succeed("systemctl is-active battle-tracker-deploy.path")
          optiplex.succeed("systemctl cat battle-tracker-deploy.path | grep -q 'PathChanged=${trigger}'")
          # the timer (switched off in VMs, see offline.nix): hourly, persistent, a little jitter
          import json
          tc = json.loads(${builtins.toJSON (builtins.toJSON timerConfig)})
          assert tc["OnCalendar"] == "hourly" and tc["Persistent"] is True and tc["RandomizedDelaySec"] == "5min", tc
        '';
      };

      # Deploys and the receiver's effect on them, against a local repo with the fake app.
      optiplex.vmTest.checks.battle-tracker-5-deploy = {
        script = wrapPy "bt_deploy" ''
          repo = "/var/tmp/bt-app"
          hook = "http://127.0.0.1:${toString opt.webhookPort}/hooks/${webhookId}"
          prof = "${profile}"
          sh = lambda c: optiplex.succeed(c).strip()

          # the deploy unit builds from the local repo, and trusts pebble's root for its Caddy health check
          optiplex.wait_until_succeeds("curl -sS --cacert ${caCert} --resolve acme.test:15000:192.168.178.60 https://acme.test:15000/roots/0 -o /tmp/pebble-root.pem", timeout=60)
          optiplex.succeed("mkdir -p /run/systemd/system/battle-tracker-deploy.service.d")
          optiplex.succeed("printf '[Service]\\nEnvironment=BT_SOURCE=git+file://" + repo + "\\nEnvironment=BT_WEB_CACERT=/tmp/pebble-root.pem\\n' > /run/systemd/system/battle-tracker-deploy.service.d/test.conf")
          optiplex.succeed("systemctl daemon-reload")
          optiplex.succeed(f"mkdir -p {repo} && cd {repo} && git init -q -b main && git config user.email t@example.com && git config user.name t")

          def commit(gen, mode):
              optiplex.succeed(f"sed -e 's/%GEN%/{gen}/; s/%MODE%/{mode}/' ${fakeApp} > {repo}/flake.nix")
              optiplex.succeed(f"cd {repo} && git add flake.nix && git commit -q -m {gen}")
              return sh(f"git -C {repo} rev-parse HEAD")

          def generations():
              return len([l for l in optiplex.succeed(f"nix-env --profile {prof} --list-generations").split("\n") if l.strip()])

          def invocation():
              return sh("systemctl show -p InvocationID --value battle-tracker-deploy.service")

          def settle():
              optiplex.wait_until_succeeds("test \"$(systemctl is-active battle-tracker-deploy.service)\" != activating", timeout=300)

          def post(ref):
              return optiplex.succeed(f"curl -sS -X POST -H 'Content-Type: application/json' -d '{{\"ref\": \"{ref}\"}}' {hook}")

          def bt_pid():
              return sh("systemctl show -p MainPID --value bt-sync.service")

          base_gens = generations()
          pid0 = bt_pid()
          before = invocation()

          with subtest("a push to another branch does not start the deploy"):
              c1 = commit("gen1", "ok")
              post("refs/heads/feature")
              optiplex.sleep(4)
              assert invocation() == before
              optiplex.fail("test -e ${trigger}")

          with subtest("a push to main starts it: a new generation, bt-sync restarted, web and server switched"):
              post("refs/heads/main")
              optiplex.wait_until_succeeds(f"test \"$(systemctl show -p InvocationID --value battle-tracker-deploy.service)\" != '{before}'", timeout=60)
              settle()
              assert sh("systemctl show -p Result --value battle-tracker-deploy.service") == "success"
              assert generations() == base_gens + 1, generations()
              assert sh(f"cat {prof}/rev") == c1
              assert "fake web gen1" in sh(f"cat {prof}/web/index.html")
              # the compile-time sync URL reached the app build
              optiplex.succeed(f"grep -q 'https://pnp-backend.nnik.dev' {prof}/web/main.dart.js")
              assert bt_pid() != pid0 and bt_pid() != "0"
              optiplex.succeed("curl -fsS http://127.0.0.1:${toString syncPort}/health")
              optiplex.succeed("test \"$(stat -c %U ${stateDir}/.fake-health)\" = bt-sync")
              # Caddy serves the new bundle right away
              assert "fake web gen1" in optiplex.succeed("curl -sS --cacert /tmp/pebble-root.pem --resolve pnp.nnik.dev:443:127.0.0.1 https://pnp.nnik.dev/")
              # the State is the same directory as before
              optiplex.succeed("test -e ${stateDir}/0123456789abcdef0123456789abcdef.json")

          with subtest("main unchanged: nothing is built, nothing restarts"):
              pid1 = bt_pid()
              optiplex.succeed("systemctl start battle-tracker-deploy.service")
              assert generations() == base_gens + 1
              assert bt_pid() == pid1
              optiplex.succeed("journalctl -u battle-tracker-deploy.service -n 5 --no-pager | grep -q 'which is live'")

          with subtest("a server that fails /health: rolled back, bt-sync healthy, the unit failed, ntfy told"):
              commit("gen2-bad", "unhealthy")
              optiplex.fail("systemctl start battle-tracker-deploy.service")
              assert sh(f"cat {prof}/rev") == c1
              assert "fake web gen1" in sh(f"cat {prof}/web/index.html")
              assert generations() == base_gens + 1, generations()
              optiplex.succeed("systemctl is-active bt-sync.service")
              optiplex.succeed("curl -fsS http://127.0.0.1:${toString syncPort}/health")
              assert sh("systemctl show -p Result --value battle-tracker-deploy.service") == "exit-code"
              optiplex.wait_until_succeeds("grep -q 'battle-tracker-deploy.service failed on optiplex' /tmp/ntfy.log")
              optiplex.succeed("journalctl -u battle-tracker-deploy.service --no-pager | grep -q 'rolling back to generation'")
              optiplex.succeed("systemctl reset-failed battle-tracker-deploy.service")
              # the same head is not rebuilt (and bt-sync not restarted) every hour
              pid2 = bt_pid()
              optiplex.succeed("systemctl start battle-tracker-deploy.service")
              assert bt_pid() == pid2
              optiplex.succeed("journalctl -u battle-tracker-deploy.service -n 5 --no-pager | grep -q 'failed to deploy before'")

          with subtest("a commit that does not build: the profile and bt-sync are untouched"):
              commit("gen3-nobuild", "buildfail")
              pid3 = bt_pid()
              optiplex.fail("systemctl start battle-tracker-deploy.service")
              assert sh(f"cat {prof}/rev") == c1
              assert bt_pid() == pid3
              assert generations() == base_gens + 1
              optiplex.succeed("systemctl reset-failed battle-tracker-deploy.service")

          with subtest("the next good commit deploys again, and old generations are pruned to the keep count"):
              c4 = commit("gen4", "ok")
              optiplex.succeed("systemctl start battle-tracker-deploy.service")
              assert sh(f"cat {prof}/rev") == c4
              assert "fake web gen4" in sh(f"cat {prof}/web/index.html")
              assert generations() == base_gens + 2, generations()
              for i in range(5, 5 + ${toString opt.keepGenerations}):
                  commit(f"gen{i}", "ok")
                  optiplex.succeed("systemctl start battle-tracker-deploy.service")
              assert generations() == ${toString opt.keepGenerations}, generations()
              optiplex.succeed("systemctl is-active bt-sync.service")
        '';
      };
    }
  ];
}
