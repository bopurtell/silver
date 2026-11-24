"""Starter source handoff and headless synthesis, using public ASIC CLIs only."""

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import signal
import stat
import subprocess


CATALOG = "hardcaml-asic-targets.json"
SILVER_CONFIG = {
    ".workbench/hardcaml-workbench-asic.sexp",
    ".workbench/hardcaml-workbench-preparation.sexp",
}
METRIC = "design__instance__count"
FIXTURE_IDENTITY = "Silver acceptance fixture <silver-fixture@example.invalid>"
FIXTURE_NAME, FIXTURE_EMAIL = FIXTURE_IDENTITY[:-1].split(" <")
GIT = ["git", "-c", "core.hooksPath=/dev/null"]


class ReplayError(RuntimeError):
    def __init__(self, step, detail):
        self.step = step
        super().__init__(f"{step}: {detail}")


def require(condition, message):
    if not condition:
        raise ValueError(message)


@contextmanager
def step(name):
    try:
        yield
    except (KeyError, TypeError, ValueError, OSError) as exc:
        raise ReplayError(name, str(exc)) from exc


@dataclass(frozen=True)
class StarterSnapshot:
    source: Path
    files: tuple


def relative_file(path):
    name = str(path)
    relative = PurePosixPath(name)
    require(relative.parts and relative.as_posix() == name and not relative.is_absolute()
            and all(part not in (".", "..") for part in relative.parts),
            f"unsafe relative path: {name!r}")
    return relative


def starter_bytes(root, name):
    parts = relative_file(name).parts
    path = root
    for part in parts[:-1]:
        path /= part
        require(stat.S_ISDIR(path.lstat().st_mode), f"not a plain source directory: {path}")
    path /= parts[-1]
    require(stat.S_ISREG(path.lstat().st_mode), f"not a plain source file: {path}")
    return path.read_bytes()


def target_executable(catalog, chip=None):
    require(catalog["schema_version"] == 1 and len(catalog["targets"]) == 1,
            "expected a fresh one-target catalog")
    entry, = catalog["targets"]
    require(entry["id"] == catalog["default_target"]
            and (chip is None or entry["id"] == chip), "catalog target does not match selection")
    executable = relative_file(entry["executable"])
    require(len(executable.parts) == 2 and executable.parts[0].startswith("asic_")
            and executable.name == "project.exe", "expected a starter project executable")
    return executable.as_posix()


def capture_starter(project, created_files, rendered):
    """Freeze exactly the authored provider files and portable target catalog.

    ``created_files`` is the authoring apply receipt's relative paths; ``rendered``
    is the decoded ``hardcaml-asic-starter render --name NAME`` response.
    """
    with step("starter source capture"):
        project = Path(project).resolve(strict=True)
        require(rendered["schema_version"] == 1 and rendered["provider"] == "hardcaml_asic",
                "unexpected starter renderer manifest")
        published = [relative_file(name).as_posix() for name in created_files]
        require(len(set(published)) == len(published), "duplicate published paths")
        require(CATALOG in published, "authoring did not publish the target catalog")
        catalog = starter_bytes(project, CATALOG)
        directory = PurePosixPath(target_executable(json.loads(catalog))).parent
        files = {}
        for entry in rendered["files"]:
            relative = relative_file(entry["path"])
            name = relative.as_posix()
            require(name == "dune-project"
                    or (directory in relative.parents
                        and all(not part.startswith((".", "_")) for part in relative.parts[1:])),
                    f"not a portable starter path: {name}")
            require(name not in files, f"duplicate renderer path: {name}")
            files[name] = entry["contents"].encode("utf-8")
        require({"dune-project", str(directory / "dune"), str(directory / "chip.ml"),
                 str(directory / "project.ml")} <= files.keys(), "incomplete renderer manifest")
        require(set(published) - SILVER_CONFIG == files.keys() | {CATALOG},
                "published portable paths differ from the renderer manifest and catalog")
        for name, contents in files.items():
            require(starter_bytes(project, name) == contents, f"authored bytes differ from renderer: {name}")
        return StarterSnapshot(project, tuple(sorted({**files, CATALOG: catalog}.items())))


def command_env(env):
    # No inherited Git routing, config injection, commit hooks or Dune build-dir
    # override. Keep the activated compiler/provider and transport environment.
    result = {k: v for k, v in (os.environ if env is None else env).items()
              if not k.startswith("GIT_") and k not in ("DUNE_BUILD_DIR", "HARDCAML_ASIC_FORWARDED_TARGET")}
    result.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_OPTIONAL_LOCKS="0",
                  GIT_TERMINAL_PROMPT="0")
    return result


