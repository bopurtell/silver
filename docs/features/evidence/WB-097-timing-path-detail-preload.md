---
id: WB-097
title: Preload details for the top N timing paths
category: evidence
feature_sets: [FS1]
status: proposed
kind: enhancement
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 8
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [timing, artifacts, cache, preload]
depends_on: []
related: [WB-069]
---

# WB-097 — Preload details for the top N timing paths

With the count set to five, leave Silver on Overview long enough to read the
timing artifacts, then open Timing and move through the first five rows in
**Timing Paths**. **Selected Path** should show each path's full detail as
soon as the highlight moves, without Enter or another provider read.

Today, [background loading](../../timing_workspace_usability.md#visible-loading-and-background-preparation)
warms the path **index**. The [detail loader](../../../terminal/timing_demand.ml)
can fetch a selected row and nearby rows after inspection starts. Its neighbor
count is relative to the selection; it does not warm the first N paths before
the user picks one.

## Acceptance criteria

- [ ] Provide a documented, saved project setting for the number of top paths
  to warm. Support at least `0` (index-only background loading) and `5`;
  document the default and supported range. Existing explicit-only mode
  suppresses background reads regardless of the count.
- [ ] Once the current analysis index is available, warm the first N distinct
  paths in Timing Paths order, or all available paths if fewer. Use real
  artifact detail, including fields absent from the index. No selection or
  explicit inspection is needed to start warm-up.
- [ ] Moving the highlight displays the exact cached detail immediately. For
  a cold row, show its loading state rather than the previous row's details;
  foreground demand takes priority over the remaining speculative reads.
- [ ] Reuse matching reads and respect cache and concurrency limits. A missing
  detail must not stall the rest of the batch or trigger an endless retry.
  Switching runs or replacing an artifact must not let an old response populate
  the new selection, even when path IDs match.

## Verification

Use a delayed, instrumented provider fixture with at least six paths and a
distinct detail-only value per path. With `N=5`, wait on Overview and verify
that only rows 1–5 have detail reads. Navigate those rows without Enter:
each value must appear on selection and the read count must stay flat.
Select row 6 to exercise a cold read. Repeat warm-up with `N=0` and in
explicit-only mode to check that neither issues background detail reads.
Switch runs during an outstanding read to exercise the stale-response case.
