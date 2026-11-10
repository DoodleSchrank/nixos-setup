# Guest of the untrusted runner VM: serves every other account (instance-wide token), labels
# shared / shared-24.04 only, 4 vCPU, 3 GB, capacity 1. Its cache disk is wiped weekly.
{
  imports = [(import ./common.nix (import ./vms.nix).vms.untrusted)];
}
