#!/usr/bin/env python3
"""Browsing behavior through the actual terminal UI, using disposable fixtures."""

import os
import tempfile
from pathlib import Path

from support import App, go, in_pane, pane_text


def directory_browsing():
    with tempfile.TemporaryDirectory(prefix="lh-browse-") as directory:
        root = Path(directory)
        (root / "a_child").mkdir()
        (root / "a_child" / "inside.txt").write_text("inside")
        (root / "b_empty").mkdir()
        (root / "c_dirlink").symlink_to("a_child")
        (root / "alpha.txt").write_text("abc")
        (root / "zeta.txt").write_text("z" * 20000)
        (root / ".hidden").write_text("hidden")
        (root / "é界é.txt").write_text("unicode")
        (root / "name\nbreak").write_text("control")
        (root / "dead_link").symlink_to("missing")
        fd = os.open(os.fsencode(root) + b"/raw\xff", os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
        app = App(cols=160, rows=30, cwd=root)
        try:
            app.start()
            lines = app.screen.text().splitlines()
            assert lines[0].count(str(root)) == 2, "pane paths must be border titles"
            assert lines[1].count("Name") == 2, "column headers must follow the border"
            assert (
                "Left pane" not in app.screen.text()
                and "Right pane" not in app.screen.text()
            )
            assert "Terminal  |" not in app.screen.text()
            assert "LH_PROMPT>" in lines[19], (
                "shell must follow the pane border directly"
            )
            for index, label in enumerate(
                ["Help", "", "", "Edit", "Copy", "RenMov", "Mkdir", "Delete", "", "Quit"]
            ):
                assert lines[-1][
                    index * 16 : (index + 1) * 16
                ] == f"{index + 1}{label}".ljust(16), (
                    "unassigned key labels must be blank and slots evenly spaced"
                )
            app.send("\x1bOP")  # F1 remains wired to help.
            app.expect("Any key closes help")
            app.send("\x1b")
            app.pump(0.1)
            for index in (0, 1):
                in_pane(app, index, "9 items | 0 marked")
                in_pane(app, index, "é界é.txt")
                in_pane(app, index, r"name\x0Abreak")
                in_pane(app, index, r"raw\xFF")
                assert ".hidden" not in pane_text(app, index)

            app.send("\x1b[B\r")
            in_pane(app, 0, "inside.txt")
            assert "inside.txt" not in pane_text(app, 1), (
                "navigation changed the other pane"
            )
            app.send("\x7f")
            in_pane(app, 0, "9 items | 0 marked")
            app.send("\r")  # Returning to parent should focus the child we left.
            in_pane(app, 0, "inside.txt")
            app.send("\x7f")
            in_pane(app, 0, "9 items | 0 marked")
            app.send("\x1b[B\r")
            in_pane(app, 0, str(root / "b_empty"))
            in_pane(app, 0, "0 items | 0 marked")
            app.send("\x7f")
            in_pane(app, 0, "9 items | 0 marked")
            app.send("\x1b[B\r")
            in_pane(app, 0, str(root / "c_dirlink"))
            in_pane(app, 0, "inside.txt")
            app.send("\x7f")
            in_pane(app, 0, "9 items | 0 marked")

            # Alpha is the first regular file after three directory entries.
            app.send("\x1b[H" + "\x1b[B" * 4 + " ")
            in_pane(app, 0, "1 marked")
            in_pane(app, 0, "* alpha.txt")
            app.send("s")
            in_pane(app, 0, "size asc")
            in_pane(app, 0, "* alpha.txt")
            app.send("r")
            in_pane(app, 0, "size desc")
            in_pane(app, 0, "* alpha.txt")
            app.send(".")
            in_pane(app, 0, ".hidden")
            in_pane(app, 0, "10 items | 1 marked")
            assert ".hidden" not in pane_text(app, 1)
            (root / "new.txt").write_text("new")
            app.send("\x12")
            in_pane(app, 0, "11 items | 1 marked")
            in_pane(app, 0, "new.txt")
            assert "new.txt" not in pane_text(app, 1), "panes refreshed together"

            go(app, root / "missing")
            in_pane(app, 0, "Not found")
            in_pane(app, 0, "* alpha.txt")
            go(app, root / "alpha.txt")
            in_pane(app, 0, "Not a directory")
            go(app, root / "dead_link")
            in_pane(app, 0, "Not found")
            if os.geteuid() != 0:
                locked = root / "locked"
                locked.mkdir()
                locked.chmod(0)
                try:
                    go(app, locked)
                    in_pane(app, 0, "Permission denied")
                    in_pane(app, 0, "* alpha.txt")
                finally:
                    locked.chmod(0o700)
            go(app, root / "a_child")
            in_pane(app, 0, "inside.txt")

            # Pane navigation never changes the persistent shell's directory.
            app.send("\x07printf 'cwd:<%s>\\n' \"$PWD\"\r")
            app.expect(f"cwd:<{root}>")
            app.send("cd /; printf '<%s>\\n' SHELL_MOVED\r")
            app.expect("<SHELL_MOVED>")
            in_pane(app, 0, str(root / "a_child"))
            app.send("\x07\t")
            go(app, root / "b_empty")
            in_pane(app, 1, "0 items | 0 marked")
            in_pane(app, 0, "inside.txt")
            app.send("q")
            app.finished()
        finally:
            app.close()


def large_directory():
    with tempfile.TemporaryDirectory(prefix="lh-large-") as directory:
        root = Path(directory)
        for index in range(2500):
            (root / f"item{index:05d}").touch()
        app = App(cols=120, rows=30, cwd=root)
        try:
            app.start()
            # Exercise the shell while the initial directory scans are running.
            app.send("\x07printf '<%s>\\n' RESPONSIVE\r")
            app.expect("<RESPONSIVE>")
            in_pane(app, 0, "2500 items")
            in_pane(app, 1, "2500 items")
            app.send("\x07\x1b[F")
            in_pane(app, 0, "item02499")
            app.send(" ")
            in_pane(app, 0, "1 marked")
            app.send("\x1b[5~")
            in_pane(app, 0, "item02487")
            app.send("\x1b[H")
            in_pane(app, 0, "item00000")
            assert "item02499" not in pane_text(app, 0)
            app.send("\x12\x12\x12")
            in_pane(app, 0, "2500 items | 1 marked")
            app.send("q")
            app.finished()
        finally:
            app.close()


def shift_marking():
    with tempfile.TemporaryDirectory(prefix="lh-shift-") as directory:
        root = Path(directory)
        for index in range(30):
            (root / f"item{index:02d}").touch()
        app = App(cols=140, rows=30, cwd=root)
        try:
            app.start()
            in_pane(app, 0, "30 items")
            app.send("\x1b[1;2A")  # Shift+Up on parent cannot mark it.
            in_pane(app, 0, "0 marked")
            app.send("\x1b[B" + "\x1b[1;2B" * 3)
            in_pane(app, 0, "3 marked")
            in_pane(app, 1, "0 marked")
            # Traverse the same rows again: all three marks are removed.
            app.send("\x1b[H\x1b[B" + "\x1b[1;2B" * 3)
            in_pane(app, 0, "0 marked")
            app.send("\x1b[H\x1b[1;2F")  # Toggle the entire range on.
            in_pane(app, 0, "30 marked")
            in_pane(app, 0, "item29")
            app.send("\x1b[1;2B")  # Toggle the last item off at the boundary.
            in_pane(app, 0, "29 marked")
            app.send("\x1b[1;2H")  # Invert the mixed range: only item29 remains.
            in_pane(app, 0, "1 marked")
            in_pane(app, 0, "item00")
            app.send("\x1b[1;2F")  # Invert again: only item29 is unmarked.
            in_pane(app, 0, "29 marked")
            app.send(" ")
            in_pane(app, 0, "30 marked")
            app.send("\x1b[H\x12")
            in_pane(app, 0, "30 marked")
            # Shift+PageDown retains its terminal-history binding.
            app.send("\x1b[6;2~\x1b[B ")
            in_pane(app, 0, "29 marked")
            assert "* item00" not in pane_text(app, 0)
            # Shift navigation in shell focus is not applied to either pane.
            app.send("\x07\x1b[1;2B\x1b[1;2F\x07")
            in_pane(app, 0, "29 marked")
            in_pane(app, 1, "0 marked")
            app.send("q")
            app.finished()
        finally:
            app.close()


if __name__ == "__main__":
    for test in [directory_browsing, large_directory, shift_marking]:
        test()
        print(f"PASS {test.__name__}")
