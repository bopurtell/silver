---
id: WB-085
title: Frontend-independent authoring calls
category: project
feature_sets: [FS3]
status: closed
kind: feature
priority: P1
severity: n/a
requested_size: Unspecified
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [daemon, authoring, protocol]
depends_on: []
related: [WB-051, WB-079, WB-082, WB-083]
---

# WB-085 — Frontend-independent authoring calls

## Request
Make previewing and applying a source change operations on the service host. A menu, palette command or management workspace should not have to know how to write a Dune file.

## Baseline before this ticket
Silver can host its service locally or connect to a daemon. Source recipes belong to providers; the existing ASIC path addresses a project that already exists.

## Scope
Define the Silver request/response boundary for authoring: identify destination and optional existing project/object, preview new files and proposed registration edits, then submit an explicit operation and report its outcome. The daemon invokes the underlying headless operation on its host. Exercise the boundary with a controlled recipe before requiring any particular starter.

## Out of scope
Designing provider template contents or owning their rollback semantics (WB-051), GUI forms, and a generic remote filesystem editor.

## Acceptance criteria
- [x] A terminal-independent client can preview and apply the same operation against a standalone service or connected daemon. Paths refer to the service host, including when no Dune project exists yet.
- [x] Preview and cancel are read-only. If a path becomes occupied after preview, applying does not replace it. Return enough information to distinguish created files, skipped registration and a failed operation.
- [x] A client can render the intended target and outcome without parsing terminal text or constructing Dune/OCaml source.
- [x] Requests contain project/object identity, not an Overview tile or window ID. The same request from the palette, a separate management window or a Project workspace addresses the same destination.

## Implementation and verification
`/api/v1/authoring` accepts the [typed request](../../../protocol/authoring.ml) before project open. The standalone host permits its launch directory; a connected daemon permits only directories explicitly configured with repeatable `--authoring-root DIR`. Opening a project does not grant write access. The `controlled-v1` fixture exercises the service; it is not an ASIC project generator.

Preview IDs are single-use, including on failed apply. The service retains the most recent 128 outstanding previews. Run `dune runtest -j 2 backend/test/authoring daemon/test protocol/test` for backend, transport and host-mode checks.

## Dependencies
None for the service contract. [WB-051](WB-051-new-project-creation.md) and [WB-078](WB-078-project-entry.md) now use it for project creation and first-starter adoption. Other authoring tickets own their operation-specific adapters.

## Estimate rationale
13 points for the protocol, unbound-destination path and local/connected service tests; excludes recipes and UI.

## Agreed behavior
- Destinations refer to the service host, even before a Dune project is open. New-project creation supports a new or existing empty directory and refuses a nonempty one. Adding a starter to an existing Dune project is a separate operation.
- Preview describes the destination, files and any proposed registration change. Apply refers to that preview by ID. A conflicting change after preview requires a fresh preview, not an overwrite. Cancel writes no source.
- Report stale preview separately from provider failure. Identify created files and the registration outcome so a client knows what happened before offering a retry.
- Exercise this boundary with a controlled recipe first. The provider that supplies the first production starter and its contents are WB-051 decisions.

## References
[Product boundary](../../project_authoring_and_command_design.md#product-boundary-from-an-empty-directory-to-a-run).
