---
id: WB-086
title: Project management window versus workspace prototype
category: workspaces
feature_sets: [FS3, FS5]
status: closed
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

**Owner decision:** use one large centered floating window. Project management
is a task entered from an inspection, not a permanent workspace tab. The
narrow trial window left too little room for paths; the accepted layout uses
most of an 80-column terminal and puts Objects and Actions side by side when
space allows. See [controls and comparison findings](WB-086-owner-trial.md).

## Request
Try keeping the larger set of authoring controls outside Overview: compare a separate management window with a dedicated Project workspace.

## Current baseline
Workspace tabs organize views. The proposed compact Project menu gives discoverability without reserving a permanent row of actions, but it may not be the best place to browse and manage many objects.

## Scope
Enter via **Project ▾ → Manage This Project…**. First prototype a dedicated Project workspace; then host the same browser in a separate management window while keeping the current inspection visible. Compare the hosts, not two different command implementations. A fixture may stand in for the service; neither prototype writes source itself.

| Browser selection | Local commands (same bindings as the palette, with object context) |
| --- | --- |
| IP libraries → `controlled_fifo` | New Module…, New Chip Target from This IP… |
| Chip targets → `fifo_demo` | New Flow… with FIFO preselected |
| `fifo_demo` → `standard` → `balanced` | Duplicate Profile… for `standard/balanced` |

The hierarchy belongs in the browser, not a cascading Project menu. Highlighting an object is inspection only: selecting SRAM to browse its flows does not change the launch target or staged plan. Retargeting requires an explicit action. Reuse WB-077's navigation model: Tab between regions, arrows or counted `j`/`k` within lists, `/` to filter, Enter to choose, Esc to return.

## Out of scope
Shipping both UIs, choosing a permanent layout before trying them, or duplicating provider or daemon work.

## Acceptance criteria
- [x] Try the same tasks in both: from Testing find New IP Library by mouse; from a selected library create a module by keyboard; preview then cancel a chip creation and resume the original inspection.
- [x] At 80 columns compare discoverability, visible destination, keyboard travel and focus restoration. Confirm neither requires a crowded Overview toolbar.
- [x] In both hosts, with FIFO the launch target, browse a different chip and invoke New Flow. Assert the wizard receives that chip while FIFO and its staged plan remain unchanged. Compare whether an ongoing run stays visible during management and what it takes to resume inspection.
- [x] Record owner feedback and recommend window, workspace, both or neither, with a reason. Keep the palette path available regardless of the outcome.

## Dependencies
No backend blocker for prototypes. Align with [WB-077](../presentation/WB-077-project-action-menu.md) for focus and [WB-085](../project/WB-085-authoring-service.md) for the eventual service interface.

## Estimate rationale
5 points for two small demos and a comparison, not a production window-management system.

## Navigation decision
An authoring wizard launched from the browser returns to the object it was
opened on. Dismissing the browser returns to the originating workspace, tile
and row. Wizards opened directly from the palette keep their normal return path.

## References
[Original menu design](../../project_authoring_and_command_design.md#menus-and-keyboard-interaction); owner follow-up, 2026-11-20.
