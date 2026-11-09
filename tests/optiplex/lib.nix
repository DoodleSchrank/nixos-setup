# Helpers shared by the hermetic test, the install test and the rehearsal.
{lib}: rec {
  indent = n: text: let
    pad = lib.concatStrings (lib.genList (_: " ") n);
  in
    lib.concatMapStringsSep "\n" (l:
      if l == ""
      then ""
      else pad + l) (lib.splitString "\n" (lib.removeSuffix "\n" text));

  # A subtest block at column 0 (use as ${...} on a line of its own in a ''-string).
  subtest = name: body: ''
    with subtest(${builtins.toJSON name}):
    ${indent 4 body}
  '';

  # Checks of one tier and phase from a node config (optiplex.vmTest.checks), as Python source.
  # Each runs in its own subtest, ordered by name.
  renderChecks = {
    tier,
    phase,
    config,
  }: let
    checks = lib.filterAttrs (_: c: lib.elem tier c.tiers && c.phase == phase) config.optiplex.vmTest.checks;
  in
    lib.concatMapStrings (name: subtest name checks.${name}.script + "\n") (lib.attrNames checks);

  # Fixtures as store scripts, in name order (the guest sees /nix/store).
  fixtureScripts = {
    pkgs,
    config,
  }:
    lib.mapAttrsToList (name: f: {
      inherit name;
      script = pkgs.writeShellScript "optiplex-fixture-${name}" ''
        set -euo pipefail
        ${f.script}
      '';
    })
    config.optiplex.vmTest.fixtures;

  renderFixtures = args:
    lib.concatMapStrings (f: subtest "fixture ${f.name}" ''optiplex.succeed("${f.script}")'' + "\n") (fixtureScripts args);

  # The comparison of `systemctl --failed` with optiplex.vmTest.offlineUnits, as Python source.
  # `machine` is the Python variable of the host.
  failedUnitsCheck = {
    config,
    machine ? "optiplex",
  }: ''
    offline = ${builtins.toJSON config.optiplex.vmTest.offlineUnits}
    failed = [l.split()[0] for l in ${machine}.succeed("systemctl --failed --no-legend --plain").splitlines() if l.strip()]
    for u in failed:
        if u in offline:
            print(f"allowed to fail: {u} ({offline[u]})")
    unexpected = [u for u in failed if u not in offline]
    assert not unexpected, f"failed units: {unexpected}"
  '';
}
