{
  services.nfs.server = {
    enable = true;
    # fixed rpc.statd port; for firewall
    lockdPort = 4001;
    mountdPort = 4002;
    statdPort = 4000;

    extraNfsdConfig = '''';
    exports = ''
      /home/yannik/stuff/storage/todo    192.168.178.0/24(insecure,rw,no_subtree_check,nohide)
    '';
    #hostName = "yannik-pc";
  };
  networking.firewall.allowedTCPPorts = [111 2049 4000 4001 4002 20048];
  networking.firewall.allowedUDPPorts = [111 2049 4000 4001 4002 20048];
}
