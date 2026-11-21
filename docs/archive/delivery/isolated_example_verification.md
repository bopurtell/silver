# Isolated example tooling verification

## Current verification — 2026-11-19

The recovered implementation is in `../bpurtell-feature5-recovery` on base
`92b3f3d`. The recorded commands and paths in the Nov 5 evidence below are
historical. On the recovery checkout, the daemon and terminal built with
`-j6`, terminal tests passed, and the isolated Python suite passed 35 fixtures.
The setup supports `.workbench/` and legacy root-level configs; when both exist
they must match byte-for-byte. The smoke helper can select a simulation provider
relative to the cloned example root.

The real-example smoke (`/tmp/opencode/wb052-1yh7_1kg`) used committed example
revision `df7be91d230de84bf5c40bf47a79bbdc9f68e78e` and recorded provider
generation `a6b95e48dd784eeb99ccc2e797f10faa`. It audited the disposable clone,
built `asics/fifo_demo/cli/project.exe` with `-j 1`, handed the private endpoint
to the plain client, and stopped the owned daemon. The client reported 25
generic workspace items with zero jobs.

The final loopback SSH/tmux walkthrough (`/tmp/opencode/wb052-real-ssh-ql40v_4k`)
used the rebuilt recovery pair. At 120×40 the F8 navigation controls were visible
on entry, and scrolling exposed each help section. The client survived tmux
detach/reattach and reconnected after a private daemon restart. Both reopening
over SSH and attaching a local client through an SSH forward passed. The private
tmux `escape-time` stayed at 500 ms. The run verified cleanup of SSH, tmux, the
daemon, and temporary keys. It did not exercise retained-evidence inspector exits
or viewer launch on separate hosts; the regression tests below cover those cases.
Separately, the terminal waveform PTY regression passed all 21 checks on the
recovery binaries, including a headless recording viewer receiving the verified
byte-exact file (`/tmp/opencode/pt8-waveform-pty-0ua_zizb`). That local run does
not establish viewer placement across two hosts.

### Automated inspector and viewer acceptance

Run from the recovery checkout with its prebuilt daemon and client:

```sh
python3 -B terminal/test_inspector_exits_pty.py \
  --daemon _build/default/daemon/main.exe --client _build/default/terminal/main.exe

python3 -B terminal/test_viewer_ssh_locality.py \
  --daemon _build/default/daemon/main.exe --client _build/default/terminal/main.exe \
  --loopback
```

The inspector test passed 12 checks covering the table and row detail, Esc from
detail and filter input, Esc to close the explorer, reopening, and direct close
with Space c x. It checks that the workspace and retained evidence stay intact.
Evidence: `/tmp/opencode/wb052-inspector-d3bd99d80bd1`.

The viewer test passed 14 checks with a private loopback SSH server. In each
client's private temporary directory, a recorder observed a verified export with
the expected byte count and digest. Evidence: `/tmp/opencode/wb052-viewer-ssh-_dh403pu`.
For a two-host run, replace `--loopback` with:

```sh
--ssh-host YOUR_SSH_ALIAS --remote-client /absolute/path/to/matching/main.exe
```

The configured host needs Python 3 and loopback TCP forwarding in both directions.
Use the same client executable on both hosts (the test compares SHA-256) and an
SSH alias that can authenticate noninteractively. The test provisions its own
fixture, daemon, and recording viewers; it needs no existing run or GUI. It
requires distinct hostnames in two-host mode and checks each viewer's reported
hostname, private verified path, and VCD bytes. The two-host run is still pending.

## Scope and ownership

This is an **explicitly added bounded adoption-tooling extension**, not a claim that
the original WB-052 already specified this tooling. The original ticket remains
partial. Implementation is on `bpurtell/isolated-review-tooling` in
`/home/wayne/devel/jane/bpurtell-feature5`, created from committed `oxcaml`
`2b428159b2c86e56725e4a664db75b0627f40c75`. No dirty owner-worktree changes were copied.

Entry points (Python 3, standard library only):

- `scripts/isolated_example.py`: explicit clone/rewrite and default read-only audit.
- `scripts/isolated_review.py`: preflight, optional worktree build, private launch.
- `scripts/isolated_review_dune.py`: session-local Dune job-limit wrapper.
- `scripts/verify_isolated_review.py`: opt-in reproducible real-example smoke test.

## Explicit setup workflow

