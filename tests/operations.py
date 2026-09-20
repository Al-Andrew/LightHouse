#!/usr/bin/env python3
"""File actions through the real TUI, exclusively in disposable directories."""

import os
import signal
import tempfile
from pathlib import Path

from support import App, go, in_pane, submit, wait

F5, F6, F7, F8 = "\x1b[15~", "\x1b[17~", "\x1b[18~", "\x1b[19~"


def completed(app, count=1):
    app.expect(f"{count}/{count} items complete")
    app.expect("Completed")
    app.send("\r")
    app.pump(0.1)


def file_actions():
    with tempfile.TemporaryDirectory(prefix="lh-actions-") as directory:
        root = Path(directory)
        source, dest = root / "source", root / "dest"
        source.mkdir()
        dest.mkdir()
        (source / "tree").mkdir()
        (source / "tree" / ".hidden").write_text("nested")
        (source / "tree" / "loop").symlink_to(".")
        (source / "a.txt").write_text("alpha")
        (source / "b.txt").write_text("beta")
        app = App(cols=140, rows=30, cwd=root)
        try:
            app.start()
            go(app, source)
            in_pane(app, 0, "3 items")
            app.send("\t")
            go(app, dest)
            in_pane(app, 1, "0 items")
            app.send("\t")
            # Current row is never an operation source.
            app.send(F5)
            app.pump(0.1)
            assert "Source:" not in app.screen.text()
            # Copy a directory with the other pane as default destination.
            app.send("\x1b[B\x1b[B" + F5)
            app.expect("Source: tree")
            app.send("\r")
            completed(app)
            assert (dest / "tree" / ".hidden").read_text() == "nested"
            assert os.readlink(dest / "tree" / "loop") == "."
            in_pane(app, 1, "tree")
            # Select two files and leave Cursor on the Current row. Marks win.
            app.send("\x1b[B\x1b[2~\x1b[2~\x1b[H" + F5)
            app.expect("2 marked items")
            app.send("\r")
            completed(app, 2)
            assert (dest / "a.txt").read_text() == "alpha"
            assert (dest / "b.txt").read_text() == "beta"
            in_pane(app, 1, "3 items")
            # A conflict must not replace the modified destination.
            (dest / "a.txt").write_text("keep")
            app.send(F5 + "\r")
            app.expect("Destination conflict")
            assert (dest / "a.txt").read_text() == "keep"
            assert (source / "a.txt").read_text() == "alpha"
            app.send(" s")  # Skip all ordinary conflicts for this job.
            app.expect("Partial")
            app.send("\r")
            # Clear marks, rename a single file relative to the source pane.
            app.send("\x1b[H\x1b[B\x1b[B\x1b[B\x1b[2~\x1b[2~\x1b[A" + F6)
            app.expect("Move / Rename")
            app.expect("Source: a.txt")
            submit(app, "renamed.txt")
            completed(app)
            assert not (source / "a.txt").exists()
            assert (source / "renamed.txt").read_text() == "alpha"
            in_pane(app, 0, "renamed.txt")
            # Mkdir is relative to the active pane, including spaces and Unicode.
            app.send(F7)
            app.expect("Create directory")
            submit(app, "new 界 folder")
            completed(app)
            assert (source / "new 界 folder").is_dir()
            in_pane(app, 0, "new 界 folder")
            # Canceling the input dialog must make no filesystem change.
            app.send(F7 + "abandoned\x1b")
            app.pump(0.15)
            assert not (source / "abandoned").exists()
            # Errors retain interaction until result dismissal.
            app.send(F7)
            submit(app, "missing/child")
            app.expect("Not found")
            app.send("\x07\n")
            app.pump(0.1)
            app.expect("Not found")
            os.kill(app.shell_pid, signal.SIGHUP)
            app.pump(0.3)
            assert app.proc.poll() is None
            app.expect("Not found")
            app.send("\r")
            # Refresh both panes after mkdir when they show the same directory.
            app.send("\t")
            go(app, source)
            in_pane(app, 1, "renamed.txt")
            app.send(F7)
            submit(app, "both-panes")
            completed(app)
            in_pane(app, 0, "both-panes")
            in_pane(app, 1, "both-panes")
            app.send("q")
            app.finished()
        finally:
            app.close()


