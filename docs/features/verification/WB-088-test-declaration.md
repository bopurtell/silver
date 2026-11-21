---
id: WB-088
title: Jump from a catalog test to its OCaml declaration
category: verification
feature_sets: [FS2, FS3]
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
tags: [testing, cobalt, navigation]
depends_on: [WB-087]
related: [WB-032, WB-063, WB-066]
---

# WB-088 — Open the selected test declaration

Carry an optional declaration position on a stable test catalog entry. Have one
real provider capture it at the OCaml call site (for example with `[%here]`),
not inside a shared registration helper. Route the Testing action through
WB-087 rather than teaching the editor about tests.

## Acceptance
- With no run or failure required, select the test and invoke “Open declaration”
  (`gd` proposed). Cobalt focuses the correct project file and declaration.
- Edit, go Back to the same Testing selection, and repeat the jump. Unsaved
  edits survive. The same chord inside Cobalt retains editor semantics.
- An older provider or a test with no position still lists and runs normally;
  the jump is unavailable with a reason, not a search by display name.
