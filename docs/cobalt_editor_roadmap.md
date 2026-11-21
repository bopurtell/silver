# Cobalt in Silver: recommended delivery order

Target the terminal frontend first. A project has one live editor session across
workspace switches; one numbered terminal pool belongs to the Silver frontend.
These are proposed lifetimes. Today each `cobalt` invocation runs its own editor:
`bin/cli/cobalt_cli.ml` calls `Cobalt_ui.Editor_view.run` directly. There is no
Cobalt session daemon for Silver to attach to.

**Ownership:** Each Silver WB ticket is the single tracking and acceptance record
for its slice, including any Cobalt source, packaging, or test changes it needs.
Reference the same WB ID from changes in both repos and link their verification
on the Silver ticket; no matching Cobalt ticket is required.

For asynchronous implementation, the **Cobalt repo** has a module-level work
queue at `docs/backlog/silver_integration.md`. C1/C2 hand off the editor and
generic open action; C3 hands off ToggleTerm. C4 addresses a separately running
main editor; C5/C6 cover a standalone Cobalt overview and test-launch command.
The latter tracks can proceed independently of the embedded editor demo. The
Cobalt harnesses prove module readiness; the live two-app demos remain Silver
acceptance work.

| Order | Ticket | What to try before moving on |
| --- | --- | --- |
| 1 | [WB-087 — Persistent editor and generic file open](features/workspaces/WB-087-cobalt-editor.md) | Open a project file at a line, edit it, leave, and come back to the same buffer. |
| 2 | [WB-088 — Test declaration jump](features/verification/WB-088-test-declaration.md) | **First demo:** select a real test, jump to its OCaml declaration, then go back to the same catalog row. |
| 3 | [WB-089 — Silver-wide ToggleTerm](features/integrations/WB-089-shared-toggleterm.md) | Start a shell from Testing; reopen that same numbered shell from Timing. |
| 4 | [WB-090 — Delegate embedded Cobalt toggles](features/integrations/WB-090-cobalt-terminal-handoff.md) | **Second demo:** invoke that shell while typing in Cobalt, hide it, and keep typing. |
| 5 | [WB-091 — Trace one timing path](features/evidence/WB-091-timing-origin-trace.md) | Identify the last provable source location for each endpoint of a real path. |
| 6 | [WB-021 — Evidence-backed source navigation](features/evidence/WB-021-source-navigation.md) | Use the trace to implement and exercise the first evidence-backed Timing → Editor handoff. |

This order gets a useful editing loop in hand before taking on terminal input or
synthesis provenance. WB-089 and WB-091 can be investigated independently.
Only revisit daemon-owned sessions if reconnect/reattach or remote shell execution
becomes a requirement; neither demo needs those semantics.
