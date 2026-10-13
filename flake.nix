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

    # services.cerbo (llama-swap serving the model) and programs.cerbo (the
    # command, hints and optional ssh tunnel) for NixOS.
    nixosModules.default = ./nix/nixos.nix;

    # programs.cerbo for home-manager; same options as the NixOS one.
    homeManagerModules.default = ./nix/home.nix;
    homeModules.default = ./nix/home.nix;

    checks = forAll (pkgs: {
      allowlist = pkgs.runCommand "cerbo-allowlist" {} ''
        cd ${./.}
        ${pkgs.python3}/bin/python3 tests/test_allowlist.py
        touch $out
      '';
    });

    devShells = forAll (pkgs: {
      default = pkgs.mkShell {
        packages = with pkgs; [python3 python3Packages.flake8 alejandra jq];
      };
    });

    formatter = forAll (pkgs: pkgs.alejandra);
  };
}
