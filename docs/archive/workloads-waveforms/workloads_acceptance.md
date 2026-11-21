# Workloads acceptance and isolated session

Historical acceptance evidence. See [Workloads](../../workloads.md) for current controls and launch options.

2026-11-05. **Bounded integration accepted:** actual retained evidence and a fresh
example implementation-RTL workload were exercised through the production client.
The existing example root configuration and PT.6 session remain unchanged. This
guide opens a separate prepared PT.8 session; no additional build is required.

**Standard-flow recovery, 2026-11-05:** incorporated into the waveform-enabled
`session-waveforms-final-01` below.
The original config-only PT.8 session supported workload simulation but omitted
the source closure required by normal Plan/Preparation. The recovery session
includes an independent source snapshot, matching provider libraries and private
build/results paths. The endpoint form now prefills from advertised endpoints and
preserves quoted assignments. See [real UI recovery acceptance](../../standard_plan_recovery.md).

**Waveform recovery:** the initial PT.8 provider published only result-reference
JSON, not VCD. The new session captures and publishes actual six-signal VCDs and
keeps JSON workload inspection separate. Historical runs are preserved and do not
gain invented waveforms. See [final waveform acceptance](waveform_acceptance.md).

## Reopen the captured acceptance session

Terminal1:

```bash
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_launch.py daemon \
  --session .dev/asic-pt8-workbench/session-waveforms-final-01
```

Leave that foreground daemon running. In Terminal2:

```bash
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_launch.py client \
  --session .dev/asic-pt8-workbench/session-waveforms-final-01
```

The daemon chooses an available port and publishes it in this session's discovery
directory; the client reads that endpoint. Only one daemon should own this private
session state. The launchers use prebuilt matching Workbench binaries in
`silver/_build_pt8_workbench/default/` and private configuration, client
state and daemon state. They do not use `.dev/asic-pt6/current`, install dependencies,
restart another daemon or change the root example's FIFO/ASIC configurations.

The private workload provider is fully prebuilt. The launcher also supplies the
matching `hardcaml_asic.execution` library environment for standard-flow source
builds in the independent private example snapshot.
The normal root example's separately configured source-build flow still needs its
own matching activation environment; see [Resources launch](../../resource_inspector.md).

## Accepted evidence and review

Private session: `session-final-review-01`. Immutable ASIC reader/producer generation:
`ee3af8de9f83418b9afed9c67e473e3c`.

Actual native HTTP/PTY acceptance:

```text
hardcaml_asic_example/.dev/asic-pt8-workbench/session-final-review-01/
  native-acceptance-bb8eac43b648403d86e6c94c5cc9dfe3/assertions.json
  final-audit-a97dcfe970a4461a8e3dec9e0ebb8cf4/
  coordinator-review-01/receipt.json
```

Acceptance used the production Testing cases→seed→confirmation form to launch a
new Exact workload, then its artifact action to open **Validated** Workloads and
compare with original Flops. It also verifies a fresh HTTP-launched pair, readable
functional failure, automatic A/B capture, wide/narrow UI and warm navigation with
no child-tool execution. Original execution provider identities were preserved.
The coordinator independently checked the fresh raw simulator output, testbench
inputs, memory oracle/counters, stock model/source closure and public result digest;
no extra simulator/daemon was launched for that audit.

[Frontend independent review](workloads_frontend_review.md) corrected four
findings: prefixed FS2 artifact matching, digest loss on reopening, highlighted-vs-
loaded capture mismatch and missing target-generation pins on comparison refresh.
Its corrected independent harness retains45 original assertions and adds33 controls;
all78 pass. Original reproductions and failed receipts remain unchanged.

[Backend independent review](workloads_backend_review.md) corrected cache-root
alias publication and restored query/document binding gaps. Descriptor-bound cache
storage and canonical binding restore pass61 independent observations, including
zero observed descriptor growth across repeated failure cases. Hash consistency is
not authenticated history or an atomic cross-file snapshot. Cache format2 restores
derived evidence as unverified; old format1 derived caches require explicit rebuild.

Focused backend63 and storage-correction30 checks, the full terminal suite/lint,
protocol/adapter/daemon regressions,51 ASIC result and49 comparison checks passed.
Coordinator broad check passed:

```bash
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j6 \
  --build-dir _build_pt8_workbench @all @runtest
```

Detailed controls, limits, cache/freshness and legacy manual-capture fallback:
[UI guide](../../workloads_workspace.md), [shared handoff](workloads_protocol_handoff.md),
[plan](workloads_integration_plan.md), and
[example producer handoff](../../../../hardcaml_asic_example/docs/pt8_workbench_provider.md).
Earlier capture/compiler/harness failures remain recorded there and in their
private immutable attempts. Root configs/selected providers, installed capture,
original retained evidence/bundles and tested Workbench binaries were hash-checked
before/after native acceptance. No Git publication, existing-session restart,
Protemu work or EDA occurred. User visual acceptance is the next manual step.
