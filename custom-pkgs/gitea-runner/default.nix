# Gitea Runner 5.4.1 (https://gitea.com/gitea/runner), for the runner VMs (machines/optiplex/runner-vms/).
# nixpkgs' gitea-actions-runner is 3.1.0: an overrideAttrs with the newer source. The package layout is the
# same (the binary is renamed `runner` -> `gitea-runner` by nixpkgs' postInstall, the module expects exactly
# that name), `register --token-file` and `daemon --config` exist in both. v5.4.1 needs Go 1.27 (go.mod),
# nixpkgs' default `go` is 1.26.
{
  lib,
  fetchFromGitea,
  buildGoModule,
  go_1_27,
  gitea-actions-runner,
  testers,
}:
(gitea-actions-runner.override {
  buildGoModule = buildGoModule.override {go = go_1_27;};
}).overrideAttrs (finalAttrs: prev: {
  version = "5.4.1";
  src = fetchFromGitea {
    domain = "gitea.com";
    owner = "gitea";
    repo = "runner";
    rev = "v${finalAttrs.version}";
    hash = "sha256-nrrkvwkhEZVZJRbbmYF8biKuckAiu+zkTgfMIeLqFbc=";
  };
  vendorHash = "sha256-gYzgsj+3ZvRyN5G8ZY4VvXQYQidQrK7EZjMcuvrXnlk=";
  # (the update script and the nixos test of the nixpkgs package do not apply to this one)
  passthru = (removeAttrs prev.passthru ["tests" "updateScript"]) // {
    tests.version = testers.testVersion {
      package = finalAttrs.finalPackage;
      version = "v${finalAttrs.version}";
    };
  };
})
