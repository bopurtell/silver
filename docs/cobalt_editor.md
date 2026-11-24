# Cobalt editor integration

Silver embeds Cobalt in the **Editor** workspace for local projects. The
frontend keeps one live editor session per opened local project: switching
workspaces or temporarily selecting another project does not close the buffers
or clear their undo history. The daemon saves the workspace layout, not editor
buffers. An explicitly attached daemon project is not treated as local just
because its absolute root also exists on the client.

## Terminal controls

- Select **Editor** or press **Space c c**, type `ed`, and press **Enter** to
  open Cobalt without choosing a file.
- From a Silver pane, open **Space c c → Open project file…** and enter
  `src/file.ml`, `src/file.ml:12`, or `src/file.ml:12:4`. Line and display-cell
  column are one-based. A line without a column means column 1; a path by itself
  preserves the cursor in an existing buffer. A bad path does not switch tabs.
- With the Testing catalog focused, select a case and press `gd` or choose
  **Open declaration** to go to its registered source location.
- In Cobalt normal mode, **Space c c** offers both Cobalt and Silver commands.
  Type `ov` and press **Enter** to switch directly to Overview. **Esc** closes
  the palette without leaving Cobalt.
- **Alt+Left** or **F7** returns to the workspace that opened Editor, preserving
  its focus and selection. **F6** or a pane click switches between Cobalt and
  the originating Silver tile; on narrow terminals the companion is hidden
  and **F6** focuses the workspace tabs. **Ctrl+O**, `gd`, **Space l i**, and
  **Space g g** retain their Cobalt meanings.
- Embedded Cobalt uses the same [project terminal pool](terminal_controls.md#shared-project-terminal)
  as Silver. Closing the terminal overlay returns to the editor without
  leaving Insert mode.

Cobalt's own quit command uses its normal unsaved-buffer checks. **Ctrl+C**
exits Silver and discards unsaved editor changes.

## Embedded editor layout and theme

Silver reads `silver/editor.sexp` under an absolute, nonempty `XDG_CONFIG_HOME`,
or under `$HOME/.config` if that variable is unset, empty, or relative. Silver
creates the file on first entry to the local Editor without replacing an
existing file. This is a per-user setting; there is no project-local fallback,
and standalone Cobalt's configuration does not control the embedded editor.

The shipped layout shows the source pane and Problems in a bottom band:

```lisp
((schema_version 1)
 (layout ((views ((Problems Band)))))
 (theme inherit))
```

Use `(layout ((views ())))` for the source pane alone. To also show History
and set a theme just for the embedded editor:

```lisp
((schema_version 1)
 (layout ((views ((Problems Band) (History Band)))))
 (theme abyss))
```

The supported views are `Problems`, `History`, `Language_servers`, and `Vcs`.
Place each in a `Band` (below the source), `Tab` (initially inactive), or `Split`
(beside the source); at most one view can use `Split`. To show the Status pane
on the right, add `(status ((position Right) (size 28)))` alongside `views`
inside `layout`.

`(theme inherit)` follows the active project's Silver theme, including palette
previews. An explicit Cobalt theme such as `abyss` affects only the editor.
Neither choice overwrites Silver's presentation preferences or changes its layout.
Restart Silver to reload the file; if it is unreadable or malformed, Silver
leaves it alone, displays a notice, and uses the shipped defaults.

## Use standalone Cobalt with Silver

A separate Cobalt window can connect to an already-running Silver project.
Follow [Share a project with standalone Cobalt](project_workflows.md#share-a-project-with-standalone-cobalt)
in Silver, then choose **Silver: Discover/Connect…** in Cobalt's command palette.
Select the live project offer and press **Enter**. This does not start or
reconfigure a daemon, and stopping sharing does not revoke existing connections
or interrupt jobs.

Alternatively, in a Cobalt build with the Silver adapter, specify the daemon
endpoint and canonical project root directly:

```sh
cobalt --silver-endpoint http://127.0.0.1:30900 \
  --silver-project /absolute/path/to/project
```

See [Cobalt's Silver guide](https://github.com/bopurtell/cobalt/blob/oxcaml/bin/SILVER_OVERVIEW.md)
for test quick launch, stage and flow controls, and watching a retained attempt.

## Build and verify

Use a [Cobalt](https://github.com/bopurtell/cobalt) checkout that provides
`cobalt.hosted` with file open, workspace LSP, `Layout`, reactive appearance,
and hosted palette commands. Build both checkouts with the same OCaml switch
and Bonsai/Bonsai_term versions. From the Cobalt checkout:

```sh
opam exec -- dune runtest -j 4 app/test/open_location examples/hosted_editor
opam exec -- dune build -j 4 @install
```

Install Cobalt in that switch or point Dune at the build prefix. The latter
leaves the switch unchanged. From the Silver checkout:

```sh
export OCAMLPATH="/absolute/path/to/cobalt/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
opam exec -- dune build -j 4 terminal/main.exe @terminal/test-editor-pty \
  @terminal/test-editor-palette-pty @terminal/test-editor-config-pty
./install.sh --without-asic
```

See [Install Silver](install.md) for other installation modes and dependencies.
Cobalt's [hosted API](https://github.com/bopurtell/cobalt/blob/oxcaml/ui/HOSTED.md)
and [hosted consumer example](https://github.com/bopurtell/cobalt/blob/oxcaml/examples/hosted_consumer/README.md)
describe the embedding contract and isolated-prefix builds.
