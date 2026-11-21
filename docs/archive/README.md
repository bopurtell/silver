# Documentation archive

Historical plans, design snapshots and validation evidence live here. They are
not active requirements or current launch instructions. Start with the
[documentation index](../README.md) for current guides.

## Release curation — 2026-11-21

The plans and receipts below record what was proposed or verified at the time.
Paths, binary hashes and results in a receipt refer to that capture, not a
current build. For today's build and test commands see the
[repository README](../../README.md#development) and [test index](../../test/README.md).

The old PT8 review directories, `reviewdocs/`, and their one-off runners and
generated receipts have been retired. Historical invocations below refer to the
revision they were recorded against. Maintained regressions are listed in the
[testing inventory](../testing_inventory.md).

| Record set | Start with | Current guide |
| --- | --- | --- |
| Initial terminal, installation and ASIC evidence | [Native and synthesis acceptance](delivery/native_and_synthesis_acceptance.md), [environment inventory](delivery/initial_environment_inventory.md), [installation checks](delivery/initial_installation_checks.md), [initial ASIC evidence acceptance](delivery/asic_evidence_initial_acceptance.md) | [Terminal controls](../terminal_controls.md), [ASIC evidence inspection](../asic_evidence_inspection.md) |
| Simulation and project adoption | [Structured simulation delivery](delivery/structured_simulation_delivery.md), [project adoption integration](delivery/project_adoption_integration.md), [Testing cluster plan](delivery/testing_cluster_plan.md) | [Testing workspace](../testing_workspace.md), [existing-project setup](../existing_project_setup.md) |
| ASIC launch, timing and resources | [Checklist launch](delivery/checklist_launch_workflow_plan.md), [launch and stage consistency](delivery/launch_stage_consistency_plan.md), [fresh-prefix handoff](delivery/unified_fresh_prefix_handoff.md), [Timing checklist](delivery/timing_checklist_overview_plan.md), [executable Timing](delivery/executable_timing_stage_plan.md), [Timing workspace and preload](delivery/timing_workspace_followup_plan.md), [Timing usability](delivery/timing_usability_preload_plan.md), [Resources handoff](delivery/resource_inspector_handoff.md) | [Checklist launch](../checklist_launch_workflow.md), [Timing workspace](../timing_workspace_usability.md), [Resources inspector](../resource_inspector.md) |
| Presentation and demos | [Composition](delivery/frontend_composition_plan.md), [refinement](delivery/frontend_refinement_plan.md), [Overview sidebar](delivery/overview_sidebar_plan.md), [layout restore](delivery/default_layout_restore_plan.md), [post-merge audit](delivery/workspace_post_merge_audit.md), [real-example polish](delivery/real_example_polish_plan.md), [synthetic flow](delivery/synthetic_flow_plan.md), [synthetic Testing](delivery/synthetic_testing_plan.md) | [Workspace configuration](../workspace_configuration.md), [themes](../overview_sidebar.md#live-color-schemes), [synthetic flow](../synthetic_flow.md) |
| Workloads and waveform integration | [Workloads acceptance](workloads-waveforms/workloads_acceptance.md), [frontend implementation](workloads-waveforms/workloads_frontend_acceptance.md), [integration plan](workloads-waveforms/workloads_integration_plan.md), [waveform recovery plan](workloads-waveforms/waveform_recovery_plan.md), [final waveform acceptance](workloads-waveforms/waveform_acceptance.md), [waveform navigation and rendering](workloads-waveforms/waveform_navigation_acceptance.md) and their linked independent receipts | [Workloads](../workloads.md), [Waveforms](../testing_workspace.md#embedded-waveform-viewer) |
| Copied example development session | [Session plan](example-development/development_session_plan.md), [backend review](example-development/development_session_backend_review.md), [Git-context review](example-development/development_git_context_independent_review.md), [pre-closeout acceptance plan](example-development/developer_workflow_acceptance_plan.md), [paused handoff](example-development/developer_workflow_acceptance_handoff.md), [resource handoff](example-development/developer_workflow_resource_handoff.md), [endpoint rejection](example-development/developer_workflow_endpoint_rejection.md) | [Superseding acceptance closeout](../developer_workflow_refactored_closeout.md) |

## 2026-10-12 consolidation

The [October 12 P0–P7 plan](construction_phase_plan_2026_10_12.md) was archived on
2026-10-15 when the active plan moved to demo phases M0–M5. It preserves the old
provider handoff and phase statuses; newer native/provider development supersedes
parts of that handoff. Relative links inside that snapshot retain their original
locations.

The snapshots retain their bodies, including old statuses, proposals and code
references. Relative links inside them were written for their original location
directly under `docs/`; treat them as historical references, not a current
navigation tree. In particular, links to the removed scaf worktree are historical.
The files are grouped together to preserve same-document-set references where
possible. Active documents link to current locations.

| Snapshot | Why retained |
| --- | --- |
| [Architecture](2026-10-12/hardcaml_workbench_architecture.md) | Detailed original architecture, wire/driver decisions and first module/tile proposal |
| [September plan](2026-10-12/construction_phase_plan_2026_09.md) | Completed 1A–1C evidence and former scaf D1–D4 roadmap |
| [Initial replacement plan](2026-10-12/construction_phase_plan.md) | W0–W6 proposal before window/run/provider refinement |
| [Philosophy](2026-10-12/project_idea_and_philosophy.md) | Earlier product rationale, now consolidated into architecture |
| [Development evidence](2026-10-12/development.md) | Recorded build/install, protocol, fixture and human acceptance checks; old toolchain investigations |
| [Prettification](2026-10-12/prettification.md) | Original UI audit and P0–P5 proposal |
| [Fixed layout](2026-10-12/terminal_layout_spec.md) | Previous fixed-dashboard cell budgets and wireframes |
| [Baseline captures](2026-10-12/terminal_baseline_captures.md) | Capture method and old-screen observations |

The current development commands are in the repository [README](../../README.md).
Generated baseline files remain under `test/baselines/terminal/`; this consolidation
does not regenerate them or change the application.

When archiving another design, record its date and replacement here. Keep
completion evidence distinct from unimplemented proposals. Git history also
retains every committed version; this directory makes important snapshots easy
to find without reconstructing that history.
