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
#  boot.initrd.kernelModules = [ "" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices.cryptroot.device = "/dev/disk/by-uuid/8e56fedd-d177-4b11-993d-733fbddaa774";

  networking = {
    hostName = "yannik-koenneker-thinkpad";
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 localhost
    '';
    firewall.enable = true;
    firewall.allowPing = true;
    firewall.allowedTCPPorts = [];
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
  hardware.opentabletdriver.enable = true;
  hardware.opentabletdriver.daemon.enable = true;
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.hardware.bolt.enable = true;

}
