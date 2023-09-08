{ config, pkgs, ... }:
{
  imports = [
    ../../programs/sound.nix
    ../../programs/ssh.nix
    ./services.nix
  ];

  users.users."yannik".openssh.authorizedKeys.keyFiles = [
    ../../programs/configs/ssh/authorized_keys
  ];

  environment = {
    systemPackages = with pkgs; [

    ];
  };


  users.users.yannik = {
    isNormalUser = true;
    extraGroups = ["wheel" "adbusers"];
  };
  home-manager.users.yannik = { pkgs, ... }: {
    programs.zsh.enable = true;
    imports = [../../users/yannik/user.nix];
  };
  services.jellyfin.openFirewall = true;
}
