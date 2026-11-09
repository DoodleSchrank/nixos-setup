# Demo "Kept service" for the hermetic test: shows how a service ticket plugs into the harness.
# A real service file does exactly this next to its own config (see optiplex.vmTest in
# machines/optiplex/vm-test.nix):
#   - gate the service on !restoreMode,
#   - list it in optiplex.stateUnits (RequiresMountsFor=/state),
#   - add a fixture that seeds synthetic State, and checks for both phases.
{
  config,
  lib,
  pkgs,
  ...
}: {
  optiplex.stateUnits = ["demo-kept"];

  systemd.services.demo-kept = lib.mkIf (!config.optiplex.restoreMode) {
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStart = pkgs.writeShellScript "demo-kept" ''
        echo "demo-kept sees: $(cat /state/demo-kept/marker)"
        exec ${pkgs.coreutils}/bin/sleep infinity
      '';
    };
  };

  optiplex.vmTest.fixtures.demo-kept.script = ''
    install -d /state/demo-kept
    echo synthetic-state-1 > /state/demo-kept/marker
  '';

  optiplex.vmTest.checks.demo-kept-restore = {
    phase = "restore";
    script = ''
      # restoreMode: the Kept service is switched off, its State is there
      optiplex.fail("systemctl cat demo-kept.service")
      optiplex.succeed("grep -qx synthetic-state-1 /mnt/tbssd/state/demo-kept/marker")
    '';
  };

  optiplex.vmTest.checks.demo-kept = {
    script = ''
      # after the normal deploy: it runs against the seeded State
      optiplex.wait_for_unit("demo-kept.service")
      optiplex.wait_until_succeeds("journalctl -u demo-kept.service | grep -q 'demo-kept sees: synthetic-state-1'")
    '';
  };
}
