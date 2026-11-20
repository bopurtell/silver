---
id: WB-083
title: Flow-owned profiles and explicit authoring commands
category: project
feature_sets: [FS0, FS3]
status: needs-design
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [flow, methodology, profiles]
depends_on: [WB-085]
related: [WB-077, WB-082]
---

# WB-083 — Flow-owned profiles and explicit authoring commands

## Request
Give each named flow an obvious source home, and distinguish creating a methodology, duplicating a settings variant and running an existing selection.

## Current baseline
FIFO's project declares a base flow; its catalog constructs `standard`, registers profiles from `flow_profiles.ml` and is exposed by the chip CLI. A new file alone registers nothing.

## Scope
Adopt a provider-owned starter convention: one methodology module supplies a complete entry with profiles, endpoints and default. The chip flow catalog collects entries. Add **Add methodology…** and **Duplicate profile…** in Silver over headless authoring operations. **Run flow…** uses the existing execution path.

## Out of scope
Forcing one library or file per profile, migrating every custom catalog, or changing declared defaults when selecting a flow.

## Acceptance criteria
- [ ] Create a second methodology with an initial profile; register explicitly and discover it from CLI and Silver. Declining registration or encountering custom OCaml never triggers wholesale rewriting.
- [ ] Duplicate `standard/balanced` under a new ID; both profiles belong to the same methodology and the existing default remains intact. Reject collisions.
- [ ] Running the new selection creates an attempt without editing source; the prior profile remains runnable.

## Dependencies
[WB-085](WB-085-authoring-service.md) supplies preview/apply for the UI. A single existing chip is sufficient. Share the explicit registration-edit convention with [WB-082](WB-082-chip-target-starter.md), not its project-level target catalog.

## Estimate rationale
13 points for the example convention, two provider-backed operations and CLI/UI verification.

## Assumptions and decisions needed
**Needs design:** editable starter structure and snippet fallback for adding profiles to hand-written modules. A module can become a library if sharing warrants it.

## References
[Design: where to find a flow](../../project_authoring_and_command_design.md#where-to-find-a-flow).
