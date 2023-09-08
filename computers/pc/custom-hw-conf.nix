{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
       ./hardware-configuration.nix
     ];
   boot.loader.systemd-boot.enable = true;
   boot.loader.efi.canTouchEfiVariables = true;
   boot.initrd.availableKernelModules = [ "cryptd" ];
   boot.kernelPackages = pkgs.linuxPackages_xanmod;
   boot.kernel.sysctl = {
     "abi.vsyscall32" = 0;
  };
  boot.supportedFilesystems = [ "ntfs" ];
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/2c565d63-925c-4041-8172-a0e652c3eb6a";
    #https://nixos.wiki/wiki/Full_Disk_Encryption for some future day :(
    #allowDiscards = true;
    #keyFileSize = 4096;
    #keyFile = "/dev/sdf";
  };

  networking = {
    hostName = "yannik-pc";
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 localhost
    '';
    firewall.enable = true;
    firewall.allowPing = true;
    defaultGateway = "192.168.178.1";
    nameservers = [ "192.168.178.20" ];
    interfaces.enp12s0 = {
      wakeOnLan.enable = true;
      ipv4.addresses = [{
        address = "192.168.178.21";
        prefixLength = 24;
      }];
    };
  };
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
  #nvidia shibizzles
  hardware.opengl.enable = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;
  hardware.nvidia.modesetting.enable = true;
  hardware.nvidia.forceFullCompositionPipeline = true;

   # steam shibizzles
   hardware.opengl.driSupport32Bit = true;

   # nfs stuff
   fileSystems."/export/movies" = {
       device = "/storage/entertainment/movies";
       options = [ "bind" ];
     };

     fileSystems."/export/series" = {
       device = "/storage/entertainment/series";
       options = [ "bind" ];
     };

     fileSystems."/export/todo" = {
       device = "/storage/entertainment/todo";
       options = [ "bind" ];
     };

     fileSystems."/export/music" = {
       device = "/storage/entertainment/music";
       options = [ "bind" ];
     };
}

