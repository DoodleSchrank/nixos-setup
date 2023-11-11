{ pkgs }:

pkgs.stdenv.mkDerivation {
  name = "protonge";
  src = stdenv.fetchFromGithub {
    owner = "GloriousEggroll";
    repo = "proton-ge-custom";
    rev = "GE-Proton8-15";
    hash = "";
  };
}