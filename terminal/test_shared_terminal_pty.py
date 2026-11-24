"""Shared terminal acceptance through a real Silver frontend PTY (no build required).

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


PROMPT = "shared-shell$"
OVERLAY = re.compile(r" Terminal \d+ \(local\) \|")
PALETTE = "COMMAND PALETTE"
PALETTE_KEYS = b" cc"
TOGGLE_KEYS = b" /"
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
    (project / "dune-project").write_text("(lang dune 3.22)\n(name shared_terminal_pty)\n")
    (project / "subdir").mkdir()
    home = base / "home"
    home.mkdir()
    audit = base / "audit"
    audit.mkdir()
    shell = base / "test-shell"
    # A real interactive Bash with deterministic startup, prompt and private history.
    # Disable PTY input echo so output assertions cannot match the typed command.
    shell.write_text("""#!/bin/sh
cat "/proc/$$/stat" > "$SHARED_TERMINAL_TEST_AUDIT/shell.$$"
stty -echo
export PS1='shared-shell$ ' HISTFILE=/dev/null HISTSIZE=1000
unset PROMPT_COMMAND HISTCONTROL HISTIGNORE HISTTIMEFORMAT
exec /bin/bash --noprofile --norc --noediting "$@"
""")
    shell.chmod(0o700)
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(base / "config"),
               XDG_STATE_HOME=str(base / "state"), XDG_RUNTIME_DIR=str(base / "runtime"),
               SHELL=str(shell), SHARED_TERMINAL_TEST_AUDIT=str(audit), SHARED_TERMINAL_TEST_PROJECT=str(project))
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
        title = re.compile(rf" Terminal {number} \(local\) \|")
        return see(label, title, *expected, absent=absent)

    def chord(keys):
        for key in keys:
            send(bytes([key]))
            term.drain(.04)

    def paste(data):
        send(b"\x1b[200~" + data + b"\x1b[201~")

    def open_palette(label):
        chord(PALETTE_KEYS)
        see(label, PALETTE)

    def palette_command(query, title):
        label = query.replace(" ", "-")
        open_palette("open-" + label)
        send(query.encode())
        see("query-" + label, PALETTE, "> " + query + "▏", "│ > " + title)
        send(b"\r")

    def resize(width, height):
        term.width, term.height = width, height
        fcntl.ioctl(term.master, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
        term.process.send_signal(signal.SIGWINCH)

    def inner_size(label, *, after=None):
        pattern = re.compile(rf"WB_SIZE_{label}=<(\d+) (\d+)>")
        # An outer SIGWINCH and shell input can arrive in either order.
        wait = ""
        if after is not None:
            rows, cols = after[:2]
            wait = (f"""for i in {{1..40}}; do [ "$(stty size)" != '{rows} {cols}' ] && break; """
                    "sleep .05; done; ")
        command(wait + f"""printf 'WB_SIZE_%s=<%s>\\n' {label} "$(stty size)" """)
        screen = shown("size-" + label, 2, pattern, absent=(PALETTE,))
        rows, cols = map(int, pattern.search(screen).groups())
        title_y, title_x = next((y, match.start())
                                for y, line in enumerate(screen.splitlines())
                                if (match := OVERLAY.search(line)))
        return rows, cols, title_y, title_x

    def check_center(geometry):
        rows, cols, y, x = geometry
        assert 0 < rows < term.height - 1 and 0 < cols < term.width, geometry
        assert x > 0 and y > 0, geometry
        # Allow one cell of rounding and room for a frame around the PTY.
        assert abs(2 * x + cols - term.width) <= 3, geometry
        assert abs(2 * y + rows + 1 - term.height) <= 3, geometry

    def check_bottom(geometry):
        rows, cols, y, x = geometry
        assert x == 0 and y > 0, geometry
        assert cols == term.width and y + rows + 1 == term.height, geometry

    def arm_read(label, *, count=None):
        # Echo is disabled and IFS= preserves the leading space. For timeout,
        # read two bytes without Enter so no later key can trigger the replay.
        option = "" if count is None else f" -n {count}"
        command(f"printf 'WB_READY_%s\\n' {label}; IFS= read -r{option} WB_INPUT; "
                f"""printf 'WB_READ_%s=<%s>\\n' {label} "$WB_INPUT" """)
        shown("read-ready-" + label, 2, f"WB_READY_{label}")

    def read_result(label, literal):
        shown("read-result-" + label, 2, f"WB_READ_{label}=<{literal}>", absent=(PALETTE,))

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
                f"""> "$SHARED_TERMINAL_TEST_AUDIT/{report.name}"; printf 'WB_CHILD_%s\\n' {number}""")
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
        command("""[ "$(pwd -P)" = "$SHARED_TERMINAL_TEST_PROJECT" ] && printf 'WB_CWD_%s\\n' initial""")
        shown("initial-project-cwd", 2, "WB_CWD_initial")
        command("WB_VALUE=number_two; cd subdir; : history_only_two")
        command("""(while [ ! -f "$SHARED_TERMINAL_TEST_AUDIT/release" ]; do sleep .05; done; """
                """printf 'WB_HIDDEN_%s\\n' two; : > "$SHARED_TERMINAL_TEST_AUDIT/emitted") &""")
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
        command("""[ "$(pwd -P)" = "$SHARED_TERMINAL_TEST_PROJECT/subdir" ] && printf 'WB_TWO=<%s>\\n' "$WB_VALUE" """)
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

        wide_rows, wide_cols, *_ = inner_size("wide")
        resize(116, 32)
        small_rows, small_cols, *_ = inner_size("small", after=(wide_rows, wide_cols))
        assert 0 < small_rows < wide_rows <= 40, (small_rows, wide_rows)
        assert 0 < small_cols < wide_cols <= 132, (small_cols, wide_cols)
        toggle()
        see("timing-focus-restored-after-resize", timing, absent=(OVERLAY,))
        toggle()
        shown("unnumbered-reopens-most-recent", 2, "WB_SIZE_small")

        chord(TOGGLE_KEYS)
        see("space-slash-hides-and-restores-focus", timing, absent=(OVERLAY, PALETTE))
        paste(TOGGLE_KEYS)
        see("pasted-space-slash-does-not-open", timing, absent=(OVERLAY, PALETTE))
        open_palette("palette-from-workspace")
        chord(TOGGLE_KEYS)
        see("space-slash-does-not-open-from-palette", PALETTE, ">  /▏", absent=(OVERLAY,))
        send(b"\x1b")
        see("escape-returns-to-workspace", timing, absent=(OVERLAY, PALETTE))
        chord(TOGGLE_KEYS)
        shown("space-slash-opens-most-recent-from-workspace", 2, "WB_SIZE_small",
              absent=(PALETTE,))
        assert started() == {one, two}, "Space / replaced a shell"

        arm_read("escape")
        open_palette("palette-from-live-terminal")
        chord(TOGGLE_KEYS)
        see("space-slash-stays-in-palette-query", PALETTE, ">  /▏")
        send(b"\x1b")
        shown("escape-returns-to-terminal", 2, "WB_READY_escape", absent=(PALETTE,))
        command("resumed")
        read_result("escape", "resumed")

        arm_read("rejected")
        send(b" cx literal\r")
        read_result("rejected", " cx literal")

        arm_read("slow", count=2)
        send(b" c")
        read_result("slow", " c")

        arm_read("paste")
        paste(PALETTE_KEYS + TOGGLE_KEYS)
        send(b"\r")
        read_result("paste", " cc /")

        bottom = inner_size("before_center")
        check_bottom(bottom)
        palette_command("term center", "Terminal: Center")
        see("centered-overlay", re.compile(r"(?m)^.+ Terminal 2 \(local\) \|"),
            absent=(PALETTE,))
        center = inner_size("center")
        check_center(center)
        assert center[:2] != bottom[:2], (center, bottom)
        resize(104, 28)
        smaller = inner_size("smaller_center", after=center)
        check_center(smaller)
        assert smaller[0] < center[0] and smaller[1] < center[1], (smaller, center)
        palette_command("term bottom", "Terminal: Bottom")
        shown("bottom-overlay", 2, re.compile(r"(?m)^ Terminal 2 \(local\) \|"),
              absent=(PALETTE,))
        check_bottom(inner_size("returned_bottom"))
        resize(116, 32)

        command("""[ "$(pwd -P)" = "$SHARED_TERMINAL_TEST_PROJECT/subdir" ] && [ "$WB_VALUE" = number_two ] """
                """&& history | grep -q 'history_only''_two' && printf 'WB_PLACEMENT_%s\\n' kept""")
        shown("placement-kept-shell-state", 2, "WB_PLACEMENT_kept")
        palette_command("close term", "Close Terminal")
        see("palette-close-restores-focus", timing, absent=(OVERLAY, PALETTE))
        assert live(two, require_running=True), "Close terminal stopped its shell"
        toggle()
        shown("reopen-after-palette-close", 2, "WB_PLACEMENT_kept", absent=(PALETTE,))
        assert started() == {one, two}, "Placement or close/reopen replaced a shell"

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
        f12_two, = started() - {one, two}
        command("""[ -z "${WB_VALUE+x}" ] && [ "$(pwd -P)" = "$SHARED_TERMINAL_TEST_PROJECT" ] && printf 'WB_RESTART_%s\\n' clean""")
        shown("restarted-two-has-fresh-state", 2, "WB_RESTART_clean")
        command("WB_VALUE=discard_me; cd subdir; printf 'WB_PALETTE_EXIT_%s\\n' two; exit 23")
        shown("two-exited-before-palette-restart", 2, "WB_PALETTE_EXIT_two", EXITED)
        palette_command("restart term", "Restart Exited Terminal (F12)")
        shown("palette-restart", 2, PROMPT, absent=(PALETTE, EXITED, "WB_PALETTE_EXIT_two"))
        new_two, = started() - {one, two, f12_two}
        assert not live(f12_two), "Palette restart left the old shell alive"
        command("""[ -z "${WB_VALUE+x}" ] && [ "$(pwd -P)" = "$SHARED_TERMINAL_TEST_PROJECT" ] && printf 'WB_PALETTE_RESTART_%s\\n' clean""")
        shown("palette-restart-has-fresh-state", 2, "WB_PALETTE_RESTART_clean")
        child_two = persistent_child(2)

        toggle(1)
        shown("one-survived-two-restart", 1, "WB_ISOLATED_one")
        command("""printf 'WB_ONE=<%s>\\n' "$WB_VALUE" """)
        shown("one-retained-its-variable", 1, "WB_ONE=<number_one>")
        assert started() == {one, two, f12_two, new_two}
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
        with tempfile.TemporaryDirectory(prefix="silver-shared-terminal-") as directory:
            exercise(client, Path(directory))


if __name__ == "__main__":
    main()
