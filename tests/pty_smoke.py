#!/usr/bin/env python3
"""Exercise the real executable through a PTY; Python standard library only."""

import os
import re
import shutil
import signal
import tempfile
import time
from pathlib import Path

from support import App, wait, go


def shell_and_resize():
    app = App()
    try:
        app.start()
        app.expect("Name")
        assert app.screen.text().splitlines()[1].count("Name") == 2
        app.send("\x07")
        app.pump(0.1)
        app.send("LH_TEST=persistent; printf '<%s>\\n' READY\r")
        app.expect("<READY>")
        app.send("\x07\t\x07")
        app.send("printf '<%s>\\n' \"$LH_TEST\"\r")
        app.expect("<persistent>")
        app.send("printf '\\303\\251\\347\\225\\214e\\314\\201\\n'\r")
        app.expect("é界é")
        app.resize(80, 24)
        app.expect("Name")
        app.send("printf 'size:'; stty size\r")
        app.expect("size:8 80")
        app.send("sleep 30\r")
        app.pump(0.1)
        app.send("\x03printf '<%s>\\n' INTERRUPTED\r")
        app.expect("<INTERRUPTED>")
        app.send("\x07z")
        app.pump(0.15)
        app.send("printf 'zoom:'; stty size\r")
        app.expect("zoom:23 80")
        app.send("\x07")
        app.expect("Name")
        app.send("q")
        app.finished()
    finally:
        app.close()


def geometry_and_fragmented_paste():
    """PTY geometry follows compact/tiny/zoom layout; paste stays shell input."""
    with tempfile.TemporaryDirectory(prefix="lighthouse-terminal-") as directory:
        report = Path(directory) / "size"
        pasted = Path(directory) / "paste"
        app = App()
        try:
            app.start()
            app.send("\x07")
            for cols, rows, terminal_rows in [
                (1, 1, 1),
                (12, 4, 3),
                (32, 10, 3),
                (80, 24, 8),
            ]:
                app.resize(cols, rows)
                app.pump(0.15)
                report.unlink(missing_ok=True)
                app.send(f"stty size > {report}\r")
                wait(
                    app,
                    lambda: (
                        report.exists()
                        and report.read_text().strip() == f"{terminal_rows} {cols}"
                    ),
                    f"child geometry did not become {terminal_rows} {cols}",
                )
            app.send("\x07z")
            app.pump(0.15)
            report.unlink()
            app.send(f"stty size > {report}\r")
            wait(
                app,
                lambda: report.exists() and report.read_text().strip() == "23 80",
                "zoom geometry",
            )
            # Split framing and payload across independent input batches.
            for fragment in (
                "\x1b[20",
                "0~printf '%s' ",
                f"PASTED > {pasted}",
                "\x1b[20",
                "1~",
            ):
                app.send(fragment)
                app.pump(0.05)
            assert not pasted.exists(), "paste unexpectedly submitted the command"
            app.send("\r")
            wait(
                app,
                lambda: pasted.exists() and pasted.read_text() == "PASTED",
                "fragmented paste",
            )
            app.send("\x07q")
            app.finished()
        finally:
            app.close()


def shell_exit():
    app = App()
    try:
        app.start()
        app.send("\x07exit\r")
        wait(app, lambda: not Path(f"/proc/{app.shell_pid}").exists(), "shell not reaped")
        assert app.proc.poll() is None, "shell EOF exited LightHouse"
        app.expect("Name")
        app.send("\n")
        app.expect("LH_PROMPT>")
        app.send("printf '<%s>\\n' RESTARTED\r")
        app.expect("<RESTARTED>")
        app.send("\x07q")
        app.finished()
    finally:
        app.close()


def terminal_lifetime():
    with tempfile.TemporaryDirectory(prefix="lh-lifetime-") as directory:
        root = Path(directory)
        work = root / "work"
        work.mkdir()
        report = root / "output"
        app = App(cwd=root)
        try:
            app.start()
            app.send("\x07LH_KEEP=kept; sleep 0.2; printf hidden > " + str(report) + "\r")
            app.send("\n")
            app.pump(0.1)
            assert "LH_PROMPT>" not in app.screen.text()
            wait(app, report.exists, "hidden child did not run")
            app.resize(12, 4)
            app.pump(0.1)
            assert "LH_PROMPT>" not in app.screen.text()
            app.resize(100, 30)
            app.send("\n")
            app.send("printf '<%s>\\n' \"$LH_KEEP\"\r")
            app.expect("<kept>")
            app.send("\x07")
            go(app, work)
            app.send("\x07")
            for cycle in range(3):
                app.send("exit\r")
                app.pump(0.3)
                assert app.proc.poll() is None
                app.send("\n")
                app.expect("LH_PROMPT>")
                app.send("printf 'cwd:'; pwd\r")
                app.expect("cwd:" + str(work))
            app.send("exit\r")
            app.pump(0.3)
            work.rmdir()
            app.send("\n")
            app.expect("WorkingDirectoryUnavailable")
            app.send("\r")
            assert app.proc.poll() is None
            go(app, root)
            app.send("t")
            app.expect("LH_PROMPT>")
            app.send("\x07q")
            app.finished()
        finally:
            app.close()


