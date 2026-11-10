{pkgs, ...}: let
  callPackage = pkgs.callPackage;
in {
  nixpkgs.overlays = [(final: prev: {
    custom-packages = {
      blackandwhite-gtk = callPackage ./blackandwhite-gtk {};
      gitea-runner = callPackage ./gitea-runner {};
      mautrix-telegram = callPackage ./mautrix-telegram {};
    };
  })];
}