---
id: WB-075
title: Human-readable job labels in the execution tile
category: presentation
feature_sets: [FS0, FS2, FS5]
status: delivered
kind: defect
priority: P2
severity: S3
requested_size: Unspecified
size: S
points: 3
confidence: high
estimate_scope: incremental
origin: owner-intake
tags: [execution, jobs, labels]
depends_on: []
related: [WB-064, WB-005, WB-063]
---

# WB-075 — Human-readable job labels in the execution tile

## Request
Owner note, 2026-10-20: why does the Testing workspace's execution tile say
`simulation.run` or `simulation.discover`? Is there a different run and discovery
that needs to be told apart?

## Current baseline
No — there is one run and one discovery. The tile prints the raw job kind,
`namespace.name` (`Job.Kind.to_string`, rendered at `host_view.ml`). `simulation.*`
jobs are the structured FS2 provider's discovery and run jobs. Generic project jobs
show as `dune.*`, and driver jobs as `project-driver.generate-rtl` / `.describe`.
The namespace is what separates structured simulation from generic Dune tests, but
the raw form reads like an internal ID.

## Scope
- Map known job kinds to short labels, e.g. `sim discover`, `sim run <case>`,
  `dune build`, `dune test`, `RTL generate`; unknown kinds keep the raw form.
- Keep the raw kind in job detail/inspection.

## Out of scope
Process-tree views (WB-005) and generic job detail (WB-064).

## Acceptance criteria
- [ ] Execution rows show readable labels that still distinguish structured simulation from generic tests.
- [ ] Unknown or provider-added kinds fall back to `namespace.name`.
- [ ] Job detail shows the exact raw kind.
- [ ] Test scripts that match the old strings are updated.

## Dependencies
None.

## Estimate rationale
3 points, high confidence: one label mapping plus script expectation updates.

## Assumptions and decisions needed
Confirm label wording; include the case or suite name on run rows when it fits?

## References
- [Job kinds](../../../protocol/job.ml)
- [Execution rendering](../../../terminal/host_view.ml)

## Delivery notes — 2026-11-05

Implementation is **delivered, awaiting owner acceptance**. The acceptance checklist
above remains unchecked pending owner review; automated evidence is recorded below.

Execution rows now use the following presentation-only labels:

| Raw kind | Row label |
| --- | --- |
| `simulation.discover` | `sim discover` |
| `simulation.run` | `sim run`, with available suite/case context |
| `dune.build` | `dune build` |
| `dune.test` | `dune test` |
| `project-driver.generate-rtl` | `RTL generate` |
| `project-driver.describe` | `project describe` |
| Unknown/provider-added kinds | Exact raw `namespace.name` |

Simulation context is joined by job ID from simulation state in the same workspace,
never borrowed from an unrelated selected attempt. Single-case detail adds
`suite/case`; multi-case/whole-suite detail and retained history add the suite.
Without matching context the label remains `sim run`. Normal row-width clipping
still applies. Selected-job detail includes `Kind: <exact raw kind>`; protocol kinds
are unchanged. Label wording and contextual readability await owner review.

### Verification

Passed with `DUNE_BUILD_DIR=_build_labels` and `scripts/with-switch.sh`:

- `dune runtest -j10 terminal`: mappings, case-sensitive unknown fallback,
  job-ID context matching, single/multiple/all-case selections, history fallback,
  rendered labels/raw detail, and existing state-color/identity tests.
- `dune build -j10 @lint terminal/main.exe daemon/main.exe`.
- Focused formatting checks for `terminal/presentation.ml` and
  `terminal/host_view.ml`; `git diff --check`.

Updated `scripts/test-testing-workspace.py` with readable discovery and single-case
run expectations. The following PTY check was attempted twice:

```sh
python3 -B scripts/test-testing-workspace.py \
  --daemon _build_labels/default/daemon/main.exe \
  --client _build_labels/default/terminal/main.exe
```

Both attempts failed at the initial `testing-layout-120x40` assertion, before the
new label checks: the screen still showed Overview with Testing present in the tab
bar. No unchanged-baseline comparison was performed, so the cause is not established
and end-to-end verification remains incomplete. Evidence is retained locally at
`/tmp/opencode/testing-workspace-iqxke0at` and
`/tmp/opencode/testing-workspace-a73oonct`. The temporary `_build_labels` directory
was subsequently cleaned. Repository-wide `@fmt` also encountered formatting
differences outside the focused formatted files. Neither PTY nor owner acceptance
is claimed.
