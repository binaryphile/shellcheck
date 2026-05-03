# Handoff: Custom Rules for IFS/noglob Bash Conventions

## Goal

Add custom shellcheck rules that enforce the bash style guide conventions used across Ted's projects. These rules understand the `IFS=$'\n'; set -o noglob` execution model where most shellcheck quoting warnings are false positives, but a specific naming convention (`_` suffix) creates a taint-tracking system for variables that DO need quoting.

## The conventions to enforce

### 1. Taint tracking via `_` suffix

Variables whose values contain IFS characters (newlines) are marked with a trailing underscore: `cmd_`, `oldIfs_`, `content_`. These MUST be quoted when expanded. Non-underscore variables are safe unquoted under IFS/noglob.

Rules:
- **SC9001**: `_`-suffixed variable used unquoted -> error. "Variable $foo_ contains IFS characters and must be quoted."
- **SC9002**: `$(command)` assigned to a non-`_` variable when the command could produce newlines -> warning. "Command substitution assigned to $foo -- use $foo_ if it may contain newlines." (Conservative: flag all command substitutions assigned to non-`_` vars, with an allowlist for known single-line commands like `basename`, `dirname`, `id`, `hostname`, `uname`.)
- **SC9003**: Non-`_` variable quoted unnecessarily -> info/style. "Variable $foo does not need quoting under IFS/noglob." (Only when a shellcheckrc opts into IFS/noglob mode.)

### 2. `*List` suffix

Variables with multi-value data (newline-separated) use `*List` suffix: `groupList`, `hostList`. The `_` and `*List` suffixes are mutually exclusive.

Rules:
- **SC9004**: Variable named with both `_` and `List` -> error. "Suffixes _ and *List are mutually exclusive."

### 3. DI pattern

Injectable globals use `${var:-default}`: `${platform:-detectPlatform}`.

Rules:
- **SC9005**: Lowercase global variable without `${var:-default}` pattern -> info. "Global $platform has no default -- consider DI pattern ${platform:-default}." (This one is aspirational -- may be too noisy. Implement last, evaluate usefulness.)

## Architecture

### Where rules go

`src/ShellCheck/Checks/Custom.hs` -- this file exists specifically for site-specific patches. It exports a `checker` with `perScript` and `perToken` callbacks.

### How to write a check

Pattern from `Commands.hs`:

```haskell
-- Property-based test (name starts with prop_)
prop_checkMyRule1 = verify checkMyRule "var_=$foo; echo $var_"
prop_checkMyRule2 = verifyNot checkMyRule "var_=$foo; echo \"$var_\""

-- The check function
checkMyRule = CommandCheck ... $ \token -> do
    -- pattern match on token AST
    -- use warn/info/style/err to emit comments
    warn (getId token) 9001 "message"
```

Key API (from `AnalyzerLib.hs`):
- `warn id code msg` -- warning (SC code in 2000-2999 range; we use 9000+ for custom)
- `info id code msg` -- informational
- `style id code msg` -- style suggestion
- `err id code msg` -- error
- `perToken` -- called for every AST node; pattern match on constructors from `AST.hs`
- `perScript` -- called once per script; good for whole-file analysis
- `Parameters` -- provides `shellType`, `rootNode`, `tokenPositions`, `cfgAnalysis`

### AST constructors to know

From `src/ShellCheck/AST.hs`:
- `T_DollarBraced` -- `${var}`, `${var:-default}`, etc.
- `T_DollarExpansion` -- `$(command)`
- `T_NormalWord` -- word containing expansions
- `T_DoubleQuoted` -- `"..."`
- `T_Assignment` -- `var=value`
- `T_SingleQuoted` -- `'...'`

To check if a variable expansion is inside quotes, walk up the AST looking for `T_DoubleQuoted` parent.

### Running tests

```bash
# Build
cabal build
# or
stack build

# Run tests (all checks include property tests via QuickCheck)
cabal test
# or
stack test
```

Tests are property-based: `prop_checkFoo = verify checkFoo "script"` returns True if the check fires on that script. `verifyNot` returns True if it does NOT fire.

### SC code range

Upstream uses SC1000-SC2999. Use SC9000-SC9999 for custom rules to avoid conflicts with future upstream codes.

## Implementation sequence

1. **SC9001 first** -- `_`-suffixed variable unquoted. This is the highest-value rule (catches real bugs). Pattern: find `T_DollarBraced` nodes where the variable name ends in `_` and the node is NOT inside a `T_DoubleQuoted` parent.

2. **SC9004** -- mutually exclusive `_`/`*List` suffixes. Trivial regex check on variable names.

3. **SC9002** -- command substitution taint. Find `T_Assignment` where the RHS contains `T_DollarExpansion` and the LHS variable name doesn't end in `_`.

4. **SC9003** -- unnecessary quoting. Inverse of SC9001: non-`_` variable inside `T_DoubleQuoted`. Requires opt-in (only fire when IFS/noglob mode is declared).

5. **SC9005** -- DI pattern. Last, evaluate if useful.

## Activation

These rules should only fire when opted in. Options:
- A new `# shellcheck enable=custom-rules` directive
- A `.shellcheckrc` setting like `enable=custom-rules`
- Always-on in the fork (simplest -- this IS the fork's purpose)

Recommend: always-on in the fork. The fork is purpose-built for these conventions. Users who don't want them use upstream shellcheck.

## Style guide reference

The full bash style guide is at `~/projects/jeeves/programming/bash-style-guide.md`. Key sections:
- Section 5: quoting rules under IFS/noglob
- Section 7: naming conventions (`_` suffix, `*List` suffix)
- Section 14: trap patterns (why SC2064 is safe)

## Building

```bash
# Nix (preferred)
nix-build

# Cabal
cabal build

# Stack
stack setup
stack build
```

## Existing .shellcheckrc disable list

The shared `.shellcheckrc` (at `~/dotfiles/.shellcheckrc`) disables these codes for the IFS/noglob convention:

```
SC2086  SC2046  SC2053  SC1010  SC1090  SC1091  SC2064  SC2015
SC2016  SC2088  SC2206  SC2068  SC2178  SC2229  SC2317  SC2329
SC2154  SC2034  SC2164
```

The custom rules (SC9001-SC9005) replace the blunt SC2086 disable with precise taint-aware checking. Once SC9001 is working, SC2086 can potentially be re-enabled -- the custom rule handles the nuance that SC2086 can't.
