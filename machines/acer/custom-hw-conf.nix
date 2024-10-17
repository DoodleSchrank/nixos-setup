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
  boot.initrd.kernelModules = [ "" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices.cryptroot.device = "/dev/disk/by-uuid/c786c76a-7cad-492f-9681-b5b4efa0984a";

  networking = {
    hostName = "yannik-laptop";
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 localhost
    '';
    firewall.enable = true;
    firewall.allowPing = true;
    # warpinator ports
    firewall.allowedTCPPorts = [42000 42001];
    defaultGateway = "192.168.178.1";
    nameservers = ["192.168.178.20"];
#    interfaces.enp14s0 = {
    #      ipv4.addresses = [
#        {
#address = "192.168.178.22";
#          prefixLength = 24;
#        }
#      ];
 #   };
  };
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      libva
      vaapiVdpau
    ];
  };
}
