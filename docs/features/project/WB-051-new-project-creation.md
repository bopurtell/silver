---
id: WB-051
title: Provider-owned new-project creation
category: project
feature_sets: [FS3]
status: closed
kind: feature
priority: P3
severity: n/a
requested_size: Unspecified
size: L
points: 21
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [templates, creation, providers]
depends_on: []
related: []
---

# WB-051 — Create a project from a provider template

## Request
Original size: **Unspecified**. Create a new project using provider-owned templates,
then open the result in Workbench.

## Baseline before this ticket
The delivered initializer configures an existing Dune project and refuses replacement.
Workspace starter templates describe layouts, not source trees or project recipes.
The setup area spec assigns recipe content to the project/provider rather than
Workbench; no universal new-project schema is established by existing setup.

## Scope
- Define a bounded template descriptor and explicit generation operation.
- Adopt one real provider-owned starter with validated name/destination parameters.
- Preview generated files and publish to a new destination or directly into a selected empty directory without clobbering work.
- Offer explicit open/setup handoff after successful generation.

## Out of scope
An online template marketplace, arbitrary script installation, toolchain provisioning,
automatic initial commits and automatic hardware execution.

## Acceptance criteria
1. The template identifies its provider/version and required inputs before generation.
2. An existing nonempty destination or conflicting file is refused with no partial replacement. An existing empty destination does not require creating a nested directory.
3. Parameter errors and generator failure leave a clearly reported recoverable state.
4. The adopted starter opens using documented existing project/setup contracts.
5. Creating/opening a project does not implicitly build, simulate or run EDA.

## Dependencies
Required: delivered initializer/opener and one selected provider template contract.
No separate ticket blocker; template contract work is included here.
Related: none; configuration migration is not needed to use today's supported files.

## Estimate rationale
21 points cover one descriptor/generator boundary, one starter and safe handoff.
Exclude authoring every provider's recipes, package installation and template catalogs.

## Delivery
The first provider is `hardcaml_asic`. Its `hardcaml-asic-starter render --name NAME` command returns versioned JSON with relative paths and file contents; rendering does not write the destination. Silver validates and freezes that output at preview. Apply publishes the reviewed bytes without overwriting files. If a write fails partway through, the service reports retained output for inspection.

`scripts/test-real-project-starter.py` exercises the real provider through a Silver daemon: cancel in an empty directory, create there, open without submitting a job, then explicitly run the generated project's Dune tests.

## References
- [Existing initializer](../../../setup/initialization.ml)
- [Provider ownership requirements](../project_setup.md)
- [Delivered setup/layout distinction](../../fs3_adoption.md)
