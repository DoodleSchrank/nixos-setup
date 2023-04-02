{
  programs.zsh = {
    enable = true;
    enableAutosuggestions = true;
    enableSyntaxHighlighting = true;
    shellAliases = {
      la = "ls -lah";
      vim = "nvim";
      recompile = "sudo nixos-rebuild switch";
      conf = "cd /etc/nixos/";
      rm = "trash-cli put";
      mkdir = "mkdir -p";
      cd = "take";
    };
    oh-my-zsh = {
      enable = true;
      plugins = [ "sudo" "colorize" "colored-man-pages" "dirhistory" "extract" ];
      theme = "robbyrussell";
    };
  };
}