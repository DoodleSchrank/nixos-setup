{config, pkgs, ...}: {
  dconf.enable = true;
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
    };
  };

  gtk = {
    enable = true;
    theme = {
      name = "BlackAndWhite";
      package = pkgs.custom-packages.blackandwhite-gtk;
    };
    iconTheme = {
      name = "rose-pine";
      package = pkgs.rose-pine-icon-theme;
    };
    font.name = "FiraCode";
  };

  # Wayland, X, etc. support for session vars
  # systemd.user.sessionVariables = config.home-manager.users.yannik.home.sessionVariables;


  qt = {
    enable = true;
    platformTheme.name = "adwaita";
    style.package = [pkgs.adwaita-qt];
    style.name = "adwaita-dark";
  };

  home.packages = with pkgs; [
    # https://github.com/nix-community/home-manager/issues/3113
    pkgs.dconf
  ];
}
