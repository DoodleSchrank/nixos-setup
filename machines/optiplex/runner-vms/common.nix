# Guest NixOS config shared by both runner VMs. A function of the VM's spec (vms.nix) that returns
# the module; trusted.nix and untrusted.nix import it.
#
# What the VM is: a read-only root rebuilt from this config on every boot (tmpfs root, the closure
# as an erofs store disk), rootful Podman, and one Gitea runner (`services.gitea-actions-runner`
# with our package, Gitea Runner 5.4.1) that registers with the token the host hands in as a
# systemd credential. Only two disk images persist (the host side mounts them, see
# services/gitea-runners.nix): runner.img (the registration) and cache.img (podman store, job
# workdirs, action cache, temp files). No SSH server, no login: debugging goes through the
# hypervisor console, whose output is the host's `journalctl -u microvm@<name>`.
#
# Trust boundary is the hardware VM, not anything in here: jobs run with container.privileged, so a
# job is root with all capabilities inside the VM.
spec: {
  config,
  lib,
  pkgs,
  ...
}: let
  vmData = import ./vms.nix;
  mounts = vmData.guestMounts;
  cacheDir = mounts.cache;
  instance = "main"; # runner state dir: ${mounts.runner}/main, unit gitea-runner-main
  tokenCredential = "/run/credentials/@system/RUNNER_TOKEN";
  url = "https://git.nnik.dev";