def partial_copy():
    with tempfile.TemporaryDirectory(prefix="lh-partial-") as directory:
        root = Path(directory)
        (root / "tree").mkdir()
        os.mkfifo(root / "tree" / "pipe")
        app = App(cols=140, rows=30, cwd=root)
        try:
            app.start()
            in_pane(app, 0, "1 items")
            app.send("\x1b[B\x1b[B" + F5)
            submit(app, "copy")
            app.expect("Unsupported file type")
            assert (root / "tree" / "pipe").exists()
            assert (root / "copy").is_dir()
            assert not (root / "copy" / "pipe").exists()
            app.send("s")
            app.expect("Partial")
            app.send("\rq")
            app.finished()
        finally:
            app.close()


def cross_filesystem_move():
    shared = Path("/dev/shm")
    if not shared.is_dir() or not os.access(shared, os.W_OK):
        print("SKIP cross_filesystem_move: /dev/shm unavailable")
        return
    with (
        tempfile.TemporaryDirectory(prefix="lh-cross-") as directory,
        tempfile.TemporaryDirectory(prefix="lh-cross-", dir=shared) as destination,
    ):
        root = Path(directory)
        if root.stat().st_dev == Path(destination).stat().st_dev:
            print("SKIP cross_filesystem_move: no second filesystem")
            return
        (root / "source").write_text("preserve me")
        app = App(cols=140, rows=30, cwd=root)
        try:
            app.start()
            in_pane(app, 0, "1 items")
            app.send("\x1b[B\x1b[B" + F6)
            submit(app, destination)
            app.expect("Moves between filesystems are not supported yet")
            assert (root / "source").read_text() == "preserve me"
            assert list(Path(destination).iterdir()) == []
            app.send("s")
            app.expect("Partial")
            app.send("\rq")
            app.finished()
        finally:
            app.close()


def delete_actions():
    with tempfile.TemporaryDirectory(prefix="lh-delete-") as directory:
        root = Path(directory)
        source, outside = root / "source", root / "outside"
        source.mkdir()
        outside.mkdir()
        (outside / "keep").write_text("untouched")
        (source / "a_tree" / "nested").mkdir(parents=True)
        (source / "a_tree" / "nested" / ".hidden").write_text("remove")
        (source / "b_link").symlink_to(outside)
        (source / "c_file").write_text("remove")
        (source / "d_broken").symlink_to("missing")
        (source / "z_keep").write_text("keep")
        app = App(cols=140, rows=30, cwd=source)
        try:
            app.start()
            in_pane(app, 0, "5 items")
            app.send(F8)  # Never delete the synthetic parent entry.
            app.pump(0.1)
            assert "Permanently delete" not in app.screen.text()
            # Mark a tree and a directory link; the Cursor returns to the Current row.
            app.send("\x1b[B\x1b[B\x1b[2~\x1b[2~\x1b[H" + F8)
            app.expect("Permanently delete 2 item(s)?")
            app.expect("This cannot be undone")
            app.send(b"\x1b[200~\r\nn\x1b[201~")
            app.pump(0.1)
            assert (source / "a_tree").is_dir()
            assert (source / "b_link").is_symlink()
            app.expect("Permanently delete 2 item(s)?")
            app.send("\x1b")
            app.pump(0.1)
            assert (source / "a_tree").exists()
            app.send(F8)
            app.expect("Permanently delete 2 item(s)?")
            app.send("\r")
            completed(app, 2)
            assert not (source / "a_tree").exists()
            assert not (source / "b_link").is_symlink()
            assert (outside / "keep").read_text() == "untouched"
            for index in (0, 1):
                in_pane(app, index, "3 items")
            # Delete one file, then a broken link without dereferencing it.
            for name, count in [("c_file", 2), ("d_broken", 1)]:
                app.send("\x1b[H\x1b[B\x1b[B" + F8)
                app.expect("Permanently delete 1 item(s)?")
                app.expect(str(source / name))
                app.send("\r")
                completed(app)
                assert not os.path.lexists(source / name)
                in_pane(app, 0, f"{count} items")
            # A stale source fails in the app instead of affecting another entry.
            app.send("\x1b[H\x1b[B\x1b[B" + F8)
            app.expect("Permanently delete 1 item(s)?")
            (source / "z_keep").unlink()
            app.send("\r")
            app.expect("Not found")
            app.send("\r")
            in_pane(app, 0, "0 items")
            app.send("q")
            app.finished()
        finally:
            app.close()


