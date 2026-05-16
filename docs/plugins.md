# Writing Custom ShellCheck Checks

A practical guide to adding checks using the plugin system.

## Quick Start (concept)

This snippet shows the shape of a custom check — a `CustomCheck` value plus the check function it points at. It is a concept, not a complete loadable module; see **Complete Loadable Example** below for the full module structure (with the `foreign export` declarations the dynamic loader needs) that you can copy-paste and build.

```haskell
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Data.List (isPrefixOf)

check :: CustomCheck
check = CustomCheck {
    ccChecker = myCheckFunction,
    ccAlwaysOn = True,    -- or False for optional
    ccDescription = newCheckDescription {
        cdName = "my-check-name",
        cdDescription = "What this check does",
        cdPositive = "echo $unsafeInput",
        cdNegative = "echo $safeInput"
    }
}

myCheckFunction :: Token -> Analysis
myCheckFunction token = case getExpansionName token of
    Just name | "unsafe" `isPrefixOf` name ->
        warn (getId token) 9010 $
            "Variable $" ++ name ++ " uses the unsafe prefix."
    _ -> return ()
```

Expected output when the resulting plugin is loaded and run on a script:

```
$ echo '#!/bin/bash
echo $unsafeInput' | shellcheck -

In - line 2:
echo $unsafeInput
     ^----------^ SC9010 (warning): Variable $unsafeInput uses the unsafe prefix.
```

## Complete Loadable Example

The full minimal module that builds as a `.so` and loads via `dlopen`:

```haskell
-- BEGIN COMPLETE EXAMPLE
module MyPlugin where

import Foreign.C.Types (CInt)
import Foreign.StablePtr (StablePtr, newStablePtr)

import ShellCheck.Checks.Custom.Base (CustomCheck(..), pluginApiVersion, getExpansionName)
import ShellCheck.AnalyzerLib
import ShellCheck.Interface

import Data.List (isPrefixOf)

foreign export ccall plugin_api_version :: IO CInt
foreign export ccall plugin_init :: IO (StablePtr [CustomCheck])

plugin_api_version :: IO CInt
plugin_api_version = return (fromIntegral pluginApiVersion)

plugin_init :: IO (StablePtr [CustomCheck])
plugin_init = newStablePtr [myCheck]

myCheck :: CustomCheck
myCheck = CustomCheck {
    ccChecker = myCheckFunction,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "my-external-check",
        cdDescription = "Variables prefixed with unsafe are flagged.",
        cdPositive = "echo $unsafeInput",
        cdNegative = "echo $safeInput"
    }
}

myCheckFunction :: Token -> Analysis
myCheckFunction token = case getExpansionName token of
    Just name | "unsafe" `isPrefixOf` name ->
        warn (getId token) 9010 $
            "Variable $" ++ name ++ " uses the unsafe prefix."
    _ -> return ()
-- END COMPLETE EXAMPLE
```

Build and install:

```bash
ghc -dynamic -shared -fPIC -package ShellCheck src/MyPlugin.hs -o libmyplugin.so
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/shellcheck/plugins"
cp libmyplugin.so "${XDG_DATA_HOME:-$HOME/.local/share}/shellcheck/plugins/"
```

## Accessing Parameters

Check functions have type `Token -> Analysis` where `Analysis` is an RWS monad with `Parameters` as the reader. Use `ask` to access:

```haskell
import Control.Monad.RWS (ask)

myCheck :: Token -> Analysis
myCheck token = do
    params <- ask
    let parents = parentMap params    -- Map from Id to parent Token
        shell = shellType params      -- Sh | Bash | Dash | Ksh | BusyboxSh
    -- use parents, shell, etc.
```

Common Parameters fields:
- `parentMap` — walk the AST parent chain
- `shellType` — gate checks by shell dialect
- `rootNode` — the full script AST
- `cfgAnalysis` — control flow graph (if extended analysis is enabled)

## Choosing Always-On vs Optional

Set `ccAlwaysOn` in your `CustomCheck`:

- **Always-on** (`True`): Fires without any configuration. Use for checks where the pattern is unambiguous — if someone writes the flagged pattern, they almost certainly want the warning.

- **Optional** (`False`): Requires `enable=your-check-name` in shellcheckrc or `--enable=your-check-name` on the CLI. Use for checks that are noisy outside a specific execution model, or that enforce style preferences rather than correctness.

The `cdName` in `CheckDescription` is the enable/disable identifier.

## Building External Plugins

External plugins are `.so` files loaded at startup from `$XDG_DATA_HOME/shellcheck/plugins/`. They must be built against the same ShellCheck library and GHC version as the host binary.

### ABI constraints

