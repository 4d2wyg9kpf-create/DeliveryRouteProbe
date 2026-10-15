from __future__ import annotations

import hashlib
import json
import math
import re
import unicodedata
from dataclasses import dataclass, field


PROVINCES = {
    "서울": "서울특별시", "서울시": "서울특별시", "부산": "부산광역시", "부산시": "부산광역시",
    "대구": "대구광역시", "대구시": "대구광역시", "인천": "인천광역시", "인천시": "인천광역시",
    "광주": "광주광역시", "광주시": "광주광역시", "대전": "대전광역시", "대전시": "대전광역시",
    "울산": "울산광역시", "울산시": "울산광역시", "세종": "세종특별자치시", "세종시": "세종특별자치시",
    "경기": "경기도", "강원": "강원특별자치도", "강원도": "강원특별자치도",
    "충북": "충청북도", "충남": "충청남도", "전북": "전북특별자치도", "전라북도": "전북특별자치도",
    "전남": "전라남도", "경북": "경상북도", "경남": "경상남도", "제주": "제주특별자치도", "제주도": "제주특별자치도",
}


def clean(value) -> str:
    if value is None:
        return ""
    if isinstance(value, float):
        if not math.isfinite(value):
            return ""
        if value.is_integer():
            return str(int(value))
    if isinstance(value, (list, tuple)):
        return "\n".join(clean(v) for v in value)
    return re.sub(r"[ \t\r\u00a0]+", " ", unicodedata.normalize("NFKC", str(value))).strip()


def json_text(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def fingerprint(value) -> str:
    return hashlib.sha256(json_text(value).encode("utf-8")).hexdigest()


def province_name(value: str) -> str:
    value = clean(value)
    return PROVINCES.get(value, value)


# Require the actual building number; never identify 1, 10 and 1-1 as one address.
ROAD = re.compile(r"^(?P<prefix>.+?(?:대로|로|길))\s+(?P<underground>지하\s*)?(?P<main>\d+)(?:\s*[-−]\s*(?P<sub>\d+))?(?P<tail>.*)$")


def road_key(value: str) -> str:
    value = clean(value).replace("−", "-")
    value = re.sub(r"\([^)]*\)", "", value).strip()
    match = ROAD.match(value)
    if not match:
        return ""
    words = match["prefix"].split()
    if len(words) < 2 or not (words[0] in PROVINCES or words[0].endswith(("시", "도"))):
        return ""
    words[0] = province_name(words[0])
    # The tail may contain detailed address, but cannot smuggle another building number.
    tail = match["tail"].strip()
    if tail and not re.match(r"^(?:[, ]*(?:\d+동|\d+층|\d+호|지하\d+층|[가-힣A-Za-z]+동)(?:\s|,|$))", tail):
        return ""
    number = str(int(match["main"]))
    if match["sub"] and int(match["sub"]):
        number += "-" + str(int(match["sub"]))
    return " ".join(words) + " " + ("지하 " if match["underground"] else "") + number


def split_roads(value) -> tuple[list[str], list[str]]:
    """Split full/abbreviated road addresses, keeping commas inside parentheses intact."""
    if isinstance(value, (list, tuple)):
        tokens = [clean(x) for x in value]
    else:
        text = clean(value)
        if not text or text.lower() in {"없음", "해당없음", "null", "none", "nan", "-"}:
            return [], []
        tokens, part, depth = [], [], 0
        for char in text:
            depth += (char == "(") - (char == ")")
            if char in "\n;|/" or (char == "," and depth <= 0):
                tokens.append("".join(part).strip()); part = []
            else:
                part.append(char)
        tokens.append("".join(part).strip())
    roads, issues = [], []
    last_prefix = ""
    last_area = ""
    for token in tokens:
        if not token:
            continue
        token = re.sub(r"^도로명주소\s*[:：]?\s*", "", token).strip()
        candidate = token
        if re.match(r"^(?:지하\s*)?\d+(?:-\d+)?\s*(?:\([^)]*\))?$", token) and last_prefix:
            candidate = last_prefix + " " + token
        elif last_area and not road_key(token) and re.match(r"^\S+(?:대로|로|길)\s+", token):
            candidate = last_area + " " + token
        key = road_key(candidate)
        if not key:
            issues.append(token)
            continue
        if key not in roads:
            roads.append(key)
        match = ROAD.match(key)
        last_prefix = match["prefix"]
        last_area = " ".join(last_prefix.split()[:-1])
    return roads, issues


def region_from_road(roads: list[str]) -> tuple[str, str]:
    if not roads:
        return "", ""
    words = roads[0].split()
    district = []
    for word in words[1:]:
        if word.endswith(("시", "군", "구")):
            district.append(word)
        else:
            break
    return province_name(words[0]), " ".join(district)


@dataclass
class CatalogRecord:
    code: str
    name: str
    road_raw: str = ""
    roads: list[str] = field(default_factory=list)
    road_issues: list[str] = field(default_factory=list)
    jibun: str = ""
    province: str = ""
    district: str = ""
    households: str = ""
    buildings: str = ""
    use: str = ""
    approval_date: str = ""
    raw: dict = field(default_factory=dict)
    road_known: bool = True

    def normalized(self):
        return {key: value for key, value in self.__dict__.items() if key != "raw"}

    @property
    def scope_hash(self):
        return fingerprint(self.normalized())

    def validate(self):
        if not self.code or not re.fullmatch(r"[A-Za-z0-9:_-]{1,150}", self.code):
            raise ValueError("단지코드에는 영문·숫자·하이픈·밑줄·콜론만 사용할 수 있습니다.")
        if not self.name:
            raise ValueError("단지명이 없습니다.")


def validate_coordinates(latitude, longitude):
    if latitude in (None, "") and longitude in (None, ""):
        return None, None
    try:
        lat, lon = float(latitude), float(longitude)
    except (TypeError, ValueError):
        raise ValueError("위도와 경도를 모두 숫자로 입력하세요.") from None
    if not (math.isfinite(lat) and math.isfinite(lon) and -90 <= lat <= 90 and -180 <= lon <= 180):
        raise ValueError("위도·경도의 범위를 확인하세요.")
    return lat, lon
