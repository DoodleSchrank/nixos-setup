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
  boot.kernelPackages = pkgs.linuxPackages;
  boot.kernel.sysctl = {
    "abi.vsyscall32" = 0;
  };
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices.cryptroot.device = "/dev/disk/by-uuid/45e918a4-9733-4b2f-affd-63aafeccd212";

  networking = {
    hostName = "yannik-koenneker-thinkpad";
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 localhost
    '';
    firewall.enable = true;
    firewall.allowPing = true;
    firewall.allowedTCPPorts = [53317];
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
