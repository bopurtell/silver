#!/usr/bin/env python3
"""Run the installed Silver starter journey and its clean CLI handoff."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


class Unavailable(Exception):
    """An installation prerequisite is absent; no acceptance claim is possible."""


def prerequisites(tools, evidence, env):
    binaries = {}
    for name in ("silver", "hardcaml-asic-starter", "hardcaml-asic-targets",
                 "hardcaml-asic-flow", "dune", "git"):
        path = shutil.which(name, path=env["PATH"])
        if not path:
            raise Unavailable(f"{name} is missing from PATH")
        binaries[name] = path
    if not tools or not tools.is_dir():
        raise Unavailable("provide the provisioned tool root via --toolchain or ASIC_TOOLCHAIN")
    libraries = subprocess.run([binaries["dune"], "installed-libraries", "--root", str(evidence)],
                               env=env, cwd=evidence, text=True, capture_output=True, timeout=30)
    if libraries.returncode or not any(line.split()[:1] == ["hardcaml_asic"]
                                       for line in libraries.stdout.splitlines()):
        raise Unavailable("Dune could not find the installed hardcaml_asic library in this environment"
                          + (f": {libraries.stderr.strip()}" if libraries.stderr.strip() else ""))
    # Use the installed provider's own lockfile and checks, including engine/image
    # availability. Never install, fetch or repair tools during acceptance.
    with (evidence / "toolchain-check.log").open("w") as log:
        result = subprocess.run(
            [binaries["hardcaml-asic-flow"], "provision", "--check", "--offline",
             "--toolchain", str(tools)], stdout=log, stderr=subprocess.STDOUT,
            cwd=evidence, env=env, timeout=120)
    if result.returncode:
        raise Unavailable(f"toolchain check exited {result.returncode}; see toolchain-check.log")
    (evidence / "provider-version.json").write_bytes(subprocess.check_output(
        [binaries["hardcaml-asic-flow"], "--version", "--json"], cwd=evidence, env=env, timeout=15))
    return binaries


def run_environment(evidence, side, tools):
    # Preserve the activated compiler/provider and Docker credentials. Give each
    # side independent Silver state and prevent external Dune build/cache reuse.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GIT_", "SILVER_", "WORKBENCH_", "DUNE_"))}
    for key, name in (("XDG_STATE_HOME", "state"), ("XDG_CONFIG_HOME", "config"),
                      ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime")):
        path = evidence / side / name
        path.mkdir(mode=0o700, parents=True)
        env[key] = str(path)
    env.update(DUNE_CACHE="disabled", ASIC_TOOLCHAIN=str(tools),
               PDK_ROOT=str(tools / "pdk"), PDK=str(tools / "pdk"),
               TT=str(tools / "tt"), FLOW_PY=str(tools / ".venv/bin/python"))
    env.setdefault("HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT", "6")
    return env


def journey(evidence, tools, report, record):
    from authoring_first_run import first_run
    from authoring_acceptance_replay import capture_starter, commit_starter, inspect_synthesis, replay_synthesis
    if any((p / "dune-project").is_file() or os.path.lexists(p / ".git")
           for p in [evidence, *evidence.parents]):
        raise ValueError("--evidence must be outside existing Dune projects and Git repositories")
    project = evidence / "authored"
    project.mkdir()
    record("open Silver in empty directory")
    ui_env = run_environment(evidence, "ui", tools)
    ui = evidence / "ui"
    snapshot = None

    def commit_design(project, files, rendered):
        nonlocal snapshot
        snapshot = capture_starter(project, files, rendered)
        return commit_starter(snapshot, ui, ui_env)

    first = first_run(project, ui, tools, ui_env, record, commit_design=commit_design)
    selected = first["selection"]
    provider = Path(report["installed"]["hardcaml-asic-flow"])
    baseline = inspect_synthesis(project, provider=provider, attempt=first["attempt"],
                                 stream_id=first["stream_id"], plan_identity=first["plan_identity"],
                                 selection=selected, receipts=evidence / "ui", env=ui_env,
                                 record=lambda name: record("Silver " + name))
    report["silver"] = baseline
    if baseline["metric"]["value"] != first["cell_count"]:
        raise ValueError("Silver's displayed cell count differs from its checkpoint report")
    baseline["screen"] = first["synthesis_screen"]
    baseline["fixture_commit"] = first["fixture_commit"]
    cli_env = run_environment(evidence, "cli", tools)
    record("reproduce in clean clone")
    report["replay"] = replay_synthesis(snapshot, evidence / "clone", provider=provider,
                                        toolchain=tools, selection=selected, baseline=baseline,
                                        fixture_commit=first["fixture_commit"],
                                        receipts=evidence / "cli", env=cli_env,
                                        record=lambda name: record("CLI " + name))
    record("compared synthesis results")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain", type=Path, default=os.environ.get("ASIC_TOOLCHAIN"))
    parser.add_argument("--evidence", type=Path, help="new directory for source, both runs and logs")
    args = parser.parse_args()
    if not __debug__:
        parser.error("acceptance requires Python assertions; unset PYTHONOPTIMIZE")
    if args.evidence:
        evidence = args.evidence.resolve()
        evidence.mkdir(parents=True, exist_ok=False)
    else:
        evidence = Path(tempfile.mkdtemp(prefix="silver-authoring-acceptance-")).resolve()
    tools = args.toolchain.resolve() if args.toolchain else None
    print(f"Authoring acceptance evidence: {evidence}", flush=True)
    report = {"scenario": "starter-authoring", "toolchain": str(tools) if tools else None,
              "status": "running"}

    def record(step):
        report["step"] = step
        temporary = evidence / "summary.tmp"
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(evidence / "summary.json")
        if report["status"] == "running":
            print(f"  {step}", flush=True)

    try:
        record("check installed prerequisites")
        env = os.environ.copy()
        binaries = prerequisites(tools, evidence, env)
        report["installed"] = binaries
        journey(evidence, tools, report, record)
        report["status"] = "passed"
        code = 0
    except Unavailable as exc:
        report.update(status="skipped", reason=str(exc))
        code = 77
    except (Exception, KeyboardInterrupt) as exc:
        report.update(status="failed", reason=f"{type(exc).__name__}: {exc}")
        code = 1
    record(report["step"])
    print(f"{report['status'].upper()}: {report['step']}" +
          (f": {report['reason']}" if "reason" in report else ""))
    return code


if __name__ == "__main__":
    sys.exit(main())
