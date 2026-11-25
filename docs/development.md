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

## Manual native CI on GitHub Actions

Once `.github/workflows/ci.yml` is on the default branch, open **Actions**,
select **Silver native CI**, choose **Run workflow**, and select the branch
to test. The runner reuses the pinned OxCaml switch and native dependencies
when there is an exact cache hit; otherwise it provisions them from scratch.
Each run builds the Silver packages from the selected revision and runs both
`@test-local` and `@test-api`. Silver's `_build` directory is not cached.

Leave **Benchmark a cold provisioning** unchecked for both runs. Checking it
skips both restore and save; use that only for a separate cold benchmark.
To measure the benefit, dispatch once to populate the cache, then dispatch
again on the same branch after a Silver-only source change. (Running twice
at the same revision also tests reuse.) Check the first log for a cache miss
and successful save, and the second for an exact hit and no provisioning.
Compare **total job time**, including cache transfer, as well as the individual
build and test times. For reference, the [first uncached run](https://github.com/bopurtell/silver/actions/runs/45603339552)
took 73m 28s, of which 48m 29s was provisioning.

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
