# Silver project authoring and command design

Design discussion record, 2026-11-20. Use this as the starting point for implementation planning. **Current behavior** below describes the checkouts examined during the discussion. The remaining sections describe the intended experience and candidate designs, not shipped features.

## Product boundary: from an empty directory to a run

Silver should be a place to start a hardware design, run it, and investigate the result. Someone using a standard flow should not have to study a CLI guide just to connect an executable, a Dune stanza, and an integration file. Someone developing a new circuit or methodology should still be able to write ordinary OCaml and use the underlying tools without Silver.

The dividing line is ownership: **Silver owns the interaction; the build tools define valid operations; the user owns the design source.** In particular, `hardcaml_asic` should define what makes an ASIC starter and flow valid. A menu and a headless command should invoke the same scaffolding operation. Silver should ask for genuine design choices (top, target, clock, constraints), not infer electrical intent from a directory name.

The product test: starting in an empty directory with the tools installed, create a small ASIC example, preview its flow, run synthesis, and inspect the result. Then clone the committed design files elsewhere and reproduce the run from the CLI without copying the original Silver session state.

## Current behavior: what “open a project” means

- **Project discovery:** `silver` searches the current directory and then its ancestors for the nearest regular `dune-project` file. A `dune` file defines local build rules; it is not a project-root marker. Neither `.git` nor a Silver config is the marker. If none is found, interactive local startup opens project setup in an unbound workspace. See [`setup/project_discovery.ml`](../setup/project_discovery.ml).
- **Inspection:** Silver opens the Dune project and inspects it on the service host. Generic Dune use does not require an ASIC declaration. Optional integration configuration tells Silver about additional capabilities; it does not create the project. [Config resolution](../project_integration/config_location.ml) prefers `.workbench/` and supports legacy root locations. The example launcher's `.dev/workbench-main` is session state, not design source.
- **Multiple chips, one project:** `hardcaml_asic_example` has distinct declarations for [FIFO](../../hardcaml_asic_example/asics/fifo_demo/project/fifo_chip.ml), [program memory](../../hardcaml_asic_example/asics/program_memory/project/program_memory.ml), and [SRAM budget](../../hardcaml_asic_example/asics/sram_budget/sram_budget.ml). The project catalog registers FIFO and program memory with their own `cli/chip.exe` entry points. The FIFO CLI also exposes its chip/variant discovery interface to Silver's [launch-target picker](launch-target.md).

## Vocabulary and ownership

| Term | Meaning in Silver |
| --- | --- |
| **Project** | The Dune project. A Git *checkout* is just a local working copy. Its root may coincide with the project root, but Git is not part of the design hierarchy. |
| **Workspace** | A way to organize what the user is viewing, not another name for a project or chip. |
| **IP library** | Reusable digital design source and its verification. A project can contain IP libraries or depend on them. An IP block need not be a chip. |
| **IP instance** | A use of a block. The parent circuit owns the instance because the wiring lives there. No second registration in Silver. |
| **Chip target** | One independently buildable chip declaration: a top design plus target, clock/timing intent, pinout, policy, and base flow. A reusable wrapper can be the top for one target and a component elsewhere. |
| **Named flow / profile / run** | A methodology offered for a chip; a named settings variant belonging to that methodology; one execution attempt. Selecting a profile is not creating a flow. |

For example, the [FIFO IP](../../hardcaml_asic_example/ip/controlled_fifo/rtl/) defines the block, the [Tiny Tapeout wrapper](../../hardcaml_asic_example/asics/fifo_demo/rtl/tt_wrapper.ml) instantiates and wires it, and the FIFO chip declaration chooses the wrapper as the design to build. Adding a second FIFO instance is a wiring change, not an occasion to generate a new library, CLI, or Silver configuration.

**Proposed multi-chip model:** keep one hardware declaration per chip. A project-level **chip-target catalog** should list targets and how to reach them. The Dune project supplies the entries; `hardcaml_asic` defines a listing/selection interface usable from the CLI; Silver consumes it. The catalog should not restate pinouts, clocks, or IP inventories. Removing a catalog entry should remove a chip from the picker without preventing its independent CLI build. No overarching `Silver.Project.create` is needed.

In the UI, use **Project: `hardcaml_asic_example` · Chip target: `fifo_demo`**. Use `Hardcaml_asic.Chip_target.create` for a declaration; `Project.create` is its compatibility spelling. `Chip_catalog` represents the collection, not an individual chip.

## Creating things: templates that become yours

| Starting point or intent | Proposed interaction |
| --- | --- |
| Empty directory | Offer **Create project here…** and **Open existing project…**. Default to the current directory; offer a small Hardcaml simulation or ASIC starter. |
| Existing Dune project | Open immediately. **Set up project…** offers **Import existing ASIC design…** (register an executable by reference) or **Add ASIC starter…** (create design sources). No second project initialization. |
| New reusable block | **New IP Library…** creates a new directory with a small Dune library stanza, an empty or example `.ml` module, and a test stub. |
| Another module in a library | **New Module…** creates the module in the chosen library. From that library's own menu the destination is already known. Avoid “Add file to project” and a duplicate Silver file inventory. |
| New independently runnable chip | **New Chip Target…** scaffolds the declaration, build/CLI wiring, and integration needed to expose it. This is where repeated copy-and-edit plumbing is worth automating. |

