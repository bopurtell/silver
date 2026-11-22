"""Stop a UI-launched Timing workflow from its originating view, without browsing runs."""
from contextlib import closing
import argparse
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from test_checklist_defaults_pty import Terminal, calls, equipment, wait
from test_chip_contexts_pty import Session, dismiss, field, selected_row


def exercise(client, daemon, base, scenario, query):
    base.mkdir()
    root, tools = base / "project", base / "tools"
    root.mkdir()
    tools.mkdir()
    (root / "dune-project").write_text("(lang dune 3.22)\n")
    equipment(root, tools, [("controlled_fifo", "default"), ("program_memory", "rom")])
    path = root / "controlled_fifo.json"
    catalog = json.loads(path.read_text())
    catalog["declaration"]["entries"][0]["methodology"]["endpoints"] = ["timing"]
    path.write_text(json.dumps(catalog))
    if scenario == "building":
        dune = tools / "dune"
        dune.write_text(dune.read_text().replace(
            "echo build >> build-calls", "echo build >> build-calls\n       exec sleep 30"))
    elif scenario == "physical-unallocated":
        provider = root / "physical"
        provider.write_text(provider.read_text().replace(
            '    save()\n    emit(env("stage-observation", event="observation_allocated"',
            '    time.sleep(30)\n    save()\n    emit(env("stage-observation", event="observation_allocated"'))
    else:
        (root / "hold-physical").touch()

    session = Session(SimpleNamespace(client=client, daemon=daemon, outer_timeout=20), base, root)
    session.env.update(PATH=str(tools) + ":" + session.env["PATH"],
                       XDG_CONFIG_HOME=str(base / "config"), XDG_CACHE_HOME=str(base / "cache"))

    def workflow():
        workflows = field(session.rpc("asic"), "workflows")
        return workflows[0] if workflows else None

    def watched():
        ws = session.rpc("workspace")
        context, = [c for c in field(ws, "contexts")
                    if field(c, "id") == field(ws, "main_context")]
        return field(context, "selected_run")

    try:
        session.start()
        with closing(Terminal(session, width=250, height=48)) as term:
            term.capture("ready", ["Connection: connected", "available to launch"])
            # On the run selector with no selection, the old resolver deliberately
            # cannot derive an inspected run, even though this is the launch origin.
            for _ in range(20):
                if "overview › run selector" in term.drain(.15).casefold():
                    break
                os.write(term.master, b"\t")
            term.capture("origin", ["Overview › run selector"])
            assert not workflow() and not watched()

            row = selected_row(term, "quick launch timing", "timing-command")
            assert ("Launch timing and view" in row or "Run in view" in row), row
            assert "controlled_fifo/default" in row, row
            os.write(term.master, b"\r")
            phase = "Building" if scenario == "building" else "Physical"
            wait(term, lambda: workflow() and field(workflow(), "phase") == phase,
                 f"Timing workflow did not reach {phase}")
            w = workflow()
            selection = field(field(w, "intent"), "selection")
            assert field(selection, "endpoint") == "timing", selection
            assert field(selection, "chip_target") == [
                [["chip", "controlled_fifo"], ["variant", "default"]]], selection
            if scenario == "physical-allocated":
                wait(term, lambda: field(workflow(), "run"), "Timing run never allocated")
                wait(term, lambda: watched() == field(workflow(), "run"),
                     "Launch-and-view never selected the allocated Timing run")
            else:
                assert not watched() and not field(workflow(), "run")
                if scenario == "physical-unallocated":
                    wait(term, lambda: any(a[:1] == ["stages"]
                                           for a in calls(root / "physical-calls")),
                         "Physical producer did not enter the pre-allocation hold")

            # The UI poll and the above API poll are independent. The first matching
            # row must be viewed-flow, not the explicit workflow command or bulk.
            prefix = "Cancel — controlled_fifo-flow · "
            wanted = prefix + field(w, "key")
            for attempt in range(8):
                row = selected_row(term, query, f"stop-{scenario}-{attempt}")
                painted = row.split(" · stop viewed ASIC flow", 1)[0].rstrip()
                if len(painted) > len(prefix) and wanted.startswith(painted):
                    break
                dismiss(term)
            else:
                raise AssertionError(
                    f"{scenario}, workflow {field(w, 'id')}, watched {watched()!r}: {row}")
            os.write(term.master, b"\r")
            wait(term, lambda: field(workflow(), "phase") == "Cancelled",
                 f"Stop did not cancel exact workflow {field(w, 'id')}")
            assert field(workflow(), "id") == field(w, "id")
            assert field(workflow(), "cancel_requested") == "true"
            if scenario != "physical-allocated":
                assert not watched()
            if scenario == "building":
                assert not any(a[:1] == ["stages"] for a in calls(root / "physical-calls"))
            print(f"{scenario}: {query} stopped {field(w, 'id')} (watched={bool(watched())})")
    finally:
        session.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", type=Path, required=True)
    parser.add_argument("--daemon", type=Path, required=True)
    scenarios = ["building", "physical-unallocated", "physical-allocated"]
    parser.add_argument("--scenario", choices=scenarios)
    parser.add_argument("--query", choices=("cancel", "stop"), default="cancel")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="quick-timing-cancel-") as tmp:
        for scenario in [args.scenario] if args.scenario else scenarios:
            exercise(args.client.resolve(), args.daemon.resolve(), Path(tmp) / scenario,
                     scenario, args.query)
