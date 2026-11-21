"""Real PTY regressions for project navigation, scrolling and object-scoped dispatch."""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import shlex
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from test_chip_contexts_pty import FIFO, MEM, ROOT, Session, Terminal, field, setup, sexp, wait
from test_ip_authoring_pty import expected, snapshot


NEW, OPEN = "New Project…", "Open Project…"
UP, DOWN = b"\x1b[A", b"\x1b[B"
CTRL_Y, CTRL_E = b"\x19", b"\x05"


def send(t, keys):
    os.write(t.master, keys)
    return t.drain(.12)


def click(t, screen, label, row=None, *, button=0):
    lines = screen.splitlines()
    y = next(i for i, s in enumerate(lines) if label in s) if row is None else row
    x = lines[y].index(label)
    report = f"\x1b[<{button};{x + 1};{y + 1}"
    send(t, (report + "M" + (report + "m" if button < 64 else "")).encode())


def inspect_second(t):
    tabs = t.capture("workspace-tabs", ["2 Testing", "Project ▾"])
    if "[2 Testing]" not in tabs.splitlines()[0]:
        click(t, tabs, "2 Testing", row=0)
    ready = t.capture("testing", ["[2 Testing]", "simulation-catalog", "Project ▾"])
    top = ready.splitlines()[0]
    assert top.index("Project ▾") < top.index("Overview") < top.index("[2 Testing]"), top
    assert len(ready.splitlines()[1]) == t.width == os.get_terminal_size(t.master).columns
    click(t, ready, "simulation-catalog")
    send(t, b"d")
    t.capture("discovered", ["> [x] first", "[x] second"])
    send(t, b"j")
    inspection = ["> [x] second", "[2 Testing]"]
    return t.capture("inspect-second", inspection)


def project(t):
    screen = inspect_second(t)
    inspection = ["> [x] second", "[2 Testing]"]
    click(t, screen, "Project ▾")
    ip, module, chip, target = "New IP Library", "New Module", "New Chip Target", "Select Launch Target"
    author, select = "Author in this project", "Select or browse"
    screen = t.capture("flat-project", ["─ " + author, ip, module, chip, "─ " + select,
                                       target, "[2 Testing]"], absent=[NEW, OPEN])
    indexes = [screen.index(label) for label in
               (author, ip, module, chip, "New Flow", "Duplicate Profile", select, "Run Flow", target)]
    assert indexes == sorted(indexes), screen

    def highlighted(label, row):
        screen = t.capture(label, [row])
        line, = (line for line in screen.splitlines() if row in line)
        assert re.search(r"[>›▸▶]\s*" + re.escape(row), line), screen

    for key, row in [(b"j", module), (b"k", ip), (b"\x1b[B", module),
                     (b"\x1b[A", ip), (b"10j", "Manage This Project"), (b"6k", module)]:
        send(t, key)
        highlighted("movement-" + key.hex(), row)
    send(t, b"/j")
    t.capture("literal-j", ["Filter:", "j▏"])
    send(t, b"\x1b")
    t.capture("escape-filter", [author, ip, target], absent=["j▏"])
    send(t, b"\x1b")
    t.capture("escape-menu", inspection, absent=[author])
    # Off the catalog, k must not move its cursor. Back on it, k must move it.
    send(t, b"\t")
    send(t, b"k")
    t.capture("tab-away", inspection)
    send(t, b"\x1b[Z")
    send(t, b"k")
    t.capture("shift-tab-back", ["> [x] first", "[2 Testing]"])
    send(t, b"j")
    send(t, b"\x1bOQ")  # xterm F2
    t.capture("direct-project", [ip, target, "[2 Testing]"])
    send(t, b"/New IP Library")
    t.capture("filter-ip", [ip], absent=[module, chip, target])
    send(t, b"\r")
    t.capture("existing-ip-template", ["New IP Library", "empty", "sample"], absent=[author])
    send(t, b"\x1b")
    t.capture("cancel-to-inspection", inspection, absent=["sample", author])
    send(t, b"k")
    t.capture("cancel-restores-focus", ["> [x] first", "[2 Testing]"])


