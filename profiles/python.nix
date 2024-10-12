{pkgs}:
pkgs.python3.withPackages (p:
    with p; [
      pip
      setuptools
    ])
