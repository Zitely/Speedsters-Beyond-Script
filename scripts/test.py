#!/usr/bin/env python3
"""Run controller tests, plus the real bundle against a small Roblox API double."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LUAU = os.environ.get("LUAU_BIN", "luau")
subprocess.run(["python3", str(ROOT / "scripts/build.py"), "--check"], check=True)
subprocess.run([LUAU, str(ROOT / "tests/Core.spec.luau")], check=True, cwd=ROOT)
subprocess.run([LUAU, str(ROOT / "tests/Movement.spec.luau")], check=True, cwd=ROOT)
bundle = (ROOT / "SpeedstersBeyond.lua").read_text()
loader = (ROOT / "Loader.lua").read_text()
readme_loader = (ROOT / "README.md").read_text().split("```lua\n", 1)[1].split("```", 1)[0]
if readme_loader != loader:
    raise SystemExit("README loader differs from Loader.lua")
assert "]====]" not in bundle
fixture = "local BUNDLE = [====[" + bundle + "]====]\n"
fixture += "local Mock = (function()\n" + (ROOT / "tests/RobloxMock.luau").read_text() + "\nend)()\n"
fixture += (ROOT / "tests/Hub.spec.luau").read_text()
with tempfile.TemporaryDirectory(prefix="speedsters-tests-") as folder:
    test_file = Path(folder) / "Hub.spec.luau"
    test_file.write_text(fixture)
    subprocess.run([LUAU, str(test_file)], check=True, cwd=ROOT)
    loader_test = Path(folder) / "Loader.spec.luau"
    assert "]====]" not in loader
    loader_test.write_text("local LOADER = [====[" + loader + "]====]\n" + (ROOT / "tests/Loader.spec.luau").read_text())
    subprocess.run([LUAU, str(loader_test)], check=True, cwd=ROOT)
