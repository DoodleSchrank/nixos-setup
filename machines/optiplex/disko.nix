# System disk only. The Data disk (Samsung 870 EVO, ext4) is never in here: see storage.nix.
#
# Install: nixos-anywhere --flake .#optiplex-restore --disk-encryption-keys /tmp/secret.key <file> ...
# (the file holds the LUKS passphrase; disko reads it from /tmp/secret.key on the target).
{
  config,
  lib,
  ...
}:
{
  disko.devices.disk.system = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-KBG40ZNS256G_NVMe_KIOXIA_256GB_21LPG2BCQL42";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = ["umask=0077"];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            passwordFile = "/tmp/secret.key";
            settings.allowDiscards = true;
            content = {
              type = "btrfs";
              extraArgs = ["-f"];
              subvolumes = let
                opts = ["compress=zstd" "noatime"];
              in {
                "@" = {
                  mountpoint = "/";
                  mountOptions = opts;
                };
                "@nix" = {
                  mountpoint = "/nix";
                  mountOptions = opts;
                };
                "@log" = {
                  mountpoint = "/var/log";
                  mountOptions = opts;
                };
                "@swap" = {
                  mountpoint = "/swap";
                  mountOptions = opts;
                  swap.swapfile.size = "16G";
                };
              };
            };
          };
        };
      };
    };
  };

  # journal from the start of stage 2 (skipped when a test turns the disko config off)
  fileSystems = lib.mkIf config.disko.enableConfig {
    "/var/log".neededForBoot = true;
  };
}
