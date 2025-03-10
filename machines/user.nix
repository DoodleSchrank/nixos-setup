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
    extraGroups = ["wheel" "adbusers" "video" "networkmanager" "scanner" "lp"];

    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7gWRkUn443KqPdDSzKMgL4Y6PvRkGd+lFo55WHMvPXhYfgLUgPcN6/Mm+4VMvvPATCJ7j3Dbnbn5E35FJpClZAvbDwFxYlNoW4x5D4tjjQ5gNMZ9RWefuM7pOIEcoIK+2shnBZ+JmZ3UuR33dCBQELOSwFqOO8HHhWSfPexFTf2F90FX/DwbNUgZ2nFscxFQqFxNCzT4zpNHzaTBpFt6F3mHOLy8iYr2J2G8cFG6Xuzc9Dfo6Oyj3UZ85aFyDUUTakfW2d1S80wLojba/vj02WkK06ameNnYuKvWEi5t5kiD2OhVwaF6+/rwTEPos9Ww8GSrewB9FAmfangmapZpXkf2tGL4e67c2cSH2h3PnwHuCMlOdsvt++JDw1FLZmUi7LDJXLxn1tUeh93TnQcBj7sq6FXIcbjB5RNckENYtM/gN33+DYJtFK9c/h3KOLg4dutEZy5caAHiRNbdQqiLFQ/Z355KYUj6HMn7zQfyeviP0l82nXLvNMLgP5N5Xd2E= yannik@yannik-pc"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL0LdztYU0ADGCLHnbHtaN1Jz5Qpm8Nqpoyor3rSXKh5 yannik@yannik-laptop"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII34rl5qklVPASP/IRq4+JKp8OYW3y4qHVr26n62LOnu yannik@yannik-koenneker-thinkpad"
    ];
  };
}
