{pkgs, ...}: {
  programs.sway = {
    enable = true;
  };
  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = {
        command = "${pkgs.sway}/bin/sway";
        user = "yannik";
      };
      default_session = initial_session;
    };
  };
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
}
