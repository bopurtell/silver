---
id: WB-082
title: New chip target inside an existing project
category: project
feature_sets: [FS3]
status: delivered
design_status: designed
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: L
points: 21
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [templates, hardcaml-asic, chip-target]
depends_on: [WB-080, WB-085]
related: [WB-051, WB-078, WB-081]
---

# WB-082 — New chip target inside an existing project

In the authoring UI a **Silver project** is the enclosing Dune-backed project that owns a collection of chip targets. `hardcaml_asic` declares an individual **chip target**. The project catalog lists those targets; it is not another chip declaration.

## Request
Avoid copying the declaration, executable wrapper, Dune stanza and registration by hand for each independently runnable chip.

## Current baseline
WB-051/WB-078 supply project creation and first-starter entry. WB-080 introduced the compatible `Chip_target.create` spelling and a versioned JSON target catalog. Consumer projects own chip declarations and CLI wiring. This ticket aligns the existing paths and terminology; creating an IP module or wiring a second instance does not itself create a chip.

## Scope
- **New Project…** creates the Silver project (Dune root), then creates and registers its first chip target using the same target-authoring operation as **New Chip Target…**. The first target is the initial default. Opening an existing generic Dune project still does not create a chip.
- **New Chip Target…** operates inside the open project. Its first choice is **From IP library…** or **From example/template…**. The latter starts with the provider's minimal working example. Show the harness, technology and clock assumptions before applying.
- **From IP library…** selects an existing library and creates a new chip-owned wrapper, declaration and CLI that depend on it. From a library's contextual action, preselect that library. Leave IP implementation and verification files alone. Require explicit interface/clock/reset/pin mapping where the recipe cannot establish it; do not silently invent connections or advertise an unwired top as ready.
- Reuse one headless `hardcaml_asic` recipe through the daemon. Preview new chip files separately from catalog registration. For an additional chip, offer registration selected by default but deselectable; registration appends an entry without changing the default, active launch target or staged plan. Offer **Select new chip target** explicitly after registration.
- Normalize ASIC-facing terminology across the provider public entry points, CLI/help, starter output, guides and the `hardcaml_asic_example` consumer: **project** for the enclosing collection, **chip target** for a build declaration. Prefer `Chip_target.create` in new and migrated code. Keep inexpensive aliases where useful; preserving every historical name/layout is not an acceptance gate. Document migration and verify the example in the new organization.

## Out of scope
Reimplementing Dune-root creation (reuse WB-051), provisioning tools, inferring electrical intent, or regenerating user-owned code.

## Acceptance criteria
- [x] Add a second buildable target alongside an existing one. It works headlessly and, once registered, appears in the catalog; the first target still builds.
- [x] Preview distinguishes new files from the registration edit. Declining registration leaves the new target independently buildable. For a custom catalog show the snippet and destination instead of rewriting it.
- [x] A name/path collision leaves existing source intact. Manual edits survive subsequent creation of a different target.
- [x] Automate the fresh-project path: one Dune root and one registered default chip, produced by the same target recipe used to append chip B. Build A and B; check A's hand-edited files byte-for-byte, and verify its default and active selection did not change.
- [x] Exercise both starter branches through the daemon. For **From IP**, use a real library and explicit mapping: build the wrapper and verify observable IP behavior through it. The IP sources remain byte-identical. An unsupported interface or missing required mapping is reported before claiming success.
- [x] Exercise stale catalog preview and registration declined. Neither may overwrite concurrent edits. With registration declined the new target builds directly but is absent from the picker.
- [x] Build and enumerate the migrated example targets using documented chip-target vocabulary. Test the new public path, not just the compatibility alias.

## Dependencies
[WB-085](WB-085-authoring-service.md) connects the UI to the headless operation on the service host.
[WB-080](WB-080-chip-catalog.md) defines the registration contract. Coordinate with [WB-051](WB-051-new-project-creation.md) so a fresh ASIC starter can reuse this recipe rather than maintaining a second declaration.

## Estimate rationale
The original 13 points covered one starter and registration. Revised provisional estimate: 21 points, including both starter paths, first-target reuse and provider/example vocabulary migration.

## Implementation and verification
The first supported IP interface is the sample library at `ip/<name>` with its `chip-interface.json` declaration and `Block.create : Hardcaml.Signal.t -> Hardcaml.Signal.t`. The explicit `ui_in:uo_out:comb8` mapping connects eight input and output pins; the block uses neither clock nor reset. Preview typechecks the selected source on the service host. The generated test compares wrapper and IP outputs across all 256 inputs.

`r` changes the registration choice at preview; **Enter** applies. Registration does not select the target for launch. For custom catalogs the preview supplies a manual entry instead of rewriting the file.

- With matching binaries on `PATH`, `python3 -B scripts/test-real-project-starter.py --daemon "$(command -v silver-daemon)" --author "$(command -v silver-author)"` exercises fresh creation, mapped IP, default preservation and a directly built unregistered chip.
- `terminal/test_startup_entry_pty.py` and `terminal/test_ip_authoring_pty.py` exercise the real dialogs, cancellation, stale previews, explicit selection and wrapper behavior. Pass the installed Silver and renderer paths for real-provider coverage.
- The [example migration notes](../../../../hardcaml_asic_example/docs/repository_layout.md#chip-target-migration-wb-082) cover the new `cli/chip.exe` paths, compatibility entry points and target-specific ownership.

## References
[Target authoring rationale](../../project_authoring_and_command_design.md).
