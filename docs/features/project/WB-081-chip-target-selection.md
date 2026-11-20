---
id: WB-081
title: Chip-target selection in Silver
category: project
feature_sets: [FS0, FS3]
status: partial
design_status: designed
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

**Designed — ready for remaining implementation and automated acceptance.**

## Request
Open one Dune project and choose which chip to inspect, plan or run.

## Current baseline
The [launch-target picker](../../launch-target.md) already selects an exact chip/variant pair, loads its flows and guards against launching a stale plan after switching targets. Selecting a run to inspect does not select its chip for launch. Remaining work is to apply that distinction consistently across workspace contexts and session restore.

## Scope
Consume the provider catalog on the service host. Add **Select chip target…** and distinguish Project, Chip target and Workspace in the UI. Carry target identity through flow discovery, preview, launch and result association.

## Out of scope
Multiple project roots, editing catalog entries, or creating a new chip on selection.

## Acceptance criteria
- [ ] In one example project select A and B and see their respective flows. With an independently inspected B and Main on A, launching in B targets B.
- [ ] Changing selection cannot launch A's staged plan against B or relabel an existing result. Selecting a target never edits source or the catalog default.
- [ ] A legacy single-executable integration works without migration; a generic Dune project still opens without ASIC support.
- [ ] Linked contexts follow Main. Detaching copies the effective launch target; later changes in either context leave the other untouched.
- [ ] Reopen with the saved chip/variant present, then repeat with that pair removed. Restore the exact pair in the first case; identify the missing pair and require explicit selection in the second. No silent fallback launch.

### Automated closeout (no manual walkthrough required)

Drive the real terminal with a controlled provider recording submissions. Main targets FIFO; an independent workspace targets program memory. Both inspect the same historical FIFO run. In each workspace open the palette, assert the **selected row before Enter** names the effective chip/variant and profile, press Enter, and assert exactly one fresh synthesis submission for that pair. Do not infer dispatch from the rendered label. Use the existing named synthesis action until [WB-076](../presentation/WB-076-palette-intent-aliases.md) lands, then exercise literal `synth` + Enter.

Cover linked/independent propagation, explicit retargeting from a run, and restore/missing-target cases with focused state/service tests. Stage a plan for A, switch to B and attempt the staged launch: assert an explanation and **zero** provider launches (use `a launch` once available). [Existing chip-example coverage](../../../scripts/test-chip-example.py) is a starting point; real EDA is not a gate for dispatch correctness.

## Dependencies
[WB-080](WB-080-chip-catalog.md) supplies authoritative listing and invocation. Picker dispatch can land before the [Project menu](../presentation/WB-077-project-action-menu.md).

## Estimate rationale
13 points for provider consumption, context propagation and backwards-compatible run handling.

## Agreed design
- **Launch target is intent; inspected run is evidence.** Browsing or pinning a run never retargets launch. Offer an explicit **Use this run's chip/variant as launch target** action.
- `synth` uses the invoking workspace's effective target and profile. Staged launch uses the exact captured plan in that context; after a target change require a new plan, never rebind the old one.
- Use the catalog default on first open. Remember stable chip/variant IDs across sessions, respecting linked versus independent contexts. Restoring IDs does not restore authority to launch a previously staged plan.

## References
[Current ASIC config](../../../project_integration/asic_config.ml); [run contexts](../run_contexts.md); [design record](../../project_authoring_and_command_design.md).
