{ lib, stdenv, fetchgit }:

stdenv.mkDerivation rec {
  pname = "BlackAndWhite";
  version = "1.0";

  srcs = [
    (fetchgit {
      url = "https://www.opencode.net/infinity64/blackandwhite-gtk.git";
      hash = "sha256-llwr/jE3Ze1Cq1EZtz5w5ebRbUHVpHbrK6R+IdPXrY4=";
    })
  ];

  sourceRoot = ".";

  installPhase = ''
    mkdir -p $out/share/themes
    cp -a blackandwhite-gtk/BlackAndWhite $out/share/themes
  '';

  meta = with lib; {
    description = "This is a simple GTK black and white theme for minimalists and people who are still rocking B/W monitors.";
    homepage = "https://www.opencode.net/infinity64/blackandwhite-gtk";
    license = licenses.gpl3Only;
    platforms = platforms.all;
    maintainers = [ maintainers.me ];
  };
}