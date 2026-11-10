# Seafile 13 (filesync.nnik.dev): upstream's container image under rootful podman. The one documented
# exception to "native NixOS" (ADR 0001, ticket 17): since 13 upstream supports only Docker for the
# community edition and nixpkgs dropped the module. No Docker daemon.
#
#   * Image seafileltd/seafile-mc:13.0.29, pinned by digest and loaded from a Nix-built tarball
#     (dockerTools.pullImage), so the build is reproducible and the VM test needs no network.
#     Update = bump tag, digest and hash below on purpose. The image runs the 12.0 -> 13.0 upgrade
#     scripts by itself on the first start (version stamp seafile-data/current_version).
#   * Database: the shared native MariaDB (databases.nix / mariadb.nix) over TCP on the podman
#     network's gateway, account `seafile`. Cache: a native Redis (`redis-seafile`) on the same
#     address. Both listen on all addresses and are open in the firewall only on the interface of
#     the podman network (podman-seafile), never on the LAN.
#   * State: /state/seafile (Data disk) is /shared/seafile in the container. The image's nginx is
#     baked in since 13, so nothing else of /shared needs to persist (the "System-disk /shared"
#     of the ticket text is not needed). Thumbnails are a cache and not carried (seahub-data/thumbnail).
#   * Secrets (secrets/optiplex/seafile.yaml: db_password, jwt_private_key, seahub_secret_key) stay in
#     /run/secrets: db password and JWT key reach the container as an env file (sops template),
#     seahub's SECRET_KEY as a read-only file that seahub_settings.py reads (seafile-prepare-state).
#   * Public vhost filesync.nnik.dev -> 127.0.0.1:25577 (the container's nginx; it routes /seafhttp
#     and /seafdav itself). Opens no port of its own.
#   * restoreMode: the container (and with it podman-seafile.service) does not exist. The network,
#     Redis, the secrets, the helper script and MariaDB do.
#   * The container refuses to start until `seafile-prepare-state` has run on the copied State
#     (so a missing copy never lets the image set up an empty server with its default admin).
#
# Copy and upgrade procedure for the Cutover runbook: see the Answer of ticket 34 and
# `seafile-prepare-state --help`.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  net = cfg.databases.seafileNetwork;

  version = "13.0.29";
  image = pkgs.dockerTools.pullImage {
    imageName = "seafileltd/seafile-mc";
    imageDigest = "sha256:9506f49d5e5065082c134e6348498eed5a5866ddbd94bd5a3e479a6c285bc61a";
    hash = "sha256-QRzs+CUHd5t06ertmyoZkxcK5Fnh8O9XS2gRQNOPpIU=";
    finalImageTag = version;
    os = "linux";
    arch = "amd64";
  };
  # Test only: the Docker-era version, to create a synthetic 12 State.
  image12 = pkgs.dockerTools.pullImage {
    imageName = "seafileltd/seafile-mc";
    imageDigest = "sha256:8d0dd6b682c12cb0e1d4f1f73ba223b0176e9e3d43805408a2f631706e9c10e8";
    hash = "sha256-H9HwNkPh3UoNHDoCqqGHEvzeRAYNAuHuabZYIWrOf5E=";
    finalImageTag = "12.0.14";
    os = "linux";
    arch = "amd64";
  };

  accountHost = "${lib.head (lib.splitString "/" net.subnet)}/255.255.255.0"; # the /24 form of the MariaDB account host (mariadb.nix)
  hostname = "filesync.nnik.dev";
  port = 25577; # the live port, kept (Caddy -> the container's nginx)
  redisPort = 6379;
  stateDir = "/state/seafile";
  network = "seafile";
  secretMount = "/secrets/seahub_secret_key"; # must match SECRET_FILE in prepare-state.py
  envFile = config.sops.templates."seafile.env".path;
  podmanBin = lib.getExe config.virtualisation.podman.package;

  environment = {
    SEAFILE_SERVER_HOSTNAME = hostname;
    SEAFILE_SERVER_PROTOCOL = "https";
    TIME_ZONE = "Europe/Berlin";
    SEAFILE_MYSQL_DB_HOST = net.gateway;
    SEAFILE_MYSQL_DB_PORT = "3306";
    SEAFILE_MYSQL_DB_USER = "seafile";
    SEAFILE_MYSQL_DB_CCNET_DB_NAME = "ccnet_db";
    SEAFILE_MYSQL_DB_SEAFILE_DB_NAME = "seafile_db";
    SEAFILE_MYSQL_DB_SEAHUB_DB_NAME = "seahub_db";
    CACHE_PROVIDER = "redis";
    REDIS_HOST = net.gateway;
    REDIS_PORT = toString redisPort;
    ENABLE_SEADOC = "false";
    ENABLE_NOTIFICATION_SERVER = "false";
  };

  prepareState = pkgs.writeShellApplication {
    name = "seafile-prepare-state";
    runtimeInputs = [pkgs.python3 pkgs.systemd pkgs.coreutils];
    text = ''
      if [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ]; then
        cat <<'EOF'
      seafile-prepare-state [--state-dir /state/seafile]

      Prepares the copied Seafile 12 State for the 13 image. Run as root, after
        1. rsync of /mnt/tbssd/filesync/seafile/{conf,seafile-data,seahub-data} to /state/seafile/
           (numeric ids kept, without seahub-data/thumbnail and logs/),
        2. optiplex-db-restore of the three Seafile databases,
      and before the normal deploy. Idempotent. See machines/optiplex/services/seafile/prepare-state.py.
      EOF
        exit 0
      fi
      if [ "$(id -u)" != 0 ]; then
        echo "run as root" >&2
        exit 1
      fi
      if systemctl is-active --quiet podman-seafile.service; then
        echo "podman-seafile.service is running: stop it first" >&2
        exit 1
      fi
      exec python3 ${./seafile/prepare-state.py} "$@"
    '';
  };

  # --- VM test: the synthetic Docker-era State -------------------------------------------------
  # What the Arch server had after years of use, in miniature: a 12.0.14 container (the image of the
  # live server, same env as the compose file, INIT_* test values) set up State and the databases
  # once; one library with one file and one public share link are created through the web API.
  # The container is then removed. The fixture runs in restoreMode, so MariaDB, the network and Redis
  # are up and podman-seafile.service does not exist.
  # The check scripts of all services share one Python namespace (vm.nix has `probe`, `reachable`, ...):
  # run each in a function so that its variables stay local.
  wrapPy = name: body: "def ${name}():\n" + lib.concatMapStringsSep "\n" (l: "    " + l) (lib.splitString "\n" body) + "\n${name}()\n";
  testAdmin = "admin@test.invalid";
  testAdminPassword = "test-admin-pw-1234";
  fixtureDir = "/root/seafile-fixture";
  curl = "${pkgs.curl}/bin/curl";
  jq = "${pkgs.jq}/bin/jq";
  fixture = ''
    install -d -m 0700 ${fixtureDir}
    ${podmanBin} load -i ${image12}
    ${podmanBin} network exists ${network}
    install -d -m 0755 ${stateDir}

    # Seafile 12 still wants a memcached called `memcached`.
    nft insert rule inet nixos-fw input-allow iifname "${net.interface}" tcp dport 11211 accept
    systemd-run --unit=fixture-memcached ${pkgs.memcached}/bin/memcached -l 0.0.0.0 -u nobody

    # The 12 image still reads DB_HOST/DB_USER/DB_PASSWORD/DB_ROOT_PASSWD (13 reads SEAFILE_MYSQL_DB_*).
    # It waits for MariaDB as `root`; that account exists for this fixture only (dropped below).
    dbpw="$(sed -n 's/^SEAFILE_MYSQL_DB_PASSWORD=//p' ${envFile})"
    ${pkgs.mariadb_114}/bin/mariadb --protocol=socket -uroot -e "CREATE USER 'root'@'${accountHost}' IDENTIFIED BY 'fixtureroot'; GRANT ALL ON *.* TO 'root'@'${accountHost}'"
    ${podmanBin} run -d --name seafile12 --network ${network} \
      -p 127.0.0.1:${toString port}:80 \
      --add-host memcached:${net.gateway} \
      -e DB_HOST=${net.gateway} -e DB_PORT=3306 -e DB_USER=seafile -e DB_PASSWORD="$dbpw" -e DB_ROOT_PASSWD=fixtureroot \
      -v ${stateDir}:/shared/seafile \
      --env-file ${envFile} \
      ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${k}=${v}") (environment // {USE_EXISTING_DB = "1";}))} \
      -e INIT_SEAFILE_ADMIN_EMAIL=${testAdmin} -e INIT_SEAFILE_ADMIN_PASSWORD=${testAdminPassword} \
      seafileltd/seafile-mc:12.0.14

    base=http://127.0.0.1:${toString port}
    ok=
    for _ in $(seq 60); do
      if [ "$(${curl} -fsS $base/api2/ping/ 2>/dev/null)" = '"pong"' ]; then ok=1; break; fi
      sleep 2
    done
    if [ -z "$ok" ]; then
      ${podmanBin} logs seafile12 | tail -50
      echo "seafile 12 did not come up"; exit 1
    fi

    token=$(${curl} -fsS -d username=${testAdmin} -d password=${testAdminPassword} $base/api2/auth-token/ | ${jq} -r .token)
    auth="Authorization: Token $token"
    repo=$(${curl} -fsS -H "$auth" -d name=synthetic-lib $base/api2/repos/ | ${jq} -r .repo_id)
    echo "synthetic State v12 file content" > ${fixtureDir}/hello.txt
    up=$(${curl} -fsS -H "$auth" "$base/api2/repos/$repo/upload-link/?p=/" | ${jq} -r .)
    up="$base''${up#https://${hostname}}"
    ${curl} -fsS -H "$auth" -F file=@${fixtureDir}/hello.txt -F parent_dir=/ -F replace=1 "$up"
    share=$(${curl} -fsS -H "$auth" -d repo_id=$repo -d path=/hello.txt $base/api/v2.1/share-links/ | ${jq} -r .token)
    test -n "$repo" -a -n "$share"
    printf 'REPO=%s\nSHARE=%s\n' "$repo" "$share" > ${fixtureDir}/ids

    ${podmanBin} stop -t 60 seafile12
    ${podmanBin} rm seafile12
    ${podmanBin} rmi seafileltd/seafile-mc:12.0.14
    ${pkgs.mariadb_114}/bin/mariadb --protocol=socket -uroot -e "DROP USER 'root'@'${accountHost}'"
    systemctl stop fixture-memcached.service
    test "$(cat ${stateDir}/seafile-data/current_version)" = 12.0.14
  '';
