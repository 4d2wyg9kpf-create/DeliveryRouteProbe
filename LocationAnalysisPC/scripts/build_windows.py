"""Build and exercise the actual portable Windows application."""
from __future__ import annotations

import hashlib
import importlib.metadata as metadata
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from location_analysis import VERSION


def copy_licenses(destination):
    for name in ["PySide6-Essentials", "shiboken6", "openpyxl", "et_xmlfile", "xlrd", "pyinstaller"]:
        distribution = metadata.distribution(name)
        for file in distribution.files or []:
            if any(token in str(file).lower() for token in ["license", "copying", "copyright"]):
                source = Path(distribution.locate_file(file))
                if source.is_file():
                    # Retain all texts, including similarly named Qt component licenses.
                    target = destination / name / str(file).replace("..", "_").replace(":", "_")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
    python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if python_license.is_file():
        shutil.copy2(python_license, destination / "Python-LICENSE.txt")
    shutil.copy2(ROOT / "location_analysis" / "assets" / "OFL.txt", destination / "NanumGothic-OFL.txt")


def main():
    if sys.platform != "win32" or platform.architecture()[0] != "64bit":
        raise RuntimeError("Build on 64-bit Windows with 64-bit Python.")
    os.chdir(ROOT)
    subprocess.run([sys.executable, "scripts/fetch_assets.py"], check=True)
    assets = ROOT / "location_analysis" / "assets"
    subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir", "--windowed",
        "--noupx", "--name", "LocationAnalysisPC", "--add-data", f"{assets}{os.pathsep}location_analysis/assets",
        "run_app.py"], check=True)
    bundle = ROOT / "dist" / "LocationAnalysisPC"
    for name in ["README.md", "THIRD-PARTY-NOTICES.md"]:
        shutil.copy2(ROOT / name, bundle / name)
    licenses = bundle / "licenses"
    licenses.mkdir(exist_ok=True)
    copy_licenses(licenses)
    output = ROOT / "build" / "verification"
    output.mkdir(parents=True, exist_ok=True)
    executable = bundle / "LocationAnalysisPC.exe"
    environment = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    for mode in ["--self-test", "--smoke-test"]:
        subprocess.run([str(executable), mode, str(output)], check=True, timeout=120, env=environment)
    # A normal, empty startup is part of GUI smoke verification; no fixtures are shipped as user data.
    checks = {name: json.loads((output / name).read_text(encoding="utf-8")) for name in ["self-test.json", "gui-smoke.json", "unit-tests.json"]}
    if any(result.get("status") != "passed" for result in checks.values()):
        raise RuntimeError("Release checks did not pass.")
    release = ROOT / "build" / "release"
    release.mkdir(parents=True, exist_ok=True)
    archive = Path(shutil.make_archive(str(release / f"LocationAnalysisPC-{VERSION}-Windows-x64"), "zip", ROOT / "dist", "LocationAnalysisPC"))
    report = {"application": "LocationAnalysisPC", "version": VERSION, "commit": os.environ.get("GITHUB_SHA", "local"),
        "workflow_run": os.environ.get("GITHUB_RUN_ID", ""), "platform": platform.platform(), "python": platform.python_version(),
        "status": "passed", "archive": archive.name, "bytes": archive.stat().st_size,
        "sha256": hashlib.file_digest(archive.open("rb"), "sha256").hexdigest(),
        "executable_sha256": hashlib.file_digest(executable.open("rb"), "sha256").hexdigest(),
        "checks": checks, "data": "Synthetic fixtures only; no nationwide K-apt dataset bundled.", "code_signed": False}
    (release / f"LocationAnalysisPC-{VERSION}-verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"archive": str(archive), "bytes": report["bytes"], "status": report["status"]}))


if __name__ == "__main__":
    main()
