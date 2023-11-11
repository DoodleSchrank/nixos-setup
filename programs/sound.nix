{config, ...}: {
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa = {
      enable = true;
      support32Bit = true;
    };
    pulse.enable = true;
    jack.enable = true;
    #lowLatency = {
    #  enable = true;
    #  quantum = 64;
    #  rate = 48000;
    #};
    #security.rtkit.enable = true;
  };
}
