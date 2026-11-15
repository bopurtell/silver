---
id: WB-068
title: Waveform cursor repeat lag and step units
category: verification
feature_sets: [FS2, FS5]
status: needs-triage
kind: defect
priority: P2
severity: S3
requested_size: Unspecified
size: M
points: 8
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [waveforms, cursor, latency, zoom]
depends_on: []
related: [WB-028, WB-067, WB-027]
---

# WB-068 — Waveform cursor repeat lag and step units

## Request
Owner notes, 2026-10-20: repeated h and l in the waveform should just work, rather
than lagging on repeated presses as they do now. This relates to the cursor's tick
scaling: perhaps step by one character column versus one actual timestep should be
distinguished. Reported S3 usability defect; unconfirmed until reproduced.

## Current baseline
`waveform_view.ml` moves the cursor by exactly **one VCD tick** per h/l press
(`t.cursor - 1L` / `Int64.succ t.cursor`), whatever the zoom. When one screen column
covers many ticks (the ruler's compressed mapping), several presses can leave the
cursor in the same column, so it looks stuck or laggy. Each keypress also rebuilds
the view; per-key render cost has not been measured. `:` jumps to an absolute tick.

## Scope
- Reproduce and measure: per-key latency under held-key repeat at representative
  zooms and trace sizes, separating render cost from "no visible movement".
- Two explicit step units: **column** (move to the next/previous screen column's
  tick) and **tick** (one raw timestep). Pick the default and a key for the other.
- Optional: jump to the focused signal's next/previous value change.
- Keep keypresses from queueing up behind slow renders, e.g. by coalescing repeats.

## Out of scope
Count prefixes (`20 l`), which are WB-067. Lazy trace loading and four-state
graphics remain WB-028.

## Acceptance criteria
- [ ] Recorded before/after latency for held h/l on a bounded fixture.
- [ ] In column mode, every press moves the cursor at least one visible column.
- [ ] Tick mode moves exactly one timestep and shows that unit in the ruler or help.
- [ ] Holding h/l for 2 s stops within one frame of release, with no queued backlog.
- [ ] Cursor never leaves trace bounds; off-screen indicators stay correct.

## Dependencies
None required. WB-067's counts multiply whichever step unit this ticket defines.
WB-027 measurement tooling can be reused for the latency record.

## Estimate rationale
8 points, medium confidence: the step-unit change is narrow. Render coalescing may
need deeper view changes if profiling shows it is the main cost.

## Assumptions and decisions needed
- Default unit: column on `h/l` (and left/right arrows); exact tick on `H/L`.
- Value-change jumps are deferred.

## Delivery notes — 2026-11-05

Implemented on `bpurtell/waveform-cursor-stepping`, based on `oxcaml`, in
`../bpurtell-feature2`. Delivery evidence below is engineering verification;
owner acceptance and the acceptance checkboxes remain pending.

### Behavior and implementation

- Column navigation uses the actual prepared integer raster, including resize and
  quick-view geometry, anchored at the viewport start rather than tick zero.
  In compressed views it targets the adjacent column's first tick; in expanded
  views it moves one tick to the next distinct cursor position (possibly several
  cells). Bounds saturate at the inclusive trace endpoints, including Int64.max_value.
  At a trace endpoint/partial final column, clamping can prevent visible movement.
- `H/L` moves exactly one tick, except at the corresponding trace endpoint.
  Waveform help now states both units. Off-screen navigation brings the cursor
  back into view using existing viewport-follow behavior.
- No extra repeat queue/coalescer was added: the installed Bonsai-term event loop
  drains pending input before rendering, cursor state updates are synchronous,
  and stationary-window movement retains the native graph cache. The measured
  defect was same-column movement, not sustained render backlog.
- Filter editing and the text-editing helper were not changed. Count prefixes
  remain WB-067; optional value-change jumps are deferred.

### Before/after evidence

Real PTY, 180×50, eight selected buses; small fixture: 8 signals / 16,384 changes /
226,568 bytes; large: 128 signals / 393,216 changes / 5,585,290 bytes.
Each fixture/zoom has 16 isolated h/l samples and four two-second holds
(both directions at 30 and 120 Hz). Expanded/default/compressed raster scales
are respectively 16 cells/tick, 2 cells/tick, and 16 ticks/cell.

| Fixture / zoom | Before median header latency | After median header latency | Same-column singles before → after |
| --- | ---: | ---: | ---: |
| Small / expanded | 3.50 ms | 3.21 ms | 0/16 → 0/16 |
| Small / default | 4.86 ms | 2.81 ms | 0/16 → 0/16 |
| Small / compressed | 2.52 ms | 3.42 ms | 16/16 → 0/16 |
| Large / expanded | 4.20 ms | 4.97 ms | 0/16 → 0/16 |
| Large / default | 6.80 ms | 3.99 ms | 0/16 → 0/16 |
| Large / compressed | 3.02 ms | 3.84 ms | 16/16 → 0/16 |

All 24 after-column holds reached the exact expected cursor and viewport; maximum
correlated held-header latency was 15.55 ms. One hold finished a column step
4.53 ms after release; the other 23 had no observed post-release cursor movement.
Baseline maximum release tail was 3.84 ms, also with no sustained backlog.
H/L verification on the large fixture at all three zooms: 48 exact-tick singles
and 12 holds passed, with no observed post-release cursor movement.

These are host input-to-painted-header upper bounds, not isolated render CPU
cost or physical-display frame measurements. Same-column movement is measured
separately from response latency. The automated release threshold is 50 ms,
with at least one second of observation after release and 500 ms cursor stability;
no drains were censored. Observed tails are below a 60 Hz frame interval, but
physical one-frame release and owner acceptance are not claimed.

Durable metrics and binary hashes:
[WB-068-repeat-before-after.json](evidence/WB-068-repeat-before-after.json).
Local raw ANSI, timestamped I/O, snapshots, fixtures and preserved binaries:

- `_build/wb068-evidence/wb068-evidence-2al8y3a0/` — before
- `_build/wb068-evidence/column-u6fuyy6z/` — after columns
- `_build/wb068-evidence/tick-a04ibski/` — after ticks

### Checks and reproduction

Passed:

```sh
scripts/with-switch.sh dune build -j5 terminal/main.exe terminal/waveform_probe.exe daemon/main.exe
scripts/with-switch.sh dune runtest -j5 terminal
scripts/with-switch.sh python3 scripts/probe-wb068-repeat.py --step-mode column --samples 8 --rates 30 120
scripts/with-switch.sh python3 scripts/probe-wb068-repeat.py --step-mode tick --sizes large --samples 8 --rates 30 120
git diff --check
```

Focused mapping/view tests cover unaligned compressed starts, repeated visible
steps, expanded ticks, resize/quick-view geometry, off-screen recovery, endpoint
saturation, help and cache retention. The summary script's `--check-record`
validation passed against all three raw runs. To rerun the baseline, pass
`--step-mode baseline` and the preserved baseline `bin/client` and `bin/daemon`
to the probe.

The existing `test-embedded-waveform.py` exact-tick checks were updated to H/L,
retaining expanded h/l coverage and adding compressed column checks. Its broader
regression run passed 64 semantic checks, then stopped because retained FIFO
VCD fixtures were unavailable under `/tmp/opencode`; its FIFO-specific PTY/view
checks therefore remain unverified in this session. Evidence:
`/tmp/opencode/wb028-accept-fuguu886/`. The dedicated WB-068 real-PTY matrix above
completed using its own bounded fixtures.

## References
- [Cursor handling](../../../terminal/waveform_view.ml)
- [Time mapping](../../../terminal/waveform_time.ml)
- [WB-028 embedded viewer](WB-028-waveform-viewer.md)
