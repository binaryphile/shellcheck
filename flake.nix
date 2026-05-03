{
  description = "ShellCheck fork with custom IFS/noglob rules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            bash
            cabal-install
            coreutils
            ghc
            git
            haskell.packages.ghc966.pandoc  # for docs if needed
          ];
        };
      });
}
