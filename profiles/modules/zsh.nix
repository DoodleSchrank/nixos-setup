{lib, ...}:
{
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      la = "ls -lah";
      vim = "nvim";
      conf = "cd /etc/nixos/";
      rm = "trash";
      mkdir = "mkdir -p";
      cd = "take"; # from zsh
      fuck = "thefuck";
      rebuild = lib.mkDefault "sudo nixos-rebuild switch --flake '/home/yannik/nixos-setup#pc' |& sudo nom";
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
