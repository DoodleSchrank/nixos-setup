{pkgs, ...}: {

  home = {
    packages = with pkgs; [
      rofi
      i3status
      i3status-rust
    ];
    #file.".config/i3/config".source = ./configs/i3.conf;
    #file.".config/i3status/config".source = ./configs/i3status.conf;
  };

  xsession.windowManager.i3 = {
    enable = true;
    config = {
      modifier = "Mod1";
      bars = [
      {
        command = "${pkgs.i3status}/bin/i3status ";
        position = "top";
        colors = {
          background = "#000000";
          statusline = "#ffffff";
          separator = "#ffffff";
          focusedWorkspace = {
            background = "#000000";
            border = "#000000";
            text = "#ffffff";
          };
          activeWorkspace = {
            background = "#000000";
            border = "#000000";
            text = "#888888";
          };
          inactiveWorkspace = {
            background = "#000000";
            border = "#000000";
            text = "#888888";
          };
          urgentWorkspace = {
            background = "#af5f5f";
            border = "#af5f5f";
            text = "#ffffff";
          };
        };
      }];
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
      floating.border = 0;
      fonts = {
        names = ["DejaVU Sans Mono"];
        size = 8.0;
      };
      menu = "${pkgs.rofi}/bin/rofi -show drun";
      terminal = "alacritty";
      window = {
        border = 0;
        hideEdgeBorders = "both";
      };
      workspaceAutoBackAndForth = true;
      startup = [
        {command = "chromium"; always = true; notification = false; }
        {command = "element-desktop"; always = true; notification = false; }
        {command = "discord"; always = true; notification = false; }
        {command = "thunderbird"; always = true; notification = false; }
      ];
    };
  };
  programs.i3status-rust = {
    enable = false;
    bars = {
      top = {
        blocks = [
         {
           block = "time";
           interval = 60;
           format = "%a %d/%m %k:%M %p";
         }
       ];
      };
    };
  };
  programs.i3status = {
    enable = true;
    modules = {
      "ipv6".position = 1;
      "ethernet _first_".position = 2;
      "disk /" = {
        position = 3;
        settings.format = "/ %avail";
      };
      "cpu_usage".settings.format = "%usage";
      "cpu_usage".position = 4;

      "memory" = {
        position = 5;
        settings.format = "%used";
        settings.threshold_degraded = "1G";
        settings.format_degraded = "MEMORY < %available";
      };
      "tztime local" = {
          position = 6;
        settings.format = "%Y-%m-%d %H:%M:%S";
      };
    };
  };
}
