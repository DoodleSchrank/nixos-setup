# Timers (and their services) that must not run in any VM: the DDNS updater would overwrite the real
# DNS records, restic would back synthetic or restored State up into the real repository.
# The list is optiplex.vmTest.offlineTimers; service files append their own names to it.
{
  config,
  lib,
  ...
}: {
  optiplex.vmTest.offlineTimers = ["ddns-porkbun"];
  systemd.timers = lib.genAttrs config.optiplex.vmTest.offlineTimers (_: {enable = lib.mkForce false;});
  systemd.services = lib.genAttrs config.optiplex.vmTest.offlineTimers (_: {enable = lib.mkForce false;});
}
