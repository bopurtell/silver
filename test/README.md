# Workbench tool-test entry points

Tests are mostly **owned by their subsystems**, not collected as source files here.
This directory is the suite index, shared test support and fixture/baseline storage. The
application's **Testing workspace** runs project-declared cases; that is a different
thing from the tests of Workbench itself.

Start with [the ownership guide and source map](../docs/testing.md).

## Select existing suites

| Root alias | Existing owners selected | What it means |
| --- | --- | --- |
| `@test-contracts` | protocol, provider, project integration, adapters, pyramid harness controls | Wire/config/argv contracts and controlled runner tests; no real EDA |
| `@test-presentation` | terminal, workspaces and terminal-local tests | Production parsing/state/rendering/input plus focused persistence/handoff integration |
| `@test-backend` | backend/test recursively | Service/process/cache/storage and controlled-provider integration |
| `@test-setup` | setup/test | Initialization/config/CLI/filesystem integration |
| `@test-api` | daemon/test | Native local HTTP/RPC server integration |
| `@test-support` | test/support | Shared PTY/screen helper contracts and compatibility imports |
| `@test-native-smoke` | terminal waveform handoff | Opt-in synthetic daemon/client HTTP/PTY integration |
| `@test-native-standalone` | installed `silver` and persistent daemon | Opt-in project discovery, locking, retained state and PTY quit/reattach lifecycle |
| `@test-local` | contracts + presentation + backend + setup + support | Aggregate; **excludes API, native smoke and real EDA** |

Shared-support tests participate in `@runtest`; native smoke is opt-in.
Local tests may start subprocesses, create Git fixtures and run nested builds.
Use the same build directory and lock as the example launcher when testing a
checkout used by both repositories:

```bash
flock /tmp/opencode/workbench-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j2 \
  --build-dir _build_workbench @test-contracts @test-presentation
```

On a resource-constrained machine, run backend and setup separately with `-j1`:
setup intentionally starts twelve initializer processes. To run the PTY waveform
smoke test and the support library controls from fresh sandboxes:

```bash
flock /tmp/opencode/workbench-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j2 \
  --build-dir _build_workbench --sandbox=copy --force @test-support @test-native-smoke
```

## Opt-in real fresh-prefix tests

### Classic Bluespec front end

With the worktree's Silver installed and the [Bluespec starter
toolchain](../examples/bluespec_classic/README.md) on `PATH`:

```sh
python3 scripts/test-bluespec-frontend.py
python3 terminal/test_bluespec_pty.py
python3 test/integration/bluespec_fifo.py
python3 test/integration/bluespec_ip.py --author "$(command -v silver-author)"
```

The first starts with an empty directory, launches project actions and checks
both correct and mutated RTL through the real daemon, including retained
waveform data after restart. The second exercises the local terminal, Cobalt,
Testing, and the waveform viewer. The third builds a separately synthesized
child backed by BSC's FIFO primitive and checks the FIFO data in the trace.
The last authors reusable IP, imports it in the design and proves that
changing only the dependency changes the Verilator result.
None requires an ASIC toolchain.

### ASIC flow

For the real FIFO 64 MiB export and retained ASIC GDS handoff, use the
[streaming export acceptance runner](../docs/streaming_export_acceptance.md).
It lives at `test/integration/streaming_export.py`, takes explicit prebuilt and
retained-evidence inputs, and is not selected by the default/local/native-smoke
aliases. Both real paths pass after the bounded authenticated-block index fix;
the simulation case retains the 64 MiB/120-second timeout regression gate.

Each endpoint alias runs one independent fresh build/emission and its entire selected
physical prefix. **None is selected by `@runtest`, `@test-local`, or `@all`.**

| Alias | Selection |
| --- | --- |
| `@test-real-elaboration` | Build/emission only |
| `@test-real-synthesis` | Fresh through synthesis |
| `@test-real-floorplan` | Fresh through floorplan |
| `@test-real-placement` | Fresh through placement |
| `@test-real-cts` | Fresh through CTS |
| `@test-real-routing` | Fresh through routing |
| `@test-real-timing` | Fresh through timing |
| `@test-real-signoff` | Fresh through signoff; potentially long-running |
| `@test-real-pyramid` | All eight fresh runs, serially; explicit large-change qualification |

An explicit `HARDCAML_WORKBENCH_REAL_TEST_CONFIG` is required. All selected real
aliases rerun, rather than returning a cached EDA success. The runner's inexpensive
controls alone join ordinary tests. See [configuration, commands and actual
verification](../docs/real_prefix_pyramid.md). Real Elaboration and Synthesis passed;
the later endpoint selectors/full pyramid are implemented but not yet executed here.

## Data stays data

`test/dune` marks these children data-only:

- `fixtures/`: specimen inputs, including a separate miniature Dune project.
- `baselines/`: retained expected terminal output.

Their nested Dune files are fixture data rather than Workbench build targets.

`test/support/` contains shared screen reconstruction and the PTY driver.
`test/integration/pyramid/` contains real-flow integration and its runner tests.
