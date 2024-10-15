{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  users.defaultUserShell = pkgs.zsh;
  security.sudo.wheelNeedsPassword = false;

  users.users.yannik = {
    isNormalUser = true;
    extraGroups = ["wheel" "adbusers" "video" "networkmanager"];
    openssh.authorizedKeys.keyFiles = [ modules/configs/ssh/authorized_keys];
  };
}
