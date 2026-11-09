# Base of nixosConfigurations.optiplex (the home server, see GLOSSARY.md).
#
# This module is what every service ticket plugs into. It runs no Kept service.
# Layout:
#   default.nix     imports, options, locale, nix settings, users, sshd, sops-nix
#   disko.nix       System disk (the Data disk is never in here)
#   hardware.nix    kernel modules, microcode, boot loader
#   networking.nix  networkd, initrd unlock network, resolver, nftables
#   storage.nix     Data disk mount and the /state bind mount
#   monitoring.nix  notify-failure@ (OnFailure for all services) and smartd
#   services/       one file per Kept service, listed in services/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.optiplex;
  hostSecrets = cfg.secretsDir + "/host.yaml";
  haveHostSecrets = builtins.pathExists hostSecrets;
in {
  imports = [
    ../user.nix
    ./disko.nix
    ./hardware.nix
    ./networking.nix
    ./storage.nix
    ./monitoring.nix
    ./services
  ];

  options.optiplex = {
    restoreMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Cutover install mode (flake output `optiplex-restore`). PostgreSQL and
        MariaDB run and their roles and databases exist, but every Kept service
        is switched off, so State can be restored and chowned first. The normal
        deploy (`.#optiplex`) then starts everything.

        Convention for service files: gate the service's `enable` (or its
        units' `wantedBy`) on `!config.optiplex.restoreMode`. Switch services
        off, never modules: users, groups, sops secrets and /state/<service>
        directories must still exist in restore mode. The edge (Caddy, ACME,
        DDNS, blocky) stays on.
      '';
    };

    stateUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["gitea" "vaultwarden"];
      description = ''
        Services (with or without the `.service` suffix) that keep State under
        /state. Each gets `RequiresMountsFor=/state`, so they do not start (and
        never write to the System disk) while the Data disk is missing. The
        list merges across files, so every service file just adds its unit.
      '';
    };

    secretsDir = lib.mkOption {
      type = lib.types.path;
      default = ../../secrets/optiplex;
      description = ''
        Directory with the sops files, one per service. Service files build
        their `sopsFile` from it: `config.optiplex.secretsDir + "/gitea.yaml"`.
        The VM tests point it at a mirror with test secrets.
      '';
    };

    firewall.lanOnly = {
      tcp = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [];
        description = "TCP ports opened to the LAN only (192.168.178.0/24 and fd65:c1a5:7d2b::/64).";
      };
      udp = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [];
        description = "UDP ports opened to the LAN only.";
      };
    };
  };

  config = {
    ## Uid/gid rule for service files (State survives reinstalls, the System disk's
    ## uid map does not): every service user or group that owns files under /state
    ## gets a fixed `uid`/`gid` in its service file (users.users.<n>.uid, users.groups.<n>.gid).
    ## Never rely on dynamically allocated system ids for anything on the Data disk.

    ## sops-nix convention: one file per service, secrets/optiplex/<service>.yaml,
    ## mirroring services/<service>.nix. The files are encrypted to the `yannik` and
    ## `optiplex` age recipients (secrets/.sops.yaml); the host decrypts with its SSH
    ## host key. A service file declares
    ##   sops.secrets."<name>" = {
    ##     sopsFile = config.optiplex.secretsDir + "/<service>.yaml";
    ##     owner = "<service user>"; mode = "0400";
    ##   };
    ## Secrets stay under /run/secrets. Never point a secret's `path` into /state:
    ## sops-nix runs at activation, possibly before the (nofail) Data disk is mounted.
    ## Link or copy into place from the service's preStart/tmpfiles instead.
    sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    sops.gnupg.sshKeyPaths = [];
    sops.defaultSopsFormat = "yaml";

    system.stateVersion = "26.11"; # nixpkgs release at install time, never change

    time.timeZone = "Europe/Berlin";
    i18n.defaultLocale = "en_US.UTF-8";
    console.keyMap = "de";
    hardware.bluetooth.enable = true; # Home Assistant

    nix = {
      settings = {
        experimental-features = ["nix-command" "flakes"];
        trusted-users = ["root" "yannik"]; # `nixos-rebuild --target-host` copies as yannik
        auto-optimise-store = true;
      };
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 7d";
      };
    };

    environment.systemPackages = with pkgs; [git curl];

    ## Users: yannik is the only human login.
    programs.zsh.enable = true;
    users.mutableUsers = false;
    users.groups.yannik.gid = 1001; # matches Data disk ownership
    users.users.yannik = {
      uid = 1001;
      group = "yannik";
      # Services add him via users.groups.<group>.members, not extraGroups.
      extraGroups = lib.mkForce ["wheel" "kvm"];
      # Console password (local keyboard only; ssh stays key-only, sudo passwordless).
      hashedPasswordFile = lib.mkIf haveHostSecrets config.sops.secrets.yannik_password_hash.path;
    };
    users.users.root.hashedPassword = "!";

    sops.secrets.yannik_password_hash = lib.mkIf haveHostSecrets {
      sopsFile = hostSecrets;
      neededForUsers = true;
    };
    warnings = lib.optional (!haveHostSecrets) ''
      secrets/optiplex/host.yaml does not exist (looked in ${toString cfg.secretsDir}): yannik gets no console password.
      Create it with `sops secrets/optiplex/host.yaml` (key: yannik_password_hash,
      value from `mkpasswd -m yescrypt`) and `git add` it.
    '';

    services.openssh = {
      enable = true;
      ports = [25560];
      openFirewall = false; # 25560 is opened LAN-only below
      hostKeys = [
        {
          type = "ed25519";
          path = "/etc/ssh/ssh_host_ed25519_key";
        }
        {
          type = "rsa";
          bits = 4096;
          path = "/etc/ssh/ssh_host_rsa_key";
        }
      ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = ["yannik"];
      };
    };
    optiplex.firewall.lanOnly.tcp = [25560];
  };
}
