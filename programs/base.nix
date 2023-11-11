{
  config,
  pkgs,
  lib,
  ...
}: {
  environment = {
    pathsToLink = ["/libexec"];
    systemPackages = with pkgs; [
      wget
      curl
      trash-cli
      zsh
      vimv
      ranger

      btop
      thefuck

      zsh-command-time
      zsh-autocomplete
      zsh-syntax-highlighting
      chroma
      #zsh-completions conflicting with trash-cli
      vimPlugins.vim-nix
    ];
  };
}
