"""WB-081: real terminal, durable contexts and an instrumented fresh-build provider."""
from contextlib import closing, contextmanager
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import argparse
import json
import os
import runpy

from test_checklist_defaults_pty import ROOT, Terminal, calls, equipment, wait

fs = runpy.run_path(str(ROOT / "scripts/test-native-execution.py"))
Session, sexp, field = (fs[k] for k in ("Session", "sexp", "field"))
FIFO = ("fifo", "deep", "fast")
MEM = ("program_memory", "rom", "small")
NAMED = "Launch synthesis and view"


def setup(root, tools):
    root.mkdir()
    tools.mkdir()
    (root / "dune-project").write_text("(lang dune 3.22)\n")
    equipment(root, tools, [FIFO[:2], MEM[:2]])
    for chip, _, profile in (FIFO, MEM):
        p = root / (chip + ".json")
        p.write_text(p.read_text().replace(chip + "-default", profile))


def dismiss(term):
    os.write(term.master, b"\x1b")
    term.drain(.2)


def selected_row(term, query, label):
    for key in (b" ", b"c", b"c"):
        os.write(term.master, key)
        term.drain(.12)
    return type_palette_query(term, query, label)


def type_palette_query(term, query, label):
    os.write(term.master, query.encode())
    # A matching query line and an unselected matching row are both false positives.
    screen = term.capture(label, ["COMMAND PALETTE", "> " + query + "▏"])
    lines = screen.splitlines()
    header = next(i for i, line in enumerate(lines) if "COMMAND PALETTE" in line)
    left = lines[header].rindex("╭", 0, lines[header].index("COMMAND PALETTE"))
    right = lines[header].index("╮", left)
    rows = []
    for line in lines[header + 2:]:
        if line[left:left + 1] == "╰":
            break
        if line[left:].startswith("│ > "):
            rows.append(line[left + 4:right])
    assert len(rows) == 1, screen
    return rows[0]


