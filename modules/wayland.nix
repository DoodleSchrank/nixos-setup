{pkgs, ...}: {
  programs.sway = {
    enable = false;
  };
  services.greetd = {
    enable = false;
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
