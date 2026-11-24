# Testing Silver: ownership and integration boundaries

This guide is about **tests of the software tool**. The
[Testing workspace](testing_workspace.md) executes a separate thing: a
project's declared verification suites. A deliberate DUT failure can be a
passing Silver test if Silver reports and retains that failure correctly.

## Where tests belong

Treat a software subsystem like an IP for test ownership: the subsystem owns its
behavioral contracts and tests, while the application owns composition contracts.
Reusable test infrastructure corresponds to a common verification-agent library.
Software build/runtime dependencies replace RTL elaboration dependencies; not every
dependency creates a separate integration test or needs a full-system test.

The main rule is **put a test with the smallest owner of the behavior/composition
being asserted**. The number of modules it imports is not the deciding factor.

| Behavior under test | Natural owner/location here |
| --- | --- |
| Codec or state-machine invariant | Inline next to its module, or that library's `test/` |
| Backend service + its provider adapter | `backend/test/` if the backend owns the composition contract |
| HTTP server request/response handling | `daemon/test/` even though it uses backend/protocol libraries |
| Terminal input/state/rendering + catalog behavior | `terminal/` inline/focused tests, or terminal-owned integration |
| Whole setup→daemon→client→provider scenario | Repository-wide integration/acceptance in `test/integration/` and `scripts/` |
| DUT stimulus/model/assertions/scoreboards | Project-owned verification/provider, not Workbench's generic tool tests |
| Shared fake provider/PTY/HTTP helpers | Test-only reusable support such as `test/support/`, not production imports from test entrypoints |

For example, a cache/provider test does not move to root just because it composes
two modules. A test of the complete installed client/daemon/provider workflow does
belong at the application-integration level. Keep responsibility visible rather
than sorting every two-module test into a global folder.

## Current layout

```text
protocol/                  production code and some inline contracts
  test/                    additional codec/validation contracts
provider/test/             provider wire/runner conformance
project_integration/test/  project/config/driver contracts
adapters/test/             invocation/parsing/identity contracts
backend/test/              services, caches, processes, lifecycle and provider integration
daemon/test/               native HTTP/RPC integration
setup/test/                setup/configuration/CLI integration
terminal/                  presentation code, inline tests and focused test modules
  workspaces/              workspace definition/preset tests
  test/                    additional terminal-owned integration
scripts/                   many opt-in HTTP/PTY/installed/real-provider/EDA harnesses
test/
  dune                     index/selectors over existing subsystem tests
  integration/             app-wide fresh-prefix and streaming export runners
  support/                 shared PTY/screen helpers and controlled regression tests
  fixtures/                DATA ONLY, including miniature projects
  baselines/               DATA ONLY, expected terminal captures
```

OCaml `let%test`/`let%test_unit`/expect tests run through explicitly enabled Dune
inline-test libraries. They need not have filenames starting with `test_` or be
inside root `test/`. Conversely, an executable named `test_provider` or a Python
file named `test-*` is not automatically a registered test.

Nested projects in `test/fixtures/` are specimens, not Silver build targets.

## Runnable selection groups

See [root test README](../test/README.md) for commands and explicit constraints.

| Alias | Selection |
| --- | --- |
| `@test-contracts` | protocol + provider + project-integration + adapters |
| `@test-presentation` | terminal tests recursively, including workspaces |
| `@test-backend` | backend tests recursively |
| `@test-setup` | setup tests |
| `@test-api` | daemon HTTP/RPC tests, selected separately |
| `@test-support` | shared test helpers, compatibility imports and failure/cleanup controls |
| `@test-native-smoke` | opt-in synthetic terminal waveform handoff with real daemon/client |
| `@test-native-standalone` | opt-in installed command, discovery, locking, and reattachment |
| `@test-local` | contracts + backend + presentation + setup + support; API and native smoke are NOT included |

These are mixed unit/contract/local-integration groups. They do not imply complete
API or frontend coverage. Shared helper tests now join `@runtest`; native smoke
remains opt-in and no real EDA is added to the default closure.

Local tests can start subprocesses, create disposable Git fixtures, or run
nested builds. Some RPC fixtures select nested `-j1`; an outer Dune limit
does not override subprocess budgets. On constrained machines run setup
separately: it deliberately starts twelve initializers.

## Integration is about contracts, not a complete N×M product

Tests can be organized by the composition owner and parameterized over meaningful
dimensions. Important dimensions include protocol version, pass/fail/error/partial
outcome, endpoint, case selection, artifact kind and cancellation/reconnect phase.
Use equivalence classes, boundary cases, selected pairwise combinations and known
high-risk interactions, plus a small number of complete workflows. Do not claim
exhaustive combinations merely because tests run at the application level.

For stage prefixes, cheap controlled-provider tests verify stopping at the intended
endpoint and not launching successors; explicit real-tool tests establish actual
EDA behavior. Running all real physical endpoints after a styling edit is not a
reasonable default. Conversely, avoiding an expensive run does not make its old
measurements valid for newly changed hardware or backend inputs.

## Opt-in external inputs

The [real fresh-prefix tests](real_prefix_pyramid.md) have individually
selectable endpoints and an explicit serial aggregate. Only the controlled
harness tests run in the default or local selection. Similarly, the
[streaming export runner](streaming_export_acceptance.md) needs explicit
prebuilt and retained-evidence inputs. Do not point these runners at an
owner's mutable project or reuse retained hardware measurements as proof of a
new execution.
