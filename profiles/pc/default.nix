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

    #programming
    android-studio
    flutter
    android-tools
    sdkmanager

    #amd
    amdvlk
    vulkan-tools
    dxvk
  ];

  #xdg.mimeApps = {
  #  enable                              =  true;
  #  defaultApplications = {
  #      "default-web-browser"           = [ "chromium.desktop" ];
  #      "text/html"                     = [ "chromium.desktop" ];
  #      "x-scheme-handler/http"         = [ "chromium.desktop" ];
  #      "x-scheme-handler/https"        = [ "chromium.desktop" ];
  #      "x-scheme-handler/about"        = [ "chromium.desktop" ];
  #      "x-scheme-handler/unknown"      = [ "chromium.desktop" ];
  #  };
  #};

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
  wayland.windowManager.sway.config = {
    startup = lib.mkOptionDefault [
      {command = "element-desktop"; }
      {command = "discord"; }
      {command = "mattermost-desktop"; }
    ];

    workspaceOutputAssign = [
      {workspace = "1"; output = "DP-1";}
      {workspace = "2"; output = "DP-3";}
    ];

    output = {
      DP-1.pos = "0,0";
      DP-3.pos = "2560,0";
    };
  };

}
