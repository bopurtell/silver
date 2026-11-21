# Silver documentation

Silver opens independent Hardcaml projects, runs their configured commands, and
lets you inspect execution and hardware evidence. Project and provider commands
also work without Silver.

## Open or set up a project

- [Install and open Silver](../README.md#install-and-open-silver) — open a Dune
  project locally, create an ASIC starter, or attach to a persistent daemon.
- [Manage a project](features/workspaces/WB-086-owner-trial.md) — browse its IP
  libraries, chip targets, flows, and profiles without changing the launch target.
- [Connect an existing project](existing_project_setup.md) and
  [migrate its configuration](migration_guides/project-configuration.md).
- [Try the Cyclesim counter](../examples/cyclesim_counter/README.md) or
  [explore a simulated flow](synthetic_flow.md) without physical EDA tools.
  For real ASIC evidence, see the [retained example demo](real_asic_example_demo.md).

## Launch and inspect an ASIC run

- [Choose a chip and flow](launch-target.md), then use the
  [stage checklist](checklist_launch_workflow.md) to prepare or launch it.
  [Launch and stage consistency](launch_stage_consistency.md) explains how to
  distinguish readiness from the exact submitted run.
- Inspect [synthesis cells](synthesis_inspection.md), [resource declarations and
  realized use](resource_inspector.md), or [timing paths, clocks and physical
  evidence](asic_evidence_inspection.md).
- [Investigate Timing](timing_workspace_usability.md) and read
  [stage and run durations](execution_durations.md).
- [Collect or accept an execution and browse reports](finalization_and_artifacts.md).
  [Execution, runs and evidence](features/runs_and_evidence.md) explains why a
  completed run, its individual checks, and acceptance are different facts.

## Run simulations and compare results

- [Testing workspace](testing_workspace.md) — discover suites, select cases and
  seeds, rerun failures, and inspect retained artifacts and logs.
- [Waveforms](testing_workspace.md#embedded-waveform-viewer) — press **w** for
  quick inspection or **W** for a dedicated workspace with the exact trace pinned.
- [Workloads](workloads.md) — what a workload contract is and how to compare two
  verified results. [Workloads workspace controls](workloads_workspace.md) cover
  capture, refresh, comparison, and handoff to Testing.
- [Structured simulation reference](structured_simulation.md) — reruns, history,
  trace export, and the documented limits.

## Navigate and customize the terminal

- [Terminal controls](terminal_controls.md#controls) and
  [linked and independent run contexts](features/run_contexts.md).
- [Overview and theme picker](overview_sidebar.md#live-color-schemes),
  [appearance presets](appearance_presets.md), and
  [identifier compression](identifier_compression.md).
- [Compose windows and workspaces](workspace_configuration.md), or
  [restore a built-in layout](default_layout_restore.md) without losing runs or pins.
- [Browse a design's hierarchy](hierarchy_tile.md).

## Integrate a provider

- [ASIC provider integration](asic_provider_integration.md) and
  [project preparation](project_preparation.md).
- [Simulation provider contract](simulation_provider_contract.md) and
  [native OCaml providers](features/verification/WB-066-ocaml-provider-library.md).
- [Execution module](execution_module.md), [architecture](hardcaml_workbench_architecture.md),
  and [rendering](rendering.md).

## Develop Silver

- [Build and check Silver](../README.md#development),
  [test suite selectors](../test/README.md), and
  [test ownership and integration boundaries](testing.md). These test Silver,
  not the hardware projects you run in its Testing workspace.
- [Real fresh-prefix acceptance tests](real_prefix_pyramid.md) are opt-in and
  require an explicitly prepared external project.
- [Feature inventory](feature_list.md), [ticket catalog](features/README.md),
  [decision log](decisions.md), and [formatting guide](formatting_guide.md).
- [Construction plan](construction_phase_plan.md), [migration guides](migration_guides/README.md),
  and [backlog](backlog/README.md).
- [Documentation archive](archive/README.md) — completed implementation plans,
  review receipts, and historical acceptance evidence.
