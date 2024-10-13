{pkgs, lib, config, ...}:
  let
    modButton = "Mod1";
  in {
  imports = [
    ./fuzzel.nix
    ./gammastep.nix
    ./mako.nix
    ./waybar.nix
  ];
  wayland.windowManager.sway = {
    enable = true;
    systemd.enable = true;
    config = rec {
      input = {
        "*" = {
          xkb_layout = "de";
          xkb_variant = "nodeadkeys";
        };
        "type:touchpad" = {
          dwt = "enabled";
          tap = "enabled";
          middle_emulation = "enabled";
          natural_scroll = "enabled";
        };
      };
      modifier = modButton;
      bars = [
      {
        command = "${pkgs.waybar}/bin/waybar ";
        position = "top";
      }];
      defaultWorkspace = "2";
      colors = {
        focused = {
          background = "#000000";
          border = "#000000";
          childBorder = "#000000";
          indicator = "#2e9ef4";
          text = "#ffffff";
        };
        focusedInactive = {
          background = "#000000";
          border = "#000000";
          childBorder = "#000000";
          indicator = "#2e9ef4";
          text = "#ffffff";
        };
        unfocused = {
          background = "#000000";
          border = "#000000";
          childBorder = "#000000";
          indicator = "#292d2e";
          text = "#8f8f8f";
        };
        urgent = {
          background = "#000000";
          border = "#af5f5f";
          childBorder = "#000000";
          indicator = "#900000";
          text = "#8f8f8f";
        };
      };
      output."*".bg =  "#000000 solid_color";

      floating.border = 0;
      fonts = {
        names = ["DejaVU Sans Mono"];
        size = 8.0;
      };
      menu = "${pkgs.fuzzel}/bin/fuzzel --show drun";
      terminal = "alacritty";
      window = {
        border = 0;
        hideEdgeBorders = "both";
      };
      workspaceAutoBackAndForth = true;
      workspaceOutputAssign = [
        {workspace = "1"; output = "DP-1";}
        {workspace = "2"; output = "DP-3";}
      ];
      startup = lib.mkOptionDefault [
        {command = "chromium"; }
        {command = "betterbird"; }
        {command = "gammastep"; }
        {command = "warpinator"; }
      ];
      keybindings = lib.mkOptionDefault {
        "${modButton}+Insert exec" =  ''${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp -d)" - | ${pkgs.wl-clipboard}/bin/wl-copy'';
        "${modButton}+F3" = "light -U 10";
        "${modButton}+F4" = "light -A 10";
      };
    };
  };
}
