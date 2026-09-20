#!/usr/bin/env python3
"""Pane filter interaction, environment isolation and subprocess cancellation."""

import shutil
import tempfile
from pathlib import Path

from support import App, go, in_pane, pane_text, wait


def live_filter():
    with tempfile.TemporaryDirectory(prefix="lh-filter-") as directory:
        root = Path(directory)
        for name in ("alpha", "alphabet", "beta", "café", "name\nbreak"):
            (root / name).touch()
        app = App(
            cols=160,
            rows=30,
            cwd=root,
            env_overrides={
                "FZF_DEFAULT_OPTS": "--exact --no-ignore-case --print-query",
                "FZF_DEFAULT_OPTS_FILE": "/nonexistent/ignore-me",
            },
        )
        try:
            app.start()
            in_pane(app, 0, "5 items")
            app.send("/ap")
            in_pane(app, 0, "2 items")
            assert "beta" not in pane_text(app, 0)
            in_pane(app, 1, "5 items")
            app.send("\r\x1b[F ")
            in_pane(app, 0, "1 marked")
            app.send("/\r")
            in_pane(app, 0, "1 marked")
            app.send("/\x15cafe")
            in_pane(app, 0, "1 items | 0 marked")
            in_pane(app, 0, "café")
            app.send("\x15zzzz")
            in_pane(app, 0, "No matches")
            in_pane(app, 0, "/..")
            app.send("\r\t/beta\r\t")
            in_pane(app, 1, "1 items")
            in_pane(app, 0, "No matches")
            app.send("\x1b")
            in_pane(app, 0, "5 items")
            app.send("/\x1b[200~qsr\x00\n\x07\x1b[201~")
            in_pane(app, 0, "No matches")
            assert app.proc.poll() is None
            app.send("\x15" + "界" * 50)
            app.resize(36, 12)
            app.pump(0.3)
            assert app.proc.poll() is None
            app.resize(160, 30)
            app.pump(0.3)
            app.send("\x1b")
            in_pane(app, 0, "5 items")
            go(app, root)
            in_pane(app, 0, "5 items")
            app.send("\x07printf '<%s>\\n' FILTER_SHELL_OK\r")
            app.expect("<FILTER_SHELL_OK>")
            app.send("\x07q")
            app.finished()
        finally:
            app.close()


def cancellation_and_failures():
    fzf = shutil.which("fzf")
    assert fzf, "install fzf to run filtering tests"
    with tempfile.TemporaryDirectory(prefix="lh-filter-process-") as directory:
        root = Path(directory)
        listing = root / "listing"
        listing.mkdir()
        (listing / "alpha").touch()
        (listing / "beta").touch()
        executable = root / "fzf"
        pidfile = root / "pid"
        executable.write_text(
            "#!/bin/sh\n"
            'if [ "$2" = slow ]; then\n'
            f"  echo $$ > '{pidfile}'\n"
            "  exec /bin/sleep 30\n"
            "fi\n"
            'if [ "$2" = fail ]; then exit 2; fi\n'
            f'exec "{fzf}" "$@"\n'
        )
        executable.chmod(0o755)
        app = App(cols=160, rows=30, cwd=listing, env_overrides={"PATH": str(root)})
        try:
            app.start()
            in_pane(app, 0, "2 items")
            app.send("/slow")
            wait(app, pidfile.exists, "slow fzf did not start")
            pid = int(pidfile.read_text())
            app.send("\x15beta")
            in_pane(app, 0, "1 items")
            in_pane(app, 0, "beta")
            wait(
                app,
                lambda: not Path(f"/proc/{pid}").exists(),
                "superseded fzf was not reaped",
            )
            app.send("\x15fail")
            in_pane(app, 0, "fzf failed")
            in_pane(app, 0, "beta")
            app.send("\x1b")
            in_pane(app, 0, "2 items")
            executable.unlink()
            app.send("/alpha")
            in_pane(app, 0, "Install fzf in PATH")
            in_pane(app, 0, "alpha")
            app.send("\x1b")
            in_pane(app, 0, "2 items")
            app.send("q")
            app.finished()
        finally:
            app.close()


if __name__ == "__main__":
    for test in (live_filter, cancellation_and_failures):
        test()
        print(f"PASS {test.__name__}")
