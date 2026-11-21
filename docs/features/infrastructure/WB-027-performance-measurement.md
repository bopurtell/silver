---
id: WB-027
title: Workbench latency/resource/evidence-loading measurements
category: infrastructure
feature_sets: [FS0, FS3]
status: delivered
kind: validation
priority: P1
severity: n/a
requested_size: Feature
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [latency, memory, loading, measurements]
depends_on: []
related: [WB-043, WB-044, WB-005]
---

# WB-027 — Workbench latency/resource/evidence-loading measurements

## Request
Measure Workbench interaction latency, memory use and evidence-loading behavior
so optimization decisions rest on tool measurements rather than impressions.

## Current baseline
Construction records retain scoped responsiveness/cache evidence and defer broader
high-tile-count, latency and memory/disk measurements. These are not a complete baseline.

## Scope
- Define reproducible cold, warm and restart evidence-loading workloads.
- Measure input-to-visible-response, query/cancel latency and loading duration.
- Record daemon/client memory, allocation where practical and retained disk use.
- Include realistic tile counts, evidence sizes and local versus slow-storage conditions.
- Publish workload, environment, measurement method and uncertainty with results.

## Out of scope
- Measuring DUT timing, area or power as though they were Workbench performance.
- Broad optimization rewrites or fresh physical flows solely to collect sample data.

## Acceptance criteria
- A repeatable harness produces attributable latency/memory/loading measurements.
- Cold/warm/restart paths and cache-hit behavior are separately reported.
- Input responsiveness is measured through the actual host/transport where relevant.
- Results state sample counts, distributions and environment rather than one magic number.
- Instrumentation overhead and unsupported measurements are explicit.
- Proposed acceptance thresholds are documented for owner review, not invented delivery claims.

## Dependencies
No additional prerequisite tickets; use current fixtures and retained evidence.
[WB-043](WB-043-slow-storage.md) targets measured I/O bottlenecks and
[WB-044](WB-044-load-acceptance.md) consumes this measurement method.
[WB-005](WB-005-process-monitor.md) provides related live visibility, not DUT metrics.

## Estimate rationale
13 points, M, medium confidence: bounded instrumentation and workload design span
frontend/backend seams. Incremental estimate includes the measurement baseline,
excluding subsequent optimizations and separately ticketed load acceptance.

## Assumptions and decisions needed
Agree representative environments and responsiveness budgets. Reuse retained large
evidence where possible and distinguish synthetic workloads from actual user sessions.

## References
- [Construction coverage/scaling followups](../../construction_phase_plan.md).
- [FS1 measured interaction followup](../../asic_evidence_inspection.md).
- [Cache architecture](../run_summary_cache.md).

## Delivery evidence

Implemented on `bpurtell/performance-baseline` in the isolated
`../performance-baseline` worktree from committed `oxcaml` `2b42815`.
Changes remain uncommitted for review. Thresholds remain proposed, not
owner-approved; implementation status does not imply load-acceptance approval.

- Harness: `scripts/measure-workbench-performance.py`.
- [Reproducible commands, method, bounds, limitations and proposed thresholds](WB-027-measurement-guide.md).
- [Recorded baseline distributions, resources, environment and identities](WB-027-baseline-results.md).
- Accepted full matrix: `/tmp/opencode/workbench-performance-p8o3ek31/result.json`:
  256/1024 synthetic rows × 1/24 tiles × local/1-second injected read stall ×
  three independent samples = 24 trials and 384 successful timing observations,
  zero failures/timeouts. L1/L2 provider avoidance, payload/digest/freshness,
  real PTY workspace selection, cancellation and process cleanup assertions passed.

Verification commands (run serially in the assigned worktree):

```sh
scripts/with-switch.sh dune build -j 3 daemon/main.exe terminal/main.exe
python3 -B scripts/measure-workbench-performance.py --self-test
python3 -B scripts/measure-workbench-performance.py --daemon _build/default/daemon/main.exe --client _build/default/terminal/main.exe --rows 256 --tiles 1 --samples 1 --storage local --budget 120
python3 -B scripts/measure-workbench-performance.py --daemon _build/default/daemon/main.exe --client _build/default/terminal/main.exe --rows 256,1024 --tiles 1,24 --samples 3 --slow-delay 1 --budget 600
git diff --check
```

Build, pure self-tests (including fragmented ANSI, timeout retention, active
workspace discrimination and provider allowlist), smoke and full matrix passed.
Smoke evidence: `/tmp/opencode/workbench-performance-by0h06wi/result.json`.
An intentional overall-budget exhaustion check also ran:

```sh
python3 -B scripts/measure-workbench-performance.py --daemon _build/default/daemon/main.exe --client _build/default/terminal/main.exe --rows 256 --tiles 1 --samples 20 --storage local --budget 30
```

It exited nonzero at the overall deadline during trial 08 startup, preserved
partial results and the timeout screen, and reported all owned processes stopped
with no cleanup errors in
`/tmp/opencode/workbench-performance-zz12mz0b/rows-256-tiles-1-local-08/result.json`.
This expected negative check is excluded from baseline statistics. Earlier smoke
attempts exposed stale Dune metadata/palette assumptions in reused test helpers;
the harness-local adapters were corrected before the accepted runs.

No fresh physical flows or owner-example writes were used. No external repository,
provider installation, shared dependency, production instrumentation or shared
catalog/construction-plan changes were made. The baseline is explicitly synthetic;
real-storage/remote/display measurements and OCaml allocation counts remain
unsupported as detailed in the guide.
