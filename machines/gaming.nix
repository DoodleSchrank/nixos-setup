{pkgs, inputs, ...}:
{
  boot.kernel.sysctl = {
    "abi.vsyscall32" = 0;
  };
  environment = {
    pathsToLink = ["/libexec"];
    systemPackages = with pkgs; [
      inputs.umu.packages.${pkgs.system}.umu
    ];
  };
  programs = {
    steam = {
      enable = true;
      extraCompatPackages = [
        pkgs.proton-ge-bin
      ];
      gamescopeSession = {
        enable = true;
      };
    };
    zsh.enable = true;
    dconf.enable = true;
  };
}
