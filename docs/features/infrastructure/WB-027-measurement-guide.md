# WB-027 measurement guide

This is a diagnostic baseline, with **synthetic evidence**, for owner review.
It measures Workbench behavior using the real daemon HTTP transport and terminal
client. It does not run physical flows or measure DUT performance.

## Reproduce

From this worktree, using the installed read-only toolchain:

```sh
scripts/with-switch.sh dune build -j 3 daemon/main.exe terminal/main.exe
python3 -B scripts/measure-workbench-performance.py --self-test
python3 -B scripts/measure-workbench-performance.py \
  --daemon _build/default/daemon/main.exe \
  --client _build/default/terminal/main.exe \
  --rows 256,1024 --tiles 1,24 --samples 3 --slow-delay 1 --budget 600
git diff --check
```

Build and measurement commands run **serially**. Reserve the session's five-job
allocation for measurement: Python harness, daemon, terminal client and provider
children; do not run a concurrent build. The build uses three Dune jobs and does
not claim the server-wide allowance. No Git-writing commands are needed.

Requires Linux `/proc`, Python 3 standard library, a PTY, the two supplied
executables, and the existing `/tmp/opencode` parent. No installation is performed.
Every run prints a fresh private evidence directory. No output directory is
reused. HOME, XDG configuration/cache/state, TMPDIR, daemon discovery/state,
project, results and endpoint (`--port 0`) are private. Permission prompts in the
application are not disabled. Provider commands are allowlisted read-only calls;
build/EDA/Git commands are denied in the runtime environment. Dune project
discovery receives explicitly synthetic version/workspace metadata. The owner
manual-validation project and shared dependencies are not runtime inputs.

For a small smoke, use `--rows 256 --tiles 1 --samples 1 --storage local
--budget 120`. For the default larger case, omit the rows/tiles arguments:
1024 rows, 24 tiles, three samples, both storage conditions, a ten-second stall.
Use `--help` for bounds. Maximum 40 trials, 20 samples per cell, 200 tiles,
1800 seconds overall; evidence rows must fit the conservative 1500 KiB row budget
below the production 2 MiB inspection limit. Incompatible sizes fail before launch.
The overall deadline includes setup; shutdown has bounded grace periods beyond it.

## Workload and attribution

Each matrix cell/sample creates an independent project and generated retained
run from `demo/synthetic_flow/provider.py` / `scenarios.json`. The timing index
contains deterministic unique path rows with 256 bytes of source padding by
default. 256 rows represents a small inspection and 1024 approximates the
existing 1020-path retained latency fixture. One and 24 additional timing tiles
exercise a small and larger workspace; built-in tiles are recorded separately.
All timing tiles share one selected run/index. Some tiles extend offscreen in
the 200×60 PTY: this is retained workspace scaling, not 24 independent datasets
or 24 simultaneously visible tiles. These are representative test shapes, not
an owner-approved distribution of real sessions.

1. **Cold:** new daemon and empty Workbench state; register the retained synthetic
   run, load its summary, then publish an inspection index. Assert one provider
   index call, exact row count and SHA-256 source digest. Summary preloading at
   registration is recorded rather than assumed absent.
2. **Warm/L1:** reopen the same summary/index. Assert unchanged payload and no
   additional provider reads.
3. **Restart/L2:** terminate the daemon, restart with the same private state,
   verify a changed daemon instance ID and restored workspace, then reopen.
   Assert identical payloads except cached-unverified freshness, and zero provider
   calls. The explicit reopen duration and daemon startup/open duration are
   separate; eager loading during startup is not attributed solely to reopen.
4. **Host input:** start the real terminal client in a PTY and select WB027 by
   palette command. Check the active workspace header/breadcrumb. Measure query
   text appearing in the reconstructed palette and standalone Escape returning
   to the workspace. Repeat while a provider read is pending.
5. **Transport/cancel:** during a separate 15-second minimum read hold, measure
   HTTP dispatch acknowledgement, Get round trip, Cancel acknowledgement and
   cancellation reaching a terminal operation state. Verify cancellation error
   identity and that the read is still pending before Cancel.

