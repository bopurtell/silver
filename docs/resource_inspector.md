# Inspect resources in Workbench

Resources shows ASIC-owned requested, selected, elaborated and realized facts.
Opening a source reads existing evidence; it does not build, emit, synthesize or
run physical tools. The provider owns selection, reconciliation and measurements.

## Open the workspace

Open **Space c c** and choose **Inspect resources (open Resources workspace)**.
Fresh default sessions include Resources after Timing. Existing saved layouts are
preserved: this explicit action creates/opens Resources without resetting other
workspaces. **Add resource-summary tile** adds the compact Overview entry.

The Resources workspace has a **request list** and a linked **resource detail**
tile. Browse the list with `j`/`k` or the arrow keys; the detail tile follows
the highlighted request without requiring Enter. The list remains in place
while you scroll a long contract or inspect additional evidence in detail.
In Resources, open **Space c c** and choose how the two tiles share your screen:

* **Resources: List and detail side by side** gives both tiles more height.
  Use it to browse a long list or read a long contract.
* **Resources: Stack list above detail** gives the request list the full width
  for implementation names and synthesis/final columns. Scroll the detail
  tile to see the rest of the selected request.

Either choice also opens the pair from a saved single-tile built-in Resources
workspace. Silver remembers the orientation for that workspace. The highlighted
request stays selected; changing layout does not reload the resource evidence
or change the run. Custom-authored layouts keep their own layout policy.