def signal_under_load():
    app = App()
    try:
        app.start()
        app.send("\x07yes\r")
        app.pump(0.15)
        app.proc.send_signal(signal.SIGTERM)
        app.finished()
    finally:
        app.close()


def failed_start():
    app = App(shell="/no/such/lighthouse-test-shell")
    try:
        app.finished(expected=1)
        assert b"ShellNotExecutable" in app.raw
    finally:
        app.close()


def stubborn_foreground():
    app = App()
    child_pid = None
    try:
        app.start()
        app.send(
            "\x07python3 -c \"import os,signal,time; signal.signal(signal.SIGHUP,signal.SIG_IGN); print('STUBBORN',os.getpid(),flush=True); time.sleep(30)\"\r"
        )
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            app.pump()
            match = re.search(r"STUBBORN (\d+)", app.screen.text())
            if match:
                child_pid = int(match[1])
                break
        assert child_pid is not None, app.screen.text()
        app.send("\x07q")
        app.finished()
        # An orphan may briefly remain a zombie until its reaper runs.
        status = Path(f"/proc/{child_pid}/status")
        if status.exists():
            assert re.search(r"State:\s+Z", status.read_text()), (
                "foreground process survived quit"
            )
    finally:
        if child_pid:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        app.close()


def tiny_resize():
    app = App()
    try:
        app.start()
        for cols, rows in [(1, 1), (12, 4), (32, 10), (100, 30)]:
            app.resize(cols, rows)
            app.pump(0.12)
            assert app.proc.poll() is None
        app.expect("Name")
        app.send("q")
        app.finished()
    finally:
        app.close()


def shell_context_signals():
    """A shell's OSC 3008 integration must not write host logs over the UI."""
    app = App()
    try:
        app.start()
        app.send("\x07")
        app.pump(0.1)
        chrome = app.screen.text().splitlines()[:19]
        app.send(
            "for i in 1 2 3; do printf '\\033]3008;start=lh-test;type=command\\007'; printf '\\033]3008;end=lh-test;exit=success\\007'; done; printf '\\033]3008;invalid=lh-test\\007'; printf '<%s>\\n' CONTEXT_DONE\r"
        )
        app.expect("<CONTEXT_DONE>")
        assert b"unimplemented OSC callback" not in app.raw, (
            "Ghostty diagnostics escaped into the TUI"
        )
        assert b"expected 'start=' or 'end=' prefix" not in app.raw, (
            "Ghostty warnings escaped into the TUI"
        )
        assert app.screen.text().splitlines()[:19] == chrome, (
            "shell metadata corrupted file panes"
        )
        app.send("\x07\t\x07")
        app.pump(0.1)
        assert app.screen.text().splitlines()[:19] == chrome, (
            "focus repaint left stale borders"
        )
        app.send("\x07q")
        app.finished()
    finally:
        app.close()


def redirected_diagnostics():
    """Keep warnings available in a file without stealing the child's stderr."""
    with tempfile.TemporaryFile() as diagnostics:
        app = App(stderr=diagnostics)
        try:
            app.start()
            app.send(
                "\x07printf '\\033]3008;invalid=lh-test\\007'; printf '<%s>\\n' CHILD_STDERR >&2\r"
            )
            app.expect("<CHILD_STDERR>")
            assert b"expected 'start=' or 'end=' prefix" not in app.raw
            app.send("\x07q")
            app.finished()
            diagnostics.seek(0)
            logs = diagnostics.read()
            assert b"expected 'start=' or 'end=' prefix" in logs, (
                "redirected diagnostics were lost"
            )
            assert b"<CHILD_STDERR>" not in logs, "child stderr escaped its PTY"
        finally:
            app.close()


def full_screen_programs():
    if not shutil.which("nvim") or not shutil.which("top"):
        print("SKIP full_screen_programs: install nvim and top for this check")
        return
    with tempfile.TemporaryDirectory(prefix="lighthouse-test-") as directory:
        path = Path(directory) / "editor.txt"
        path.write_text("ghostty editor probe\n")
        app = App()
        try:
            app.start()
            app.send("z")
            app.send(f"nvim --clean -n -i NONE {path}\r")
            app.expect("ghostty editor probe")
            app.send("A!")
            app.send("\x1b")
            app.pump(0.15)
            app.send(":wq\r")
            app.expect("LH_PROMPT>")
            assert path.read_text() == "ghostty editor probe!\n"
            app.send("top -d 1\r")
            app.expect("load average")
            app.resize(120, 40)
            app.expect("load average")
            app.send("q")
            app.expect("LH_PROMPT>")
            assert app.proc.poll() is None, "shell's q was handled by the UI"
            app.send("\x07q")
            app.finished()
        finally:
            app.close()


if __name__ == "__main__":
    for test in [
        shell_context_signals,
        redirected_diagnostics,
        shell_and_resize,
        geometry_and_fragmented_paste,
        shell_exit,
        terminal_lifetime,
        signal_under_load,
        failed_start,
        stubborn_foreground,
        tiny_resize,
        full_screen_programs,
    ]:
        test()
        print(f"PASS {test.__name__}")
