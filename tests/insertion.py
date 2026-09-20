#!/usr/bin/env python3
"""Cursor references arrive literally and never submit input by themselves."""

import os
import shlex
import tempfile
from pathlib import Path
from support import App, go, in_pane, wait


def path_insertion():
    with tempfile.TemporaryDirectory(prefix="lh-insert-") as directory:
        root = Path(directory)
        name = "a '$(touch BAD); file"
        entry = root / name
        ran = root / "ran"
        entry.write_text("#!/bin/sh\nprintf executed > " + str(ran) + "\n")
        entry.chmod(0o755)
        report = root / "report"
        app = App(cwd=root)
        try:
            app.start()
            in_pane(app, 0, "1 items")
            app.send("\x1b[B\x1b[B")
            app.send("\x07printf '%s' ")
            app.pump(0.1)
            app.send("\x07\x06")
            app.pump(0.1)
            assert not report.exists()
            app.send(f"> {report}\r")
            wait(app, report.exists, "insertion not delivered")
            assert report.read_text() == str(entry)
            assert not (root / "BAD").exists()
            # Hidden session reuses its input and process; no automatic cd.
            app.send("printf '%s' ")
            app.send("\n\x06")
            app.send(f"> {report}\r")
            app.pump(0.2)
            assert report.read_text() == str(entry)
            # An explicit reference goes to the current foreground program too.
            capture = root / "capture"
            program = (
                "import os,tty,termios; saved=termios.tcgetattr(0); tty.setraw(0); print('CAPTURE_READY',flush=True); data=b'';\nwhile True:\n b=os.read(0,1)\n if b==b'\\r': break\n data+=b\ntermios.tcsetattr(0,termios.TCSANOW,saved)\nopen("
                + repr(str(capture))
                + ", 'wb').write(data)"
            )
            app.send("\x1b[200~python3 -c " + shlex.quote(program) + "\x1b[201~\r")
            app.expect("CAPTURE_READY")
            app.send("\x06\x07\x06\r")
            wait(app, capture.exists, "foreground input capture")
            expected = "'" + str(entry).replace("'", "'\\''") + "' "
            assert capture.read_bytes() == b"\x06" + os.fsencode(expected)
            # Absent session accepts insertion during startup without Enter.
            app.send("exit\r")
            wait(app, lambda: not Path(f"/proc/{app.shell_pid}").exists(), "shell EOF")
            app.send("\x06")
            app.expect("LH_PROMPT>")
            assert app.proc.poll() is None
            assert not ran.exists(), "startup insertion submitted a command"
            app.send("\r")
            wait(app, ran.exists, "startup insertion was lost")
            assert ran.read_text() == "executed"
            app.send("\x07q")
            app.finished()
        finally:
            app.close()


def directory_references():
    with tempfile.TemporaryDirectory(prefix="lh-reference-") as directory:
        root = Path(directory)
        current = root / "a 'directory"
        current.mkdir()
        link = root / "a 'link"
        link.symlink_to(current.name)
        report = root / "report"
        app = App(cwd=root)
        try:
            app.start()
            for pane_index, location in [(0, current), (1, link)]:
                if pane_index:
                    app.send("\t")
                go(app, location)
                in_pane(app, pane_index, "0 items")
                in_pane(app, pane_index, "/.")
                in_pane(app, pane_index, "/..")
                # Enter on the initial Current row keeps Pane focus and location.
                app.send("\r")
                app.send("\x07cd /\rcd ")
                app.pump(0.1)
                app.send("\x07\x1b[H\x06")
                app.pump(0.1)
                assert not report.exists(), "Path insertion submitted input"
                app.send("; printf '%s' \"$PWD\" > " + shlex.quote(str(report)) + "\r")
                wait(app, report.exists, "current directory insertion")
                assert report.read_text() == str(location), report.read_text()
                report.unlink()
                # Parent resolves against the Pane, independent of the shell cwd.
                app.send("cd /\rprintf '%s' ")
                app.pump(0.1)
                app.send("\x07\x1b[H\x1b[B\x06")
                app.send("> " + shlex.quote(str(report)) + "\r")
                wait(app, report.exists, "parent directory insertion")
                assert report.read_text() == str(root)
                report.unlink()
                app.send("\x07")
            go(app, "/")
            in_pane(app, 1, "/..")
            app.send("\x1b[H\r\x1b[B\r")
            app.send("\x07printf '%s' ")
            app.pump(0.1)
            app.send("\x07\x06")
            app.send("> " + shlex.quote(str(report)) + "\r")
            wait(app, report.exists, "root reference insertion")
            assert report.read_text() == "/"
            app.send("\x07q")
            app.finished()
        finally:
            app.close()


if __name__ == "__main__":
    path_insertion()
    print("PASS path_insertion")
    directory_references()
    print("PASS directory_references")
