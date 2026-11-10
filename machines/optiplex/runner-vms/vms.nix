# The two runner VMs as data, shared by the host side (services/gitea-runners.nix) and the guests
# (common.nix). Plain attrset, no module.
#
# Addresses: one routed tap per VM, each in its own /24 with the host at .1 and the VM at .2.
# Nothing else may use 10.100.0.0/16 (the forward rules treat all of 10/8 as private anyway).
rec {
  # Where the host side mounts the two disk images inside the guest. The guest's runner state and
  # Podman/job directories are built on these (common.nix).
  guestMounts = {
    runner = "/var/lib/gitea-runner"; # runner.img: .runner, .labels, .token-hash
    cache = "/var/lib/runner-cache"; # cache.img: podman store, job workdirs, action cache, tmp
  };

  # Job container image of the label (the live runners' labels; docker.gitea.com is the runner's own image repo).
  image = tag: "docker://docker.gitea.com/runner-images:${tag}";

  vms = {
    trusted = {
      name = "runner-trusted";
      tap = "vm-trusted"; # interface name on the host (max 15 chars)
      hostAddress = "10.100.1.1";
      address = "10.100.1.2";
      prefixLength = 24;
      mac = "02:00:0a:64:01:02";
      vcpu = 6;
      mem = 4096;
      capacity = 2;
      runnerImageMiB = 1024;
      cacheImageMiB = 80 * 1024;
      # Registered at org level for `aitopia`; the label names are the ones the workflows use today.
      labels = [
        "ubuntu-latest:${image "ubuntu-latest"}"
        "ubuntu-24.04:${image "ubuntu-24.04"}"
      ];
    };
    untrusted = {
      name = "runner-untrusted";
      tap = "vm-untrusted";
      hostAddress = "10.100.2.1";
      address = "10.100.2.2";
      prefixLength = 24;
      mac = "02:00:0a:64:02:02";
      vcpu = 4;
      mem = 3072;
      capacity = 1;
      runnerImageMiB = 1024;
      cacheImageMiB = 40 * 1024;
      # Registered instance-wide. Never `ubuntu-latest`: a runner takes any job whose label matches,
      # whoever owns it, and that would hand aitopia's jobs (and their secrets) to this VM.
      labels = [
        "shared:${image "ubuntu-latest"}"
        "shared-24.04:${image "ubuntu-24.04"}"
      ];
    };
  };
}