def save_json(path, value):
    with path.open("x") as out:
        json.dump(value, out, indent=2)
        out.write("\n")


def run(name, argv, cwd, receipts, env, timeout=120):
    """Record exact inputs and stdout/stderr, including failed steps."""
    argv = [str(arg) for arg in argv]
    with step(name):
        save_json(receipts / f"{name}.command.json", dict(argv=argv, cwd=str(cwd), timeout=timeout))
        output, errors = (receipts / f"{name}.{extension}" for extension in ("stdout", "stderr"))
        with output.open("xb") as out, errors.open("xb") as err:
            with subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                  stdout=out, stderr=err, start_new_session=True) as proc:
                try:
                    proc.wait(timeout=timeout)
                except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
                    # Let the provider publish its terminal outcome and clean up
                    # the tool process before escalating within this process group.
                    proc.terminate()
                    try:
                        proc.wait(timeout=45)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait()
                    if isinstance(exc, KeyboardInterrupt):
                        raise
                    raise ReplayError(name, f"timeout after {timeout}s; see {errors}") from exc
        require(proc.returncode == 0, f"exit {proc.returncode}; see {errors}\n"
                + errors.read_text(errors="replace")[-2000:].strip())
        return output


def query(name, argv, cwd, receipts, env):
    output = run(name, argv, cwd, receipts, env)
    with step(name):
        result = json.loads(output.read_bytes())
        require(isinstance(result, dict), "expected CLI JSON object")
        return result


def commit_starter(snapshot, receipts, env=None):
    """Commit the captured sources once, in the disposable authored project."""
    project = snapshot.source
    with step("commit starter fixture"):
        receipts = Path(receipts).resolve(strict=True)
        require(receipts != project and receipts.parent == project.parent,
                "commit receipts must be a sibling of the disposable authored project")
        require(not any(os.path.lexists(parent / ".git") for parent in (project, *project.parents)),
                "refusing to write to an existing repository")
        # Opening the project can start Dune discovery before any design build.
        # Walk only non-build entries; Git still receives the explicit allowlist.
        actual = {p.relative_to(project).as_posix()
                  for child in project.iterdir() if child.name != "_build"
                  for p in (child.rglob("*") if child.is_dir() else [child]) if not p.is_dir()}
        require(actual - SILVER_CONFIG == set(dict(snapshot.files)),
                "refusing to commit an unexpected pre-build source tree")
        for path, data in snapshot.files:
            require(starter_bytes(project, path) == data, f"authored source changed: {path}")
    env = command_env(env)
    run("fixture-init", [*GIT, "init", "--quiet", "--template=", "--object-format=sha1",
                         "--initial-branch=starter"], project, receipts, env)
    run("fixture-add", [*GIT, "add", "-f", "--", *dict(snapshot.files)], project, receipts, env)
    date = "2000-01-01T00:00:00+00:00"
    env.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
    run("fixture-commit", [*GIT, "-c", "user.name=" + FIXTURE_NAME,
                          "-c", "user.email=" + FIXTURE_EMAIL,
                          "commit", "--quiet", "--no-gpg-sign", "-m", "Authored starter fixture"],
        project, receipts, env)
    head = run("fixture-head", [*GIT, "rev-parse", "HEAD"], project, receipts, env)
    return head.read_text().strip()


