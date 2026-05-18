# Use Cases: ShellCheck Custom Check Plugin System

Cockburn-shape use cases for the plugin system documented in
[design.md](design.md). The plugin system extends ShellCheck with
out-of-tree checks loaded at startup as shared libraries; the use
cases below capture WHAT the system does from three stakeholder
perspectives. Mechanism (HOW) lives in design.md; this file is the
behavioral contract.

## Stakeholders

| Stakeholder | Interest |
|---|---|
| **Plugin Author** (PA) | Build a `.so` that adds new SC9xxx checks without forking ShellCheck. Wants a stable API, clear build constraints, ability to test checks in isolation. |
| **End-user** (EU) | Get extra warnings from third-party convention checks while running `shellcheck` as usual. Wants opt-in, predictable output, suppression via `# shellcheck disable=`. |
| **Host Maintainer** (HM) | Evolve ShellCheck's parser and analysis types without silently breaking out-of-tree plugins. Wants compile-time and load-time signals that a plugin is incompatible. |

The plugin system serves a fourth interest implicitly — **ShellCheck
distribution maintainers** retain a small, single-purpose host binary;
domain-specific rule sets live in their own repos with their own release
cadence.

---

## UC-1: Author a plugin

| Field | Value |
|---|---|
| **Scope** | The ShellCheck fork's plugin API surface (`Base.hs`, `Loader.hs`, the dynamic-loading ABI). |
| **Level** | User-goal (a complete build-and-ship workflow). |
| **Primary Actor** | Plugin Author. |
| **Other Stakeholders** | Host Maintainer (cares that the author depends only on documented exports); End-user (cares that the resulting `.so` is loadable in their shellcheck install). |

### Preconditions

- A nix flake or cabal project consuming `binaryphile/shellcheck` as a library input.
- GHC version matching the host's GHC (enforced by sharing the flake input).
- A plugin source module that imports `ShellCheck.Checks.Custom.Base`.

### Minimal Guarantee

If the author follows the documented build constraints (dynamic linking
flags, same GHC, no `-flink-rts`, exports `plugin_api_version` and
`plugin_init`), the produced `.so` either loads successfully OR fails
at load time with a specific error message (version mismatch, missing
symbol, RTS conflict). It does not silently corrupt host state.

### Success Guarantee (Postconditions)

- A `.so` file exists at a path the author chose.
- ShellCheck, run with `--plugin-dir <path>`, logs
  `Loaded plugin: <name>.so (N check(s))` on stderr.
- Each `CustomCheck` the plugin exports appears in `shellcheck
  --list-optional` (for `ccAlwaysOn = False` checks) or fires on every
  applicable token (for `ccAlwaysOn = True`).
- Per-check `prop_` tests run via `cabal test` (or the plugin's test
  driver) and exercise both positive and negative fixtures.

### Trigger

The author has a convention or pattern they want to enforce across
many scripts and has decided the rule is too specific for upstream
ShellCheck.

### Main Success Scenario

1. Author imports `ShellCheck.Checks.Custom.Base` and writes a
   `Token -> Analysis` function that pattern-matches the AST shape
   they care about and calls `warn` / `err` / `style` / `info` with
   an SC9xxx code.
2. Author wraps the function in a `CustomCheck` value with
   `ccAlwaysOn`, `ccDescription`, and `cdName` populated.
3. Author writes inline `prop_` tests using `verify` / `verifyNot` /
   `verifyCode` from `Base.hs` covering positive and negative fixtures.
4. Author adds a `Plugin.hs` module that exports
   `foreign export ccall plugin_api_version :: IO CInt` and
   `foreign export ccall plugin_init :: IO (StablePtr [CustomCheck])`,
   with `plugin_init` returning `newStablePtr` over the check list.
5. Author builds the module with `ghc -dynamic -shared -fPIC -no-hs-main`
   (or a nix flake derivation that does the same).
6. Author runs `nm -D <plugin>.so | grep plugin_` and confirms
   `plugin_api_version` and `plugin_init` are exported.
7. Author runs `shellcheck --plugin-dir <dir> -f gcc <fixture>` and sees
   the new SC9xxx codes emit.

### Extensions

