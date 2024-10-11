{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];
  boot.initrd.availableKernelModules = ["cryptd"];
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelPackages = pkgs.linuxPackages_xanmod;
  boot.kernel.sysctl = {
    "abi.vsyscall32" = 0;
  };
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices.cryptroot.device = "/dev/disk/by-uuid/23ce993e-3161-424f-b6d7-93d9b9bdbcb9";

  networking = {
    hostName = "yannik-pc";
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 localhost
    '';
    firewall.enable = true;
    firewall.allowPing = true;
    firewall.allowedTCPPorts = [53317 42000 42001];
    defaultGateway = "192.168.178.1";
    nameservers = ["192.168.178.20"];
    interfaces.enp14s0 = {
      wakeOnLan.enable = true;
      ipv4.addresses = [
        {
          address = "192.168.178.21";
          prefixLength = 24;
        }
      ];
    };
  };
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      rocmPackages.clr.icd
      libva
      amdvlk
      libva
      vaapiVdpau
    ];
    extraPackages32 = with pkgs; [
      rocmPackages.clr.icd
    ];
  };
}
