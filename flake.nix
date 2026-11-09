{
  description = "NixOS-Heimrechner";

  inputs = {
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    #nixpkgs.url = "nixpkgs/nixos-22.11";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Optiplex: declarative disk layout (System disk only) and the runner VMs
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    home-manager,
    sops-nix,
    disko,
    ...
  }: let
    system = "x86_64-linux";
  in {
    nix.settings.auto-optimise-store = true;
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };

    nixosConfigurations = {
      pc = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./custom-pkgs
          ./machines/pc
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.users.yannik = ./profiles/pc;
          }
        ];
      };
      acer = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./custom-pkgs
          ./machines/acer
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.users.yannik = ./profiles/acer;
          }
        ];
      };
      thinkpad = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./custom-pkgs
	        ./machines/thinkpad
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.users.yannik = ./profiles/thinkpad;
          }
        ];
      };
      optiplex = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./custom-pkgs
          ./machines/optiplex
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.users.yannik = ./profiles/optiplex;
          }
        ];
      };
      # nixos-anywhere installs this one; the normal deploy then switches to
      # .#optiplex (see optiplex.restoreMode in machines/optiplex/default.nix).
      optiplex-restore = self.nixosConfigurations.optiplex.extendModules {
        modules = [{ optiplex.restoreMode = true; }];
      };
    };
  };
}
