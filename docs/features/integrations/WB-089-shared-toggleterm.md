---
id: WB-089
title: Numbered ToggleTerm sessions across Silver workspaces
category: integrations
feature_sets: [FS3]
status: needs-design
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [cobalt, terminal, workspace]
depends_on: []
related: [WB-090]
---

# WB-089 — One ToggleTerm pool across Silver workspaces

**Cross-repo ownership:** WB-089 owns Silver's terminal pool and overlay plus
any Cobalt library extraction or packaging needed to reuse its terminal runtime.
Record both standalone terminal regression results and the Silver shell-reuse check here.

Reuse or extract Cobalt's `terminal/host/runtime.mli` and numbered
`ui/terminal_host.mli` pool. Silver owns the overlay and focus. Specify the
shell's initial project directory and local execution host explicitly; a remote
run selection must not silently change where commands execute.

## Acceptance
- Start terminal 2 from Testing, set a shell variable, hide it, then reopen 2
  from Timing. Its variable and output produced while hidden are present.
  Terminal 1 has a separate shell and history.
- Resize the overlay, hide it and restore the invoking tile. A workspace switch
  does not stop the shell. Shell exit/restart affects only that number, and
  closing the frontend cleans up its PTYs and children.

## Cobalt handoff

Link `cobalt.terminal` from the terminal frontend. Its `Cobalt_terminal_pool`
module is the same numbered PTY pool standalone Cobalt uses; it does not
depend on the editor UI. Create it once per frontend, pass the local project
directory and dimensions on `Start`, keep consuming updates while the overlay
is hidden, and await `shutdown` on frontend exit.

Cobalt's `examples/terminal_pool/README.md` gives the pool-only example and
isolated install check. The example verifies persistent hidden output, shell
reuse and child cleanup. The Testing → Timing overlay check above is still
Silver-side acceptance.
