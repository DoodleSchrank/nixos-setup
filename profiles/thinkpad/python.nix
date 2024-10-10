{pkgs}:
pkgs.python312.withPackages (p:
    with p; [
      pip
      setuptools
    ])
