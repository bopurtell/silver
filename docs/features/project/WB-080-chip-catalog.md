---
id: WB-080
title: Provider chip-target catalog and CLI selection
category: project
feature_sets: [FS3]
status: delivered
kind: feature
priority: P1
severity: n/a
requested_size: Unspecified
size: L
points: 21
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [hardcaml-asic, catalog, cli]
depends_on: []
related: [WB-081, WB-082]
---

# WB-080 — Provider chip-target catalog and CLI selection

## Request
List and address several independently buildable chips in one Dune project, even with Silver closed.

## Current baseline
The example declares FIFO, program-memory and SRAM-budget targets separately. `Hardcaml_asic.Project.create` declares one target, not the enclosing project. Silver's ASIC integration names one executable.

## Scope
Define a `hardcaml_asic` listing/selection contract and exercise it from the CLI against two real targets. The Dune project supplies stable entries and how to reach them; targets retain their own design declarations and flow catalogs. Prefer `Chip_target.create` vocabulary with a compatible `Project` spelling.

## Out of scope
A second top-level `Silver.Project.create`, copied hardware metadata, UI selection, or source generation.

## Acceptance criteria
- [x] CLI list/select distinguishes two targets and reaches each target's own declaration/flows. Unknown and duplicate target IDs yield actionable errors.
- [x] Removing a catalog entry removes discoverability without breaking the target's direct build. Old `Project.create` consumers build without rewriting declarations.

## Dependencies
None. This is the provider contract consumed by [WB-081](WB-081-chip-target-selection.md) and [WB-082](WB-082-chip-target-starter.md).

## Estimate rationale
21 points, low confidence: the catalog crosses producer API, CLI and consumer-example boundaries.

## Implementation and verification
The provider's `hardcaml-asic-targets` CLI consumes the project's versioned `hardcaml-asic-targets.json`. Each stable ID points to a project-relative executable; omitting the ID selects the declared default. The example registers `fifo_demo` and `program_memory`. `Chip_target.create` is a compatible alias for `Project.create`.

With the catalog-capable provider active, run `python3 -B scripts/test_target_catalog.py` in `hardcaml_asic_example` for the two-target CLI and independent-build checks. The example's recorded provider pin predates the catalog tool; use matching local sources until a published provider revision is available.

## References
[Ownership model](../../project_authoring_and_command_design.md#vocabulary-and-ownership); [existing consumer config](../../../project_integration/asic_config.ml).
