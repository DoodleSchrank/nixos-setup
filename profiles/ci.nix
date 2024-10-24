{pkgs, ...}:
{
  imports = [
    modules/vim.nix
    modules/zsh.nix
  ];

  home.username = "yannik";
  home.stateVersion = "24.11";
  nixpkgs.config.allowUnfree = true;

  home.packages = with pkgs; [
    #nix
    nix-tree
    nix-output-monitor
    nix-diff
    age
    direnv

    #other ci tools
    tree
    linuxKernel.packages.linux_xanmod_stable.cpupower
    dig
  ];


  programs = {
    home-manager.enable = true;
    git = {
      enable = true;
      userName = "Yannik Könneker";
    };
    zsh.enable = true;
  };

}
