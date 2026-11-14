# A tiny stand-in for the app flake (AItopia/battle-tracker), for the deploy VM test: the same
# packages.<system>.{web,server} shape (web is .override-able with syncBaseUrl), built in the Nix sandbox
# without any input. The test commits this file to a local git repo, with GEN and MODE filled in:
#   GEN   shows up in index.html, so a test can tell the generations apart
#   MODE  ok | unhealthy (the server answers /health with 503) | buildfail (the server does not build)
# The at-sign names are filled in by pkgs.replaceVars; the percent names by the test.
{
  outputs = {self}: let
    system = "x86_64-linux";
    bash = builtins.storePath "@bash@";
    coreutils = builtins.storePath "@coreutils@";
    serverScript = builtins.storePath "@serverScript@";
    mode = "%MODE%";
    build = name: script:
      derivation {
        inherit name system;
        builder = "${bash}/bin/bash";
        args = ["-c" script];
      };
    web = args:
      build "fake-web" ''
        export PATH=${coreutils}/bin
        mkdir -p $out
        echo '<html>fake web %GEN%</html>' > $out/index.html
        echo "var BT_SYNC_BASE_URL = '${args.syncBaseUrl or ""}'; // %GEN%" > $out/main.dart.js
      '';
  in {
    packages.${system} = {
      web = (web {}) // {override = web;};
      server = build "fake-server" ''
        export PATH=${coreutils}/bin
        ${
          if mode == "buildfail"
          then "echo this server does not build; exit 1"
          else ""
        }
        mkdir -p $out/bin
        cp ${serverScript} $out/bin/server
        chmod +x $out/bin/server
        echo ${mode} > $out/bin/mode
      '';
    };
  };
}
