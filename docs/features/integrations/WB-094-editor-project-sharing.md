---
id: WB-094
title: Share the open Silver project with Cobalt
category: integrations
feature_sets: [FS2, FS4]
status: closed
design_status: designed
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 8
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [cobalt, project-sharing, discovery, testing]
depends_on: []
related: [WB-077, WB-086, WB-093]
---

# WB-094 — Share the open Silver project with Cobalt

## Request

Let a user working in Silver explicitly share the current project so that a
standalone Cobalt can find and connect to it locally. Silver owns the sharing
workflow, advertisement lifecycle, and end-to-end acceptance. Cobalt C7
(`docs/backlog/silver_integration.md` in Cobalt) owns consumer discovery and
connection UX; it does not own Silver jobs or history.

## Current baseline

Silver's standalone mode hosts a service in the terminal invocation, with
persistent project state (or an explicit `--standalone-state-dir`). It keeps
opened projects' embedded services alive when switching projects so their jobs
and in-memory state survive. `--connect` attaches to an existing service; the
service owns the project and history, and the URL can also represent an SSH
forward. See [`terminal/main.ml`](../../../terminal/main.ml) and
[`daemon/server_host.ml`](../../../daemon/server_host.ml). Cobalt's existing
companion can bind to a verified endpoint; sharing must make the current binding
discoverable, not start another service with an empty or different history.

## Scope

- Add **Share with Cobalt…** for the open project via **Manage This Project…**
  and the palette. Follow [WB-086](../workspaces/WB-086-management-surface.md):
  centered floating wizard, keyboard-first controls, and return to the invoking
  inspection on dismissal. Show the project and current sharing status, and
  explain what a local Cobalt can discover and connect to.
- Sharing is off by default. After deliberately opening the wizard for an
  eligible project, **Enter** on the initial screen confirms **Share for this
  session**. **Remember for this project** is an optional, unchecked choice;
  neither opening the wizard nor cancelling an unconfirmed change writes a
  preference or publishes anything. A remembered choice belongs to the local
  user, not project source, and takes effect when that project is opened again
  against an eligible local service. **Stop sharing** withdraws this instance's
  advertisement and clears its remembered opt-in for that project.
- Only advertise a verified same-machine, same-user project connection. Support
  the current embedded service and verified local attached service without
  rebinding either. Reject unbound projects and remote or unverifiable
  attachments with a reason; loopback alone does not prove locality. Do not
  add a remote listener, publish an SSH forward, or copy source, buffers, or
  history into discovery.
- Advertise only the active, opted-in project for this Silver instance. On
  project switch, stop sharing the old project before publishing an eligible
  new one. On exit, withdraw this instance's advertisement; stale advertisements
  after an unclean exit must not be accepted as live. Independent instances
  must not overwrite or withdraw each other's advertisements. Sharing changes
  discoverability, not the backend's lifetime: do not stop a service, cancel
  jobs, alter launch or run selection, or delete history to change sharing.

## Approved v1 design

**Closed and owner-accepted (2026-11-22).** Session-only means the publishing
Silver session: quitting Cobalt must not consume or withdraw the offer. A new
Cobalt process may select it again while Silver is still sharing that project.
The wizard explains that “Stop sharing” stops advertising the project for new
connections; it does not revoke existing connections or interrupt jobs.

The **Silver frontend publishes**; the existing **service executes**; the Cobalt
Silver module discovers and verifies. An offer identifies one publication, not a
checkout. Two windows on the same root get two rows, even if they use the same
backend. Show project name/root, embedded vs attached, and a short distinguishing
offer ID in the picker. Never auto-select a different row after a failure.

- **Publish:** use `editor-shares/v1/` under Silver's per-user runtime directory
  (`native_http/runtime.ml` path rules, independent of the project state dir).
  One bounded versioned S-expression per offer: fresh opaque offer ID, local
  endpoint, daemon instance ID, already-open project ID, canonical root and
  embedded/attached label. Use a private same-owner directory and regular
  mode-0600 records; reject symlinks and unsafe ownership. List only this
  registry. Do not promote C7's multi-row fixture file to a production index.
- **Lifetime:** take an exclusive advisory lock on the fresh record before
  atomically renaming it into view; keep that same descriptor/inode locked for
  the share lifetime. Withdraw by unlinking this offer before releasing the
  lock. A reader requires the published inode still to be present and the
  publisher lock held (nonblocking shared-lock probe). An unlocked leftover
  after a crash is stale even if an attached daemon is still answering. A new
  share gets a new ID. No heartbeat, PID-only liveness, or global registry rewrite.
- **Locality:** embedded Silver can attest the endpoint it started. For
  `--connect`, require the *actual current endpoint and instance* to match the
  trusted same-user local daemon discovery record with its lifetime lock held,
  plus a fresh matching hello. Never spawn or rediscover a substitute. If this
  evidence is absent (including a forwarded or arbitrary loopback URL), disable
  Share with a reason; leave the existing Silver session alone.
- **Connect:** follow C7's existing verification order: re-read the chosen live
  offer, verify v1 hello/instance and required capability, verify exact project
  ID and root via the read-only snapshot, then recheck the same publication
  before swapping the binding. No `open-project`, discovery job or launch here.
  Failed checks leave the previous binding intact. Stop sharing prevents new
  discovery/attachment via that offer; it does not revoke existing clients.
