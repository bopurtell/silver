---
id: WB-052
title: Adoption/help/SSH/tmux workflow polish
category: project
feature_sets: [FS3, FS5]
status: partial
kind: enhancement
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 8
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [help, ssh, tmux, adoption]
depends_on: []
related: []
---

# WB-052 — One bounded adoption polish pass

## Request
Original size: **Unspecified**. Improve adoption guidance, contextual help and
practical SSH/tmux use so existing workflows are easier to discover and recover.

## Current baseline
FS3 delivers installed initialization, portable workspaces and persistent presentation.
FS1 documents inspector controls, client-host artifact viewers and tmux Escape delay.
The owner's earlier Escape-latency issue is recorded as resolved, not reopened here.
There are still distinct configuration, session and provider-host concepts to explain.

## Scope
- Review one end-to-end existing-project setup and remote terminal journey.
- Improve help for root/environment selection, attachment and explicit provider refresh.
- Explain inspector exit controls, remote viewer locality and tmux Escape configuration.
- Address a bounded set of misleading messages found in that review.

## Out of scope
An endless UX program, automatic SSH provisioning, changing the user's tmux settings,
new rendering modes and a comprehensive terminal/font compatibility matrix.

## Acceptance criteria
1. A documented minimal route reaches useful generic views before hardware setup.
2. Help distinguishes client host, daemon host and provider paths for remote use.
3. Inspector exit and reconnect/reopen guidance match actual supported controls.
4. tmux guidance explains the tradeoff and requires explicit user configuration.
5. Selected adoption failures show a next action without claiming unavailable capabilities.

## Dependencies
Required: delivered FS3 setup and FS1 controls; no new ticket blocker.
Related: none required; terminal glyph validation is a separate compatibility outcome.

## Estimate rationale
8 points cover one bounded review, documentation/message fixes and workflow verification.
Exclude mouse/layout redesign, new onboarding engines and broad remote infrastructure.

## Assumptions and decisions needed
Default: one local and one SSH/tmux walkthrough using existing supported features.
TBD: representative remote environment and the finite issue list selected for the pass.
Help changes should point to real controls rather than promise future shortcuts.

## References
- [Adoption guide](../../existing_project_setup.md)
- [Inspector/tmux guidance](../../asic_evidence_inspection.md)
- [Terminal entrypoint](../../../terminal/main.ml)

## Added bounded scope — isolated review tooling (2026-11-05)

Explicitly requested extension: task-local example setup and a reproducible launcher
for a worktree's own daemon/client, with pinned provider environment, private state
and preferences, endpoint handoff, identity reporting and actionable preflight.
This implementation was **not part of the original ticket scope/estimate above**.
It supports adoption review without disturbing the owner's manual-validation pair.

Implementation and verification: [isolated example verification](../../archive/delivery/isolated_example_verification.md).

## Recovery and adoption pass — 2026-11-19

- Recovered the isolated review tooling onto `oxcaml` (`92b3f3d`), retaining the
  configured build target fix without the old branch tip's unrelated deletions.
- The [adoption guide](../../existing_project_setup.md) and F8 connection details now cover
  generic project opening, attach-only behavior, host-local paths and viewers,
  reconnect, inspector exits, and explicit refresh. Missing-project and invalid
  endpoint diagnostics suggest a next action.
- Fixtures and a disposable committed-source example passed on the recovered
  build. A real loopback SSH/tmux run exercised the new help, detach/reattach,
  recovery after a daemon restart, client reopen, and forwarded attachment.
- The automated retained-evidence inspector test passed, including Esc from
  detail/filter and direct close. The automated viewer-locality test passed in
  loopback mode. Status stays **partial** until it runs against a second host;
  see the [automated acceptance commands](../../archive/delivery/isolated_example_verification.md#automated-inspector-and-viewer-acceptance).