Templates are **one-shot starters**, not the output of a GUI model that must be regenerated. Preview what will be created, refuse destination collisions, and hand the source to the user. An edited starter remains ordinary project code; to try another starter, create another one. Avoid generated monoliths, protected comment regions, and actions that rewrite customized files as a side effect.

Creating and connecting are different operations. For example, a newly created flow module is not automatically registered in an explicit OCaml catalog. Offer a narrowly labeled **Register this flow in the chip catalog of flows** edit with the exact change visible. If custom OCaml makes an edit unreliable, show the snippet and where it belongs. Never regenerate the whole catalog just to add one entry. Selecting and running need no source edits at all.

## Where to find a flow

**In the FIFO example:** `fifo_chip.ml` supplies the base LibreLane hardening flow. See [`flow_catalog.ml`](../../hardcaml_asic_example/asics/fifo_demo/project/flow_catalog.ml) for catalog wiring and [`standard_profiles.ml`](../../hardcaml_asic_example/asics/fifo_demo/flows/standard_profiles.ml) for the `standard` profiles, including `balanced` and `synth_delay`. The [chip CLI](../../hardcaml_asic_example/asics/fifo_demo/cli/chip.ml) exposes that catalog.

**Preferred organization:** someone asking “where is flow 2 defined?” should be able to open one obvious module. Let each named flow supply one complete catalog entry: methodology, supported endpoints and parameters, available profiles, and default profile. The chip's flow catalog collects those entries and chooses a default. For example:

```text
asics/chip_a/
  project/project.ml       # design, target, constraints, base flow
  flows/standard.ml        # standard methodology and its profiles
  flows/exploratory.ml     # another methodology and its profiles
  flows/catalog.ml         # register entries and select the chip default
```

A module is enough for a small flow. Use a separate library when sharing warrants it, or split a large set of profiles into files without changing who owns them. The **project's chip-target catalog** answers “which chips?”; the **chip's flow catalog** answers “which methodologies and profiles for this chip?”

Give different operations different verbs:

- **Run flow…** selects an existing flow/profile and creates an attempt. Running `standard / balanced` creates no `.ml` file and changes no declared default.
- **Duplicate profile…** creates durable settings based on an existing profile. A new settings variant does not need a new methodology or necessarily its own file.
- **Add methodology…** starts a new recipe or set of supported endpoints. A template may supply its initial profiles; the resulting flow module belongs to the project.

## Menus and keyboard interaction

Preserve the workspace strip. Prototype one always-visible **Project ▾** at its left edge, visually separated from workspace names. Project opens a menu; workspaces change what you see. Start there before adding a permanent toolbar row or a mode that toggles a wall of buttons.

Put broadly discoverable actions in Project (Open/New Project, New IP Library, New Chip Target, New Module, Select Chip Target). Also put actions beside the objects they operate on: **New Module** on a library, **New flow** on a chip's flow list, **Run** on a profile. Menus, clickable actions, and the palette should invoke the same command. Pass the invoking context: if a workspace is inspecting a chip independently of the shared selection, running its profile must target the chip shown there.

A menu should be one focused list, not a permanent Tab stop for every command. Provide a documented key to open Project from a tile. Preserve normal Tab/Shift-Tab focus navigation outside the menu. Inside it, support arrows or `j`/`k`, movement counts such as `10j`, `/` to filter, and Enter to invoke. In filter text mode, `j` types a letter. Escape leaves filtering, then closes the menu and restores the original focus. Mouse activation should produce the same result as Enter.

## Command palette: stable intent beats fuzzy ranking

Treat the first result for a small set of common queries as a learned keyboard shortcut. Bind curated aliases to stable command IDs rather than assigning a global priority to every command. More specific queries such as `synth rows` should still find specialist actions. New commands must not displace the basic actions below.

| Query + Enter | Contract |
| --- | --- |
| `a launch` | Launch the **currently staged plan**, preserving its target, profile, and endpoint. If no plan is staged, say so; do not promote “Launch CTS in view” into its place. |
| `synth` | Start a **fresh synthesis run in view** for the current chip target and profile, even if the staged plan goes through CTS. Do not discover rows or navigate to a report. |
| `new ip` | Open **New IP Library…** in the current project, rather than discovering or refreshing resources. |

Show what Enter will do in the selected row, e.g. `Run synthesis in view · fifo_demo / standard / balanced → synthesis`. With the needed context known, the interaction is **open palette → type `synth` → Enter → synthesis starts**. No Tab, extra query text, or redundant confirmation. Test the action that actually executes, not just the list ordering.

## What to prototype before fixing the layout or API

1. From Testing, can a first-time mouse user find **New IP Library…** without knowing a palette command?
2. From a selected IP library, can a keyboard user create a module without selecting that library again?
3. At 80 columns, can someone open a menu, filter, cancel, and return to the same row without losing their place?
4. With a plan staged through CTS, do `a launch` and `synth` visibly target and execute their distinct intended operations? Does an unavailable alias avoid launching a different command?
5. Can a fresh project complete the empty-directory-to-reproducible-run path above, and can an existing multi-chip project expose a second chip without duplicating its hardware declaration?

Still to settle in implementation planning: the target-catalog contract and storage, the first starter's exact contents, how to offer registration edits for hand-written catalogs, and the final menu placement and key binding after terminal demos. The ownership rules and user-facing operations above are the criteria for judging those choices.