- **Remember:** store only the opt-in keyed by canonical project root in the
  user's settings, never a port, project session ID or offer ID. On reopen or
  switch, recheck eligibility and mint a fresh offer. Stop clears the preference
  for future opens and withdraws only the invoking frontend's offer.

First vertical slice: start embedded Silver with a nondefault state directory,
seed a retained attempt, share, and connect from unflagged Cobalt. Assert the
same instance, project and attempt in both windows. Then exercise attached
mode, competing offers and withdrawal/crash with the gates below. WB-095 can
use an explicit connection throughout; this registry adds no flow-launch API.

## Acceptance criteria

- [x] Automate the wizard in a terminal: fresh project starts off; open and
  cancel without publishing; reopen and press Enter to share without persisting;
  dismiss back to the same workspace, tile, and row. Reopen Silver to check the
  default reset; explicitly remember, reopen to check opt-in, then stop sharing
  and reopen to confirm it stays off. Verify unbound and SSH-forwarded or
  otherwise unverifiable connections cannot publish.
- [x] In the automated Silver+Cobalt E2E, seed a real retained attempt and start
  a job through Silver. Share and discover the project in standalone Cobalt,
  verify the connection against the advertised service, and assert the same
  backend/project identity and retained attempt identity and result that Silver
  sees. Launch a test from the connected Cobalt and verify its acknowledged
  attempt appears alongside the historical attempt in Silver. Exercise both
  embedded and local attached modes, including a nondefault
  state directory for the embedded case. Turning sharing off or switching
  projects while a job is active must leave that job running to completion with
  the same identity and history; no replacement service or job may be started.
- [x] Run two Silver instances with overlapping sharing lifetimes. Verify
  discovery distinguishes live destinations, including two instances offering
  the same project; the selected destination must resolve to the expected
  backend/project. Stop sharing, switch projects, and exit in one instance;
  verify withdrawal without affecting the other's offer. Include an unclean
  exit or stale offer and verify Cobalt reports it unavailable rather than
  silently selecting another destination. Verify exit or withdrawal from an
  attached Silver client does not stop the attached service or its jobs.
- [x] Provide a reproducible fake contract for C7 covering no offers, verified
  offers, multiple offers, withdrawal/staleness, and failed or mismatched
  verification. Use it in automated consumer tests. Record the fixture,
  commands, and real E2E results here; fake-peer success alone is not acceptance.

## Asynchronous handoff

**Publisher verification:** `native_http/editor_share.mli` exposes validation,
publish/withdraw and local preference operations. `dune build
@native_http/test/runtest` passed for the producer, including concurrent offers,
crash staleness and rejection of unverifiable attached endpoints. A forced
unlink-permission failure also verified the leftover inode loses its publisher
lock while the frontend is still running, so it cannot remain a live offer. Those checks
cover publication; the live editor/history gates above are separate.

Use the approved publication, lifetime and verification rules above for both
the Silver publisher and the C7 reader. Record matching fixtures when wiring
the producer and consumer. Silver can test wizard and lifecycle behavior
independently; the real two-app history check remains WB-094's acceptance gate.

## Reproduction

From Silver, `dune build @terminal/test-project-sharing-pty` verifies the
wizard through the project-management and palette routes, including focus
restoration, session-only sharing, remembering and stopping, refusals, and
withdrawal on switch, exit and crash. The PTYs use isolated runtime and
preferences directories.

The Cobalt fixture and production-format test publisher are documented in
`cobalt/silver_overview/README.md`.
Cobalt's `silver_overview/test/test_connection.ml` tests the bounded registry
and injects a fake peer. From Cobalt, the standalone PTY test can also be run
as `python3 bin/test_silver_share_cli.py _build/default/bin/cobalt.exe`.

From Silver, after building both apps, run the real publisher/consumer check:

```sh
python3 scripts/test-editor-project-sharing.py \
  --silver _build/default/terminal/main.exe \
  --daemon _build/default/daemon/main.exe \
  --cobalt ../../cobalt/_build/default/bin/cobalt.exe
```

The check creates its own runtime/config/state directories, starts no external
EDA tools, and touches no existing session. Omit `--mode` to run both embedded
and attached checks.

**Results (2026-11-22):** The Cobalt reader tests and both fake-peer PTY
sources (fixture and locked production format) passed. The command above
passed against the real Silver terminal and daemon, with `TMPDIR=/dev/shm`
to avoid the machine's `/tmp` quota. Embedded recovered the exact retained
attempt and `Passed` outcome after a restart with a nondefault state path.
Attached verified the existing daemon and project. In both modes the Cobalt
acknowledgement's exact attempt/job appeared in Silver beside the retained
attempt. A crashed duplicate's stale row failed without falling through to the
live offer. Project switching (embedded) and stop/exit (attached) preserved
the independent offer, the running Silver job, and the queued Cobalt job;
both original jobs completed with their expected outcomes and no extra jobs.
Cobalt refreshed the completed result through the existing verified project
connection after all offers were gone.
