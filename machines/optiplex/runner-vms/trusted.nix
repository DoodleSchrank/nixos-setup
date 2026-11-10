# Guest of the trusted runner VM: serves the `aitopia` organisation (registration token with
# `--scope aitopia`), labels ubuntu-latest / ubuntu-24.04, 6 vCPU, 4 GB, capacity 2.
{
  imports = [(import ./common.nix (import ./vms.nix).vms.trusted)];
}