def pointer_authoring(t, root, renderer):
    original = snapshot(root)
    focus = ["[2 Testing]", "> [x] first"]
    for name, commit in (("abandoned", False), ("counter", True)):
        screen = t.capture(name + "-before", focus)
        click(t, screen, "Project ▾")
        screen = t.capture(name + "-project", ["New IP Library"])
        click(t, screen, "New IP Library")
        screen = t.capture(name + "-template", ["Sample behavior template", "Overview"])
        # The tab strip is fully exposed. Clicking it must not leave the wizard
        # or switch workspaces underneath it.
        click(t, screen, "Overview", 0)
        screen = t.capture(name + "-modal", ["[2 Testing]", "Sample behavior template"])
        click(t, screen, "Sample behavior template")
        t.capture(name + "-name", ["enter library name", "Template: sample", "[Cancel]"],
                  absent=["[Preview]"])
        send(t, name.encode())
        screen = t.capture(name + "-input", [name + "▏", "[Preview]"])
        # The heading/field is not a submit button.
        click(t, screen, name + "▏")
        screen = t.capture(name + "-field-inert", [name + "▏", "[Preview]"])
        click(t, screen, "[Preview]")
        screen = t.capture(name + "-preview", [f"ip/{name}/block.ml", "[Apply]", "[Cancel]"])
        assert snapshot(root) == original and not (root / "ip").exists()
        click(t, screen, "[Apply]" if commit else "[Cancel]")
        screen = t.capture(name + "-receipt", [f"ip/{name}/block.ml" if commit
                           else "Preview cancelled. No files created.", "[Done]"])
        click(t, screen, "[Done]")
        t.capture(name + "-closed", focus, absent=["[Done]", "AUTHORING RESULT"])
        if commit:
            original.update(expected(renderer, "render-ip", "--name", name, "--template", "sample"))
        else:
            assert not (root / "ip").exists()
        assert snapshot(root) == original
        # Verify actual focus, not just the workspace or a retained marker.
        send(t, b"j")
        t.capture(name + "-focus", ["[2 Testing]", "> [x] second"])
        send(t, b"k")


def list_page(t, name, rows, selected, *, heading, end=None):
    """Check ordered physical rows and the marker, scoped to the painted list."""
    screen = t.capture(name, [heading])
    lines = screen.splitlines()
    first = next(i for i, line in enumerate(lines) if heading in line)
    shown, markers = [], []
    for line in lines[first + 1:]:
        line = line.lstrip()
        if line.startswith("╰") or (end is not None and end in line):
            break
        text = line.removeprefix("│").split("│", 1)[0].strip()
        if not text or text == "/ filter" or "▏" in text or re.match(r"\d+/\d+\b", text):
            continue
        marked = text.startswith(("› ", "> "))
        title = (text[2:] if marked else text).strip().split(" · ", 1)[0].removesuffix("…")
        shown.append(title)
        if marked:
            markers.append(title)
    assert shown == list(rows), (name, shown, rows, screen)
    assert markers == ([] if selected is None else [selected]), (name, markers, selected, screen)
    return screen


def scrolled_palette(t):
    # A real 80x10 PTY leaves just a few visible results. The workspace tabs
    # can paint before the initial ASIC read binds the selected chip. Opening
    # a palette that early leaves a stale capture, whose rows are rightly inert.
    t.capture("compact", ["Overview"])

    def bound_chip():
        screen = send(t, b" ccSelect launch target: fifo / deep")
        send(t, b"\x1b")
        return "> Select launch target: fifo / deep (selected)" in screen

    wait(t, bound_chip, "palette did not capture the initial selected chip")
    for key in (b" ", b"c", b"c", b"Switch to"):
        send(t, key)
    labels = tuple("Switch to " + name for name in ("Overview", "Testing", "Waveforms",
                                                    "Timing", "Resources"))
    first, second, _, timing, last = labels
    screen = t.capture("filtered", ["> Switch to Overview", "Switch to Testing"], absent=[last])
    capacity = sum("Switch to " in row and "▏" not in row for row in screen.splitlines())
    assert 2 <= capacity < len(labels), screen

    def page(name, top, selected):
        return list_page(t, "scroll-palette-" + name, labels[top:top + capacity], selected,
                         heading="COMMAND PALETTE")

    page("initial", 0, first)
    send(t, CTRL_E)
    page("down-without-selection", 1, None)
    send(t, CTRL_Y * 2)
    screen = page("back-at-start", 0, first)
    # Wheel still moves the selection, not just the viewport.
    click(t, screen, "Switch to Overview", button=65)
    page("wheel", 0, second)
    send(t, DOWN * 3)
    bottom = len(labels) - capacity
    page("last-result", bottom, last)
    send(t, UP)
    page("reverse-stays-put", bottom, timing)
    send(t, UP * (3 - bottom))
    page("reverse-to-top-edge", bottom, labels[bottom])
    send(t, UP)
    page("cross-top-edge", bottom - 1, labels[bottom - 1])
    send(t, DOWN * (len(labels) - bottom))
    screen = page("bottom-for-click", bottom, last)
    click(t, screen, timing)  # Click a visible row other than the selection.
    t.capture("clicked-scrolled-row", ["Timing: active"], absent=["COMMAND PALETTE"])

    # Enter dispatches the hidden selection, not the top displayed match.
    for key in (b" ", b"c", b"c", b"Switch to"):
        send(t, key)
    page("reopened", 0, first)
    send(t, DOWN * 4 + CTRL_Y * 4)
    page("hidden-last-selection", 0, None)
    send(t, b"\r")
    t.capture("entered-hidden-result", [re.compile(r"Resources: active|\[5 Resources\]")],
              absent=["COMMAND PALETTE"])


