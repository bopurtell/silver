# Workloads workspace controls

Open, compare, and refresh verified workload results without rerunning them.
For workload terminology, example launch options, and acceptance evidence,
see [Workloads](workloads.md).

## Open and inspect

Use `Space c c` to open the command palette:

1. **Open Workloads workspace** creates the shipped Workloads workspace only when
   needed, or navigates to the existing workspace. Existing layouts, hidden/zoomed
   tiles, pins and custom definitions named `workloads` are preserved. A hidden
   Workloads tile needs explicit restoration through the normal tile commands.
2. **Workloads: Import exact retained result.json** prompts for an absolute file
   path. This is a retained read, not a run allocation. The daemon resolves paths;
   the terminal does not read arbitrary evidence files locally.
3. The result detail shows concise recorded execution status, functional outcome
   and performance availability, followed immediately by provider metrics. Full
   bundle/hardware/workload/simulation identities, metric definitions/scope and
   retained outcome details are available with `d` (provenance).
   Undefined/unavailable values remain unavailable.
4. `Esc` returns to the retained results list; `j/k` selects rows, `Enter` opens a
   result, `/` filters and `Ctrl-U` clears the filter. The selected identity does not
   follow Main's physical run selection.
5. `d` opens controls, bindings, provenance/source references and full diagnostics;
   `j/k` scrolls, `[`/`]` scrolls eight lines. `r` explicitly refreshes the selected
   exact source or pair. Palette commands expose the same operations.

Numeric tokens use `Yojson.Raw`: integer and decimal tokens never pass through
OCaml floats. Numerator/denominator and provider rational deltas remain visible.
The UI neither recomputes eligibility/deltas nor treats command completion as
functional success. Physical qualifications are visible independently of cycle
metrics: functional clock period, implementation constraints and host elapsed time
are not measured Fmax; this memory workload has no firmware/fetch evidence.

## Capture and compare an explicit pair

After opening the selected result's validated detail, use **Workloads: Capture A
left result** or **Workloads: Capture B right result**. When the public inspection
contains its verified absolute `binding.bundle` locator, capture is immediate with
no path-entry form. Each capture retains the result path,
public `source_digest`, bundle path and inspection-reader identity. Changing source
does not retarget either capture. A result change while the bundle form is open
rejects that form's capture.

Older inspection projections without `binding.bundle` retain an explicit absolute
bundle-directory prompt. The UI never guesses it from a directory, identity,
latest pointer or unrelated execution. A supplied bundle cannot override a
verified locator. Capture is unavailable from the list or an unloaded/mismatched
selection, so highlighting B cannot capture A's old document.

Choose **Workloads: Axis resource_policy**, `hardware`, `flow_configuration` or
`descriptive`, then **Workloads: Compare captured A / B (c)**. Axis commands with
both captures present immediately query the new explicit axis. **Swap A / B and
query provider** invalidates the old view and sends the newly ordered pair; no
local delta negation is used. Stable command IDs include `workloads.capture-a`,
`workloads.capture-b`, `workloads.axis.resource_policy`, `workloads.compare`,
`workloads.swap` and `workloads.refresh`.

After a verified comparison, Refresh pins both returned combined side
`source_digest` values independently of the standalone workload digests. Swap
exchanges those side pins with their sources; changing axis clears the combined
comparison-generation pins and reacquires them under the new axis, while preserving
each captured workload digest. Explicit recapture clears the old pair generation.

Comparison shows provider outcomes, eligibility/reasons, exact signed deltas and
comparison digest. Its comparator companion has its own identity, distinct from
the workload-inspection companion captured on each side. Neither identity is
silently relabelled as the original simulation producer.

### Existing positive example

Relative to `/home/wayne/devel/jane/hardcaml_asic_example`, import:

