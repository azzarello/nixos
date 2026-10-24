{
  description = "corndog's NixOS machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }:
  let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    breakerModules = [
      disko.nixosModules.disko
      ./hosts/breaker/disko.nix
      ./hosts/breaker/hardware-configuration.nix
      ./hosts/breaker/configuration.nix
      ./modules/common.nix
      ./modules/k3s.nix
      ./modules/zfs-datasets.nix
      ./modules/router.nix
      ./modules/netdata.nix
    ];
  in {
    # breaker — HP mini PC. Always-on box: future router, DNS, small services.
    nixosConfigurations.breaker = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = breakerModules;
    };

    # breaker with the router role switched on: what cutover will deploy (docs/router.md).
    nixosConfigurations.breaker-router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = breakerModules ++ [{ router.enable = true; }];
    };


    checks.x86_64-linux = {
      router = import ./tests/router.nix { inherit pkgs; };
      router-k3s = import ./tests/router.nix { inherit pkgs; withK3s = true; };
      # the cutover config must at least build
      breaker-router = self.nixosConfigurations.breaker-router.config.system.build.toplevel;
    };
  };
}
