# Project configuration directory — WB-049

Integration configuration now belongs in `.silver/`
beneath the project root. Schemas and basenames remain separate:

```text
.silver/silver.sexp
.silver/silver-asic.sexp
.silver/silver-simulation.sexp
.silver/silver-preparation.sexp
```

Only these four files are migrated. Layout templates, personal XDG state, caches,
provider registries and canonical run evidence are not moved. The project root
remains the Dune project root, not `.silver/`.

## Lookup and compatibility

| Files present | Result |
| --- | --- |
| Legacy root file only | Load legacy file |
| Common-directory file only | Load common file |
| Both, byte-identical | Load common file |
| Both, different bytes | Fail with both paths in the diagnostic |
| Neither | Existing absent-configuration behavior |

Invalid or unsafe common configuration never falls back to legacy configuration.
Symlinks and nonregular files are rejected. Files are bounded to 64 KiB; simulation
retains its stricter 16 KiB loader limit. Reads detect observed filesystem changes,
but do not provide atomic snapshots against concurrent editors.

Both `silver*.sexp` and `hardcaml-workbench*.sexp` are recognized in `.silver/`,
`.workbench/`, and at the project root. Every existing copy must be byte-identical.
New initialization writes to `.silver/`, refusing existing configuration at any location.
The unrelated Bazel `.silver/project.json` is retained.

## Explicit migration

Use a newly built/installed initializer:

```sh
silver-init --root /absolute/project --migrate-configs --dry-run
silver-init --root /absolute/project --migrate-configs
```

`--discover-project` can replace `--root` when invoked within a project. Migration
cannot be combined with initialization-only options. Dry-run describes proposed
directory creation and every copy without writing anything.

Migration preflights all four classes, copies exact bytes without rewriting paths
or parsing schemas, and **retains every legacy original**. Identical targets are
skipped; differing targets are never overwritten. Repeating succeeds without writes.
Publication is atomic per file, not across the whole set. On partial failure,
originals and completed copies remain usable; fix the issue and rerun. Publication
uses Linux `/proc/self/fd` and no-replace hard links, requiring filesystem hard-link
support. New files have mode 0600 and a new directory 0700.

After checking the result, explicitly remove obsolete legacy copies when ready.
Until then, edits must keep all copies byte-identical; whitespace differences also
conflict. Rollback before further edits can remove the new copies and use the
retained originals. No automatic deletion or provider-registry transfer occurs.

## Paths, identities and adoption

Relative generic driver paths and preparation build targets retain their
**project-root** meaning. ASIC executable/resource paths retain their absolute-path
requirements. Relocation does not make machine-specific values portable.

Unchanged parsed values preserve ASIC registry/cache identity, simulation config
digest and preparation matching. However, the generic source-tree hash includes
relative filenames: copying/moving configuration can change source provenance,
as can Git dirty/commit state. Existing run evidence is not rewritten.

Existing refresh boundaries apply: generic integration uses explicit refresh;
ASIC configuration remains pinned to its loaded service scope with freshness checks;
simulation/preparation recheck at their existing admission boundaries. Migration
does not restart daemons or adopt providers automatically.

The example's main/development launchers and FIFO installer recognize both locations,
reject conflicts and synchronize identical dual copies when publishing configuration.
Development recovery journals cover both copies. No actual example or Protemu
configuration was migrated during implementation.

## Verification

Project-integration, setup and backend suites pass with `dune runtest -j4` in a
private build directory. Tests cover lookup combinations, unsafe/changing paths,
byte limits, identity stability, dry-run, no-clobber, repeat and failure/resume.
Additional disposable-fixture checks:

```sh
python3 -B scripts/test-config-migration-consumers.py
python3 -B scripts/test-config-migration.py --init /path/to/setup/main.exe
```

Real EDA and live project migration are not part of these tests.

## Local state and SDK

New runtime and personal-state directories use `silver` under the relevant XDG
root. Existing `hardcaml-workbench` state is used in place when no corresponding
Silver directory exists. If both exist, resolve the conflict explicitly before
starting Silver; stop running daemons before moving any state.

The package/module `hardcaml_workbench_provider` / `Hardcaml_workbench_provider`
is now `silver_provider` / `Silver_provider`. Rebuild providers against the new
SDK; the simulation wire protocol and generic manifest language tag are unchanged.
