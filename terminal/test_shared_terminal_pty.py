"""WB-089 acceptance through a real Silver frontend PTY (no build required).

Run from Silver: python3 -B terminal/test_shared_terminal_pty.py _build/default/terminal/main.exe
"""
import argparse
import fcntl
import os
from pathlib import Path
import re
import signal
import struct
import sys
import tempfile
import termios
import time
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


PROMPT = "wb089$"
OVERLAY = re.compile(r"(?m)^ Terminal \d+ \(local\) \|")
EXITED = re.compile(r"\bexited 23\b", re.IGNORECASE)
F10, F12 = b"\x1b[21~", b"\x1b[24~"


def process_stat(text):
    pid = int(text.split(" ", 1)[0])
    fields = text.rsplit(")", 1)[1].split()
    return (pid, fields[19]), fields[0]  # start time disambiguates PID reuse


def breadcrumb(workspace, tile):
    # At narrower widths the footer drops the workspace segment as a unit.
    return re.compile(rf"(?m)(?:{workspace} [›>] | {{2,}}){tile}\s*\Z")


def live(identity, *, require_running=False):
    try:
        current, state = process_stat(Path(f"/proc/{identity[0]}/stat").read_text())
    except (FileNotFoundError, ProcessLookupError):
        return False
    return current == identity and not (require_running and state in ("Z", "X"))


