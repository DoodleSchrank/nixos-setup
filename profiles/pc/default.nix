{
  pkgs,
  config,
  lib,
  stdenv,
  environment,
  specialArgs,
  inputs,
  options,
  ...
}: {
  imports = [
    ../ci.nix
    ../gui.nix
    ../gaming.nix
    ../programming.nix
  ];

  home.packages = with pkgs; [
    #drawing
    krita

    #amd
    amdvlk
    vulkan-tools
    dxvk
  ];

  /*xdg.mimeApps = {
    enable                              =  true;
    defaultApplications = {
        "default-web-browser"           = [ "firefox.desktop" ];
        "text/html"                     = [ "firefox.desktop" ];
        "x-scheme-handler/http"         = [ "firefox.desktop" ];
        "x-scheme-handler/https"        = [ "firefox.desktop" ];
        "x-scheme-handler/about"        = [ "firefox.desktop" ];
        "x-scheme-handler/unknown"      = [ "firefox.desktop" ];
    };
  };*/

  # overrides of defaults
  programs.git.userEmail = "y.koenneker@web.de";
  programs.zsh.shellAliases.rebuild = "sudo nixos-rebuild switch --flake '/home/yannik/nixos-setup#pc' |& sudo nom";
  programs.waybar.settings.mainbar.modules-right = lib.mkForce [
    "network"
    "cpu"
    "memory"
    "clock"
    "tray"
  ];
  wayland.windowManager.sway.config.startup = lib.mkOptionDefault [
    {command = "element-desktop"; }
    {command = "discord"; }
    {command = "mattermost-desktop"; }
  ];

}