in {
  config = lib.mkMerge [
    {
      # --- podman on the host: rootful, no Docker daemon, nftables like the NixOS firewall ----------
      virtualisation.podman = {
        enable = true;
        dockerCompat = false;
      };
      virtualisation.oci-containers.backend = "podman";
      virtualisation.containers.containersConf.settings.network.firewall_driver = "nftables";

      # The network is a file in /etc/containers; the bridge itself appears with the container.
      # Subnet and interface name come from databases.nix (the MariaDB account and firewall rule use them).
      systemd.services.podman-network-seafile = {
        description = "Podman network for the Seafile container";
        wantedBy = ["multi-user.target"];
        path = [config.virtualisation.podman.package];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if podman network exists ${network}; then
            have="$(podman network inspect ${network} --format '{{range .Subnets}}{{.Subnet}} {{.Gateway}}{{end}}')"
            [ "$have" = "${net.subnet} ${net.gateway}" ] && exit 0
            podman network rm ${network}
          fi
          podman network create --driver bridge --disable-dns \
            --subnet ${net.subnet} --gateway ${net.gateway} --interface-name ${net.interface} ${network}
        '';
      };

      # --- Redis: the cache (no State) --------------------------------------------------------------
      # All addresses (the bridge does not exist yet at boot), protected-mode off; the firewall opens
      # the port only on the container network's interface.
      services.redis.servers.seafile = {
        enable = true;
        bind = null;
        port = redisPort;
        save = [];
        settings.protected-mode = "no";
      };
      networking.firewall.interfaces.${net.interface}.allowedTCPPorts = [redisPort]; # 3306: mariadb.nix

      # --- secrets ----------------------------------------------------------------------------------
      sops.secrets = let
        file = cfg.secretsDir + "/seafile.yaml";
      in {
        seafile_db_password = {
          sopsFile = file;
          key = "db_password";
        };
        seafile_jwt_private_key = {
          sopsFile = file;
          key = "jwt_private_key";
        };
        seafile_seahub_secret_key = {
          sopsFile = file;
          key = "seahub_secret_key";
          restartUnits = lib.optional (!cfg.restoreMode) "podman-seafile.service";
        };
      };
      sops.templates."seafile.env" = {
        restartUnits = lib.optional (!cfg.restoreMode) "podman-seafile.service";
        content = ''
          SEAFILE_MYSQL_DB_PASSWORD=${config.sops.placeholder.seafile_db_password}
          JWT_PRIVATE_KEY=${config.sops.placeholder.seafile_jwt_private_key}
        '';
      };

      assertions = [
        {
          assertion = lib.hasSuffix "/24" net.subnet;
          message = "seafile.nix assumes a /24 for optiplex.databases.seafileNetwork.subnet (the VM test builds the MariaDB account host from it)";
        }
      ];

      environment.systemPackages = [prepareState];
      optiplex.stateUnits = ["podman-seafile"];

      # --- the public vhost ---------------------------------------------------------------------------
      # useACMEHost = "nnik.dev" comes from the base. No body limit, no timeouts: Seafile's own
      # max_upload_size applies, the container's nginx has its long timeouts for /seafhttp.
      services.caddy.virtualHosts.${hostname}.extraConfig = ''
        import security
        reverse_proxy 127.0.0.1:${toString port}
      '';
    }

    # --- the container (off in restoreMode) ------------------------------------------------------------
    (lib.mkIf (!cfg.restoreMode) {
      virtualisation.oci-containers.containers.seafile = {
        image = "seafileltd/seafile-mc:${version}";
        imageFile = image;
        inherit environment;
        environmentFiles = [envFile];
        networks = [network];
        ports = ["127.0.0.1:${toString port}:80"];
        volumes = [
          "${stateDir}:/shared/seafile"
          "${config.sops.secrets.seafile_seahub_secret_key.path}:${secretMount}:ro"
        ];
      };

      systemd.services.podman-seafile = rec {
        requires = ["mysql.service" "mariadb-seafile-setup.service" "redis-seafile.service" "podman-network-seafile.service"];
        after = requires;
        preStart = lib.mkBefore ''
          if [ ! -e ${stateDir}/.optiplex-prepared ]; then
            echo "${stateDir} has not been prepared: copy the State and run seafile-prepare-state first" >&2
            exit 1
          fi
          # seafile.yaml was created with a placeholder for seahub_secret_key: never sign sessions with it
          if grep -q PLACEHOLDER ${config.sops.secrets.seafile_seahub_secret_key.path}; then
            echo "seahub_secret_key in secrets/optiplex/seafile.yaml is still the placeholder: carry the live SECRET_KEY (see the Answer of ticket 34)" >&2
            exit 1
          fi
        '';
      };
    })

    # --- VM test --------------------------------------------------------------------------------------
    # (the root disk for the two 1.7 GB images is sized in tests/optiplex/overlay-hermetic.nix)
    {
      optiplex.vmTest.fixtures.seafile.script = fixture;

      optiplex.vmTest.checks.seafile-restore = {
        phase = "restore";
        script = wrapPy "sf_restore" ''
          # restoreMode: no container unit, but the database it needs is up and the 12 State is there
          optiplex.fail("systemctl cat podman-seafile.service")
          optiplex.succeed("systemctl is-active mysql.service mariadb-seafile-setup.service redis-seafile.service podman-network-seafile.service")
          optiplex.succeed("test \"$(podman ps -a --format '{{.Names}}')\" = \"\"")
          optiplex.succeed("test \"$(cat ${stateDir}/seafile-data/current_version)\" = 12.0.14")
          optiplex.succeed("test \"$(stat -c %u:%g ${stateDir}/seafile-data)\" = 0:0")
          # preconditions of the conversion: the Docker-era conf
          conf = "${stateDir}/conf"
          optiplex.succeed(f"grep -qi '^\\[database\\]' {conf}/seafile.conf")
          optiplex.succeed(f"grep -q '^SECRET_KEY' {conf}/seahub_settings.py")
          optiplex.succeed(f"grep -q '^DATABASES' {conf}/seahub_settings.py")
          optiplex.succeed(f"grep -q '^CACHES' {conf}/seahub_settings.py")
          oldkey = optiplex.succeed(f"grep '^SECRET_KEY' {conf}/seahub_settings.py").split('"')[1]
          assert len(oldkey) > 20, oldkey
          print(optiplex.succeed(f"ls -la {conf}; ls -la ${stateDir} ${stateDir}/seahub-data"))
          # the unit refuses to run before the preparation (checked after the switch, see seafile-prepared)
          optiplex.fail("test -e ${stateDir}/.optiplex-prepared")

          # the conversion, twice (idempotent)
          optiplex.succeed("seafile-prepare-state")
          h1 = optiplex.succeed(f"cd {conf} && find . -type f -exec sha256sum {{}} +").strip()
          out = optiplex.succeed("seafile-prepare-state")
          assert "nothing" in out, out
          assert optiplex.succeed(f"cd {conf} && find . -type f -exec sha256sum {{}} +").strip() == h1
          optiplex.succeed("test -e ${stateDir}/.optiplex-prepared")
          optiplex.fail(f"grep -qi '^\\[database\\]\\|^\\[memcached\\]' {conf}/seafile.conf")
          optiplex.fail(f"grep -q '^DATABASES\\|^CACHES\\|^SECRET_KEY *=' {conf}/seahub_settings.py")
          optiplex.succeed(f"grep -q 'SERVICE_URL' {conf}/seahub_settings.py")
          optiplex.succeed(f"grep -q '${secretMount}' {conf}/seahub_settings.py")
          # no secret value is left in State: neither the old SECRET_KEY nor the DB password
          optiplex.fail(f"grep -rF -e '{oldkey}' ${stateDir}/conf")
          dbpw = optiplex.succeed("cat ${config.sops.secrets.seafile_db_password.path}").strip()
          optiplex.fail(f"grep -rF -e '{dbpw}' ${stateDir}/conf")
          print(optiplex.succeed(f"cat {conf}/seahub_settings.py {conf}/seafile.conf"))
        '';
      };

      optiplex.vmTest.checks.seafile = {
        script = wrapPy "sf_main" ''
          ids = dict(l.split("=", 1) for l in optiplex.succeed("cat ${fixtureDir}/ids").split())
          repo, share = ids["REPO"], ids["SHARE"]

          # --- the unit: State required, started after the databases ---
          optiplex.succeed("systemctl show -p RequiresMountsFor podman-seafile.service | grep -q '/state'")
          optiplex.succeed("systemctl show -p After podman-seafile.service | grep -q 'mysql.service'")
          optiplex.succeed("systemctl show -p After podman-seafile.service | grep -q 'redis-seafile.service'")
          optiplex.wait_for_unit("podman-seafile.service")
          optiplex.wait_until_succeeds("test \"$(curl -fsS http://127.0.0.1:${toString port}/api2/ping/)\" = '\"pong\"'", timeout=600)
          assert optiplex.succeed("cat ${stateDir}/seafile-data/current_version").strip() == "${version}"
          print(optiplex.succeed("podman logs seafile 2>&1 | tail -60"))
          optiplex.succeed("systemctl is-active redis-seafile.service")
          optiplex.fail("systemctl cat docker.service")
          optiplex.fail("test -S /var/run/docker.sock")

          # --- the 12 -> 13 upgrade ran on the synthetic State ---
          sql = "mariadb --protocol=socket -uroot -N -B -e"
          print(optiplex.succeed(f"{sql} 'select table_name, table_rows from information_schema.tables where table_schema = \"seafile_db\" and table_rows > 0'"))
          optiplex.succeed(f"{sql} 'select count(*) from seafile_db.Branch' | grep -qx '[1-9]'")
          optiplex.succeed(f"{sql} 'show tables from seahub_db' | grep -q share_fileshare")
          optiplex.succeed("podman exec seafile python3 -c 'import os; assert os.environ[\"CACHE_PROVIDER\"] == \"redis\"'")
          # SECRET_KEY comes from the sops file, no literal value in State
          optiplex.fail("grep -rn '^SECRET_KEY *= *[\"\\']' ${stateDir}/conf")
          optiplex.succeed("test \"$(podman exec seafile python3 -c \"print(open('${secretMount}').read().strip())\")\" = \"$(cat ${config.sops.secrets.seafile_seahub_secret_key.path})\"")
          optiplex.succeed("podman exec seafile test -r ${secretMount}")
          optiplex.fail("podman exec seafile sh -c 'echo x > ${secretMount}'")

          # --- listeners: 25577 on loopback only; 3306/6379 only from the container network ---
          optiplex.succeed("podman exec seafile bash -c 'exec 3<>/dev/tcp/${net.gateway}/3306'")
          optiplex.succeed("podman exec seafile bash -c 'exec 3<>/dev/tcp/${net.gateway}/${toString redisPort}'")
          def probe(client, ip, p):
              return client.execute(f"timeout 4 bash -c 'exec 3<>/dev/tcp/{ip}/{p}'")[0] == 0
          for p in (${toString port}, 3306, ${toString redisPort}):
              assert not probe(lan, "192.168.178.20", p), f"lan reaches {p}"
              assert not probe(outside, "203.0.113.1", p), f"outside reaches {p}"
              assert not probe(lan, "fd65:c1a5:7d2b::20", p), f"lan reaches {p} over v6"
          assert probe(optiplex, "127.0.0.1", ${toString port})
          print(optiplex.succeed("nft list ruleset | grep -n 'podman-seafile\\|${toString port}' || true"))
          rules = optiplex.succeed("nft list chain inet nixos-fw input-allow")
          for line in rules.splitlines():
              if "3306" in line or "${toString redisPort}" in line:
                  assert "${net.interface}" in line, line

          # --- through Caddy, from the LAN client (pebble's root is random per start) ---
          caCert = "${pkgs.path + "/nixos/tests/common/acme/server/ca.cert.pem"}"
          lan.wait_until_succeeds(f"curl -sS --cacert {caCert} --resolve acme.test:15000:192.168.178.60 https://acme.test:15000/roots/0 -o /tmp/pebble-root.pem", timeout=60)
          curl = "curl -sS --cacert /tmp/pebble-root.pem --resolve ${hostname}:443:192.168.178.20 https://${hostname}"
          lan.wait_until_succeeds(f"{curl}/api2/ping/ -o /dev/null", timeout=120)
          head = lan.succeed(f"{curl}/api2/ping/ -D - -o /dev/null").lower()
          assert head.startswith("http/2 200") or head.startswith("http/1.1 200"), head
          assert "strict-transport-security: max-age=31536000" in head, head
          login = lan.succeed(f"{curl}/accounts/login/")
          assert "csrfmiddlewaretoken" in login and "Log In" in login, login[:500]

          # a login with the synthetic admin works, and the library is in its list
          tok = lan.succeed(f"{curl}/api2/auth-token/ -d username=${testAdmin} -d password=${testAdminPassword}")
          import json
          token = json.loads(tok)["token"]
          repos = json.loads(lan.succeed(f"{curl}/api2/repos/ -H 'Authorization: Token {token}'"))
          assert [r["id"] for r in repos] == [repo], repos
          assert repos[0]["name"] == "synthetic-lib"
          lan.fail(f"{curl}/api2/auth-token/ -d username=${testAdmin} -d password=wrong -f")

          # the public share link of the old State resolves, and the file downloads intact (seafhttp via the proxy)
          page = lan.succeed(f"{curl}/f/{share}/")
          assert "hello.txt" in page, page[:500]
          assert lan.succeed(f"{curl}/f/{share}/?dl=1 -L").strip() == "synthetic State v12 file content"
          # and so does a download with the account (block store carried over untouched)
          dl = lan.succeed(f"{curl}/api2/repos/{repo}/file/?p=/hello.txt -H 'Authorization: Token {token}'").strip().strip('"')
          assert lan.succeed(f"curl -sS --cacert /tmp/pebble-root.pem --resolve ${hostname}:443:192.168.178.20 {dl}").strip() == "synthetic State v12 file content"

          # upload and download of a new 20 MB file through Caddy (no body limit)
          up = json.loads(lan.succeed(f"{curl}/api2/repos/{repo}/upload-link/?p=/ -H 'Authorization: Token {token}'"))
          lan.succeed("head -c 20000000 /dev/urandom > /tmp/big.bin; sha256sum /tmp/big.bin | cut -d' ' -f1 > /tmp/big.sha")
          lan.succeed(f"curl -fsS --cacert /tmp/pebble-root.pem --resolve ${hostname}:443:192.168.178.20 -F file=@/tmp/big.bin -F parent_dir=/ '{up}'")
          dl = lan.succeed(f"{curl}/api2/repos/{repo}/file/?p=/big.bin -H 'Authorization: Token {token}'").strip().strip('"')
          lan.succeed(f"curl -fsS --cacert /tmp/pebble-root.pem --resolve ${hostname}:443:192.168.178.20 {dl} | sha256sum | cut -d' ' -f1 | diff - /tmp/big.sha")

          # Redis is the cache seahub uses (it holds keys by now)
          optiplex.succeed("test \"$(${pkgs.redis}/bin/redis-cli -h ${net.gateway} -p ${toString redisPort} dbsize | tr -dc 0-9)\" -gt 0")

          # --- no secret in the units' command lines or in State ---
          dbpw = optiplex.succeed("cat ${config.sops.secrets.seafile_db_password.path}").strip()
          optiplex.fail(f"systemctl cat podman-seafile.service | grep -F '{dbpw}'")
          optiplex.fail(f"grep -rF '{dbpw}' ${stateDir}/conf")
        '';
      };

      optiplex.vmTest.checks.seafile-prepared-guard = {
        # runs as the last normal-phase check (name order): without the marker the unit refuses
        script = wrapPy "sf_guard" ''
          optiplex.succeed("systemctl stop podman-seafile.service")
          optiplex.succeed("mv ${stateDir}/.optiplex-prepared /tmp/marker")
          optiplex.fail("systemctl start podman-seafile.service")
          optiplex.succeed("journalctl -u podman-seafile.service --no-pager | grep -q 'has not been prepared'")
          optiplex.succeed("mv /tmp/marker ${stateDir}/.optiplex-prepared")
          optiplex.succeed("systemctl reset-failed podman-seafile.service; systemctl start podman-seafile.service")
          optiplex.wait_until_succeeds("test \"$(curl -fsS http://127.0.0.1:${toString port}/api2/ping/)\" = '\"pong\"'", timeout=300)
        '';
      };
    }
  ];
}