| Slot | Result | Exact bundle under `.dev/asic-pt8-workloads/bundles/` |
| --- | --- | --- |
| A | `acceptance/pt8-workloads/simulation-04/flops/result.json` | `4475418b7acca27b4ce3258e8097efc2b738544d9bc90d571a3489bb27b42761` |
| B | `acceptance/pt8-workloads/simulation-04/exact/result.json` | `c535d00cc950de9ebd438c78cdd99fe33f75bfd4cad1a20d7559fc1ff6f98fda` |

Enter absolute paths in the UI and select `resource_policy`. The established public
pair has seven zero workload deltas (1307 cycles, 525 reads, 262 writes, 787 accepted
operations, 2083 defined observations, one-edge read latency, 787/1307 operations per
cycle). This guide records the existing example evidence; A's native test below
uses a labelled synthetic reader. C/coordinator own actual installed-provider and
fresh-simulation acceptance. Historical physical SRAM is qualified feasibility
context, not a matched physical Flops/Exact area/speed comparison.

## Fresh launch and result handoff

**Workloads: Launch fresh memory workload… (Testing)** opens/creates Testing and
explicitly requests suite discovery. It then uses the existing catalog subset
selection and launch form. Select the example's `memory-workloads` suite and positive
`flops256` and/or `exact256` cases. Supported seed is `34097`, no parameters or
ASIC inputs. The provider enforces these fixed options; changing a view never
launches the workload. The existing form's final `launch` confirmation submits it.
Retained attempts display the suite ID captured at launch, including
`pt8-memory-workloads` for earlier attempts.

Status, logs, cancellation, rerun, durable history and submission retry remain
FS2-owned. After completion select the intended case in Testing and invoke
**Inspect workload result (selected Testing case)**. It resolves that case's exact
available `flops256-result-reference` or `exact256-result-reference` artifact,
reads at most16KiB through the existing artifact RPC, validates byte span/hash and
the strict reference schema, then imports the supplied absolute path with its
expected public digest. Another attempt/case cannot supply that selection. Missing,
changed, oversized and stale references produce a visible reason.

Those are provider declaration IDs. The public FS2 artifact ID is exactly
`ATTEMPT-flops256-result-reference` or `ATTEMPT-exact256-result-reference`; handoff
requires that exact selected-attempt namespace and its matching case attachment,
not an arbitrary suffix. Both paths are tested with actual backend artifact capture
and byte reads.

Artifact transport, simulation attempt, hardware/bundle identity and any ASIC
physical execution remain separate. The result files stay in the provider's
retention directory; copying a reference does not copy the workload evidence.
For fresh runs, follow the [checkout-backed example launch steps](workloads.md#run-the-example-workload).

## Async, cache and restoration

Rendering/filtering/geometry/provenance/palette navigation consume published state.
Read intents alone call `Asic.Operation.Workloads (Load ...)`. The transport owner
uses existing daemon/client/project fences, tile lifetime and view generation,
plus admission/receipt revision floors for reused operation keys. Queries include
ordered targets, axis and both captured workload digests. Changing source/axis,
closing/retyping a tile or reconnecting fences obsolete receipts. The Testing
reference handoff also fences its original session/workspace/artifact/navigation.

Warm workspace reopening requests an existing cached query only when its digest
descriptor is present. A restored response is labelled `CACHED UNVERIFIED`; a cold
or evicted document stays explicitly unloaded until requested. Refresh failures
keep retained facts and diagnostics visible. Parsed documents are reused while
their descriptor digest/provider identity is unchanged. B bounds cache entries,
raw bytes, source validation and provider execution. No provider is called by
the renderer.

Client navigation saves source, A/B captures, axis and query with exact tile and
session membership. New optional schema1 preference fields preserve old sidecars.
Restoration grants no validation status and does not rewrite layout/context state.
Esc/Enter and cached/palette reopening preserve the selected inspection's full
`expected_digest`. Per-path query memory survives comparison and restoration; for
otherwise ambiguous cache inventory, pinned queries sort before unpinned queries
with a stable key tie-breaker. Explicit Import remains the route to capture a new
current source intentionally.
