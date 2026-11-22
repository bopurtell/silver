---
id: WB-093
title: Silver quick launch from standalone Cobalt
category: integrations
feature_sets: [FS2, FS4]
status: proposed
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: L
points: 21
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [cobalt, quick-launch, testing, stages]
depends_on: []
related: [WB-032, WB-063]
---

# WB-093 — Silver quick launch from standalone Cobalt

**Slice 1 implemented and live-tested; slice 2 pending.** This ticket owns cross-repo acceptance
for Cobalt C6 (`docs/backlog/silver_integration.md` in Cobalt). Silver owns
execution and launch semantics; Cobalt's optional Silver module owns client state.
The separate Silver window need not have the target selected or even have focus.

## Slice 1: test tile and `test` alias

Capture a real discovery/launch/result exchange for a parameterized test. Use
Silver's submission key, discovery digest and typed selection; identify the
acknowledged attempt from its reply. Check the Cobalt tile and palette against
this same contract. Neither requires a prior attempt or a visible overview.

**Live acceptance:** bind the two windows to one project. In Cobalt, select a
variant and use Enter to change `n=10` to `50`; applying must create no attempt.
Launch with `R`. Hide the tile and launch the same target with exact `test` from
code. Verify both distinct attempts in Silver have the intended selection and
value. Check configured-default precedence over last launch and first-use picker
behavior when neither exists. Confirm reconnect after a lost acknowledgement
does not submit again, and closing Cobalt does not cancel execution.

**Evidence:** Cobalt's `examples/silver_overview/check_quick_launch.py`, run
with `--cobalt` and `--silver-client` against a private daemon, passed the
two-window check. Apply created no attempt; tile `R` and the hidden-tile
palette invocation produced two distinct passing `FIFO / seeded` attempts
with `n=50`. The real catalog and launch exchange are in Cobalt's
`examples/silver_overview/wire/c6-{catalog,launch}.json`. Cobalt's
`dune runtest` also exercises default precedence, first use, and lost
acknowledgement without replay.

## Slice 2: stage checklist and fundamental aliases

Identify the public operation(s) corresponding to Silver's own quick launch.
Compare the resolved flow, profile and endpoint for checklist `R` and a palette
alias against Silver's native launch through that stage.

**Live acceptance:** select a non-synthesis row; exact `synth` must still offer
synthesis first and launch through synthesis. `R` must instead honor the selected
row. Repeat alias target checks for `timing` and `routing`. Extra query text
exposes related commands; an unavailable exact target cannot dispatch a runner-up.
Neither launch path moves focus to a different window or changes the watched run.
