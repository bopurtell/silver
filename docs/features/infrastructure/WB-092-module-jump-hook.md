---
id: WB-092
title: Module-provided jump actions for Silver tiles
category: infrastructure
feature_sets: [FS3, FS4]
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
tags: [navigation, modules, actions]
depends_on: []
related: [WB-087, WB-088, WB-021]
---

# WB-092 — Let a module offer jumps for a selection

A tile asks the module behind it which named jump actions apply to a stable
selection. At invocation capture the project, module-owned selection reference
and action ID. The shared backend dispatches to the module's resolver; it does
not parse rendered text or switch on known tile kinds. A known location may be
returned immediately; evidence lookup can complete later for that same request.

Return one location, multiple labeled candidates, or an unavailable reason.
The frontend owns candidate choice, destination (embedded or main editor),
focus and Back. Providers do not open editors. Use one resolved location shape
across destinations; document coordinate units and preserve source identity for
retained evidence when supplied.

## Acceptance
- Exercise offer → resolve with a headless example module, without a Testing
  tile, Cobalt, or a running editor. Adding another provider needs no dispatcher change.
- Cover direct, ambiguous and unavailable results. Nothing opens automatically
  for an ambiguous or unavailable jump.
- Start a lookup for A and move selection to B before completion: the result
  remains identified with A; an obsolete response cannot satisfy a newer request.
- A recording destination receives the same resolved location regardless of
  editor choice. Keybindings and live editor transport remain frontend concerns.
