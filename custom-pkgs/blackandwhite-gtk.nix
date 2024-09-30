{ lib, stdenv, fetchgit }:

stdenv.mkDerivation rec {
  pname = "BlakcAndWhite";
  version = "1.0";

  srcs = [
    (fetchgit {
      url = "https://www.opencode.net/infinity64/blackandwhite-gtk.git";
      hash = "";
      sparseCheckout = [
        "BlackAndWhite"
      ];
    })
  ];

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/themes
    cp -a BlackAndWhite* $out/share/themes
    rm $out/share/themes/*/{LICENSE,README.md}
    runHook postInstall
  '';

  meta = with lib; {
    description = "This is a simple GTK black and white theme for minimalists and people who are still rocking B/W monitors.";
    homepage = "https://www.opencode.net/infinity64/blackandwhite-gtk";
    license = licenses.gpl3Only;
    platforms = platforms.all;
    maintainers = [ maintainers.me ];
  };
}