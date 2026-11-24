# Structured simulation, reruns and trace evidence

Use the [Testing workspace guide](testing_workspace.md) for day-to-day
simulation and [waveform inspection](testing_workspace.md#embedded-waveform-viewer).
The structured provider enumerates suites and cases separately from generic
`dune runtest` jobs. A test attempt is scoped to the project; it does not
automatically inherit the run viewed in an ASIC workspace.

## What an attempt records

- A suite, selected cases, a uint64 seed, and declared parameters.
- Case progress, outcomes, failure messages, logs, and reports. Process exit
  and semantic result are distinct; an invalid or incomplete event stream
  cannot create a successful attempt.
- A rerun of one selected case or all failed cases creates a new attempt
  linked to its parent, using the original seed and parameters. It uses the
  current project and provider environment, not an archived build or source tree.
- Accepted partial results survive cancellation. Restart does not replay
  unfinished attempts. History, live job logs, and retained artifact copies have
  separate retention limits; a historical attempt may no longer have live logs.

For execution and wire details, see the
[simulation provider contract](simulation_provider_contract.md).

## Try it

The [Cyclesim counter](../examples/cyclesim_counter/README.md#build-configure-and-open)
is a PDK-free Dune project with a native provider, reset/wrap cases, a seeded
case, and actual VCD waveforms. For a deliberate mismatch, set
`inject_failure` to `true` and inspect the result and report in Testing.

For an external viewer, pass `--simulation-viewer /absolute/viewer-executable`
to Silver. This is an alias of its binary-viewer option: the executable runs
on the client host and receives one private local filename. To supply extra
arguments, use a wrapper. Viewing retained evidence does not require the
project's simulation provider to remain configured.

### Terminal controls

The [Testing workspace](testing_workspace.md) is the normal entry point.
To use the standalone simulation tile, open **Space c c**, choose
**Add simulation tile**, and focus it with **Tab**. Use the palette to
discover suites, open a launch form, reopen an attempt, page the history,
rerun cases, cancel the selected attempt, and export or open an artifact.
Discovery enumerates suites and cases; it never launches a test.

| Control in the simulation tile | Effect |
| --- | --- |
| `j` / `k` | Browse attempts on the current history page |
| `n` / `p` | Select a case |
| `l` | Toggle stream-labelled current-job logs |
| `[` / `]` | Scroll wrapped detail or log content |

Two tiles can retain independent selections. Hiding a tile stops its
observation polling, not its producer.

## Limits

Provider v1 discovers a bounded static catalog. Optional ASIC inputs are
exact references, not automatic staging of collateral. History is bounded
working storage, not archival retention. A missing or corrupt artifact
remains unavailable; Silver does not substitute another attempt's evidence.
Reconnecting does not automatically resubmit a launch with an unconfirmed
receipt; check the newest history first.
