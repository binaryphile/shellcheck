{
  description = "ShellCheck with dynamic plugin loading (test build)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        shellcheck = pkgs.haskellPackages.callCabal2nix "ShellCheck" self {};
      in {
        packages = {
          default = shellcheck;
          lib = shellcheck;
        };
      });
}
