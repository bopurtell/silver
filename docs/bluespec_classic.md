# Classic Bluespec in a Silver project

The front-end workflow starts with a `.bs` design and ends with a checked
Verilator run and a VCD. You do not need an opam switch in the **design**, a
Hardcaml wrapper, an ASIC provider, or a PDK.

## Start in an empty directory

For interactive creation, launch `ag`, choose **New Project…**, select
the **Bluespec Classic / Bazel / Rust** starter, and choose the destination.
From an open local project use **Project → New Project…**. For scripts:

```sh
mkdir fifo-lab && cd fifo-lab
ag init --bluespec
bazel build //:rtl          # Classic Bluespec → Verilog
bazel test //:simulation   # Rust checks the Verilated design
ag
```

Use **Space c c → Open project file…** and enter `Counter.bs` to edit the
counter. `checker.rs` contains the expected behavior; `bench.cpp` connects it
to the generated Verilator model. To check that you are testing the edited
hardware, change `value + 1` to `value + 2` in a scratch project and rerun:
the checker should report a mismatch and leave a waveform through the failure.
Use Silver's project build or test action to run the same Bazel labels. For
an inspectable run, open **Space c c → Switch to Testing**, focus **Simulation
Catalog**, choose **Bluespec Classic**, and press **Shift+R** to launch
`counter-smoke`. Its default seed is 42; press **e** to change it. In [Testing](testing_workspace.md),
select the attempt and its waveform artifact; press **w** to inspect it. A
plain Bazel test job gives you its process result; the structured run also
retains the trace with the attempt.

The starter's `.workbench/hardcaml-workbench-simulation.sexp` runs
`simulation_provider.py` relative to the project root, so moving the checkout
does not break the registration. If you copy the project to another host,
check that `provider_executable` names Python 3 on that host.

See the [editable starter](../examples/bluespec_classic/README.md) for tool
prerequisites, source layout and the bench interface.

## Add reusable IP inside the project

| To create… | Choose | Example |
| --- | --- | --- |
| A `.bs` file next to the top | **Project → New Module…** | Enter `.` for the package directory and `helper` for the name. Preview and apply to create `Helper.bs`. |
| A reusable IP library | **Project → New IP Library…** | Enter `widget` to create `ip/widget/Widget.bs` and `ip/widget/BUILD.bazel`. |
| Another `.bs` file in that library | **Project → New Module…** | Enter `ip/widget` and `pipeline` to create `ip/widget/Pipeline.bs`. The generated library's filegroup already includes it. |

Use lowercase names starting with a letter; digits and underscores are also
allowed after the first letter. The wizard capitalizes the first letter for the
Classic package name. Review the proposed paths before applying. Creating a
library does not instantiate the block or change the top.

A consuming design needs **both** a Bazel dependency on the library's
sources and a Classic `import` for the package it uses. The build dependency
gets the files into the BSC action's sandbox; the import makes their symbols
available to the design. For a project made with an older starter, see
[updating an existing Bluespec project](bluespec_existing_projects.md).

## Open an existing Bazel workspace

At the design root, point `.silver/project.json` at your existing build and
test labels. For instance:

```json
{
  "schema_version": 1,
  "name": "fifo",
  "build_label": "//rtl/fifo:rtl",
  "test_label": "//verify/fifo:scoreboard"
}
```

Run `ag` there. The build and test actions do not require a simulation
provider; the Testing catalog does. To expose structured verification, adapt
the starter's provider to launch your bench and publish its outcome and
trace using the [simulation provider contract](simulation_provider_contract.md).
The v1 project file selects one pair of labels. It is not a list of every
module, flow, or test case in the checkout.

## Who owns what?

| Question | Authority |
| --- | --- |
| What is this Silver project called, and what should Build and Test launch? | `.silver/project.json`: a name and explicit Bazel labels. Dune-backed projects continue to use their existing integration. |
| Which sources, dependencies and commands build the RTL or test? | The project's Bazel rules. Both labels work headlessly and Silver does not mirror their dependency graph. |
| What is instantiated in the hardware? | The elaborated design. A build dependency might instantiate zero modules or hundreds; a Bazel package tree isn't an RTL hierarchy. |
| Which suite, cases and seeds can the user run? | The simulation provider registered in `.workbench/`. Silver owns attempt identity, supervision and retained artifacts. |
| What does a physical flow do? | Its provider. Project intent can associate a target with a flow; the provider defines stages, validates inputs and interprets evidence. |

`.silver/` is not a replacement for `.workbench/`, nor is `.dev/` required in a
design checkout. Keep existing companion files where their resolvers expect
them. Classic Bluespec is the Haskell-style `.bs` language compiled by `bsc`;
using the installed compiler does not make the design a Cabal project.

## Which action elaborates the design?

Use **Build** (`b` in the workbench). In the starter, it runs `bazel build
//:rtl`; BSC elaborates the configured top and emits Verilog. Use **Testing**
when you also want to run the Rust checker and retain its waveform.

The ASIC Stage Checklist's **Elaboration** row prepares a `hardcaml_asic`
implementation bundle. It does not launch BSC. The Classic starter supports
front-end builds and simulation, not ASIC physical design, FPGA implementation
or hardware emulation.