- **2a.** Author needs the parent token chain → use `getPath
  (parentMap params)` (see `docs/plugins.md` "Walking the parent
  chain").
- **2b.** Author needs the contiguous comment block above a token →
  use `getDocCommentsBefore params t` (see `docs/plugins.md`
  "Reading comments").
- **3a.** Test framework needs the actual SC code asserted, not just
  "any warning" → use `verifyCode` instead of `verify`.
- **5a.** `nix build` fails with "missing module ShellCheck.X" →
  flake input pin is stale; bump `inputs.shellcheck.url` to the
  host commit that introduced the export.
- **7a.** Plugin loads but emits no warnings on a fixture that
  should violate the rule → check `--enable=<cdName>` is passed (or
  set `ccAlwaysOn = True`); check `cdName` matches the `--enable`
  argument.
- **7b.** Plugin fails to load with "API version mismatch" → host
  bumped `pluginApiVersion`; rebuild plugin against the new host
  pin (see UC-3 for the maintainer side).
- **7c.** Plugin fails to load with "undefined symbol" → plugin
  used `-flink-rts` (forbidden — share host's RTS) or built against
  a different GHC than the host.

---

## UC-2: Run shellcheck with plugin checks

| Field | Value |
|---|---|
| **Scope** | The ShellCheck binary at invocation time. |
| **Level** | User-goal (one shellcheck invocation that produces plugin-sourced warnings). |
| **Primary Actor** | End-user running shellcheck on their script(s). |
| **Other Stakeholders** | Plugin Author (cares that their `.so` is reachable and the warnings emit correctly); Host Maintainer (cares that plugin warnings interleave correctly with built-in SC1xxx-SC3xxx). |

### Preconditions

- A built `.so` file exists at a known path.
- Shellcheck binary exists and was built with `-rdynamic`.
- The user knows the `cdName` of each optional plugin check they want
  enabled (or is willing to use `--enable=all`).

### Minimal Guarantee

If a plugin fails to load (bad ABI, missing symbol, wrong API version),
shellcheck logs a clear error to stderr and continues with all other
plugins and all built-in checks. A bad plugin does not crash
shellcheck; it does not silently disable other plugins.

### Success Guarantee (Postconditions)

- Stderr log shows `Loaded plugin: <name>.so (N check(s))` for each
  loaded plugin.
- Stdout/stderr (per chosen `-f` formatter) shows SC9xxx warnings
  for every violation in the script that matches an active plugin
  check.
- `# shellcheck disable=SC9xxx` directives in the script suppress
  the matching plugin warning the same way they suppress built-in
  warnings.
- Exit code reflects the highest-severity warning emitted (plugin
  warnings count toward the exit code on the same severity scale).

### Trigger

The user runs `shellcheck` on a script and wants extra warnings from
a third-party convention check set they've installed.

### Main Success Scenario

1. User copies (or symlinks) `<plugin>.so` into
   `$XDG_DATA_HOME/shellcheck/plugins/` (or passes `--plugin-dir
   <dir>` on the command line).
2. User runs `shellcheck --enable=<cdName> <script>` (or sets
   `enable=<cdName>` in `~/.shellcheckrc` for persistent opt-in).
3. Shellcheck enumerates plugin files, `dlopen`s each, verifies
   API version, calls `plugin_init`, and merges the returned
   `[CustomCheck]` lists.
4. Shellcheck logs `Loaded plugin: <name>.so (N check(s))` per
   loaded plugin.
5. Shellcheck parses the script and runs every active check (built-in
   + always-on plugin + enabled-optional plugin) over the AST.
6. Diagnostics emit in source order via the chosen formatter
   (`-f gcc`, `-f tty`, `-f json1`, etc.).

### Extensions

- **1a.** `$XDG_DATA_HOME` unset → shellcheck falls back to
  `~/.local/share/shellcheck/plugins/`.
- **2a.** User passes `--enable=all` instead of named checks → every
  `ccAlwaysOn = False` plugin check activates.
- **2b.** User omits `--enable=` and the desired checks have
  `ccAlwaysOn = False` → checks are silent; user sees them in
  `shellcheck --list-optional` to learn their names.
- **3a.** Plugin file is not a valid ELF/Mach-O → `dlopen` returns
  null; shellcheck logs `Failed to load plugin <path>: <reason>` to
  stderr and continues with the rest.
- **3b.** Plugin's `plugin_api_version` doesn't match host's
  `pluginApiVersion` → shellcheck logs
  `Plugin <path> reports API version N, expected M` and skips the
  plugin.
- **3c.** Plugin's `plugin_init` throws or returns invalid pointer →
  shellcheck logs the exception and skips the plugin.
- **6a.** Two plugins emit warnings with the same `(severity, code,
  position, message)` → deduplicated via `nub` in Analyzer.hs.
- **6b.** Two plugins emit warnings with the same SC code but
  different positions or messages → both emit independently; SC code
  collision is the plugin authors' coordination problem, not a host
  issue.

---

## UC-3: Evolve the plugin API

| Field | Value |
|---|---|
| **Scope** | The plugin-visible API surface (`Base.hs` exports, `Token` constructors, `Parameters` fields, the dynamic-loading ABI). |
| **Level** | User-goal (a complete host-side API change with downstream rebuild path). |
| **Primary Actor** | Host Maintainer of the ShellCheck fork. |
| **Other Stakeholders** | Plugin Author (must rebuild against the new API on incompatible changes); End-user (will see clear load-time errors rather than runtime crashes when running a stale plugin). |

### Preconditions

- Host has a working build (cabal/nix) before the change.
- Existing plugins build green against the current `pluginApiVersion`.
- Out-of-tree plugins exist and are discoverable via era / docs / git
  forks (so the maintainer can warn their authors).

### Minimal Guarantee

A plugin built against an older `pluginApiVersion` fails to load with
a specific version-mismatch message rather than loading and crashing
on the first unfamiliar AST constructor, missing symbol, or changed
field layout.

### Success Guarantee (Postconditions)

- `pluginApiVersion` integer in `Base.hs` is incremented.
- `docs/design.md` §2.3 Versioning paragraph reflects the new
  current version.
- `docs/design.md` §2.3 Contract Stability table lists any new or
  removed exports.
- If the change is plugin-visible behavior (not just signature),
  `docs/plugins.md` "Common AST Patterns" gains or updates the
  relevant subsection.
- Existing plugins in trusted forks (e.g.,
  `shellcheck-convention-plugin`) are rebuilt and re-pinned against
  the new commit before the cycle closes.

### Trigger

The maintainer needs to change a `Token` constructor's shape, add or
remove a `Base.hs` export, or change a public type's signature in a
way that pre-existing plugins cannot transparently absorb.

### Main Success Scenario

1. Maintainer changes the type, constructor, or export in
   `src/ShellCheck/AST.hs`, `Base.hs`, `AnalyzerLib.hs`, or
   `Interface.hs`.
2. Maintainer increments `pluginApiVersion` in
   `src/ShellCheck/Checks/Custom/Base.hs`.
3. Maintainer updates `docs/design.md` §2.3 (Versioning + Contract
   Stability table) and, if applicable, `docs/plugins.md` "Common AST
   Patterns".
4. Maintainer rebuilds known downstream plugins against the new host
   commit; verifies each `.so` loads with `Loaded plugin: ... (N
   check(s))`.
5. Maintainer commits and pushes the host change; tags the commit so
   plugin authors can pin to it.
6. Plugin authors bump their flake inputs to the new host commit and
   rebuild.

### Extensions

- **1a.** The change is plugin-visible but compatible (e.g., new
  optional field on `CheckDescription` with a default) → no version
  bump needed; document the new field in `docs/design.md` §1.x and
  `docs/plugins.md`.
- **2a.** Maintainer forgets to bump `pluginApiVersion` → old plugins
  load successfully but may crash on the first unfamiliar AST node;
  this is the failure mode the version bump exists to prevent.
- **4a.** A downstream plugin fails to build → either the change is
  more invasive than the maintainer realized (revisit scope), or the
  plugin's source needs migration (publish a short migration note in
  the host commit message).
- **6a.** Plugin authors don't rebuild → their pre-rebuild `.so` files
  fail to load with the version-mismatch message and the user sees
  the failure on next `shellcheck` invocation; no silent breakage.

---

## Cross-UC invariants

- **Suppression is by SC code, not by source.** `# shellcheck
  disable=SC9001` suppresses an SC9001 warning regardless of whether
  the originating check is built-in or plugin-loaded.
- **Plugin warnings interleave with built-in warnings** in source-line
  order at the formatter layer. Plugin authors do not need to think
  about output ordering.
- **`pluginApiVersion` is the single contract gate.** Any incompatible
  change to the surface listed in design.md §2.3 must bump it; no
  other versioning surface exists.
