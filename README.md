# Silver

Formerly Hardcaml Workbench. The repository is now
[`bopurtell/silver`](https://github.com/bopurtell/silver), checked out as `silver/`.
Existing `hardcaml-workbench` commands, `hardcaml_workbench*` packages and OCaml
modules, configuration filenames, environment variables, and saved state paths
remain supported under their existing names.

A development workbench for inspecting, running, measuring, and debugging Hardcaml designs.

## Install and open Silver

For ASIC projects, install [hardcaml_asic](https://github.com/LeEmperor/hardcaml_asic#install-the-provider) first.
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

[Empty-directory synthesis acceptance](docs/authoring_acceptance.md) exercises
this starter with installed tools, then rebuilds it in a clean clone and checks
the CLI synthesis result against Silver's.

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

**Manage This Project…** opens a centered window over your current workspace.
Browse libraries, chips, flows and profiles without changing the launch target.
The **Filter** button and `/` work with shortcuts hidden. To display shortcuts,
choose **Show project browser control hints** from the command palette.
Finishing or cancelling an authoring wizard takes you back to the same browser
selection; **Esc** returns to the inspection you started from.
[Project browser controls](docs/features/workspaces/WB-086-owner-trial.md).

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
rewriting your OCaml.

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

## Documentation

- [Documentation index](docs/README.md) — setup, operation and provider integration.
- [Cyclesim counter example](examples/cyclesim_counter/README.md) — build a four-bit counter, generate local provider configuration, and run directed and seeded cases without ASIC tools.
- [Testing workspace](docs/testing_workspace.md) — discover suites, launch cases, rerun a failure and inspect its waveform or report.
- [ASIC checklist](docs/checklist_launch_workflow.md) and [synthesis inspection](docs/synthesis_inspection.md) — launch a stage and inspect the evidence from that run.
- [Compose windows and workspaces](docs/workspace_configuration.md) and [restore a layout](docs/default_layout_restore.md).
- [Overview and theme picker](docs/overview_sidebar.md#live-color-schemes) — press **Space c c**, type `theme`, and press **Enter**. Preview with the arrow keys, **Enter** to keep, **Escape** to cancel.
- [Silver's test suites](test/README.md) — run checks on Silver itself, independently of the hardware tests in the Testing workspace.

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
[the simulation setup guide](docs/features/project/WB-039-simulation-setup.md).

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
for the example provider configuration and verified client/daemon pair;
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
`refresh-binaries` after future builds.

### Repository checks

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
./scripts/with-switch.sh dune build -j4 @test-native-standalone
```

The fixture uses an explicitly selected compatible switch. The installed-application
script tests an isolated install; the baseline check compares rendered terminal output.
