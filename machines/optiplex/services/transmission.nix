# Transmission: native daemon on the home IP (no VPN), peer port 51413 public on v4 and v6,
# RPC on loopback only behind the LAN-only Caddy vhost http://transmission.opti.plex.
#
# Paths
#   /trrnt             bind mount of /mnt/tbssd/trrnt (replaces Arch's symlink, which does not
#                      survive the module's RootDirectory sandbox). download-dir and watch-dir
#                      live there, so the 96 resume files (destination /trrnt) stay valid.
#   /state/transmission  `home`: <home>/.config/transmission-daemon holds the resume files and
#                      the copied .torrent files. settings.json in there is rewritten from
#                      `settings` below on every start, so edits in the web UI do not survive.
#
# Ownership: the NixOS default uid/gid 70 (pinned below, also in restoreMode: the Cutover chown
# and `chown transmission:` need the user while the daemon is off). yannik joins the group
# through users.groups.transmission.members (his extraGroups is mkForce'd in default.nix).
# umask 002, so downloads are group-writable.
#
# The State copy and the chown/rollback commands are in ./transmission/ (restore.sh,
# diff-settings.sh); the VM checks that exercise them are in ./transmission-vmtest.nix.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  restore = cfg.restoreMode;
  rpcPort = 25559;
  host = "transmission.opti.plex";
  trrntMount = {
    device = "/mnt/tbssd/trrnt";
    fsType = "none";
    options = ["bind" "nofail"];
    depends = ["/mnt/tbssd"];
  };
in {
  imports = [./transmission-vmtest.nix];

  config = lib.mkMerge [
    {
      # --- identity: present in restoreMode too (switch the service off, never the users) -----
      users.groups.transmission = {
        gid = 70;
        members = ["yannik"];
      };
      users.users.transmission = {
        uid = 70;
        group = "transmission";
        isSystemUser = true;
        home = "/state/transmission";
        description = "Transmission BitTorrent user";
      };

      # --- /trrnt ----------------------------------------------------------------------------
      fileSystems."/trrnt" = trrntMount;
    }

    # qemu-vm.nix replaces every fileSystems entry by virtualisation.fileSystems, which only
    # exists in the VM tests (storage.nix hands them optiplex.dataFileSystems for /state and the
    # Data disk, which does not know /trrnt).
    (lib.optionalAttrs (options ? virtualisation && options.virtualisation ? fileSystems) {
      virtualisation.fileSystems."/trrnt" = trrntMount;
    })

    (lib.mkIf (!restore) {
      services.transmission = {
        enable = true;
        package = pkgs.transmission_4; # the resume files are 4.x format
        home = "/state/transmission";
        openPeerPorts = true; # 51413 tcp+udp, v4 and v6
        openRPCPort = false; # loopback only, reached through Caddy
        # null: the module must not chmod the existing /trrnt (775) or yannik's watch/.
        downloadDirPermissions = null;

        settings = {
          # paths
          download-dir = "/trrnt";
          incomplete-dir-enabled = false; # the module defaults to on
          watch-dir = "/trrnt/watch";
          watch-dir-enabled = true;
          rename-partial-files = true;

          # peers and ports: public peer port, no UPnP/NAT-PMP (static share on the router)
          peer-port = 51413;
          peer-port-random-on-start = false;
          port-forwarding-enabled = false;
          dht-enabled = false; # private trackers
          pex-enabled = false;
          lpd-enabled = false;
          utp-enabled = true;
          encryption = 1; # prefer encrypted
          peer-limit-global = 2000;
          peer-limit-per-torrent = 500;
          upload-slots-per-torrent = 14;
          cache-size-mb = 4;
          preallocation = 1;

          # queue, no limits
          download-queue-enabled = true;
          download-queue-size = 5;
          queue-stalled-enabled = true;
          queue-stalled-minutes = 30;
          ratio-limit-enabled = false;
          speed-limit-down-enabled = false;
          speed-limit-up-enabled = false;

          # RPC: loopback, no auth. Caddy keeps the Host header, so the host whitelist matches.
          rpc-bind-address = "127.0.0.1";
          rpc-port = rpcPort;
          rpc-authentication-required = false;
          rpc-host-whitelist-enabled = true;
          rpc-host-whitelist = host;
          rpc-whitelist-enabled = true; # Caddy connects from loopback
          rpc-whitelist = "127.0.0.1,::1";

          # a string: transmission 4 reads it as octal, an int would be taken as decimal
          umask = "002";
        };
      };

      systemd.services.transmission = {
        # Nothing may run (or write) while the Data disk is missing.
        unitConfig.RequiresMountsFor = ["/trrnt" "/state"];
        # transmission-setup only has before/partOf, so nothing starts it on a fresh /state.
        requires = ["transmission-setup.service"];
        after = ["transmission-setup.service"];
        serviceConfig = {
          # home is not under /var/lib: do not create /var/lib/transmission on the System disk.
          StateDirectory = lib.mkForce [];
          # The module mounts watch-dir read-only; transmission renames the .torrent files it
          # picked up to *.added, which needs write access (/trrnt itself is writable).
          BindReadOnlyPaths = lib.mkForce [builtins.storeDir "/etc"];
        };
      };
      systemd.services.transmission-setup.unitConfig.RequiresMountsFor = ["/state"];
      optiplex.stateUnits = ["transmission" "transmission-setup"];

      # --- Caddy: LAN-only, plain http ---------------------------------------------------------
      services.caddy.virtualHosts."http://${host}".extraConfig = ''
        import lan_only
        header -X-Frame-Options
        rewrite /rpc /transmission/rpc
        reverse_proxy 127.0.0.1:${toString rpcPort}
      '';
      # blocky's customDNS mapping for opti.plex already answers transmission.opti.plex.
    })
  ];
}
