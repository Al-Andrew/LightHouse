#!/usr/bin/env python3
import json
import os
import shlex
import signal
import sys
import tempfile
from pathlib import Path
from support import App, wait, in_pane

F4 = "\x1bOS"
FIXTURE = str(Path(__file__).parent / "fixtures/editor.py")


def read_report(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def external_editor():
    with tempfile.TemporaryDirectory(prefix="lh-editor-") as directory:
        root = Path(directory)
        config = root / "config/lighthouse"
        config.mkdir(parents=True)
        work = root / "work"
        work.mkdir()
        target = work / "a '$(touch BAD); file"
        target.write_text("initial")
        report = root / "report"
        argv = [sys.executable, FIXTURE, str(report), "fixed spaces", "$(touch BAD)"]
        (config / "config.json").write_text(json.dumps({"editor": argv}))
        app = App(cwd=work, env_overrides={"XDG_CONFIG_HOME": str(root / "config"), "EDITOR": "/invalid/fallback"})
        try:
            app.start()
            in_pane(app, 0, "1 items")
            app.send("\x07EDITOR_KEEP=survived\r\x07\x1b[B" + F4)
            app.expect("EDITOR_READY")
            data = read_report(report)
            assert data["argv"] == ["fixed spaces", "$(touch BAD)", str(target)]
            assert data["cwd"] == str(work)
            assert data["size"] == [100, 30]
            assert "EDITOR_BOTTOM" in app.screen.text().splitlines()[-1]
            payload = b"\x07\nq\x1bOS\x1b[200~pasted\x07\n\x1b[201~"
            app.send(payload)
            wait(app, lambda: read_report(report).get("input") == payload.hex(), "tool input interception")
            app.resize(80, 24)
            wait(app, lambda: read_report(report).get("size") == [80, 24], "tool resize")
            app.send("\x18")
            app.expect("Name")
            in_pane(app, 0, "created-by-tool")
            in_pane(app, 1, "created-by-tool")
            assert target.read_text() == "edited by fixture\n"
            app.send("\x07printf '<%s>\\n' \"$EDITOR_KEEP\"\r")
            app.expect("<survived>")
            app.send("\x07" + F4)
            app.expect("EDITOR_READY")
            os.kill(app.shell_pid, signal.SIGHUP)
            app.pump(0.2)
            assert app.proc.poll() is None
            app.send("\x19")
            app.expect("Editor exited unsuccessfully")
            app.expect("FAILED_FINAL_OUTPUT")
            app.send("\r" + F4)  # Dismiss and relaunch in one host-input batch.
            app.expect("EDITOR_READY")
            app.send("\x18")
            app.expect("Name")
            app.send("q")
            app.finished()
        finally:
            app.close()


def editor_configuration():
    with tempfile.TemporaryDirectory(prefix="lh-config-") as directory:
        root = Path(directory)
        config = root / "config/lighthouse"
        config.mkdir(parents=True)
        work = root / "work"
        work.mkdir()
        target = work / "file"
        target.write_text("initial")
        report = root / "report"
        settings = config / "config.json"
        bad_executable = root / "invalid-executable"
        bad_executable.write_text("not an executable format")
        bad_executable.chmod(0o755)
        cases = [
            (json.dumps({"editor": [str(bad_executable)]}), "/bin/true", "SpawnFailed"),
            (None, "", "Configure editor argv"),
            ("{bad", "/bin/true", "Invalid editor configuration"),
            ('{"editor":[]}', "/bin/true", "Invalid editor configuration"),
            ('{"editor":["/no/such/editor"]}', "/bin/true", "Configured editor executable"),
            (None, "unterminated '", "Invalid quoted arguments"),
        ]
        for explicit, fallback, error in cases:
            settings.unlink(missing_ok=True)
            if explicit is not None:
                settings.write_text(explicit)
            app = App(cwd=work, env_overrides={"XDG_CONFIG_HOME": str(root / "config"), "EDITOR": fallback})
            try:
                app.start()
                in_pane(app, 0, "1 items")
                app.send("\x1b[B" + F4)
                app.expect(error)
                app.send("\rq")
                app.finished()
            finally:
                app.close()
        settings.write_text("{}")
        fallback = " ".join(shlex.quote(arg) for arg in [sys.executable, FIXTURE, str(report), "quoted ' argument", "$(literal)"])
        app = App(cwd=work, env_overrides={"XDG_CONFIG_HOME": str(root / "config"), "EDITOR": fallback})
        try:
            app.start()
            in_pane(app, 0, "1 items")
            app.send("\x1b[B" + F4)
            app.expect("EDITOR_READY")
            assert read_report(report)["argv"] == ["quoted ' argument", "$(literal)", str(target)]
            app.send("\x18")
            app.expect("Name")
            app.send("q")
            app.finished()
        finally:
            app.close()


def editor_eligibility_and_shutdown():
    with tempfile.TemporaryDirectory(prefix="lh-eligible-") as directory:
        root = Path(directory)
        config = root / ".config/lighthouse"
        config.mkdir(parents=True)
        work = root / "work"
        work.mkdir()
        (work / "dir").mkdir()
        (work / "a-broken").symlink_to("missing")
        (work / "b-link").symlink_to("c-file")
        (work / "c-file").write_text("edit this")
        (work / "d-marked").write_text("keep marked")
        report = root / "report"
        (config / "config.json").write_text(json.dumps({"editor": [sys.executable, FIXTURE, str(report)]}))
        app = App(cwd=work, env_overrides={"XDG_CONFIG_HOME": "", "HOME": str(root), "EDITOR": "/invalid/fallback"})
        pid = None
        try:
            app.start()
            in_pane(app, 0, "5 items")
            for _ in range(2):
                app.send("\x1b[B" + F4)
                app.expect("Choose a local regular file")
                app.send("\r")
            app.send("\x1b[F\x1b[2~\x1b[H\x1b[B\x1b[B\x1b[B" + F4)
            app.expect("EDITOR_READY")
            assert read_report(report)["argv"] == [str(work / "b-link")]
            app.send("\x18")
            app.expect("Name")
            assert (work / "c-file").read_text() == "edited by fixture\n"
            assert (work / "d-marked").read_text() == "keep marked"
            app.send(F4)
            app.expect("EDITOR_READY")
            pid = read_report(report)["pid"]
            app.proc.send_signal(signal.SIGTERM)
            app.finished()
            assert not Path(f"/proc/{pid}").exists(), "tool child was not reaped"
        finally:
            app.close()



if __name__ == "__main__":
    for test in [external_editor, editor_configuration, editor_eligibility_and_shutdown]:
        test()
        print("PASS", test.__name__)
