# Contributing to Silver

Start with the [source installation prerequisites](install.md#build-from-source), the
[test suite selectors](../test/README.md), and the [test ownership guide](testing.md).
Tests of Silver are separate from the verification suites of hardware projects
that Silver opens. Use an [opt-in acceptance runner](real_prefix_pyramid.md)
only when you intend to use real ASIC tooling.

## Build and check

The checkout's `scripts/with-switch.sh` wrapper selects the existing
`5.2.0+ox` switch by default. Set `OPAM_SWITCH` to choose another installed
switch. The wrapper doesn't provision dependencies. Preview test dependency
installation with `./scripts/with-switch.sh opam install . --deps-only --with-test --show-actions`
and review the result before installing. Formatting and lint checks also use
`ocamlformat` and `ppx_js_style`. The opam metadata is generated from `dune-project`.

From the Silver checkout, run these serially against the same Dune build
directory; adjust the job limit to the available budget, including subprocesses:

```sh
./scripts/with-switch.sh dune build -j4 @fmt
./scripts/with-switch.sh dune build -j4 @lint
./scripts/with-switch.sh dune runtest -j4
./scripts/with-switch.sh dune build -j4
```

Additional checks for the relevant boundaries:

```sh
FIXTURE_OPAM_SWITCH=5.2.0+ox ./scripts/test-fixture.sh
./scripts/test-native-application.sh
./scripts/capture-terminal-baseline.sh --check
./scripts/with-switch.sh dune build -j4 @test-native-standalone
```

The fixture uses an explicitly selected compatible switch, and the native
application script exercises an isolated install. See
[terminal baselines](../test/baselines/terminal/README.md) before updating captures.

## Native CI on GitHub Actions

**Silver native CI** runs on pull requests and pushes to `oxcaml`. Updating
a PR cancels its superseded run. You can also start a run from **Actions →
Silver native CI → Run workflow** and select a branch.
The runner reuses the pinned OxCaml switch and native dependencies
when there is an exact cache hit; otherwise it provisions them from scratch.
Each run builds the Silver packages from the selected revision and runs both
`@test-local` and `@test-api`. Silver's `_build` directory is not cached.

Pull requests can restore an eligible cache. Only runs on the `oxcaml` branch
save a new cache. For manual cache comparisons, leave **Benchmark a cold
provisioning** unchecked for both runs; checking it skips both restore and save.
To measure the benefit, dispatch on `oxcaml` after a cache-key change, then dispatch
again on the same branch after a Silver-only source change. (Running twice
at the same revision also tests reuse.) Check the first log for a cache miss
and successful save, and the second for an exact hit and no provisioning.
Compare **total job time**, including cache transfer, as well as the individual
build and test times. On the same revision, a [cold run](https://github.com/bopurtell/silver/actions/runs/45691162363)
took 53m 44s and a [warm run](https://github.com/bopurtell/silver/actions/runs/45707984213)
took 22m 26s.

## Inline expect-test prerequisite

When adding an inline expect-test library below the Dune project root, preserve
the existing stanza convention:

```lisp
(inline_tests (flags (-source-tree-root .)))
```

In the affected `ppx_expect` preview build, the corrected-file writer combines
`source_tree_root` with the test filename's basename, dropping the subdirectory.
Without the override, the runner can raise `Sys_error` for a missing
`./../test_protocol.ml` before it reports any result. The `.` override uses the
runner's library working directory, so both expect diffs and `dune promote`
resolve the intended file.
