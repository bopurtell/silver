---
id: WB-091
title: Trace a retained timing path to its provable origins
category: evidence
feature_sets: [FS1, FS4]
status: needs-design
kind: research
priority: P2
severity: n/a
requested_size: Unspecified
size: S
points: 5
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [timing, provenance, cobalt]
depends_on: []
related: [WB-021, WB-022]
---

# WB-091 — Trace before designing the source map

Choose one real retained path. Start with `Timing_workspace.selection` (run,
domain, stage, source digest, row ID), not the rendered label. Follow launch
and capture separately through the report, netlist, emitted RTL and generator
using the artifacts available for that build.

## Acceptance
- Record artifact identities and the evidence for each hop, including exactly
  where identity is lost. Distinguish a missing artifact from an optimized or
  ambiguous object. A documented dead end is a valid result.
- Recommend the first producer change for WB-021, if needed: e.g. capture a
  register's instance path and OCaml call site at elaboration. State how to
  check whether synthesis preserves the link; spelling alone is not proof.
- Specify the UI result for exact, multiple, RTL-only, stale and unmapped
  origins. A mapped source is not a diagnosis of the timing violation.
