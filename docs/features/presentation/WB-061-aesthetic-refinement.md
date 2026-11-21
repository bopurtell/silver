---
id: WB-061
title: Bounded workspace aesthetic refinement
category: presentation
feature_sets: [FS5]
status: partial
kind: enhancement
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 13
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [aesthetics, owner-review, bounded-polish]
depends_on: []
related: [WB-001, WB-024, WB-059, WB-060]
---

# WB-061 — Bounded workspace aesthetic refinement

## Request
Refine the workspace's visual coherence and usability through owner review.
Requested size: **Unspecified**; estimate one bounded review/implementation iteration.

## Current baseline
A–E, compositional layouts, typed semantic colors, dense refinements and native
indicators are delivered. Current preferences favor dense packing, lowercase titles
and no decorative title dots. These are the review baseline, not immutable rules.

## Scope
- Review representative existing workspace captures with the owner once.
- Agree a finite punch list of spacing, hierarchy, contrast and chrome refinements.
- Implement that list and return comparable evidence for one completion review.

### Testing workspace: make Simulation Detail easier to scan

The [Testing redesign (WB-063)](WB-063-testing-workspace.md) delivered the
investigation workflow. This follow-up concerns how its fields read:

- Give labels and values distinguishable theme roles, keeping outcome, lifecycle
  and artifact availability recognizable by text as well as status color.
- Align the start of values within each group of `label: value` rows. At narrow
  widths, reduce padding or stack the value rather than squeezing it out.
- Replace `Artifact bytes` with `Artifact size`. Use decimal byte units: `0 B`,
  `513 B`, `1.25 kB`, `2.50 MB`, `3.00 GB`; keep an absent size `unknown`.
- Make the source of each group apparent: the selected attempt and its captured
  inputs, case results, and the selected artifact. The Catalog configures the
  next run; Project Tests lists generic Dune test jobs.

The Testing changes are implemented in the terminal client. The compact view
puts the outcome, case results and selected artifact ahead of the longer attempt
identifiers and captured inputs. The Project Tests tile now identifies its rows
as Dune test jobs. See [layout and selection](../../testing_workspace.md#layout-and-selection).

The [native reconnect test](../../../scripts/test-client-reconnect.py) checks that
the artifact label and size are visible without scrolling at 120×40. It compares
the painted artifact fields against the daemon response before and after narrowing,
widening and reconnecting. Local before/after captures of the same fixture and
dimensions: `/tmp/opencode/{wb061-before,wb061-final}/first-client-selected.txt`
(with `.ansi` alongside for color).

## Out of scope
An infinite theme redesign, new investigation capabilities, or silently choosing
a final default. Separate feature tickets retain their own scope and estimates.

## Acceptance criteria
- [x] Record the selected workspaces, visual goals and bounded punch list up front.
- [ ] Show before/after terminal captures with the same content and dimensions.
- [ ] Narrow-size recovery, semantic statuses and keyboard discoverability remain sound.
- [ ] Record owner review outcome and explicitly defer any newly requested iteration.
- [ ] Appearance-only changes preserve identities, contexts and provider behavior.
- [x] Compare the same attempt and artifact at normal and narrow widths. Labels,
  values and statuses remain distinguishable; grouped values align where space
  permits. Verify zero, unknown and scaled sizes (1,250,000 bytes → `1.25 MB`).

## Dependencies
Required: none; existing workspaces and captures support immediate review.
Related: [WB-001](WB-001-checklist-column-alignment.md) and
[WB-024](WB-024-context-link-label.md) are separately scoped cosmetic defects;
[WB-059](WB-059-terminal-glyph-validation.md) adds compatibility findings;
[WB-060](WB-060-comparison-gallery.md) can enrich comparison evidence.

## Estimate rationale
Thirteen incremental points cover one agreed review, implementation and acceptance
cycle. Low confidence reflects aesthetic choices, not unlimited future polish.

## Assumptions and decisions needed
Agree the review sample, completion standard and maximum punch list before work.
New requests beyond that list become followups rather than extending this estimate.

## References
- [Current presets and captures](../../appearance_presets.md)
- [Delivered refinement](../../frontend_refinement.md)
- [Appearance contract](../appearance.md)