1. Select an existing provider **generation**, its compatible opam switch, and
   toolchain/PDK directories. Do not install or refresh shared dependencies here.
   Capture a complete environment JSON, rather than an ambient-shell overlay.
   For example (replace the absolute paths):

   ```json
   {
     "PATH": "/provider/generations/GEN/bin:/opam/SWITCH/bin:/usr/bin:/bin",
     "OPAM_SWITCH_PREFIX": "/opam/SWITCH",
     "OCAMLPATH": "/provider/generations/GEN/lib",
     "HOME": "/task/private-home",
     "LANG": "C.UTF-8",
     "DUNE_CACHE": "disabled",
     "PYTHONDONTWRITEBYTECODE": "1"
   }
   ```

   Keep this file private; captured environments may contain credentials. Setup
   canonicalizes PATH/OCAMLPATH/switch aliases, saves mode-0600 environment JSON
   beneath a mode-0700 directory, and records environment/provider SHA-256 hashes.
   Launch using that saved environment. Changing it or provider bytes requires an
   explicit setup rewrite, not an automatic refresh. Installed library contents
   are not recursively hashed; preserve the selected generation/switch in place.

2. Create a new detached checkout from a specific committed example revision:

   ```sh
   python3 -B scripts/isolated_example.py \
     --clone-from /source/hardcaml_asic_example --revision COMMIT \
     --project-root /task/example --rewrite \
     --provider-executable /provider/generations/GEN/bin/hardcaml-asic-flow \
     --env-file /task/environment.json --toolchain /shared/flow-tools \
     --simulation-provider /task/example/simulation/provider.py
   ```

   The parent directory must exist and the destination must not exist. Clone uses
   `--no-hardlinks --no-checkout` then detached checkout of the resolved commit.
   Source uncommitted changes are reported and excluded. No source Git config,
   identity, branch, index or working files are changed. No commit/push occurs.

   For an existing explicit task copy, omit `--clone-from`/`--revision`. First run
   without `--rewrite` and configuration overrides to audit it. Unsafe copied
   absolute paths fail closed; `--rewrite` is the explicit repair operation.
   Initial copies must exclude build outputs, symlinks and hardlinks. The script
   never deletes those to make an audit pass. It retains original configs once.

3. Active ASIC project executable, ASIC/preparation result roots and simulation
   provider become task-local. Simulation requires explicit selection; provider
   arguments must be empty. Only toolchain, Python, support tools, PDK and selected
   ASIC provider paths may remain external read-only dependencies. A missing
   ASIC configuration requires `--toolchain`; optional dependencies can be given
   with `--python`, `--support-tools`, and `--pdk-root`.

4. Run the printed launcher `--check` command. Build the project's `bin/project.exe`
   with its saved environment and `dune build -j 1 --root /task/example bin/project.exe`.
   The smoke-test helper below performs that environment handoff explicitly.
   Findlib availability is a preflight, **not an API/ABI compatibility guarantee**;
   the project compilation is the stronger check.

## Launcher and short manual review

From this worktree, first build its own pair:

```sh
dune build -j 1 daemon/main.exe terminal/main.exe
```

Use the verified disposable checkout below for a short local review:

```sh
PROJECT=/tmp/opencode/wb052-h5trayxc/example
PROVIDER=/home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-pt8/provider/generations/f205e0d66f8d4f2b8d1e5f098171bb21/bin/hardcaml-asic-flow
python3 -B scripts/isolated_review.py --project-root "$PROJECT" \
  --provider-executable "$PROVIDER" \
  --env-file "$PROJECT/.isolated-example/environment.json" --check
python3 -B scripts/isolated_review.py --project-root "$PROJECT" \
  --provider-executable "$PROVIDER" \
  --env-file "$PROJECT/.isolated-example/environment.json"
```

1. Check the printed worktree/project/provider paths, provider and binary hashes,
   selected Dune/switch/OCAMLPATH, private session directory, endpoint and instance.
2. Confirm generic project views open for the **task** root. No hardware driver is
   configured in this committed example; the plain client explains that honestly.
3. Change a presentation preference and inspect its files under the printed
   session's `preferences/`; the owner's preferences are not used. Each invocation
   starts fresh; retained sessions are evidence, not automatic resume targets.
4. Exit the client normally (or interrupt the launcher). Only its owned processes
   are cleaned up. Inspect `launch.json` and `daemon.log` in the retained session.
   To reopen, rerun the launcher; it creates a new private pair and endpoint.

`--plain` prints generic status then exits. `--check` does not create a session or
start the pair. `--build` explicitly builds this worktree with `-j 1` before launch;
it is mutually exclusive with `--check`. Binary overrides must still resolve inside
this worktree's `_build`. Launch snapshots both binaries before execution.
The daemon binds port 0 and publishes readiness; the launcher verifies its PID and
hands its loopback endpoint to `--connect`. It never discovers, attaches to, signals,
replaces, or stops an owner daemon. Separate discovery, daemon state, terminal
preferences, temporary/cache directories and diagnostics are supplied.

