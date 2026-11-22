"""Short prepared-flow fixture with CLI4 observation cursors and staged cleanup."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def envelope(kind, version=1, **fields):
    return dict(contract="hardcaml-asic." + kind, schema_version=version, **fields)


def atomic(path, data):
    pending = path.with_suffix(".pending")
    pending.write_text(json.dumps(data))
    pending.replace(path)


def emit(data):
    print(json.dumps(data), flush=True)


def native_sta(path, execution):
    """Exact Timing analysis from the interrupted execution, not a checkpoint."""
    directory = path.parent.parent / "fixture-sta"

    def source(name):
        file = directory / name
        return dict(path=str(file), sha256=hashlib.sha256(file.read_bytes()).hexdigest())

    attempt = execution["attempt_id"]
    metrics = [
        dict(key=key, raw_key=raw + "__corner:slow", corner="slow",
             availability="available", value=value, unit=unit, reason=None,
             source=dict(file=source("slow/sta.log"), state=source("state_out.json"), line=1),
             units_source=source("slow/generated.lib") if unit == "ns" else None)
        for key, raw, value, unit in (
            ("setup_slack", "timing__setup__ws", 16., "ns"),
            ("hold_slack", "timing__hold__ws", .125, "ns"),
            ("setup_violations", "timing__setup_vio__count", 0, "count"),
            ("hold_violations", "timing__hold_vio__count", 0, "count"))
    ]
    provenance = ["config.json", "runtime.txt", "state_out.json", "slow/sta.log", "slow/generated.lib"]
    payload = envelope("timing-analysis", 2, attempt_id=attempt,
                       occurrence_id=attempt + "/implementation.timing",
                       analysis_id=attempt + "/post-pnr-sta", stage="timing",
                       execution_file=str(path), execution_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                       status="completed", reason=None, enclosing_status=execution["status"],
                       evidence_scope="immutable_timing_execution_source_not_checkpoint",
                       native_grammar="librelane-3.1.0.dev3-step-output-runtime-v1",
                       duration=dict(seconds=6.21, precision_seconds=.001, basis="librelane_step_wall_clock",
                                     source=source("runtime.txt")),
                       producer=dict(class_id="OpenROAD.STAPostPNR", directory=str(directory), config=source("config.json")),
                       inventory=[source(name) for name in provenance],
                       corners=[dict(corner="slow", status="measured", setup_goal="pass", hold_goal="pass")],
                       metrics=metrics, timing_goal="pass")
    return dict(payload, source_digest=hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest())


def produce(option):
    plan = json.loads(Path(option("--methodology-plan")).read_text())
    assert plan["plan_identity"] == option("--expected-plan-identity")
    recipe = plan["methodology"]["recipe"]
    assert recipe["stages"] == ["synthesis", "floorplan", "placement", "cts", "routing", "timing"]
    workspace = Path(option("--workspace"))
    attempt = workspace / "observation"
    attempt.mkdir(parents=True)
    stream = workspace.name
    execution_file = attempt / "execution.json"
    methodology = envelope("historical-methodology", state="recorded",
                           plan_identity=plan["plan_identity"], bundle_identity=plan["bundle_identity"],
                           reference=dict(attempt_id=stream))
    events, artifacts = [], []
    occurrences = {stage: dict(action_key="implementation." + stage,
                               occurrence_id=stream + "/implementation." + stage,
                               status="unreached", exit_code=None, duration_seconds=0,
                               error=None, best_effort=False, verdict=None)
                   for stage in recipe["stages"]}
    started = time.monotonic()

    def event(name, **data):
        events.append(envelope("stage-observation", 2, stream_id=stream, sequence=len(events) + 1,
                               event=name, data=data, recorded_at="2026-10-20T12:00:00.000000Z",
                               elapsed_seconds=time.monotonic() - started))

    def publish(outcome=None):
        execution = dict(attempt_id=stream, plan=recipe, occurrences=list(occurrences.values()),
                         artifacts=artifacts)
        if outcome:
            atomic(execution_file, dict(execution, **outcome))
        inspection = envelope("stage-observation", 2, stream_id=stream, cursor=len(events),
                              writer_active=outcome is None,
                              observation_status="active" if outcome is None else "final",
                              state=dict(execution, outcome=outcome), methodology=methodology,
                              execution_file=str(execution_file) if outcome else None)
        # A single atomic generation for both observations.
        atomic(attempt / "journal.json", dict(inspection=inspection, events=events))

    def occurrence(stage, name, status, exit_code, duration=0, error=None, artifact=None):
        current = dict(occurrences[stage], status=status, exit_code=exit_code,
                       duration_seconds=duration, error=error)
        occurrences[stage] = current
        event(name, occurrence=current, artifact=artifact)

    request = dict(expected_plan_identity=plan["plan_identity"],
                   methodology_launch=dict(attempt_id=stream, expected_plan_identity=plan["plan_identity"]))
    event("allocated", request=request, workspace=str(workspace))
    event("planned", plan=recipe)
    event("prepared", runtime_record=None)
    stopping_stage = "timing" if Path(__file__).with_name("stop-in-timing").exists() else "routing"
    for stage in recipe["stages"][:recipe["stages"].index(stopping_stage)]:
        checkpoint = workspace / (stage + "-checkpoint")
        checkpoint.write_text(stage)
        artifact = dict(boundary=stage, path=str(checkpoint), identity=hashlib.sha256(stage.encode()).hexdigest())
        artifacts.append(artifact)
        occurrence(stage, "started", "running", None)
        occurrence(stage, "published", "running", None, artifact=artifact)
        occurrence(stage, "finished", "completed", 0, duration=.125, artifact=artifact)

    stop = None

    def terminate(_signum, _frame):
        nonlocal stop
        stop = "SIGTERM"

    signal.signal(signal.SIGTERM, terminate)
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    (workspace / (stopping_stage + "-child")).write_text(str(child.pid))
    try:
        occurrence(stopping_stage, "started", "running", None)
        publish()
        emit(envelope("stage-observation", event="observation_allocated",
                      attempt=str(attempt), stream_id=stream))
        if stopping_stage == "timing":
            # Like the real attempt, STA finishes and publishes its own evidence
            # while the surrounding Timing segment is still owned and running.
            for name, data in (("config.json", "{}"), ("runtime.txt", "6.21"),
                               ("state_out.json", "{}"), ("slow/sta.log", "positive slack"),
                               ("slow/generated.lib", "time_unit : \"1ns\";")):
                file = workspace / "fixture-sta" / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(data)
            (workspace / "sta-finished").touch()
        deadline = time.monotonic() + 30
        while stop is None and not (workspace / "interrupt").exists() and time.monotonic() < deadline:
            time.sleep(.02)
        if stop is not None:
            (workspace / "cleanup-entered").touch()
            deadline = time.monotonic() + 10
            while not (workspace / "cleanup-release").exists() and time.monotonic() < deadline:
                time.sleep(.02)
        error = ("backend execution interrupted" if stopping_stage == "timing"
                 else "Routing interrupted by " + (stop or "fixture producer"))
    finally:
        child.terminate()
        child.wait(timeout=2)
    (workspace / "cleanup-finished").touch()
    # Bare interruption can have the exact same SIGTERM status as user cancellation.
    exit_code = 143 if stop or stopping_stage == "timing" else 130
    occurrence(stopping_stage, "finished", "interrupted", exit_code,
               duration=time.monotonic() - started, error=error)
    outcome = dict(status="interrupted", exit_code=exit_code, error=error)
    event("outcome", **outcome)
    publish(outcome)
    emit(envelope("stage-observation", event="observation_terminal", execution_file=str(execution_file)))
    return outcome["exit_code"]


def main():
    args = sys.argv[1:]

    def option(flag):
        return args[args.index(flag) + 1]

    if args == ["--version", "--json"]:
        emit(dict(cli_contract=dict(version=4, capabilities=dict(namedflow1=True, timing_stage1=True))))
    elif args[:1] == ["stages"]:
        return produce(option)
    elif args[:1] == ["observation"]:
        generation = json.loads((Path(args[2]) / "journal.json").read_text())
        inspection = generation["inspection"]
        if args[1] == "inspect":
            emit(inspection)
        else:
            assert args[1] == "read-updates" and option("--stream-id") == inspection["stream_id"]
            after = int(option("--after"))
            emit(envelope("stage-observation", 2, stream_id=inspection["stream_id"], after=after,
                          cursor=inspection["cursor"], events=generation["events"][after:]))
    elif args[:1] == ["report"]:
        path = Path(args[1])
        inspection = json.loads((path.parent / "journal.json").read_text())["inspection"]
        execution = json.loads(path.read_text())
        report = envelope("report", execution=execution, methodology=inspection["methodology"],
                          checkpoints=[dict(reference=a) for a in execution["artifacts"]],
                          completion=dict(physical="partial"), acceptance="not_evaluated")
        if (path.parent.parent / "sta-finished").exists():
            report["timing_analysis"] = native_sta(path, execution)
        emit(report)
    else:
        raise ValueError(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
