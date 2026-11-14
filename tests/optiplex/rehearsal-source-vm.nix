# The runner script of the source VM (rehearsal-source.nix), built with the nixpkgs that flake.lock pins and
# without a flake output of its own:   nix build --impure -f tests/optiplex/rehearsal-source-vm.nix
let
  lock = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes;
  nixpkgs = builtins.fetchTree lock.nixpkgs.locked;
in
  (import (nixpkgs + "/nixos") {
    system = "x86_64-linux";
    configuration = ./rehearsal-source.nix;
  }).vm
