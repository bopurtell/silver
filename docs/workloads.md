# Workloads: launch, inspect and compare results

For everyday FIFO and memory-workload development, use the example's
[checkout-backed launcher](https://github.com/LeEmperor/hardcaml_asic_example/blob/main/docs/workbench_main.md).
For the workflow in Silver, see [Workloads workspace controls](workloads_workspace.md).

## What “workload” means here

**The workload is the scenario contract; stimulus is one of its components.**
It specifies input operations/data together with execution assumptions and rules,
completion, defined expected observations and measurement rules/window. The testbench
driver, assertions/reference model/checker and monitors implement those requirements;
they can remain reusable environment components rather than one monolithic object.
For UVM users, sequence items correspond to raw stimulus, and a sequence/virtual
sequence corresponds to the traffic part of a workload. The full contract also
covers rules normally distributed across test configuration, checking and monitors.

| Term | Meaning in this workflow |
| --- | --- |
| Stimulus | Raw operations, transactions and logical input data |
| Workload | The stimulus plus scenario assumptions/rules, completion, expected behavior and measurement rules |
| Test/case | A runnable configuration that executes a scenario and checks its behavior |
| Suite | A collection of selectable cases |
| Attempt | One actual execution of selected cases with concrete inputs |
| Result | Outcomes, measurements, identities and retained evidence from that execution |
| Waveform | Recorded signal activity; not the entire verification result |

```text
memory-workloads suite
├── flops256 case → fixed memory workload on the Flops implementation
└── exact256 case → same logical workload on the supported SRAM implementation
```

Conceptually a case may consume several workloads. Today these two cases each
consume one fixed workload, with multiple internal traffic phases. There is no
arbitrary N-workload composition feature or separate workload runner. Hardware
variant, concrete driver/model/image artifacts and execution identities remain
separate from the logical workload. See the
[provider terminology and contract](https://github.com/LeEmperor/hardcaml_asic/blob/main/docs/guides/variant-comparison.md#terminology-stimulus-workload-test-and-suite).

## Inspect and compare retained evidence

Use absolute result paths as seen by the Silver daemon. The paths below are
relative to the example checkout and refer to a previously captured pair; if
those retained files aren't available, [run the two example cases](#run-the-example-workload)
and capture their fresh results instead.

Older Testing attempts may show the original suite ID `pt8-memory-workloads`.
Keep that ID when reopening an attempt; only the current catalog uses
`memory-workloads`.

1. Press **Space c c**, choose **Open Workloads workspace**.
2. Choose **Workloads: Import exact retained result.json** and enter the absolute
   path ending in `acceptance/pt8-workloads/simulation-04/flops/result.json`.
3. After it shows **Validated**, choose **Workloads: Capture A left result**.
4. Import the absolute path ending in
   `acceptance/pt8-workloads/simulation-04/exact/result.json`.
5. Capture **B right result**, then choose **Workloads: Axis resource_policy** or
   **Workloads: Compare captured A / B (c)**.

Captures use the public reader's verified bundle locator, so no bundle-path entry
is needed. The captured pair should show seven **comparable** zero deltas: 1,307
cycles, 525 reads, 262 writes, 787 operations, 2,083 defined observations, latency
of one cycle, and throughput of 787/1307 operations per cycle. This is
logical-cycle evidence, not Fmax or a
physical area/speed winner. Source/provider/simulation identities remain distinct.

Navigation: **Esc** returns to results; **j/k** select or scroll; **Enter** opens;
**d** shows provenance/controls/full identities; **r** explicitly refreshes the
exact source/pair; **/** filters and **Ctrl-U** clears. Swap sends a new ordered
provider query. Merely opening, filtering or resizing the workspace runs no tools.
Restored evidence is labelled **Cached unverified** until explicitly refreshed.

## Run the example workload

On the [prepared and published example checkout](https://github.com/LeEmperor/hardcaml_asic_example/blob/main/docs/workbench_main.md#prepare-publish-then-start),
open Silver using `python3 -B scripts/silver.py open` from the example checkout in
its selected opam environment. If its daemon is already running, use `client`
instead of `open`. In Silver:

1. From the palette choose **Workloads: Launch fresh memory workload… (Testing)**.
2. Select **Memory workloads** (`memory-workloads`) and open the launch form.
3. Select **flops256** (256-word flip-flop memory), **exact256** (256-word SRAM
   macro), or both.
4. Keep seed **34097** (`0x8531`), then confirm **launch**.

This is the supported fixed directed workload; the seed records its identity and
does not generate arbitrary random stimulus. Other seeds/options reject rather
than being ignored. There are no additional workload parameters or ASIC inputs.

The simulation supervisor owns launch, live state, logs, cancellation, durable
history and rerun. Actual emitted implementation RTL executes under Icarus; Exact
uses both unchanged stock SRAM functional model files. No synthesis/P&R/STA starts.
Both cases run sequentially when selected together.

For two independent attempts at once (for example, a memory workload and a FIFO
test), configure the prepared example checkout with
`python3 -B scripts/configure-simulation.py --max-parallel-runs 2`. Start the
updated Silver daemon and submit each attempt separately from Testing. Changing
the limit is not necessary to run the two cases sequentially in one attempt.

When the attempt completes, select the intended case in Testing and choose
**Inspect workload result (selected Testing case)**. This reads its exact
attempt/case-bound reference artifact, checks its byte digest and opens the retained
result with the expected public source digest. Capture it as A or B and compare it
explicitly with the retained result or another fresh result.

### Open the fresh waveform

If the configured provider published a VCD, select the intended attempt and case
in Testing, then focus **Artifacts**. Press **w** for the quick embedded
viewer or **Shift-W** for the dedicated Waveforms workspace. The palette also
offers **Open embedded waveform** and **Open dedicated Waveforms workspace** for
the exact VCD. A JSON cursor can resolve the same case's VCD sibling; it is never
passed to the VCD parser. JSON-only historical attempts explain that no VCD was
published, while their independent Workloads result inspection still works.

The VCD shows clock, enable, active-low write command (`rst_n`, not memory reset),
address (`ui_in`), write low byte (`uio_in`) and response (`q`). Unknown initial
memory responses remain X. At time zero the known lanes render while `q`'s lane says
**X/Z in window; no graph**; exact X values remain visible. This is a bounded
two-state graph fallback, not full four-state plotting. Press **:** and enter
**2595000** (1 ps ticks) in the captured example to view the first defined response,
**13C6**. No storage array or vendor hierarchy dump is produced.

A Testing result-reference artifact points to the retained workload evidence;
it is not a copy of the full bundle.
Simulation success, functional verification and performance availability are shown
separately. Readable failure/partial evidence does not become a performance pass.
