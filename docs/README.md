# Silver documentation

Silver opens hardware projects, runs their configured commands, and
lets you inspect execution and hardware evidence. Project and provider commands
also work without Silver.

## Get started

- [Install Silver](install.md) and [open a project or attach to a daemon](project_workflows.md).
- [Start a Classic Bluespec project](bluespec_classic.md) with Bazel, Verilator and Rust.
- [Manage a project](project_management.md) or [connect an existing project](existing_project_setup.md).
- [Migrate root companion files to `.silver/`](migration_guides/project-configuration.md).
- Try the [Cyclesim counter](../examples/cyclesim_counter/README.md) or
  [synthetic flow demo](synthetic_flow.md) without physical EDA tools.

## Launch and inspect an ASIC run

- [Choose a chip and flow](launch-target.md), then use the
  [stage checklist](checklist_launch_workflow.md) to prepare or launch it.
  [Plan readiness and launch state](launch_stage_consistency.md) explains how to
  tell them apart.
- Inspect [synthesis cells](synthesis_inspection.md), [resources](resource_inspector.md),
  or [timing paths, clocks, and physical evidence](asic_evidence_inspection.md).
- [Investigate timing](timing_workspace_usability.md) and interpret
  [stage and run durations](execution_durations.md).
- [Collect or accept an execution and browse its reports](finalization_and_artifacts.md).

## Run simulations and compare results

- [Testing workspace](testing_workspace.md) — discover suites, select cases and
  seeds, rerun failures, and inspect retained artifacts and logs.
- [Configure and check a simulation provider](simulation_setup.md) before opening
  its project in Silver.
- [Waveforms](testing_workspace.md#embedded-waveform-viewer) — press **w** for
  quick inspection or **W** for a dedicated workspace with the exact trace pinned.
- [Workloads](workloads.md) and [Workloads workspace controls](workloads_workspace.md)
  cover capture, refresh, comparison, and handoff to Testing.
- [Structured simulation reference](structured_simulation.md) — reruns, history,
  trace export, and limits.

## Edit, navigate, and customize

- [Cobalt editor](cobalt_editor.md) — open source locations, configure the embedded
  editor, or connect a separate Cobalt window.
- [Terminal controls](terminal_controls.md#controls), [shared project terminal](terminal_controls.md#shared-project-terminal),
  and [linked and independent run contexts](run_contexts.md).
- [Themes and appearance](appearance_presets.md), [identifier compression](identifier_compression.md),
  and the [Hierarchy tile](hierarchy_tile.md).
- [Compose windows and workspaces](workspace_configuration.md) or
  [restore a built-in layout](default_layout_restore.md) without losing runs or pins.

## Integrate a provider

- [ASIC provider integration](asic_provider_integration.md) and
  [project preparation](project_preparation.md).
- [Simulation provider contract](simulation_provider_contract.md) and
  [the native OCaml provider SDK](../provider/README.md).

## Contribute to Silver

- [Contributing](development.md), [test suite selectors](../test/README.md),
  and [test ownership](testing.md). These are tests of Silver, not hardware
  verification in its Testing workspace.
- Opt-in real-tool tests: [fresh-prefix acceptance](real_prefix_pyramid.md)
  and [starter synthesis acceptance](authoring_acceptance.md).
- [Hardware source formatting guide](formatting_guide.md).
