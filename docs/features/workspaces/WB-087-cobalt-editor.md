---
id: WB-087
title: Persistent Cobalt editor workspace and open-location action
category: workspaces
feature_sets: [FS3]
status: delivered
kind: feature
priority: P2
severity: n/a
requested_size: Large Feature
size: L
points: 21
confidence: low
estimate_scope: incremental
origin: owner-intake
tags: [cobalt, editor, navigation]
depends_on: []
related: [WB-029, WB-088, WB-090]
---

# WB-087 — Persistent Cobalt editor workspace

**Cross-repo ownership:** WB-087 owns the Silver workspace and any Cobalt changes
to expose the editor lifecycle, focus, and open-location entry point. Verify
standalone startup in Cobalt as well as the hosted editing loop in Silver.

Silver owns the layout and workspace focus; Cobalt owns its buffers, modes,
navigation and Git UI. Compare a hosted component with a supervised local child
on focus, resizing and session lifetime; record the smallest viable boundary.
Expose a host action taking project identity, relative path and optional line
and column. Define coordinate units at the boundary.

## Acceptance
- Invoke the action from Silver with just a path and with a line/column.
  Both focus the Editor workspace; a missing file reports why it cannot open.
- Edit without saving, switch workspaces and open the same file again. The same
  buffer and undo history survive. A different project cannot reuse that buffer by accident.
- Resize with a small Silver testing or overview tile beside Cobalt. Give focus
  to either surface and back; Cobalt editing, LSP bindings and its Git view
  remain reachable without Silver consuming their keys.

## Cobalt handoff

Silver's native terminal links `cobalt.hosted`. The Editor is a client-local
workspace, not a daemon tile and not a second terminal. Embedding lets Silver
compose a sibling pane and translate Cobalt's cursor without a PTY, terminal
emulator, child-process protocol, or independent terminal size. A supervised
child would isolate faults and allow a different toolchain, but would need
that extra boundary, plus an IPC path into its *existing* editor session to
preserve dirty buffers and undo history. The hosted API is the smaller boundary
for this release.

The frontend mounts one live Cobalt session per opened local project on demand.
Hiding the Editor, switching to the side pane, and temporarily selecting another
project do not unmount it. Silver owns project admission, pane allocation,
terminal I/O, input focus, and Back; Cobalt owns editor state, LSP, and Git.
Editor quit uses Cobalt's normal dirty checks; quitting Silver shuts down retained
editors and discards unsaved changes. Explicitly connected daemon projects are
not treated as local merely because their absolute root is a valid local path.
The request uses the active project's identity and a relative file. Line and
display-cell column are **one-based**; line-only means column 1, and file-only
preserves an existing buffer's cursor. Bad requests don't switch workspaces.
Terminal actions submit `Workspace_host.Editor_open` with a
`Module_jump.Location.t`; `Editor_workspace` validates the project binding and
adapts that location to `Cobalt_hosted.Open_location.request`.
An opaque retained-source identity cannot be verified against the working copy
and is rejected rather than silently dropped. Cobalt's ordinary local-file
semantics follow symlinks.

### Terminal controls

- From the Silver dashboard, `Space c c` → **Open project file…** →
  `src/file.ml`, `src/file.ml:12`, or `src/file.ml:12:4`. Numeric colon suffixes
  are interpreted as coordinates. **Switch to Editor** returns to the current
  editor surface without reopening a file.
- With the Testing catalog focused, select a case and use `gd` or the command
  palette's **Open declaration**. This resolves the catalog's stable selection
  through the shared module hook, then uses the same open action.
- `F7` goes Back to the Silver dashboard without changing its workspace, focus
  or selected case. `F6` (or a pane click) switches focus between Cobalt and the
  Silver side pane when available. The side pane shows the dashboard's focused
  tile and supports `j`/`k` or Up/Down without editing Cobalt. It is hidden on
  narrow terminals. Other editor keys, including `gd`, `Space l i`, and
  `Space g g`, belong to Cobalt. `Ctrl+C` exits Silver and discards unsaved edits.

### Build and verify

Use a Cobalt checkout that exports `cobalt.hosted`, built using the same switch
and Bonsai/Bonsai_term versions as Silver. From the Cobalt checkout:

```sh
opam exec -- dune runtest -j 4 app/test/open_location examples/hosted_editor
opam exec -- dune build -j 4 @install
```

Install the `cobalt` package in that switch, or make its build/install prefix
available to Dune (the example leaves the switch unchanged). From Silver:

```sh
export OCAMLPATH="/absolute/path/to/cobalt/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
opam exec -- dune build -j 4 terminal/main.exe @terminal/test-editor-pty
./install.sh --without-asic
```

The Cobalt tests cover standalone startup and its public hosted API. The
Silver PTY test covers path-only and positioned opens, missing-file errors,
focus and resizing, Git view, dirty buffers and undo across Back, and project isolation.
See Cobalt's `ui/HOSTED.md` and `examples/hosted_consumer/README.md` for the
component contract and isolated-prefix installation.
