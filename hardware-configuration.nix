{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "mpt3sas" "nvme" "usbhid" "sd_mod" "aesni_intel" "cryptd"];
  boot.initrd.kernelModules = [ "dm-snapshot" "usb_storage" ];
  boot.kernelPackages = pkgs.linuxPackages_xanmod;
  boot.kernelModules = [ "kvm-intel" ];
  boot.kernel.sysctl = {
    "abi.vsyscall32" = 0;
  };
  boot.extraModulePackages = [ ];

  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/118abaea-ad74-40f4-a0e2-58a8080b9cb4";
    #https://nixos.wiki/wiki/Full_Disk_Encryption for some future day :(
    #allowDiscards = true;
    #keyFileSize = 4096;
    #keyFile = "/dev/sdf";
  };


  fileSystems."/" =
    { device = "/dev/disk/by-uuid/24d558ad-665f-4953-88f8-98c9323d7387";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/B756-60A6";
      fsType = "vfat";
    };

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/63ea054a-5c14-429d-ba8a-d794d3d844be";
      fsType = "ext4";
    };

  fileSystems."/storage" =
    { device = "/dev/disk/by-uuid/cd93ad94-9efd-495f-9a86-2a3304eb1adb";
      fsType = "btrfs";
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/d70a38bb-d094-4c2c-9e0a-965309cbae79"; }
    ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.hostName = "yannik-pc";
  networking.networkmanager.enable = true;
  networking.extraHosts = ''
    127.0.0.1 localhost
  '';
  networking.firewall.enable = true;
  networking.firewall.allowPing = true;
  networking.defaultGateway = "192.168.178.1";
  networking.nameservers = [ "192.168.178.20" ];
  networking.interfaces.eno1 = {
    wakeOnLan.enable = true;
    ipv4.addresses = [{
      address = "192.168.178.21";
      prefixLength = 24;
    }];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  #nvidia shibizzles
  hardware.opengl.enable = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;
  hardware.nvidia.modesetting.enable = true;
  hardware.nvidia.forceFullCompositionPipeline = true;

  # steam shibizzles
  hardware.opengl.driSupport32Bit = true;
}
