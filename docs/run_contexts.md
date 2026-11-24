# Select and compare ASIC runs

Overview, Timing, and Resources normally follow the project's shared **Main**
run context. Select a run in any linked run selector and the following tiles
in those workspaces use that run. This does not launch, cancel, or retarget work.
Cursor position, scrolling, and filters are local to each tile.

To compare a different run in one workspace, use **Make workspace independent** in the
[command palette](terminal_controls.md#controls) there, then select another run.
Use **Relink workspace to Main** to follow the shared selection again. To keep
just one tile on a reference run, focus it and use **Pin tile to selected run**;
**Unpin tile (follow context)** removes the pin. Window and layout
configuration is covered in [Compose your own windows and workspaces](workspace_configuration.md).

A pin binds a run identity, not an immutable snapshot: the run may acquire
later results, and missing provider data is not replaced by another run.
Cached reports may need to be refreshed after reconnecting. Keep execution
completion, evidence availability, and [acceptance](finalization_and_artifacts.md)
separate: a completed run is not necessarily a passing check or an accepted result.
