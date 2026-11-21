---
id: WB-077
title: Keyboard-first Project and contextual menus
category: presentation
feature_sets: [FS3, FS5]
status: closed
design_status: designed
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 8
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [menu, keyboard, focus]
depends_on: []
related: [WB-013, WB-054, WB-067]
---

# WB-077 — Keyboard-first Project and contextual menus

The first click opens actions, not a project tree. WB-086 is not a prerequisite.

## Request
Make commands discoverable by mouse without turning the workspace strip into a toolbar or adding a Tab stop per action.

## Current baseline
The terminal already has workspace navigation, tile focus and contextual palette commands.

## Scope
Add a visible `Project ▾` left of the workspace strip, visually separate from workspace names. Provide a local actions menu on relevant objects, without a button on every run row. Invoke the same command IDs as the palette, with the invoking object's context. Expose commands as they become available.

### First screen: flat action menu

| Group, in display order | Entries, in display order |
| --- | --- |
| Open or create | New Project…, Open Project… |
| Author in this project | New IP Library…, New Module…, New Chip Target…, New Flow… |
| Select or browse | Select Launch Target…, Manage This Project… |

Use separators, not nested submenus. Keep synthesis and staged launch in the run context and palette. **Manage This Project…** is the handoff to the WB-086 object browser; opening `Project ▾` itself neither opens that browser nor switches workspaces. Until a destination or underlying action exists, do not present it as executable. Do not build a substitute wizard, registry or browser to fill an empty slot.

Project-wide actions prompt for a destination when needed; local actions supply the selected object. For example, New Module from Project asks which library, while New Module on `controlled_fifo` starts there. Tab/Shift-Tab navigate regions, not every action row; list keys move the highlight. Pick and document a free direct-open binding after checking the existing keymap.

## Out of scope
Implementing the authoring commands listed in the menus; a new workspace or configurable toolbar. Keep this menu compact: [WB-086](../workspaces/WB-086-management-surface.md) compares two places for the fuller management UI. Both should reuse these command bindings and WB-085's daemon calls rather than putting authoring logic in Overview.

## Acceptance criteria
- [x] Click or use a documented key to open Project from a tile. The workspace stays selected; Tab/Shift-Tab between tiles works normally after dismissal.
- [x] Arrows, `j`/`k`, counts such as `10j`, `/` filtering and Enter work. In filter mode `j` is text; Escape leaves filtering, then dismisses and restores the originating tile and row.
- [x] Demo at 80 columns. A local action on an independently inspected object passes that object, not Main's selection, through both keyboard and mouse dispatch.
- [x] Automate the 80-column terminal path from Testing: open by click and by key, verify a flat action list and unchanged workspace, filter to New IP Library, invoke its existing wizard and cancel back to the prior inspection. Check the invoked command/context, not just its label. Exercise filtering/dismissal focus restoration separately.

## Dependencies
None. Reuse [WB-054](WB-054-contextual-controls.md) contextual actions; menu-local movement need not wait for general tile-buffer navigation.

## Estimate rationale
8 points: one reusable focused list, hit testing, dispatch context and terminal interaction checks.

## Delivery and verification
**F2** opens Project from a tile. In local Silver the first group is **New Project…** and **Open Project…**. These operate on a Dune root, while **New IP Library…**, **New Module…** and **New Chip Target…** add to the open project. **Select Launch Target…** is offered when available.

**F3** opens Actions for the highlighted run; right-clicking anywhere on a run row opens its actions regardless of the previous highlight. Left-click still browses, and opening the menu does not select the run for inspection.

`terminal/test_project_menus_pty.py` passed against the installed client and daemon at 80 columns, including the Testing wizard round trip and detached-workspace dispatch. `terminal/test_mouse_pty.py` also passed against the installed binaries, covering tab switching, tile focus, overlay hit testing and `--no-mouse`.

## References
[Design: menus and keyboard](../../project_authoring_and_command_design.md#menus-and-keyboard-interaction).
