{
  programs.zsh = {
    enable = true;
    enableAutosuggestions = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      la = "ls -lah";
      vim = "nvim";
      conf = "cd /etc/nixos/";
      rm = "trash";
      mkdir = "mkdir -p";
      cd = "take"; # from zsh
      fuck = "thefuck";
    };
    oh-my-zsh = {
      enable = true;
      plugins = ["sudo" "colorize" "colored-man-pages" "dirhistory" "extract"];
      theme = "robbyrussell";
    };
    initExtra = ''
      eval "$(direnv hook zsh)"
    '';
  };
}
