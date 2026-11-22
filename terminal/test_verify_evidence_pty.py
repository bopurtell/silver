"""Verify retained run summaries through the real Silver terminal and daemon.

Two private historical attempts use the existing fake provider. A report gate
proves cached paint does not wait for the verifier, without a latency benchmark.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import sys
from tempfile import TemporaryDirectory
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "test"))
from support.terminal import Terminal

native = runpy.run_path(str(ROOT / "scripts/test-native-execution.py"))
Session, field, sexp, write_config = (
    native[k] for k in ("Session", "field", "sexp", "write_config")
)

BALANCED = "attempt-balanced"
DELAY = "attempt-synth_delay"
READS = (("observation", "read-updates"), ("observation", "inspect"), ("report",))


def prepare(base):
    root = base / "project"
    root.mkdir()
    (root / "dune-project").write_text("(lang dune 3.22)\n")
    fixture = ROOT / "backend/test/asic"
    for name in ("fake_provider.py", "production_flow_list.json"):
        shutil.copyfile(fixture / name, root / name)
    # Intercept only the read boundary. Never forward a producer request.
    wrapped = root / "provider"
    wrapped.write_text(f"#!{sys.executable}\n" + r"""
import json, os, sys, time
from pathlib import Path

args = sys.argv[1:]
with Path("provider-requests").open("a") as out:
    out.write(json.dumps(args) + "\n")
if args != ["--version", "--json"] and args[:2] not in (
    ["chip", "list"], ["flow", "list"], ["observation", "read-updates"],
    ["observation", "inspect"],
) and args[:1] != ["report"]:
    sys.exit("test guard: unexpected provider invocation")

if args[:1] == ["report"]:
    attempt = Path(args[1]).parent.name
    blocked = Path("block-" + attempt)
    if blocked.exists():
        Path("report-waiting-" + attempt).touch()
        end = time.monotonic() + 30
        while blocked.exists():
            if time.monotonic() >= end:
                sys.exit("test guard: report gate timed out")
            time.sleep(.025)