def clone_starter(snapshot, clone, receipts, env, *, fixture_commit):
    """Shallow-clone the one named fixture without changing its repository."""
    name = "clean source clone"
    with step(name):
        origin = snapshot.source
        require(not clone.is_relative_to(snapshot.source) and not snapshot.source.is_relative_to(clone),
                "clone must be in a separate tree from the authored project")
        require(not receipts.is_relative_to(snapshot.source), "receipts must be outside the fixture")
        require(not os.path.lexists(clone) and clone == clone.resolve(),
                f"clone must be a new canonical path: {clone}")
        for path, data in snapshot.files:
            require(starter_bytes(snapshot.source, path) == data, f"authored source changed: {path}")
    paths = [path for path, _ in snapshot.files]
    run("fixture-clone", [*GIT, "clone", "--quiet", "--no-local", "--depth", "1", "--", origin.as_uri(), clone],
        receipts, receipts, env)
    tracked = run("clone-inventory", [*GIT, "ls-files", "-z"], clone, receipts, env)
    head = run("clone-head", [*GIT, "rev-parse", "HEAD"], clone, receipts, env)
    author = run("clone-author", [*GIT, "show", "-s", "--format=%an <%ae>", "HEAD"], clone, receipts, env)
    with step(name):
        commit = head.read_text().strip()
        require(fixture_commit == commit, "clone did not receive the requested fixture commit")
        require(author.read_text().strip() == FIXTURE_IDENTITY, "clone commit has unexpected fixture identity")
        require(tracked.read_bytes().split(b"\0") == [*(os.fsencode(path) for path in paths), b""],
                "cloned Git inventory differs from the captured file list")
        actual = {str(path.relative_to(clone)) for child in clone.iterdir() if child.name != ".git"
                  for path in (child.rglob("*") if child.is_dir() else [child]) if not path.is_dir()}
        require(actual == set(paths), "clean clone contains non-source artifacts")
        for path, data in snapshot.files:
            require(starter_bytes(clone, path) == data, f"cloned source differs: {path}")
        return dict(path=str(clone), fixture_commit=commit, fixture_identity=author.read_text().strip(),
                    files={path: hashlib.sha256(data).hexdigest() for path, data in snapshot.files})


def read_metric(report, *, execution, stream_id, plan_identity, selection, observed_methodology):
    """Extract Silver's same checkpoint-backed metric, not a parsed UI label."""
    require(report["contract"] == "hardcaml-asic.report" and report["schema_version"] == 1,
            "unsupported report contract")
    target = report["target"]
    require(target["kind"] == "stage_execution" and target["selected_record"] == execution,
            "report selected the wrong execution")
    details = report["execution"]
    require(details["attempt_id"] == stream_id and details["status"] == "completed"
            and details["exit_code"] == 0, "report is not a completed execution of this attempt")
    require(report["completion"] == dict(requested="synthesis", physical="synthesis"),
            "report does not show synthesis endpoint completion")
    methodology = report["methodology"]
    require(methodology["state"] == "recorded" and methodology == observed_methodology
            and methodology["reference"]["attempt_id"] == stream_id
            and methodology["plan_identity"] == plan_identity, "report methodology identity mismatch")
    require(methodology["flow"]["id"] == selection["flow"]
            and methodology["profile"]["id"] == selection["profile"]
            and methodology["endpoint"] == selection["endpoint"] == "synthesis",
            "report does not reflect the selected flow/profile/endpoint")
    checkpoints = [c for c in report["checkpoints"] if c["reference"]["boundary"] == "synthesis"]
    require(len(checkpoints) == 1, "expected exactly one synthesis checkpoint")
    checkpoint, = checkpoints
    metrics = [m for m in checkpoint["metrics"] if m["raw_key"] == METRIC]
    require(len(metrics) == 1, "expected exactly one mapped-cell count")
    metric, = metrics
    count = metric["value"]
    numeric = type(count) is int or (type(count) is float and math.isfinite(count) and count.is_integer())
    require(metric["availability"] == "available" and metric["unit"] == "cells"
            and numeric and count > 0, "mapped-cell count unavailable or not a positive integer")
    compatibility = checkpoint["validation"]["manifest"]["compatibility"]
    return dict(metric=dict(key=METRIC, value=int(count), unit="cells", source=metric["source"]),
                checkpoint=checkpoint["reference"], plan_identity=plan_identity,
                bundle_identity=methodology["bundle_identity"],
                effective_parameters=methodology["effective_parameters"],
                runtime=dict(image=compatibility["binding"]["image_identity"]["image_id"],
                             bridge_sha256=compatibility["bridge_sha256"],
                             requested_tools=compatibility["requested_tools"],
                             target=compatibility["target"]))


