# Silver

Formerly Hardcaml Workbench. The repository is now
[`bopurtell/silver`](https://github.com/bopurtell/silver), checked out as `silver/`.
Existing `hardcaml-workbench` commands, `hardcaml_workbench*` packages and OCaml
modules, configuration filenames, environment variables, and saved state paths
remain supported under their existing names.

A development workbench for inspecting, running, measuring, and debugging Hardcaml designs.

## Install and open Silver

Install [hardcaml_asic](../hardcaml_asic/README.md#install-the-provider) first.
Then, from the **Silver checkout**, install once for your user:

```sh
./install.sh
```

`./install.sh --without-asic` installs Silver for generic Dune/simulation use.
`./install.sh --asic-provider /absolute/path/to/hardcaml_asic` checks a
specific CLI during installation; that check does not pin every project to
that executable.

This builds the native app and installs its commands under `~/.local/bin`; no
`sudo` is needed. If that directory isn't on your `PATH`, add
`export PATH="$HOME/.local/bin:$PATH"` to your shell configuration.
`command -v silver` shows which installation your shell will launch.
This is a **source installer**: it expects an opam switch with Silver's native
build dependencies installed (this workspace uses `5.2.0+ox`). Run the installer
again after updating the checkout to replace your installed commands.

**Which dependencies belong where?** Silver builds against Hardcaml and its UI
and server libraries. It calls `hardcaml_asic` as a separate executable for
ASIC operations. A hardware project that imports `Hardcaml_asic`, on the other
hand, needs that package's compiled libraries in its build environment. Updating
the ASIC provider does not by itself require rebuilding Silver. Provisioning
the PDK and physical-flow tools is a separate step needed to run those flows.

For an ASIC-enabled project, its configured absolute `provider_executable`
pins the CLI. If that field is omitted, Silver selects a compatible CLI on
the service host’s `PATH`; `SILVER_ASIC_PROVIDER=/absolute/path/to/hardcaml_asic`
can select an experimental installation for those unpinned projects. Discovery
checks the advertised CLI contract, not just the filename or package version.
A project still declares its own project executable, toolchain and results
directory. Running a remote daemon uses **its** tools, not the client machine's.

Then switch to the project you want to inspect:

```sh
cd /path/to/your/dune/project
silver
```

From anywhere inside a Dune project, run **`silver`** in a terminal. It opens
the nearest project and hosts its loopback service inside the app process. `q`
closes both; use a persistent daemon instead for work that must continue after
you leave. Use `silver --project-root /path/to/project` to select a different
project. Sessions for the same checkout reuse state under
`${XDG_STATE_HOME:-$HOME/.local/state}/silver/projects`; only one standalone
session can own that project's state at a time.

Outside a Dune project, interactive local `silver` opens with a floating project
setup dialog. Create an ASIC starter in the empty directory, choose a new
directory beneath it, or open an existing Dune project. Type the project name
or path, then click the displayed controls to preview, apply, or cancel.
**Enter** also advances each step. **Esc** dismisses setup without creating
anything or quitting Silver; **p** reopens it.

With a local project already open, click **Project ▾ → New Project…** to
create a separate Dune project with its first chip target. **Open Project…**
opens an existing Dune root instead. To create another chip *inside the current
project*, choose **New Chip Target…**.
New projects default to a sibling directory. Both actions stay in the same
terminal; switching projects keeps the original workspace and its running jobs.

Inside an existing, unconfigured Dune project, open the command palette
(**Space c c**) and choose **Set up project…**. **Add ASIC starter…** adds design
files to this project and keeps its `dune-project` and existing sources.
**Import existing ASIC design…** connects an already-built design executable by
reference. Creating or adding a starter requires `hardcaml-asic-starter` on
`PATH`; importing a design does not. None of these actions launches EDA.

**Project browser trial:** Choose **Project ▾ → Manage This Project…** to browse
libraries, chip targets and profiles without changing the launch target. **Try
window** keeps the current inspection visible. [Controls and comparison](docs/features/workspaces/WB-086-owner-trial.md).

**Reusable IP:** Click **Project ▾ → New IP Library…**, or type **`new ip`**
in the palette and press **Enter**. Click the empty or sample template, type a
name, then click **Preview**. Review the paths under `ip/<name>/` and click
**Apply** to create the files or **Cancel** to leave the project alone. The
same steps work with the keyboard: arrows and **Enter** to choose, **Enter**
to preview and apply, **Esc** to cancel. Use **New
Module…** to add an `.ml` file to a library. Without a selected library, enter
its directory relative to the project root. If the library lists modules
explicitly, the preview explains the Dune edit to make yourself.

The installed `silver-author` uses the same service locally (or with
`--endpoint URL --root /project/on/host`). From inside a Dune project:

```sh
silver-author new-ip accum --template sample          # preview only
silver-author new-ip accum --template sample --apply
silver-author new-module helper --library ip/accum --apply
dune runtest ip/accum
```

**Chip targets:** A Silver project has one Dune root. Each chip target in it
owns its wrapper, ASIC declaration and executable. Use **New Chip Target…** to
add one from the provider example or wrap an existing supported IP library.
Registering an additional target makes it discoverable without changing the
catalog default. Press **r** at the preview to toggle registration, then
**Enter** to create. Leave registration off to build the target directly
instead. After registration, **s** explicitly selects the new launch target;
build `asic_<name>/project.exe` first if the executable is not yet available.

```sh
silver-author new-chip chip_b                     # preview the example target
silver-author new-chip chip_b --apply
silver-author new-chip inverted --from-ip ip/accum \
  --mapping ui_in:uo_out:comb8 --no-register --apply
```

The IP command maps the eight `ui_in` pins through the sample library's
combinational `Block.create` to the eight `uo_out` pins. It does not connect a
clock or reset. The IP library and its tests stay in their original directory.
This first mapping requires the updated sample starter's `chip-interface.json`
and a matching `Block.create` type. A library created before that declaration
was introduced is not automatically treated as compatible.

**Flows and profiles:** Choose **Project ▾ → New Flow…** to add a methodology
to a chip. Check the **Owner** before choosing a recipe: you can author a flow
for chip B while chip A remains selected for launch. **Duplicate Profile…**
copies the source profile's explicit settings; unspecified settings still come
from the methodology. Both commands preview their source changes. Neither
starts a run or changes the default. Build the owner's chip executable before
discovering and running the new selection.

```sh
silver-author new-flow explore --chip chip_b --recipe librelane_classic_v1 --apply
silver-author duplicate-profile timing_trial --chip chip_b --flow standard --from balanced --apply
```

Omit `--apply` to preview. New chip starters and the migrated FIFO example
register those files on build. For a hand-written catalog that hasn't opted
into this convention, Silver gives you a registration snippet instead of
rewriting your OCaml. See the [management browser trial](docs/features/workspaces/WB-086-owner-trial.md)
to compare browsing these objects in a workspace and in a side window.

Standalone command-line submissions (`--plain --action`, `--refresh-integration`
and `--asic-operation`) wait for the operation; use `--connect` to submit
work that should outlive the client.

For a persistent session, run `silver-daemon --port 8080`, then
`silver --connect http://127.0.0.1:8080 --project-root /path/on/server`.
Quitting this client leaves the daemon running. For a remote machine, forward
the port with SSH (`ssh -N -L 8080:127.0.0.1:8080 HOST`) and use that same
local URL.

**Packaging:** `silver` and `silver-daemon` install together. The installer
uses Dune (the OCaml build tool) internally. Local mode needs no separately
running server or web package. Native build dependencies (including the sibling
`hardcaml_workbench_provider` package) are declared in `dune-project`.
Opening a project probes `dune` and inspects the workspace on the service host,
even when you're only browsing. Start Silver in the project's normal Dune/OCaml
environment. Hardware simulation and ASIC flows additionally need the providers
and tools selected by that project.

These are native builds for the host platform. On the current Linux x86-64
build the terminal executable links to glibc, libm, zlib and GMP; distributing
a binary for another platform needs a build and install check on that target.
Run `./scripts/with-switch.sh dune build -j4 @test-native-standalone` to check
the installed entry points, project discovery, state reuse and quit behavior.

**Picking up in a new session?** Read the [cross-repository checkpoint](docs/session_checkpoint.md)
for PT.0–PT.8 status, paused acceptance and preservation constraints. Refactor
continuations are grouped under [migration guides](docs/migration_guides/README.md).

For tests **of Workbench itself**, start at [test/README.md](test/README.md) and
[the testing guide](docs/testing.md): subsystem-owned tests, explicit suite selectors,
and opt-in native/real-provider acceptance are distinct from hardware verification
launched inside the application's Testing workspace.

**Everyday example development:** use the [checkout-backed main launcher](../hardcaml_asic_example/docs/workbench_main.md):
`python3 -B scripts/silver.py open` from the prepared checkout, or
`daemon` and `client` in separate terminals. It opens
the actual editable repository, uses persistent `.dev/workbench-main` state and
`_flow_results/workbench` results, and exposes FIFO/PT.8 suites and normal physical
endpoints. The older [captured development session](docs/development_session.md)
uses an independent copied project and is historical acceptance guidance.

**PT.8 Workloads (2026-11-05):** inspect verified workload results, capture explicit
A/B variants and launch a fresh example workload through Testing. The
[isolated session launch guide](docs/pt8_workloads.md) provides the server/client
commands and accepted retained→fresh-run walkthrough, preserving existing sessions.

**Current direction (2026-10-16):** configurable Bonsai Term tiles over typed
provider/module contracts, a command palette and named workspaces linked to a shared
Main run context by default. Workspaces can inspect independently; tiles can pin
references. Simulation/testing includes generic tests and structured suites/cases,
seeds, reruns and trace evidence over the existing supervisor. ASIC
flow ownership stays with the project and `hardcaml_asic`; development uses the
sibling FIFO specimen and headless tests.

**FS0 demos are implemented and exercised:** workspace/run-context persistence,
palette and generic test/log tiles, synthesis views, installed ASIC discovery/plan/
launch/observation, and L1/L2 summary reuse. Two real synthesis profiles produced
673 and 685 cells; those synthesis-only runs have acceptance `not_evaluated`. Existing Dune,
RTL/artifact and hierarchy workflows remain covered by installed tests.
**FS1 now adds** synthesis resource/check metrics and explicit finalization import
with aggregate timing, physical resources, check verdicts and declared-clock context.
Workbench can also launch collection/acceptance, observe and cancel its owned
finalization, and browse bounded report/artifact text with optional terminal-host
external text opening.
Real physical completion, external acceptance pass/fail inspection and owned-container
cancellation are exercised. FS1 now also delivers retained timing-path exploration,
measured clock reports, stage-specific physical/routing/congestion tables and exact
binary external handoff. These complete the adopted-evidence FS1 scope; embedded
graphical editing and appearance-gallery polish remain later work. See the
[current FS1 evidence and limits](docs/fs1_investigation.md) and [delivery record](docs/construction_phase_plan.md).
The owner has confirmed the Escape-responsiveness fix. Inspector presentation
polish and broader race/scaling coverage remain followups, not FS1 feature blockers.

**Substantial FS2 is delivered and accepted; milestone closed:** project-declared suites/cases, explicit seeds and
parameters, live progress/failure detail, targeted reruns, durable bounded history
and byte-exact trace export. Actual Hardcaml Cyclesim and native HTTP/terminal PTY
acceptance passed. Start with the [Cyclesim example](examples/fs2_cyclesim/README.md)
and [FS2 controls/acceptance](docs/fs2_acceptance.md). ASIC association is optional;
embedded waveforms and real gate-level adapters remain later integrations.

**Testing adoption extension:** the actual FIFO example now has a project-owned
FS2 provider with directed/seeded cases and genuine VCD/report artifacts. A catalog
and cooperative Attempts/Cases/Detail/Artifacts/Logs workspace expose the existing
backend coherently. [Open it and try the controls](docs/testing_workspace.md);
[implementation/evidence](docs/testing_cluster_plan.md). The original standalone
simulation tile and independent counter fixture remain supported.

## Documentation

- [Compose your own windows and workspaces](docs/workspace_configuration.md) — shared
  stock/user specification, editable examples, atomic apply and built-in recovery.

- [Execution durations](docs/execution_durations.md) — stage/run and simulation elapsed
  times in Overview and Testing, availability limits, and linked-context theme colors.
- [Lazy Timing details and cache configuration](docs/timing_cache_and_duration_alignment_plan.md)
  — selected-first loading, bounded neighbor warming, cache limits, and duration columns.
- [Reconnect and saved navigation](docs/client_reconnect_hydration_plan.md) — retained
  catalog reuse, immediate tab hydration, and restored attempt/artifact/Timing selections.

- [Restore a default workspace layout](docs/default_layout_restore.md) — one-step
  recovery from extra/hidden tiles or altered sizes, preserving runs and pins.

- [Documentation index](docs/README.md) — orientation and reading routes.
- [FS0 controls](docs/fs0_terminal.md) and [acceptance](docs/fs0_acceptance.md) — run the demo and inspect its evidence.
- [Synthesis inspection](docs/synthesis_inspection.md) — FS1 cell tables, sorting/filtering and evidence drilldown.
- [FS1 physical inspection](docs/fs1_acceptance.md) — metrics, timing/check/resource views, exact finalization import, real acceptance and limits.
- [Finalization and reports](docs/fs1_lifecycle_and_artifacts.md) — collect/accept palette commands, reconnect/cancel, paged artifact reading and configured external text viewing.
- [FS1 investigation completion](docs/fs1_investigation.md) — timing paths, measured clocks, physical/routing evidence, binary handoff, exact installed provider and adoption instructions.
- [FS2 simulation controls and acceptance](docs/fs2_acceptance.md) — suites, seeds, failures, reruns, history and trace export; real Cyclesim/native HTTP/PTY evidence.
- [FS2 provider/RPC contract](docs/fs2_simulation_contract.md) — configure a project-owned simulation provider and implement structured discovery/events.
- [FS3 adoption](docs/fs3_adoption.md) — initialize existing projects, import/export/clone layouts and retain presentation preferences.
- [Feature list](docs/feature_list.md) — concise scope/status and focused feature specs.
- [Feature sets](docs/feature_sets.md) — FS0 initial demos and later themed work groups.
- [Decision log](docs/decisions.md) — accepted run contexts; remaining command/snapshot policy.
- [Architecture](docs/hardcaml_workbench_architecture.md) — product, ownership, providers,
  runs/storage and workspace/window/tile boundaries.
- [Construction plan](docs/construction_phase_plan.md) — active demo phases M0–M5 and progress.
- [Rendering](docs/rendering.md) — styles, layout, interaction and headless UI testing.
- [Appearance handoffs](docs/design/README.md) — imported aesthetic sources and F12/FS5 interpretation.
- [Try the appearance presets](docs/appearance_presets.md) — A–E skins and independent color/icon/density controls.
- [Workspace composition and palette](docs/frontend_composition.md) — per-workspace OCaml definitions, floating fuzzy palette, configurable badges/chrome and typed status emphasis.
- [Refined Overview and Timing](docs/frontend_refinement.md) — border titles, compact summaries, horizontal stages, wide run labels and cooperative Timing investigation panes.
- [Current Overview sidebar and schemes](docs/overview_sidebar.md) — tightly packed vertical sidebar/right summaries, live Carbon/Slate/Crimson/Neon schemes and exact planned-run preview.
- [Real ASIC example demo and current polish](docs/real_asic_example_demo.md) — black default, value-only status colors, split checklist/planned-run sidebar and verified actual-example launch commands.
- [Launch/checklist consistency](docs/launch_stage_consistency.md) — exact submitted-run tracking beside preview readiness, real stage observations and read-only refresh after upgrade.
- [Checklist r → Plan → Launch](docs/checklist_launch_workflow.md) — real capability-backed stage shortcuts, cold-catalog discovery and visible launch-command availability.
- [Interactive synthetic flow](docs/synthetic_flow.md) — populated Overview/Timing, live checklist, simulated launches and FS1 inspection without EDA tools.
- [Synthetic Testing and both demo launch pairs](docs/synthetic_testing.md) — Overview/Timing/Testing defaults, synthetic FS2 pass/failure evidence, wider Session panels and actual-example hand-validation.
- [Formatting guide](docs/formatting_guide.md) — retained source conventions.
- [Backlog](docs/backlog/README.md) — explicitly deferred ideas and reactivation triggers.
- [Archive](docs/archive/README.md) — earlier designs, plans and completion evidence.

## Development

Build concurrency is one **shared pool of 20 jobs**, including nested builds and
provider helpers. One worker may use `-j20`; two may use `-j10` each; three must
divide the pool (for example 6/6/6 with 2 reserved). Parent verification may use all 20
only after other builds stop. Always pass an explicit job limit. This supersedes
the earlier conservative two-job guidance in historical acceptance records.

Use `scripts/with-switch.sh` for Silver development commands. It selects the existing
`5.2.0+ox` opam switch by default; `OPAM_SWITCH=my-switch` overrides it. The wrapper
does not create a switch or install dependencies. Inspect dependency requirements:

```sh
./scripts/with-switch.sh opam install . --deps-only --with-test --show-actions
```

Review the actions before installing; omit `--show-actions` to apply them. Formatting
and lint tooling also need `ocamlformat` and `ppx_js_style`. Generated opam metadata
comes from `dune-project`. The native package is separate from optional web tooling.

After installing this checkout with `./install.sh`, launch against an independent project:

```sh
silver --project-root /absolute/path/to/project --environment opam:PROJECT_SWITCH
```

From anywhere inside a project, `--discover-project` replaces `--project-root` and
opens the nearest ancestor containing a regular `dune-project` (the selected root is
reported; an explicit `--project-root` never searches upward). Simulation provider
configuration can be generated and checked (discovery only, no tests run) with
`silver-simulation-setup init|check`; see
[WB-039](docs/features/project/WB-039-simulation-setup.md).

Use the project's actual switch. `--environment inherited` means the daemon's
startup environment, not necessarily the current client's shell. Add `--plain`
for noninteractive use. The current `b`/`t` controls submit build/test; `q` exits
the app. In an attached session the separate daemon stays alive.

The palette (**Space c c**) also offers **Appearance: A - Instrument**, **B - Structured**,
**C - Minimal**, **D - Studio**, and **E - Structured studio**, plus separate color,
icon and density controls. These experimental client-local choices preserve run
contexts and pins; see the [preset guide](docs/appearance_presets.md).

Separate foreground startup is:

```sh
silver-daemon --port 8080
# In another terminal:
silver --connect http://127.0.0.1:8080 --project-root /absolute/path/to/project \
  --environment opam:PROJECT_SWITCH
```

### Open the current real ASIC example demo

When you open a configured ASIC project, Silver discovers its targets and
flows. Choose **Overview → Planned Run → Launch chip**, then highlight
**synthesis** in the **stage checklist** and press **Shift+R** to run it for
that chip. You don't need to stage a plan first. **Space c c → Discover ASIC
flows and runs** remains available to refresh a changed catalog.
See [choosing a chip and staging its flow](docs/launch-target.md).

The **Resources inspector** is now available through **Space c c → Inspect
resources (open Resources workspace)**. It can explicitly import the retained SRAM
capture without running EDA. See [Resources controls, current provider and restart
commands](docs/resource_inspector.md); existing saved layouts are preserved.

Fresh checklist launches now execute **Elaboration → Synthesis → … → endpoint**
as one daemon-owned workflow, consuming the exact emitted bundle. Both app binaries
must be current. See [unified fresh-prefix controls and restart instructions](docs/unified_fresh_prefix_plan.md#delivery-and-user-verification)
for the PT.5 example provider configuration and validated default-binary pair;
the pinned demo launcher below keeps its own copied binaries until refreshed.

The actual example has a prepared persistent provider and isolated demo state.
From this checkout, Terminal1:

```sh
python3 -B scripts/real-asic-example-demo.py daemon
```

Terminal2:

```sh
python3 -B scripts/real-asic-example-demo.py seed
python3 -B scripts/real-asic-example-demo.py client
```

This adopts real retained named signoff evidence without EDA. See
[the current guide](docs/real_asic_example_demo.md) for exact provenance, limits and
`refresh-binaries` after future builds. It replaces the volatile historical setup below.

### Historical FS1 manual demo (superseded)

The commands in this section record the earlier temporary installation and evidence
paths, which may no longer exist after reboot. Use the persistent launcher above
for current testing rather than copying these old provider/result paths.

This local demo inspects the retained `hardcaml_asic_example` physical execution
and its accepted finalization; it does not rerun implementation or acceptance.
Use the existing matching client/daemon binaries and a terminal around 120×40.
The example's `hardcaml-workbench-asic.sexp` must select the inspection-capable
provider (the manual-demo config has been updated to this generation):

```sexp
(provider_executable /tmp/opencode/workbench-fs1-inspection-provider/generations/59466eda06df463e8d921678830ff5c2/bin/hardcaml-asic-flow)
```

Changing that setting requires reopening with a daemon that rereads the config.
ASIC registration/cache identity includes configuration, so re-register exact known
references after a provider-path change. Existing layout/pin records are separate.
The retained test harness's deadline-limited relay is not a permanent demo provider.

From this checkout, **Terminal 1**, create fresh state and start the daemon:

```sh
STATE=$(mktemp -d /tmp/opencode/workbench-manual-fs1-XXXXXX)
./scripts/with-switch.sh _build/default/daemon/main.exe \
  --port 41734 --state-dir "$STATE"
```

Keep the chosen state path to reopen this arrangement later. Use an unused port
and the same URL below; only one daemon may own a state directory. To reuse an
existing session, use its intended daemon/state lifecycle instead of starting a
second owner.

In **Terminal 2**, also from this checkout, register the retained evidence once
for this project/configuration namespace:

```sh
ROOT=/home/wayne/devel/jane/hardcaml_asic_example
URL=http://127.0.0.1:41734
wb() {
  ./scripts/with-switch.sh _build/default/terminal/main.exe \
    --connect "$URL" --project-root "$ROOT" --environment inherited \
    --api --plain "$@"
}

wb --asic-operation \
  '(Register ((attempt /tmp/opencode/workbench-fs1-physical-w0rftdi0/results/observations/20261015T192439611662Z_965b68b0) (stream_id 965b68b0f7454e14bc7d6f12f32ab9c7)))' \
  --wait --wait-timeout-seconds 120

# Exact Run_ref for this retained specimen, not a directory-derived new identity.
RUN='((backend asic) (id 965b68b0f7454e14bc7d6f12f32ab9c7) (build ()) (label ()))'
wb --asic-operation \
  "(Inspect_finalization (run $RUN) (attempt /tmp/opencode/workbench-fs1-acceptance-5oa67d8u/operations/20261015T203811140090Z_3bbfa7f1))" \
  --wait --wait-timeout-seconds 120

./scripts/with-switch.sh _build/default/terminal/main.exe \
  --connect "$URL" --project-root "$ROOT" --environment inherited
```

These API operations only read existing provider evidence and populate Workbench
state. The specimen shows **673 synthesis cells**, aggregate setup/hold around
**11.6755/0.125029 ns**, and terminal acceptance **pass**. Execution completion,
individual checks and that explicit acceptance operation remain separate facts.

**Project and object actions:** Click **Project ▾** at the left of the workspace
tabs, or press **F2** from a tile. For example, from Testing choose **New IP
Library…** to open the same wizard as the `new ip` palette command. In the run
selector, **right-click a run** to open its actions, or press **F3** for the
highlighted run. Opening the menu does not switch workspaces, change your
launch target, or select a run for inspection.

In either menu, use **↑/↓** or **k/j** to move (**10j** moves ten rows), **/**
to filter, and **Enter** or a click to choose. While filtering, `j` and `k`
type letters. **Esc** leaves filtering; **Esc** again returns to the tile.

The workspace accepts terminal mouse input by default. Click a workspace tab
to switch immediately, or click a tile to focus it. In Runs, clicking a run
highlights it; **Enter** still applies that run
to the workspace. Wheel down/up over the focused tile browses like **j/k**. A
wheel over another tile does nothing until you click to focus it. **Ctrl+wheel**
moves focus like **Tab/Shift+Tab** within the current workspace. Palettes and
modal views prevent clicks and wheels from reaching tiles underneath.

If your terminal uses Ctrl+wheel for zoom, or tmux handles the wheel itself,
Silver only receives the events they forward. Tab and Shift+Tab work either
way. Start the client with `--no-mouse` for terminal-native text selection and
scrollback.

1. **Space c c → Apply default layout (add missing tiles)** supplies the dashboard
   while preserving existing tiles, pins and contexts.
2. Use **Tab** to focus the run selector and **Enter** to select the registered run.
3. Use the palette's **Inspect timing paths**, **Inspect clocks**, **Inspect physical**,
   **Inspect routing**, or **Browse reports/artifacts** commands.

Timing inspection now opens a composed **Timing investigation workspace** with
Paths, Selected path and Provenance panes; Tab changes panes and Enter requests
selected detail. Esc closes its detail reader; workspace navigation returns to
Overview. See [current Timing controls](docs/frontend_refinement.md).
Other rich inspectors remain full-window, client-local views attached to the
initiating tile. Enter opens a row detail; Esc returns to the table, then closes
the inspector. Switching to the already-active Overview does not dismiss a retained
non-timing inspector. `/` filters, `s` sorts and `c/g/p` cycle corner/group/producer.
See [all controls and evidence](docs/fs1_investigation.md#timing-paths-and-navigation).

**Finalize**, **Finalize and accept**, and flow-launch commands start work;
Inspect/Browse commands read existing evidence. `q` exits from the normal workspace;
Ctrl-C exits from every mode while daemon work continues. Domain refresh remains
polled, but local input redraw is immediate. If tmux delays Escape, the explicit
server-wide setting `tmux set-option -s escape-time 10` reduces its ambiguity wait;
see the [measured followup](docs/fs1_investigation.md#escape-responsiveness-in-tmux--2026-10-16-followup).

**Historical FS0 comparison:** the 673/685 two-run state at
`/tmp/opencode/workbench-fs0-91em64rl/real/state` is retained with its original
configuration identity. The upgraded example config does not automatically open
that registry. Its original commands/screens remain in [FS0 acceptance](docs/fs0_acceptance.md);
`test-fs0.py --reopen-real` mutates that selected state and is not the fresh-state
manual demo above. Preserve it and use private copies with matching configuration
for historical acceptance replay.

Run repository checks serially because they share Dune's build lock:

```sh
./scripts/with-switch.sh dune build -j20 @fmt
./scripts/with-switch.sh dune build -j20 @lint
./scripts/with-switch.sh dune runtest -j20
./scripts/with-switch.sh dune build -j20
```

Relevant integration checks, when changing those boundaries:

```sh
FIXTURE_OPAM_SWITCH=5.2.0+ox ./scripts/test-fixture.sh
./scripts/test-native-application.sh
./scripts/capture-terminal-baseline.sh --check
python3 -B scripts/test-fs0.py
```

The fixture uses an explicitly selected compatible switch. The installed-application
script tests an isolated install; legacy capture checks retain the original inspector
baselines, while `--capture-fs0 DIR` captures the new host with synthetic fixtures.
Historical toolchain investigations and detailed acceptance
records remain in the [archive](docs/archive/README.md). Record new phase evidence
in the construction plan rather than starting another general development diary.
