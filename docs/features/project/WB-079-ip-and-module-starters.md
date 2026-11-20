---
id: WB-079
title: New IP library and module starters
category: project
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
- [x] `new ip` + Enter opens the wizard instead of resource discovery. Preview then create; the starter builds and its test can be run with ordinary Dune.
- [x] From a selected library, create a module without reselecting a destination; from the palette with no library context, choose one explicitly.
- [x] Cancel or repeat against an occupied path without changing user files. If a custom Dune stanza needs editing, identify the required change rather than rewriting it.

## Dependencies
[WB-085](WB-085-authoring-service.md) supplies the authoring call used by the wizard.
No project-root generator required. Coordinate alias registration with [WB-076](../presentation/WB-076-palette-intent-aliases.md) and menu placement with [WB-077](../presentation/WB-077-project-action-menu.md).

## Estimate rationale
8 points for two related templates, command/context integration and real Dune checks.

## Delivered starters
The empty starter provides an editable module and test stub. The sample starter is
a Hardcaml inverter with a Cyclesim test. Both live under `ip/<name>/` with a
library stanza that discovers added modules. An added module is a source file,
not a chip target or an instance of the library.

## Provider verification
`hardcaml-asic-starter render-ip --name accum --template sample` describes the
library; `render-module --name helper` describes a single editable module.
Rendering writes no source files. Both library variants were built and tested
with ordinary Dune, including compilation of an added module without a stanza edit.

## Silver verification
Owner confirmed the **new ip** and **Library: … → New Module…** palette workflows in the installed Silver. All acceptance criteria are checked.

The installed-binary PTY test covers both templates, contextual and explicit
module destinations, preview/cancel/apply, collisions, and ordinary `dune build`
and `dune runtest` with the real renderer:

```sh
python3 -B terminal/test_ip_authoring_pty.py "$(command -v silver)" "$(command -v hardcaml-asic-starter)"
```

`dune runtest author_cli backend/test/authoring daemon/test` exercises headless
local and connected commands, host-side path validation, and stale previews.
For module creation, select a directory with one explicitly named Dune library;
generated or ambiguous stanzas are declined.

## References
[Design: one-shot templates](../../project_authoring_and_command_design.md#creating-things-templates-that-become-yours).
