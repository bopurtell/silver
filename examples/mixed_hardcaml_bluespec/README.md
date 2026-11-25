# Hardcaml top with Classic Bluespec IP

Yes: instantiate the Bluespec IP as an external RTL module. In this example
Hardcaml emits `mixed_top.v`, with an `Instantiation.create` for `mkCounterIp`.
BSC compiles `CounterIp.bs` into `mkCounterIp.v`; Dune gives both files to
Verilator. The Hardcaml top reads the child count and also samples it in its own
register. The bench checks both outputs on every rising edge, including the
sample's one-cycle latency and the child's reset, hold, clear, and wraparound.

## Copy and run

From the Silver repository root, copy the standalone example **outside** the
repository. Use an OCaml switch with `hardcaml` and `dune` available, and put
`bsc`, `verilator`, `make`, `g++`, and `python3` on `PATH`.

```sh
project=$(mktemp -d)
cp -R examples/mixed_hardcaml_bluespec/. "$project/"
cd "$project"
# If needed: eval "$(opam env --switch=5.2.0+ox)"
dune build @rtl     # _build/default/mixed_top.v and mkCounterIp.v
dune runtest        # PASS: mixed top checked 264 cycles
```

Open `_build/default/mixed.vcd` in a waveform viewer to inspect `ip_count` and
`sampled_count`. To check the workflow in a fresh copy, including a mutation
that must fail simulation, run `python3 test/integration/mixed_hardcaml_bluespec.py`
from the repository root.

If Silver is installed, run `ag` in the copied project. Its
`.silver/silver.sexp` maps **Build** to Dune's `@rtl` and
**Test** to `@runtest`. No wizard or simulation provider is needed; the VCD is
a local Dune output, not a retained artifact in Silver's Testing workspace.

When adapting the example, match the BSC-generated module name, port names,
widths, and reset polarity in `emit_top.ml`. In particular, `EN_step` enables
the Classic action method; the `alwaysReady` contract means it has no
`RDY_step` port. This example uses Verilator because a Hardcaml
`Instantiation.create` supplies only a reference to the external RTL, not a
Cyclesim model. It does not set up an ASIC flow.
