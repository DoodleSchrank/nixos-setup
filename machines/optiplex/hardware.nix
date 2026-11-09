{
  config,
  lib,
  ...
}: {
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "sd_mod"
    "r8169" # enp2s0 (Realtek RTL8111/8168): needed in the initrd for the SSH unlock
  ];
  boot.kernelModules = ["kvm-intel"];

  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true; # Bluetooth (UB500) firmware

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 10; # 1 GiB ESP holds kernel + SSH initrd per generation
  };
  boot.loader.efi.canTouchEfiVariables = true;
}
