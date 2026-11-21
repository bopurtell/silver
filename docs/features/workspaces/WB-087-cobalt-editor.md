---
id: WB-087
title: Persistent Cobalt editor workspace and open-location action
category: workspaces
feature_sets: [FS3]
status: needs-design
kind: feature
priority: P2
severity: n/a
requested_size: Large Feature
size: L
points: 21
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [cobalt, editor, navigation]
depends_on: []
related: [WB-029, WB-088, WB-090]
---

# WB-087 — Persistent Cobalt editor workspace

**Cross-repo ownership:** WB-087 owns the Silver workspace and any Cobalt changes
to expose the editor lifecycle, focus, and open-location entry point. Verify
standalone startup in Cobalt as well as the hosted editing loop in Silver.

Silver owns the layout and workspace focus; Cobalt owns its buffers, modes,
navigation and Git UI. Compare a hosted component with a supervised local child
on focus, resizing and session lifetime; record the smallest viable boundary.
Expose a host action taking project identity, relative path and optional line
and column. Define coordinate units at the boundary.

## Acceptance
- Invoke the action from Silver with just a path and with a line/column.
  Both focus the Editor workspace; a missing file reports why it cannot open.
- Edit without saving, switch workspaces and open the same file again. The same
  buffer and undo history survive. A different project cannot reuse that buffer by accident.
- Resize with a small Silver testing or overview tile beside Cobalt. Give focus
  to either surface and back; Cobalt editing, LSP bindings and its Git view
  remain reachable without Silver consuming their keys.