`local` reads generated JSON normally. `synthetic-slow` sleeps immediately before
that same read for `--slow-delay` seconds. This repeatable injected **read stall**
is a controlled slow-storage surrogate, not physical disk/network throttling.
Both conditions also receive the separate hold for responsiveness/cancellation.
No OS caches are dropped: “cold” means Workbench-cache cold, not disk-cache cold.

## Outputs and interpretation

- `result.json`: all raw timing observations, per-cell nearest-rank p90/p95,
  min/median/max/mean/sample standard deviation, failures, timeout lower bounds,
  resources and cleanup audits. Successful samples alone enter distributions;
  never interpret a censored timeout as a fast success. With three observations,
  p90/p95 are simply the maximum, not a reliable tail estimate.
- `invocation.json`: options, environment, executable/script SHA-256 identities.
  Each trial's `fixture-identity.json` identifies exact evidence and execution
  bytes. Generated absolute paths vary across runs; row evidence hashes remain
  deterministic for a given shape.
- Trial `http.jsonl`, provider calls/completions, PTY ANSI/events/keys/screens,
  daemon logs, state and fixture files retain attribution. Setup failures retain
  a failed result; timeout screens have separate records. Failures exit nonzero;
  completed PTY timeouts are explicitly `completed-with-timeouts` and require
  review of JSON, not just the process exit code.
- Memory is Linux RSS/HWM/virtual/anonymous/file and PSS/private/swap where
  accessible, with PID/start-time identity at named checkpoints. Client memory
  is sampled after tile rendering and cancellation. These are process point
  samples, not process-tree peaks; HWM is lifetime high-water RSS.
- Disk records logical and allocated regular-file bytes separately for retained
  daemon state, synthetic fixture and the entire evidence tree. The
  `instrumentation`/`all_evidence` totals **include** state and fixture; they are
  not additive categories. Counts are snapshots before the final result write,
  not exact final directory totals, and exclude directory metadata.

Loading is dispatch through observed publication, including HTTP transfer,
Python parsing/logging and polling. Warm loading deliberately still transfers
the real evidence payload. PTY latency is input-write to reconstructed visible
text, an upper bound including output read/ANSI reconstruction. It does not
measure a physical display or compositor. Palette setup/drain delays occur
outside the timed key intervals. A timed-out Escape is recovered with NUL only
after recording the censored sample.

Instrumentation records 100 clock-pair and ten `/proc` probe timings, the 20 ms
poll interval and up-to-10 ms PTY select wait. Resource/disk probes occur outside
the main latency intervals. There is no overhead subtraction or paired
uninstrumented run: Python provider startup, parsing, logging and screen
reconstruction remain uncalibrated components of the observed upper bounds.
No production instrumentation was added.

Unsupported: OCaml allocation/GC counts, physical/remote slow storage, OS-cold
I/O, device-level I/O, process-tree peak memory, inspector row filtering/detail
latency, beyond-cap inspection payloads, tmux/browser transport and physical
display latency. Small sequential samples on a shared host do not establish
confidence intervals or causality. Compare cells cautiously; increase samples
in separate bounded runs and alternate condition order externally if needed.

## Proposed thresholds — not owner-approved

These are review candidates for this exact 1024-row/24-tile workload and host
transport, not pass criteria enforced by the diagnostic harness or delivery SLOs:

| Candidate | Proposed review threshold |
|---|---|
| Palette input and Escape, idle and stalled | p95 ≤100 ms, zero censored samples |
| Get during stall / Cancel acknowledgement | p95 ≤250 ms |
| Cancel to terminal state | p95 ≤500 ms |
| Local cold index load | p95 ≤1000 ms |
| Warm / restart explicit index reopen | p95 ≤500 ms each |
| Synthetic slow cold load | p95 ≤injected delay +1000 ms |
| Cache correctness | exactly one cold index read; zero L1/L2 provider reads |
| Daemon/client RSS after rendering | each ≤256 MiB, review ≥20% matched-baseline growth |
| Retained state at shutdown | ≤8 MiB for this bounded fixture; review ≥20% matched-baseline growth |

Owner review must settle representative hardware/session sizes, sample count and
budgets before these become acceptance gates. Review disk and memory growth
against identical fixture bytes and tile counts; this harness does not establish
long-session leak freedom. See [recorded results](WB-027-baseline-results.md).
