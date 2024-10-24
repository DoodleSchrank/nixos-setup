{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    ./custom-hw-conf.nix
    ../gui.nix
    ../ci.nix
    ../user.nix
  ];
  services.logrotate.checkConfig = false;
  environment.systemPackages = with pkgs; [
    fprintd
    doas
  ];
  services = {
    fwupd.enable = true;
    blueman.enable = true;
    fprintd.enable = true;
  };

  security.pam.services.swaylock = {
                           text = ''
                             auth sufficient pam_unix.so try_first_pass likeauth nullok
                             auth sufficient pam_fprintd.so
                             auth include system-login
                           '';
                         };
  security.pam.services.swaylock.fprintAuth = true;
  security.doas = {
    enable = true;
  };

  services.acpid = {
    enable = true;
    lidEventCommands =
    ''
      export PATH=$PATH:/run/current-system/sw/bin:/home/yannik/.nix-profile/bin
      export WAYLAND_DISPLAY=wayland-1
      export XDG_RUNTIME_DIR=/run/user/1000
      lid_state=$(cat /proc/acpi/button/lid/LID/state | awk '{print $NF}')
      if [ $lid_state = "closed" ]; then
        doas -u yannik swaylock --config /home/yannik/.config/swaylock/config &> /tmp/lid_event.log &
      fi
    '';
   };
}

