---
id: WB-013
title: Mouse focus, scrolling and actions
category: workspaces
feature_sets: [FS3, FS5]
status: partial
kind: enhancement
priority: P2
severity: n/a
requested_size: Ticket
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [mouse, focus, scrolling, selection]
depends_on: []
related: [WB-014, WB-046, WB-053, WB-056]
---

# WB-013 — Mouse focus, scrolling and actions

## Request
Support mouse interaction, first for focus, scrolling and selection/actions with
keyboard parity. Requested size: **Ticket**. Drag layout editing comes later.

## Current baseline
The native terminal enables button and wheel reporting without hover. Use
`--no-mouse` for terminal-native selection. Keyboard focus, navigation and
the effective rendered layout are shared with the pointer path.

## Scope
- Enable supported native mouse events and map cell coordinates to visible targets.
- Add click-to-focus/select, wheel scrolling and bounded existing action activation.
- Route overlay/modal input before underlying tiles, with full keyboard equivalents.

## Out of scope
Drag move/resize, desktop window management, or mandatory mouse-only controls.
Interactive layout editing is separately scoped in WB-046.

## Acceptance criteria
- [x] Clicking visible tiles and supported selection rows focuses/selects the target at current geometry.
- [x] Wheel input browses the focused tile; Ctrl+wheel uses keyboard tile order.
- [x] Palette/modal capture prevents click-through and preserves focus.
- [x] Geometry tests cover narrow layouts and resize; keyboard-only operation has a native PTY check.
- [ ] Explicit pointer activation of actions beyond browsing. Row clicks are deliberately selection-only.

## Dependencies
Required: none; action routing, geometry and keyboard behavior are delivered.
Related: [WB-014](WB-014-hotkey-configuration.md) configures keyboard equivalents;
[WB-046](WB-046-interactive-layout-editing.md) owns later drag editing;
[WB-053](../presentation/WB-053-tile-local-tabs.md) adds optional tab targets;
[WB-056](../presentation/WB-056-floating-panes.md) adds optional floating surfaces.

## Estimate rationale
Thirteen incremental points cover native event integration, hit testing and focus/
scroll/action parity checks. Drag editing and floating-window policy are excluded.

## Interaction decisions
A workspace tab is a navigation control: clicking its label switches immediately.
A left press on a data row focuses the tile and selects the indicated item
without activating it. Clicking tile chrome focuses
without changing the selection; hovering does not focus. Plain wheel browses
like `j`/`k` only over the focused tile. Ctrl+wheel moves focus in the same order
as Tab/Shift+Tab. Captured input and modal surfaces take precedence over tiles.
Terminal and tmux shortcuts may intercept wheel events before Silver sees them.

## Verification
Operator feedback: run selection without activation, wheel navigation and focus
behavior, compact layout, and modal capture felt right. Workspace tabs were the
exception: selection without switching did not match the expected interaction.

Run `./scripts/with-switch.sh dune build -j4 @runtest @terminal/test-mouse-pty`
from this worktree. The native test opens a real terminal client against a
private, synthetic two-run project. It checks SGR mouse negotiation, selection
without activation, focus order, wheel boundaries, palette capture, terminal
cleanup, and the keyboard-only option.

## References
- [Native event setup](../../../terminal/main.ml)
- [Workspace host](../../../terminal/workspace_host.ml)
- [Input ownership contract](../workspaces_and_layouts.md)
