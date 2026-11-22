---
id: WB-090
title: Delegate embedded editor terminal requests to Silver
category: integrations
feature_sets: [FS3]
status: closed
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

**Closed at the owner's request (2026-11-22).** The hosted PTY probe verified
shell reuse and restoration of Insert mode. One input owner per
keystroke: Cobalt recognizes the chord while editing; Silver selects the
number and owns overlay focus. Verify the unnumbered case across workspaces:
select shell 2 in Timing, hide it, toggle from Cobalt Insert mode, see the same
shell 2, hide it, then type at the original editor cursor in Insert mode.

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

## Cobalt handoff

Pass `~on_toggle_terminal` to `Cobalt_hosted.component`: `Some 2` selects
terminal 2; `None` toggles the most recently selected terminal **in Silver**,
including one selected from Timing. Cobalt recognizes the chord and emits
the action. While the editor owns input, do not also match that chord in the
Silver router. Silver should open its WB-089 overlay, move focus, and return
focus to the mounted editor when the overlay closes. See Cobalt's
`ui/HOSTED.md` for the component contract. From the Cobalt checkout, run
`dune runtest -j 4 hosted/test` for the fake-host acceptance test and
`dune build -j 4 @scripts/smoke-embedded-terminal` for standalone regression.
