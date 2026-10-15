"""Fetch verified, redistributable Korean fonts for desktop builds."""
from __future__ import annotations

import hashlib
from pathlib import Path
from urllib.request import Request, urlopen
from concurrent.futures import ThreadPoolExecutor


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "location_analysis" / "assets"
FONTS = {
    "NanumGothic-Regular.ttf": "2aa2b20905b4136808a0126d8e36e5c0f576715c",
    "NanumGothic-Bold.ttf": "79a9bdc1fa190b5786b247bb5db6a00893e620fb",
    "OFL.txt": "69ff40157d0bba4c65e4ecf77564e1f01d0b02a5",
}
QT_LICENSES = {
    "Apache-2.0.txt": "136d90045663ab0acaeff2a3ecf0013c968de8c9",
    "BSD-3-Clause.txt": "b91bbd89468099ae5c3028f176783976ca538187",
    "GFDL-1.3-no-invariants-only.txt": "857214dd84593e0bacaac0211d76de0b69f2fa18",
    "GPL-2.0-only.txt": "d159169d1050894d3ea3b98e1c965c4058208fe1",
    "GPL-3.0-only.txt": "94a9ed024d3859793618152ea559a168bbcbb5e2",
    "LGPL-3.0-only.txt": "65c5ca88a67c30becee01c5a8816d964b03862f9",
    "LicenseRef-Qt-Commercial.txt": "825b1f358b1f42d762112defbf0a193c9d968488",
    "Qt-GPL-exception-1.0.txt": "d0322bf0e4e1d484d35cc6a1d96fa2b65b9d579b",
}


def blob_hash(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def fetch(item):
    path, url, expected = item
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and blob_hash(path.read_bytes()) == expected:
        return
    with urlopen(Request(url, headers={"User-Agent": "LocationAnalysisPC-build"}), timeout=45) as response:
        data = response.read()
    if blob_hash(data) != expected:
        raise ValueError(f"Asset integrity check failed: {path.name}")
    path.write_bytes(data)


def main():
    resources = [(ASSETS/name, "https://raw.githubusercontent.com/google/fonts/main/ofl/nanumgothic/"+name, digest) for name,digest in FONTS.items()]
    resources += [(ASSETS/"licenses"/name, "https://raw.githubusercontent.com/pyside/pyside-setup/v6.8.3/LICENSES/"+name, digest) for name,digest in QT_LICENSES.items()]
    with ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(fetch, resources))
    print(f"Verified desktop assets: {len(resources)}")


if __name__ == "__main__":
    main()