def inspect_synthesis(project, *, provider, attempt, stream_id, plan_identity, selection, receipts, env=None,
                      record=None):
    """Inspect only the explicit observation allocated by the original launch."""
    project, provider, receipts, attempt = map(Path, (project, provider, receipts, attempt))
    with step("inspect inputs"):
        require(provider.is_absolute() and attempt.is_absolute() and bool(stream_id) and bool(plan_identity),
                "expected explicit provider, observation, stream and preview identity")
    env = command_env(env)
    if record:
        record("observe")
    observed = query("observe", [provider, "observation", "inspect", attempt, "--json"], project, receipts, env)
    with step("observe"):
        require(observed["contract"] == "hardcaml-asic.stage-observation"
                and observed["schema_version"] == 2 and observed["stream_id"] == stream_id,
                "unexpected observation contract or stream")
        outcome = observed["state"]["outcome"]
        require(observed["observation_status"] == "final" and observed["writer_active"] is False
                and outcome["status"] == "completed" and outcome["exit_code"] == 0,
                "observation did not complete")
        execution = observed["execution_file"]
        require(execution and Path(execution).is_absolute(), "no explicit execution file in observation")
        runtime_roots = canonical_tool_paths(observed["execution_request"])
    if record:
        record("report")
    report = query("report", [provider, "report", execution, "--json"], project, receipts, env)
    with step("report"):
        result = read_metric(report, execution=execution, stream_id=stream_id, plan_identity=plan_identity,
                             selection=selection, observed_methodology=observed["methodology"])
        reference = report["methodology"]["reference"]
        frozen = Path(reference["snapshot_path"]).read_bytes()
        require(hashlib.sha256(frozen).hexdigest() == reference["snapshot_sha256"],
                "retained preview snapshot changed after report validation")
        plan = json.loads(frozen)
        manifest = json.loads(plan["bundle_manifest"])
        require(plan["plan_identity"] == plan_identity
                and manifest["identity"] == result["bundle_identity"], "retained bundle identity mismatch")
        design_inputs = {entry["path"]: entry["sha256"] for entry in manifest["source_inputs"]}
        bundle_inputs = {entry["path"]: entry["sha256"] for entry in manifest["files"]}
        require(bool(design_inputs) and bool(manifest["synthesis_sources"]), "bundle lacks synthesis inputs")
        synthesis_inputs = {path: bundle_inputs[path]
                            for path in {*manifest["synthesis_sources"], "constraints/top.sdc", "src/config.json"}}
        with provider.open("rb") as source:
            provider_digest = hashlib.file_digest(source, "sha256").hexdigest()
        return dict(**result, project=str(project.resolve()), attempt=str(attempt), stream_id=stream_id,
                    execution_file=execution, runtime_roots=runtime_roots, provider_sha256=provider_digest,
                    selection=normalized_selection(selection), design_inputs=design_inputs,
                    synthesis_inputs=synthesis_inputs, source_revision=manifest["source_revision"])


def canonical_tool_paths(paths):
    roots = {key: Path(paths[key]) for key in ("support_tools", "pdk_root", "python")}
    require(all(path.is_absolute() for path in roots.values()), "missing absolute tool roots")
    # Do not follow the interpreter symlink itself; that would bypass its venv.
    return {key: str(path.resolve() if key != "python" else path.parent.resolve() / path.name)
            for key, path in roots.items()}


def normalized_selection(selection):
    return dict(**{key: selection[key] for key in ("chip", "variant", "flow", "profile", "endpoint")},
                assignments=list(selection.get("assignments", ())))


def compare_synthesis(original, replay):
    with step("compare synthesis"):
        require(original["project"] != replay["project"] and original["attempt"] != replay["attempt"]
                and original["stream_id"] != replay["stream_id"]
                and original["execution_file"] != replay["execution_file"],
                "replay must be an independently allocated run at a different path")
        for field in ("selection", "provider_sha256", "runtime_roots", "runtime", "effective_parameters",
                      "design_inputs", "synthesis_inputs"):
            require(original[field] == replay[field], f"non-comparable {field}")
        old, new = original["metric"], replay["metric"]
        require((old["key"], old["unit"]) == (new["key"], new["unit"]) == (METRIC, "cells"),
                "measurements do not use the same mapped-cell metric")
        require(old["value"] == new["value"],
                f"mapped-cell count changed: Silver {old['value']}, replay {new['value']}")
        return dict(key=METRIC, unit="cells", silver=old["value"], replay=new["value"], equal=True)


