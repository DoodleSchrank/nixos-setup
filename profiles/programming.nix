{pkgs, ...}:
{
  home.packages = with pkgs; [
    #programming
    jdk
    jetbrains.idea-ultimate
    jetbrains.clion
    direnv
    #(import ./python.nix {pkgs = pkgs;})
  ];
}