os.execv(sys.executable, [sys.executable, str(Path(__file__).with_name("fake_provider.py")), *args])
""")
    wrapped.chmod(0o700)
    write_config(root, wrapped, wrapped, base / "results")
    return root


def seed(session):
    runs = []
    for attempt, count in ((BALANCED, "50"), (DELAY, "73")):
        path = session.root / attempt
        path.mkdir()
        (path / "done").touch()
        reference = [["attempt", str(path)], ["stream_id", "stream-" + attempt.removeprefix("attempt-")]]
        result = session.rpc("asic", sexp(["Register", reference]))
        run, = (field(r, "run") for r in field(result, "runs") if field(r, "reference") == reference)
        session.rpc("asic", sexp(["Observe", run]), wait=True)
        loaded = session.rpc("asic", sexp(["Load_summary", run]), wait=True)
        summary, = (s for s in field(loaded, "summaries") if field(s, "run") == run)
        assert field(summary, "cell_count") == [count] and field(summary, "freshness") == "Validated", summary
        runs.append(run)

    ws = session.rpc("workspace")
    overview, = (w for w in field(ws, "workspaces") if field(w, "preset") == ["overview"])
    wid = field(overview, "id")
    cid = field(overview, "context")
    context, = (c for c in field(ws, "contexts") if field(c, "id") == cid)
    ws = session.mutate(ws, sexp(["Select_run", ["workspace", wid], ["context", cid],
                                  ["expected_selection_revision", field(context, "selection_revision")],
                                  ["run", [runs[0]]]]))
    # Two visible synthesis tiles: one follows the workspace; one is pinned.
    tiles = [t for t in field(ws, "tiles") if field(t, "workspace") == wid]
    following = next((field(t, "id") for t in tiles if field(t, "kind") == "synthesis"), None)
    if following is None:
        ws = session.mutate(ws, f'(Create_tile (workspace {sexp(wid)}) (kind synthesis)'
                            ' (geometry ((x 0) (y 8) (width 56) (height 14))))')
        following = field(field(ws, "tiles")[-1], "id")
    ws = session.mutate(ws, f'(Create_tile (workspace {sexp(wid)}) (kind synthesis)'
                        ' (geometry ((x 60) (y 8) (width 56) (height 14))))')
    pinned = field(field(ws, "tiles")[-1], "id")
    ws = session.mutate(ws, sexp(["Set_tile_binding", ["tile", pinned],
                                  ["binding", ["Pin_run", runs[1]]]]))
    return wid, following, pinned, runs


def wait(term, predicate, failure):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if result := predicate():
            return result
        term.drain(.15)
    raise AssertionError(f"{failure}\n{term.drain(0)}")


def exercise(client, daemon, base):
    root = prepare(base)
    session = Session(argparse.Namespace(client=client, daemon=daemon, outer_timeout=20), base, root)

    def requests():
        return [json.loads(line) for line in (root / "provider-requests").read_text().splitlines()]

    def check_reads(offset, *expected):
        observed = []
        for args in requests()[offset:]:
            if tuple(args[:2]) in READS:
                observed.append((tuple(args[:2]), Path(args[2]).name))
            elif tuple(args[:1]) in READS:
                observed.append((tuple(args[:1]), Path(args[1]).parent.name))
            else:
                assert args == ["--version", "--json"] or args[:2] in (
                    ["chip", "list"], ["flow", "list"]), args
        assert observed == [(read, attempt) for attempt, reads in expected for read in reads], observed

    def expect_operation(term, kind, run, state, freshness, count):
        def matching():
            snap = session.rpc("asic")
            key = kind + ":" + field(run, "id")
            op = next((o for o in field(snap, "operations") if field(o, "key") == key), None)
            s = next((s for s in field(snap, "summaries") if field(s, "run") == run), None)
            if not op or field(op, "state") != state or not s:
                return None
            assert field(op, "kind") == kind and field(op, "run") == [run], op
            assert field(op, "activity") == "Evidence_read", op
            actual = field(s, "freshness")
            assert (actual[0] if isinstance(actual, list) else actual) == freshness, s
            assert field(s, "cell_count") == [count], s
            return snap
        return wait(term, matching, f"Missing typed {state} {kind} for {run}")

    def verify_from_palette(term, label):
        for key in (b" ", b"c", b"c"):
            os.write(term.master, key)
            term.drain(.12)
        os.write(term.master, b"veri")
        term.capture(label + "-veri-selected",
                     [re.compile(r"COMMAND PALETTE[^\n]*\n[^\n]*> veri▏[^\n]*\n"
                                 r"[^\n]*│ > Verify evidence\b")])
        os.write(term.master, b"\r")  # No completion or movement to another row.
        term.capture(label + "-veri-dispatched", absent=["COMMAND PALETTE"])

    try:
        session.start()
        wid, following, pinned, (selected, other) = seed(session)
        session.stop()

        offset = len(requests())
        blocked = root / ("block-" + BALANCED)
        blocked.touch()
        session.start()
        try:
            before = session.rpc("workspace")
            with closing(Terminal(session, width=180)) as term:
                ready = root / ("report-waiting-" + BALANCED)
                wait(term, ready.exists, "Startup did not request the selected run's report")
                term.capture("retained-while-report-blocked",
                             ["Connection: connected", "Reported cells (agg.): 50 (cached/unverified)",
                              "Reported cells (agg.): 73 (cached/unverified)"])
                expect_operation(term, "validate-summary", selected, "executing", "Cached_unverified", "50")
                check_reads(offset, (BALANCED, READS[-1:]))
                blocked.unlink()
                snap = expect_operation(term, "validate-summary", selected, "completed", "Validated", "50")
                cached, = (s for s in field(snap, "summaries") if field(s, "run") == other)
                assert field(cached, "freshness") == "Cached_unverified", cached
                term.capture("selected-validated", ["Reported cells (agg.): 50",
                                                    "Reported cells (agg.): 73 (cached/unverified)"],
                             absent=["Reported cells (agg.): 50 (cached/unverified)"])
                ws = session.rpc("workspace")
                assert field(ws, "contexts") == field(before, "contexts"), "Startup verification changed selection"

                # Focus a pinned tile whose exact run differs from the workspace selection.
                zoomed = session.mutate(ws, sexp(["Set_zoom", ["workspace", wid], ["tile", [pinned]]]))
                term.capture("focused-pinned", ["Reported cells (agg.): 73"],
                             absent=["Reported cells (agg.): 50"])
                check_reads(offset, (BALANCED, READS[-1:]))
                (root / "revision").touch()  # Explicit Refresh may adopt a new report.
                verify_from_palette(term, "pinned")
                expect_operation(term, "refresh", other, "completed", "Validated", "74")
                term.capture("pinned-validated", ["Reported cells (agg.): 74"])
                term.drain(3)
                check_reads(offset, (BALANCED, READS[-1:]), (DELAY, READS))
                assert session.rpc("workspace") == zoomed, "Verify evidence changed selection/layout"
                session.mutate(zoomed, sexp(["Set_zoom", ["workspace", wid], ["tile", []]]))
        finally:
            blocked.unlink(missing_ok=True)
            session.stop()

        # The selected source now differs from its retained summary. Startup must
        # not adopt that change or retry on each poll; explicit Verify can adopt it.
        offset = len(requests())
        session.start()
        # Register the project before starting the PTY and plain RPC poller.
        # Otherwise both clients can try to initialize the same Dune workspace.
        session.rpc("workspace")
        with closing(Terminal(session, width=180)) as term:
            term.capture("recovery-connected", ["Connection: connected"])
            expect_operation(term, "validate-summary", selected, "failed", "Refresh_failed", "50")
            term.capture("failed-keeps-cache", ["Reported cells (agg.): 50", "Reported cells (agg.): 74"])
            term.drain(3)
            check_reads(offset, (BALANCED, READS[-1:]))
            # Restored client-local focus can still be on the pinned tile.
            # Explicitly focus the following tile before testing recovery.
            session.mutate(session.rpc("workspace"),
                           sexp(["Set_zoom", ["workspace", wid], ["tile", [following]]]))
            term.capture("focused-following", ["Reported cells (agg.): 50"],
                         absent=["Reported cells (agg.): 74"])
            verify_from_palette(term, "recovery")
            expect_operation(term, "refresh", selected, "completed", "Validated", "51")
            check_reads(offset, (BALANCED, READS[-1:]), (BALANCED, READS))
            data = session.rpc("asic")
            assert {sexp(field(r, "run")) for r in field(data, "runs")} == {sexp(selected), sexp(other)}
            assert not field(data, "workflows") and not field(data, "finalizations")
            snapshot = session.raw("/api/v1/snapshot", [["instance_id", session.metadata["instance_id"]]])
            assert snapshot[0] == "Ok" and not field(snapshot[1], "jobs"), snapshot
    finally:
        session.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument("--daemon", type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument("--evidence", type=Path, help="New path for retaining PTY and RPC captures")
    args = parser.parse_args()
    if args.evidence:
        args.evidence.mkdir()
        exercise(args.client, args.daemon, args.evidence.resolve())
    else:
        with TemporaryDirectory(prefix="verify-evidence-") as tmp:
            exercise(args.client, args.daemon, Path(tmp))