def delete_permission_error():
    if os.geteuid() == 0:
        print("SKIP delete_permission_error: running as root")
        return
    with tempfile.TemporaryDirectory(prefix="lh-delete-permission-") as directory:
        root = Path(directory)
        locked = root / "locked"
        locked.mkdir()
        (locked / "file").write_text("keep")
        locked.chmod(0o555)
        app = App(cols=140, rows=30, cwd=locked)
        try:
            app.start()
            in_pane(app, 0, "1 items")
            app.send("\x1b[B\x1b[B" + F8)
            app.expect("Permanently delete 1 item(s)?")
            app.send("\r")
            app.expect("Permission denied")
            assert (locked / "file").read_text() == "keep"
            app.send("\rq")
            app.finished()
        finally:
            app.close()
            locked.chmod(0o755)


def shift_marked_actions():
    for action in (F5, F6, F8):
        with tempfile.TemporaryDirectory(prefix="lh-shift-actions-") as directory:
            root = Path(directory)
            source, destination = root / "source", root / "destination"
            source.mkdir()
            destination.mkdir()
            for name in ["a", "b", "keep"]:
                (source / name).write_text(name)
            app = App(cols=140, rows=30, cwd=source)
            try:
                app.start()
                in_pane(app, 0, "3 items")
                app.send("\t")
                go(app, destination)
                in_pane(app, 1, "0 items")
                app.send("\t\x1b[B\x1b[B" + "\x1b[1;2B" * 2)  # Mark a/b; cursor on keep.
                in_pane(app, 0, "2 marked")
                app.send("\x1b[H\x1b[B\x1b[B" + "\x1b[1;2B" * 2)  # Unmark a/b.
                in_pane(app, 0, "0 marked")
                app.send("\x1b[H\x1b[B\x1b[B" + "\x1b[1;2B" * 2)  # Mark them again.
                in_pane(app, 0, "2 marked")
                in_pane(app, 1, "0 marked")
                app.send("\x1b[F")  # Cursor on unmarked keep; actions use a/b.
                app.send(action)
                app.expect(
                    "Permanently delete 2 item(s)?"
                    if action == F8
                    else "2 marked items"
                )
                app.send("\r")
                completed(app, 2)
                assert (source / "keep").read_text() == "keep"
                assert not (destination / "keep").exists()
                for name in ["a", "b"]:
                    assert (source / name).exists() == (action == F5)
                    if action != F8:
                        assert (destination / name).read_text() == name
                app.send("q")
                app.finished()
            finally:
                app.close()


def merge_decisions():
    with tempfile.TemporaryDirectory(prefix="lh-merge-") as directory:
        root = Path(directory) / ("long-directory-" * 8)
        root.mkdir()
        source, dest = root / "source", root / "dest"
        source.mkdir()
        dest.mkdir()
        (source / "a").write_text("replacement")
        (dest / "a").write_text("old")
        app = App(cols=140, cwd=source)
        try:
            app.start()
            in_pane(app, 0, "1 items")
            app.send("\x07sleep 0.2; printf BACKGROUND_; printf FINISHED\r\x07")
            app.send("\x1b[B\x1b[B" + F5)
            submit(app, dest)
            app.expect("Destination conflict")
            app.expect("[ ] Apply to all")
            app.expect("source/a")
            app.expect("dest/a")
            app.expect("BACKGROUND_FINISHED")
            app.send("\x07\n\x06\x1bOS")
            app.pump(0.1)
            app.expect("Destination conflict")
            assert "Editor" not in app.screen.text()
            # Changes while the prompt is open require fresh unchecked consent.
            (dest / "a").write_text("changed during prompt")
            app.send(" o")
            app.expect("[ ] Apply to all")
            app.expect("Destination conflict")
            assert (dest / "a").read_text() == "changed during prompt"
            os.kill(app.shell_pid, signal.SIGHUP)
            wait(
                app,
                lambda: not Path(f"/proc/{app.shell_pid}").exists(),
                "shell EOF while waiting",
            )
            app.expect("Destination conflict")
            app.send("o")
            completed(app)
            assert (dest / "a").read_text() == "replacement"
            app.send("q")
            app.finished()
        finally:
            app.close()


if __name__ == "__main__":
    for test in [
        file_actions,
        merge_decisions,
        partial_copy,
        cross_filesystem_move,
        delete_actions,
        delete_permission_error,
        shift_marked_actions,
    ]:
        test()
        print(f"PASS {test.__name__}")
