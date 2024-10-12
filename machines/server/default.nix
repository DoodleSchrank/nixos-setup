{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/ssh.nix
    ./services.nix
  ];

  users.users."yannik".openssh.authorizedKeys.keyFiles = [
    ../modules/configs/ssh/authorized_keys
  ];
  virtualisation.docker.enable = true;

  environment = {
    systemPackages = with pkgs; [
      docker-compose
    ];
  };

  users.users.yannik = {
    isNormalUser = true;
    extraGroups = ["wheel" "adbusers" "docker"];
  };
  home-manager.users.yannik = {pkgs, ...}: {
    programs.zsh.enable = true;
    imports = [];
  };
  services.jellyfin.openFirewall = true;
}
