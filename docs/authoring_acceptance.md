# Reproduce a Silver starter's synthesis result (WB-084)

From the Silver checkout, in the OCaml switch where the ASIC provider and its
libraries are installed, run:

```sh
python3 -B scripts/run-authoring-acceptance.py \
  --toolchain /absolute/path/to/provisioned-tools \
  --evidence /absolute/path/to/new-evidence-directory
```

Choose an evidence path **outside existing Dune projects and Git repositories** so that Silver
starts in its empty-directory setup dialog. Both builds and their results are
retained there. The tool root is a separate input: an existing example's
`_flow_tools` can be reused without using its design, build tree or results.
If `/tmp` has a small user quota, put the evidence directory on disk and set
`TMPDIR` to a writable disk-backed directory for Dune's temporary files.

### Prerequisites

- Linux with a PTY, Python 3.11+, Git, Dune, and [an ASIC-enabled Silver installation](../README.md#install-and-open-silver).
- `silver`, `hardcaml-asic-starter`, `hardcaml-asic-targets`, and `hardcaml-asic-flow`
  on `PATH`; the active Dune context must be able to build a project that uses
  `hardcaml_asic`.
- A [provisioned tool root](https://github.com/LeEmperor/hardcaml_asic/blob/HEAD/docs/guides/bootstrap.md),
  including the IHP PDK, TT support tools, and a reachable Docker engine with
  the locked LibreLane image. To check this installation separately:

  ```sh
  hardcaml-asic-flow provision --toolchain /absolute/path/to/provisioned-tools --check --offline
  ```

### CLI handoff

The handoff consists of `dune-project`, the generated `asic_<chip>/` source
files, and `hardcaml-asic-targets.json`. Planning records Git provenance, so
the acceptance snapshots those bytes as a disposable Git fixture before the
first plan, then clones the same revision at another path. A CLI user needs
only that source and the same installed tools. From the clean clone, these
are the public commands (Bash, with `jq` for reading the JSON):

```bash
set -eu
chip=$(jq -r '.default_target' hardcaml-asic-targets.json)
exe=$(jq -r --arg chip "$chip" '.targets[] | select(.id==$chip).executable' hardcaml-asic-targets.json)
dune build "$exe"
cli="_build/default/$exe"
select_args=(--source-root "$PWD" --chip "$chip" --variant default
             --flow standard --profile balanced --endpoint synthesis --json)
out=$(mktemp -d)
"$cli" flow plan "${select_args[@]}" > "$out/plan.json"
id=$(jq -er '.plan_identity' "$out/plan.json")
"$cli" flow emit "${select_args[@]}" --expected-plan-identity "$id" \
  --results-root "$out" > "$out/emit.json"
bundle=$(jq -er '.output_dir' "$out/emit.json")
tools=/absolute/path/to/provisioned-tools
hardcaml-asic-flow stages "$bundle" --methodology-plan "$out/plan.json" \
  --expected-plan-identity "$id" --workspace "$out/workspace" \
  --checkpoint-store "$out/workspace/checkpoints" --support-tools "$tools/tt" \
  --pdk-root "$tools/pdk" --python "$tools/.venv/bin/python" --json > "$out/stages.jsonl"
execution=$(jq -ser 'last | select(.status=="completed" and .exit_code==0).execution_file' "$out/stages.jsonl")
hardcaml-asic-flow report "$execution" --json > "$out/report.json"
jq '.checkpoints[] | select(.reference.boundary=="synthesis") | .metrics[]
    | select(.raw_key=="design__instance__count") | {value,unit}' "$out/report.json"
```

### Reading the result

See `summary.json` in the printed evidence directory. Exit **0** means both
synthesis runs completed and the design metric matched. Exit **77** means an
installation prerequisite was unavailable; `toolchain-check.log` contains the
provider's diagnostics if its check ran. Exit **1** means the acceptance
failed: start with `step` and `reason` in the summary. A successful preview,
bundle build, or toolchain check does not count as a synthesis result.

`ui/plan-preview.txt` records the unsubmitted plan. `ui/synthesis-inspected.txt`
records what Silver showed after launch. `cli/` retains the exact commands,
outputs and report for the clone. The comparison uses `design__instance__count`
at the synthesis checkpoint; attempt IDs and timestamps should differ.

For the fast regression tests, run `dune runtest scripts`. These exercise
failure reporting, the terminal observations, and clean-clone and metric
checks without invoking synthesis.
