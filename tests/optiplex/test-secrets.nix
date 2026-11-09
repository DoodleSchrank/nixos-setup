# Test secrets and a test ssh key for yannik, shared by the hermetic test, the install test and the
# rehearsal dry run. Test-only; nothing here protects anything real.
{
  config,
  lib,
  pkgs,
  ...
}: let
  sshKeys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
in {
  # --- secrets and ssh --------------------------------------------------------------------
  optiplex.secretsDir = ../../secrets/test/optiplex;
  # sops-nix refuses a keyFile in the Nix store, so a (test-only, public) copy is placed in /run
  # before the secrets are set up.
  sops.age.keyFile = "/run/test-age-key.txt";
  system.activationScripts.testAgeKey = lib.stringAfter ["specialfs"] ''
    install -m 0400 ${../../secrets/test/age-key.txt} /run/test-age-key.txt
  '';
  # (sops-nix defines these two only when there are secrets of the respective kind)
  system.activationScripts.setupSecrets = lib.mkIf (lib.any (s: !s.neededForUsers) (lib.attrValues config.sops.secrets)) {
    deps = ["testAgeKey"];
  };
  system.activationScripts.setupSecretsForUsers = lib.mkIf (lib.any (s: s.neededForUsers) (lib.attrValues config.sops.secrets)) {
    deps = ["testAgeKey"];
  };
  sops.age.sshKeyPaths = lib.mkForce [];
  users.users.yannik.openssh.authorizedKeys.keys = [sshKeys.snakeOilPublicKey];
}
