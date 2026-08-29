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
        # Blanket doHaddock=false across the whole package set
        # (dotfiles#854101, follow-up to dotfiles#112524's identical fix in
        # shellcheck-convention-plugin): the prior bare `dontHaddock` below
        # only stripped ShellCheck's OWN doc output -- its transitive deps
        # (assoc, colour, prettyprinter, ansi-terminal, optparse-applicative,
        # hashable, etc.) still built full haddock docs via nixpkgs' default,
        # since callCabal2nix built against the unmodified base
        # `pkgs.haskellPackages`. Overriding mkDerivation itself applies to
        # every package built through this set. Verified: this override's
        # own assoc.outputs == [out] vs the base set's [out doc].
        haskellPackages = pkgs.haskellPackages.override {
          overrides = hself: hsuper: {
            mkDerivation = args: hsuper.mkDerivation (args // { doHaddock = false; });
          };
        };
        shellcheck = pkgs.haskell.lib.dontCheck (
          haskellPackages.callCabal2nix "ShellCheck" self {}
        );
      in {
        packages = {
          default = shellcheck;
          lib = shellcheck;
        };
      });
}
