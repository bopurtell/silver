---
id: WB-082
title: New chip target inside an existing project
category: project
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
tags: [templates, hardcaml-asic, chip-target]
depends_on: [WB-080, WB-085]
related: [WB-051, WB-078, WB-081]
---

# WB-082 — New chip target inside an existing project

## Request
Avoid copying the declaration, executable wrapper, Dune stanza and registration by hand for each independently runnable chip.

## Current baseline
Consumer projects own these files today. Creating an IP module or wiring a second instance does not require this plumbing.

## Scope
`hardcaml_asic` supplies a headless one-shot target starter; Silver's **New Chip Target…** gathers inputs and previews the same operation. Identify the top, target and timing assumptions explicitly. Offer catalog registration as a distinct narrow edit.

## Out of scope
Creating the enclosing Dune project (WB-051), provisioning tools, inferring electrical constraints or regenerating user code.

## Acceptance criteria
- [ ] Add a second buildable target alongside an existing one. It works headlessly and, once registered, appears in the catalog; the first target still builds.
- [ ] Preview distinguishes new files from the registration edit. Declining registration leaves the new target independently buildable. For a custom catalog show the snippet and destination instead of rewriting it.
- [ ] A name/path collision leaves existing source intact. Manual edits survive subsequent creation of a different target.

## Dependencies
[WB-085](WB-085-authoring-service.md) connects the UI to the headless operation on the service host.
[WB-080](WB-080-chip-catalog.md) defines the registration contract. Coordinate with [WB-051](WB-051-new-project-creation.md) so a fresh ASIC starter can reuse this recipe rather than maintaining a second declaration.

## Estimate rationale
13 points for the provider recipe, CLI/UI parity and safe integration with a populated project.

## Assumptions and decisions needed
**Needs design:** first target recipe and how to recognize a catalog where a narrow registration edit is safe.

## References
[Target authoring rationale](../../project_authoring_and_command_design.md).
