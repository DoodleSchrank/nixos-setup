{
  pkgs,
  config,
  lib,
  stdenv,
  environment,
  specialArgs,
  inputs,
  ...
}: {
  imports = [
    ../ci.nix
    ../gui.nix
    ../programming.nix
  ];

  home.packages = with pkgs; [
    #drawing
    krita
    gromit-mpx

    #displays
    kanshi
    wl-mirror

    #specked gaming
    lutris
    gamemode
    wineWowPackages.waylandFull
  ];

  # overrides of defaults
  programs.git.userEmail = "yannik.koenneker@ovgu.de";
  programs.zsh.shellAliases.rebuild = "sudo nixos-rebuild switch --flake '/home/yannik/nixos-setup#thinkpad' |& sudo nom";
  wayland.windowManager.sway.config = {
    startup = lib.mkOptionDefault [
      {command = "mattermost-desktop"; }
      {command = "kanshi"; always = true;}
    ];
    workspaceOutputAssign = lib.mkForce [
      {workspace = "1"; output = "eDP-1";}
    ];
    keybindings = lib.mkOptionDefault {
      "Mod1+P" = "mode 'drawing'";
    };
  };
  services = {
    kanshi = {
      enable = true;
      settings = [
        {
          profile.name = "undocked";
          profile.outputs = [ {
            criteria = "eDP-1";
          }];
          profile.exec = [
            "${pkgs.sway}/bin/swaymsg workspace 1, move workspace to eDP-1"
          ];
        }
        {
          profile.name = "work";
          profile.outputs = [{
              criteria = "eDP-1";
              position = "0,1440";
            } {
              criteria = "DP-10";
              position = "1235,0";
              mode = "2560x1440";
            } {
              criteria = "DP-9";
              position = "3795,0";
              mode = "2560x1440";
            }];
          profile.exec = [
            "${pkgs.sway}/bin/swaymsg workspace 1, move workspace to DP-10"
            "${pkgs.sway}/bin/swaymsg workspace 2, move workspace to DP-10"
            "${pkgs.sway}/bin/swaymsg workspace 3, move workspace to eDP-1"
            "${pkgs.sway}/bin/swaymsg workspace 4, move workspace to DP-9"
          ];
        }
        {
          profile.name = "mirror";
          profile.outputs = [{
              criteria = "eDP-1";
              position = "0,0";
            } {
              criteria = "HDMI-A-1";
              position = "2000,2000";
            }];
          profile.exec = [
            "${pkgs.sway}/bin/swaymsg workspace 10, ${pkgs.sway}/bin/swaymsg fullscreen, exec wl-mirror eDP-1"
          ];
        }
      ];
    };
    gromit-mpx = {
      enable = true;
    };
  };
}
