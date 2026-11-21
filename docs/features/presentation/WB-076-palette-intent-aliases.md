---
id: WB-076
title: Predictable palette launch aliases
category: presentation
feature_sets: [FS0, FS5]
status: closed
kind: enhancement
priority: P1
severity: n/a
requested_size: Unspecified
size: S
points: 3
confidence: high
estimate_scope: incremental
origin: owner-intake
tags: [palette, launch, aliases]
depends_on: []
related: [WB-054, WB-079]
---

# WB-076 — Predictable palette launch aliases

Owner accepted and closed this ticket on 2026-11-21.

## Request
Make the first Enter on a common query predictable, even as more commands are added.

## Baseline before this ticket
Palette search includes inspection, discovery and endpoint-specific launches. Its highest match need not be the operation the user meant.

## Scope
Pin exact curated queries to command identities before ordinary fuzzy ordering. Show the actual target, profile and endpoint on the selected launch row.

## Out of scope
Global command reweighting, learning preferences or changing the underlying flow recipes.

## Acceptance criteria
- [x] With a plan staged through CTS, `a launch` + Enter launches that exact plan. With no staged plan it explains why it cannot run; Enter never dispatches another match.
- [x] Under the same conditions, `synth` + Enter starts one fresh synthesis run in view for the current target/profile. No Tab or redundant confirmation when the inputs are known.
- [x] `synth rows` can still find discovery. Exercise actual dispatch after inserting a competing search match, not just sorted labels.

## Automated verification
`dune build @terminal/test-palette-launch-aliases-pty @terminal/test-chip-contexts-pty`
drives the terminal and checks the selected row, the submitted recipe and the
run put in view. `@terminal/runtest-terminal_presentation` covers competing
commands and chip names that match the launch aliases.

## Follow-up shortcuts
The [palette reference](../../frontend_composition.md#command-palette) lists
the stage, chip and verification shortcuts. Bare endpoint names use the
selected flow's capabilities: `cts` starts a new run through CTS, while
`a launch` submits a plan already staged. `chip` and `test suites` open
pickers; `test` reviews the current suite's selected cases before submission.

## Dependencies
None. [WB-079](../project/WB-079-ip-and-module-starters.md) delivered the `new ip` alias and wizard. The launch aliases in this ticket are independent.

## Estimate rationale
3 points: a small ordering change plus targeted dispatch coverage using existing launch commands.

## Assumptions and decisions needed
The two launch meanings are settled; preserve the existing staged-plan and fresh-run paths.

## References
[Design: stable intent](../../project_authoring_and_command_design.md#command-palette-stable-intent-beats-fuzzy-ranking).
