{pkgs}:
pkgs.python312.withPackages (p:
    with p; [
      pip
      setuptools
      six
      pyparsing
      pillow
      packaging
      numpy
      kiwisolver
      fonttools
      cycler
      scipy
      python-dateutil
      contourpy
      matplotlib
      #conan
      ##setuptools
    ])
