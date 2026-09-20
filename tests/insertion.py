#!/usr/bin/env python3
"""Cursor references arrive literally and never submit input by themselves."""
import os
import tempfile
from pathlib import Path
from support import App, in_pane, wait


def path_insertion():
    with tempfile.TemporaryDirectory(prefix="lh-insert-") as directory:
        root = Path(directory)
        name = "a '$(touch BAD); file"
        entry = root / name
        entry.write_text("contents")
        report = root / "report"
        app = App(cwd=root)
        try:
            app.start()
            in_pane(app, 0, "1 items")
            # Parent row cannot start or focus a shell.
            app.send("\x06")
            app.expect("NoCursorEntry")
            app.send("\r\x1b[B")
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
            # Absent session accepts insertion during startup without Enter.
            app.send("exit\r")
            wait(app, lambda: not Path(f"/proc/{app.shell_pid}").exists(), "shell EOF")
            app.send("\x06")
            app.expect("LH_PROMPT>")
            assert app.proc.poll() is None
            # Clear the inserted filename before submitting a command.
            app.send("\x15printf '<%s>\\n' STARTED\r")
            app.expect("<STARTED>")
            app.send("\x07q")
            app.finished()
        finally:
            app.close()


if __name__ == "__main__":
    path_insertion()
    print("PASS path_insertion")
