{
  programs.zsh = {
    enable = true;
    enableAutosuggestions = true;
    enableSyntaxHighlighting = true;
    shellAliases = {
      la = "ls -lah";
      vim = "nvim";
      rebuild = "sudo nixos-rebuild switch --flake '/etc/nixos#heimrechner' |& sudo nom";
      conf = "cd /etc/nixos/";
      rm = "trash";
      mkdir = "mkdir -p";
      cd = "take"; # from zsh
      fuck = "thefuck";
    };
    oh-my-zsh = {
      enable = true;
      plugins = [ "sudo" "colorize" "colored-man-pages" "dirhistory" "extract" ];
      theme = "robbyrussell";
    };
  };
}
