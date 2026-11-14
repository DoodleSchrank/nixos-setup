# Timers (and their services) that must not run in any VM: the DDNS updater would overwrite the real
# DNS records, restic would back synthetic or restored State up into the real repository.
# The list is optiplex.vmTest.offlineTimers; service files append their own names to it.
{
  config,
  lib,
  ...
}: {
  optiplex.vmTest.offlineTimers = ["ddns-porkbun"];
  systemd.timers = lib.genAttrs (config.optiplex.vmTest.offlineTimers ++ ["battle-tracker-deploy"]) (_: {enable = lib.mkForce false;});
  systemd.services = lib.genAttrs config.optiplex.vmTest.offlineTimers (_: {enable = lib.mkForce false;});
  # battle-tracker-deploy is in the timer list only, not the service list: its timer would build from
  # git.nnik.dev, which no VM reaches, but the service and its path unit stay, the tests start them
  # (services/battle-tracker.nix).
}