def exercise(client, base):
    launcher = base / "silver"
    launcher.symlink_to(client)
    project = base / "project"
    project.mkdir()
    (project / "dune-project").write_text("(lang dune 3.22)\n(name wb089_pty)\n")
    (project / "subdir").mkdir()
    home = base / "home"
    home.mkdir()
    audit = base / "audit"
    audit.mkdir()
    shell = base / "test-shell"
    # A real interactive Bash with deterministic startup, prompt and private history.
    # Disable PTY input echo so output assertions cannot match the typed command.
    shell.write_text("""#!/bin/sh
cat "/proc/$$/stat" > "$WB089_AUDIT/shell.$$"
stty -echo
export PS1='wb089$ ' HISTFILE=/dev/null HISTSIZE=1000
unset PROMPT_COMMAND HISTCONTROL HISTIGNORE HISTTIMEFORMAT
exec /bin/bash --noprofile --norc --noediting "$@"
""")
    shell.chmod(0o700)
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(base / "config"),
               XDG_STATE_HOME=str(base / "state"), XDG_RUNTIME_DIR=str(base / "runtime"),
               SHELL=str(shell), WB089_AUDIT=str(audit), WB089_PROJECT=str(project))
    for name in ("ENV", "BASH_ENV", "WB_VALUE"):
        env.pop(name, None)
    session = SimpleNamespace(env=env, evidence=base)
    # Start from outside the project to distinguish project cwd from launcher's cwd.
    term = Terminal(session, argv=[launcher, "--project-root", project], cwd=base,
                    width=132, height=40)

    def send(data):
        os.write(term.master, data)

    def see(label, *expected, absent=()):
        return term.capture(label, expected, absent=absent)

    def command(text):
        send(text.encode() + b"\r")

    def click(text, location, *, row_contains=None):
        y, row = next((y, row) for y, row in enumerate(text.splitlines(), 1)
                      if location in row and (row_contains is None or row_contains in row))
        x = row.index(location) + 1 + (2 if location.startswith("╭ ") else 0)
        send(f"\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m".encode())

    def switch_workspace(workspace, *expected, absent=()):
        label = re.compile(rf"\b\d+ {workspace}\b")
        screen = see("tab-available-" + workspace, label)
        tab_row = next(row for row in screen.splitlines() if "Project ▾" in row)
        click(screen, label.search(tab_row).group(0), row_contains="Project ▾")
        return see("workspace-" + workspace, re.compile(rf"\[\d+ {workspace}\]"),
                   *expected, absent=absent)

    def focus(workspace, tile, crumb):
        screen = switch_workspace(workspace, tile)
        click(screen, tile)
        seen = breadcrumb(workspace, crumb)
        see("focus-" + workspace, seen)
        return seen

    def toggle(number=None):
        # Match main.ml's outer input router; the overlay owns the shell input.
        send(F10 if number is None else b"\x1b" + str(number).encode())

    def shown(label, number, *expected, absent=()):
        title = re.compile(rf"(?m)^ Terminal {number} \(local\) \|")
        return see(label, title, *expected, absent=absent)

    def resize(width, height):
        term.width, term.height = width, height
        fcntl.ioctl(term.master, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
        term.process.send_signal(signal.SIGWINCH)

    def inner_size(label):
        pattern = re.compile(rf"WB_SIZE_{label}=<(\d+) (\d+)>")
        command(f"""printf 'WB_SIZE_%s=<%s>\\n' {label} "$(stty size)" """)
        screen = shown("size-" + label, 2, pattern)
        return tuple(map(int, pattern.search(screen).groups()))

    def await_condition(label, condition):
        deadline = time.monotonic() + 8
        while not condition():
            screen = term.drain(.1, allow_exit=True)
            assert time.monotonic() < deadline, f"{label}\n{screen}"

    def started():
        return {process_stat(path.read_text())[0] for path in audit.glob("shell.*")}

    def persistent_child(number):
        # A child which ignores hangup must still be cleaned up when Silver exits.
        report = audit / f"child.{number}"
        command(f"""(trap '' HUP; exec sleep 120) & cat "/proc/$!/stat" """
                f"""> "$WB089_AUDIT/{report.name}"; printf 'WB_CHILD_%s\\n' {number}""")
        shown(f"child-{number}", number, f"WB_CHILD_{number}")
        child, _ = process_stat(report.read_text())
        assert live(child, require_running=True), f"Terminal {number} cleanup probe was not live"
        return child

    release = audit / "release"
    try:
        see("startup", re.compile(r"\[\d+ Overview\]"), "Connection: connected")
        testing = focus("Testing", "╭ simulation-catalog ", "simulation catalog")
        toggle(2)
        shown("two-from-testing", 2, PROMPT)
        two, = started()
        command("""[ "$(pwd -P)" = "$WB089_PROJECT" ] && printf 'WB_CWD_%s\\n' initial""")
        shown("initial-project-cwd", 2, "WB_CWD_initial")
        command("WB_VALUE=number_two; cd subdir; : history_only_two")
        command("""(while [ ! -f "$WB089_AUDIT/release" ]; do sleep .05; done; """
                """printf 'WB_HIDDEN_%s\\n' two; : > "$WB089_AUDIT/emitted") &""")
        command("printf 'WB_ARMED_%s\\n' two")
        shown("background-writer-armed", 2, "WB_ARMED_two", absent=("WB_HIDDEN_two",))
        toggle()
        see("testing-focus-restored", testing, absent=(OVERLAY,))

        timing = focus("Timing", "╭ timing · paths ", "timing paths")
        release.touch()
        await_condition("background writer never emitted", (audit / "emitted").exists)
        see("output-was-hidden", timing, absent=(OVERLAY, "WB_HIDDEN_two"))
        toggle(2)
        shown("two-from-timing", 2, "WB_ARMED_two", "WB_HIDDEN_two")
        assert started() == {two}, "Opening #2 in Timing launched an extra shell"
        command("""[ "$(pwd -P)" = "$WB089_PROJECT/subdir" ] && printf 'WB_TWO=<%s>\\n' "$WB_VALUE" """)
        shown("two-kept-cwd-and-variable", 2, "WB_TWO=<number_two>")
        command("""history | grep -q 'history_only''_two' && printf 'WB_HISTORY_%s\\n' two""")
        shown("two-kept-history", 2, "WB_HISTORY_two")

        toggle(1)  # Switch numbers without dismissing the overlay first.
        shown("one-is-separate", 1, PROMPT, absent=("WB_HIDDEN_two", "WB_TWO=<number_two>"))
        one, = started() - {two}
        command("""if [ -z "${WB_VALUE+x}" ] && ! history | grep -q 'history_only''_two'; then printf 'WB_ISOLATED_%s\\n' one; fi""")
        shown("one-has-separate-variable-and-history", 1, "WB_ISOLATED_one")
        command("WB_VALUE=number_one")
        child_one = persistent_child(1)
        toggle(2)
        shown("switch-back-to-two", 2, "WB_TWO=<number_two>", absent=("WB_ISOLATED_one",))
        assert started() == {one, two}

        wide_rows, wide_cols = inner_size("wide")
        resize(116, 32)
        small_rows, small_cols = inner_size("small")
        assert 0 < small_rows < wide_rows <= 40, (small_rows, wide_rows)
        assert 0 < small_cols < wide_cols <= 132, (small_cols, wide_cols)
        toggle()
        see("timing-focus-restored-after-resize", timing, absent=(OVERLAY,))
        toggle()
        shown("unnumbered-reopens-most-recent", 2, "WB_SIZE_small")

        command("printf 'WB_LAST_%s\\n' two; exit 23")
        shown("two-retains-final-screen", 2, "WB_LAST_two", EXITED)
        assert not live(two), "Exited terminal 2 shell was not reaped"
        toggle()
        see("hide-exited-two", absent=(OVERLAY, EXITED))
        toggle(2)
        shown("toggle-does-not-restart-exited-two", 2, "WB_LAST_two", EXITED)
        assert started() == {one, two}
        send(F12)
        shown("explicit-restart", 2, PROMPT, absent=(EXITED, "WB_LAST_two"))
        new_two, = started() - {one, two}
        assert new_two != two
        command("""[ -z "${WB_VALUE+x}" ] && [ "$(pwd -P)" = "$WB089_PROJECT" ] && printf 'WB_RESTART_%s\\n' clean""")
        shown("restarted-two-has-fresh-state", 2, "WB_RESTART_clean")
        child_two = persistent_child(2)

        toggle(1)
        shown("one-survived-two-restart", 1, "WB_ISOLATED_one")
        command("""printf 'WB_ONE=<%s>\\n' "$WB_VALUE" """)
        shown("one-retained-its-variable", 1, "WB_ONE=<number_one>")
        assert started() == {one, two, new_two}
        assert live(one) and live(new_two)
        assert live(child_one, require_running=True) and live(child_two, require_running=True)
        switch_workspace("Testing", "╭ simulation-catalog ", absent=(OVERLAY,))
        toggle(1)
        shown("one-survived-visible-workspace-switch", 1, "WB_ONE=<number_one>")
        toggle()
        see("hide-before-quit", re.compile(r"\[\d+ Testing\]"), "R run checked cases",
            absent=(OVERLAY,))
        send(b"\x03")  # Silver Ctrl-C, not input to the numbered shell.
        await_condition("Silver did not exit", lambda: term.process.poll() is not None)
        assert term.process.returncode == 0, term.process.returncode
        assert not live(one) and not live(new_two), "Silver exited without reaping both shells"
        await_condition("Silver left a shell's background child running",
                        lambda: not any(live(child, require_running=True)
                                        for child in (child_one, child_two)))
    finally:
        release.touch()
        term.close()
        # Failed assertions must not leave the fixture's sleep/shell processes behind.
        # Only signal a matching PID/starttime recorded by this fixture.
        for report in audit.iterdir():
            if report.name.startswith(("shell.", "child.")) and report.stat().st_size:
                identity, _ = process_stat(report.read_text())
                if live(identity, require_running=True):
                    try:
                        os.kill(identity[0], signal.SIGKILL)
                    except ProcessLookupError:
                        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("client", type=Path, help="already built Silver executable")
    parser.add_argument("--evidence", type=Path, help="retain screen captures in a new directory")
    args = parser.parse_args()
    client = args.client.resolve(strict=True)
    if args.evidence:
        evidence = args.evidence.resolve()
        evidence.mkdir()
        exercise(client, evidence)
    else:
        with tempfile.TemporaryDirectory(prefix="silver-wb089-") as directory:
            exercise(client, Path(directory))


if __name__ == "__main__":
    main()
