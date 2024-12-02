
{
  programs.ssh = {
    enable = true;
    matchBlocks = {
      desktop = {
        user = "yannik";
        port = 25560;
        hostname = "192.168.178.21";
      };
      optiplex = {
        user = "yannik";
        port = 25560;
        hostname = "192.168.178.20";
      };
      laptop = {
        user = "yannik";
        port = 25560;
        hostname = "192.168.178.20";
      };
      thinkpad = {
        user = "yannik";
        port = 25560;
        hostname = "192.168.178.20";
      };
      levante = {
        user = "k203175";
        hostname = "levante4.dkrz.de";
        forwardAgent = true;
        identityFile = "/home/yannik/.ssh/id_ed25519.pub";
        forwardX11 = true;
      };
    };
  };
}