in {
  options.runnerVm.extraSettings = lib.mkOption {
    type = lib.types.attrs;
    default = {};
    description = "Extra runner config.yaml settings (merged over the defaults below), for the VM tests.";
  };

  config = {
    system.stateVersion = "26.11";
    networking.hostName = spec.name;

    # --- hypervisor ------------------------------------------------------------------------
    microvm = {
      hypervisor = "qemu"; # microvm.nix's default; nothing here needs another one
      vcpu = spec.vcpu;
      inherit (spec) mem;
      # The VM's own closure as an image. The host's /nix/store is never shared into the guests.
      storeOnDisk = true;
      interfaces = [
        {
          type = "tap";
          id = spec.tap;
          inherit (spec) mac;
        }
      ];
      # microvm.volumes (the two images) and credentialFiles (the token) are set by the host side.
    };

    # --- network: static, IPv4 only, DNS from the host's blocky ----------------------------------
    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.enableIPv6 = false;
    systemd.network.networks."10-uplink" = {
      matchConfig.MACAddress = spec.mac;
      address = ["${spec.address}/${toString spec.prefixLength}"];
      gateway = [spec.hostAddress];
      networkConfig.IPv6AcceptRA = false;
      linkConfig.RequiredForOnline = "routable";
    };
    # Plain resolv.conf, no resolved: blocky answers git.nnik.dev with the host (split horizon) and
    # everything else normally. The host's firewall allows exactly this port and 443.
    networking.nameservers = [spec.hostAddress];
    services.resolved.enable = false;
    # The host is the only boundary that matters (and it blocks all inbound), and the job containers must
    # reach the runner's cache server on this address.
    networking.firewall.enable = false;

    # --- nothing to log in to ---------------------------------------------------------------
    services.openssh.enable = false;
    users.mutableUsers = false;
    users.allowNoPasswordLogin = true;
    users.users.root.hashedPassword = "!";
    nix.enable = false;
    # The runner's and podman's logs end up on the hypervisor console (= host journal of microvm@<name>).
    services.journald.settings.Journal = {
      ForwardToConsole = true;
      TTYPath = "/dev/ttyS0";
      MaxLevelConsole = "info";
    };

    # --- disks: only runner.img and cache.img persist ----------------------------------------
    # The root is a tmpfs (half the RAM): nothing big may land on it. Everything that grows goes to
    # cache.img (mounted by the host side's microvm.volumes at ${cacheDir}): the podman store (below),
    # job work directories (host.workdir_parent) and the action cache (cache.dir) in the runner
    # config, and the temp dirs (TMPDIR of the runner unit, podman's image_copy_tmp_dir) that
    # image layers are unpacked into.
    systemd.tmpfiles.rules = [
      "d ${cacheDir}/containers 0755 root root -"
      "d ${cacheDir}/tmp 1777 root root -"
      "d ${cacheDir}/work 0755 gitea-runner gitea-runner -"
      "d ${cacheDir}/actcache 0755 gitea-runner gitea-runner -"
    ];
    # (tmpfiles runs after local-fs.target, which includes both image mounts)

    boot.kernelModules = ["overlay" "veth" "bridge" "br_netfilter" "nf_tables" "nft_masq" "nft_chain_nat" "nf_nat" "xt_MASQUERADE" "xt_conntrack" "vhost_vsock"];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # --- podman, rootful, with its Docker-compatible socket ---------------------------------------
    # The runner autodetects /run/podman/podman.sock (podman.socket); the module also exports it as DOCKER_HOST.
    virtualisation.podman.enable = true;
    virtualisation.containers.storage.rootful.settings.storage = {
      graphroot = "${cacheDir}/containers";
      runroot = "/run/containers/storage";
    };
    virtualisation.containers.containersConf.settings.engine.image_copy_tmp_dir = "${cacheDir}/tmp";
    # `docker:dind` resolves through podman's search registries (containers-shortnames), no docker.io prefix needed.

    # --- the runner ------------------------------------------------------------------------------
    users.groups.gitea-runner.gid = 975;
    users.users.gitea-runner = {
      isSystemUser = true;
      uid = 975; # fixed: it owns the persistent runner.img
      group = "gitea-runner";
      home = "${mounts.runner}/${instance}";
    };

    services.gitea-actions-runner = {
      package = pkgs.custom-packages.gitea-runner; # Gitea Runner 5.4.1 (custom-pkgs/gitea-runner)
      instances.${instance} = {
        enable = true;
        name = spec.name;
        inherit url;
        tokenFile = tokenCredential;
        inherit (spec) labels;
        # Carried from the live Portainer stack's config.yaml (ticket 25, ticket 33), minus the
        # --security-opt/--cap-add options that container.privileged replaces. 5.x config keys.
        settings = lib.recursiveUpdate {
          log.level = "info";
          runner = {
            inherit (spec) capacity;
            timeout = "3h";
            shutdown_timeout = "10m";
            fetch_interval = "2s";
            fetch_interval_max = "5s";
            workdir_cleanup_age = "24h";
            default_image = "docker.gitea.com/runner-images:ubuntu-latest";
            tool_cache_mode = "none";
          };
          cache = {
            enabled = true;
            dir = "${cacheDir}/actcache";
            # An address the job containers (on podman's bridge networks inside this VM) reach: the VM's own.
            host = spec.address;
            port = 39999;
            retention = "168h";
            repo_size_limit = "10GB";
            size_limit = "20GB";
          };
          container = {
            privileged = true; # jobs are root in this VM; docker:dind works without a capability list
            valid_volumes = [];
            force_pull = false;
            network = "";
          };
          # Job work directories (and the health check's disk) live on cache.img.
          host.workdir_parent = "${cacheDir}/work";
          health_check = {
            enabled = true;
            min_free_disk_space_mb = 5120;
          };
        } config.runnerVm.extraSettings;
      };
    };

    systemd.services."gitea-runner-${instance}" = {
      # Without a token credential (the host starts the VM before the production token exists) the
      # unit stays inactive instead of failing in a loop.
      unitConfig.ConditionPathExists = tokenCredential;
      environment.TMPDIR = "/var/tmp"; # cache.img, not the tmpfs /tmp
      serviceConfig = {
        # A fixed user, so the files on the persistent runner.img keep their owner across boots (the module's
        # StateDirectory=gitea-runner/main then creates ${mounts.runner}/${instance} for it).
        DynamicUser = lib.mkForce false;
        Group = "gitea-runner";
        # shutdown_timeout (10m) plus a minute: a stop (weekly wipe, host reboot) lets running jobs finish
        TimeoutStopSec = "11m";
      };
    };
  };
}
