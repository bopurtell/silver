---
id: WB-083
title: Flow-owned profiles and explicit authoring commands
category: project
feature_sets: [FS0, FS3]
status: closed
design_status: designed
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [flow, methodology, profiles]
depends_on: [WB-085]
related: [WB-077, WB-082]
---

# WB-083 — Flow-owned profiles and explicit authoring commands

Delivered in the provider, Silver CLI and native Project menu. Owner accepted and closed this ticket on 2026-11-21.

## Request
Give each named flow an obvious source home, and distinguish creating a methodology, duplicating a settings variant and running an existing selection.

## Baseline before this ticket
FIFO's project declares a base flow; its catalog constructs `standard`, registers profiles from `flow_profiles.ml` and is exposed by the chip CLI. A new file alone registers nothing.

## Scope
- **New Flow…** authors one complete methodology entry with a provider-supported recipe, endpoints and initial profile. Default the owner to the invoking workspace's chip; allow choosing another chip before choosing the recipe. Preview the actual owner. Creating a flow does not switch targets, change defaults, stage a plan or start a run.
- **Duplicate Profile…** copies explicit assignments into a new ID in the same methodology, allows edits to provider-advertised parameters, and leaves unspecified settings inherited from methodology defaults. This is not live inheritance from the source profile. **Run Flow…** only executes an existing selection.
- Use the same authoring operation headlessly and from Silver: the provider describes source changes; the daemon previews/applies them on its host. Rendering alone is not a completed headless workflow.

### Standard flow collection and FIFO migration

Give the directory and the file pattern distinct roles. A chip's Dune build explicitly opts one directory into catalog generation (ordinary Dune rule invoking a provider generator; exact stanza TBD). Within that directory only `flow_*.ml` sources are entry modules. Other modules can be helpers. Do not scan the whole Dune project or infer chip ownership merely from a filename.

Generate deterministic catalog wiring under `_build/`, calling each entry's common function. Track additions/removals through Dune dependencies, reject duplicate IDs, and keep the default flow explicit rather than deriving it from filename order. No `.workbench` manifest, checked-in generated catalog, or per-flow edit to the Dune file. A standard **New Flow…** preview explains that creating the module registers it on build; do not report a failed build as a runnable flow.

**Implementation deliverable:** migrate `hardcaml_asic_example/asics/fifo_demo` from its hand-written catalog/profile assembly to this convention. Preserve `standard/balanced`, `standard/synth_delay`, the existing default and plan behavior; update its explicit source-input inventory so new flow sources participate in build identity. New chip starters should use the same convention. Other hand-written catalogs remain supported: offer a registration snippet rather than rewriting arbitrary OCaml.

## Out of scope
Requiring inline or custom profiles to move into separate files, migrating every custom catalog, or changing declared defaults when selecting a flow.

## Acceptance criteria
- [x] From the headless authoring CLI create a flow for B while A is the default. Only a new flow source is tracked. Build in a clean checkout without Silver running; B's CLI lists it and A's does not. Silver sees the same entries without changing the active target.
- [x] On the migrated FIFO example verify the existing selections/default and resolved settings. Add and remove an entry without touching the stanza; an ordinary helper is ignored and duplicate IDs give an actionable error.
- [x] Duplicate `standard/balanced` as `timing_trial`. The only tracked change is `flows/standard/profiles/timing_trial.ml`. Build and verify both profiles are listed under `standard`, the default remains `balanced`, and later changes to `balanced`'s explicit assignments do not change the copy.
- [x] Reject ID collisions with inline or additional profiles and refuse to overwrite an occupied path. For a custom flow without directory registration, return a declaration snippet and report manual registration required; leave its source unchanged.
- [x] Running the new selection creates an attempt without editing source; the prior profile remains runnable.

## Dependencies
[WB-085](WB-085-authoring-service.md) supplies preview/apply. Coordinate the starter layout with [WB-082](WB-082-chip-target-starter.md); registering a chip in the project catalog is distinct from compiling a chip's flow collection.

## Estimate rationale
13 points for the example convention, two provider-backed operations and CLI/UI verification.

## Agreed profile layout
Each starter-layout flow opts into its own additional-profile directory, `flows/<flow-id>/profiles/`. Built-in profiles may stay inline. **Duplicate Profile…** creates one user-owned OCaml module containing the new profile ID and copied explicit assignments with the user's edits. The build combines those modules with the owning flow's inline profiles; no existing source, Dune stanza or default selection is rewritten. Custom flows may opt in, or use the manual snippet fallback.

Implementation and verification work: validate the Dune rule, module linkage and build-identity tracking for both flow and profile sources on the supported Dune version. The FIFO migration remains an implementation deliverable.

## References
[Design: where to find a flow](../../project_authoring_and_command_design.md#where-to-find-a-flow).

## Verification
With matching provider libraries and tools installed, run:

```sh
python3 -B scripts/test-real-project-starter.py \
  --daemon "$(command -v silver-daemon)" --author "$(command -v silver-author)" \
  --flow-recipe librelane_classic_v1
```

The test adds `explore` and duplicates `standard/balanced` as `timing_trial`
for chip B while A is the project default. Each apply must add exactly one
source module. It then rebuilds both chips from a source-only copy without
Silver state and checks that B alone lists the additions and both defaults
are unchanged. `scripts/test_flow_collection.py` in `hardcaml_asic_example`
exercises the migrated FIFO and verifies the original and copied profiles.
