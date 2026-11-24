"""Literal palette aliases through the native client and recorded provider."""
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import argparse
import json
import os
import re

from test_chip_contexts_pty import (
    FIFO, MEM, Session, field, selected_row, setup, type_palette_query,
)
from test_checklist_defaults_pty import Terminal, calls, wait

STAGES = ["synthesis", "floorplan", "placement", "cts", "routing", "timing", "signoff"]


def exercise(client, daemon, base):
    root, tools = base / "project", base / "tools"
    setup(root, tools)
    for target, endpoints in [(FIFO, STAGES), (MEM, ["synthesis"])]:
        path = root / (target[0] + ".json")
        catalog = json.loads(path.read_text())
        catalog["declaration"]["entries"][0]["methodology"]["endpoints"] = endpoints
        path.write_text(json.dumps(catalog))
    session = Session(SimpleNamespace(client=client, daemon=daemon, outer_timeout=20), base, root)
    session.env["PATH"] = str(tools) + ":" + session.env["PATH"]
    chip, variant, profile = FIFO
    flow = chip + "-flow"

    def snapshot():
        return session.rpc("asic")

    def workflows():
        return field(snapshot(), "workflows")

    def provider_launches():
        return [a for a in calls(root / "physical-calls") if a[:1] == ["stages"]]

    def emissions():
        return [e["argv"] for e in calls(root / "events.jsonl") if e["kind"] == "emit-start"]

    def discoveries():
        return [a for a in calls(root / "project-calls") if a[:2] == ["flow", "list"]]

    def selected_run():
        ws = session.rpc("workspace")
        main, = (c for c in field(ws, "contexts") if field(c, "id") == field(ws, "main_context"))
        return field(main, "selected_run")

    def blocked_enter(term, query, reason, label):
        os.write(term.master, b"\r")
        # Enter must leave the explained-but-disabled command in the palette.
        # The caller also checks the daemon and provider for side effects.
        term.capture(label, ["COMMAND PALETTE", f"> {query}▏", reason])
        os.write(term.master, b"\x1b")
        term.capture(label + "-dismissed", ["Overview"], absent=["COMMAND PALETTE"])

    def pick_chip(term, target):
        row = selected_row(term, "chip", f"picker-command-{target[0]}")
        assert "Select Launch Target" in row, row
        before = len(discoveries())
        os.write(term.master, b"\r")
        screen = term.capture(f"picker-{target[0]}", [
            "COMMAND PALETTE", "Select launch target: fifo / deep",
            "Select launch target: program_memory / rom",
        ], absent=["Launch synthesis and view", "Discover ASIC flows and runs"])
        assert re.search(r"│ > ▏", screen), screen
        assert len(discoveries()) == before
        assert not provider_launches() and not emissions() and not workflows()
        label = f"{target[0]} / {target[1]}"
        row = type_palette_query(term, target[0], f"picker-selected-{target[0]}")
        assert f"Select launch target: {label}" in row, row
        os.write(term.master, b"\r")
        term.capture(f"picker-closed-{target[0]}", ["Overview"], absent=["COMMAND PALETTE"])
        wait(term, lambda: len(discoveries()) > before, f"Picker did not discover {label}")
        assert len(discoveries()) == before + 1, discoveries()
        argv = discoveries()[-1]
        assert [argv[argv.index(flag) + 1] for flag in ("--chip", "--variant")] == list(target[:2])

        def loaded():
            current = snapshot()
            return (field(current, "chip_target") == [[["chip", target[0]], ["variant", target[1]]]]
                    and [field(flow, "id") for flow in field(current, "flows")] == [target[0] + "-flow"])

        wait(term, loaded, f"Picker did not select and load {label}")
        term.capture(f"selected-target-{target[0]}", ["available to launch"])
        assert not provider_launches() and not emissions() and not workflows()

    def check_selection(intent, endpoint):
        selection = field(intent, "selection")
        assert dict(selection) == dict(flow=flow, profile=profile, endpoint=endpoint,
                                       assignments=[], chip_target=[[["chip", chip],
                                                                     ["variant", variant]]])
        assert field(intent, "elaboration_only") == "false"

    def stage_cts(term):
        previous = field(snapshot(), "fresh_intent")
        term.palette(f"Plan ASIC {flow} / {profile}")
        screen = term.capture("plan-form", ["PLAN ENDPOINT"])
        prompt, = re.findall(r"> (synthesis|cts)\s*▏", screen)
        os.write(term.master, b"\x7f" * len(prompt) + b"cts")
        term.capture("plan-cts", ["> cts▏"])
        os.write(term.master, b"\r")
        term.capture("staged-cts", ["ready: Fresh input intent", "endpoint: cts"],
                     absent=["PLAN ENDPOINT"])
        intent, = field(snapshot(), "fresh_intent")
        assert [intent] != previous, intent
        check_selection(intent, "cts")
        return field(intent, "id")

    def launch(term, query, endpoint, recipe, *, staged_id=None, in_view=False):
        before = {field(w, "id") for w in workflows()}
        old_run = selected_run()
        row = selected_row(term, query, f"selected-{query}-{len(before)}")
        assert all(s in row for s in (f"{chip}/{variant}", flow, profile, f"→ {endpoint}")), row
        if endpoint == "synthesis":
            assert not re.search(r"\bcts\b", row, re.I), row

        os.write(term.master, b"\r")  # No Tab, extra text, or confirmation.
        term.capture("dispatched-" + query, ["Overview"], absent=["COMMAND PALETTE", "PLAN ENDPOINT"])

        def completed():
            new = [w for w in workflows() if field(w, "id") not in before]
            if not new:
                return False
            workflow, = new
            phase = field(workflow, "phase")
            assert phase not in ("Failed", "Cancelled", "Interrupted"), workflow
            if phase == "Completed":
                return workflow
            return False

        wait(term, completed, f"{query!r} did not complete a native provider launch")
        workflow = completed()
        intent = field(workflow, "intent")
        check_selection(intent, endpoint)
        if staged_id is not None:
            assert field(intent, "id") == staged_id
        assert len(emissions()) == len(provider_launches()) == len(before) + 1
        argv = emissions()[-1]
        assert [argv[argv.index(flag) + 1] for flag in
                ("--chip", "--variant", "--flow", "--profile", "--endpoint")] == [
                    chip, variant, flow, profile, endpoint], argv
        argv = provider_launches()[-1]
        plan = json.loads(Path(argv[argv.index("--methodology-plan") + 1]).read_text())
        assert plan["methodology"]["recipe"]["stages"] == recipe, plan
        if in_view:
            run = field(workflow, "run")
            assert run and run != old_run
            wait(term, lambda: selected_run() == run, f"{query!r} did not put its new run in view")
        return field(intent, "id")

    try:
        session.start()
        with closing(Terminal(session)) as term:
            term.capture("ready", ["Connection: connected", "available to launch"])
            assert not field(snapshot(), "fresh_intent") and not workflows()
            pick_chip(term, MEM)
            before_discovery = len(discoveries())
            row = selected_row(term, "cts", "unsupported-cts-row")
            assert "Launch cts and view" in row and "Unsupported fresh endpoint" in row, row
            blocked_enter(term, "cts", "Unsupported fresh endpoint", "unsupported-cts")
            assert not field(snapshot(), "fresh_intent") and not workflows()
            assert not provider_launches() and not emissions()
            assert len(discoveries()) == before_discovery
            assert not (root / "build-calls").exists()
            pick_chip(term, FIFO)
            before_discovery = len(discoveries())
            assert before_discovery > 0
            row = selected_row(term, "a launch", "selected-no-staged-plan")
            assert "No staged plan" in row, row
            blocked_enter(term, "a launch", "No staged plan", "no-staged-plan")
            assert not field(snapshot(), "fresh_intent") and not workflows()
            assert not provider_launches() and not emissions()
            assert len(discoveries()) == before_discovery
            assert not (root / "build-calls").exists()

            launch(term, "synth", "synthesis", ["synthesis"], in_view=True)
            cts = stage_cts(term)
            launch(term, "a launch", "cts", ["synthesis", "floorplan", "placement", "cts"],
                   staged_id=cts)
            cts = stage_cts(term)
            assert launch(term, "synth", "synthesis", ["synthesis"], in_view=True) != cts
            for end, stage in enumerate(STAGES, 1):
                launch(term, stage, stage, STAGES[:end], in_view=True)
            assert len(discoveries()) == before_discovery

            row = selected_row(term, "synth rows", "selected-discovery")
            assert "discover" in row.lower(), row
            os.write(term.master, b"\r")
            wait(term, lambda: len(discoveries()) > before_discovery,
                 "synth rows did not reach the project's discovery provider")
            term.capture("discovery-dispatched", ["Overview"], absent=["COMMAND PALETTE"])
            assert len(discoveries()) == before_discovery + 1, discoveries()
            assert len(workflows()) == len(provider_launches()) == len(emissions()) == 3 + len(STAGES)
    finally:
        session.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument("--daemon", type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence:
        args.evidence.mkdir()
        exercise(args.client, args.daemon, args.evidence.resolve())
    else:
        with TemporaryDirectory(prefix="palette-aliases-") as tmp:
            exercise(args.client, args.daemon, Path(tmp))
