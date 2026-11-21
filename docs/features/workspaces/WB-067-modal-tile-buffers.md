---
id: WB-067
title: Vim-style tile buffers with counts, visual selection and repeat
category: workspaces
feature_sets: [FS3, FS5]
status: delivered
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

## Baseline before WB-067
Tiles have local j/k/h/l-style browsing, filters and Enter actions, each implemented
per view (`waveform_view.ml`, `timing_workspace.ml`, `testing_workspace.ml`, ...).
There is no shared count prefix, no visual selection and no repeat. Waveforms
Signals toggles one focused signal with Enter. Modal input already captures keys
before tile and global bindings, and Space c c is the palette leader.

## Design: who owns a digit?
In normal navigation, the **focused tile kind** declares whether bare digits belong
to the workspace switcher or to the tile. Count support is a separate decision:
a tile can own digits without implementing a count. In particular, an unhandled
tile-owned digit must not fall through to the switcher.

| Focus in normal navigation | What happens when I type `2`, then `0`? |
| --- | --- |
| An Overview tile that offers workspace shortcuts | `2` immediately selects its bound workspace. `0` is a new key in the resulting focus; there is no wait for a second digit. |
| Waveforms → Session | Same workspace shortcuts as Overview. Session is a metadata tile, not a motion target. |
| Waveforms → Waves | Stay in Waves. Show `2`, then `20` as the pending count. No motion until a motion key arrives. |
| Waveforms → Signals | Stay in Signals. Bare digits have no action unless Signals defines a local binding; they neither switch workspaces nor prime a Waves count. |

Text entry, an active modal, or a leader sequence gets first claim on the key.
For example, typing `20` into the Signals filter inserts `20` as text. Outside
those modes, route the key once using the focused tile's policy. The Waves and
Signals policies apply even before a trace loads or when the signal list is empty.

In Waves, `20h` / `20l` mean twenty ordinary column steps; `20H` / `20L` mean
twenty exact tick steps. `20j` / `20k` move by signal rows. Use the same bounds
and viewport-follow behavior as the corresponding single presses. The motion
consumes the count, so `20lh` moves right twenty columns, then left one. Esc
cancels without moving. Any other non-digit key clears the count before its
ordinary action; leaving Waves clears it rather than saving it for the next visit.
The indicator saturates at 9,999 so a pasted or mistyped number cannot request
unbounded work.

## Scope
- A shared, tile-local key-sequence layer: numeric count prefixes for motions and
  repeatable actions, with a visible pending-count indicator and Esc to cancel.
- Declare digit ownership per tile kind as above. Preserve existing workspace
  shortcuts on shortcut-owning tiles; do not infer ownership from count support.
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
- [x] With Waves focused, typing `2` then `0` shows a pending `20` without switching
  workspaces. At a compressed zoom, `20l` matches 20 single `l` column steps;
  `20L` moves exactly 20 ticks. Both clamp at trace bounds.
- [x] `20j` moves signal focus down as far as 20 single `j` presses would.
- [x] With `2` bound to another workspace, `2` switches on the first press in a
  shortcut-owning Overview tile. In Signals it stays put, and in the Signals
  filter it inserts `2`.
- [x] Type `20` in Waves, focus Signals, type `2`, then return to Waves: `l` moves
  one column. Neither tile's digits triggered a workspace switch.
- [x] A pending count is visible and cleared by Esc, by a non-count key, or by focus change.
- [x] In Signals, a visual range can be extended with j/k and bulk-toggled in one action.
- [x] Bulk toggles leave filtered-out signals untouched and persist like single toggles.
- [x] Palette leader, modal capture and existing single-key actions behave unchanged.
- [x] Count/selection state is tile-local and never changes run or context selection.

The waveform handoff PTY test drives the real client with a sparse trace where
twenty column steps differ from twenty ticks. It compares cursor and viewport,
checks the pending indicator with hints hidden, and exercises the same `2` in
Overview, Session, Waves, Signals, and a text filter. For Signals it covers a
mixed range, an all-enabled range, and cancellation. Run it with
`scripts/with-switch.sh dune build @terminal/test-native-smoke`.

## Dependencies
No required prerequisite. WB-068 defines the Waves step unit that counts multiply.
WB-014 can later make the bindings configurable. WB-053 tabs and WB-013 mouse
selection should reuse the same range model.

## Estimate rationale
21 points, low confidence: a shared input layer plus two real consumers and their
tests. Rolling it out to every tile is not included; each later tile adopts it incrementally.

## Assumptions and decisions needed
- VCD picker and Logs keep their existing behavior; neither the Waves count nor
  the Signals local-only policy is a workspace-wide default.
- Which tiles get counts/visual mode first beyond Waves and Signals?
- Is "Ches buffer" behavior meant to match a specific Ches keymap? If so, reference it.

## References
- [Focus and key routing](../../../terminal/waveform_routing.ml)
- [Filtered signal ranges](../../../terminal/signal_visual.ml)
- [Real-terminal count and selection regression](../../../terminal/test_waveform_handoff_pty.py)
- [Waveform view input](../../../terminal/waveform_view.ml)
- [Waveforms workspace controls](../../testing_workspace.md#dedicated-waveforms-workspace)
- [WB-018 Ches tiles](../integrations/WB-018-ches-tiles.md)
