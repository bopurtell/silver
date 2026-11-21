---
id: WB-084
title: Empty-directory to reproducible synthesis acceptance
category: project
feature_sets: [FS0, FS3]
status: closed
kind: validation
priority: P2
severity: n/a
requested_size: Unspecified
size: S
points: 5
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [acceptance, synthesis, reproducibility]
depends_on: [WB-078, WB-082]
related: [WB-076, WB-081]
---

# WB-084 — Empty-directory to reproducible synthesis acceptance

## Request
Show that Silver can take a new user from an empty directory to a real synthesis result and hand off a self-contained design to a CLI user.

## Current baseline
The prepared FIFO checkout demonstrates real execution, but starting from a configured checkout skips authoring and can mask local path or state dependencies.

## Scope
Deliver a repeatable opt-in journey using installed tools: start Silver in an empty directory, create an ASIC starter, preview the target/flow, explicitly launch synthesis, inspect the result, then reproduce it headlessly from a clean copy of the committed design.

## Out of scope
Full physical signoff, bit-identical logs/attempt IDs, or repeating the menu and multi-target interaction matrices.

## Acceptance criteria
- [x] Record prerequisites and the selected target/profile/endpoint. Capture real synthesis completion and one comparable design result (e.g. cell count under the same toolchain).
- [x] In a clean clone at a different path, without copying `.dev`, Silver state, build outputs or results, use the documented CLI to reproduce synthesis and compare that result.
- [x] Distinguish an unavailable toolchain/skipped run from a passed acceptance; document the first failing step.

## Dependencies
[WB-078](WB-078-project-entry.md) provides empty-directory entry; [WB-082](WB-082-chip-target-starter.md) provides the reusable ASIC target recipe. Multi-chip selection is tested separately.

## Reproduction

The [WB-084 runbook](../../authoring_acceptance.md) gives the opt-in command,
installed-tool prerequisites, clean-clone CLI commands, and evidence layout.
`dune runtest scripts` covers the acceptance checks without requiring a PDK.

### Verified 2026-11-21

Silver created `demo` in an empty directory, previewed `demo/default` →
`standard/balanced` → `synthesis`, then explicitly launched the run. The
Silver inspector displayed **40 cells**. A clean clone containing only the ten
committed design files rebuilt the chip and independently reported **40 cells**
at the synthesis checkpoint (`design__instance__count`). Both used the IHP
SG13CMOS5L Tiny Tapeout 6×4 target and LibreLane `3.1.0.dev3`.

| Evidence | Recorded identity |
| --- | --- |
| Same disposable source revision | `6e6af72a2bb696d5ec7ee6d98a7e0fe01a8ff031` |
| Silver execution | `02531a41ba7c46bbb9d9c5cc0314b0b6` |
| Clean CLI execution | `358f3081804d4e059e32bd96ecf90ed3` |
| Matched container image | `sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a` |

Local receipt: `~/.cache/wb084-validation/acceptance-01/summary.json`.
An earlier attempt stopped at `CLI build` when the native linker hit the
`/tmp` user quota. That attempt was recorded as failed; the passing result
above used a fresh disk-backed evidence directory.

## Estimate rationale
5 points for an opt-in real-tool journey and clean-clone comparison, excluding the implementation it exercises.

## Assumptions and decisions needed
Use the same installed tools in both runs; user/session state must not supply missing source inputs.

## References
[Product boundary and acceptance intent](../../project_authoring_and_command_design.md#product-boundary-from-an-empty-directory-to-a-run).
