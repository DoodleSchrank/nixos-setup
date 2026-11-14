# One generation of the battle-tracker profile, built by battle-tracker-deploy:
#
#   nix build --impure --no-link --print-out-paths --file farm.nix
#
# Everything comes in through the environment (hence --impure):
#   BT_SOURCE         flake URL of the app repo, without a ref (git+https://git.nnik.dev/AItopia/battle-tracker)
#   BT_REV            the commit to build
#   BT_SYNC_BASE_URL  compile-time sync URL of the web bundle
#   BT_BASH, BT_COREUTILS  store paths of the two tools the link farm needs
#
# The result is { web, server, rev }: web/ and server/ are the app's two packages, rev is a file with the
# commit. The profile (a Nix profile) switches both together, and the rev is how the next deploy knows what
# is live. A derivation instead of pkgs.linkFarm: the app flake's own nixpkgs is not needed for it, so any
# flake that exposes packages.<system>.{web,server} (the VM test brings a tiny fake) can be deployed.
let
  env = builtins.getEnv;
  system = builtins.currentSystem;
  rev = env "BT_REV";
  app = builtins.getFlake "${env "BT_SOURCE"}?ref=main&rev=${rev}";
  packages = app.packages.${system};
  web = packages.web.override {syncBaseUrl = env "BT_SYNC_BASE_URL";};
  bash = builtins.storePath (env "BT_BASH");
  coreutils = builtins.storePath (env "BT_COREUTILS");
in
  builtins.derivation {
    name = "battle-tracker";
    inherit system;
    builder = "${bash}/bin/bash";
    args = [
      "-c"
      ''
        set -e
        ${coreutils}/bin/mkdir $out
        ${coreutils}/bin/ln -s ${web} $out/web
        ${coreutils}/bin/ln -s ${packages.server} $out/server
        echo ${rev} > $out/rev
      ''
    ];
  }