def scrolled_project(t):
    author, select = "─ Author in this project", "─ Select or browse"
    ip, module, chip = "New IP Library", "New Module", "New Chip Target"
    flow, duplicate, run = "New Flow", "Duplicate Profile", "Run Flow"
    launch, manage = "Select Launch Target", "Manage This Project"
    rows = (author, ip, module, chip, flow, duplicate, select, run, launch, manage)
    t.capture("scroll-project-ready", ["Overview"])

    def page(name, top, selected):
        return list_page(t, "scroll-project-" + name, rows[top:top + 6], selected,
                         heading="╭ Project ")

    send(t, b"\x1bOQ")
    page("initial", 0, ip)
    send(t, CTRL_E)
    page("group-scroll", 1, ip)
    send(t, CTRL_E)
    page("selection-hidden", 2, None)
    send(t, CTRL_Y)
    page("selection-recovered", 1, ip)
    send(t, CTRL_E + b"\r")
    t.capture("scroll-project-enter-hidden", ["choose template", "sample"])
    send(t, b"\x1b")
    t.capture("scroll-project-template-closed", ["Overview"], absent=["choose template"])
    send(t, b"\x1bOQ")
    send(t, b"99j")
    page("jump-to-bottom", 4, manage)
    send(t, UP)
    screen = page("reverse-stays-put", 4, launch)
    click(t, screen, manage)
    t.capture("scroll-browser-open", ["Back to inspection", "Objects", "Actions", "fifo-flow"])

    objects = ("Project", "Chip: " + FIFO[0], "fifo-flow", "balanced", FIFO[2],
               "Chip: " + MEM[0])

    def browser(name, top, selected, destination):
        screen = list_page(t, "scroll-browser-" + name, objects[top:top + 4], selected,
                           heading="Objects", end="Actions")
        assert "For: " + destination in screen, screen
        return screen

    browser("initial", 0, "Project", "Project")
    send(t, CTRL_E)
    browser("hidden-object-keeps-owner", 1, None, "Project")
    send(t, CTRL_Y)
    browser("restored-object", 0, "Project", "Project")
    send(t, b"4j")
    browser("select-over-edge", 1, FIFO[2], "fifo/fifo-flow/fast")
    send(t, UP)
    screen = browser("reverse-stays-put", 1, "balanced", "fifo/fifo-flow/balanced")
    click(t, screen, FIFO[2])
    browser("clicked-scrolled-object", 1, FIFO[2], "fifo/fifo-flow/fast")
    send(t, CTRL_Y)
    browser("hidden-profile-keeps-owner", 0, None, "fifo/fifo-flow/fast")
    send(t, b"\r")
    t.capture("scroll-browser-enter-hidden-owner",
              ["▶ Actions", "› Duplicate Profile", "For: fifo/fifo-flow/fast"])


