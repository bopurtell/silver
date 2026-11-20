---
id: WB-078
title: Empty-directory entry and existing-project adoption
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
tags: [startup, discovery, adoption]
depends_on: [WB-051, WB-085]
related: [WB-010, WB-039, WB-050, WB-082]
---

# WB-078 — Empty-directory entry and existing-project adoption

## Request
Let `silver` be the first command in an empty directory and remain useful in an existing, unconfigured Dune project.

## Baseline before this ticket
Discovery chooses the nearest regular `dune-project`. With no enclosing project it reports an error. Existing Dune projects can already open without ASIC integration.

## Scope
For interactive local startup without a project, open an unbound Silver workspace with a dismissible project setup dialog. Default to the starting directory; preview the selected starter and explicitly open the resulting root. In an existing generic Dune project offer **Set up project…**, with separate actions to add starter files or import an existing executable by reference.

## Out of scope
Template protocol/contents (WB-051), new chip generation (WB-082), changing noninteractive command discovery.

## Acceptance criteria
- [x] Cancel from an empty directory without writing anything. Create there without forcing a nested directory, or choose an existing project instead.
- [x] From a nested source directory the nearest existing project still opens immediately. A discovery permission error is not treated as an empty directory.
- [x] In an existing Dune project, point setup at an existing ASIC design without replacing source. Creation/opening alone never starts EDA.

## Verification
On the fresh-project preview, **Enter** applies and opens the result. **Esc** cancels without writing and leaves the unbound workspace open; **p** reopens setup. In a bound project, **Add ASIC starter…** creates design files; **Import existing ASIC design…** references an already-built executable. Both paths were exercised with the installed `silver`.

`terminal/test_startup_entry_pty.py` exercises the launcher and dashboard handoff. `terminal/test_asic_adoption_pty.py` exercises **Set up project…** in the local palette, including starter preview/cancel/apply, collision handling, invalid import correction and registering an executable while preserving existing sources.

## Dependencies
[WB-085](WB-085-authoring-service.md) supplies daemon-side preview/apply before a project is open.
[WB-051](WB-051-new-project-creation.md) supplies the generator and preview/open handoff. Adding a first starter to a generic project is covered here. Adding a second independently buildable chip to an already configured project remains [WB-082](WB-082-chip-target-starter.md).

## Estimate rationale
8 points for startup without a bound project, destination choice, and the adoption UI, excluding generation.

## Destination decision
Create directly in the selected empty directory, or at a new destination. Do not add a nested directory implicitly. If the destination becomes occupied after preview, require a new preview ([WB-085](WB-085-authoring-service.md)).

## References
[Discovery](../../../setup/project_discovery.ml); [authoring intent](../../project_authoring_and_command_design.md).
