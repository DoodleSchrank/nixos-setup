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
    extraConfig.pipewire = {
      default.clock.allowed-rates = [ 44100 48000 96000 ];
      default.clock.quantum = 32;
      default.clock.min-quantum = 32;
      default.clock.max-quantum = 1024;
    };
  };
}
