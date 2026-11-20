---
id: WB-079
title: New IP library and module starters
category: project
feature_sets: [FS3]
status: proposed
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 8
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [ip, templates, modules]
depends_on: [WB-085]
related: [WB-017, WB-051, WB-076, WB-077]
---

# WB-079 — New IP library and module starters

## Request
Create reusable hardware source, not a Silver inventory entry or an IP instance.

## Current baseline
The example keeps IP RTL and verification separate from chip targets. Dune describes libraries; a parent circuit instantiates and wires their blocks.

## Scope
Expose the same local scaffolding operation headlessly and in Silver. **New IP Library…** offers empty and sample-behavior starters, with a small module, Dune stanza and test stub. **New Module…** targets an existing library. Bind `new ip` to the library wizard.

## Out of scope
An editor, an add-file manifest, wiring instances, and regenerating user source.

## Acceptance criteria
- [ ] `new ip` + Enter opens the wizard instead of resource discovery. Preview then create; the starter builds and its test can be run with ordinary Dune.
- [ ] From a selected library, create a module without reselecting a destination; from Project or the palette with no library context, choose one explicitly.
- [ ] Cancel or repeat against an occupied path without changing user files. If a custom Dune stanza needs editing, identify the required change rather than rewriting it.

## Dependencies
[WB-085](WB-085-authoring-service.md) supplies the authoring call used by the wizard.
No project-root generator required. Coordinate alias registration with [WB-076](../presentation/WB-076-palette-intent-aliases.md) and menu placement with [WB-077](../presentation/WB-077-project-action-menu.md).

## Estimate rationale
8 points for two related templates, command/context integration and real Dune checks.

## Assumptions and decisions needed
Use small editable starter files; the first sample behavior and test contents can be chosen during implementation.

## References
[Design: one-shot templates](../../project_authoring_and_command_design.md#creating-things-templates-that-become-yours).
