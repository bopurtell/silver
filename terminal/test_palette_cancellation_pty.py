"""WB-096: native Enter dispatch against a private daemon's real active workflows."""
import argparse
from contextlib import closing, contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shlex
import sys
from tempfile import TemporaryDirectory
from threading import Thread
from types import SimpleNamespace
from urllib.parse import urlsplit

from test_checklist_defaults_pty import ROOT, Terminal, equipment, script, wait
from test_chip_contexts_pty import Session, dismiss, field, fs, selected_row, sexp


@contextmanager
def observe_requests(session):
    """Transparent recorder for PTY requests. All responses come from the real daemon."""
    target = urlsplit(session.url)
    requests = []
    projects = {}

    class Proxy(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def forward(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.path == "/api/v1/asic" and self.command == "POST":
                request = fs["parse"](body.decode())
                operation = field(request, "operation")
                if isinstance(operation, list) and operation[0] == "In_context":
                    operation = field(operation[1:], "operation")
                if isinstance(operation, list) and operation[0].startswith("Cancel"):
                    requests.append((field(request, "project"), operation))
            with closing(HTTPConnection(target.hostname, target.port, timeout=20)) as connection:
                connection.request(
                    self.command, self.path, body if self.command == "POST" else None,
                    {k: v for k, v in self.headers.items()
                     if k.lower() == "content-type" or k.lower().startswith("x-workbench-")})
                response = connection.getresponse()
                payload = response.read()
                if self.path == "/api/v1/open-project":
                    parsed = fs["parse"](payload.decode())
                    if parsed[0] == "Ok":
                        project = field(parsed[1], "project")
                        projects[field(fs["parse"](body.decode()), "root")] = (
                            field(project, "id"))
                self.send_response(response.status)
                self.send_header("Content-Type", response.getheader("Content-Type", "application/sexp"))
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        do_GET = do_POST = forward

    with ThreadingHTTPServer(("127.0.0.1", 0), Proxy) as proxy:
        thread = Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{proxy.server_port}", requests, projects
        finally:
            proxy.shutdown()
            thread.join()


def exercise(client, daemon, base, *, verb):
    base.mkdir()
    bulk_query = verb + " all"
    root, tools = base / "project", base / "tools"
    root.mkdir()
    tools.mkdir()
    (root / "dune-project").write_text("(lang dune 3.22)\n")
    target = ("controlled_fifo", "main") if verb == "stop" else ("electrum", "main")
    chip, variant = target
    bulk_title = f"Cancel All — {chip}/{variant}"
    bulk_two = bulk_title + " (2 "  # The palette may clip the trailing “flows)”.
    outside = ("other-chip", "other")
    equipment(root, tools, [target, outside])
    catalog_path = root / (chip + ".json")
    catalog = json.loads(catalog_path.read_text())
    catalog["declaration"]["entries"][0]["methodology"]["endpoints"] = ["synthesis", "timing"]
    catalog_path.write_text(json.dumps(catalog))

    # Share the journal producer used by the backend cancellation check. The
    # usual fresh provider supplies cheap, held synthesis producers for bulk.
    physical = root / "physical"
    basic = root / "basic-provider.py"
    basic.write_text(physical.read_text().replace(
        '    time.sleep(30 if os.path.exists("hold-physical") else 0.2)',
        '''    deadline = time.monotonic() + 120
    while not os.path.exists("release-basic") and time.monotonic() < deadline:
        time.sleep(0.02)'''))
    router = root / "select-provider.py"
    routing = ROOT / "scripts/fixtures/routing_cancellation_provider.py"
    router.write_text(f"""\
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
routing = False
if args[0] == "stages":
    plan = Path(args[args.index("--methodology-plan") + 1])
    routing = "timing" in json.loads(plan.read_text())["methodology"]["recipe"]["stages"]
elif args[0] == "observation":
    routing = (Path(args[2]) / "journal.json").exists()
elif args[0] == "report":
    routing = (Path(args[1]).parent / "journal.json").exists()
os.execv(sys.executable, [sys.executable, {str(routing)!r} if routing else {str(basic)!r}, *args])
""")
    script(physical, "exec " + shlex.join([sys.executable, str(router)]) + ' "$@"\n')
    session = Session(SimpleNamespace(client=client, daemon=daemon, outer_timeout=20), base, root)
    session.env.update(PATH=str(tools) + ":" + session.env["PATH"],
                       XDG_CONFIG_HOME=str(base / "client-config"),
                       XDG_CACHE_HOME=str(base / "client-cache"))

    def asic():
        return session.rpc("asic")

    def workflows(snapshot=None):
        return {field(w, "key"): w for w in field(snapshot or asic(), "workflows")}

    def launch(key, target, endpoint="synthesis"):
        chip, variant = target
        pair = [["chip", chip], ["variant", variant]]
        selection = [["flow", chip + "-flow"], ["profile", chip + "-default"],
                     ["endpoint", endpoint], ["assignments", []], ["chip_target", [pair]]]
        state = session.rpc("asic", sexp(["Stage_fresh", ["selection", selection],
                            ["elaboration_only", "false"], ["expected_plan_identity", []]]))
        intent, = field(state, "fresh_intent")
        state = session.rpc("asic", sexp(["Launch_fresh", ["key", key],
                            ["intent_id", field(intent, "id")]]))
        return field(workflows(state)[key], "id")

    def select_chip(target):
        pair = [["chip", target[0]], ["variant", target[1]]]
        session.rpc("asic", sexp(["Select_chip", pair]), wait=True)

    def selected_main_run():
        ws = session.rpc("workspace")
        context, = [c for c in field(ws, "contexts") if field(c, "id") == field(ws, "main_context")]
        return field(context, "selected_run")

    def select_run(run):
        ws = session.rpc("workspace")
        main = field(ws, "main_context")
        context, = [c for c in field(ws, "contexts") if field(c, "id") == main]
        workspace, = [w for w in field(ws, "workspaces") if field(w, "name") == "Overview"]
        session.mutate(ws, sexp(["Select_run", ["workspace", field(workspace, "id")],
                                 ["context", main],
                                 ["expected_selection_revision", field(context, "selection_revision")],
                                 ["run", [run]]]))

    def focused_checklist(term):
        for _ in range(20):
            if "overview › stage checklist" in term.drain(.15).casefold():
                return
            os.write(term.master, b"\t")
        term.capture("focus-checklist", ["Overview › Stage checklist"])

    def all_physical(*keys):
        known = workflows()
        return all(key in known and field(known[key], "phase") == "Physical" for key in keys)

    def cancelled(*keys):
        known = workflows()
        return all(field(known[key], "phase") == "Cancelled" for key in keys)

    def cancellation_latched(*keys):
        known = workflows()
        return all(field(known[key], "cancel_requested") == "true" for key in keys)

    def not_cancel_requested(*keys):
        known = workflows()
        for key in keys:
            w = known[key]
            assert field(w, "phase") == "Physical" and field(w, "cancel_requested") == "false", w

    def disabled_enter(term, label, reason, requests, before):
        os.write(term.master, b"\r")
        term.capture(label, ["COMMAND PALETTE", reason])
        assert requests == before, requests
        dismiss(term)

    try:
        session.start()
        with observe_requests(session) as (url, requests, projects):
            with closing(Terminal(session, argv=[str(client), "--connect", url,
                                                "--project-root", str(root)],
                                  width=210, height=50)) as term:
                term.capture("ready", ["Connection: connected", "available to launch"])
                project = projects[str(root)]
                # Drive the user's real launch-and-view path for `stop`, not
                # just an RPC-seeded run and a separately painted command.
                if verb == "stop":
                    row = selected_row(term, "timing", "launch-timing")
                    assert all(text in row for text in ("in view", f"{chip}/{variant}", chip + "-flow")), row
                    os.write(term.master, b"\r")
                    wait(term, lambda: workflows(), "Timing Enter did not launch a workflow")
                    first_key, = workflows()
                    workflow = workflows()[first_key]
                    first = field(workflow, "id")
                    selection = field(field(workflow, "intent"), "selection")
                    assert field(selection, "endpoint") == "timing", workflow
                else:
                    first_key = "electrum-first"
                    first = launch(first_key, target, "timing")
                wait(term, lambda: field(workflows()[first_key], "run"),
                     "Timing run never allocated")
                run, = field(workflows()[first_key], "run")
                if verb == "stop":
                    wait(term, lambda: selected_main_run() == [run],
                         "Launch and view did not select its allocated run")
                second = launch("second", target)
                select_chip(outside)
                out = launch("out-of-scope", outside)
                select_chip(target)
                wait(term, lambda: all_physical(first_key, "second", "out-of-scope"),
                     "Daemon did not own the three real workflows simultaneously")

                observed, = [r for r in field(asic(), "runs") if field(r, "run") == run]
                workspace = Path(field(field(observed, "reference"), "attempt")).parent
                if verb == "stop":
                    term.palette("Switch to Timing")
                    term.capture("timing-in-view", ["Timing ›"], absent=["COMMAND PALETTE"])
                else:
                    # No run in view: exact Enter must not fall through to the newest workflow.
                    row = selected_row(term, verb, "unavailable-single")
                    assert "Cancel — flow in view" in row, row
                    disabled_enter(term, "unavailable-single-enter", "No cancellable ASIC flow in view",
                                   requests, [])
                    not_cancel_requested(first_key, "second", "out-of-scope")
                    select_run(run)
                    focused_checklist(term)
                    term.capture("run-in-view", [re.compile(r"Routing:\s+running", re.I)])

                # The native submission key can be clipped in the palette;
                # the recorder below checks the full dispatched workflow ID.
                viewed_title = f"Cancel — {chip}-flow · "
                if verb == "cancel":
                    viewed_title += first_key
                row = selected_row(term, verb, "exact-single")
                assert viewed_title in row, row
                rows = term.capture("cancel-order", [
                    bulk_two, "Cancel fresh workflow second",
                ]).splitlines()
                first_pos = next(i for i, r in enumerate(rows) if "> " + viewed_title in r)
                assert bulk_two in rows[first_pos + 1], rows
                assert any("Cancel fresh workflow" in r for r in rows[first_pos + 2:]), rows
                before = asic()
                assert any(field(op, "key") == "run:" + first_key and field(op, "state") == "executing"
                           for op in field(before, "operations")), before

                os.write(term.master, b"\r")
                try:
                    if verb == "stop":
                        wait(term, lambda: requests, "Exact stop Enter did not dispatch")
                        term.palette("Switch to Overview")
                        focused_checklist(term)
                    term.capture("cancelling-routing", [re.compile(r"Routing:\s+cancelling…", re.I)],
                                 timeout=8)
                finally:
                    (workspace / "cleanup-release").touch()
                wait(term, lambda: cancelled(first_key), "Single Enter did not cancel viewed flow")
                assert requests == [(project, ["Cancel_workflow", first])], requests
                not_cancel_requested("second", "out-of-scope")
                terminal_rows = [re.compile(r"Routing:\s+cancelled", re.I),
                                 re.compile(r"Timing:\s+skipped — flow cancelled during routing", re.I)]
                term.capture("skipped-after-cleanup", terminal_rows)
                term.palette("verify evidence")
                wait(term, lambda: any(field(op, "key") == "refresh:" + field(run, "id")
                                      and field(op, "state") == "completed"
                                      for op in field(asic(), "operations")), "Run Refresh did not finish")
                term.capture("skipped-after-refresh", terminal_rows)
                finished, = [r for r in field(asic(), "runs") if field(r, "run") == run]
                execution_file, = field(finished, "execution_file")
                generation = json.loads(Path(execution_file).with_name("journal.json").read_text())
                assert not any(e["event"] == "started"
                               and e["data"]["occurrence"]["action_key"] == "implementation.timing"
                               for e in generation["events"]), generation

                third = launch("third", target)
                wait(term, lambda: all_physical("second", "third", "out-of-scope"),
                     "Daemon did not own the bulk candidates")
                # Wait for the terminal poll, independently of the API snapshot.
                for attempt in range(8):
                    row = selected_row(term, bulk_query, f"bulk-{attempt}")
                    if bulk_two in row:
                        break
                    dismiss(term)
                else:
                    raise AssertionError(row)

                newer = launch("newer", target)
                wait(term, lambda: all_physical("newer"), "Newer workflow not active")
                # Never refresh or reopen: operate on the two IDs in the painted command.
                os.write(term.master, b"\r")
                # The serialized physical queue may defer cleanup for the
                # captured flow behind the intentionally held out-of-scope one.
                wait(term, lambda: cancellation_latched("second", "third"),
                     "Bulk Enter did not cancel precisely the captured in-scope flows")
                expected = [(project, ["Cancel_workflow", w]) for w in [first, third, second]]
                assert requests == expected, (requests, expected, out, newer)
                not_cancel_requested("newer", "out-of-scope")

                # A separate owned finalization for the visible execution makes the single
                # alias ambiguous. Its legacy key intentionally collides with another
                # workflow's key; only its typed explicit operation may be sent.
                wait(term, lambda: field(workflows()["out-of-scope"], "run"),
                     "Out-of-scope run never acquired released physical slot")
                run, = field(workflows()["out-of-scope"], "run")
                observed, = [r for r in field(asic(), "runs") if field(r, "run") == run]
                execution = Path(field(field(observed, "reference"), "attempt")) / "execution.json"
                session.rpc("asic", sexp(["Finalize", ["key", "newer"], ["run", run],
                                         ["execution_file", str(execution)], ["acceptance", []]]))
                select_run(run)
                for attempt in range(8):
                    row = selected_row(term, verb, f"ambiguous-{attempt}")
                    if "Multiple active flows" in row:
                        break
                    dismiss(term)
                else:
                    raise AssertionError(row)
                disabled_enter(term, "ambiguous-enter", "Multiple active flows", requests, expected)
                row = selected_row(term, "Cancel finalization newer", "finalization-exact")
                assert "Cancel finalization newer" in row, row
                os.write(term.master, b"\r")
                expected += [(project, ["Cancel_finalization", ["key", "newer"], ["run", run]])]
                wait(term, lambda: len(requests) >= len(expected), "No exact finalization dispatch")
                assert requests == expected, (requests, expected)
                not_cancel_requested("newer", "out-of-scope")

                catalog_path = root / "chips.json"
                catalog = json.loads(catalog_path.read_text())
                catalog["default_chip"] = outside[0]
                catalog["chips"] = [c for c in catalog["chips"] if c["id"] != chip]
                catalog_path.write_text(json.dumps(catalog))
                term.palette("Discover ASIC flows and runs")
                for attempt in range(8):
                    row = selected_row(term, bulk_query, f"missing-chip-{attempt}")
                    if bulk_title in row and "Chip/variant missing from" in row:
                        break
                    dismiss(term)
                else:
                    raise AssertionError(row)
                disabled_enter(term, "missing-chip-enter", "missing from catalog",
                               requests, expected)
                not_cancel_requested("newer", "out-of-scope")
                (root / "release-basic").touch()
                wait(term, lambda: cancelled("second", "third"),
                     "Captured bulk workflows did not settle to Cancelled")
                wait(term, lambda: any(field(f, "key") == "newer"
                                      and field(f, "state") == "interrupted"
                                      for f in field(asic(), "finalizations")),
                     "Exact queued finalization did not settle as interrupted")
                assert requests == expected, (requests, expected)
    finally:
        session.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument("--daemon", type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()

    def run(base):
        for verb in ("cancel", "stop"):
            exercise(args.client, args.daemon, base / verb, verb=verb)

    if args.evidence:
        args.evidence.mkdir()
        run(args.evidence.resolve())
    else:
        with TemporaryDirectory(prefix="palette-cancellation-") as tmp:
            run(Path(tmp))
