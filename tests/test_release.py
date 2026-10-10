"""Exercise the release recipe without .NET, Windows, or package registration.

Run with: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as log:
    log.write(json.dumps([name, args, os.getcwd()]) + "\n")
if name == "wslpath":
    if len(args) != 2 or args[0] != "-w":
        sys.exit(7)
    print("WIN:" + str(Path(args[1]).resolve()))
elif name == "dotnet":
    if os.environ.get("FAIL_PUBLISH"):
        sys.exit(8)
    output = Path(args[args.index("-o") + 1])
    (output / "NotifyFlash.exe").write_text("published")
elif name == "powershell.exe" and "-File" in args:
    if os.environ.get("FAIL_REGISTER"):
        sys.exit(9)
elif name == "powershell.exe" and "-Command" in args:
    if not Path("NotifyFlash.exe").is_file():
        sys.exit(10)
'''


class ReleaseTest(unittest.TestCase):
    def run_release(self, destination, **extra_env):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        shutil.copyfile(ROOT / "Makefile", root / "Makefile")
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name in ("dotnet", "taskkill.exe", "powershell.exe", "wslpath"):
            stub = bin_dir / name
            stub.write_text(STUB)
            stub.chmod(0o755)
        output = root / destination
        output.mkdir(parents=True)
        (output / "config.json").write_text("keep config")
        (output / "notify-flash.log").write_text("keep log")
        log = root / "commands.jsonl"
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                   COMMAND_LOG=str(log), **extra_env)
        result = subprocess.run(
            ["make", "release", "DOTNET=dotnet", f"RELEASE_DIR={output}"],
            cwd=root, env=env, text=True, capture_output=True)
        commands = [json.loads(line) for line in log.read_text().splitlines()]
        return root, output, result, commands

    def test_release_directories(self):
        for name in ("release", "Program Files/Notify Flash"):
            with self.subTest(name=name):
                _, output, result, commands = self.run_release(name)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((output / "NotifyFlash.exe").is_file(), result.stdout + result.stderr)
                self.assertEqual((output / "NotifyFlash.exe").read_text(), "published")
                self.assertEqual((output / "config.json").read_text(), "keep config")
                self.assertEqual((output / "notify-flash.log").read_text(), "keep log")
                publish = next(args for tool, args, _ in commands if tool == "dotnet")
                self.assertEqual(publish[publish.index("-o") + 1:], [str(output)])
                powershell = [(args, cwd) for tool, args, cwd in commands if tool == "powershell.exe"]
                self.assertEqual(len(powershell), 2)
                registration = powershell[0][0]
                self.assertEqual(registration[registration.index("-ExternalLocation") + 1], "WIN:" + str(output))
                self.assertEqual(powershell[1][1], str(output))

    def test_publish_failure_stops_registration_and_restart(self):
        _, _, result, commands = self.run_release("release", FAIL_PUBLISH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(tool == "dotnet" for tool, _, _ in commands))
        self.assertFalse(any(tool == "powershell.exe" for tool, _, _ in commands))

    def test_registration_failure_stops_restart(self):
        _, output, result, commands = self.run_release("release", FAIL_REGISTER="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((output / "NotifyFlash.exe").read_text(), "published")
        powershell = [args for tool, args, _ in commands if tool == "powershell.exe"]
        self.assertEqual(len(powershell), 1)
        self.assertIn("-File", powershell[0])


if __name__ == "__main__":
    unittest.main()
