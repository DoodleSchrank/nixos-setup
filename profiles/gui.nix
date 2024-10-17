{pkgs, ...}:
{
  imports = [
    modules/alacritty.nix
    modules/chromium.nix
    modules/darkmode.nix
    modules/sway
  ];
  home.packages = with pkgs; [
    #comm
    (pkgs.discord.override {
      withOpenASAR = true;
      withVencord = true;
    })
    element-desktop
    betterbird
    zoom-us
    telegram-desktop
    mattermost-desktop
    rustdesk-flutter

    #media
    feh
    okular
    vlc
    yt-dlp

    #other gui tools
    pavucontrol
    libreoffice
    android-file-transfer
    warpinator
    firefox
    udiskie
    #file browser
    nemo
  ];

  # doesnt recognize wayland
  services = {
    network-manager-applet.enable = true;
    udiskie = {
      enable = true;
      tray = "auto";
      automount = false;
      notify = false;
      settings = {
        program_options = {
          file_manager = "${pkgs.alacritty}/bin/alacritty -e ${pkgs.ranger}/bin/ranger";
        };
      };
    };
  };

  home.file.".icons/default".source = "${pkgs.numix-cursor-theme}/share/icons/Numix-Cursor-Light/";

  home.sessionVariables = {
    XDG_ACTIVATION_TOKEN = "1";
  };
}
