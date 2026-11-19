# WB-040 real export acceptance

`test/integration/streaming_export.py` is an opt-in whole-application test. It uses
the production daemon, HTTP transport, terminal PTY and export implementation.
Inputs are explicit prebuilt FIFO provider/simulator executables and the example's
retained ASIC demo manifest. A recording executable replaces the graphical viewer;
its receipt is written only after opening and hashing the published file.

The runner creates a private project, daemon state, client state and temporary
directory under `/tmp/opencode/wb040-real-export-*`. It starts/stops only its own
processes. ASIC evidence is read through the real provider with an exact read-only
command allowlist. Input hashes are checked before and after. No EDA, installation,
owner-session configuration change or implicit build occurs.

## Run

Build the Silver binaries explicitly if needed, using the shared build budget:

```sh
flock /tmp/opencode/workbench-pt8-build.lock \
  ./scripts/with-switch.sh dune build -j2 terminal/main.exe daemon/main.exe
```

From `silver/`, run each case independently (replace `asic` with `simulation` for
the 64 MiB case). Paths below select the currently prepared sibling example:

```sh
./scripts/with-switch.sh python3 -B test/integration/streaming_export.py \
  --case asic \
  --daemon _build/default/daemon/main.exe \
  --client _build/default/terminal/main.exe \
  --fifo-provider ../hardcaml_asic_example/_build/default/ip/controlled_fifo/verif/simulation/test_provider.exe \
  --fifo-simulator ../hardcaml_asic_example/_build/default/ip/controlled_fifo/verif/simulation/fifo_sim.exe \
  --asic-manifest ../hardcaml_asic_example/.dev/workbench-real-demo/manifest.json
```

Omitting `--case` runs simulation then ASIC, stopping on the first failure. These
tests are not in `@runtest`, `@test-local` or `@test-native-smoke`: they require
external prepared executables/retained evidence and can spend two minutes exporting
one trace. The overall budget is 600 seconds; the application's 120-second export
deadline is unchanged. Run the cases serially.

## Assertions

- **Simulation:** launch the actual FIFO `export-stress` case through the daemon,
  require Passed, a 64 MiB registered VCD and the independently verified seed-42
  digest. Use the actual terminal's external-viewer command. Check completed file
  size/digest, exact attempt/artifact metadata, private permissions, verified
  publication, no leftover partial export, and handoff within the policy deadline.
- **ASIC:** register the manifest's original allocation, load its real summary and
  finalization, and obtain the GDS through `List_artifacts`. Select it in the actual
  Reports/Artifacts UI and press `b`. Check source/export/recording-viewer digest
  equality, size, exact run/finalization identity, metadata, private publication,
  cleanup, deadline and unchanged source evidence.

`checks.json`, `inputs.json`, `exports.json`, provider-call logs, PTY captures and
`result.json` retain the outcome and binary provenance. A failed export additionally
writes its final screen and a receipt reporting any partial storage and whether
the recording viewer ran. Failure returns a nonzero exit status, not a skip or xfail.

## Results — 2026-11-19

### ASIC: passed

Evidence: `/tmp/opencode/wb040-real-export-ohrrlpiw/`.

All **10 checks passed**. The actual **4,751,922-byte GDS** exported and reached the
headless viewer in **11.52 seconds**, with SHA-256
`4b22e17aa21b1b6ea97296e07369179f8f5dcaf886dae256335da01217f82daf`.
The captured run/finalization reference and source bytes were preserved. This
closes the shared ASIC binary handoff acceptance item; it is not a new physical
design/signoff qualification or a measurement at the 16 MiB upper boundary.

### Initial 64 MiB simulation: blocked by export timeout (fixed below)

Evidence: `/tmp/opencode/wb040-real-export-23wxtlws/` (also reproduced in the first
run, `/tmp/opencode/wb040-real-export-tb2n90u7/`).

The real simulation **passed**, registering exactly **67,108,864 bytes** with the
expected SHA-256
`a4662d87338898d3b328a56a9d74692adf2cfc21701c62d21c96c0a0a9b8952e`.
The actual client then reported **“Export cancelled or timed out”** at its export
deadline. At the test's final check (~125.6 seconds, allowing for cleanup), there
was **no viewer launch and no remaining partial export**. The success assertion
correctly fails.

This kept WB-040 `partial` until the fix below. The previous
`backend/artifact_file.ml` hashed the complete artifact for every 64 KiB page:
64 MiB entailed roughly 64 GiB of logical read/hash work. The regression is preserved
at its original size and deadline.

### Fixed: both real paths pass together

Evidence: `/tmp/opencode/wb040-real-export-ob2okfku/`. **All 19 checks passed**:

| Path | Bytes | Export + headless handoff |
| --- | ---: | ---: |
| Real FIFO VCD | 67,108,864 | 7.51 seconds |
| Retained ASIC GDS | 4,751,922 | 11.33 seconds |

The new backend index stores at most 32 KiB of SHA-256 block digests from one
full-file verification scan. Each warm read authenticates the complete blocks
containing its requested slice. A device/inode/size/nanosecond-mtime/ctime change
forces a full rescan; a post-read fingerprint check rejects races. The cache
retains neither whole-file bytes nor descriptors, and the client still checks the
whole exported file's registered digest before verified publication and handoff.

Focused file, ASIC-artifact and simulation-service tests passed, including warm
cross-block/EOF slices, atomic inode replacement and out-of-page tampering with
exact size and mtime preserved. The existing per-operation allocation ceiling
of 2 MiB still passes. The deterministic cancellation test passed all 21 checks
against the rebuilt applications (`/tmp/opencode/pt8-waveform-pty-zl3h0uzi/`).

WB-040 is now `closed` within the owner-approved limits and headless acceptance
scope. Historical failures above remain recorded rather than being overwritten.

The separate deterministic cancellation test remains documented in WB-040 and
selected by `@test-native-smoke`. Manual reaction-speed cancellation is unnecessary.
