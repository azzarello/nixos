{
  description = "corndog's NixOS machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, disko, ... }: {
    # breaker — HP mini PC. Always-on box: future router, DNS, small services.
    nixosConfigurations.breaker = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./hosts/breaker/disko.nix
        ./hosts/breaker/hardware-configuration.nix
        ./hosts/breaker/configuration.nix
      ];
    };
  };
}
