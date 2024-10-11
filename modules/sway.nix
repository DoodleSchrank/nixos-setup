{config, pkgs, lib, ...}:
  let
    modButton = "Mod1";
  in {
  home = {
    packages = with pkgs; [
      wofi
      sway
      waybar
    ];
  };

  wayland.windowManager.sway = {
    enable = true;
    systemd.enable = true;
    config = rec {
      input = {
        "*" = {
          xkb_layout = "de";
          xkb_variant = "nodeadkeys";
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
      startup = [
        {command = "chromium"; }
        {command = "element-desktop"; }
        {command = "discord"; }
        {command = "betterbird"; }
        #{command = "localsend_app"; }
        {command = "warpinator"; }
      ];
      keybindings = lib.mkOptionDefault {
        "${modButton}+Insert exec" =  ''${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp -d)" - | ${pkgs.wl-clipboard}/bin/wl-copy'';
      };
    };
  };
  programs.waybar = {
    enable = true;
    #systemd.enable = true;
    style = ''
      ${builtins.readFile "${pkgs.waybar}/etc/xdg/waybar/style.css"}
      window#waybar {
        background: transparent;
        border-bottom: none;
      }
      window#waybar, #workspaces, #network, #cpu, #memory, #clock, #tray, label:focus {
        border: none;
        background: #000000;
        color: white;
      }
      #workspaces button.focused {
        background: #2e2e2e;
      }
    '';
    settings = [{
      height = 10;
      layer = "top";
      position = "top";
      tray = { spacing = 10; };
      modules-left = [ "sway/workspaces" "sway/mode" ];
      modules-center = [ "sway/window" ];
      modules-right = [
        "network"
        "cpu"
        "memory"
        "tray"
        "clock"
      ];
      clock = {
        format = "{:%H:%M - %d-%m-%Y}";
      };
      cpu = {
        format = "{usage}% ";
        tooltip = false;
      };
      memory = { format = "{}% "; };
      network = {
        format = "{ifname}: {ipaddr}/{cidr}";
        format-disconnected = "Disconnected ⚠";
      };
      "sway/mode" = { format = ''<span style="italic">{}</span>''; };
    }];
  };
  #program launcher
  programs.fuzzel = {
    enable = true;
    settings = {
      colors.foreground = "ffffffff";
      colors.background = "000000AA";
    };
  };
  #notifications
  services.mako = {
    enable = true;
    anchor = "top-right";
    backgroundColor = "#00000088";
    defaultTimeout = 2500;
  };
  #nightlight
  services.gammastep = {
    enable = true;
    dawnTime = "7:00-8:00";
    duskTime = "22:30-23:00";
    latitude = 54.5;
    longitude = 9.9;
    temperature.day = 6500;
    temperature.night = 3000;
    tray = true;
  };
}