The PATH shim overrides adapter `-j20` with `-j 1`; BLAS/OpenMP thread defaults also
become 1. This is not a global scheduler: absolute Dune invocations and independent
physical-tool worker settings can bypass it. Review one job at a time and budget
nested tool workers separately. Verification used serial builds/tests, no subagent
builds, and at most the launcher, daemon and client process workloads together.
It did not consume the full five-job allowance or the server-wide twenty-job ceiling.

## Verification evidence (2026-11-05)

Exact commands, run from `/home/wayne/devel/jane/bpurtell-feature5`:

```sh
dune build -j 1 daemon/main.exe terminal/main.exe
python3 -B -m unittest discover -s scripts -p 'test_isolated_*.py'
python3 -B scripts/verify_isolated_review.py \
  --source /home/wayne/devel/jane/hardcaml_asic_example \
  --revision 70ea683a395a4833aa29ab4de9fbc024c8bcd8c1 \
  --generation /home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-pt8/provider/generations/f205e0d66f8d4f2b8d1e5f098171bb21 \
  --switch-prefix /home/wayne/.opam/5.2.0+ox \
  --toolchain /home/wayne/devel/jane/hardcaml_asic_example/_flow_tools
```

- Worktree pair build passed; **28 fixtures passed**. They cover unsafe copied paths, config/build
  symlinks, hardlinks, missing receipts, provider/environment drift, explicit rewrite,
  clone commands, endpoint/PID validation, timeout/early exit/interruption cleanup,
  client exit propagation, private preferences and missing-library diagnostics.
  `git diff --check` and `git diff --no-index --check -- /dev/null FILE` for
  each new script and this note also passed; the index is empty.
- Real smoke passed: isolated config audit **before** project build; project build
  with explicit `-j 1`; launcher preflight; real daemon/client endpoint handoff;
  generic workspace (55 inspected items); zero client exit; owned daemon reaped.
- Evidence: `/tmp/opencode/wb052-h5trayxc`, session `sessions/review-ayc1dq_h`,
  endpoint `http://127.0.0.1:33689` (now stopped). Provider SHA-256:
  `01b59aa1d9db90094df6c15480960660f4020a218c459c8a9361bf724ec46b51`.
- Negative preflight (expected exit 1, no pair launched):

  ```sh
  python3 -B scripts/isolated_review.py \
    --project-root /tmp/opencode/wb052-h5trayxc/example \
    --provider-executable /home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-pt8/provider/generations/f205e0d66f8d4f2b8d1e5f098171bb21/bin/hardcaml-asic-flow \
    --env-file /tmp/opencode/wb052-h5trayxc/example/.isolated-example/environment.json \
    --require-library missing_wb052_library --check
  ```

  It names the missing findlib package, selected switch/OCAMLPATH and corrective
  action. An existing provider executable alone does not supply build libraries.
- An earlier run of the same smoke command with generation
  `/home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-pt6/generations/97b85a9e25e24615b758b97b21ca9697`
  failed at project compilation (`Timing.create` unbound), despite library queries
  passing. Evidence retained at `/tmp/opencode/wb052-yrnd7qvj`. Selecting the existing
  compatible fixed PT8 generation required no owner installation/config changes.
  Its installation receipt describes a development snapshot, not a clean-release
  source claim. Intermediate successful smoke evidence: `/tmp/opencode/wb052-w8xfjrqt`.

## Limits and remaining original WB-052 criteria

- Local plain-client integration is verified. Interactive presentation review,
  representative SSH/tmux traversal, latency/escape tradeoffs, inspector exits and
  remote reconnect/reopen controls still need manual review under original WB-052.
- Client host, daemon host and provider paths coincide in this local launcher.
  It does not provision SSH, configure tmux, forward remote ports or validate remote
  viewer locality. Existing guidance remains in `existing_project_setup.md`/`asic_evidence_inspection.md`.
- No ASIC physical flow, simulation installation or provider-refresh workload was
  run. Setup pins paths/environment; it is not a source-code security sandbox.
  Shared dependencies are read-only by workflow contract, not chmod/mount changes.
  Use external read-only mounts for OS-enforced isolation. Never run shared install,
  bootstrap or refresh operations from this workflow. Python bytecode and Dune cache
  writes are disabled; writable result paths remain task-local.
- Strict known-field S-expression parsing fails closed on unsupported syntax.
  Receipt-proven build directory interiors are trusted generated files, allowing
  Dune's normal symlinks; root symlinks are rejected. Hostile/concurrent filesystem
  mutation is outside this bounded accidental-cross-checkout protection.
- External changes: only the three disposable `/tmp/opencode/wb052-*` directories
  above (clones, configs, environment receipts, local build products, session logs).
  No edits to `hardcaml_asic`, the owner example, other worktrees, or shared toolchains.
  Main-checkout workload changes were preserved. No staging, commits, pushes,
  Git identity changes or attribution trailers were made.
