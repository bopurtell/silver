---
id: WB-040
title: Bounded-memory large-trace streaming
category: infrastructure
feature_sets: [FS2, FS1]
status: partial
kind: enhancement
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [traces, streaming, artifacts]
depends_on: []
related: [WB-028, WB-042]
---

# WB-040 — Bounded-memory large-trace streaming

## Request
Stream large trace artifacts to verified private files with bounded memory,
instead of retaining whole traces in memory or silently lifting existing caps.

## Current baseline
FS2 exports byte-exact traces under declared paging/artifact limits, including a
64 MiB artifact cap. FS2-F02 preserves larger-trace streaming as additional scope.

## Scope
- Write pages incrementally to a private temporary file while hashing bytes.
- Define transport, total-size and storage limits explicitly.
- Publish only after complete byte-count/digest verification and atomic finalization.
- Preserve shared ASIC external handoff behavior where the path is reused.

## Out of scope
- Embedded waveform rendering or unlimited artifact size/retention.
- Launching a viewer against incomplete or unverified output.

## Acceptance criteria
- A declared large trace exports with measured bounded peak memory.
- Final bytes/digest match the registered artifact exactly.
- Missing/changed pages, oversize output and digest mismatch reject publication.
- Cancellation and timeout clean up private partial output.
- Viewer launch occurs only after complete verified publication.
- Existing bounded simulation and ASIC handoff paths retain their identity guarantees.

## Dependencies
No additional prerequisite tickets; a bounded streaming slice can declare its own limits.
[WB-042](WB-042-resource-budgets.md) can unify reservations and retention later.
[WB-028](../verification/WB-028-waveform-viewer.md) is a separate consumer-facing viewer,
not required to demonstrate verified export.

## Estimate rationale
13 points, M, medium confidence: existing paging/provenance seams are known, while
incremental hashing, cleanup and publication cross storage/transport boundaries.
Estimate is incremental and excludes embedded rendering and broader budget policy.

## Assumptions and decisions needed
The bounded slice below selects explicit limits without increasing provider storage
budgets. Streaming reduces memory pressure but does not remove disk or transport limits.

## Delivery — 2026-11-05

**Implementation complete for the declared bounded slice; owner acceptance pending.**
`partial` records that distinction, rather than treating automated evidence as owner
sign-off. Worktree: `../bpurtell-feature4`, branch `bpurtell/streaming-trace-export`,
based on `oxcaml`. No embedded waveform loading change is included.

### Selected limits and storage policy

| Resource | Explicit limit/policy |
| --- | --- |
| Simulation artifact | 64 MiB, retaining the existing protocol cap |
| Shared ASIC external binary | 16 MiB, retaining existing eligibility/extensions |
| Transport page | 64 KiB raw / 128 KiB hexadecimal characters |
| Fetch budget | 4,096 pages, including the last page; tiny pages can exhaust it |
| Metadata | 64 KiB per export |
| Deadline | 120 seconds for transfer, verification, publication and launcher completion |
| Active private exports | One process-wide across simulation and ASIC |
| Partial output storage | At most 64 MiB payload + 64 KiB metadata per terminal process, excluding filesystem overhead |
| Private permissions | Directory `0700`, files `0600` (or more restrictive umask) |
| Publication | Verified staging directory atomically renamed to a `-verified` sibling |
| Published retention | Explicit user-owned files, retained even on viewer failure; remove the returned directory when finished |

There is no cross-process disk reservation, automatic published-file pruning or
unlimited-artifact promise. A cleanup failure is surfaced and keeps the process's
reservation locked to prevent repeated partial-file accumulation. Process crash or
SIGKILL cleanup is not guaranteed; abandoned `hardcaml-export-partial-*` directories
may require manual removal. Existing provider attempt/history storage budgets remain
256/512 MiB. The 64 MiB fixture is the declared large trace for this slice; raising
the artifact cap requires a separately justified provider/storage policy.

### Implementation and identity

- `terminal/streaming_export.ml` writes one validated page at a time while hashing,
  checks total count/SHA256, then independently re-reads the private file with a
  64 KiB buffer and verifies count/SHA256 before atomic directory publication.
- Simulation retains attempt/artifact/hash/offset/total/EOF checks. ASIC retains
  run/terminal-attempt/artifact/hash/offset/page-limit checks and extension rules.
  Main's ASIC owner fence also checks the captured client connection.
- Cancellation/current-owner changes and timeout race pending reads. Cleanup does
  not wait for an unresolved fetch; a stopped guard prevents late reads from writing,
  publishing or launching. Polling is every 10 ms between scheduler operations.
  File operations are synchronous bounded operations with yields between pages;
  a stalled filesystem syscall can delay deadline/cancellation processing.
- Viewers receive only a verified local path after publication. Launcher failures
  retain verified output. Embedded loading keeps its existing bounded in-memory
  path, named `run_embedded` to distinguish it from external streaming.
- `backend/artifact_file.ml` hashes through a 64 KiB buffer and retains only the
  requested slice. Simulation capture incrementally copies/hashes to a private
  temporary file. Simulation and ASIC byte-page reads retain path/descriptor,
  regular-file, size, mutation and registered digest checks.
- Every backend page still rehashes the entire file; no weak stat-only cache was
  introduced. A 64 MiB/1,024-page export entails about 64 GiB logical read/hash work.
  ASIC catalog listing/text display remain bounded whole-file consumers outside
  byte streaming. This delivery establishes bounded export memory, not a new
  throughput guarantee or end-to-end HTTP performance acceptance.

### Verification and acceptance evidence

- Full `dune build -j 5 @all @lint` and `dune runtest -j 5`: passed.
- Terminal tests exercise corrupt/changed/missing/oversized pages, digest mismatch,
  disk readback corruption, write/rename failures, timeout and cancellation with
  unresolved reads, inert late completion, cleanup failure, concurrency reservation,
  empty artifacts, metadata bounds and verified-only viewer launch.
- Backend tests exercise maximum-size page/capture allocations below 2 MiB per
  measured operation, cross-buffer slices, mutation, rejected file types/paths,
  cleanup and tampering outside a requested page even with restored mtime.
- Fresh-process native exporter probe: 1 MiB peak RSS 52,716–52,972 KiB;
  64 MiB peak RSS 55,712–56,088 KiB. Conservative growth **3,372 KiB (3.29 MiB)**
  for 63 MiB additional trace bytes. All six runs independently verified every
  byte/count/digest and removed output. See
  [measurement method and reproduction](../../../terminal/streaming_memory_evidence.md).
- Repository-wide `@fmt` reports pre-existing formatting drift (including waveform,
  resource, and main modules). Changed export/backend additions were formatted and
  checked separately; this is not recorded as a clean global formatting pass.

Owner acceptance still requires review of the chosen 64/16 MiB slice and temporary/
retained-file policy, plus real terminal-host/provider/viewer exercise on the owner's
environment. Automated implementation checks do not substitute for that acceptance.

## References
- [FS2-F02 streaming](../../backlog/fs2_followups.md#fs2-f02--large-trace-streaming).
- [Current artifact limits](../../../protocol/simulation.ml).
- [Private/atomic file helpers](../../../backend/simulation_files.ml).
