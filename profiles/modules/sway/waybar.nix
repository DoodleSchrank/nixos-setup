{pkgs, lib, ...}:
{
  programs.waybar = {
    enable = true;
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
      #network.disconnected, #network.disabled {
        color: red;
      }
      * {
        font-family: FiraCode;
      }
    '';
    settings = {
      mainbar = {
        height = 10;
        layer = "top";
        position = "top";
        tray = { spacing = 10; };
        modules-left = [ "sway/workspaces" "sway/mode" ];
        modules-center = [ "sway/window" ];
        modules-right = lib.mkDefault [
          "network"
          "cpu"
          "memory"
          "battery"
          "clock"
          "tray"
        ];
        clock = {
          format = "{:%d-%m-%Y - %H:%M}";
        };
        cpu = {
          format = "CPU: {usage}%";
          tooltip = false;
        };
        memory = { format = "{used}GiB / {avail}GiB"; };
        network = {
          format = "{ipaddr}";
          format-disconnected = "Disconnected ⚠";
          format-wifi = "{essid} ({ipaddr} | {signalStrength}%) ";
        };
        battery = {
          format = "{capacity}% {icon}";
          format-alt = "{time} {icon}";
          format-charging = "{capacity}% ⚡";
          format-icons = [ "" "" "" "" "" ];
          format-plugged = "{capacity}% ";
          states = {
            critical = 15;
            warning = 30;
          };
        };
        "sway/mode" = { format = ''<span style="italic">{}</span>''; };
      };
    };
  };
}