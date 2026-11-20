# Choose the ASIC launch target

Open the command palette (`Space c c`) and run **Discover ASIC flows and runs**.
For a project with a chip catalog, search **Select launch target**, or type a
chip or variant name. Each row selects one exact chip/variant pair. Selection
loads its flows; it does not build anything or switch the run you are inspecting.

In Overview, **Planned Run** shows the launch chip, variant, flow, profile and
endpoint. The run selector and physical-stage results are evidence from the
selected execution, which may belong to a different chip. Selecting that run
does not pick the next launch target.
The picker is available even in saved workspaces without a Planned Run pane.
If checklist evidence identifies a different chip, its stage action is blocked;
use **Plan ASIC** or a named **Launch … and view** action for the current chip.

1. Search **Plan ASIC** and choose a flow/profile for the displayed chip/variant.
   Enter an endpoint, optionally followed by `name=value` arguments, and press
   Enter to stage those inputs.
2. Reopen the palette and choose **Launch planned run without view** to keep
   inspecting the current run, or **Launch and view planned run** to follow the
   new allocation. Check the target in the action title before pressing Enter.
3. After switching chips or variants, stage a new plan. A previously captured
   plan or open input prompt cannot launch against the new chip.

If a variant advertises no named flows, its launch inputs show as unavailable.
Select a variant that offers the flow you need. Projects without a chip catalog
continue to use their existing project-level flow commands.

### Reproduce the example

From `hardcaml_asic_example`, with the sibling development binaries built:

```sh
SILVER_ASIC_PROVIDER="$PWD/../hardcaml_asic/_build/install/default/bin/hardcaml-asic-flow" \
  ../silver/_build/default/terminal/main.exe --standalone
```

Discover the catalog, select `sram_budget / two_slot`, and choose **Plan ASIC
standard / balanced** with endpoint `synthesis`. The `three_slot` variant runs
the same three-bank design with a different macro budget. `program_memory`
advertises its own `stock256-r0 / qualification` flow.

From the Silver checkout, `python3 -B scripts/test-chip-example.py` exercises
the native project picker and plan form, emits the bundle against the preview's
identity, and inspects its three requests while FIFO is the launch target.
Add `--prepare` to verify Silver's own rebuild and elaboration-only workflow,
including that its prepared bundle has the same identity. This option writes
the bundle into the example's configured preparation store.
Use `--synthesize` instead for a real two-slot synthesis run through Silver's
workflow, using the configured Docker/PDK installation.
