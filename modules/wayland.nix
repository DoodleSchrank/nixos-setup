{pkgs, ...}: {
  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = {
        # https://discourse.nixos.org/t/issue-with-xdg-open-in-sway/38096
        command = "dbus-run-session ${pkgs.sway}/bin/sway";
        user = "yannik";
      };
      default_session = initial_session;
    };
  };
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
}
