{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  lan = {
    v4 = "192.168.178.0/24";
    v6 = "fd65:c1a5:7d2b::/64";
  };

  # Static .20 (also a FritzBox DHCP reservation). IPv6 comes from router
  # advertisements; the token makes the interface id ::20, i.e. <prefix>::20 and
  # fd65:c1a5:7d2b::20, which the FritzBox port shares and the DDNS AAAA point at.
  lanNetwork = {
    matchConfig.MACAddress = cfg.network.mac;
    address = ["192.168.178.20/24"];
    gateway = ["192.168.178.1"];
    networkConfig = {
      IPv6AcceptRA = true;
      IPv6PrivacyExtensions = false;
    };
    ipv6AcceptRAConfig.Token = "static:::20";
  };

  portSet = ports: lib.concatMapStringsSep ", " toString (lib.unique ports);
  lanRules = proto: ports:
    lib.optionalString (ports != []) ''
      ip saddr ${lan.v4} ${proto} dport { ${portSet ports} } accept
      ip6 saddr ${lan.v6} ${proto} dport { ${portSet ports} } accept
    '';
in {
  options.optiplex.network.mac = lib.mkOption {
    type = lib.types.str;
    default = "a4:bb:6d:7f:65:61"; # enp2s0, Realtek RTL8111/8168 (FritzBox reservation, WoL)
    description = ''
      MAC of the LAN NIC. Everything (networkd, the WoL link file, the initrd)
      matches on it instead of the name `enp2s0`, so a VM only needs the MAC set.
    '';
  };

  config = {
    networking = {
      hostName = "optiplex";
      domain = "opti.plex";
      useNetworkd = true;
      useDHCP = false;
      networkmanager.enable = false;

      # The host resolves through its own blocky (service ticket "Edge") and falls
      # back to a public resolver, which is not handed to the LAN. Plain resolv.conf,
      # no systemd-resolved: its stub listener would collide with blocky on :53 and
      # its FallbackDNS= only applies when no other server is configured. Until
      # blocky exists 127.0.0.1 refuses instantly and the fallback answers.
      nameservers = ["127.0.0.1" "9.9.9.9"];
      resolvconf.extraOptions = ["timeout:1"];
      # openresolv drops every non-local nameserver once it has seen 127.0.0.1, which
      # would silently remove the fallback again.
      resolvconf.extraConfig = "resolv_conf_local_only=NO";

      nftables.enable = true;
      firewall = {
        enable = true;
        # Public ports (80, 443, 8448, 3478 + 49152-49252, 51413) are opened by their
        # own service files with allowedTCPPorts/allowedUDPPorts (v4 and v6 alike).
        # LAN-only ports go through optiplex.firewall.lanOnly.{tcp,udp}.
        extraInputRules = lib.concatStrings [
          (lanRules "tcp" cfg.firewall.lanOnly.tcp)
          (lanRules "udp" cfg.firewall.lanOnly.udp)
        ];
      };
    };
    services.resolved.enable = false;

    systemd.network = {
      enable = true;
      networks."10-lan" = lanNetwork;
      links."10-lan" = {
        matchConfig.PermanentMACAddress = cfg.network.mac;
        linkConfig.WakeOnLan = "magic";
      };
      wait-online.anyInterface = true;
    };

    # Initrd: the same static address, so the LUKS unlock works over SSH (port 2222).
    #
    # Unlock from the LAN:
    #   ssh -p 2222 root@192.168.178.20          (yannik's key; host key = the initrd key)
    #   systemd-tty-ask-password-agent --query   (type the passphrase; boot continues)
    # (`systemctl default` in that shell is the fallback that also continues the boot.)
    #
    # /etc/secrets/initrd/ssh_host_ed25519_key is placed with nixos-anywhere
    # --extra-files and is a dedicated key, never /etc/ssh/ssh_host_ed25519_key:
    #   ssh-keygen -t ed25519 -N "" -f <extra-files>/etc/secrets/initrd/ssh_host_ed25519_key
    boot.initrd.systemd.network = {
      enable = true;
      networks."10-lan" = lanNetwork;
    };
    boot.initrd.network.ssh = {
      enable = true;
      port = 2222;
      authorizedKeys = config.users.users.yannik.openssh.authorizedKeys.keys;
      hostKeys = ["/etc/secrets/initrd/ssh_host_ed25519_key"];
    };
  };
}
