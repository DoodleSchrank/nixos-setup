{pkgs}:
pkgs.python310.withPackages (p:
    with p; [
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
