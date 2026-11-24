# Testing catalog and cooperative investigation

The Testing workspace exposes catalog, attempts, cases, result detail, artifacts
and logs as coordinated panes. It runs the project's tests through its configured
provider. To connect your own project, see
[simulation provider setup](simulation_setup.md).

## Open it in the real example

For fresh runs, see
[Configure the ASIC example simulation suites](project_workflows.md#configure-the-asic-example-simulation-suites).
The current catalog includes `controlled-fifo` and **Memory workloads**
(`memory-workloads`). For the fixed memory cases and seed, see
[Run the example workload](workloads.md#run-the-example-workload).

1. Open **Space c c → Switch to Testing**.
2. Tab to **simulation-catalog**. Silver loads the configured project's suites
   in the background after opening it, even if you start in Overview.
3. Choose the suite and check the cases you want. With **Simulation Catalog**
   focused, press **Shift+R** to launch one attempt immediately with the suite's
   displayed seed and parameters. These start at the provider's defaults. Use
   **`e`** to edit and save the catalog settings without starting a run.
4. To change inputs for one attempt, press **Enter** instead. Edit cases, seed
   and parameters in the form, then confirm to launch.

Reconnecting to the same daemon reuses its catalog. A fresh daemon discovers
again. If the provider failed, Silver shows the error rather than repeatedly
running it; **d** retries after you fix it. Clients attached to an older daemon
without automatic discovery can still use **d**.

From the global palette (`Space c c`), type `test suites` or `verification`
to open the suite picker. With a suite selected in the active Testing workspace,
`test` opens the launch form for its selected cases. If there is no current
suite, `test` opens the picker instead.

To adopt the stock arrangement in an existing Testing workspace, open **Space c c**
and choose **Restore default layout: Testing (hide extras)**. This hides extra
tiles, including an existing Project Tests tile, without deleting them or their
history. **Apply default layout (add missing tiles)** keeps extras visible.

## Layout and selection

At ordinary terminal sizes, history is on the left and investigation on the right:

```text
history             investigation
                    ┌────────────────────┬───────────────────┐
session             │ catalog            │ simulation detail │
simulation attempts ├────────────────────┼───────────────────┤
                    │ cases              │ artifacts         │
execution           ├────────────────────┴───────────────────┤
                    │ selected attempt's logs                │
                    └────────────────────────────────────────┘
```

Use **Simulation Attempts** to pick a run; Cases, Detail, Artifacts and Logs
follow that selection. Use **Execution** for the broader job history, including
suite discovery, simulation runs, and generic project commands. Selecting a job
there does not change the simulation attempt you are investigating.

- **Simulation Catalog** is for the next run: choose a suite and cases, then
  review the launch form. Browsing the catalog does not retarget Detail.
- **Simulation Detail** follows the selected **Simulation Attempts** row. Suite,
  seed and parameters are the inputs captured for that attempt. Case outcomes
  and diagnostics are results from that same attempt. Selecting an artifact adds
  its identity, availability, digest, media type and size. Size uses decimal
  bytes (`1.25 MB` = 1,250,000 bytes); `unknown` means no size was reported.
- **Simulation Cases** lines up case names and results. **Simulation Artifacts**
  lines up artifact names, their owning case (or `suite`), and availability so
  you can compare rows down each column.
- **Project Tests** is an optional filtered view of jobs from **Run project tests**
  (the project's Dune test alias or configured Bazel test label). Those jobs are already visible in Execution;
  use **Space c c → Add project-tests tile** if you want a dedicated view, or
  **Restore project-tests …** if the old tile is hidden.

- The six panes share one **client/workspace-local** investigation and one polling
  stream. A second Testing workspace/client has its own selection.
- Focus and scrolling belong to each tile. Catalog/attempt/case/artifact cursors
  remain visible as lists grow; manual scroll pauses cursor-follow until navigation.
- Selecting another case clears the old artifact selection. Selecting an artifact
  identifies its owning case when supplied. Attempt changes invalidate old detail.
- Same-session reconnect preserves appropriate browsing while fencing pending
  responses. Replacement sessions/workspace identities do not inherit stale state.
- Generic project tests remain process results, not structured case counts or ASIC
  acceptance. The legacy standalone **simulation** tile still works independently.

## Controls

| Focus | Key/action | Effect |
| --- | --- | --- |
| Palette | `test` | Review the active Testing suite's selected cases in the launch form, or open the suite chooser if there is no current suite. Only explicit confirmation launches an attempt. |
| Palette | `test suites` or `verification` | Browse and select suites in Testing without launching. |
| Any simulation pane | `d` | Explicitly discover/refresh suites; never implied by rendering |
| Catalog | `n` / `p` | Choose next/previous declared suite |
| Catalog | `j` / `k`, arrows | Browse cases without changing attempt investigation |
| Catalog | `x` | Toggle the current case in the explicit subset |
| Catalog | `a` | Explicitly select all currently declared cases |
| Catalog | `/`, then text; Enter/Esc | Edit/finish a case filter; matching never launches work |
| Catalog | `u` | Accept current refreshed discovery/defaults after reviewing changes |
| Catalog | `R` (Shift+R) | Run the current suite's checked cases immediately with the displayed seed and parameters. The filter only changes which cases you see. |
| Catalog | `e` | Edit and save inputs for subsequent runs of the selected suite without launching an attempt. |
| Catalog | Enter or `r` | Review the selected suite and cases; edit seed or parameters for this run before confirming. |
| Attempts | `j` / `k`, arrows | Select an exact retained attempt and observe its detail |
| Cases | `j` / `k`, arrows | Select a case for shared investigation |
| Artifacts | `j` / `k`, arrows | Select an exact artifact; list explicitly includes all cases |
| Artifacts | `e` / `v` | Export verified bytes / open configured external viewer; successful exports send the path to the terminal clipboard |
| Artifacts | `w` | Open selected VCD in the full-area embedded waveform viewer |
| Artifacts | `W` | Open selected VCD in the dedicated Waveforms workspace |
| Investigation panes | `r` / `f` | Rerun selected case / all failed cases using original inputs on current project |
| Any simulation pane | `h` | Newest history page; palette also provides older pages |
| All panes | `[` / `]`, Tab/Shift-Tab | Independent scroll; move focus |
| Palette | Zoom focused tile / Unzoom workspace | More room for full inputs, failures, metadata or logs |

For generic Dune tests, choose **Run project tests** by name.

To check the aliases against installed binaries, run from the repository root:

```sh
python3 -B terminal/test_testing_aliases_pty.py \
  --client "$(command -v ag)" --daemon "$(command -v silver-daemon)"
```

The check uses a private project, daemon state and simulation fixture.

### Export path clipboard

Successful external simulation exports show a compact confirmation instead of the
long file path: **Export ready; path sent to clipboard (F8: path, F9: copy)**.
Clipboard transfer uses OSC 52, so it can reach your local clipboard over SSH when
your terminal (and any tmux/screen layer) permits clipboard writes. Terminal
acceptance cannot be detected; the message confirms that the request was sent.
**F8** toggles details with the complete quoted path (`[` / `]` scroll), and **F9**
resends the last successful export path. These also provide recovery when clipboard
transfer is unavailable. The exported file itself remains on the client host.

### Embedded waveform viewer

Select a retained VCD in Artifacts and press **w**, or choose **Simulation: Open
embedded waveform …** from the palette. No GTKWave installation, display forwarding
or viewer flag is needed. This opens a full-area view rather than adding another
tile to Testing. **Esc/q** returns to the existing workspace/focus/selection.

The viewer uses the active Workbench appearance: panel framing, background,
selection, values and waveform strokes follow its preset/color scheme. A compact
header shows case and shortened attempt/digest; full provenance is available with
`i`. The graph maps the visible time window onto the available columns and
preserves the exact VCD tick at the cursor. A resize recomputes the mapping
without changing a user-selected time window. In compressed views, a column
containing multiple transitions is marked `#`; a flat rendered sample does not
by itself mean the signal stayed stable throughout the column.

**Visible cursor and absolute-time ruler:** quick viewing and the workspace Waves
tile now share an exact integer tick-to-cell mapping. A theme-colored vertical
cursor highlights the column without replacing waveform glyphs. The two-row ruler
above it shows absolute physical times (including the VCD timescale multiplier),
with adaptive major/minor marks and complete non-overlapping labels. Both remain
visible when idle hints are hidden.

At expanded scales the cursor marks the tick's first cell. At compressed scales it
marks the cell containing the exact tick, with that cell's inclusive tick interval
reported explicitly; multiple cursor ticks may share a column while exact inspected
values still change. Panning can leave the cursor outside the window: a left/right
indicator then replaces the highlight instead of pretending the cursor is at an
edge. Ruler marks stop at the real retained trace end. `:` continues to accept an
absolute **VCD tick**, while ruler labels show physical time. Large times are exact,
including physical values exceeding signed-int64 multiplication range.

| Key | Embedded action |
| --- | --- |
| `j/k`, Up/Down | Focus a signal |
| Enter | Toggle focused signal in graph selection; disabled names remain visible |
| Space c c | Open the global command palette |
| `/` | Edit signal filter; Enter applies, Esc cancels |
| `h/l`, Left/Right | Move to the previous/next visible column |
| `H/L` | Move by one exact VCD tick |
| `f` | Fit the full trace |
| `d` | Restore the default extent: eight periods when a reliable clock is inferred, otherwise Fit |
| `:` | Enter absolute VCD tick; Enter applies |
| `[` / `]` | Pan half a window |
| `+` / `-` | Zoom in/out |
| `g/G` | First/last timestamp |
| `{` / `}` | Page the exact binary value of a wide bus |
| `i` | Inspect wrapped exact artifact identity, including SHA256; `j/k` scroll |
| Esc / `q` | Leave identity details, or return from waveform to Testing |

Artifact bytes are identity-checked and SHA256-verified before worker-thread parsing.
The opened view remains pinned to its project/attempt/case/artifact; asynchronous
completions cannot revive a closed view or replace a subsequently opened trace.
Navigation for eight identities is remembered in the current client session while
only the current parsed model is retained. Reloading another identity re-verifies its
bytes before restoring navigation. Opening/closing never launches a simulation.

#### Dedicated Waveforms workspace

Press **W** on a selected Testing artifact to create or reuse the **Waveforms**
workspace. This is a real persisted workspace with independent, themed tiles:

- **Session:** compact captured project/case/artifact, loading status and time units,
  below the workspace tabs. Waveforms suppresses the large global banner above tabs.
- **Signals:** all matching signal names, enabled or disabled; `j/k` focuses,
  **Enter** toggles, `/` filters. Disabled names are never hidden merely because
  their waves are not plotted.
- **Waves:** selected lanes with cursor, time entry, pan, zoom and exact values.
- **VCD picker:** VCDs belonging to the pinned attempt. `j/k` browses; **Enter**
  explicitly retargets the coordinated tiles. Merely browsing does not change the
  active trace. The pinned marker survives availability changes.
- **Logs:** stdout/stderr from the pinned attempt's captured job and daemon instance.
  Missing/expired jobs or a changed daemon instance show unavailable; logs from an
  unrelated current job are never substituted.

If Waveforms is already open, switch to it directly: an explicit or restored
Waveforms pin takes precedence. Without a pin, Waveforms follows an exact VCD
selection in Testing or the sole supported VCD in its retained attempt/case.
A missing or ambiguous source is reported without choosing an arbitrary artifact.
Use **W** to pin one independently of later Testing selection. Selecting an ASIC
Timing run does not supply a waveform.

While another workspace is visible, Silver verifies and decodes the intended
VCD and prepares the first Session, Signals and Waves viewport for the current
terminal size and display settings. A ready viewport is reused on switch; a
changed artifact, pin, or display setting cannot reuse its old panes. The idle
lane warms one workspace at a time within the embedded 8 MiB and renderer limits.
Picker metadata and captured logs still load separately when Waveforms is open.
The isolated `terminal/test_waveform_preparation_pty.py` regression checks for
the correct plotted signals and no VCD reads or viewport rendering at the
first switch, including after source changes and resize.

Use ordinary Tab/Shift-Tab focus, workspace switching, hide/zoom/layout actions and
**Space c c** palette access. Space is no longer a signal-toggle key, including in
quick inspection. `w` remains the temporary full-area inspection path, while `W`
leaves a workspace available for continued investigation. Exact identity remains
inspectable through `i` and pin-scoped palette actions.

Number keys follow keyboard focus. In **Session**, a bound number switches
workspaces immediately. In **Waves**, type a count followed by a motion:
`20h` / `20l` move twenty column steps left / right, `20H` / `20L` move twenty
raw ticks, and `20j` / `20k` move down / up signal rows. Esc cancels an unused
count; moving focus clears it too. In **Signals**, numbers stay local:
typing `2` in the list keeps you there, and typing it in `/` enters filter text.

To inspect a FIFO flag, highlight `full` in **Signals**, then focus **Waves**.
Press `n` (next change) or `p` (previous change) to land on the exact tick where
`full` changed value. The highlighted row is the target, even if its lane is
unchecked. On a binary flag these motions visit both rising and falling edges;
on a bus they visit changes to the whole value. `w` and `b` are aliases for
`n` and `p`. `3n` jumps three changes ahead,
or to the last change if fewer remain. The initial sample is not an edge, and
zoom does not affect the destination.

To toggle several signals, press `V` in **Signals**, extend the marked rows
with `j` / `k`, then press Enter. If every marked signal is enabled, Enter
disables them; otherwise it enables them all. Only rows matching the current
filter participate. If enabling the range would exceed the 16-lane limit,
nothing changes. Esc cancels the selection.

Signals defaults to **Inline** values in aligned name/width/value columns. Choose
**Waveform: Signal values: Stacked (two rows per signal)** or **Waveform: Signal
values: Inline (aligned columns; default)** in the palette. This display preference
persists per project root/environment across quick and workspace views, separately
from artifact pins. Long names shorten; wide values expose a range indicator and
can be paged with `{` / `}`.

In `/` filter editing, **Ctrl-Backspace** or **Ctrl-W** deletes the preceding word;
ordinary Backspace deletes one character. Ctrl-Backspace requires an identifiable
terminal key sequence; if a terminal/tmux setup sends the same DEL as ordinary
Backspace, use Ctrl-W. Spaces are ordinary text while editing. Enter applies and
Esc cancels.

Idle control labels are proper hints, **hidden by default** for Waveforms panes.
**Toggle focused tile hints** restores pane hints and its idle host shortcuts.
Active editing prompts, errors and clipping indicators remain visible. The default
Signals/Waves target horizontal weights are now **1:4**, with a 24-column minimum
left column. Session sits above Signals in that column; Waves occupies the right
side across both heights. At terminal widths 80/120/230, measured left widths are
24/24/46 and Waves widths are 56/96/184. Inline name columns follow the longest
filtered signal name (including disabled/off-screen names), with minimal padding
before the width/value fields instead of stretching across the pane. Session attempt
IDs show literal first four and last four characters, for example `sim-…cdef`;
the identity inspector retains the full ID.

Existing custom layouts are not reset automatically. To add Session to an existing
Waveforms workspace, choose **Apply preset: Waveforms**, then **Layout: Fit tiles
to window** (and **Unzoom workspace** if necessary). Apply preserves existing tile
IDs, requested geometry, hidden state, bindings, contexts, extras, zoom and pins;
Fit explicitly recomposes the layout. **Restore default layout: Waveforms (hide
extras)** is the stronger explicit reset. Session is metadata-only, so adding it
does not invalidate the artifact pin or trigger a reload.

Changing Testing's selection does not retarget the workspace. `W` explicitly opens
the chosen artifact, and picker activation explicitly changes the pin. Workspace
navigation is retained across switching; up to four parsed workspace models remain
resident, with evicted models reverified when reopened. This is separate from the
quick viewer's single-model/eight-navigation history. The exact pin is stored in a
bounded client-side sidecar keyed by project/environment, alongside the daemon's
workspace registry. Client restart restores and revalidates the pin; missing bytes
remain visibly unavailable rather than silently selecting another artifact.

Acceptance: **206 checks** passed in
`/tmp/opencode/wb028-accept-3uvxecj4/report.json`, covering creation/reuse, separate
tile focus, palette access, disabled names, picker retargeting, exact-attempt log
markers, switch-away/back, client restoration, missing artifacts, daemon restart,
and three delayed responses (including workspace picker replacement). Investigation
did not invoke providers or create attempts. A subsequent display-only pinned-marker
fix passed focused inline tests, builds, lint and formatting; the full acceptance
suite was not repeated for that isolated change. Synthetic preset export smoke also
passed; startup still creates the original three starter workspaces, not Waveforms.

**Session/value/hint refinement:** the subsequent full acceptance run passed
**305 checks**, including inline alignment, stacked preference restart, actual PTY
Ctrl-Backspace/Ctrl-W/Backspace sequences, hidden/visible hint policy, compact Session
provenance, and additive legacy-layout upgrade. All identity, delayed-load, logs,
theme and provider-side-effect checks remain covered. Evidence:
`/tmp/opencode/wb028-accept-xkuv7752/report.json`; synthetic preset smoke:
`/tmp/opencode/synthetic-flow-imarw6ci`. Terminal/workspaces inline tests, native
builds, lint and formatting also passed with bounded job allocations.

**Compact left-column follow-up:** full acceptance passed **350 checks** at
`/tmp/opencode/wb028-accept-f4m244ea/report.json`, including 80/120/230-column
geometry, compact aligned values, exact full identity, persistence and all delayed
response fences. Native client/daemon/probe/preset-exporter binaries were rebuilt.
Use **Layout: Fit tiles to window** to adopt the composition in an existing custom
layout; a workspace already in Fit mode uses the new composition. Owner manual
appearance validation is pending.

**Cursor/ruler follow-up, subsequently authorized and implemented:** full acceptance
passed **1,773 checks** in `/tmp/opencode/wb028-accept-2swfin7h/report.json`. Actual
terminal cells verify highlighted columns and unchanged underlying wave glyphs in
quick/workspace views, compressed intervals, left/right off-screen states, ruler
alignment through pan/zoom/resize, first/interior/last ticks, and all four schemes
and five presets. Probe cases cover 10 ps/100 fs units and exact times above float
precision and int64 physical-time multiplication (including
`922337203685477580700 fs`). Existing layout, logs, identity, persistence and delayed
response checks still pass. Screenshots and cursor/ruler measurement JSON are in
the same evidence directory. Native client/daemon/probe/exporter builds, inline
tests, lint and formatting passed; synthetic preset smoke passed at
`/tmp/opencode/synthetic-flow-2hka9ct5/`.

**Declared parser limits:** 8 MiB VCD, 4,096 signal declarations, 4,096-bit widths,
500,000 assignments, 64 MiB expanded values, hierarchy depth 128 and paths of 1,024
bytes. Graph selection is at most 16 signals with viewport-sized lane paging and
at most 4,096 projected columns. Parsing is bounded full-file loading, not lazy
trace streaming. Timestamps remain signed-int64 nonnegative integers with explicit
VCD units. Cursor ticks and ruler physical-time labels are absolute.

X/Z and uninitialized values remain exact in textual inspection. In a mixed window,
affected lanes show an explicit limitation rather than fabricated logic values;
known lanes still show connected scalar transitions or labeled bus segments.
Missing timescales, real/string/event variables,
dump-on/off gaps, malformed data and exhausted limits are rejected explicitly.
Return to Testing to export/open externally when a trace is unsupported.

#### Verification evidence

`scripts/test-embedded-waveform.py` and `terminal/waveform_probe.ml` exercise real
retained FIFO directed, failed-case and long traces plus malformed/limit fixtures.
Combined acceptance passed **95 checks**, including controls, resize, return/reopen,
unchanged provider-call counts, and delayed responses released after closing and
after replacing an in-flight viewer. Distinct replacement digest, hierarchy, cursor
and values survived the old completion. Exact values and Back controls are checked
at 80x24, 120x40 and 180x55. Inline tests also cover 68x20 layout, complete identity
inspection and navigation snapshot/restoration.

Evidence: `/tmp/opencode/wb028-accept-kme9_maa/report.json` and its `pty/` directory.
Additional layout/inline verification: `/tmp/opencode/wb028-accept-3ffwfcfg`.
These are local evidence paths, not committed fixtures. The acceptance script can
take explicit fixture paths; inspect `--help` when reproducing on another machine.

Measured fixture probe costs (window ticks 0–100, 120x40):

| Fixture | Bytes / assignments | Parse CPU | Convert / render CPU | Peak probe RSS |
| --- | --- | --- | --- | --- |
| Directed FIFO | 317,947 / 37,274 | 16.92 ms | 0.106 / 0.192 ms | 46 MiB |
| Failed seeded FIFO | 4,309 / 551 | 0.244 ms | 0.034 / 0.357 ms | 33.5 MiB |
| Long seeded FIFO | 1,043,285 / 142,696 | 49.05 ms | 0.346 / 0.178 ms | 54.7 MiB |

PTY cursor-to-observed-paint measured 71.7 ms including harness overhead; client peak
RSS was about 80 MiB after opening. These are fixture observations, not worst-case
budget guarantees. Native terminal/daemon/probe build, terminal inline tests, lint
and formatter checks passed with explicitly bounded build pools.

Example reproduction (no other build pools active):

```sh
scripts/with-switch.sh dune build --build-dir /tmp/opencode/wb028-accept-build -j 10 \
  terminal/main.exe terminal/waveform_probe.exe daemon/main.exe
python3 scripts/test-embedded-waveform.py \
  --probe /tmp/opencode/wb028-accept-build/default/terminal/waveform_probe.exe \
  --daemon /tmp/opencode/wb028-accept-build/default/daemon/main.exe \
  --client /tmp/opencode/wb028-accept-build/default/terminal/main.exe
```

**Appearance/scale follow-up:** combined acceptance now passes **139 checks**;
evidence `/tmp/opencode/wb028-accept-i04vioew/report.json`. At 230 columns, a regular
clock occupied all 198 available plot columns with 17 equal complete 10-tick periods.
PTY tests exercised all four schemes and five presets, checking painted colors,
background and rounded/square/unframed chrome. Exact provenance remains checked in
the identity inspector, including after delayed replacement loads. This fixes the
initial overestimated label allowance that compressed 256 ticks into roughly 86
columns and left a wide Waves pane partly empty.

The earlier experimental hardcoded `/usr/bin/gtkwave` launcher argument was removed:
GTKWave is installed on the workstation, not this server, and embedded viewing does
not need it. To try this implementation, build/use the client from `sim-artifacts`;
an existing prepared client copied from another checkout will not gain the feature
until explicitly refreshed.

The existing multi-step launch form accepts cases, canonical uint64 seed, each
declared parameter and final `launch` confirmation. Ctrl-U clears a field. Catalog
defaults are not guessed: the initial declared suite defaults are shown, and
changed/removed selections disable launch until explicitly corrected/accepted.
The `e` settings form saves inputs in the current Testing workspace without
running them. Switching suites or changing the discovery digest drops the saved
seed and parameter overrides. The one-run Enter form never overwrites them.
**Discovery** asks the provider which suites and cases exist. A refresh with a
still-valid catalog lets you keep launching; an initial discovery, a failed
refresh, or rows retained from another configuration do not. If a refresh
changes your selected inputs, review the new catalog and press `u` to accept.

To submit another attempt while watching a run, focus **Catalog**, choose a
suite and cases, and press `R`. **Attempts** shows each submission separately.
With an overlap-safe provider configured for `max_parallel_runs > 1`, independent
attempts can run together; while waiting for capacity or exclusive project
work, a submitted attempt is **Queued**, not disabled.
Already-open palette/forms keep captured inputs; stale launch requests are rejected
by the normal backend digest/config checks rather than retargeted.

## Genuine FIFO provider

| Field | Declared values |
| --- | --- |
| Suite | `controlled-fifo` |
| Cases | `directed`, `seeded` |
| Default seed | `42`; the entire canonical uint64 range is supported |
| `cycles` | `64`, `4096` (default), `20000`; affects seeded traffic only |
| `checker` | `normal` (default), `mismatch` |

The provider uses the real `Controlled_fifo` DUT, existing directed traffic and
independent ordered-list reference model. `checker=mismatch` changes one expected
post-edge occupancy value at edge 17. It does not change the DUT or input stimuli:
normal and mismatch modes produce byte-identical VCDs for the same case/seed.
It deliberately demonstrates semantic **Failed** with process exit 0; use `normal`
for actual success checking. Full cycle/phase/expected/observed/stimulus/history
evidence is retained in the native report and logs.

FS2 seeds map to four little-endian 16-bit PRNG words, preserving all 64 bits.
This documented mapping differs from the old single-int CLI seed mapping. The
ordinary CLI/Dune tests keep their prior behavior. Deterministic replay is verified
for the same executable/toolchain, not claimed as archived-build reproducibility.

Persistent generation:

```text
hardcaml_asic_example/.dev/fifo-simulation/4158d5b458804b8a8428bc28862e5a49/
  fifo_sim.exe
  test_provider.exe
```

Only `test_provider.exe` links the shared provider library; the simulator/checker
retains its standalone executable interface. Python adapters remain source-level
conformance references. The former installed Python generation is preserved.

Root configuration is `hardcaml-workbench-simulation.sexp`; installation ownership
is `.dev/fifo-simulation-install.json`. Discovery/run never build or install.
The explicit installer supports a bounded build or an already-verified executable
and refuses unrelated/edited companion configuration. See the sibling's
`simulation/README.md` for maintenance and standalone commands. ASIC configuration
and canonical physical results are separate and were not modified.

## Availability limits

Logs remain the existing supervisor's bounded job logs, not newly durable full
history. After daemon restart, normalized cases/reports/traces remain available,
while absent exact-job logs are explicitly labelled unavailable. Waveforms use
byte-verified export/external viewer handoff; there is no embedded waveform viewer.
Simulation is project-scoped and supplies no automatic ASIC acceptance verdict.
There is no seed-matrix scheduler, new test schema or archived-input replay in this
slice. Missing artifacts/errors are retained as explicit states.

## Acceptance

Normal build, repository-wide format/lint and full tests passed serially at `-j20`.
Implementation agents used separate build directories at 6 jobs each, within the
shared 20-job pool. No physical EDA ran.

| Proof | Final evidence under `/tmp/opencode` |
| --- | --- |
| Genuine FIFO standalone + public HTTP + new/legacy PTY | `fifo-testing-wx4xhzjp/`: 21 cooperative assertions, 6 native attempts, 12 actual standalone case results across 8 valid runs, 12 rejected invalid requests |
| Cooperative synthetic UI | `testing-workspace-w56bs6_c/verified.json`: 15 checks |
| Synthetic demo/legacy compatibility | `synthetic-flow-58wxhzay/testing-result.json`:44 checks |
| Native indicators, including Off | `terminal-indicators-06485dae9a88/result.json`:351 checks |
| Independent real counter FS2 regression | `fs2-native-xh0meb_6/result.json`:45 checks |
| Checklist launch | `checklist-workflow-5eba10136566/result.json`:61 checks |
| Terminal interruption/restoration | `workbench-terminal-interrupt-268f0z3w/results.json`:5/5 |

The real acceptance proves exact catalog-selected cases, seed/parameters/digest,
case selection across repeated polls, coherent detail/log/artifact ownership,
byte-identical report/VCD export and targeted-rerun parent identity. The source
project's ordinary tests also passed: 7,330 directed edges and 20,017 edges using its
original seeded CLI. The expanded FS2 long-seed example checked 20,018 edges; these
different totals reflect different documented seed mappings/drain lengths.

The final real and synthetic captures validate actual painted edges/footer at
120x40 and 180x55. Earlier wide captures matched stale 120-column frames immediately
after PTY resize; explicit SIGWINCH and geometry assertions fixed that harness gap.
Model/reducer tests cover catalog changes, late receipts, workspace independence
and long-list cursor visibility; this is not exhaustive multi-monitor acceptance.

Reproduce with prebuilt binaries (allow 600 seconds for real PTY):

```sh
scripts/with-switch.sh python3 -B scripts/test-fifo-testing.py \
  --daemon _build/default/daemon/main.exe \
  --client _build/default/terminal/main.exe \
  --simulator /home/wayne/devel/jane/hardcaml_asic_example/.dev/fifo-simulation/af97d67d923441a0a654e27b6afd728f/fifo_sim.exe
scripts/with-switch.sh python3 -B scripts/test-testing-workspace.py \
  --daemon _build/default/daemon/main.exe \
  --client _build/default/terminal/main.exe
```
