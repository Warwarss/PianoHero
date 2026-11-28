"""Unified test runner for PianoHero (Godot headless tests + Python unit tests)."""
import argparse
import glob
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def find_godot(explicit: str | None = None) -> str | None:
    if explicit:
        return explicit
    env_bin = os.environ.get("GODOT_BIN")
    if env_bin and Path(env_bin).exists():
        return env_bin
    for name in ("godot", "godot4", "Godot_v4.7.2-stable_win64_console.exe"):
        found = shutil.which(name)
        if found:
            return found
    for pattern in (
        r"C:\Program Files\Godot\Godot_*_console.exe",
        r"C:\Program Files\Godot\Godot_*.exe",
    ):
        matches = sorted(glob.glob(pattern), reverse=True)
        if matches:
            return matches[0]
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", help="Path to Godot console executable")
    parser.add_argument("--skip-godot", action="store_true", help="Skip Godot headless tests")
    parser.add_argument("--skip-python", action="store_true", help="Skip Python unit tests")
    args = parser.parse_args()

    failed = False

    if not args.skip_python:
        print("=== Running Python unit tests ===")
        proc = subprocess.run(
            [sys.executable, str(ROOT / "tests" / "test_attack_decay_model.py"), "-v"],
            cwd=ROOT,
        )
        if proc.returncode != 0:
            failed = True

    if not args.skip_godot:
        print("\n=== Running Godot headless boot & core tests ===")
        godot = find_godot(args.godot)
        if not godot:
            print("ERROR: Could not find Godot executable. Pass --godot or set GODOT_BIN.", file=sys.stderr)
            return 1
        proc = subprocess.run(
            [godot, "--headless", "--audio-driver", "Dummy", "--path", str(ROOT),
             "--script", "res://tests/test_boot_and_core.gd"],
            cwd=ROOT,
        )
        if proc.returncode != 0:
            failed = True

    print("\nALL TESTS PASSED." if not failed else "\nSOME TESTS FAILED.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
