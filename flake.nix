{
  description = "NixOS-Heimrechner";

  inputs = {
    sops-nix.url = "github:Mic92/sops-nix";
    #nixpkgs.url = "nixpkgs/nixos-22.11";
    nixpkgs-old.url = "nixpkgs/nixos-24.05";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    umu = {
      url = "git+https://github.com/Open-Wine-Components/umu-launcher/?dir=packaging\/nix&submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    solaar = {
      url = "https://flakehub.com/f/Svenum/Solaar-Flake/*.tar.gz"; # For latest stable version
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    nixpkgs-old,
    home-manager,
    sops-nix,
    solaar,
    umu,
    ...
  }: let
    system = "x86_64-linux";
    pkgsOld = nixpkgs-old.legacyPackages.${system};
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
          solaar.nixosModules.default
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
    };
  };
}
