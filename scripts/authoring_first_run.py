"""Drive WB-084's first Silver session through the installed terminal UI."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from contextlib import closing
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


CHIP, VARIANT, FLOW, PROFILE, ENDPOINT = "demo", "default", "standard", "balanced", "synthesis"
TARGET = f"{CHIP}/{VARIANT}"
BUILD_TARGET = f"asic_{CHIP}/project.exe"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def send(term, keys):
    os.write(term.master, keys.encode())


def selected_command(screen, query):
    """Read the selected palette row, not the query, another row or an adjacent pane."""
    lines = screen.splitlines()
    for index, header in enumerate(lines):
        if "╭ COMMAND PALETTE" not in header:
            continue
        left = header.index("╭ COMMAND PALETTE")
        right = header.index("╮", left)
        if lines[index + 1][left + 1:right].strip() != f"> {query}▏":
            break
        for line in lines[index + 2:]:
            if line[left:left + 1] == "╰":
                break
            if line[left:].startswith("│ > "):
                return line[left + 4:right].strip()
    return None


def palette_preview(term, label, query, expected):
    for key in " cc":
        send(term, key)
        term.drain(.12)
    send(term, query)
    screen = term.capture(label, ["COMMAND PALETTE", f"> {query}▏"])
    row = selected_command(screen, query)
    require(row is not None and (row == expected or row.startswith(expected + " · ")),
            f"{label}: expected selected {expected!r}, got {row!r}")


def completed(screen):
    """Return whether the synthesis row itself (not a neighboring tile) completed."""
    return re.search(r"\bSynthesis:\s+completed\b", screen, re.IGNORECASE) is not None


def cell_count(screen):
    counts = re.findall(r"(?:^|│)[ \t]*Reported cells \(agg\.\):[ \t]*([0-9]+)[ \t]*(?=│|$)",
                        screen, re.MULTILINE)
    require(len(counts) == 1 and int(counts[0]) > 0,
            "Synthesis inspection did not report one positive total cell count")
    return int(counts[0])


def wait_for_synthesis(term, timeout):
    deadline = time.monotonic() + timeout
    while True:
        screen = term.drain(min(1, max(0, deadline - time.monotonic())))
        if re.search(r"\b(?:Synthesis|Workflow|Elaboration|Elaboration-bundle emission):\s+"
                     r"(?:(?:build|emission)_failed|failed|cancelled|interrupted)\b",
                     screen, re.IGNORECASE):
            term.save("synthesis-failed", screen)
            raise RuntimeError("Silver reported a failed workflow; see synthesis-failed.txt")
        if completed(screen) and re.search(r"Reported cells \(agg\.\):\s*[1-9][0-9]*\b", screen):
            term.save("synthesis-completed", screen)
            return
        if time.monotonic() >= deadline:
            term.save("synthesis-timeout", screen)
            raise TimeoutError("Silver did not show completed synthesis metrics; see synthesis-timeout.txt")


def inspect_synthesis(term):
    for _ in range(20):
        if "overview › synthesis" in term.drain(.12).casefold():
            break
        send(term, "\t")
    term.capture("synthesis-focused", ["Overview › synthesis"])
    palette_preview(term, "zoom-synthesis-command", "Zoom focused tile", "Zoom focused tile")
    send(term, "\r")
    return cell_count(term.capture("synthesis-inspected", ["Reported cells (agg.):",
                                                           "synthesis: completed", "Evidence: validated"]))


def execution_records(results):
    # The provider's segmented Runner writes execution-<attempt>.json.
    return [path for path in results.rglob("execution-*.json") if path.is_file()]


def successful_execution(results):
    records = execution_records(results)
    require(len(records) == 1, f"Expected exactly one Silver synthesis execution record, got {records}")
    path, = records
    record = json.loads(path.read_text())
    require(record.get("status") == "completed" and record.get("exit_code") == 0
            and record["plan"]["stages"] == [ENDPOINT]
            and record["plan"]["initial_boundary"] is None,
            f"Silver execution did not complete one fresh synthesis: {path}")
    return path


def execution_reference(results, path):
    record = json.loads(path.read_text())
    stream = record["attempt_id"]
    plan_identity = record["methodology"]["plan_identity"]
    require(re.fullmatch(r"[a-f0-9]{32}", stream) and re.fullmatch(r"[a-f0-9]{64}", plan_identity),
            "Invalid provider stream or plan identity in Silver execution record")
    attempts = []
    for allocation in results.rglob("000000000001.json"):
        event = json.loads(allocation.read_text())
        if (event["event"] == "allocated" and event["stream_id"] == stream
                and event["data"]["workspace"] == str(path.parent)):
            attempts.append(allocation.parent)
    require(len(attempts) == 1, f"Expected one observation for Silver execution {stream}, got {attempts}")
    return dict(attempt=str(attempts[0]), stream_id=stream, plan_identity=plan_identity)


def first_run(project: Path, evidence: Path, tools: Path, env: dict, record, *, commit_design,
              setup_timeout=180, synthesis_timeout=1800):
    """Author and synthesize one starter.

    `record(step)` marks each phase. `commit_design(project, created_files,
    rendered)` is the caller-owned source handoff and returns the committed revision.
    """
    record("silver-start-empty")
    project, evidence, tools = (Path(p).resolve() for p in (project, evidence, tools))
    require(project.is_dir() and not any(project.iterdir()), "Silver requires an empty project directory")
    require(not evidence.is_relative_to(project), "Silver evidence must be outside the project")
    require(tools.is_dir(), "Provisioned toolchain directory does not exist")
    evidence.mkdir(parents=True, exist_ok=True)
    runtime_env = dict(env, GIT_OPTIONAL_LOCKS="0")
    for key in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
        path = Path(env[key]).resolve() if env.get(key) else evidence / key
        if not path.is_relative_to(evidence) or path == evidence or path.is_relative_to(project):
            path = evidence / key
        path.mkdir(mode=0o700, exist_ok=True)
        require(not any(path.iterdir()), f"Silver requires fresh {key}: {path}")
        runtime_env[key] = str(path)
    silver = shutil.which("silver", path=runtime_env.get("PATH", ""))
    dune = shutil.which("dune", path=runtime_env.get("PATH", ""))
    renderer = shutil.which("hardcaml-asic-starter", path=runtime_env.get("PATH", ""))
    require(silver and dune and renderer, "Installed silver, dune and hardcaml-asic-starter must be on PATH")
    # Preserve argv[0]: the installed `silver` launcher has its own startup behavior.
    session = SimpleNamespace(env=runtime_env, evidence=evidence)
    with closing(Terminal(session, argv=[os.path.abspath(silver)], cwd=project, width=200, height=48)) as term:
        term.capture("empty-workspace", ["Unbound workspace", "Create project here"])
        record("silver-preview-starter")
        send(term, "c")
        term.capture("starter-name", ["Project name"])
        send(term, CHIP + "\r")
        term.capture("starter-destination", ["Destination"])
        send(term, "\r")
        term.capture("starter-preview", ["Create preview", "Recipe: hardcaml-asic-starter-v1",
                                        f"First registered chip target (default): {CHIP}",
                                        f"asic_{CHIP}/project.ml", "Enter: Apply and open"])
        require(not any(project.iterdir()), "Authoring preview changed the empty project")

        record("silver-apply-starter")
        send(term, "\r")
        term.capture("starter-opened", ["Overview", f"Project: {CHIP}", "Connection: connected"],
                     absent=["Unbound workspace"], timeout=setup_timeout)
        catalog = json.loads((project / "hardcaml-asic-targets.json").read_text())
        require(catalog["default_target"] == CHIP
                and catalog["targets"] == [{"id": CHIP, "executable": BUILD_TARGET}],
                f"Unexpected starter target catalog: {catalog}")
        raw = subprocess.check_output([renderer, "render", "--name", CHIP], cwd=project,
                                      env=runtime_env, timeout=setup_timeout)
        (evidence / "starter-renderer.json").write_bytes(raw)
        rendered = json.loads(raw)
        source_paths = sorted([item["path"] for item in rendered["files"]]
                              + ["hardcaml-asic-targets.json"])
        created_files = sorted(str(path.relative_to(project)) for path in project.rglob("*")
                               if path.is_file() and "_build" not in path.relative_to(project).parts)
        require(set(created_files) == set(source_paths) | {
            ".workbench/hardcaml-workbench-asic.sexp",
            ".workbench/hardcaml-workbench-preparation.sexp",
        }, f"Unexpected published starter files: {created_files}")
        # The provider needs a real HEAD for source provenance. The wrapper owns
        # repository creation and the exact source-only commit used for replay.
        record("commit-authored-design")
        fixture_commit = commit_design(project, created_files, rendered)

        record("silver-build-starter")
        # Silver generated a project-relative toolchain setting. Bind installed tools
        # without copying them or changing the authored source/configuration.
        (project / "_flow_tools").symlink_to(tools, target_is_directory=True)
        build_log = evidence / "starter-build.log"
        with build_log.open("w") as log:
            build = subprocess.run([dune, "build", BUILD_TARGET], cwd=project, env=runtime_env,
                                   stdout=log, stderr=subprocess.STDOUT, timeout=setup_timeout)
        require(build.returncode == 0, f"Starter Dune build failed; see {build_log}")

        record("silver-preview-flow")
        discover = "Discover ASIC flows and runs"
        palette_preview(term, "discover-command", discover, discover)
        send(term, "\r")
        term.capture("launch-target", [f"Launch target: {TARGET}", "available to launch",
                                      "Run: none selected"], timeout=setup_timeout)
        plan = f"Plan ASIC {FLOW} / {PROFILE}"
        palette_preview(term, "plan-command", plan, f"{plan} (enter endpoint) — {TARGET}")
        send(term, "\r")
        term.capture("plan-endpoint", [f"PLAN ENDPOINT — {TARGET}", f"> {ENDPOINT}▏"])
        send(term, "\r")
        term.capture("plan-preview", ["ready: Fresh input intent", "Workflow: Not submitted",
                                     f"endpoint: {ENDPOINT}", f"flow: {FLOW} / profile: {PROFILE}",
                                     "Run: none selected"], absent=["PLAN ENDPOINT"])
        palette_preview(term, "launch-synthesis-command", "Launch and view planned run",
                        f"Launch staged in view — {TARGET} · {FLOW} / {PROFILE} → {ENDPOINT}")
        results = project / "_flow_results" / "workbench" / "asic"
        require(not execution_records(results), "An execution already existed before explicit launch")

        record("silver-launch-synthesis")
        send(term, "\r")
        wait_for_synthesis(term, synthesis_timeout)

        record("silver-inspect-synthesis")
        count = inspect_synthesis(term)
        execution = successful_execution(results)
        selection = dict(chip=CHIP, variant=VARIANT, flow=FLOW, profile=PROFILE, endpoint=ENDPOINT)
        return dict(selection=selection, fixture_commit=fixture_commit, cell_count=count,
                    synthesis_screen=str(evidence / "synthesis-inspected.txt"),
                    **execution_reference(results, execution))
