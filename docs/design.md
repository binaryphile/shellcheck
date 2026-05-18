# Design: ShellCheck Custom Check Plugin System

## 1. Plugin System Architecture

### 1.1 CustomCheck Type

```haskell
data CustomCheck = CustomCheck {
    ccChecker     :: Token -> Analysis,
    ccAlwaysOn    :: Bool,
    ccDescription :: CheckDescription
}
```

- `ccChecker`: Runs in the `Analysis` monad (RWS with Parameters as reader). Use `ask` for Parameters.
- `ccAlwaysOn`: `True` = fires without configuration. `False` = needs `enable=` in shellcheckrc or CLI.
- `ccDescription`: Metadata for the optional check system — name, description, positive/negative examples.

### 1.2 Compositor (Custom.hs)

```haskell
checker :: [CustomCheck] -> AnalysisSpec -> Parameters -> Checker
checker loadedPlugins spec _params = Checker {
    perScript = const $ return (),
    perToken  = \t -> mapM_ (\c -> ccChecker c t) activeChecks
  }
  where
    keys = asOptionalChecks spec
    isEnabled c = cdName (ccDescription c) `elem` keys || "all" `elem` keys
    activeChecks = filter (\c -> ccAlwaysOn c || isEnabled c) loadedPlugins

optionalChecks :: [CustomCheck] -> [CheckDescription]
optionalChecks loadedPlugins =
    map ccDescription $ filter (not . ccAlwaysOn) loadedPlugins
```

`ccAlwaysOn` directly drives execution. The compositor is the only place that reads it — plugin modules don't need to know.

### 1.3 Registration Pattern

All custom checks are loaded dynamically at startup as shared library plugins — see section 1.6. The compositor has no built-in checks.

### 1.4 Test Helpers (Base.hs)

```haskell
verify     :: (Token -> Analysis) -> String -> Bool        -- any diagnostic produced
verifyNot  :: (Token -> Analysis) -> String -> Bool        -- no diagnostic
verifyCode :: (Token -> Analysis) -> Integer -> String -> Bool  -- specific SC code
```

These wrap the check into a `Checker` and use `producesComments` from AnalyzerLib — the same mechanism used by ShellSupport.hs tests. No code duplication.

### 1.5 AST Utilities (Base.hs)

Generic utilities needed by any plugin examining variable expansions, quoting, or comment context:

- `getExpansionName :: Token -> Maybe String` — extract variable name from `T_DollarBraced`
- `isInRedirectContext :: Map Id Token -> Token -> Bool` — workaround for `isQuoteFree` not recognizing `T_FdRedirect` in ancestor traversal
- `getDocCommentsBefore :: Parameters -> Token -> [String]` — the contiguous `T_Comment` block immediately preceding a target token within its enclosing body list (strict line-adjacency; blank lines or non-comment siblings terminate the block). Backed by the parser's `attachComments` splice, which inserts `T_Comment` nodes into body lists and drops comments inside command-substitution / heredoc bodies.

**Scaling guard**: If AST utilities grow beyond ~5 functions, extract into `Custom/ASTUtils.hs`.

### 1.6 Dynamic Plugin Loading

External plugins are `.so` files loaded via `dlopen` at startup from `$XDG_DATA_HOME/shellcheck/plugins/`.

**Architecture**: `Loader.hs` scans the plugin directory, loads each `.so` with `RTLD_NOW | RTLD_GLOBAL`, verifies API version via `foreign import ccall "dynamic"`, extracts `[CustomCheck]` via `StablePtr`, and returns the merged list. `RTLD_GLOBAL` ensures plugin symbols are available for subsequently loaded plugins.

**Threading**: `[CustomCheck]` is threaded as a parameter through the call chain:
```
shellcheck.hs:  loadPlugins dir        -- IO boundary
                checkScript plugins sys spec
Checker.hs:     analyzeScript plugins (spec root)
Analyzer.hs:    Custom.checker plugins spec params
Custom.hs:      plugins  -- all checks come from plugins
```

Circular import (`AnalyzerLib` imports `Interface`, `CustomCheck` needs `Analysis` from `AnalyzerLib`) prevents embedding `[CustomCheck]` in `AnalysisSpec`. Parameter threading is the correct solution.

