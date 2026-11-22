---
id: WB-021
title: Evidence-backed RTL/OCaml source navigation
category: evidence
feature_sets: [FS1, FS4]
status: proposed
kind: feature
priority: P2
severity: n/a
requested_size: Large Feature
size: L
points: 34
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [source-mapping, rtl, ocaml, provenance]
depends_on: []
related: []
---

# WB-021 — Navigate real source mappings

**Interaction design agreed (2026-11-22); producer design follows WB-091.**
`gd` on a whole path offers launch or capture; on a selected endpoint it follows
that end directly. Open a unique verified span with endpoint/instance context,
or offer labeled candidates without preemptively opening one. For changed
source, offer retained bytes if available; otherwise report the mismatch. When
unmapped, stay on the path and offer the original report span if retained.

**Cobalt integration ownership:** If opening a retained artifact needs a new
read-only buffer or range-selection hook in Cobalt, track that change and its
verification here alongside Silver's navigation action.

**Cobalt delivery slice:** use the [retained-path trace](WB-091-timing-origin-trace.md)
to select one producer, the [module jump hook](../infrastructure/WB-092-module-jump-hook.md)
to offer and resolve Timing actions, and the [generic editor action](../workspaces/WB-087-cobalt-editor.md)
to open its result. For a whole path, offer launch/capture rather than silently
choosing an endpoint. Open retained RTL read-only when that is the last proven hop;
label ambiguous or stale origins explicitly. Back restores the exact Timing
selection. An RTL-only jump is useful incremental delivery, not closure of this ticket.

## Request
Original size: **Large Feature**. Navigate from hardware evidence into generated
RTL and original OCaml through actual mapping provenance.

## Current baseline
FS1 exposes report spans and design/constraint references with hashes.
The structural hierarchy carries instance/port metadata, not a source-location graph.
Existing documents explicitly reject guessing OCaml lines from synthesized names.
Editor-open requirements already call for file/range plus source/build identity.

## Scope
- Adopt one producer-emitted mapping format linking evidence objects, generated RTL
  ranges and original OCaml locations, including one-to-many/unmapped results.
- Retain mapping source/build/artifact identities and validate location freshness.
- Add explicit navigation from one supported evidence surface to mapped locations.
- Provide a bounded source peek or editor-open payload through an agreed action seam.

## Out of scope
Heuristic name matching, general decompilation, an embedded editor, and mapping every
optimized net in every backend. Ches hosting is not required for first navigation.

## Acceptance criteria
1. One real producer example demonstrates evidence → RTL → OCaml with retained mapping.
2. Navigation exposes the mapping producer/version and source/build identity.
3. Missing, ambiguous or optimized-away mappings are explicit choices/states.
4. Changed source bytes do not open a stale range as if it were current.
5. Editor actions carry exact file/range and identity without shell interpolation.

## Dependencies
Required: delivered evidence/artifact identity and a mapping producer adopted in this scope.
No additional ticket blocker; related: none required for the first navigation seam.

## Estimate rationale
34 points cover one mapping contract/producer adoption and one navigation integration.
Exclude editor embedding, graphical physical inspection and general compiler debug metadata.

## Assumptions and decisions needed
After WB-091, choose the first producer, mapping format and source-root resolution.
The existing jump location carries a project-relative point and opaque identity;
use the trace to scope read-only artifact opening and verified range support.
Default: exact provenance or explicit unmapped; no jump inferred from similar names.
If no producer mapping exists, include its bounded generation in the chosen first slice.

## References
- [Source mapping limits](../../asic_evidence_inspection.md)
- [External navigation contract](../external_clients.md)
- [Structural hierarchy](../../../protocol/hierarchy.ml)
