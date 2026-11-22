---
id: WB-095
title: Launch Silver flows and stages from standalone Cobalt
category: integrations
feature_sets: [FS2, FS4]
status: proposed
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: L
points: 21
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [cobalt, quick-launch, flows, stages]
depends_on: []
related: [WB-083, WB-093]
---

# WB-095 — Companion flow launch

This ticket owns cross-repo acceptance for the stage checklist and aliases
formerly in WB-093 slice 2, plus a tile for kicking off a named flow. WB-093's
test tile and `test` alias are separate. Deliver Cobalt **C8 (checklist and
aliases)** and **C9 (flow kickoff tile)** independently: either can ship and
be verified without the other or any sharing feature. Both use the optional
companion's existing connection and project binding. The Silver window need
not have the launch target selected or even have focus.

## C8 — Stage checklist and fundamental aliases

- `R` on the checklist launches the active flow through the **selected** stage
  using [Silver's native quick-launch rules and defaults](../../checklist_launch_workflow.md).
  Resolve against the current launch target, not the watched run. Use applicable
  flow/profile settings and explicit assignments, or the target's declared
  defaults if no settings apply; change only the endpoint. Don't borrow another
  target's settings or silently fall back from a stale explicit selection. A
  supported fresh endpoint is launchable even without a prior run.
- Exact `synth`, `timing`, and `routing` resolve their named stage independently
  of the checklist selection. On an exact query, put the action in **row 1,
  selected**. Extra query text returns to normal search and exposes related
  commands. An unavailable exact action stays first with a reason; Enter must
  not dispatch it or a runner-up.

**Two-window acceptance:** Bind standalone Cobalt and Silver to the same
project. Select a non-synthesis row; exact `synth` must offer synthesis first
and launch through synthesis. Checklist `R` must instead launch through the
selected row. Repeat the named-target checks for exact `timing` and `routing`.
Compare checklist `R` and an exact alias through the same stage with Silver's
native launch for that stage: verify the resolved target, flow, profile and
endpoint, and identify distinct acknowledged runs. Check extra query text and
an unavailable exact target (no submission). `R` keeps focus in the checklist;
dismissing the palette restores its caller. Neither path switches windows or
changes the watched run.

## C9 — Named flow kickoff tile

- List the bound project's named flows for the selected launch target. Let the
  user select a flow and a supported configuration, using
  [native Silver launch inputs and defaults](../../launch-target.md), not a
  second set of defaults in Cobalt. Preview the resolved chip/variant, named
  flow, profile, endpoint and parameter values before **Kickoff**. The selected
  flow/configuration drives the launch; no checklist selection is required.
- Browsing, editing and preparing the preview never start execution. **Kickoff**
  submits only the exact ready preview; missing, pending, failed or stale
  preparation makes Kickoff unavailable with a reason. Report acknowledgement
  and run identity in place, without changing focus or the watched run.

**Two-window acceptance:** With both windows bound to the same project, pick a
named flow and a supported configuration that differs from the default. Compare
the preview with Silver's native plan for the same inputs and verify that
selection and preview create no run. Use **Kickoff** once and verify in Silver
that the acknowledged run uses that exact configuration. Repeat with a stale
or unavailable preview and verify no run starts. Exercise the tile without
C8 or sharing enabled.

## Cross-repo contract and verification

- Silver owns discovery, resolution, preparation, execution and launch
  semantics; Cobalt's optional Silver module owns its client state. Trace the
  public operation(s) behind Silver's native paths first. Reuse the supported
  contract; do not assume a dedicated stage-launch or flow-kickoff RPC exists.
  If a public operation is missing, record the Silver-side seam and agree the
  contract before treating either live check as complete.
- Keep discovery, preparation, submission and acknowledgement asynchronous
  behind the adapter. Tiles render prepared state and emit intents; the
  checklist and its aliases use the same stage-launch path. Capture the binding,
  selection and preview identity as applicable; revalidate before submission.
  A changed binding or newer intent invalidates pending preparation, and a
  late reply cannot authorize a launch or overwrite the current selection.
- Capture real discovery, preparation (where applicable), submission and reply
  exchanges for each slice. Use those as fake-peer fixtures so Cobalt and
  Silver can work independently. Cover one submission per invocation, stale
  or unavailable inputs, late replies, focus, and rejection versus lost
  acknowledgement. Never automatically resubmit on reconnect; closing Cobalt
  does not cancel Silver's execution. Fixture tests establish adapter readiness,
  not cross-repo acceptance: record the real two-window result separately for
  each slice.
