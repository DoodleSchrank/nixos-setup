# Rehearsal overlay (impure, run on the PC with real State restored from Backup):
# nixosConfigurations.optiplex-rehearsal[-restore] = optiplex[-restore] + this module.
# See tests/optiplex/rehearsal.sh. What differs from the real host, and why:
#
#   - ACME: lego still does DNS-01 at Porkbun with the real credentials, but against Let's Encrypt
#     STAGING (no rate-limit cost, no trusted cert).
#   - No DDNS updater and no restic timers (offlineTimers): they would rewrite the real DNS records
#     and write into the real backup repository. Restore from Backup runs by hand and never
#     `forget`/`prune`.
#   - Egress is default-deny: only root, yannik and the acme user (plus DNS/DoT to anywhere, for blocky's upstreams) may open
#     connections; everything else gets an immediate refusal. This is what keeps the restored Matrix
#     bridges (live WhatsApp/Telegram sessions), Synapse federation, Home Assistant, Vaultwarden and
#     Paperless from talking to the world. Rootful podman containers are blocked in the forward chain.
#   - Hardware: qemu NIC MAC and the NVMe by-id name of the rehearsal disk.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex.rehearsal;
  uidList = lib.concatMapStringsSep ", " toString cfg.egress.allowedUids;
  portList = ps: lib.concatMapStringsSep ", " toString ps;
  forwardRules = lib.concatMapStrings (i: ''
    iifname "${i}" accept
  '') cfg.egress.allowedForwardInterfaces;
  timers = config.optiplex.vmTest.offlineTimers;
  tl = import ./lib.nix {inherit lib;};
in {
  imports = [./offline.nix];

  options.optiplex.rehearsal = {
    nicMac = lib.mkOption {
      type = lib.types.str;
      default = "52:54:00:12:34:56"; # the first NIC of a plain qemu VM
      description = "MAC of the rehearsal VM's NIC (qemu user networking).";
    };
    diskSerial = lib.mkOption {
      type = lib.types.str;
      default = "REHEARSAL0001";
      description = "Serial of the qemu NVMe System disk; the by-id name is nvme-QEMU_NVMe_Ctrl_<serial>.";
    };
    egress = {
      allowedUids = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [0 1001 3189]; # root, yannik, acme
        description = "uids that may open outgoing connections.";
      };
      allowedTcpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [53 853];
        description = "Destination TCP ports open to every user: DNS and DNS-over-TLS, so blocky (a DynamicUser service) reaches its upstreams.";
      };
      allowedUdpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [53];
        description = "Destination UDP ports open to every user.";
      };
      allowedForwardInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["microvm"];
        description = ''
          Interfaces whose forwarded traffic is allowed. Rootful podman (`podman*`) is always blocked.
          The runner-VM ticket adds its bridge here for its rehearsal.
        '';
      };
    };
  };

  config = {
    # --- staging ACME ----------------------------------------------------------------
    security.acme.defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";
    security.acme.certs."nnik.dev" = lib.mkIf config.services.caddy.enable {
      server = lib.mkForce "https://acme-staging-v02.api.letsencrypt.org/directory";
    };
    users.users.acme.uid = lib.mkDefault 3189; # pinned for the egress rule

    # --- hardware of the rehearsal VM ----------------------------------------------------
    optiplex.network.mac = cfg.nicMac;
    # qemu's virtio devices; the real hardware.nix only lists the Optiplex's own (r8169, nvme, ahci)
    boot.initrd.availableKernelModules = ["virtio_pci" "virtio_net" "virtio_blk"];
    boot.kernelParams = ["console=ttyS0"]; # the rehearsal console log
    disko.devices.disk.system.device = lib.mkForce "/dev/disk/by-id/nvme-QEMU_NVMe_Ctrl_${cfg.diskSerial}";

    # --- egress default-deny -------------------------------------------------------------------
    networking.nftables.tables.rehearsal-egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority 0; policy accept;
          oifname "lo" accept
          ct state established,related accept
          meta skuid { ${uidList} } accept
          tcp dport { ${portList cfg.egress.allowedTcpPorts} } accept
          udp dport { ${portList cfg.egress.allowedUdpPorts} } accept
          # reject, not drop: a refused service fails fast instead of hanging
          reject with icmpx type admin-prohibited
        }
        chain forward {
          type filter hook forward priority 0; policy accept;
          ${forwardRules}
          iifname "podman*" reject with icmpx type admin-prohibited
        }
      '';
    };

    environment.systemPackages = [pkgs.openssl pkgs.curl pkgs.util-linux];

    # --- rehearsal checks (tier "rehearsal"; run by rehearsal.sh over ssh) ------------------------------
    # phase "restore": these must hold before any restored Kept service starts (the bridges in particular)
    optiplex.vmTest.checks.rehearsal-timers = {
      tiers = ["rehearsal"];
      phase = "restore";
      script = ''
        # the DDNS and restic timers are absent
        # (a disabled NixOS unit is a masked unit: /dev/null)
        for t in [${lib.concatMapStringsSep ", " (t: ''"${t}"'') timers}]:
            state = optiplex.succeed(f"systemctl show -p LoadState --value {t}.timer").strip()
            assert state in ("masked", "not-found"), (t, state)
        optiplex.fail("systemctl list-timers --all --no-legend | grep -E 'ddns|restic'")
      '';
    };
    optiplex.vmTest.checks.rehearsal-egress = {
      tiers = ["rehearsal"];
      phase = "restore";
      script = ''
        # a service user cannot reach the internet, the acme user can (1.1.1.1: no DNS needed)
        optiplex.fail("runuser -u caddy -- curl -sS --max-time 8 -o /dev/null https://1.1.1.1")
        optiplex.fail("runuser -u nobody -- curl -sS --max-time 8 -o /dev/null https://1.1.1.1")
        optiplex.succeed("runuser -u acme -- curl -sS --max-time 15 -o /dev/null https://1.1.1.1")
        optiplex.succeed("curl -sS --max-time 15 -o /dev/null https://1.1.1.1")  # root
        # a real LAN host stays unreachable (the VM's 192.168.178.0/24 is qemu's own, it shadows the real LAN)
        optiplex.fail("curl -sS --max-time 5 -o /dev/null http://192.168.178.21")
        optiplex.fail("timeout 5 bash -c 'echo > /dev/tcp/192.168.178.21/80'")
      '';
    };
    optiplex.vmTest.checks.rehearsal-failed-units = {
      tiers = ["rehearsal"];
      script = tl.failedUnitsCheck {inherit config;};
    };
    optiplex.vmTest.checks.rehearsal-staging-cert = lib.mkIf config.services.caddy.enable {
      tiers = ["rehearsal"];
      phase = "restore"; # the edge stays on in restoreMode
      script = ''
        # Caddy holds the staging cert for nnik.dev + *.nnik.dev
        optiplex.wait_until_succeeds("test -s /var/lib/acme/nnik.dev/cert.pem", timeout=600)
        out = optiplex.succeed("echo | openssl s_client -connect 127.0.0.1:443 -servername x.nnik.dev 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName")
        print(out)
        assert "STAGING" in out.upper(), out
        assert "DNS:nnik.dev" in out and "DNS:*.nnik.dev" in out, out
      '';
    };
  };
}
