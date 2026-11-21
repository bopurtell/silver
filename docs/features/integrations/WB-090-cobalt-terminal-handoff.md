---
id: WB-090
title: Delegate embedded editor terminal requests to Silver
category: integrations
feature_sets: [FS3]
status: needs-design
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 8
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [cobalt, terminal, focus]
depends_on: [WB-087, WB-089]
related: []
---

# WB-090 — Delegate Cobalt terminal toggles to its host

**Cross-repo ownership:** WB-090 owns both the Cobalt input/host-action change
and the Silver handler. Acceptance below covers both repositories under this ID.

Add an optional Cobalt host action carrying the recognized toggle and terminal
number. Use the embedding boundary chosen in WB-087. Standalone Cobalt handles
the same action locally. Only the focused surface interprets raw keystrokes.

## Acceptance
- Toggle 2 in embedded Cobalt: one Silver-wide overlay opens. Reopen 2 from
  Timing and verify shell identity; no second editor-local shell was started.
- Hide from editor Insert and resume in the original buffer, cursor and mode.
  Exercise numbered chords, slow literal prefixes and pasted chord text.
  Pending input never lands in a newly focused shell or buffer.
- Repeat standalone Cobalt's toggle/reopen flow without a Silver host.
