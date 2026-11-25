# Bluespec Classic counter

This is a standalone Bazel workspace with an editable 8-bit counter in
[Bluespec Classic](Counter.bs). BSC compiles it to Verilog, Verilator runs that
RTL, and [the Rust checker](checker.rs) checks the actual output after each
rising edge. Directed tests cover reset, hold, clear priority, increment and
wraparound. A seeded sequence adds timing and input combinations.

## Build and run

Run these commands from the starter workspace. When working in the Silver
source repo, copy the starter outside the repo first so Bazel's output links
don't interfere with Dune. On Linux, put `bazel`, `bsc`, `verilator`, `rustc`,
`make`, `g++`, and `python3` on `PATH`. The build uses local compilers and no
Cargo dependencies.

```sh
bazel build //:rtl                          # bazel-bin/mkCounter.v
bazel test //:simulation --test_output=all  # default seed; produces counter.vcd
bazel run //:bench -- "$PWD/counter.vcd" 42
```

The test waveform is under `bazel-testlogs/simulation/test.outputs/` (or in
`outputs.zip` there if Bazel is configured to zip undeclared test outputs).
Verilator resolves primitives such as `FIFO2` from the BSC installation's
`Verilog/` directory. The build asks the `bsc` on `PATH` where its library is;
to override it for both BSC and Verilator, export `BLUESPECDIR` pointing to
the absolute path of the BSC `lib` directory (the parent of `Libraries/` and
`Verilog/`). Run `bazel clean` if you change installed tool or library files
in place, since Bazel does not track their contents.

## Simulator interface

From this workspace, invoke `bazel run //:bench -- ABS_VCD_PATH [SEED]`. The
VCD path must be absolute and its parent must already exist. The bench replaces
an existing file. The optional seed is an unsigned decimal 64-bit integer,
default `1`. A completed run exits `0` and writes exactly one outcome line to
stdout: `RESULT Passed` or `RESULT Failed`. A mismatch also prints the seed,
cycle, inputs, and expected/actual count and leaves a VCD through the failing
cycle. Use `bazel test //:simulation` when a mismatch should fail the command.
The bench exits `2` on invalid arguments or an unusable waveform path. Bazel
can also fail before the bench starts if, for example, Bluespec compilation
fails.

## Add packages or change the top

- Put sibling `.bs` or `.bsv` package files beside `Counter.bs` and import
  them by package name (`import MyPackage` in Classic). Match the package
  name to the filename (`MyPackage.bs`). Bazel declares these files as inputs
  automatically; BSC follows the imports and Verilator can also load
  separately synthesized modules that BSC emits. To build and inspect the
  full BSC-generated file set, run
  `bazel build //:rtl --output_groups=+generated_modules`; it is in
  `bazel-bin/rtl_modules/`.
- For a new top, set `TOP_SOURCE` to its source file and `TOP` to its
  synthesized module name in `BUILD.bazel`. `bazel build //:rtl` writes the
  new `<TOP>.v`. Update the generated header (`V<TOP>.h`), model type, and
  pin mapping in `bench.cpp`; update `checker.rs` for the new behavior.
  The `//:rtl`, `//:bench`, and `//:simulation` labels stay the same.

To see the checker catch a real hardware bug, copy the workspace and change
`value + 1` to `value + 2` in its `Counter.bs`. Then `bazel test //:simulation`
should fail at cycle 2 with `expected 1, got 2`.

## Wire in an IP library

An IP library in `ip/<name>/` has its own Bazel package. Its `BUILD.bazel`
exports its authored sources with a filegroup visible to the top's package:

```python
filegroup(
    name = "sources",
    srcs = glob(["*.bs"], allow_empty = False),
    visibility = ["//:__pkg__"],
)
```

For example, add `"//ip/sample_ip:sources"` to `IP_SOURCES` in the root
`BUILD.bazel`, then use `import Sample_ip` in the `.bs` file that uses
Silver's generated `Sample_ip.bs`. The Bazel directory name and the Classic
`package` name are separate. Match each filename to its package name exactly
and give each package a distinct name across the design. Files added under
the same IP owner are picked up by its filegroup; dependencies in other Bazel
packages must also be declared, either in `IP_SOURCES` or through a filegroup
that exports them and has the appropriate visibility.

The rule stages only the declared source files for BSC, plus access to
BSC's installed libraries. A Bazel glob does not cross a package boundary.
Run `bazel build //:rtl` and `bazel test //:simulation` after wiring in the
IP; an import alone doesn't instantiate any hardware.

From the Silver repository root, run `python3 test/integration/bluespec_ip.py`
for an opt-in regression. It uses a disposable copy, checks that an undeclared
IP is rejected, then imports and simulates the separately synthesized child.
Mutating only the IP helper must regenerate the child Verilog and fail the
unchanged checker. Pass `--author /path/to/silver-author` to use the actual
Classic authoring commands instead of a fixture with the same package layout.
