# Set up an existing project and reuse workspaces

For full window/workspace compositions with responsive layout trees, see the
[shared stock/user configuration guide](workspace_configuration.md). The portable
template workflow below remains supported and deliberately excludes custom trees.

**Default-layout recovery added 2026-10-18:** use **Restore default layout: Overview /
Timing / Testing (hide extras)** to show the built-in membership, hide accidental
extras, restore geometry, clear zoom and select Fit in one acknowledged operation.
Unlike additive Apply/Reset, this also repairs visibility; pins, contexts and
appearance remain. See [the recovery guide](default_layout_restore.md).

Integrated with current `oxcaml`, 2026-10-17. This slice delivers an existing-project
initializer, portable workspace templates and persistent client presentation choices.
Configuration-location migration (WB-049) and new-project creation (WB-051/078)
shipped after that slice. Multi-monitor UX is separate.

Templates retain preset composition, bootstrap is atomic, and header controls
persist when changed through the palette. Same-session reconnect preserves the
local investigation without applying stale responses.

## Install

Follow [Install and open Silver](../README.md#install-and-open-silver). The
commands below use the installed `ag`, `silver-init`, and `silver-workspace`. The former
`hardcaml-workbench-init` and `hardcaml-workbench-workspace` names remain available
for existing scripts.

## Open a project before configuring hardware

From a checkout with `dune-project`, open its absolute root and use the daemon's
existing execution environment:

```sh
ag --plain --project-root /absolute/path/to/project --environment inherited
ag --project-root /absolute/path/to/project --environment inherited
```

The plain command reports the selected root, environment, and generic Dune
workspace. The interactive command opens the workspace; press **Space c c** for
the command palette. Generic views do not require a hardware manifest, driver,
or ASIC provider. Use `--discover-project` for the nearest qualifying ancestor
of the client's current directory, or `--environment opam:SWITCH` to select a
switch installed on the daemon host.

## Attach over SSH or tmux

If the client runs inside SSH, run it (optionally inside tmux) on the SSH host
and attach to the daemon's loopback endpoint there. If the client runs on your
laptop, forward the remote daemon's loopback port and attach locally:

```sh
ssh -N -L 127.0.0.1:18080:127.0.0.1:8080 DAEMON_HOST
# In a second local terminal; use the actual daemon port above.
hardcaml-workbench --connect http://127.0.0.1:18080 \
  --project-root /absolute/path/on/daemon/host --environment inherited
```

- `--connect` attaches only. If it fails, check the daemon and port forward;
  the client does not start a replacement daemon. Use an explicit absolute
  daemon-host project root for a forwarded connection instead of discovering
  it from your laptop's current directory.
- Project execution, `inherited`/opam selection, and provider paths belong to
  the **daemon host**. Configured external artifact viewers and their private
  exports belong to the **terminal client host**. An SSH-host client launches
  its viewer there; a local client using a forward launches its viewer locally.
  Pass an absolute executable path on the client host when enabling a viewer.
- **F8** shows connection details; **[** and **]** scroll, **r** reconnects
  there, and **F8** returns. Automatic reconnect reopens the same project and
  environment without resubmitting jobs. Reopening the client against the same
  daemon does not reload cached ASIC provider configuration.
- In an evidence explorer, **Esc** backs out one level (filter, detail, then
  explorer); **Space c x** closes the focused inspector after leaving text
  input. Inspector **r** refreshes evidence. In tmux, detach and reattach to
  keep the same client; if standalone Escape feels delayed, see
  [the tmux Escape tradeoff](asic_evidence_inspection.md#escape-responsiveness-in-tmux--2026-10-16-followup).
  Workbench does not change your tmux settings.
- **Refresh hardware integration** explicitly reloads the manifest/project
  driver. **Discover ASIC flows and runs** queries the already loaded provider.
  Neither installs or rebuilds a provider; after changing ASIC provider
  configuration, start a fresh daemon session when it is safe to do so.

## Initialize an existing project

Open the Dune project locally with `ag`. Press **Space c c** and choose
**Set up project…**. To start a design, choose **Add ASIC starter…**, name it,
and review the proposed files before applying. To connect a design that already
exists, choose **Import existing ASIC design…** and enter the path to its already-built
design CLI (absolute or relative to the project root). **Esc** cancels; **Enter**
writes `.silver/silver-asic.sexp`. Neither opening the form nor
saving it builds or runs the design. Existing ASIC configuration is never replaced;
no generic manifest is required. The configuration uses the selected environment's
provider, `<root>/_flow_tools`, and `<root>/_flow_results/workbench/asic`. Reopen in
a fresh daemon session, then choose **Discover ASIC flows and runs** when ready.

For generic build/test aliases or a hardware manifest driver, use the separate initializer:

```sh
silver-init --root /absolute/path/to/project --dry-run
silver-init --root /absolute/path/to/project
```

The explicit root must directly contain a regular `dune-project` file, matching
the ordinary project opener. A subdirectory with only `dune` is rejected. The project
name defaults to its directory name. Optional flags are `--project-name NAME`,
`--driver ./path/to/driver.exe`, `--build-alias @all` and `--test-alias @runtest`.
Driver and alias syntax is validated through the existing manifest parser; targets
need not exist yet. The initializer performs no build, driver or provider execution.

The only published file is `.silver/silver.sexp`, in the existing version-1
format. Publication is atomic and refuses any existing destination, including a
symlink. It never replaces an existing configuration or edits build/VCS files.
Temporary files are cleaned on ordinary failure. Filesystems must support local
hard links for no-replace publication; unsupported publication fails explicitly.

Open the initialized root with the ordinary terminal `--project-root` and
`--environment` flags. This slice does not change root discovery, manifest
precedence or configuration storage location.

If the project is already open, opening it again reuses the daemon session. Use
explicit integration refresh to reload the manifest:

```sh
ag --plain --project-root /absolute/path/to/project \
  --environment inherited --refresh-integration --wait
```

A valid driverless manifest reload succeeds with `Refresh_integration.Payload.job
= None`; no job is invented. With a declared driver, `Some job` identifies the
normal supervised discovery operation. Refreshing the generic manifest does not
claim to reload ASIC or simulation provider configuration through a unified API.

## Workspace templates

Templates contain a version, workspace name, optional stable preset ID and ordered
views with kind, hidden state and requested geometry. They exclude run selections, pins, session/context/
tile IDs, zoom and appearance. Import and clone create fresh view identities in a
new workspace linked to Main; every tile follows that context. A clone copies the
layout, not the source investigation's selected run or independent context.

Preset identity preserves the registered composition and presentation policy even
after renaming the workspace. It is not a frozen copy of the compiled layout tree.
Unknown IDs remain unknown; older version-1 templates without `preset` are custom.
Import never reapplies a preset to fill missing tiles or reset geometry. Custom and
unknown-preset workspaces support generic Fit; Requested tile sizes remains the
separate shelf mode. The portable envelope is narrower than arbitrary live state:
names/kinds are at most 256 bytes, geometry is bounded and there are at most 1000
views. Invalid exports fail rather than truncate; clone `-name` is validated after
the override replaces the source name.

Start Workbench and open the project first. Use its daemon endpoint and project ID
(shown by the plain client/project snapshot), then list registry IDs:

```sh
silver-workspace list \
  -endpoint http://127.0.0.1:8080 -project PROJECT_ID

silver-workspace starter generic > generic.sexp
silver-workspace import \
  -endpoint http://127.0.0.1:8080 -project PROJECT_ID \
  -window WINDOW_ID -name "Project work" generic.sexp

silver-workspace export \
  -endpoint http://127.0.0.1:8080 -project PROJECT_ID WORKSPACE_ID > layout.sexp
silver-workspace clone \
  -endpoint http://127.0.0.1:8080 -project PROJECT_ID \
  -window WINDOW_ID -name "Layout copy" WORKSPACE_ID
```

`starter generic` supplies project, execution, project-test and log views.
`starter asic` supplies selection, ASIC controls, synthesis and stage/evidence
views. Both are offline operations. Imported workspaces become available through
the terminal's existing workspace-switch palette after refresh.

`starter overview`, `starter timing` and `starter testing` export the same OCaml
definitions used by the client and synthetic demo, including preset identity.
Testing includes the structured simulation tile; importing it does not discover or
run a simulation provider.

Import/clone each use one atomic compare-and-swap registry mutation. Conflicts are
reported rather than retried against a changed context. Invalid templates cannot
leave a partially created workspace. Input is bounded to 1 MiB and 1000 views;
unknown view kinds remain portable identifiers, not executable extensions.
Requested geometry still uses the existing shelf/Fit renderer, not free placement.

Fresh registries explicitly mark defaults as uninitialized. The first interactive
refresh submits one atomic, idempotent bootstrap operation for Overview/Timing;
CLI imports may safely happen first. Concurrent clients cannot partially populate
the defaults or repeat the bootstrap. The daemon persists completion with the
tiles. Legacy saved snapshots without the marker are treated as initialized,
including sparse revision-zero user arrangements. Bootstrap leaves imports and
explicit changes to existing tile geometry, hidden state and bindings intact.

Templates can be checked into a project's chosen location; personal session state
remains in the daemon store. No automatic template discovery or TUI file picker is
introduced. Rebuild daemon and clients together to use the new template mutation;
legacy stored workspace snapshots remain readable. Upgrade daemon, terminal and
workspace CLI together: live protocol records and operations have changed.

## Persistent presentation preferences

The existing palette's appearance preset, color scheme/intensity, icon, density, layout-mode,
chrome, tile-header and tile-appearance actions now save their explicit choices. Normal terminal
exit waits for queued writes. Preferences use a separate versioned
`presentation-<digest>.sexp` under
`${XDG_STATE_HOME:-$HOME/.local/state}/silver/terminal/`, keyed by
canonical project root and execution environment.

Schema version 2 (WB-019) adds independent `main_hints` and `palette_hints` choices
for the main-window and command-palette bottom hints, toggled by Space c h / Space c p
(palette: "hints"). Version 1 files still load with both visible; the global chrome
toggle is unchanged and still hides the footer regardless of these choices.

Schema version 3 (WB-048) adds a `tile_appearance` list holding the remaining explicit
per-tile appearance overrides: title, binding badge, hints, frame, padding and
run-selector row count. Run reference and freshness describe run selection/data rather
than appearance and stay session-local. Version 1 and 2 files still load, and every
tile appearance field they lack inherits. A version 3 file must carry the list; each
entry must be non-empty and unique per tile, with non-negative padding and at least one
row. Unknown versions and mismatched structure are rejected like other malformed files.

Tile-header and tile-appearance choices additionally match session, tile, workspace and
view kind. Replacement sessions do not inherit stale tile preferences. Focus, scroll, filters,
active workspace, run selection and provider data are not persisted in this file.
Malformed or oversized files fall back to defaults with a visible notice and are
left untouched until a later explicit preference change saves a replacement.
Concurrent clients use last-writer-wins files; preferences do not synchronize live.

Among the per-tile presentation fields, every explicit override except run reference and
freshness persists; absent fields inherit. Reset removes the stored overrides and
restores inheritance across restart. Initial restoration is consumed once, so polling never
replays an old saved choice over a new toggle/reset. Same-daemon/project reconnect
retains local browsing state while advancing request fences. Replaced sessions and
removed/moved/retyped tile identities discard stale local state; these navigation
values are still not persisted across client process restart.

## Current verification — 2026-10-17

Normal full build, repository-wide format/lint and full tests passed using
`scripts/with-switch.sh` serially at `-j 20`. This is a shared pool, not a per-agent
allowance: implementation used three separate build directories at six jobs each.

- FS3 native HTTP/CLI/PTY: **140 checks**, including concurrent bootstrap after
  pre-TUI imports, renamed-preset roundtrips, actual header toggle/reset through
  polling and restart, and manifest-only reload without jobs/tools.
  `/tmp/opencode/fs3-adoption-n5sxf42_/result.json`
- Installed initializer/client handoff from an unrelated directory, private prefix
  and HOME/XDG state: `/tmp/opencode/fs3-installed-setup-evidence-20261017/`.
- Checklist launch: **61 checks**, `/tmp/opencode/checklist-workflow-371b032839a6/`.
- Launch/stage lifecycle: **27 checks**, `/tmp/opencode/launch-stage-consistency-3b465919425f/`.
- FS2 real Cyclesim/native HTTP/PTY: `/tmp/opencode/fs2-native-rbxswj1k/`.
- Interrupt/restoration: **5/5**, `/tmp/opencode/workbench-terminal-interrupt-w_h5134h/`.

Reconnect identity and delayed-response fences have reducer coverage; the native
FS3 script proves process restart, not an exhaustive network-disconnection matrix.
ASIC regression producer execution is synthetic; real evidence reads and planning
are read-only. No real EDA, live daemon restarts or canonical evidence edits occurred.

```sh
scripts/with-switch.sh dune build -j 20 @fmt @lint
scripts/with-switch.sh dune runtest -j 20
scripts/with-switch.sh dune build -j 20
python3 -B scripts/test-project-adoption.py
```

The native script accepts explicit `--daemon`, `--terminal`, `--setup` and
`--workspace-cli` paths and performs no builds. Allow 600 seconds for PTY work.

Normal binaries and persistent real-demo copies have been refreshed. Restart the
matching daemon/client after active jobs finish; no reseed is necessary. The binary
receipt is recorded in the integration plan. Live processes were left running.

## Historical worktree verification — 2026-10-15

The original full build, `@lint`, changed-file formatting and `dune runtest -j 10`
passed. Its repository-wide `@fmt` reported inherited formatting differences in
`backend/asic_evidence_file.ml{,i}`, `backend/asic_public.ml`,
`backend/asic_service.ml`, `backend/test/asic/test_asic.ml`,
`terminal/synthesis_view.ml{,i}` and `terminal/terminal_result_view.ml`.
The report is `/tmp/opencode/fs3-format-check.log`.
Tests cover initializer validation,
no-clobber publication races, template identity/provenance stripping and atomic
failure, and fresh-process presentation persistence/failure handling.

```sh
scripts/with-switch.sh dune build -j 10 @fmt @lint
scripts/with-switch.sh dune runtest -j 10
python3 scripts/test-project-adoption.py
```

The integration script uses private state and a strict metadata-only Dune fixture:
actual initializer and template executables, a real HTTP daemon, exact registry
restoration across daemon restart, rejected malformed/stale operations, and actual
PTY palette selection and presentation restoration in a new terminal process.
It records transcripts and a `result.json` under `/tmp/opencode/fs3-adoption-*`.
Final passing run: `/tmp/opencode/fs3-adoption-ry427qxc/result.json`.
The existing five-mode terminal interrupt regression also passes:
`/tmp/opencode/workbench-terminal-interrupt-sfrzonk0/`.
It does not claim real tool runs, installed-package acceptance or full multi-monitor
convergence/responsiveness acceptance.
