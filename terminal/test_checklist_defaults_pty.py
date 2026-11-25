"""One real R key from a clean launch target must reach its own fresh execution."""
from contextlib import closing
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import time
from tempfile import TemporaryDirectory
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "test"))
from support.terminal import Terminal


def script(path, body):
    path.write_text("#!/bin/sh\nset -eu\n" + body)
    path.chmod(0o700)


def calls(path):
    return [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []


def wait(term, predicate, label):
    deadline = time.monotonic() + 12
    while not predicate():
        screen = term.drain(.15)
        if time.monotonic() > deadline:
            raise AssertionError(f"{label}\n{screen}")


def equipment(root, tools, chips=(("alpha", "regular"), ("bravo", "compact"))):
    # The two chips share neither flow nor profile. Each catalog deliberately
    # puts a valid non-default profile first, so an accidental fallback is visible.
    (root / "chips.json").write_text(json.dumps(dict(schema_version=1, default_chip=chips[0][0],
        chips=[dict(id=c, label=c, default_variant=v, variants=[dict(id=v, label=v)])
               for c, v in chips])))
    for chip, _ in chips:
        catalog = json.loads((ROOT / "backend/test/asic/production_flow_list.json").read_text())
        decl = catalog["declaration"]
        entry, = decl["entries"]
        entry["methodology"]["id"] = chip + "-flow"
        entry["profiles"][1]["id"] = entry["default_profile"] = chip + "-default"
        decl["default"] = dict(flow=entry["methodology"]["id"], profile=entry["default_profile"])
        (root / (chip + ".json")).write_text(json.dumps(catalog))
    project = root / "project-cli"
    project.write_text("#!" + sys.executable + """
import sys, json
from pathlib import Path
args = sys.argv[1:]
with open('project-calls', 'a') as out:
    print(json.dumps(args), file=out)
if args == ['chip','list','--json']:
    print(Path('chips.json').read_text())
elif args[:2] == ['flow','list']:
    print(Path(args[args.index('--chip') + 1] + '.json').read_text())
else:
    sys.exit(2)
""")
    project.chmod(0o700)
    physical = root / "physical"
    shutil.copyfile(ROOT / "backend/test/fresh_provider.py", physical)
    physical.chmod(0o700)
    (root / "silver-asic.sexp").write_text(
        f'((schema_version 1)(project_executable "{project}")(provider_executable "{physical}")'
        f'(results_root "{root}/results")(toolchain "{root}")(python ())(support_tools ())'
        '(pdk_root ())(stage_timeout_seconds ()))')
    (root / "silver-preparation.sexp").write_text(
        f'((schema_version 1)(build_target publisher.exe)(results_root "{root}/publication")'
        '(timeout_seconds 15))')
    (root / "generation").write_text("fresh-checklist")
    publisher = ROOT / "scripts/fixtures/unified_fresh_prefix.py"
    script(root / "publisher-source", "exec " + shlex.join(
        [sys.executable, str(publisher), "emit", str(root)]) + ' "$@"\n')
    # Isolate the build boundary too; do not recursively invoke real dune under runtest.
    script(tools / "dune", """case "$1" in
--version) echo 3.22.0 ;;
describe) printf '((root "%s")(build_context _build/default))\\n' "$PWD" ;;
build) test "$8" = publisher.exe
       echo build >> build-calls
       mkdir -p _build/default
       cp publisher-source _build/default/publisher.exe ;;
*) exit 2 ;;
esac
""")


def exercise(client, base):
    root, tools = base / "project", base / "bin"
    root.mkdir()
    tools.mkdir()
    (root / "dune-project").write_text("(lang dune 3.22)\n")
    equipment(root, tools)
    for name in ("hardcaml-asic-flow", "yosys", "openroad", "librelane", "verilator"):
        script(tools / name, f"echo {name} >> {shlex.quote(str(base / 'unexpected-tool'))}\nexit 1\n")
    session = SimpleNamespace(evidence=base, env=dict(os.environ, XDG_STATE_HOME=str(base / "state"),
        SILVER_ASIC_PROVIDER=str(tools / "hardcaml-asic-flow"), PATH=str(tools) + ":" + os.environ["PATH"]))
    def launch(directory):
        return closing(Terminal(session, argv=[str(client), "--standalone", "--standalone-state-dir",
                                               str(base / (directory.name + "-service")),
                                               "--project-root", str(directory)], cwd=directory))
    generic = base / "generic"
    generic.mkdir()
    (generic / "dune-project").write_text("(lang dune 3.22)\n")
    with launch(generic) as term:
        term.capture("generic-ready", ["Overview", "Connection: connected"])
        term.drain(.5)
    assert not (base / "unexpected-tool").exists()
    assert not (generic / "build-calls").exists()
    with launch(root) as term:
        term.capture("overview", ["Overview"])
        def discovered(chip):
            return any(a[:2] == ["flow", "list"] and chip in a
                       for a in calls(root / "project-calls"))
        wait(term, lambda: discovered("alpha"), "No automatic discovery of default chip")
        term.capture("default-ready", ["available to launch"])
        term.palette("Select launch target: bravo / compact")
        wait(term, lambda: discovered("bravo"), "Did not discover newly selected chip")
        # Focus via the real tile traversal. No Plan/Prepare or run selection.
        for _ in range(20):
            screen = term.drain(.15)
            if "overview › stage checklist" in screen.casefold():
                break
            os.write(term.master, b"\t")
        term.capture("checklist", ["Overview › Stage checklist", "Floorplan", "available to launch",
                                   "Run: none selected"])
        assert not (root / "build-calls").exists()
        assert not calls(root / "events.jsonl")
        # The initial catalog-only cursor is on Synthesis.
        os.write(term.master, b"j")
        term.drain(.15)
        os.write(term.master, b"R")
        def completed():
            # inspection.json is published by atomic rename, after execution.json.
            return any(json.loads(p.read_text())["observation_status"] == "final"
                       for p in (root / "results").rglob("inspection.json"))
        wait(term, completed, "Single R never completed a physical execution")

    emitted, = [e["argv"] for e in calls(root / "events.jsonl") if e["kind"] == "emit-start"]
    assert emitted == ["flow", "emit", "--flow", "bravo-flow", "--profile", "bravo-default",
                       "--endpoint", "floorplan", "--source-root", str(root), "--json",
                       "--chip", "bravo", "--variant", "compact",
                       "--results-root", str(root / "publication")], emitted
    assert (root / "build-calls").read_text().splitlines() == ["build"]
    physical, = [a for a in calls(root / "physical-calls") if a[:1] == ["stages"]]
    plan = json.loads(Path(physical[physical.index("--methodology-plan") + 1]).read_text())
    receipt, = [e for e in calls(root / "events.jsonl") if e["kind"] == "emit-finished"]
    assert plan["plan_identity"] == receipt["plan_identity"]
    assert plan["methodology"]["recipe"]["stages"] == ["synthesis", "floorplan"]
    execution, = (root / "results").rglob("execution.json")
    assert json.loads(execution.read_text())["status"] == "completed"
    assert not (base / "unexpected-tool").exists()
    assert all(a[:2] in (["chip", "list"], ["flow", "list"]) for a in calls(root / "project-calls"))


if __name__ == "__main__":
    with TemporaryDirectory(prefix="checklist-pty-") as tmp:
        exercise(Path(sys.argv[1]).resolve(), Path(tmp))
