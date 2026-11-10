{pkgs, ...}: let
  callPackage = pkgs.callPackage;
in {
  nixpkgs.overlays = [(final: prev: {
    custom-packages = {
      blackandwhite-gtk = callPackage ./blackandwhite-gtk {};
      mautrix-telegram = callPackage ./mautrix-telegram {};
    };
  })];
}