{config, ...}: {
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa = {
      enable = true;
      support32Bit = true;
    };
    pulse.enable = true;
    #jack.enable = true;
    extraConfig.pipewire."92-low-latency" = {
      "context.properties" = {
        "default.clock.rate" = 48000;
        "default.clock.quantum" = 32;
        "default.clock.min-quantum" = 32;
        "default.clock.max-quantum" = 1024;
      };
    };
  };

  # https://www.reddit.com/r/NixOS/comments/tiar2y/thunderbolt_usb_audio_interface_crackling/
  services.power-profiles-daemon.enable = false;
}
