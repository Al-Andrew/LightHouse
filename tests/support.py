#!/usr/bin/env python3
"""Shared PTY, screen, and navigation helpers for the integration suites."""

import codecs
import errno
import fcntl
import os
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import unicodedata
from pathlib import Path

BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/lighthouse").resolve()


class Screen:
    """Decode the small ANSI output vocabulary of our cell renderer."""

    def __init__(self, cols=100, rows=30):
        self.cols, self.rows = cols, rows
        self.cells = [[" "] * cols for _ in range(rows)]
        self.x = self.y = 0
        self.pending = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data):
        self.pending += self.decoder.decode(data)
        while self.pending:
            if self.pending.startswith("\x1b"):
                match = re.match(r"\x1b\[([0-?]*)([ -/]*)([@-~])", self.pending)
                if not match:
                    if len(self.pending) == 1 or self.pending.startswith("\x1b["):
                        break
                    self.pending = self.pending[2:]
                    continue
                args, _, final = match.groups()
                self.pending = self.pending[match.end() :]
                if final == "H":
                    values = [int(v or 1) for v in args.split(";")]
                    self.y = values[0] - 1
                    self.x = (values[1] if len(values) > 1 else 1) - 1
                elif final == "J" and args == "2":
                    self.cells = [[" "] * self.cols for _ in range(self.rows)]
                continue
            ch, self.pending = self.pending[0], self.pending[1:]
            if ch == "\r":
                self.x = 0
            elif ch == "\n":
                self.y += 1
            elif ch >= " " and 0 <= self.y < self.rows:
                if unicodedata.combining(ch):
                    if 0 < self.x <= self.cols:
                        self.cells[self.y][self.x - 1] += ch
                    continue
                width = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
                if 0 <= self.x < self.cols:
                    self.cells[self.y][self.x] = ch
                if width == 2 and self.x + 1 < self.cols:
                    self.cells[self.y][self.x + 1] = ""
                self.x += width

    def text(self):
        return "\n".join("".join(row) for row in self.cells)


class App:
    def __init__(
        self,
        shell="/bin/sh",
        cols=100,
        rows=30,
        stderr=None,
        cwd=None,
        env_overrides=None,
    ):
        self.master, self.slave = os.openpty()
        self.saved = termios.tcgetattr(self.slave)
        self.screen = Screen(cols, rows)
        self.raw = bytearray()
        self.resize(cols, rows)
        env = dict(
            os.environ,
            PS1="LH_PROMPT> ",
            ENV="",
            TERM="xterm-256color",
            LC_ALL="C.UTF-8",
        )
        if env_overrides:
            env.update(env_overrides)
        self.proc = subprocess.Popen(
            [str(BINARY), "--shell", shell],
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave if stderr is None else stderr,
            start_new_session=True,
            env=env,
            cwd=cwd,
        )
        self.shell_pid = None

    def resize(self, cols, rows):
        self.screen = Screen(cols, rows)
        fcntl.ioctl(
            self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0)
        )

    def pump(self, seconds=0.05):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select(
                [self.master], [], [], max(0, deadline - time.monotonic())
            )
            if ready:
                try:
                    data = os.read(self.master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        return
                    raise
                self.raw.extend(data)
                self.screen.feed(data)

    def expect(self, text, timeout=5):
        wait(self, lambda: text in self.screen.text(), f"Missing {text!r}", timeout)

    def send(self, data):
        if isinstance(data, str):
            data = data.encode()
        os.write(self.master, data)

    def start(self):
        self.expect("LH_PROMPT>")
        children = (
            Path(f"/proc/{self.proc.pid}/task/{self.proc.pid}/children")
            .read_text()
            .split()
        )
        assert children, "no persistent shell child"
        self.shell_pid = int(children[0])

    def finished(self, expected=0):
        deadline = time.monotonic() + 5
        while self.proc.poll() is None and time.monotonic() < deadline:
            self.pump()
        assert self.proc.poll() == expected, (self.proc.poll(), self.screen.text())
        self.pump()
        assert termios.tcgetattr(self.slave) == self.saved, (
            "outer termios was not restored"
        )
        assert b"\x1b[?1049l" in self.raw, "alternate screen was not restored"
        if self.shell_pid:
            assert not Path(f"/proc/{self.shell_pid}").exists(), "shell was not reaped"

    def close(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            self.pump(0.5)
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        os.close(self.master)
        os.close(self.slave)


def pane_text(app, index):
    split = app.screen.cols // 2
    left, right = (0, split) if index == 0 else (split, app.screen.cols)
    # These tests keep the default 30-row split: panes occupy rows 0..18.
    return "\n".join("".join(row[left:right]) for row in app.screen.cells[:19])


def wait(app, condition, message, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        app.pump()
        if condition():
            return
    raise AssertionError(f"{message}\n{app.screen.text()}\nexit={app.proc.poll()}")


def in_pane(app, index, text):
    wait(app, lambda: text in pane_text(app, index), f"pane {index} missing {text!r}")


def go(app, path):
    app.send("\x0c")
    app.expect("Go to directory")
    submit(app, path)


def submit(app, target):
    app.send(b"\x1b[200~" + os.fsencode(target) + b"\x1b[201~\r")
