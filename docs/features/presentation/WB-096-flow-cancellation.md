---
id: WB-096
title: Cancel active ASIC flows from the palette
category: presentation
feature_sets: [FS0, FS1]
status: delivered
kind: enhancement
priority: P2
severity: n/a
requested_size: Small
size: S
points: 3
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [palette, cancellation, stage-checklist]
depends_on: []
related: [WB-065, WB-069, WB-076]
---

# WB-096 — Cancel active ASIC flows from the palette

During a full Electrum run, the owner cancelled while Routing was running.
Routing showed **Cancelled**, but Timing still showed **Pending**, suggesting
it might start later. Make it predictable which flow Enter will stop, and
make it clear which requested stages never ran.

## Acceptance criteria

- [x] For exact `cancel` or `stop`, pin **Cancel — \<flow in view\>** first and
  **Cancel All — \<selected chip\> (\<active flow count\> flows)** second, ahead of
  competing fuzzy matches. Exact `cancel all` or `stop all` selects the bulk
  action first.
- [x] Enter on **Cancel** dispatches the existing cancellation action for the
  active run or workflow in view. If there is no unambiguous cancellable flow
  in view, keep that row first with a reason; Enter dispatches nothing.
- [x] **Cancel All** stops only active flows for the selected chip in the
  current project. Count and cancel each flow once even when both its
  workflow and its active operation are visible.
- [x] Show **Cancelling…** while cleanup is underway. Once cancellation is
  confirmed, show the interrupted stage as **Cancelled** and later requested,
  unreached stages as **Skipped** with the reason (e.g. **Timing: Skipped —
  flow cancelled during routing**). Preserve completed results and **Not
  requested** stages. An interruption alone is not proof of user cancellation.

## Verification

The Runs pane lists a pending workflow by workflow ID and phase before a
physical run is allocated. A new launch does not replace an older watched run.
The private cancellation PTY verifies that Enter on **Stop current** dispatches
the exact pending workflow ID, preserves the watched selection, and that a
workflow reaching physical execution yields one run row rather than two.

Delivered against an updated daemon. The [palette PTY regression](../../../terminal/test_palette_cancellation_pty.py)
verifies Enter dispatch for both spellings, including `stop` from Timing after
launching a controlled FIFO fixture, and the rendered skip reason after
refresh. The private Routing cancellation fixture passed 42 lifecycle
assertions, including child cleanup, no Timing start, cold refresh after
restart, and a provider-only interruption not being reported as user
cancellation.

Use short fixtures. Exercise **Enter dispatch**, not just row order: include
a competing fuzzy match, two active Electrum flows, and an out-of-scope flow.
Check the exact identities and count for single and bulk cancellation. On a
fixture with Timing requested, cancel during Routing, wait for cleanup, then
refresh the run. Verify that Timing never started and still reads **Skipped**
with the reason after refresh.

## Starting points

- [Exact palette ordering](../../../terminal/workspace_host.ml) (`ranked_command_matches`)
  pins the single and bulk actions in that order for `cancel` and `stop`;
  [WB-076](WB-076-palette-intent-aliases.md) sets the precedent.
- [Fresh workflow commands](../../../terminal/stage_launch_commands.ml) already
  dispatch cancellation by workflow ID.
- [Stage normalization](../../../backend/asic_public.ml) maps `unreached` to
  `Pending`. The [existing cancellation check](../../../scripts/test-asic-signoff-cancellation.py)
  covers cleanup and verifies that no later stage starts.