def local_projects(s, base, renderer, simulation):
    root = base / "source"
    root.mkdir()
    (root / "dune-project").write_text("(lang dune 3.17)\n(name source)\n")
    (root / "chip.ml").write_text("(* user's in-progress edit *)\n")
    (root / simulation.name).write_bytes(simulation.read_bytes())
    original = snapshot(root)
    order = ["─ Open or create", NEW, OPEN, "─ Author in this project", "New IP Library…",
             "New Module…", "New Chip Target…"]

    def menu(t, keyboard):
        if keyboard:
            send(t, b"\x1bOQ")
        else:
            click(t, t.capture("bound-tab", ["Project ▾"]), "Project ▾")
        screen = t.capture("bound-project-menu", order)
        assert [screen.index(row) for row in order] == sorted(screen.index(row) for row in order)
        return screen

    with closing(Terminal(s, argv=[str(s.args.client), "--standalone", "--project-root", str(root)],
                          cwd=root, width=80)) as t:
        t.capture("source-ready", ["Connection: connected", "Project: source"])
        inspect_second(t)
        for name, directory in (("discarded", None), ("sibling", None), ("design", "chosen")):
            target = base / (directory or name)
            screen = menu(t, keyboard=name == "sibling")
            if name == "sibling":
                assert "› " + NEW in screen, screen
                send(t, b"\r")
            else:
                click(t, screen, NEW)
            t.capture(name + "-name", ["Project name"], absent=["enter target name"])
            send(t, (name + "\r").encode())
            t.capture(name + "-destination", ["Destination"])
            send(t, ((directory or "") + "\r").encode())
            screen = t.capture(name + "-review", ["Create preview", "Recipe: hardcaml-asic-starter-v1",
                               "Name: " + name, "First registered chip target (default): " + name,
                               f"asic_{name}/project.ml", "Apply and open", "Esc cancel"])
            assert not target.exists() and snapshot(root) == original
            if name == "discarded":
                click(t, screen, "Esc cancel")
                t.capture("bound-cancel", ["Project: source", "[2 Testing]", "> [x] second"])
                send(t, b"k")
                t.capture("bound-focus", ["> [x] first"])
                assert not target.exists() and snapshot(root) == original
                continue
            click(t, screen, "Apply and open")
            t.capture(name + "-opened", ["Project: " + name, "Connection: connected"])
            files = snapshot(target)
            for path, contents in expected(renderer, "render", "--name", name).items():
                assert files[path] == contents, path
            registry = json.loads(files["hardcaml-asic-targets.json"])
            assert registry["default_target"] == name and len(registry["targets"]) == 1
            assert snapshot(root) == original
            # Explicitly switch back to the source from this newly bound session.
            screen = menu(t, keyboard=True)
            click(t, screen, OPEN)
            t.capture("bound-open", ["Existing project directory"])
            send(t, (str(root) + "\r").encode())
            t.capture("source-reopened", ["Project: source", "Connection: connected"])
            assert snapshot(root) == original and snapshot(target) == files


