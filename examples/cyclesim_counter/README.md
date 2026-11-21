# Hardcaml Cyclesim counter example

This is an independent, PDK-free Dune project. `test_provider.exe` uses Silver's
public provider library to run the separate `counter.exe` hardware checker.
The checker uses Hardcaml Cyclesim; neither executable needs an ASIC provider,
physical tools, or the Silver backend. The Python adapter and fixture codec are
independent conformance references, not requirements for using the example.

## Build, configure, and open

Install [Silver](../../README.md#install-and-open-silver) first (`--without-asic`
is sufficient). Its installer also installs `hardcaml_workbench_provider`. From
the Silver checkout, use the same opam switch and installation prefix (the
defaults are shown below):

```sh
prefix="$HOME/.local"
switch=5.2.0+ox
example="$PWD/examples/cyclesim_counter"

OCAMLPATH="$prefix/lib${OCAMLPATH:+:$OCAMLPATH}" \
  opam exec --switch="$switch" -- dune build --root "$example" \
  counter.exe test_provider.exe

"$prefix/bin/silver-simulation-setup" init --root "$example" \
  --provider-executable "$example/_build/default/test_provider.exe"
"$prefix/bin/silver-simulation-setup" check --root "$example"
"$prefix/bin/silver" --project-root "$example"
```

`init` writes the local, ignored `.workbench/hardcaml-workbench-simulation.sexp`.
It never overwrites existing configuration. If you move the checkout, update
the executable path in that file or regenerate it after moving the old file
aside. The provider finds `counter.exe` beside itself by default. Neither
Silver nor the provider builds the example.

In Silver, [discover the `counter` suite and launch a simulation](../../docs/structured_simulation.md#terminal-controls).
Select any of `wrap`, `reset`, `seeded`, a canonical uint64 decimal seed, and all
parameters:

| Parameter | Default | Domain |
|---|---|---|
| `cycles` | `64` | integer 32..100000 |
| `step` | `1` | `1`, `3`, `7` |
| `inject_failure` | `false` | `false`, `true` |

An injected failure flips the expected value at cycle 17: the DUT remains real,
the checker reports the observed mismatch, and case/suite outcome is `Failed`
with process exit zero. Domain/launch errors instead terminate the provider with
nonzero exit and an incomplete structured stream. Every case emits live flushed
progress, a closed actual VCD, a closed check report, and an explicit result.
Full uint64 seeds are converted to the same signed 64-bit LCG bit pattern without
floating-point conversion. ASIC references are empty for this project-only demo.

## Standalone hardware proof

From the Silver checkout, using the prebuilt example:

```sh
python3 scripts/test-cyclesim-provider.py \
  --counter "$PWD/examples/cyclesim_counter/_build/default/counter.exe"
```

The proof retains requests, event streams, stdout/stderr, reports, VCDs and hashes.
It checks directed wrap and synchronous clear, a fixed-LCG seeded enable pattern,
maximum uint64 seed, repeated signal-body equality, and injected checker failures.
Each cycle compares the simulated four-bit register against an independent integer
reference model. `Hardcaml.Vcd.wrap` generates the waveform around the actual
Cyclesim circuit. VCD headers contain a date; deterministic replay compares the
signal data body.

## Native migration equivalence acceptance

The following harness takes **prebuilt** executables, never builds or installs, and
creates private projects/configs and daemon state. It compares the native adapter
with the independently implemented Python reference:

```sh
opam exec --switch="${OPAM_SWITCH:-5.2.0+ox}" -- python3 scripts/test-native-provider.py \
  --only counter \
  --counter-provider "$PWD/examples/cyclesim_counter/_build/default/test_provider.exe" \
  --counter "$PWD/examples/cyclesim_counter/_build/default/counter.exe"
```

Add `--daemon /absolute/path/to/silver-daemon` to include HTTP and restart checks.
`--evidence` names a new directory; the default is a fresh
`/tmp/opencode/native-provider-*` directory.
It compares parsed discovery and every event for full suites and individual cases,
zero/max-uint64 seeds and real injected checker failures, then compares report
bytes and all VCD bytes except the date stanza. Invalid native selections must
exit nonzero before any event/artifact. HTTP mode checks captured selections,
paged artifact bytes/digests and persisted attempts after a private daemon restart.

## Native HTTP and terminal acceptance

Using the installed Silver commands and the prebuilt counter:

```sh
prefix="$HOME/.local"
opam exec --switch="${OPAM_SWITCH:-5.2.0+ox}" -- python3 scripts/test-native-simulation.py \
  --daemon "$prefix/bin/silver-daemon" \
  --client "$prefix/bin/silver" \
  --counter "$PWD/examples/cyclesim_counter/_build/default/counter.exe"
```

The script launches a real private daemon and uses native HTTP S-expressions. It
creates a project/config/state/home/tmp tree in `/tmp/opencode/fs2-native-*` and
retains raw request/response JSONL, daemon logs, terminal screens, a viewer
receipt, the exported VCD, and `result.json`. Add `--skip-pty` for an HTTP-only
check.
The harness never invokes a build. Run it in the selected switch environment so
the daemon can inspect the empty Dune fixture project.

Checks include deduplication/conflict, targeted rerun lineage and captured inputs,
semantic failure versus process failure, malformed/duplicate/truncated/gapped/
wrong-identity/post-terminal streams, missing artifacts, partial cancellation,
discovery mismatch, real Cyclesim/rerun, multi-page arbitrary-byte/hash transfer,
two independent simulation tiles, explicit terminal viewer handoff, durable
history after restart without replay, unclean daemon interruption with retained
partial results, corrupt history, and changed/missing private artifact copies.
The PTY also edits the delivered multi-step launch form, observes a real checker
failure and job logs, and submits a distinct targeted rerun through the palette.
The recording viewer actually runs as an external executable with the exported
local file; no graphical viewer is needed.

## Deterministic fault fixture

`scripts/fixtures/simulation_fault_provider.py --control ABS_JSON --calls ABS_JSONL`
is an alternative provider prefix. Control is `{"mode":"pass"}` and is read on each
invocation; calls append operation/mode/request records. Its two cases are `first`
and `second`, seed default `42`, with no parameters. Supported modes:

`pass`, `fail`, `malformed`, `duplicate`, `truncated`, `gap`, `wrong-attempt`,
`missing-finished`, `post-finished`, `nonzero`, `slow`, `cancel`,
`missing-artifact`, `rejected-artifact`, `discovery-malformed`,
`discovery-version`, `discovery-mismatch`.

`slow`/`cancel` finish the first case then emit indeterminate progress for up to
60 seconds in the second, allowing supervisor cancellation or daemon interruption.
Binary fixture traces deliberately contain NUL, non-UTF8, CRLF and exceed one
64-KiB byte page. Changed/missing durable evidence is tested by modifying only
the harness's own copied daemon artifacts after a valid capture.
