from __future__ import annotations

import glob
import os
import shutil
import subprocess
from pathlib import Path

from setuptools import find_packages, setup
from setuptools.command.build_py import build_py as _build_py
from setuptools.dist import Distribution

try:
    from setuptools.command.bdist_wheel import bdist_wheel as _bdist_wheel
except ImportError:  # pragma: no cover - compatibility with older setuptools
    from wheel.bdist_wheel import bdist_wheel as _bdist_wheel


ROOT = Path(__file__).parent.resolve()
OTP_APPS = ("kernel", "stdlib", "crypto")


def package_version() -> str:
    return os.environ.get("PYRLANG_VERSION", "0.1.2")


def erl_eval(expr: str) -> str:
    output = subprocess.check_output(
        ["erl", "-noshell", "-eval", expr],
        text=True,
    )
    return output.strip()


def otp_root() -> Path:
    return Path(
        erl_eval('io:format("~s", [code:root_dir()]), halt(0).')
    ).resolve()


def compile_beams(target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    sources = sorted(glob.glob(str(ROOT / "src" / "*.erl")))
    subprocess.check_call(
        [
            "erlc",
            "-Wall",
            "-Werror",
            "-I",
            str(ROOT / "include"),
            "-o",
            str(target),
            *sources,
        ]
    )


def copy_app(source_lib: Path, target_lib: Path, app: str) -> None:
    matches = sorted(source_lib.glob(f"{app}-*"))
    if not matches:
        raise RuntimeError(f"could not find OTP app {app!r} in {source_lib}")
    source = matches[-1]
    target = target_lib / source.name
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source / "ebin", target / "ebin", dirs_exist_ok=True)
    priv = source / "priv"
    if priv.exists():
        shutil.copytree(priv, target / "priv", dirs_exist_ok=True)


def copy_otp_runtime(target: Path) -> None:
    source = otp_root()
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    for name in ("bin", "releases"):
        shutil.copytree(source / name, target / name)

    erts_version = erl_eval(
        'io:format("~s", [erlang:system_info(version)]), halt(0).'
    )
    shutil.copytree(source / f"erts-{erts_version}", target / f"erts-{erts_version}")

    target_lib = target / "lib"
    target_lib.mkdir()
    source_lib = source / "lib"
    for app in OTP_APPS:
        copy_app(source_lib, target_lib, app)

    for candidate in (
        source.parent / "LICENSE.txt",
        source / "LICENSE.txt",
        source.parent / "AUTHORS",
    ):
        if candidate.exists():
            licenses = target / "licenses"
            licenses.mkdir(exist_ok=True)
            shutil.copy2(candidate, licenses / candidate.name)


class build_py(_build_py):
    def run(self) -> None:
        super().run()
        package_root = Path(self.build_lib) / "pyrlang"
        runtime_root = package_root / "_runtime"
        compile_beams(runtime_root / "ebin")
        copy_otp_runtime(runtime_root / "otp")


class BinaryDistribution(Distribution):
    def has_ext_modules(self) -> bool:
        return True


class bdist_wheel(_bdist_wheel):
    def finalize_options(self) -> None:
        super().finalize_options()
        self.root_is_pure = False
        self.python_tag = "py3"

    def get_tag(self) -> tuple[str, str, str]:
        _python, _abi, platform = super().get_tag()
        return "py3", "none", platform


setup(
    name="pyrlang",
    version=package_version(),
    description="Python implemented on the BEAM, packaged with Erlang/OTP",
    long_description=(ROOT / "README.md").read_text(encoding="utf-8"),
    long_description_content_type="text/markdown",
    author="Grant Jenks",
    url="https://github.com/grantjenks/pyrlang",
    packages=find_packages(include=["pyrlang", "pyrlang.*"]),
    include_package_data=True,
    python_requires=">=3.9",
    entry_points={
        "console_scripts": [
            "pyrlang=pyrlang.cli:pyrlang",
            "pyrunicorn=pyrlang.cli:pyrunicorn",
        ],
    },
    cmdclass={"build_py": build_py, "bdist_wheel": bdist_wheel},
    distclass=BinaryDistribution,
    zip_safe=False,
)
