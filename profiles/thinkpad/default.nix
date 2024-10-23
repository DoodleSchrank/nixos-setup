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
  ];

  # overrides of defaults
  programs.git.userEmail = "yannik.koenneker@ovgu.de";
  programs.zsh.shellAliases.rebuild = "sudo nixos-rebuild switch --flake '/home/yannik/nixos-setup#thinkpad' |& sudo nom";
  wayland.windowManager.sway.config = {
    startup = lib.mkOptionDefault [
      {command = "mattermost-desktop"; }
      {command = "kanshi"; always = true;}
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
              position = "0,1200";
            } {
              criteria = "DP-7";
              position = "1920,0";
              transform = "270";
            } {
              criteria = "DP-8";
              position = "0,0";
            }];
          profile.exec = [
            "${pkgs.sway}/bin/swaymsg workspace 1, move workspace to DP-8"
            "${pkgs.sway}/bin/swaymsg workspace 2, move workspace to DP-8"
            "${pkgs.sway}/bin/swaymsg workspace 3, move workspace to eDP-1"
          ];
        }
        {
          profile.name = "mirror";
          profile.outputs = [{
              criteria = "eDP-1";
              position = "0,0";
            } {
              criteria = "HDMI-1";
              position = "2000,2000";
            }];
          profile.exec = [
            "${pkgs.sway}/bin/swaymsg workspace 0, exec wl-mirror eDP-1"
          ];
        }
      ];
    };
    gromit-mpx = {
      enable = true;
    };
  };
}
