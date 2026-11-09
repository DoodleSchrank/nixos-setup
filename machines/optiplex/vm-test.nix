# Plug-in seam for the VM test harness (tests/optiplex/, ticket "VM test harness").
#
# Inert outside tests: the options below only carry data. Nothing in the running
# system reads them. The test drivers (tests/optiplex/vm.nix and rehearsal) read
# `nodes.optiplex.optiplex.vmTest` / `config.optiplex.vmTest` and run what is there.
#
# A service file sets its checks and fixtures next to its own config, for example
# machines/optiplex/services/vaultwarden.nix:
#
#   optiplex.vmTest.checks.vaultwarden = {
#     tiers = ["hermetic" "rehearsal"];
#     script = ''
#       optiplex.wait_for_unit("vaultwarden.service")
#       optiplex.succeed("curl -fsS http://127.0.0.1:8222/alive")
#     '';
#   };
#   optiplex.vmTest.fixtures.vaultwarden.script = ''
#     install -d -o vaultwarden -g vaultwarden /state/vaultwarden
#     echo synthetic > /state/vaultwarden/marker
#   '';
#
# Python snippets see these names (test-driver machine objects, or in the rehearsal tier a
# small ssh shim with the same succeed/fail/execute/wait_* methods, see
# tests/optiplex/rehearsal-shim.py):
#   optiplex   the host under test
#   lan        a LAN client at 192.168.178.50 (hermetic only)
#   outside    an internet client at 203.0.113.10 / 2001:db8:2::10 (hermetic only)
# Run `nix build .#checks.x86_64-linux.optiplex-vm` (about 3 minutes); to run one test while writing
# it, build the interactive driver: `nix build .#checks.x86_64-linux.optiplex-vm.driverInteractive`.
{
  config,
  lib,
  ...
}: let
  tierType = lib.types.enum ["hermetic" "rehearsal"];
in {
  options.optiplex.vmTest = {
    checks = lib.mkOption {
      default = {};
      description = ''
        Test-script snippets (Python, test-driver API). Collected from the final node
        configuration, so a service file adds its own and appears in the right tier.
        Each runs inside a `subtest(<name>)`. Order within a phase is by name.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          script = lib.mkOption {
            type = lib.types.lines;
            description = ''
              Python. Uses `optiplex` (and in the hermetic tier `lan`, `outside`) like a
              NixOS test script: `optiplex.succeed(...)`, `.fail(...)`, `.wait_for_unit(...)`,
              `.wait_until_succeeds(...)`, `.execute(...)`. Keep to those methods to stay
              runnable in the rehearsal tier too.
            '';
          };
          tiers = lib.mkOption {
            type = lib.types.listOf tierType;
            default = ["hermetic"];
            description = ''
              Where the check runs. `hermetic`: the nixosTest `optiplex-vm` (synthetic State, test
              CA, no internet). `rehearsal`: the impure rehearsal VM (real State restored from
              Backup, staging ACME), run by `tests/optiplex/rehearsal.sh`.
            '';
          };
          phase = lib.mkOption {
            type = lib.types.enum ["restore" "normal"];
            default = "normal";
            description = ''
              `restore`: runs while the node is still in restoreMode (after the fixtures, before
              the switch to the normal configuration). `normal`: after the switch.
            '';
          };
        };
      });
    };

    fixtures = lib.mkOption {
      default = {};
      description = ''
        Shell snippets that seed synthetic State, run as root on the host (bash, `set -euo
        pipefail`) in the hermetic tier right after boot in restoreMode, before the switch to the
        normal configuration. They write under /state (the Data disk is mounted by then), create
        dirs with the owner the service expects, and may load a tiny dump into the DB servers (the
        servers run in restoreMode). Run in attribute-name order. The rehearsal tier restores real
        State from Backup instead and ignores fixtures.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options.script = lib.mkOption {
          type = lib.types.lines;
          description = "Shell. Must be idempotent enough to run once on a fresh Data disk.";
        };
      });
    };

    offlineUnits = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {"acme-order-renew-nnik.dev.service" = "needs the internet; the hermetic cert is the self-signed fallback";};
      description = ''
        Units that may be `failed` in the tests, name (with suffix) to reason. The hermetic and
        rehearsal drivers compare `systemctl --failed` against this list, so a unit only belongs
        here if it cannot work in a VM (no internet, no hardware). The reason is printed.
      '';
    };

    offlineTimers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["ddns-update" "restic-backups-offsite"];
      description = ''
        Timers (without `.timer`) that must not run in any VM: the DDNS updater would overwrite
        the real DNS records, restic would back synthetic State up into the real repository. Both
        VM overlays set `systemd.timers.<name>.enable = false` for each. Service files append their
        timers here; they stay on in the real system.
      '';
    };
  };

  config = {
    # Host-base checks through the seam. These are also the template for service tickets.
    optiplex.vmTest.checks.state-bind = {
      tiers = ["hermetic" "rehearsal"];
      phase = "restore"; # true in both modes, so it runs as early as possible
      script = ''
        # /state is a bind mount of /mnt/tbssd/state; /mnt/tbssd is the Data disk (real UUID).
        optiplex.succeed("findmnt -n /state && findmnt -n /mnt/tbssd")
        state_src = optiplex.succeed("findmnt -n -o SOURCE /state").strip()
        data_src = optiplex.succeed("findmnt -n -o SOURCE /mnt/tbssd").strip()
        assert state_src == data_src + "[/state]", (state_src, data_src)
        uuid = optiplex.succeed(f"blkid -s UUID -o value {data_src}").strip()
        assert uuid == "70ca9b25-a1cd-46fa-bcbd-66780935c999", uuid
        # writes land on the Data disk
        optiplex.succeed("t=$(mktemp -p /state); test -e /mnt/tbssd/state/$(basename $t); rm $t")
      '';
    };

    optiplex.vmTest.checks.smartd-enabled = {
      tiers = ["hermetic" "rehearsal"];
      phase = "restore";
      script = ''
        optiplex.succeed("systemctl is-enabled smartd.service")
      '';
    };
    # qemu has no /dev/nvme0 and no 870 EVO by-id link, so smartd exits there.
    optiplex.vmTest.offlineUnits = lib.mkIf config.services.smartd.enable {
      "smartd.service" = "monitors /dev/nvme0 and the 870 EVO, which no VM has";
    };
  };
}
