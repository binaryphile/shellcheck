#!/usr/bin/env bash

# Naming Policy:
#
# Standalone script -- no namespace prefix, no global suffix.
# Functions: cmd.PascalCase (mk.bash convention).
# Locals: camelCase.  Globals: PascalCase.
# _ suffix: contains IFS characters.

Prog=$(basename "$0")

read -rd '' Usage_ <<END
Usage:

  $Prog [OPTIONS] [--] COMMAND

  Commands:

    build         -- build shellcheck
    test          -- run all tests
    clean         -- remove build artifacts

  Options:

    -h | --help     show this message and exit
    -x | --trace    enable debug tracing
END

source "${MK_BASH_LIB:-$(dirname "$0")/mk.bash}"

cmd.Build() {
  cabal build
}

cmd.Test() {
  cabal test
}

cmd.Clean() {
  cabal clean
}

mk.Run "$@"
