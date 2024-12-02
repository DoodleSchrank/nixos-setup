{pkgs, ...}:
{
  home.packages = with pkgs; [
    #programming
    jdk
    jetbrains.idea-ultimate
    jetbrains.clion
    jetbrains.rider
    mono
    dotnetCorePackages.sdk_9_0
    direnv
    (import ./python.nix {pkgs = pkgs;})
  ];
}
