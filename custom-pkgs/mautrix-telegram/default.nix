# mautrix-telegram, the Go (bridgev2) rewrite, built with goolm (pure-Go Olm; no libolm).
#
# nixpkgs still ships the Python 0.15.3 bridge (watch NixOS/nixpkgs#510662 and #581772). The live
# Arch bridge is the Go one ("v26.10+dev", built 2026-11-03 from main), whose database is on the
# bridgev2 schema (telegram_version 10). Tag v0.2610.0 has the same schema version (10) as main, but
# the live build is from main, so this pins a main commit that is newer than that build. Drop this
# package and machines/optiplex/modules/mautrix-telegram.nix once nixpkgs ships a Go module.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "mautrix-telegram";
  version = "26.10-unstable-2026-11-09";
  rev = "a36e68b399a3b014c1365f5c38ab05e8749080c0";

  src = fetchFromGitHub {
    owner = "mautrix";
    repo = "telegram";
    inherit rev;
    hash = "sha256-eO/ieiCF5wtIW8mZN5MiryFtaKVrfKZHfSKIlnSuP6Y=";
  };

  vendorHash = "sha256-cCm6QcGP3gQIUWWaT8PhE3i07mjEdVsvjbMz0+zicEA=";

  # goolm = pure-Go Olm (the same choice as the WhatsApp bridge); no `olm` input, so nothing needs
  # permittedInsecurePackages.
  tags = ["goolm"];

  subPackages = ["cmd/mautrix-telegram"];

  ldflags = [
    "-s"
    "-w"
    "-X main.Commit=${rev}"
    "-X main.BuildTime=1970-01-01T00:00:00Z"
  ];

  # go.mod asks for toolchain go1.27.2; the go line only needs 1.26. Never download a toolchain.
  env.GOTOOLCHAIN = "local";

  doCheck = false;

  meta = {
    homepage = "https://github.com/mautrix/telegram";
    description = "Matrix-Telegram puppeting bridge (Go, bridgev2)";
    license = lib.licenses.agpl3Plus;
    mainProgram = "mautrix-telegram";
  };
}
