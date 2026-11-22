# Cobalt in Silver: recommended delivery order

Target the terminal frontend first. A project has one live editor session across
workspace switches. The Editor should be a default Silver workspace: opening a
declaration selects its tab, while Back (`Alt+Left`, with `F7` as an alias)
returns to the workspace and selection that issued the jump. `Ctrl+O` remains
Cobalt's own jump-history command. One numbered terminal pool belongs to the Silver frontend.
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
main editor; C5 covers standalone monitoring. [WB-093](features/integrations/WB-093-cobalt-quick-launch.md)
and C6 are closed for test quick launch, including the live tile/`test` alias demo.

| Companion follow-up | Cobalt can start independently | Silver handoff for live acceptance |
| --- | --- | --- |
| [WB-094 — Project sharing](features/integrations/WB-094-editor-project-sharing.md) | C7: connection picker using fixture advertisements | Publish and withdraw real shares for the current project service and verify both clients see the same history. |
| [WB-095 — Stage and flow launch](features/integrations/WB-095-companion-flow-launch.md) | C8: checklist and exact aliases; C9: flow kickoff tile. Exercise both against a fake launch service. | Supply examples of native flow resolution and submission; compare live launches. Use an explicit connection independently of WB-094. |

| Order | Ticket | What to try before moving on |
| --- | --- | --- |
| 1 (parallel) | [WB-092 — Shared module jump hook](features/infrastructure/WB-092-module-jump-hook.md) | Offer and resolve a jump headlessly, independent of Testing and editor choice. |
| 1 | [WB-087 — Persistent editor and generic file open](features/workspaces/WB-087-cobalt-editor.md) | Open a project file at a line, edit it, leave, and come back to the same buffer. |
| 2 | [WB-088 — Test declaration jump](features/verification/WB-088-test-declaration.md) | **First demo:** select a real test, jump to its OCaml declaration, then go back to the same catalog row. |
| 3 | [WB-089 — Silver-wide ToggleTerm](features/integrations/WB-089-shared-toggleterm.md) | Start a shell from Testing; reopen that same numbered shell from Timing. |
| 4 | [WB-090 — Delegate embedded Cobalt toggles](features/integrations/WB-090-cobalt-terminal-handoff.md) | **Second demo:** invoke that shell while typing in Cobalt, hide it, and keep typing. |
| 5 | [WB-091 — Trace one timing path](features/evidence/WB-091-timing-origin-trace.md) | Identify the last provable source location for each endpoint of a real path. |
| 6 | [WB-021 — Evidence-backed source navigation](features/evidence/WB-021-source-navigation.md) | Use the trace to implement and exercise the first evidence-backed Timing → Editor handoff. |

This order gets a useful editing loop in hand before taking on terminal input or
synthesis provenance. Silver-wide ToggleTerm (WB-089) and embedded terminal
handoff (WB-090) are closed. Retained-path research (WB-091) and navigation
(WB-021) remain proposed.
WB-091's findings will guide WB-021's mapping format and artifact handoff.
Only revisit daemon-owned sessions if reconnect/reattach or remote shell execution
becomes a requirement; neither demo needs those semantics.
