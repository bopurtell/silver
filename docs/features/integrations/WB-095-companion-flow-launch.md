---
id: WB-095
title: Launch Silver flows and stages from standalone Cobalt
category: integrations
feature_sets: [FS2, FS4]
status: delivered
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

## Recorded acceptance (2026-11-22; ticket remains open)

`scripts/test-companion-flow-launch.py --slice c8|c9` runs the built Silver
daemon, native Silver terminal, and actual standalone Cobalt in a newly made
test project. Both UIs use the exact same project ID and `Inherit_daemon` on
private loopback. Cobalt is explicitly bound via `--silver-endpoint` and
`--silver-project`, while its document is outside that project. No editor
sharing or implicit connection is used. The fixture substitutes deterministic
source/EDA producers, not the daemon, transport, terminal clients, reservation
or preparation machinery. It does not invoke physical EDA tools or use a
running Silver project's configuration or state.

- **C8 live, default configuration:** In
  `~/.cache/wb095/wb095-gfv08m08/c8/`, `c8-comparisons.json` records seven
  distinct completed ASIC attempts: native Silver `R` on Routing, Synthesis,
  and Timing; Cobalt `R` on Routing; and exact `synth`, `timing`, `routing`
  with Routing selected. The selection and complete planned stage prefix
  match the equivalent native submission (`demo-chip/small`,
  `standard/balanced`, with the respective endpoint and no overrides).
  `c8-*` PTY captures show row-one selected aliases, regular search via
  `routing checklist`, checklist focus retained after `R` and restored after
  palette escape, and withdrawn Routing staying first but disabled. Enter
  on the disabled exact query sends nothing; an already-open Routing action
  also rejected after withdrawal without staging or submission. Native
  Overview's selected ASIC run and Cobalt's explicitly watched Testing
  attempt stayed unchanged.
- **C9 live, non-default configuration:** In
  `~/.cache/wb095/wb095-xr540yfm/c9/`, the Silver terminal's public `--api Plan`
  and Cobalt tile resolved identical `demo-chip/small`, `explore/review`,
  `routing`, `STRATEGY=delay` and plan identity
  `9165ac44f42a9e23476c0df07c5cf86ad7d0f1523ee4421c5482d6280fd66dea`.
  The actual `Run` sent the exact preview, including `plan_json`. Browsing,
  editing and previewing added zero workflows; two quick `K` presses added
  exactly one. The reply and PTY acknowledge workflow `workflow-958c76f3…`
  without a physical run ID; Silver later links completed run
  `fresh-c08d1a10…` (`c9-comparison.json` has full IDs). Changing the draft
  after review and superseding the ready preview in its server context
  each caused zero new `Run` requests and zero new workflows. The checklist
  was never opened in this C9 session; neither watched selection changed.

Each evidence root records binary paths and SHA-256 hashes in `binaries.json`.
The raw `native-http.jsonl` and `cobalt-http.jsonl` capture discovery, input
intent/plan staging, submissions and replies. `scripts/export-companion-flow-fixture.py`
projects the exchanges for Cobalt `silver_overview/test/wb095-{c8,c9}.sexp`,
replayed by `test_recorded_flow.ml`. The live captures exposed incorrect
inline-record encoding in Cobalt (`In_context`, `Stage_fresh`, `Launch_fresh`,
`Run`); fields must follow the constructor directly. C9 also rechecks the
server preview and local review generation before sending `Run`. Neither
slice needed a new Silver RPC.

To reproduce, use prebuilt binaries and put a compatible `dune` on `PATH` for
the fixture's publisher-copy rule. Replace the paths with local builds:

```sh
python3 scripts/test-companion-flow-launch.py --slice c8 \
  --daemon _build/default/daemon/main.exe --client _build/default/terminal/main.exe \
  --preset-export _build/default/terminal/workspaces/export_presets.exe \
  --cobalt /path/to/cobalt.exe --cobalt-source /path/to/cobalt
# Repeat with --slice c9. Use --evidence-parent /path/to/private/writable/dir
# if /tmp/opencode is quota-limited, and set TMPDIR for tool subprocesses.
```

Limits: this verifies fixture execution through the real service, not real
tool completion or a release build with the C8 implementation compiled out.
C8’s explicit non-default settings are covered at the adapter level, not by
this live C8 default-parity run. The public API does not atomically combine
preview polling with `Run`; for chip-aware projects Silver still validates the
exact scoped preview and plan identity if scope changes during delivery.

Verification scope: focused Cobalt flow adapter, recorded replay, checklist
and kickoff tile tests, and fixture PTYs passed. The broader Cobalt
`@screen/runtest @bin/runtest @silver_overview/runtest` attempt was not green:
it reported `/tmp` quota failures and separate configuration, main-editor,
share-connection and WB-093 quick-launch test failures. No conclusion about
those surfaces is drawn from this work.
