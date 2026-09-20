#!/usr/bin/env python3
"""Deterministic full-area editor fixture; needs no installed interactive editor."""
import json
import os
import signal
import sys
import termios
import tty
from pathlib import Path

report = Path(sys.argv[1])
received = bytearray()
saved = termios.tcgetattr(0)
tty.setraw(0)


def publish(*_):
    size = os.get_terminal_size(0)
    report.write_text(json.dumps({"argv": sys.argv[2:], "cwd": os.getcwd(), "pid": os.getpid(), "size": [size.columns, size.lines], "input": received.hex()}))
    os.write(1, f"\x1b[2J\x1b[HEDITOR_READY\x1b[{size.lines};1HEDITOR_BOTTOM\x1b[2;1H".encode())


signal.signal(signal.SIGWINCH, publish)
os.write(1, b"\x1b[?2004h")
publish()
try:
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        received.extend(data)
        publish()
        if b"\x18" in data or b"\x19" in data:
            Path(sys.argv[-1]).write_text("edited by fixture\n")
            Path("created-by-tool").write_text("refresh both Panes\n")
            if b"\x19" in data:
                os.write(1, b"\x1b[HFAILED_FINAL_OUTPUT")
                sys.exit(9)
            break
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
