---
id: WB-081
title: Chip-target selection in Silver
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
tags: [selection, context, targets]
depends_on: [WB-080]
related: [WB-024, WB-077]
---

# WB-081 — Chip-target selection in Silver

## Request
Open one Dune project and choose which chip to inspect, plan or run.

## Current baseline
The single `project_executable` in the example points at FIFO; opening the root does not expose every chip. Workspaces already support linked and independent inspection.

## Scope
Consume the provider catalog on the service host. Add **Select chip target…** and distinguish Project, Chip target and Workspace in the UI. Carry target identity through flow discovery, preview, launch and result association.

## Out of scope
Multiple project roots, editing catalog entries, or creating a new chip on selection.

## Acceptance criteria
- [ ] In one example project select A and B and see their respective flows. With an independently inspected B and Main on A, launching in B targets B.
- [ ] Changing selection cannot launch A's staged plan against B or relabel an existing result. Selecting a target never edits source or the catalog default.
- [ ] A legacy single-executable integration works without migration; a generic Dune project still opens without ASIC support.

## Dependencies
[WB-080](WB-080-chip-catalog.md) supplies authoritative listing and invocation. Picker dispatch can land before the [Project menu](../presentation/WB-077-project-action-menu.md).

## Estimate rationale
13 points for provider consumption, context propagation and backwards-compatible run handling.

## Assumptions and decisions needed
**Needs design:** persistence of selection across sessions and handling a previously selected target removed from the catalog. Never silently redirect a launch.

## References
[Current ASIC config](../../../project_integration/asic_config.ml); [run contexts](../run_contexts.md); [design record](../../project_authoring_and_command_design.md).