- Plugin MUST be built with the same GHC version as the shellcheck binary
- Plugin MUST link against the same ShellCheck library package (same nix derivation)
- Plugin MUST NOT use `-flink-rts` (shares the host's RTS)
- Plugin MUST export `plugin_api_version :: IO CInt` and `plugin_init :: IO (StablePtr [CustomCheck])`

### Installation

Copy the `.so` to `$XDG_DATA_HOME/shellcheck/plugins/` (the default plugin directory):

```bash
mkdir -p $XDG_DATA_HOME/shellcheck/plugins
cp result/lib/shellcheck/plugins/libmyplugin.so \
   $XDG_DATA_HOME/shellcheck/plugins/
```

Or use `--plugin-dir` to load from an alternate directory:

```bash
shellcheck --plugin-dir=/path/to/plugins myscript.sh
```

## Writing Effective Tests

Use `verify`, `verifyNot`, and `verifyCode` from `Base.hs`:

```haskell
-- Check fires (any diagnostic produced)
prop_fires = verify myCheck "echo $foo"

-- Check is silent (no diagnostic)
prop_silent = verifyNot myCheck "echo \"$foo\""

-- Check fires with specific SC code (strongest assertion)
prop_code = verifyCode myCheck 9010 "echo $foo"
```

Test scripts don't need shebangs — the parser defaults to Bash.

Suppression works automatically:
```haskell
prop_suppressed = verifyNot myCheck "# shellcheck disable=SC9010\necho $foo"
```

**What to test**:
- Test the check function thoroughly — it's domain logic with high significance
- Test each edge case from your spec
- Don't test every value in a lookup table — test the mechanism, not the data
- One `verifyCode` test per check to lock the SC code number

## Common AST Patterns

### Variable expansions

Both `$var` and `${var}` parse as `T_DollarBraced`. Use `getExpansionName` from Base.hs:

```haskell
myCheck token = case getExpansionName token of
    Just name -> -- name is the variable name (e.g., "foo")
    Nothing -> return ()  -- not a variable expansion
```

### Assignments

```haskell
myCheck (T_Assignment id mode name indices value) = do
    -- name is the variable name string
    -- value is the RHS token
    -- mode is Assign or Append
myCheck _ = return ()
```

### Quoting context

Use `isQuoteFree` from AnalyzerLib to check if a token is in a context where word splitting doesn't occur:

```haskell
myCheck token = do
    params <- ask
    let parents = parentMap params
        shell = shellType params
    when (not $ isQuoteFree shell parents token) $
        warn (getId token) 9010 "This needs quoting."
```

Note: `isQuoteFree` does not currently walk through `T_FdRedirect` ancestors; use `isInRedirectContext` from Base.hs as a workaround:

```haskell
    when (not (isQuoteFree shell parents token)
          && not (isInRedirectContext parents token)) $
        warn (getId token) 9010 "This needs quoting."
```

### Command names

```haskell
import ShellCheck.ASTLib (getCommandName)

myCheck token = do
    case getCommandName token of
        Just "rm" -> -- this is an rm command
        _ -> return ()
```

### Walking the parent chain

```haskell
import ShellCheck.ASTLib (getPath)
import qualified Data.List.NonEmpty as NE

myCheck token = do
    params <- ask
    let ancestors = NE.tail $ getPath (parentMap params) token
    -- ancestors is a list from immediate parent to root
```

## Nix Flake Template

```nix
{
  inputs = {
    shellcheck.url = "github:koalaman/shellcheck";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };
  outputs = { self, shellcheck, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
    scPkg = shellcheck.packages.${system}.lib;
    ghc = pkgs.haskellPackages.ghcWithPackages (p: [ p.unix scPkg ]);
  in {
    packages.${system}.default = pkgs.stdenv.mkDerivation {
      name = "my-shellcheck-plugin";
      src = ./.;
      buildInputs = [ ghc ];
      buildPhase = ''
        ghc -dynamic -shared -fPIC \
          src/MyPlugin.hs -o libmyplugin.so
      '';
      installPhase = ''
        mkdir -p $out/lib/shellcheck/plugins
        cp libmyplugin.so $out/lib/shellcheck/plugins/
      '';
    };
  };
}
```

Key: `ghcWithPackages` adds `scPkg` to GHC's package database. Type identity holds because both the shellcheck binary and the plugin link against the same `scPkg` derivation (same nix store path = same GHC unit ID).

## Debugging

Verify symbols are exported:

```bash
nm -D libmyplugin.so | grep plugin_
# Should show:
# T plugin_api_version
# T plugin_init
```

Check stderr for loader messages when running shellcheck:

```bash
shellcheck myscript.sh 2>&1 | head
# "Loaded plugin: libmyplugin.so (1 check(s))"
```

Common failures:
- `plugin_api_version symbol not found` -- missing `foreign export ccall`
- `API version mismatch` -- plugin built against different ShellCheck version
- `dlopen` error about undefined symbols -- GHC version mismatch or missing `-rdynamic` on host
