{pkgs, ...}:
{
  imports = [
    modules/wayland.nix
  ];

  environment = {
    pathsToLink = ["/libexec"];
    systemPackages = with pkgs; [
      # required to get urls to open in browser
      # https://discourse.nixos.org/t/clicked-links-in-desktop-apps-not-opening-browers/29114/11
      xdg-utils
    ];
  };
  xdg.portal = {
    enable = true;
    extraPortals = [pkgs.xdg-desktop-portal-gtk pkgs.xdg-desktop-portal-wlr];
    wlr.enable = true;
    xdgOpenUsePortal = true;
    config = {
      common.default = ["gtk" "wlr"];
    };
  };
}