def replay_synthesis(snapshot, clone, *, provider, toolchain, selection, baseline, receipts, fixture_commit,
                     env=None, timeout=900, record=None):
    """Run documented ``flow plan`` / ``flow emit`` / ``stages`` in a clean clone."""
    with step("replay inputs"):
        clone = Path(os.path.abspath(clone))
        provider, toolchain, receipts = map(Path, (provider, toolchain, receipts))
        receipts = receipts.resolve(strict=True)
        selection = normalized_selection(selection)
        require(provider.is_absolute() and toolchain.is_absolute() and timeout > 0,
                "expected absolute tool paths and positive timeout")
        require(selection["endpoint"] == "synthesis" and baseline["selection"] == selection
                and Path(baseline["project"]) == snapshot.source, "baseline does not match this starter or selection")
        require(fixture_commit and fixture_commit == baseline["source_revision"],
                "fixture commit did not produce the original synthesis")
        roots = canonical_tool_paths(dict(support_tools=toolchain / "tt", pdk_root=toolchain / "pdk",
                                          python=toolchain / ".venv/bin/python"))
        require(roots == baseline["runtime_roots"], "different tools from the Silver run")
        require(not any(Path(path).is_relative_to(snapshot.source) for path in roots.values()),
                "toolchain dependencies must be outside the original project")
        executable = target_executable(json.loads(dict(snapshot.files)[CATALOG]), selection["chip"])
        inventory = dict(snapshot.files)
        require(bool(baseline["design_inputs"]) and all(
            hashlib.sha256(inventory[path]).hexdigest() == digest for path, digest in baseline["design_inputs"].items()
        ), "Silver execution design inputs differ from the captured starter")
    env = command_env(env)
    record = record or (lambda _: None)
    record("clean source clone")
    source = clone_starter(snapshot, clone, receipts, env, fixture_commit=fixture_commit)
    record("build")
    run("build", ["dune", "build", "--root", clone, "--build-dir", "_build", "--cache=disabled",
                  "-j", "1", executable], clone, receipts, env)
    cli = clone / "_build/default" / executable
    args = ["--source-root", clone, "--json"]
    for field in ("chip", "variant", "flow", "profile", "endpoint"):
        args += ["--" + field, selection[field]]
    for assignment in selection["assignments"]:
        args += ["--set", assignment]
    record("plan")
    plan = query("plan", [cli, "flow", "plan", *args], clone, receipts, env)
    with step("plan"):
        expected = plan["plan_identity"]
        require(bool(expected) and bool(plan["bundle_identity"]), "plan did not return named identities")
    results = receipts / "results"
    record("emit")
    emitted = query("emit", [cli, "flow", "emit", *args, "--expected-plan-identity", expected,
                             "--results-root", results], clone, receipts, env)
    with step("emit"):
        require(emitted["kind"] == "bundle_emission" and emitted["reused"] is False
                and emitted["plan_identity"] == expected and emitted["plan"] == plan
                and emitted["bundle_identity"] == plan["bundle_identity"], "emission did not match fresh preview")
        bundle = Path(emitted["output_dir"])
        require(bundle.is_absolute() and bundle.resolve(strict=True).is_relative_to(results),
                "emission escaped replay results")
        plan_file = receipts / "methodology-plan.json"
        save_json(plan_file, plan)
    workspace = results / "workspace"
    record("synthesize")
    output = run("synthesize", [provider, "stages", bundle, "--methodology-plan", plan_file,
                                "--expected-plan-identity", expected, "--workspace", workspace,
                                "--checkpoint-store", workspace / "checkpoints",
                                "--support-tools", roots["support_tools"], "--pdk-root", roots["pdk_root"],
                                "--python", roots["python"], "--json"], clone, receipts, env, timeout)
    with step("synthesize"):
        messages = [json.loads(line) for line in output.read_bytes().splitlines()]
        allocation, terminal = messages
        require(allocation["contract"] == "hardcaml-asic.stage-observation"
                and allocation["event"] == "observation_allocated", "missing allocation receipt")
        attempt, stream = Path(allocation["attempt"]), allocation["stream_id"]
        require(attempt.is_absolute() and attempt.resolve(strict=True).is_relative_to(results),
                "observation escaped replay results")
        require(terminal["attempt_id"] == stream and terminal["status"] == "completed"
                and terminal["exit_code"] == 0 and terminal["execution_file"],
                "CLI did not deliver a completed execution for its allocation")
    replay = inspect_synthesis(clone, provider=provider, attempt=attempt, stream_id=stream,
                              plan_identity=expected, selection=selection, receipts=receipts, env=env, record=record)
    with step("report"):
        require(replay["execution_file"] == terminal["execution_file"]
                and Path(replay["execution_file"]).resolve(strict=True).is_relative_to(workspace)
                and replay["bundle_identity"] == emitted["bundle_identity"]
                and replay["source_revision"] == source["fixture_commit"],
                "execution evidence does not match the replay launch")
    record("compare synthesis")
    comparison = compare_synthesis(baseline, replay)
    return dict(source=source, run=replay, comparison=comparison)
