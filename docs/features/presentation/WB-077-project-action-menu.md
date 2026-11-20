---
id: WB-077
title: Keyboard-first Project and contextual menus
category: presentation
feature_sets: [FS3, FS5]
status: proposed
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

## Request
Make commands discoverable by mouse without turning the workspace strip into a toolbar or adding a Tab stop per action.

## Current baseline
The terminal already has workspace navigation, tile focus and contextual palette commands.

## Scope
Add a visible `Project ▾` left of the workspace strip, visually separate from workspace names. Provide a reusable local `Actions ▾` on relevant objects. Invoke the same command IDs as the palette, with the invoking object's context. Expose commands as they become available.

## Out of scope
Implementing the authoring commands listed in the menus; a new workspace or configurable toolbar. Keep this menu compact: [WB-086](../workspaces/WB-086-management-surface.md) compares two places for the fuller management UI. Both should reuse these command bindings and WB-085's daemon calls rather than putting authoring logic in Overview.

## Acceptance criteria
- [ ] Click or use a documented key to open Project from a tile. The workspace stays selected; Tab/Shift-Tab between tiles works normally after dismissal.
- [ ] Arrows, `j`/`k`, counts such as `10j`, `/` filtering and Enter work. In filter mode `j` is text; Escape leaves filtering, then dismisses and restores the originating tile and row.
- [ ] Demo at 80 columns. A local action on an independently inspected object passes that object, not Main's selection, through both keyboard and mouse dispatch.

## Dependencies
None. Reuse [WB-054](WB-054-contextual-controls.md) contextual actions; menu-local movement need not wait for general tile-buffer navigation.

## Estimate rationale
8 points: one reusable focused list, hit testing, dispatch context and terminal interaction checks.

## Assumptions and decisions needed
Placement is agreed. **Needs design:** choose a non-conflicting direct-open key during the terminal demo.

## References
[Design: menus and keyboard](../../project_authoring_and_command_design.md#menus-and-keyboard-interaction).
