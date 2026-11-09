# Shared MariaDB for Seafile (the only SQL user besides PostgreSQL; elabFTW is retired).
#   - MariaDB 11.4 LTS, pinned (not the `mariadb` alias), data in /state/mariadb on the Data disk
#   - the three Seafile databases are utf8mb3/utf8mb3_general_ci like the source, so tables that the
#     Seafile 13 schema upgrade creates later match the restored ones
#   - one TCP account, `seafile`, for the container (it cannot use socket auth): limited to the
#     container subnet, mysql_native_password, password from secrets/optiplex/seafile.yaml
#   - MariaDB listens on 0.0.0.0 (the podman bridge may not exist yet when it starts); port 3306 is
#     open in the firewall only on the container network's interface, never on the LAN.
# Everything is created by mariadb-seafile-setup.service on every boot, in restoreMode too. The
# Seafile ticket reads the same key (`db_password`) for the container environment.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex.databases;
  net = cfg.seafileNetwork;
  my = config.services.mysql;
  mariadb = "${my.package}/bin/mariadb";

  # "10.89.29.0/24" -> "10.89.29.0/255.255.255.0": the netmask form is the account's host part
  accountHost = let
    parts = lib.splitString "/" net.subnet;
    prefix = lib.toInt (lib.elemAt parts 1);
    octet = i: let
      bits = lib.min 8 (lib.max 0 (prefix - 8 * i));
    in
      toString (256 - builtins.elemAt [1 2 4 8 16 32 64 128 256] (8 - bits));
  in "${lib.elemAt parts 0}/${lib.concatMapStringsSep "." octet [0 1 2 3]}";

  passwordFile = config.sops.secrets.mariadb_seafile_password.path;
in {
  services.mysql = {
    enable = true;
    package = pkgs.mariadb_114;
    dataDir = "/state/mariadb";
    settings.mysqld = {
      bind-address = "0.0.0.0";
      skip-name-resolve = 1;
    };
  };

  users.users.mysql.uid = 84;
  users.groups.mysql.gid = 84;
  assertions = [
    {
      assertion = config.ids.uids.mysql == 84 && config.ids.gids.mysql == 84;
      message = "nixpkgs changed the mysql uid/gid; /state/mariadb is owned by 84:84";
    }
  ];

  # The module creates its data dir with tmpfiles; this unit also does it once the Data disk is there.
  systemd.services.mariadb-state-dir = {
    description = "MariaDB data directory in /state";
    requiredBy = ["mysql.service"];
    before = ["mysql.service"];
    unitConfig.RequiresMountsFor = ["/state"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "install -d -o mysql -g mysql -m 0755 ${my.dataDir}";
  };

  sops.secrets.mariadb_seafile_password = {
    sopsFile = config.optiplex.secretsDir + "/seafile.yaml";
    key = "db_password";
    owner = "root";
    mode = "0400";
  };

  systemd.services.mariadb-seafile-setup = {
    description = "Seafile databases and TCP account in MariaDB";
    wantedBy = ["multi-user.target"];
    requires = ["mysql.service"];
    after = ["mysql.service"];
    partOf = ["mysql.service"]; # a mysql restart runs it again
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      password="$(cat ${lib.escapeShellArg passwordFile})"
      case "$password" in
        "" | *[!A-Za-z0-9]*) echo "the Seafile DB password must be non-empty and alphanumeric (no quoting needed)" >&2; exit 1 ;;
      esac
      account="'seafile'@'${accountHost}'"
      {
        ${lib.concatMapStrings (db: ''
          echo "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci;"
        '') cfg.mariadb}
        echo "CREATE USER IF NOT EXISTS $account IDENTIFIED VIA mysql_native_password USING PASSWORD('$password');"
        # every boot: a rotated sops password takes effect
        echo "ALTER USER $account IDENTIFIED VIA mysql_native_password USING PASSWORD('$password');"
        ${lib.concatMapStrings (db: ''
          echo "GRANT ALL ON \`${db}\`.* TO $account;"
        '') cfg.mariadb}
        echo "FLUSH PRIVILEGES;"
      } | ${mariadb} --protocol=socket -uroot
    '';
  };

  networking.firewall.interfaces.${net.interface}.allowedTCPPorts = [3306];

  optiplex.stateUnits = ["mysql" "mariadb-state-dir" "mariadb-seafile-setup"];

  optiplex.vmTest.checks.databases-mariadb = {
    phase = "restore";
    tiers = ["hermetic" "rehearsal"];
    script = ''
      optiplex.wait_for_unit("mariadb-seafile-setup.service")
      sql = "mariadb --protocol=socket -uroot -N -B -e"
      v = optiplex.succeed(f"{sql} 'select version()'").strip()
      assert v.startswith("11.4."), v
      for db in ${builtins.toJSON cfg.mariadb}:
          cs = optiplex.succeed(f"{sql} \"select default_character_set_name, default_collation_name from information_schema.schemata where schema_name = '{db}'\"").split()
          assert cs == ["utf8mb3", "utf8mb3_general_ci"], (db, cs)
          assert optiplex.succeed(f"{sql} \"select count(*) from mysql.db where user = 'seafile' and db = '{db}'\"").strip() == "1", db
      acct = optiplex.succeed(f"{sql} \"select host, plugin from mysql.user where user = 'seafile'\"").split()
      assert acct == ["${accountHost}", "mysql_native_password"], acct
      optiplex.succeed("test -d /state/mariadb/mysql && test -d /mnt/tbssd/state/mariadb/mysql")
    '';
  };
}
