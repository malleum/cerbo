{
  description = "cerbo: ask a local model to do something in the shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAll (pkgs: rec {
      cerbo = pkgs.callPackage ./nix/package.nix {};
      default = cerbo;
    });

    # The server side: llama-swap serving the model on loopback.
    nixosModules.default = ./nix/nixos.nix;

    # The client side: the cerbo command and its hints file.
    homeManagerModules.default = ./nix/home.nix;

    devShells = forAll (pkgs: {
      default = pkgs.mkShell {
        packages = with pkgs; [python3 python3Packages.flake8 alejandra jq];
      };
    });

    formatter = forAll (pkgs: pkgs.alejandra);
  };
}
