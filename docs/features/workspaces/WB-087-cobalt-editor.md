---
id: WB-087
title: Persistent Cobalt editor workspace and open-location action
category: workspaces
feature_sets: [FS3]
status: closed
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

Silver's native terminal links `cobalt.hosted`. Editor is a normal, persisted
Silver workspace with its own tab. Fresh and existing layouts get the default
Editor workspace; the daemon stores its layout, not Cobalt buffers. Embedding
lets Silver compose a sibling pane and translate Cobalt's cursor without a PTY, terminal
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

- Select the **Editor** tab or use `Space c c` → `ed` → **Enter**.
  This opens the project in Cobalt without requiring a file. The normal Silver
  workspace tabs remain available above the editor.
- From a Silver pane, `Space c c` → **Open project file…** →
  `src/file.ml`, `src/file.ml:12`, or `src/file.ml:12:4`. Numeric colon suffixes
  are interpreted as coordinates. A successful open selects the Editor tab and
  focuses Cobalt.
- In Cobalt normal mode, `Space c c` opens Cobalt's command palette with Silver
  commands added alongside Cobalt's own. Type `ov` and press **Enter** to
  switch directly to Overview; no focus change is needed first. This also works
  from Cobalt's initial directory view. **Esc** closes the palette and leaves
  focus in Cobalt. Switching workspaces does not close buffers or discard edits.
  Selecting an unavailable Silver command reports the reason without running it.
- With the Testing catalog focused, select a case and use `gd` or the command
  palette's **Open declaration**. This resolves the catalog's stable selection
  through the shared module hook, then uses the same open action.
- `Alt+Left` (with `F7` as an alias) goes Back to the workspace that opened
  Editor, with its focus and selection intact. If that workspace is unavailable,
  Silver prefers Overview. `F6` or a pane click switches focus between Cobalt
  and the originating Silver tile (for example, Session, Resources, or the
  Testing catalog). Each has its own Silver title and focus styling; the
  companion retains the origin tile's presentation and browse state.
  Use `j`/`k` or Up/Down to browse it. On narrow terminals the companion is
  hidden and `F6` focuses the workspace tabs instead. `Ctrl+O` remains
  Cobalt's jump history, and `gd`,
  `Space l i`, and `Space g g` keep their Cobalt bindings. `Ctrl+C` exits
  Silver and discards unsaved edits.

### Embedded editor layout and theme

Silver reads `silver/editor.sexp` under an absolute, nonempty `XDG_CONFIG_HOME`,
or under `$HOME/.config` if that variable is unset, empty, or relative. For the
usual home directory setup, edit `~/.config/silver/editor.sexp`. Silver creates
the file on first entry to the local Editor, without replacing an existing
file. There is no project-local fallback, and standalone Cobalt's config does
not control this layout or theme.

The shipped layout is the source pane plus **Problems** at the bottom. No
other Cobalt panes are initially visible; commands such as `Space g g` can
still open their views. The file does not affect Silver's surrounding tiles,
tabs, or other workspaces.

```lisp
((schema_version 1)
 (layout ((views ((Problems Band)))))
 (theme inherit))
```

To start with just the source pane, use `(layout ((views ())))`. For example,
to show both Problems and History in the bottom band and give the editor its
own theme:

```lisp
((schema_version 1)
 (layout ((views ((Problems Band) (History Band)))))
 (theme abyss))
```

The layout supports `Problems`, `History`, `Language_servers`, and `Vcs`
as `Band` (below the source), `Tab` (initially inactive), or `Split`
(beside the source); at most one view may use `Split`. To also show Cobalt's
Status pane, add `(status ((position Right) (size 28)))` beside `views`
inside `layout`.

Use `(theme inherit)` to follow the active project's Silver color scheme,
including live palette previews and Escape cancellation. A Cobalt theme ID
such as `abyss` changes just the embedded pane. Neither choice writes Silver's
project presentation preferences.

Restart Silver to read file edits; switching workspaces or projects does not
reread the file. A malformed or unreadable file is left alone and the Editor
shows a notice and uses the shipped defaults. The settings apply to this
Silver user's local editor only; they are not sent to a provider or daemon.

### Build and verify

Use a Cobalt checkout whose `cobalt.hosted` supports file open, workspace LSP,
`Layout`, reactive `appearance`, and hosted palette commands. Build it with the same switch and
Bonsai/Bonsai_term versions as Silver. From the Cobalt checkout:

```sh
opam exec -- dune runtest -j 4 app/test/open_location examples/hosted_editor
opam exec -- dune build -j 4 @install
```

Install the `cobalt` package in that switch, or make its build/install prefix
available to Dune (the example leaves the switch unchanged). From Silver:

```sh
export OCAMLPATH="/absolute/path/to/cobalt/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
opam exec -- dune build -j 4 terminal/main.exe @terminal/test-editor-pty \
  @terminal/test-editor-palette-pty @terminal/test-editor-config-pty
./install.sh --without-asic
```

The Cobalt tests cover standalone startup and its public hosted API. Silver's
editor PTY test covers the tab at 80 columns, entering without a file,
path-only and positioned opens, missing-file errors, both Back bindings,
focus and resizing, Git view, dirty buffers and undo, and project isolation.
The palette PTY checks that Cobalt's native commands remain selectable, the
`ov` alias switches workspaces, and focus and the dirty buffer survive.
The config PTY test covers first-use generation, previews, the editor-only
override, project isolation, and restart/fallback behavior.
See Cobalt's `ui/HOSTED.md` and `examples/hosted_consumer/README.md` for the
component contract and isolated-prefix installation.
