{
  services.openssh = {
    enable = true;
    openFirewall = true;
    ports = [ 25560 ];
    startWhenNeeded = true;
    passwordAuthentication = false;
    kbdInteractiveAuthentication = false;
  };
  users.users."yannik".openssh.authorizedKeys.keyFiles = [
    ./configs/ssh/authorized_keys
  ];
}