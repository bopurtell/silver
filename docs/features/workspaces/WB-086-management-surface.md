---
id: WB-086
title: Project management window versus workspace prototype
category: workspaces
feature_sets: [FS3, FS5]
status: needs-design
kind: research
priority: P2
severity: n/a
requested_size: Unspecified
size: S
points: 5
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [prototype, management, layout]
depends_on: []
related: [WB-077, WB-085]
---

# WB-086 — Project management window versus workspace prototype

## Request
Try keeping the larger set of authoring controls outside Overview: compare a separate management window with a dedicated Project workspace.

## Current baseline
Workspace tabs organize views. The proposed compact Project menu gives discoverability without reserving a permanent row of actions, but it may not be the best place to browse and manage many objects.

## Scope
Build two bounded interactive demos around the same command IDs, contexts and authoring responses: (A) open a management window while keeping the current workspace, (B) switch to a dedicated Project workspace. Keep the Project menu as an entry point and reference for comparison. A fixture may stand in for the service; neither prototype writes source itself.

## Out of scope
Shipping both UIs, choosing a permanent layout before trying them, or duplicating provider or daemon work.

## Acceptance criteria
- [ ] Try the same tasks in both: from Testing find New IP Library by mouse; from a selected library create a module by keyboard; preview then cancel a chip creation and resume the original inspection.
- [ ] At 80 columns compare discoverability, visible destination, keyboard travel and focus restoration. Confirm neither requires a crowded Overview toolbar.
- [ ] Record owner feedback and recommend window, workspace, both or neither, with a reason. Keep the palette path available regardless of the outcome.

## Dependencies
No backend blocker for prototypes. Align with [WB-077](../presentation/WB-077-project-action-menu.md) for focus and [WB-085](../project/WB-085-authoring-service.md) for the eventual service interface.

## Estimate rationale
5 points for two small demos and a comparison, not a production window-management system.

## Assumptions and decisions needed
**Needs design through demos:** final management surface and which actions deserve persistent controls. The menu position is a usable default, not a requirement to place everything there.

## References
[Original menu design](../../project_authoring_and_command_design.md#menus-and-keyboard-interaction); owner follow-up, 2026-11-20.