These are two presentations of the same Resources module, following the
[module/tile ownership model](features/modules_and_tiles.md#ownership). The list and reader
share the workspace's source and selected resource ID. The provider supplies
the decisions and observations; neither tile independently resolves the request.

Read the detail groups in order:

* **Request and requirements:** the resource kind, fields declared by that
  kind, and which implementation policy applies. A memory can specify width,
  depth, ports and read latency. Other resource kinds show their own fields;
  a RAM layout is not imposed on a different contract.
* **Selection:** the implementation chosen at elaboration and why.
* **Actual implementation:** what was elaborated, including the instance names
  if the provider recorded any.
* **Realization and qualifications:** what synthesis or the final run verified,
  and limits on that evidence. Selection alone does not imply a netlist match.

In the ordinary detail view, the verdict and its qualification align with
**Synthesis** and **Final**. The page counters and section catalog are kept
out of this view. Press `d` for provenance; Enter in detail shows the raw
metadata when you need the provider's exact values.

### See the mapping from your own synthesis run

For the three-bank example, select `sram_budget / two_slot` as the launch
target and launch `standard / balanced` through `synthesis`. In **Resources**:

1. Open the palette (`Space c c`), search **Resources: Select execution**,
   and choose that run's ID. The tile's **Scope** identifies what it is reading.
2. Use lowercase **`r`** to refresh that source. It does not pick the latest
   run or switch away from a previously imported bundle. If you used **Launch
   and view** and the tile follows Main, the new run is already selected.
3. Check **Decision** for elaboration and **Synth** for checkpoint evidence.
   `bank0` and `bank1` should be exact macro mappings and synthesis matches.
   `bank2` should show a budget-exhausted flop fallback; optimized flops
   are not individually attributed. Highlight `bank2` to see its contract,
   requested policy and fallback reason together in the detail tile.

To inspect elaboration without synthesis, choose **Resources: Select workflow
bundle** instead. A `fifo_demo` synthesis can legitimately have zero rows: its
ordinary registers do not register SRAM requests.

### Inspect the actual SRAM evidence

Choose **Resources: Import retained resource evidence**, enter the following exact
directory **without quotes**, then press Enter:

```text
/home/wayne/devel/jane/hardcaml_asic_example/acceptance/resource-measurements/accepted-live-01/run
```

This is a retained coarse-run capture, not a newly executed run or a synthetic
observation stream. It preserves original run `be961b2c95f74c81ad6af81ca4d2b269`
and its build identity. The table should show `program`, the stock SRAM selection,
actual instance `hc_resource_7_program`, and synthesis/final `matched` observations.

Other explicit targets:

- **Resources: Import emitted bundle** — verify exact bundle inputs and inspect
  selected inventory before any physical execution.
- **Resources: Select workflow bundle …** — inspect that workflow's exact emitted
  bundle; failed/not-yet-emitted workflows have no successful empty inventory.
- **Resources: Select execution … / Select finalization …** — retain the selected
  execution/operation linkage. For a completed named stock-SRAM synthesis-only
  run, the provider checks the module and instance names in the verified
  checkpoint netlist. A selected flop fallback does not gain an inferred cell
  count. Unsupported named-stage realization is unavailable;
  aggregate checkpoint counts do not prove per-resource retention.
- **Resources: Follow tile run binding** — follow the exact workspace selected or
  pinned run. Explicit imported sources remain independent of Main changes.

Historical sources lacking inventory show **Unavailable** or **Unknown**, not
“Resources: 0.” A genuinely verified resource-free FIFO shows available empty
inventory. Likewise, implementation selection is not synthesis/physical retention.

## Controls

| Key/action | Behavior |
| --- | --- |
| `j` / `k`, arrows | Select resource/source rows; scroll in detail |
| Enter | Open selected resource detail or authorized source bytes. In detail or provenance, toggle raw metadata for the current page. |
| Esc | Return to the previous inspector view |
| `/`, Ctrl-U | Filter resources; clear filter |
| `g` | Geometry, physical component areas and gross-area ratios |
| `t` | Sampled timing paths |
| `e` | Electrical point observations |
| `d` | Full source provenance/context |
| `a` | Authorized source catalog |
| `n` / `p` | Next/previous provider page |
| `[` / `]` | Scroll eight wrapped lines |
| `r` | Explicitly refresh the exact evidence source |

The palette also exposes inventory, synthesis and final detail sections. Timing
items are byte-bounded: a page may contain fewer than the requested eight rows.
Follow the returned next page rather than assuming a fixed offset. All 76 advertised
sources in the SRAM capture are reachable through the paged catalog.

The first two table columns identify the resource and **why its implementation
was chosen**. Wider panes also show the implementation, synthesis and final
observations, then the actual elaboration role. The detail tile shows the full
values when a cell is clipped. A budget-exhausted fallback is a selection decision;
the independently colored resource verdict and stage observations describe
different evidence. The scope and source lines identify an explicit import or
an exact run binding. A chip and variant appear when the bound run or workflow
records them.
An imported bundle instead shows its verified project name and hardware
assignments when the provider supplies them. **Launch target** is shown
separately: importing evidence does not change the design that Overview plans.

Inventory detail summarizes RAM depth, width and contract attributes. Other
sections label nested observations by field (for example, a path endpoint's
pin and slew). Enter toggles the original provider metadata without requesting
another page; `a` opens the separate catalog of retained source files.

Source bytes are addressed by provider-authorized handles and validated hashes,
not arbitrary client paths. Text is sanitized for display; byte offset/hash remain
the original source identity. External SRAM model references may be recorded without
retained bytes and are not turned into readable artifacts.

## Interpret the example

- Requested contract: 256×16 single-port memory; explicit exact mapping and its reason.
- Selected macro: `RM_IHPSG13_1P_256x16_c2_bm_bist`.
- Footprint: **28,127.104 µm²**; nonspacer standard-cell footprint sum:
  **4,793.6448 µm²**; gross core rectangle: **902,417.2416 µm²**.
- **186 sampled timing paths / 372 electrical point observations**.
- Slow setup path includes macro `A_DOUT[11]` → `uo_out[3]`, slack
  **11.246561 ns**, output slew **0.067838 ns**, reported load **0.004815 pF**.
- Fast hold path ends at macro `A_ADDR[6]`, slack **0.223533 ns**; blank load remains
  absent. Analysis −40°C and bound SRAM model −55°C are displayed separately.

Area ratios are component rectangle sums over gross core/die rectangles, not
geometric unions or usable placement-site utilization. Electrical compliance is
**not_assessed**; timing coverage is sampled, not exhaustive. No per-resource power,
optimized-flop ownership, timed SRAM conformance or IR/EM qualification is implied.

Import the original `acceptance/sram/physical-p4` separately to see geometry with
timing unavailable: it does not contain the raw STA reports. The inspector never
borrows those reports from the augmented capture. Likewise, the separate synthesis
specimen's 30,309.8272 µm² combined estimate is not a physical area for this run.

## Compare explicit sources and use declared controls

1. Select/import the first source and choose **Resources: Capture comparison A**.
2. Select/import the second and choose **Resources: Capture comparison B**.
3. Choose **Resources: Compare captured A / B (c)**. Swap using the palette action.

Captures keep exact source/provider/index identities; Main changes never retarget
them. Changed provider/projection or lost validation is visible. Contract, policy,
selection, reason, role and realization differences remain explicit. Numeric deltas
require finite values and equal name/unit/stage/definition/scope/classification.
Only provider-classified **Observed** or **Derived** values receive measured deltas;
estimates/unknowns do not. Missing values retain their actual unavailable reasons.

Existing **Plan ASIC FLOW / PROFILE (enter endpoint)** and **Preparation inputs:
FLOW / PROFILE** actions expose the project's advertised controls. This feature
does not add unsupported memory-policy knobs or launch a variant sweep. Changing
inputs stages a new explicit workflow; inspecting/comparing alone never launches it.

## Freshness and failures

Rendering, filtering, ordinary polling and warm cached reopening do not invoke the
provider. Explicit cold open/refresh/page requests are bounded read-only operations.
Restored cache is **Cached_unverified**. Failed refresh, missing source, unsupported
capability and invalid evidence remain distinguishable from a valid failed resource
check. Failed required-macro evidence is readable rather than discarded as a transport
error. A late response cannot populate a different target or acknowledge a new retry.

Index truncation is visible. Catalog/detail pages are bounded; a single item too
large to represent produces an explicit error. Current limits are 32 source
descriptors, eight indexes and a bounded detail cache; these are not unlimited archives.

## Start the tested app pair

Both daemon and client changed. Stop the previous pair when no work is active, then
start the rebuilt default binaries. No demo `seed` or pinned-binary refresh is needed.
Only one daemon may own the selected state directory. Substitute your intended
state directory if it differs from the earlier session below.

Server:

```sh
cd /home/wayne/devel/jane/hardcaml_asic_example
source .dev/asic-pt6/generations/97b85a9e25e24615b758b97b21ca9697/activate.sh
export OCAMLPATH="$OCAMLPATH:$PWD/.dev/workbench-provider-sdk/lib"
export DUNEJOBS=6 OPAMJOBS=6 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
/home/wayne/devel/jane/silver/scripts/with-switch.sh \
  /home/wayne/devel/jane/silver/_build/default/daemon/main.exe \
  --port 41735 --state-dir /tmp/opencode/workbench-pt5-Zcj6Y5
```

Client:

```sh
cd /home/wayne/devel/jane/silver
./scripts/with-switch.sh _build/default/terminal/main.exe \
  --connect http://127.0.0.1:41735 \
  --project-root /home/wayne/devel/jane/hardcaml_asic_example \
  --environment inherited
```

After owner approval, only the example companion's `provider_executable` was moved
to the exact final PT.6 generation above. Its project executable, tool paths,
timeout, results and all existing `current` pointers were preserved. The dedicated
PT.6 `current` still identifies an earlier capture; use the **immutable final path**
above, not that pointer. New capability `resource_inspection1` is required.

Provider-scope change can require explicit re-registration of older named runs;
original result bytes remain intact. The SRAM import above works independently of
that named-run cache and does not create/execute a physical run.

See [implementation contract](resource_inspector_plan.md),
[frozen API handoff](resource_inspector_handoff.md) and
[native acceptance evidence](resource_inspector_acceptance.md).