**Resource lifecycle**:
- `dlopen` fails: exception caught, no handle opened
- Version/symbol check fails: dl stays open (GHC may have run init code during `dlopen` -- closing would invalidate RTS references). Small handle leak, acceptable.
- Load succeeds: dl stays open (closures reference code in `.so`), `StablePtr` freed after `deRefStablePtr`

**Plugin ABI**: Plugins must export:
- `plugin_api_version :: IO CInt` -- must match host's `pluginApiVersion`
- `plugin_init :: IO (StablePtr [CustomCheck])` -- returns the check list

**RTS sharing**: Host uses `-rdynamic` to expose RTS symbols. Plugin must NOT use `-flink-rts`.

### 1.7 Capabilities

`Custom.hs` is ShellCheck's extension point for checks loaded outside the core distribution. Dynamic plugin loading enables external checks to:

- Use `--enable=` and `--list-optional` via `CheckDescription` metadata (the same mechanism as built-in optional checks)
- Load at startup from shared libraries without modifying ShellCheck source
- Fail gracefully — bad plugins produce warnings, never crashes
- Work cross-platform (dlopen on Linux/macOS, stub on Windows)

## 2. Constraints

### 2.1 Performance Model

Complexity: `O(tokens * checks)`. Every check runs on every AST token via `doAnalysis`. Checks that don't match a token's constructor return `()` immediately (pattern-match short-circuit). Acceptable for ~4-10 custom checks on scripts of ~1000-10000 tokens. Refactor to token-constructor dispatch if plugin count exceeds ~20.

### 2.2 Failure Model

Plugins run in-process. An uncaught exception or incomplete pattern in a plugin terminates ShellCheck. Mitigation: plugins should be total — no `error`, no incomplete pattern matches, no exceptions. `prop_` tests exercise all code paths; GHC `-Wall` catches incomplete patterns at compile time.

### 2.3 Contract Stability

Plugin ABI is tied to ShellCheck's internal types (`Token`, `Parameters`, `Analysis`) and to AnalyzerLib utility functions. `pluginApiVersion` is checked at load and bumped when those types change incompatibly; plugins target a specific ShellCheck library version and rebuild on upgrade.

Plugin API stability is best-effort; `pluginApiVersion` bumps signal any incompatible change. The exports below are the plugin system's public surface:

| Export | Notes |
|---|---|
| `pluginApiVersion` | Integer version. Bumped on incompatible API changes. |
| `CustomCheck(..)` | Registration type. Fields may gain new optional fields (with defaults) but existing fields won't change type. |
| `verify`, `verifyNot`, `verifyCode` | Test helpers. |
| `getExpansionName` | Returns variable name from `T_DollarBraced`. |
| `isInRedirectContext` | Provisional; supersedable if `isQuoteFree` learns about `T_FdRedirect`. |
| `getDocCommentsBefore` | Contiguous `T_Comment` block immediately preceding a target token (strict line-adjacency). Backed by parser splice (added with `pluginApiVersion = 2`). |
| `ask`, `when` | Re-exported from `Control.Monad.RWS` and `Control.Monad` for plugin convenience. |

Plugin modules should depend on `Base.hs` exports plus `AnalyzerLib` (for the analysis monad and check-emitting functions). Internal functions (like `getCodes`) are not exported and may change freely.

**Versioning**: `pluginApiVersion` (currently 2) is checked at load time. Bump it when the `CustomCheck` type or `Base.hs` exports change incompatibly. Plugins built against an older version fail to load with a clear version mismatch message rather than crashing.

### 2.4 Dynamic Loading Constraints

Build requirements for external plugins loaded via `dlopen`:

- Plugin MUST be built with the same GHC version as the shellcheck binary
- Plugin MUST link against the same ShellCheck library package (same nix derivation / same GHC unit ID)
- Plugin MUST NOT use `-flink-rts` (shares host's RTS)
- Plugin MUST export `plugin_api_version :: IO CInt` and `plugin_init :: IO (StablePtr [CustomCheck])`
- Host MUST use `-rdynamic` to expose RTS symbols to plugins
- No `dlclose` after successful `dlopen` -- GHC closures reference code in the `.so`

### 2.5 Plugin Isolation

Plugins share the `Analysis` monad. Multiple plugins may emit diagnostics on the same token; ShellCheck's `nub` in Analyzer.hs deduplicates only identical comments (different SC codes are not deduplicated).

Plugins cannot conflict at the suppression level — `# shellcheck disable=SCxxxx` only affects that code. Each plugin's SC code is independent.
