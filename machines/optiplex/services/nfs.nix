# The one NFS export: /mnt/tbssd/trrnt, read-only, to the LAN (the Shield mounts it).
# `/movies` is gone with movie-symlinker. Not machines/modules/nfs.nix: that one opens its ports
# to everyone and exports a PC path.
#
# NFSv3 (what the Shield uses) needs rpcbind (111), mountd, statd and lockd, so those have fixed
# ports (4001/4002 as in the PC module, statd on 4003 instead of 4000, see below); v4 only needs 2049. All of them are LAN-only.
# `insecure`: Kodi's libnfs on Android connects from an unprivileged source port (as live today).
{
  config,
  lib,
  ...
}: let
  restore = config.optiplex.restoreMode;
  ports = [111 2049 4001 4002 4003];
in {
  config = lib.mkIf (!restore) {
    services.nfs.server = {
      enable = true;
      # not 4000 as on the PC: blocky's HTTP API listens on 127.0.0.1:4000 and rpc.statd's
      # wildcard bind then fails with EADDRINUSE
      statdPort = 4003;
      lockdPort = 4001;
      mountdPort = 4002;
      exports = ''
        /mnt/tbssd/trrnt 192.168.178.0/24(ro,all_squash,no_subtree_check,insecure)
      '';
    };

    # No export without the Data disk. nfs-server also goes into stateUnits purely so that the
    # no-disk test of the VM harness (which walks that list) covers it; it keeps no State there.
    systemd.services.nfs-server.unitConfig.RequiresMountsFor = ["/mnt/tbssd"];
    optiplex.stateUnits = ["nfs-server"];

    optiplex.firewall.lanOnly = {
      tcp = ports;
      udp = ports;
    };
  };
}
