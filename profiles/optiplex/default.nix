# Minimal home-manager for the Optiplex: zsh + vim. Deploys come from the PC,
# never from the box itself.
{pkgs, lib, ...}: {
  imports = [
    ../modules/zsh.nix
    ../modules/vim.nix
  ];

  programs.zsh.shellAliases.rebuild = lib.mkForce "echo 'deploy from the PC: nixos-rebuild switch --flake .#optiplex --target-host optiplex'";

  # thefuck was removed from nixpkgs (needs python < 3.12); pay-respects replaces it,
  # Its zsh integration defines `f`; `fuck` keeps the muscle memory from the shared zsh module.
  programs.pay-respects.enable = true;
  programs.zsh.shellAliases.fuck = lib.mkForce "f";

  home.packages = with pkgs; [trash-cli direnv];
  home.stateVersion = "26.11";
}
