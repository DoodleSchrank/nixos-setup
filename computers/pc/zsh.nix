{
  programs.zsh = {
    shellAliases = {
      rebuild = "sudo nixos-rebuild switch --flake '/etc/nixos#heimrechner' |& sudo nom";
    };
  };
}
