from __future__ import annotations

import os
import stat
import subprocess
import sys
import sysconfig
from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parent


def get_runtime_path() -> Path:
    return PACKAGE_ROOT / "_runtime"


def _stdlib_paths() -> list[str]:
    names = ("stdlib", "platstdlib", "purelib", "platlib")
    paths = [sysconfig.get_path(name) for name in names]
    return [path for path in dict.fromkeys(paths) if path and os.path.isdir(path)]


def _runtime_env(runtime: Path) -> dict[str, str]:
    env = os.environ.copy()
    python_paths = _stdlib_paths()
    existing = env.get("PYTHONPATH")
    if existing:
        python_paths.append(existing)
    env["PYTHONPATH"] = os.pathsep.join(python_paths)
    env["ERL_ROOTDIR"] = str(runtime / "otp")
    return env


def _ensure_executable(path: Path) -> None:
    if sys.platform == "win32":
        return
    mode = path.stat().st_mode
    desired = mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    if mode != desired:
        path.chmod(desired)


def _run(module: str, args: list[str]) -> int:
    runtime = get_runtime_path()
    erl = runtime / "otp" / "bin" / "erl"
    ebin = runtime / "ebin"
    _ensure_executable(erl)
    command = [
        str(erl),
        "-pa",
        str(ebin),
        "-boot",
        "start_clean",
        "-noshell",
        "-eval",
        f"{module}:main(init:get_plain_arguments()).",
        "-extra",
        *args,
    ]
    if sys.platform == "win32":
        return subprocess.call(command, env=_runtime_env(runtime))
    os.execve(str(erl), command, _runtime_env(runtime))
    raise AssertionError("unreachable")


def pyrlang() -> int:
    return _run("pyrlang_cli", sys.argv[1:])


def pyrunicorn() -> int:
    return _run("pyrunicorn_cli", sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(pyrlang())
