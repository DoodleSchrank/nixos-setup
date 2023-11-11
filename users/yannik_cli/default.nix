{
  pkgs,
  config,
  lib,
  stdenv,
  environment,
  specialArgs,
  ...
}: {
  home.username = "yannik";
  home.stateVersion = "23.05";

  nixpkgs.config.allowUnfree = true;
  home.packages = with pkgs; [
  ];
  programs = {
    home-manager.enable = true;
    git = {
      enable = true;
      userName = "Yannik Könneker";
      userEmail = "y.koenneker@web.de";
    };
    zsh.enable = true;
  };

  imports = [
    ../../programs/zsh.nix
    ../../programs/vim.nix
  ];
}