def local_actions(t, s):
    t.palette("Switch to Overview")

    def context(ws, ident):
        return next(c for c in field(ws, "contexts") if field(c, "id") == ident)

    def seed(target):
        chip, variant, profile = target
        t.palette(f"Select launch target: {chip} / {variant}")
        selection = [["flow", chip + "-flow"], ["profile", profile], ["endpoint", "synthesis"],
                     ["assignments", []], ["chip_target", [[["chip", chip], ["variant", variant]]]]]
        staged = s.rpc("asic", sexp(["Stage_fresh", ["selection", selection],
                       ["elaboration_only", "false"], ["expected_plan_identity", []]]))
        intent, = field(staged, "fresh_intent")
        s.rpc("asic", sexp(["Launch_fresh", ["key", chip], ["intent_id", field(intent, "id")]]))

        def completed():
            return next((field(w, "run")[0] for w in field(s.rpc("asic"), "workflows")
                         if field(w, "key") == chip and field(w, "phase") == "Completed"), None)
        wait(t, completed, "Historical run did not complete: " + chip)
        return completed()

    fifo, mem = seed(FIFO), seed(MEM)
    ws = s.rpc("workspace")
    main = field(ws, "main_context")
    overview = next(w for w in field(ws, "workspaces") if field(w, "name") == "Overview")
    wid = field(overview, "id")
    s.mutate(ws, sexp(["Select_run", ["workspace", wid], ["context", main],
                      ["expected_selection_revision", field(context(ws, main), "selection_revision")],
                      ["run", [mem]]]))
    wait(t, lambda: any("Run:" in line and field(mem, "id")[-4:] in line
                        for line in t.drain(.1).splitlines()), "Main run selection not painted")
    t.palette("Make workspace independent")
    def binding():
        return field(next(w for w in field(s.rpc("workspace"), "workspaces") if field(w, "id") == wid),
                     "context")
    wait(t, lambda: binding() != main, "Overview is still linked to Main")
    independent = binding()

    def chip_target(ident):
        op = "Get" if ident == main else sexp(["In_context", ["context", ident],
                                                ["initial_target", []], ["operation", "Get"]])
        target, = field(s.rpc("asic", op), "chip_target")
        return field(target, "chip"), field(target, "variant")

    # Zoom the selector; match the displayed run IDs rather than assuming run order.
    screen = t.capture("two-runs", ["runs 2/2"], absent=["Actions ▾"])
    click(t, screen, "runs 2/2")
    t.palette("Zoom focused tile")
    label = "Use this run's chip/variant as launch target"

    def runs(name):
        screen = t.capture(name, ["runs 2/2", "completed"], absent=["Actions ▾", label])
        rows = []
        for r in (fifo, mem):
            ident = field(r, "id")
            matches = []
            for i, line in enumerate(screen.splitlines()):
                if "completed" in line.lower():
                    for token in re.findall(r"[\w-]+(?:…[\w-]+)?", line):
                        prefix, sep, suffix = token.partition("…")
                        if token == ident or (sep and ident.startswith(prefix) and ident.endswith(suffix)):
                            matches.append((i, token))
            assert len(matches) == 1, (ident, screen)
            rows.append(matches[0])
        return screen, rows

    for mouse in (False, True):
        t.palette(f"Select launch target: {MEM[0]} / {MEM[1]}")
        wait(t, lambda: chip_target(independent) == MEM[:2], "Initial independent launch target")
        screen, (fifo_row, mem_row) = runs("runs-before-" + str(mouse))
        row, token = mem_row if mouse else fifo_row
        click(t, screen, token, row)
        screen, (fifo_row, mem_row) = runs("left-click-browses-" + str(mouse))
        assert ">" in screen.splitlines()[row].split(token)[0], screen
        if mouse:
            # Right-click FIFO itself while MEM has the browse cursor.
            click(t, screen, fifo_row[1], fifo_row[0], button=2)
        else:
            send(t, b"\x1bOR")  # xterm F3 on the highlighted FIFO row
        screen = t.capture("local-actions-" + str(mouse), [label])
        if mouse:
            click(t, screen, label)
        else:
            send(t, b"/Use this run")
            send(t, b"\r")
        wait(t, lambda: chip_target(independent) == FIFO[:2], "Wrong dispatched run/context")
        assert chip_target(main) == MEM[:2]
        ws = s.rpc("workspace")
        assert all(field(context(ws, ident), "selected_run") == [mem] for ident in (main, independent))


def exercise(args, base):
    root, tools = base / "project", base / "tools"
    setup(root, tools)
    renderer = tools / "hardcaml-asic-starter"
    fixture = ROOT / "terminal/ip_starter_fixture.py"
    renderer.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} -B "
                        f"{shlex.quote(str(fixture))} \"$@\"\n")
    renderer.chmod(0o755)
    control = base / "simulation.json"
    control.write_text("{}")
    (root / "hardcaml-workbench-simulation.sexp").write_text(sexp([
        ["schema_version", 1], ["provider_executable", sys.executable],
        ["provider_args", [str(ROOT / "scripts/fixtures/simulation_fault_provider.py"), "--control", str(control),
                           "--calls", str(base / "simulation-calls")]],
        ["discovery_timeout_seconds", 10], ["run_timeout_seconds", 30]]))
    s = Session(SimpleNamespace(client=args.client, daemon=args.daemon, outer_timeout=20), base, root)
    s.env.update(PATH=str(tools) + ":" + os.environ["PATH"])
    try:
        s.start(daemon_args=["--authoring-root", str(root)])
        with closing(Terminal(s, width=80, height=10)) as t:
            scrolled_palette(t)
        with closing(Terminal(s, width=80, height=10)) as t:
            scrolled_project(t)
        with closing(Terminal(s, width=80)) as t:
            t.capture("connected", ["Project ▾"])
            project(t)
            assert not (root / "ip").exists()
            pointer_authoring(t, root, renderer)
            local_actions(t, s)
    finally:
        s.stop()
    local_projects(s, base, renderer, root / "hardcaml-workbench-simulation.sexp")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("client", "daemon"):
        parser.add_argument("--" + name, type=lambda s: Path(s).resolve(strict=True), required=True)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence:
        args.evidence.mkdir()
        exercise(args, args.evidence)
    else:
        with TemporaryDirectory(prefix="project-menus-") as tmp:
            exercise(args, Path(tmp))
