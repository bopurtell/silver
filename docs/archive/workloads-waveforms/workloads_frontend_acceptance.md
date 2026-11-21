# Workloads frontend implementation and acceptance

Historical frontend evidence. See [Workloads workspace controls](../../workloads_workspace.md) for current use.

## Initial checks

All Dune commands use the shared lock, isolated build, switch5.2.0+ox and six jobs:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune build -j6 --build-dir _build_pt8_workbench terminal/main.exe daemon/main.exe
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune runtest -j6 --build-dir _build_pt8_workbench terminal
python3 -B terminal/test_workloads_native.py
```

Initial native HTTP/PTY eight-check pass:
`/tmp/opencode/pt8-workloads-ui-br1u5gx5/ui-receipt.json`. It exercises large exact
tokens, explicit pair and axis/swap provider calls, cache-only filtering/reopen,
held old-source response rejection, refresh failure and private-daemon restart.
Earlier failed runs remain under the same temp prefix: one fixture initially put
evidence above the cache root; another exposed ambiguous capture labels; another
incorrectly equated inspect/comparator companion identities. The fixture/labels/UI
identity presentation were corrected before the passing run.

Nine new view tests cover numeric/rational preservation, source/reconnect receipt
fences, ordered pair/axis identities, strict reference schema, pure narrow/wide
rendering, same-key receipt floors, production host input/render/tile lifetimes,
navigation/session restoration and stale capture forms. Additional tests cover
selected-case artifact handoff and custom Workloads-name/layout coexistence. Existing
terminal suites, fresh-process navigation and presentation tests pass. Additive
`workloads=None` defaults were required in existing terminal snapshot test fixtures.

Independent review and actual fresh-provider acceptance remain coordinator/C gates;
this is A's initial frontend pass, not a claim of their completion.

## F1–F4 corrections and revised native handoff

The independent findings in `docs/archive/workloads-waveforms/workloads_frontend_review.md` are corrected in the
production frontend. Added regressions cover actual backend-prefixed artifact
capture/read and both cases with cross-attempt/case negatives; exact inspection
reopening/cache collisions; highlighted-versus-loaded capture; verified bundle
auto-capture/legacy fallback; distinct target/workload generation domains including
Refresh, Swap, axis changes and restoration; and metric-first narrow presentation.

The full terminal suite and terminal lint/build pass. Updated synthetic native
HTTP/PTY eight-check receipt (including automatic capture without path forms):
`/tmp/opencode/pt8-workloads-ui-594ghnry/ui-receipt.json`.
Matching binaries are `_build_pt8_workbench/default/terminal/main.exe` and
`_build_pt8_workbench/default/daemon/main.exe`, ready for C's actual fresh-run rerun.

The unmodified independent suite was run. It now passes F4 and the F2 pinned-query
assertion, then its line111 fixture calls the production backend validator with
the emitted pinned-A query and a C-digest document. The validator correctly raises
`Captured workload/target digest changed` before the UI assertion. The original
reviewer file is unchanged. A second fixture calls `select_case "exact256"` on an
attempt listing only Flops; that selection is rejected and retains Flops, so it
cannot construct the intended different-case negative after F1 is fixed.

The maintained regression is `terminal/test/workload_handoff/`. It admits the
conflicting cached document under an unpinned query and constructs an attempt
that actually includes both cases. These fixtures exercise cache collision and
the production backend capture/read without weakening selection or validation.
Run it with `dune runtest terminal/test/workload_handoff`.

Final A binary identities for C's rerun:

| Isolated build path | SHA256 |
| --- | --- |
| `_build_pt8_workbench/default/terminal/main.exe` | `43740a9dcdd1a23f39ab2d4837f1cb570251c4a4910c862906dd001c462d2c46` |
| `_build_pt8_workbench/default/daemon/main.exe` | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |
| `_build_pt8_workbench/default/terminal/workspaces/export_presets.exe` | `1ec964a22a60121fc091f78dad5ccdb2c64ae42c1e9244a5fc505781fb350ad4` |