def exercise(client, daemon, base):
    root, tools = base / "project", base / "tools"
    setup(root, tools)
    source = {p: p.read_bytes() for p in root.iterdir() if p.is_file()}
    session = Session(SimpleNamespace(client=client, daemon=daemon, outer_timeout=20), base, root)
    session.env.update(PATH=str(tools) + ":" + os.environ["PATH"])

    @contextmanager
    def open_project():
        try:
            session.start()
            with closing(Terminal(session)) as term:
                term.capture("ready", ["Connection: connected"])
                yield term
        finally:
            session.stop()

    def ctx(workspace):
        ws = session.rpc("workspace")
        w, = (w for w in field(ws, "workspaces") if field(w, "name") == workspace)
        c, = (c for c in field(ws, "contexts") if field(c, "id") == field(w, "context"))
        return ws, w, c

    def inspect(workspace, run):
        ws, w, c = ctx(workspace)
        session.mutate(ws, sexp(["Select_run", ["workspace", field(w, "id")],
                                ["context", field(c, "id")],
                                ["expected_selection_revision", field(c, "selection_revision")],
                                ["run", [run]]]))

    def read_asic(workspace):
        ws, _, c = ctx(workspace)
        op = ("Get" if field(c, "id") == field(ws, "main_context") else
              sexp(["In_context", ["context", field(c, "id")],
                    ["initial_target", []], ["operation", "Get"]]))
        return session.rpc("asic", op)

    def stages():
        return [a for a in calls(root / "physical-calls") if a[0] == "stages"]

    def emissions():
        return [e["argv"] for e in calls(root / "events.jsonl") if e["kind"] == "emit-start"]

    def check_submission(term, target, before):
        chip, variant, profile = target
        wait(term, lambda: len(stages()) >= before + 1, "No fresh provider launch")
        assert len(stages()) == len(emissions()) == before + 1
        argv = emissions()[-1]
        assert argv[:2] == ["flow", "emit"]
        assert [argv[argv.index(flag) + 1] for flag in
                ("--chip", "--variant", "--flow", "--profile", "--endpoint")] == [
                    chip, variant, chip + "-flow", profile, "synthesis"], argv
        physical = stages()[-1]
        plan = json.loads(Path(physical[physical.index("--methodology-plan") + 1]).read_text())
        assert plan["methodology"]["recipe"]["stages"] == ["synthesis"]
        assert plan["methodology"]["snapshot"]["selected"] == dict(flow=chip+"-flow", profile=profile)
        receipt = [e for e in calls(root / "events.jsonl") if e["kind"] == "emit-finished"][-1]
        assert receipt["plan_identity"] == plan["plan_identity"]

    def pick(term, target):
        term.palette(f"Select launch target: {target[0]} / {target[1]}")

    def check_row(term, target, query=NAMED):
        row = selected_row(term, query, "before-enter-" + target[2])
        assert all(token in row for token in ("/".join(target[:2]), target[2],
                                              "synthesis", "view")), row

    with open_project() as term:
        term.capture("default", ["available to launch"])
        # Seed real historical FIFO evidence independently of the actions under test.
        target = [["chip", FIFO[0]], ["variant", FIFO[1]]]
        selection = [["flow", "fifo-flow"], ["profile", FIFO[2]], ["endpoint", "synthesis"],
                     ["assignments", []], ["chip_target", [target]]]
        def stage():
            result = session.rpc("asic", sexp(["Stage_fresh", ["selection", selection],
                                 ["elaboration_only", "false"], ["expected_plan_identity", []]]))
            return field(field(result, "fresh_intent")[0], "id")
        session.rpc("asic", sexp(["Launch_fresh", ["key", "historical-fifo"], ["intent_id", stage()]]))
        check_submission(term, FIFO, 0)
        def historical():
            return next((w for w in field(session.rpc("asic"), "workflows")
                         if field(w, "key") == "historical-fifo" and field(w, "phase") == "Completed"), None)
        wait(term, historical, "Historical FIFO run did not complete")
        run, = field(historical(), "run")
        inspect("Overview", run)
        assert field(ctx("Timing")[2], "selected_run") == [run]

        staged = stage()
        term.palette("Switch to Timing")
        # Still linked: changing Timing changes Main, and invalidates its staged plan.
        pick(term, MEM)
        term.palette("Switch to Overview")
        check_row(term, MEM)
        dismiss(term)
        term.palette("Launch planned run without view")
        screen = term.capture("stale-explanation", ["COMMAND PALETTE", "> Launch planned run without view"])
        assert any(s in screen.lower() for s in ("no staged plan", "no preview", "stale", "target changed",
                                                 "variant changed", "plan again")), screen
        dismiss(term)
        # Submit the *exact* prior ID too; the UI disabling its row is not
        # sufficient if the service will still honor a delayed stale request.
        response = session.command(["--api", "--asic-operation", sexp(["Launch_fresh",
                                   ["key", "stale-fifo"], ["intent_id", staged]])],
                                   "stale-intent", success=False)
        reply = fs["parse"](response.stdout.decode())
        assert reply[0] == "Error" and any(word in str(reply).lower()
                for word in ("stale", "superseded", "no current", "stage again")), reply
        assert len(stages()) == len(emissions()) == 1

        term.palette("Switch to Timing")
        term.palette("Make workspace independent")
        assert field(ctx("Timing")[2], "id") != field(ctx("Overview")[2], "id")
        check_row(term, MEM)
        dismiss(term)
        term.palette("Switch to Overview")
        pick(term, FIFO)
        # Retarget only on the explicit action; it reads the historical run even
        # though Timing currently intends to launch program memory.
        term.palette("Switch to Timing")
        check_row(term, MEM)
        dismiss(term)
        term.palette("Use this run's chip/variant as launch target")
        check_row(term, FIFO)
        dismiss(term)
        pick(term, MEM)
        for i, (workspace, target) in enumerate([("Overview", FIFO), ("Timing", MEM)], 1):
            term.palette("Switch to " + workspace)
            for name in ("Overview", "Timing"):
                assert field(ctx(name)[2], "selected_run") == [run]
            check_row(term, target, "synth")
            assert len(stages()) == len(emissions()) == i
            os.write(term.master, b"\r")
            check_submission(term, target, i)
            wait(term, lambda: field(ctx(workspace)[2], "selected_run") not in ([], [run]),
                 "Launch-and-view did not select its fresh result")
            if workspace == "Overview":
                inspect(workspace, run)
                # The registry mutation is acknowledged before the next terminal
                # poll. Wait for that revision before opening a captured palette.
                wait(term, lambda: any("Run:" in line and field(run, "id")[-4:] in line
                                       for line in term.drain(.1).splitlines()),
                     "Terminal did not return to the historical FIFO run")
        assert len(stages()) == len(emissions()) == 3
        def completed_selections():
            runs = field(session.rpc("asic"), "runs")
            if len(runs) != 3 or any(field(r, "status").lower() != "completed" for r in runs):
                return False
            def identity(r):
                s, = field(r, "selection")
                t, = field(s, "chip_target")
                return field(t, "chip"), field(t, "variant"), field(s, "profile")
            actual = [identity(r) for r in runs]
            assert sorted(actual) == sorted([FIFO, FIFO, MEM]), actual
            assert identity(next(r for r in runs if field(r, "run") == run)) == FIFO
            return True
        wait(term, completed_selections, "Missing completed, correctly associated submissions")

    assert all(p.read_bytes() == contents for p, contents in source.items())
    catalog = root / "chips.json"
    # Neither saved pair is now a default. A fresh client must recover both
    # exact variants, even if a catalog refresh changed its suggested variant.
    saved = json.loads(catalog.read_text())
    for chip in saved["chips"]:
        chip["default_variant"] = "different"
        chip["variants"].append(dict(id="different", label="different"))
    catalog.write_text(json.dumps(saved))
    with open_project() as term:
        for workspace, target in [("Overview", FIFO), ("Timing", MEM)]:
            term.palette("Switch to " + workspace)
            wait(term, lambda: field(read_asic(workspace), "flows"), "Catalog not restored")
            check_row(term, target)
            dismiss(term)
    mem = next(chip for chip in saved["chips"] if chip["id"] == MEM[0])
    mem["variants"] = [v for v in mem["variants"] if v["id"] != MEM[1]]
    catalog.write_text(json.dumps(saved))
    with open_project() as term:
        term.palette("Switch to Timing")
        def missing_pair():
            snapshot = read_asic("Timing")
            diagnosis = f"Saved chip/variant {MEM[0]} / {MEM[1]} is missing; select a launch target explicitly"
            if not any(diagnosis in message for op in field(snapshot, "operations")
                       for message in field(op, "error")):
                return False
            saved, = field(snapshot, "chip_target")
            assert dict(saved) == dict(chip=MEM[0], variant=MEM[1])
            assert not field(snapshot, "flows")
            return True
        wait(term, missing_pair, "Absent saved variant silently substituted")
        term.palette(NAMED)
        term.capture("missing", ["> " + NAMED + " — missing " + "/".join(MEM[:2]) + "; select chip target"])
        assert len(emissions()) == len(stages()) == 3
        dismiss(term)
        pick(term, (MEM[0], "different"))
        check_row(term, (MEM[0], "different", MEM[2]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", type=lambda s: Path(s).absolute(), required=True)
    parser.add_argument("--daemon", type=lambda s: Path(s).absolute(), required=True)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence:
        args.evidence.mkdir()
        exercise(args.client, args.daemon, args.evidence)
    else:
        with TemporaryDirectory(prefix="chip-contexts-") as tmp:
            exercise(args.client, args.daemon, Path(tmp))
