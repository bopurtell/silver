---
id: WB-067
title: Vim-style tile buffers with counts, visual selection and repeat
category: workspaces
feature_sets: [FS3, FS5]
status: needs-design
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: L
points: 21
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [modal, vim, counts, visual-selection, keyboard]
depends_on: []
related: [WB-013, WB-014, WB-018, WB-028, WB-053, WB-068]
---

# WB-067 — Vim-style tile buffers with counts, visual selection and repeat

## Request
Owner note, 2026-10-20: each buffer inside a tile should be usable like a Ches
buffer — visually select over content, and make certain commands repeatable with a
count. Example: with the cursor in Waves, `20 l` moves the cursor 20 steps. In the
Signals tile, enter a visual (line/block) mode, select down a list of signals and
enable/disable them all at once, Vim-binding style. Requested size: **Unspecified**.

## Current baseline
Tiles have local j/k/h/l-style browsing, filters and Enter actions, each implemented
per view (`waveform_view.ml`, `timing_workspace.ml`, `testing_workspace.ml`, ...).
There is no shared count prefix, no visual selection and no repeat. Waveforms
Signals toggles one focused signal with Enter. Modal input already captures keys
before tile and global bindings, and Space c c is the palette leader.

## Scope
- A shared, tile-local key-sequence layer: numeric count prefixes for motions and
  repeatable actions, with a visible pending-count indicator and Esc to cancel.
- Route digits by keyboard focus. In normal navigation, a tile that supports counts
  (initially Waves) consumes digits before workspace shortcuts. Tiles without counts
  keep their numeric workspace shortcuts, even in the same workspace. Text inputs
  and modals retain priority; no workspace-wide setting is required.
- Visual line selection (and block selection where a tile has columns) over a
  tile's rows, with a visible selection range and actions applied to the range.
- First consumers, so the mechanism is proven on real views:
   1. Waves: count `h`/`l` column steps, `H`/`L` exact ticks, or `j`/`k` signal rows.
  2. Signals: `V`, then j/k to extend, then a bulk enable/disable/toggle action.
- Views declare which actions accept counts or ranges; others ignore the prefix.

## Out of scope
Text editing, registers/macros, a full Vim emulation, configurable bindings (WB-014)
and mouse selection (WB-013). Ches embedding itself is WB-018.

## Acceptance criteria
- [ ] With Waves focused, typing `2` then `0` shows a pending `20` without switching
  workspaces. At a compressed zoom, `20l` matches 20 single `l` column steps;
  `20L` moves exactly 20 ticks. Both clamp at trace bounds.
- [ ] `20j` moves signal focus down as far as 20 single `j` presses would.
- [ ] After moving focus to a tile without counts in the same workspace, a bound
  digit switches workspaces on the first press. In a text filter it enters text.
- [ ] A pending count is visible and cleared by Esc, by a non-count key, or by focus change.
- [ ] In Signals, a visual range can be extended with j/k and bulk-toggled in one action.
- [ ] Bulk toggles leave filtered-out signals untouched and persist like single toggles.
- [ ] Palette leader, modal capture and existing single-key actions behave unchanged.
- [ ] Count/selection state is tile-local and never changes run or context selection.

## Dependencies
No required prerequisite. WB-068 defines the Waves step unit that counts multiply.
WB-014 can later make the bindings configurable. WB-053 tabs and WB-013 mouse
selection should reuse the same range model.

## Estimate rationale
21 points, low confidence: a shared input layer plus two real consumers and their
tests. Rolling it out to every tile is not included; each later tile adopts it incrementally.

## Assumptions and decisions needed
- Which tiles get counts/visual mode first beyond Waves and Signals?
- Is "Ches buffer" behavior meant to match a specific Ches keymap? If so, reference it.

## References
- [Waveform view input](../../../terminal/waveform_view.ml)
- [Waveforms workspace controls](../../testing_workspace.md#dedicated-waveforms-workspace)
- [WB-018 Ches tiles](../integrations/WB-018-ches-tiles.md)
