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
    # Shared by nixosConfigurations.optiplex and the VM tests (tests/optiplex/), which add their own overlay.
    optiplexModules = [
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
        modules = optiplexModules;
      };
      # nixos-anywhere installs this one; the normal deploy then switches to
      # .#optiplex (see optiplex.restoreMode in machines/optiplex/default.nix).
      optiplex-restore = self.nixosConfigurations.optiplex.extendModules {
        modules = [{ optiplex.restoreMode = true; }];
      };
      # Impure rehearsal VM (tests/optiplex/rehearsal.sh): staging ACME, no DDNS/restic, egress
      # default-deny, qemu NIC/disk. The -restore variant is what gets installed first.
      optiplex-rehearsal = self.nixosConfigurations.optiplex.extendModules {
        modules = [ ./tests/optiplex/overlay-rehearsal.nix ];
      };
      optiplex-rehearsal-restore = self.nixosConfigurations.optiplex-restore.extendModules {
        modules = [ ./tests/optiplex/overlay-rehearsal.nix ];
      };
      # The same with the committed test secrets, for dry runs of rehearsal.sh without real secrets
      # (no staging cert there: the Porkbun credentials are dummies).
      optiplex-rehearsal-dryrun = self.nixosConfigurations.optiplex-rehearsal-restore.extendModules {
        modules = [ ./tests/optiplex/test-secrets.nix ./tests/optiplex/dryrun.nix ];
      };
      optiplex-rehearsal-dryrun-normal = self.nixosConfigurations.optiplex-rehearsal.extendModules {
        modules = [ ./tests/optiplex/test-secrets.nix ./tests/optiplex/dryrun.nix ];
      };
    };

    # VM tests of the Optiplex (ticket "VM test harness"): see tests/optiplex/.
    packages.${system} = let
      pkgs = nixpkgs.legacyPackages.${system};
      tl = import ./tests/optiplex/lib.nix { inherit (pkgs) lib; };
      rehearsalChecks = attr: phase: pkgs.writeText "${attr}-checks-${phase}.py" (tl.renderChecks {
        tier = "rehearsal"; inherit phase;
        config = self.nixosConfigurations.${attr}.config;
      });
      installer = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./tests/optiplex/rehearsal-installer.nix ];
      };
    in {
      # rehearsal.sh: checks of the tier "rehearsal", per phase, and the pieces it runs
      optiplex-rehearsal-checks-restore = rehearsalChecks "optiplex-rehearsal" "restore";
      optiplex-rehearsal-checks-normal = rehearsalChecks "optiplex-rehearsal" "normal";
      optiplex-rehearsal-dryrun-checks-restore = rehearsalChecks "optiplex-rehearsal-dryrun" "restore";
      optiplex-rehearsal-dryrun-checks-normal = rehearsalChecks "optiplex-rehearsal-dryrun-normal" "normal";
      optiplex-rehearsal-installer = installer.config.system.build.vm;
      optiplex-rehearsal-qemu = pkgs.qemu_kvm;
      optiplex-rehearsal-ovmf = pkgs.OVMF.fd;
      # the public snakeoil key that the installer VM and the dry-run config trust (test only)
      test-ssh-key = (import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs).snakeOilPrivateKey;
    };

    checks.${system} = let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      optiplex-vm = import ./tests/optiplex/vm.nix { inherit pkgs inputs optiplexModules; };
      optiplex-install = import ./tests/optiplex/install.nix { inherit pkgs inputs optiplexModules; };
    };
  };
}
