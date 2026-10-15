"""Fetch verified, redistributable Korean fonts for desktop builds."""
from __future__ import annotations

import hashlib
from pathlib import Path
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "location_analysis" / "assets"
FONTS = {
    "NanumGothic-Regular.ttf": "2aa2b20905b4136808a0126d8e36e5c0f576715c",
    "NanumGothic-Bold.ttf": "79a9bdc1fa190b5786b247bb5db6a00893e620fb",
    "OFL.txt": "69ff40157d0bba4c65e4ecf77564e1f01d0b02a5",
}


def blob_hash(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    for filename, expected in FONTS.items():
        path = ASSETS / filename
        if path.exists() and blob_hash(path.read_bytes()) == expected:
            continue
        url = "https://raw.githubusercontent.com/google/fonts/main/ofl/nanumgothic/" + filename
        with urlopen(Request(url, headers={"User-Agent": "LocationAnalysisPC-build"}), timeout=45) as response:
            data = response.read()
        if blob_hash(data) != expected:
            raise ValueError(f"Font integrity check failed: {filename}")
        path.write_bytes(data)
    print("Verified Korean font assets: 3")


if __name__ == "__main__":
    main()
