{pkgs, lib, config, ...}:
  let
    modButton = "Mod1";
  in {
  imports = [
    ./fuzzel.nix
    ./gammastep.nix
    #./wlsunset.nix
    ./mako.nix
    ./swaylock.nix
    ./waybar.nix
  ];
  home.packages = with pkgs; [
    #multi monitor support
    wdisplays

    # screenshot
    grim
    slurp
    wl-clipboard

    # backlight
    light

    networkmanagerapplet
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
        "1386:21398:WACF2200:00_056A:5396_Stylus" = {
          map_to_output = "'California Institute of Technology 0x1413 Unknown'";
        };
      };
      modifier = modButton;
      bars = [
      {
        command = "${pkgs.waybar}/bin/waybar ";
        position = "top";
      }];
      defaultWorkspace = "workspace number 1";
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
      startup = lib.mkOptionDefault [
        {command = "chromium"; }
        {command = "thunderbird"; }
        {command = "warpinator"; }

        #https://discourse.nixos.org/t/open-links-from-flatpak-via-host-firefox/15465/11
        {command = "systemctl --user import-environment PATH"; }
        {command = "systemctl --user restart xdg-desktop-portal.service"; }



        # if services don't work
        #{command = "nm-applet"; }
        #{command = "gammastep"; }
        #{command = "udiskie --no-automount --no-notify --tray"; }
      ];
      keybindings = lib.mkOptionDefault {
        "${modButton}+Insert" =  ''exec ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp -d)" - | ${pkgs.wl-clipboard}/bin/wl-copy'';
        "${modButton}+F3" = "exec light -U 10";
        "${modButton}+F4" = "exec light -A 10";
      };
      modes = {
        drawing = {
          t = "exec gromit-mpx --toggle";
          c = "exec gromit-mpx --clear";
          v = "exec gromit-mpx --visibility";
          q = "exec gromit-mpx --quit";
          u = "exec gromit-mpx --undo";
          r = "exec gromit-mpx --redo";
          p = "mode 'default'";
        };
      };
    };
  };
  programs.chromium.commandLineArgs = [
                        "--enable-features=UseOzonePlatform"
                        "--ozone-platform=wayland" ];
}
