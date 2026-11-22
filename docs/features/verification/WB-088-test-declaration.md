---
id: WB-088
title: Jump from a catalog test to its OCaml declaration
category: verification
feature_sets: [FS2, FS3]
status: closed
kind: feature
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 8
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [testing, cobalt, navigation]
depends_on: [WB-087, WB-092]
related: [WB-032, WB-063, WB-066]
---

# WB-088 — Open the selected test declaration

Carry an optional declaration position on a stable test catalog entry. Have one
real provider capture it at the OCaml call site (for example with `[%here]`),
not inside a shared registration helper. The Testing module offers “Declaration”
through [WB-092](../infrastructure/WB-092-module-jump-hook.md) for a captured
catalog entry. WB-087 consumes the resulting location for the live embedded demo.

## Acceptance
- Before integrating the editor, resolve a real entry through the shared hook
  and assert the project, file and position at a recording destination.
- With no run or failure required, select the test and invoke “Open declaration”
  (`gd` proposed). Cobalt focuses the correct project file and declaration.
- Edit, go Back to the same Testing selection, and repeat the jump. Unsaved
  edits survive. The same chord inside Cobalt retains editor semantics.
- An older provider or a test with no position still lists and runs normally;
  the jump is unavailable with a reason, not a search by display name.

## Headless acceptance

From the Silver checkout, with the adjacent `hardcaml_asic_example` checkout:

```sh
build=/tmp/opencode/wb088-build
fifo_build=/tmp/opencode/wb088-fifo-build
fifo=ip/controlled_fifo/verif/simulation
scripts/with-switch.sh dune build --build-dir "$build" -j 5 \
  hardcaml_workbench_provider.install daemon/test/testing_declaration_acceptance.exe
OCAMLPATH="$build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}" \
  scripts/with-switch.sh dune build --root ../hardcaml_asic_example \
  --build-dir "$fifo_build" -j 4 "$fifo/test_provider.exe"
scripts/with-switch.sh "$build/default/daemon/test/testing_declaration_acceptance.exe" \
  --example-root ../hardcaml_asic_example \
  --provider "$fifo_build/default/$fifo/test_provider.exe"
```

The probe runs real FIFO discovery through native HTTP in a private project
containing a copy of the actual registration source. It records all three resolved
jumps, independently checks the project, file, line and display-cell column against
the source, and verifies no simulation was launched. No editor is required.

## Terminal acceptance

With `fifo_build` and `fifo` as above and the current Silver client built:

```sh
scripts/with-switch.sh python3 scripts/test-testing-declaration.py \
  --client _build_workbench/default/terminal/main.exe \
  --provider "$fifo_build/default/$fifo/test_provider.exe"
```

The PTY test selects a real FIFO case and jumps with `gd`. Inside the editor,
it checks the cursor coordinate through Cobalt's LSP client and verifies that
`gd` has editor semantics. F6 transfers pane focus; Alt+Left returns to the same
Testing selection (F7 remains an alias). Reopening the declaration preserves the unsaved edit and
undo/redo history, without writing the source file or launching a simulation.

To check the standard configured `hardcaml_asic_example` checkout with the
installed `~/.local/bin/silver`, run this from Silver:

```sh
scripts/with-switch.sh python3 scripts/test-testing-declaration.py --live
```

This uses the checkout's composite provider, checks that the memory and FIFO
suites both appear, and jumps to the FIFO `seeded` registration twice. It
uses fresh Silver state but opens the actual source file without editing it.
