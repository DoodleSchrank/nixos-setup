{
  description = "NixOS-Heimrechner";

  inputs = {
    sops-nix.url = "github:Mic92/sops-nix";
    #nixpkgs.url = "nixpkgs/nixos-22.11";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    #nix-gaming.url = "github:fufexan/nix-gaming";
    nurpkgs = {
      url = github:nix-community/NUR;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, nurpkgs, home-manager, sops-nix, ... }:
  let
    system = "x86_64-linux";
  in
  {
    nixosConfigurations = {
      heimrechner = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./configuration.nix
          ./computers/pc
          sops-nix.nixosModules.sops
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
          }
        ];
      };
    };
  };
}