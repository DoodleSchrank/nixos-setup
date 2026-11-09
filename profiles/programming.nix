{pkgs, ...}:
{
  home.packages = with pkgs; [
    #programming
    jdk
    jetbrains.idea
    jetbrains.clion
    jetbrains.rider
    #jetbrains.rust-rover
    android-studio
    flutter
    android-tools
    sdkmanager

    mono
    dotnetCorePackages.sdk_9_0
    direnv
    (import ./python.nix {pkgs = pkgs;})
  ];
}
