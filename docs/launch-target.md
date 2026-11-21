# Choose the ASIC launch target

When you open a configured ASIC project, Silver discovers the launch targets
and the selected target's flows. This does not launch synthesis. In the command
palette (`Space c c`), search **Select launch target**, or type a
chip or variant name. Each row selects one exact chip/variant pair. Selection
loads its flows; it does not build anything or switch the run you are inspecting.
In **Overview → Planned Run**, click **Launch chip** or **Variant**, or focus the
tile and press **`t`**, to open just the target choices. Type to filter, use the
arrow keys and Enter to choose, or Esc to cancel.

After registering another chip, build its target executable and run **Discover
ASIC flows and runs** again. A **Library: …** palette result comes from Dune;
it opens library actions, not the launch picker. The launch row is **Select
launch target: `<catalog ID> / <variant>`**. If `hardcaml-asic-targets list`
contains the chip but the launch row is missing, compare the configured project
executable's `chip list --json` output from the project root. This is the
discovery response Silver actually uses.

In Overview, **Session** summarizes the launch chip and variant on one line.
**Planned Run** shows the same target and the flow, profile, and endpoint in
aligned rows. The run selector and physical-stage results are evidence from the
selected execution, which may belong to a different chip. Selecting that run
does not pick the next launch target.

### Main and independent workspaces

Linked workspaces use Main's launch target. Making a workspace independent
starts it with the same chip and variant; selecting a different target there
does not change Main. For example, Overview can launch FIFO while a detached
workspace launches program memory, even if both are inspecting the same old
FIFO run. To launch for the chip behind that evidence, explicitly choose
**Use this run's chip/variant as launch target**.

On reopen, a saved chip/variant pair must still exist. If either ID is gone,
select a replacement explicitly. The catalog default is for first use, not a
substitute for a missing target. Restoring a target does not restore permission
to launch an old staged plan.

### Start a run

The picker is available even in saved workspaces without a Planned Run pane.
In the command palette (`Space c c`), type `chip` to open it. Choose your
target, then reopen the palette and type a stage: `synth` starts fresh synthesis;
`cts` starts a fresh run through CTS. Check the target and profile on the
highlighted row and press Enter. To launch a plan you already staged instead,
type `a launch`.

For the keyboard shortcut from **Stage checklist**, select **synthesis** and
press **Shift+R**. Silver uses the current launch chip/variant and its flow
settings, falling back to that target's declared default flow and profile. It
does not reuse a different chip's plan, even if the checklist still displays
that chip's run. Lowercase **r** stages the new plan for review instead.

For explicit flow/profile or parameter choices:

1. Search **Plan ASIC** and choose a flow/profile for the displayed chip/variant.
   Enter an endpoint, optionally followed by `name=value` arguments, and press
   Enter to stage those inputs.
2. Reopen the palette and choose **Launch planned run without view** to keep
   inspecting the current run, or **Launch and view planned run** to follow the
   new allocation. Check the target in the action title before pressing Enter.
3. After switching chips or variants, **Launch planned run** still requires a
   matching plan. Use **Shift+R** on a checklist stage to start a fresh one.

If a variant advertises no named flows, its launch inputs show as unavailable.
Select a variant that offers the flow you need. Projects without a chip catalog
continue to use their existing project-level flow commands.

**Testing** uses a separate simulation provider. Choosing an ASIC launch
target does not populate that catalog. To start a new simulation, focus the
catalog in Testing and use **Simulation: Discover suites explicitly**. An old
VCD in Waveforms is a retained result and can still be read even when no
simulation provider is configured.

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
