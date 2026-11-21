"""WB-086 owner trial. Real PTY, compiled starter targets and bound authoring service.

Run in the Silver opam switch with hardcaml-asic-starter on PATH. --evidence must
name a new directory: the two disposable projects contain real generated files.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
from types import SimpleNamespace

from test_project_menus_pty import ROOT, Session, Terminal, click, field, inspect_second, send, sexp


def setup(base):
    root = base / "project"
    root.mkdir(parents=True)
    for args in [("render", "--name", "fifo_demo"), ("render-target", "--name", "sram"),
                 ("render-ip", "--name", "controlled_fifo", "--template", "sample")]:
        manifest = json.loads(subprocess.check_output(["hardcaml-asic-starter", *args], cwd=root))
        for f in manifest["files"]:
            path = root / f["path"]
            path.parent.mkdir(exist_ok=True, parents=True)
            path.write_text(f["contents"])
    chips = [dict(id=c, executable=f"asic_{c}/project.exe") for c in ("fifo_demo", "sram")]
    (root / "hardcaml-asic-targets.json").write_text(json.dumps(dict(
        schema_version=1, default_target="fifo_demo", targets=chips)))
    subprocess.run(["dune", "build", "--root", ".", "-j", "2", *(c["executable"] for c in chips)],
                   cwd=root, check=True)
    (root / "hardcaml-workbench-asic.sexp").write_text(sexp([
        ["schema_version", 1], ["project_executable", "_build/default/" + chips[0]["executable"]],
        ["results_root", "_flow_results/workbench/asic"], ["toolchain", "_flow_tools"],
        ["python", []], ["support_tools", []], ["pdk_root", []], ["stage_timeout_seconds", []]]))
    (root / "hardcaml-workbench-preparation.sexp").write_text(sexp([
        ["schema_version", 1], ["build_target", chips[0]["executable"]],
        ["results_root", "_flow_results/workbench/preparation"], ["timeout_seconds", 30]]))
    control = base / "simulation.json"
    control.write_text("{}")
    (root / "hardcaml-workbench-simulation.sexp").write_text(sexp([
        ["schema_version", 1], ["provider_executable", sys.executable],
        ["provider_args", [str(ROOT / "scripts/fixtures/fs2_provider.py"), "--control", str(control),
                           "--calls", str(base / "simulation-calls")]],
        ["discovery_timeout_seconds", 10], ["run_timeout_seconds", 30]]))
    return root


def exercise(s, t, surface):
    title = {"workspace": "Project workspace", "window": "Management window"}[surface]
    t.capture("connected", ["Project ▾"])
    inspect_second(t)
    inspection = ["> [x] second", "[2 Testing]"]
    # Stage once before entering either host. Compare the identity and selection
    # from the daemon after opening the non-active owner's wizard.
    asic = s.rpc("asic")
    target, = field(asic, "chip_target")
    assert field(target, "chip") == "fifo_demo", asic
    selection = [["flow", "standard"], ["profile", "balanced"], ["endpoint", "synthesis"],
                 ["assignments", []], ["chip_target", [target]]]
    staged = s.rpc("asic", sexp(["Stage_fresh", ["selection", selection],
                                ["elaboration_only", "false"], ["expected_plan_identity", []]]))
    intent, = field(staged, "fresh_intent")

    def check_state():
        after = s.rpc("asic")
        assert field(after, "chip_target") == [target] and field(after, "fresh_intent") == [intent]

    def browser(label, keyboard=False):
        screen = t.capture(label + "-inspection", inspection)
        if keyboard:
            send(t, b"\x1bOQ")
            send(t, b"/Manage This Project\r")
        else:
            click(t, screen, "Project ▾")
            click(t, t.capture(label + "-menu", ["Manage This Project"]), "Manage This Project")
        return t.capture(label + "-browser", [title, "New IP Library", "Chip: sram"]
                         + (inspection if surface == "window" else []),
                         absent=inspection if surface == "workspace" else [])

    def restored(label):
        t.capture(label + "-back", inspection, absent=[title])
        send(t, b"k")
        t.capture(label + "-focus", ["> [x] first"])
        send(t, b"j")

    # The default (no env setting) must be discoverable on a normal launch.
    # Switching presentation preserves the exact selected owner and region.
    screen = browser("switch")
    click(t, screen, "Chip: sram")
    send(t, b"\t")
    screen = t.capture("switch-before", ["For: sram", "▶ Commands", "[Try "])
    click(t, screen, "[Try ")
    other = "Management window" if surface == "workspace" else "Project workspace"
    t.capture("switch-after", [other, "For: sram", "▶ Commands", "New Flow"])
    send(t, b"v")
    t.capture("switch-return", [title, "For: sram", "▶ Commands"])
    send(t, b"\x1b")
    restored("switch")

    screen = browser("ip")
    click(t, screen, "New IP Library")
    t.capture("ip-command", ["New IP Library", "Sample behavior template"])
    send(t, b"\x1b")
    restored("ip")

    browser("module", keyboard=True)
    send(t, b"99j2k")
    t.capture("counted-movement", ["▶ Objects"], absent=["For: Project"])
    send(t, b"/controlled_fifo\t")
    t.capture("module-destination", ["▶ Commands", "For: ip/controlled_fifo"])
    send(t, b"\r")
    t.capture("module-command", ["module name", "ip/controlled_fifo"])
    send(t, b"trial_module\r")
    t.capture("module-preview", ["ip/controlled_fifo/trial_module.ml", "[Apply]"])
    send(t, b"\r")
    t.capture("module-created", ["created", "[Done]"])
    assert (s.root / "ip/controlled_fifo/trial_module.ml").is_file()
    send(t, b"\r")
    restored("module")

    screen = browser("chip")
    click(t, screen, "IP library: ip_controlled_fifo")
    click(t, t.capture("chip-actions", ["New Chip Target", "For: ip/controlled_fifo"]), "New Chip Target")
    t.capture("chip-mapping", ["explicit pin mapping"])
    send(t, b"ui_in:uo_out:comb8\r")
    t.capture("chip-name", ["enter target name"])
    send(t, b"cancelled_chip\r")
    screen = t.capture("chip-preview", ["Chip Target Preview", "[Cancel]"])
    click(t, screen, "[Cancel]")
    click(t, t.capture("chip-cancel", ["Preview cancelled", "[Done]"]), "[Done]")
    restored("chip")
    assert not (s.root / "asic_cancelled_chip").exists()

    screen = browser("flow")
    click(t, screen, "Chip: sram")
    screen = t.capture("flow-destination", ["For: sram", "New Flow"])
    click(t, screen, "New Flow")
    t.capture("sram-owner-preselected", ["> Owner: sram"])
    send(t, b"\r")
    t.capture("sram-wizard", ["owner: sram", "recipe"])
    check_state()
    send(t, b"\x1b")
    restored("flow")

    browser("copy", keyboard=True)
    send(t, b"/fifo_demo/standard/balanced\t\r")
    t.capture("copy-command", ["fifo_demo/standard/balanced", "Next: new profile"])
    check_state()
    send(t, b"\x1b")
    restored("copy")

    screen = browser("browse-sram")
    click(t, screen, "Chip: sram")
    click(t, t.capture("browse-sram-actions", ["Browse flows and profiles"]), "Browse flows and profiles")
    send(t, b"/sram/standard/balanced")
    t.capture("sram-profile", ["For: sram/standard/balanced", "Duplicate Profile"])
    check_state()
    send(t, b"\x1b")
    send(t, b"\x1b")
    restored("browse-sram")

    # Start a supervised slow simulation only for the visibility comparison.
    # The prior tasks prove management itself does not submit it.
    (s.evidence / "simulation.json").write_text('{"mode":"slow"}')
    t.palette("Simulation: Launch selected catalog subset")
    for step in ("CASES", "SEED", "CONFIRM"):
        t.capture("launch-" + step.lower(), ["SIMULATION LAUNCH FORM", step])
        send(t, b"\r")
    t.capture("live-inspection", ["running"])
    screen = browser("live")
    if surface == "workspace":
        assert "running" not in screen.casefold()
    else:
        t.capture("live-visible", [title, "running"])
    send(t, b"\x1b")
    t.capture("live-resumed", ["running", *inspection], absent=[title])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--recipe-fixture", action="store_true",
                   help="Older starter: supply only the missing describe-flow-authoring recipe metadata")
    for name in ["client", "daemon", "evidence"]:
        p.add_argument("--" + name, type=lambda s: Path(s).resolve(), required=True)
    args = p.parse_args()
    args.evidence.mkdir()
    for surface in ["workspace", "window"]:
        base = args.evidence / surface
        root = setup(base)
        s = Session(SimpleNamespace(client=args.client, daemon=args.daemon, outer_timeout=20), base, root)
        if surface == "window":
            s.env["SILVER_PROJECT_BROWSER"] = surface
        else:
            s.env.pop("SILVER_PROJECT_BROWSER", None)
        if args.recipe_fixture:
            bin_dir = base / "bin"
            bin_dir.mkdir()
            starter = bin_dir / "hardcaml-asic-starter"
            desc = json.dumps(dict(schema_version=1, recipes=[dict(id="librelane_classic_v1",
                              endpoints=["synthesis"])]))
            starter.write_text("#!/bin/sh\ncase $1 in describe-flow-authoring) echo "
                               + shlex.quote(desc) + ";; *) exec " +
                               shlex.quote(shutil.which(starter.name)) + ' "$@";; esac\n')
            starter.chmod(0o755)
            s.env["PATH"] = str(bin_dir) + ":" + os.environ["PATH"]
        try:
            s.start(daemon_args=["--authoring-root", str(root)])
            with closing(Terminal(s, width=80, height=32)) as t:
                exercise(s, t, surface)
            # Compact mode shows one tile only. Open F2 from it and exercise
            # all hit coordinates at the common 80x24 size as well.
            with closing(Terminal(s, width=80, height=24)) as t:
                t.capture("compact-inspection", ["Compact: focused tile only"])
                send(t, b"\x1bOQ")
                click(t, t.capture("compact-menu", ["Manage This Project"]), "Manage This Project")
                screen = t.capture("compact-browser", ["New IP Library", "[Try "])
                click(t, screen, "[Try ")
                other = "Management window" if surface == "workspace" else "Project workspace"
                screen = t.capture("compact-switched", [other, "New IP Library"])
                click(t, screen, "New IP Library")
                t.capture("compact-clicked", ["Sample behavior template"])
                send(t, b"\x1b")
                t.capture("compact-back", ["Compact: focused tile only"])
        finally:
            s.stop()


if __name__ == "__main__":
    main()
