from __future__ import annotations

import csv
import codecs
import datetime as dt
import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from .models import CatalogRecord, clean, province_name, region_from_road, split_roads


FIELDS = {
    "code": ("단지코드", "kaptcode", "kapt코드", "공시가격id", "공시가격단지코드", "단지id", "id", "code"),
    "name": ("단지명", "아파트명", "공동주택명", "kaptname", "name"),
    "road": ("도로명주소", "도로명", "새주소", "도로명건물주소", "kaptdoroJuso", "doroJuso", "roadAddress", "roadAddresses"),
    "jibun": ("지번주소", "법정동주소", "단지주소", "주소", "kaptaddr", "jibunAddress"),
    "province": ("시도", "시도명", "광역시도", "as1", "province", "inventoryProvince"),
    "district": ("시군구", "시군구명", "as2", "district", "inventoryDistrict"),
    "households": ("세대수", "세대수(세대)", "총세대수", "kaptdaCnt", "households"),
    "buildings": ("동수", "동수(동)", "총동수", "kaptDongCnt", "buildings"),
    "use": ("단지분류", "단지분류명", "주용도", "용도", "codeAptNm", "use"),
    "approval_date": ("사용승인일", "사용승인일자", "사용검사일", "준공일", "kaptUsedate", "approvalDate"),
}
FIELD_LABELS = {"code": "단지코드 / 공시가격 ID", "name": "단지명", "road": "도로명주소", "jibun": "지번주소", "province": "시도", "district": "시군구", "households": "세대수", "buildings": "동수", "use": "단지분류 / 용도", "approval_date": "사용승인일"}


def header_key(value):
    return re.sub(r"[^0-9a-z가-힣]", "", clean(value).lower())


def infer_mapping(headers):
    keys = {header_key(h): h for h in headers}
    return {field: next((keys[header_key(alias)] for alias in aliases if header_key(alias) in keys), "") for field, aliases in FIELDS.items()}


@dataclass
class FileInfo:
    path: str
    headers: list[str]
    samples: list[dict]
    mapping: dict
    sheet: str = ""
    sheets: list[str] = field(default_factory=list)
    header_row: int = 0
    encoding: str = "utf-8-sig"
    delimiter: str = ","
    json_rows: list[dict] | None = None


def _cell_text(cell):
    value = cell.value
    if isinstance(value, (dt.datetime, dt.date)):
        return value.strftime("%Y-%m-%d")
    if isinstance(value, (int, float)) and re.fullmatch(r"0{2,}", cell.number_format or ""):
        return str(int(value)).zfill(len(cell.number_format))
    return clean(value)


def _flat_json_row(row):
    item = dict(row.get("fields") or {})
    item.update({k: v for k, v in row.items() if k not in {"fields", "rawBasic", "rawFacilities", "rawData", "addresses", "members"}})
    if "roadAddresses" in row and ("fetchedAt" in row or "inventoryProvince" in row or "inventoryDistrict" in row):
        item["_road_known"] = "1" if row.get("fetchedAt") is not None else "0"
    if not item.get("roadAddress") and not item.get("roadAddresses") and row.get("addresses"):
        item["roadAddresses"] = [a.get("roadAddress", "") for a in row["addresses"]]
    # Preserve the provenance and unmapped fields without transferring API settings.
    return {k: clean(v) if not isinstance(v, dict) else json.dumps(v, ensure_ascii=False) for k, v in item.items()}


def inspect_file(path, sheet="") -> FileInfo:
    path = Path(path)
    if not path.is_file():
        raise ValueError("선택한 파일을 찾을 수 없습니다.")
    suffix = path.suffix.lower()
    if suffix == ".json":
        root = json.loads(path.read_text(encoding="utf-8-sig"))
        if isinstance(root, list):
            rows = root
        elif isinstance(root, dict):
            rows = root.get("records", root.get("sources", root.get("items")))
            if rows is None and isinstance(root.get("concordance"), dict):
                rows = root["concordance"].get("sources")
        else:
            rows = None
        if not isinstance(rows, list) or not rows or not all(isinstance(r, dict) for r in rows):
            raise ValueError("JSON에서 records / sources / items 목록을 찾을 수 없습니다.")
        rows = [_flat_json_row(r) for r in rows]
        headers = list(dict.fromkeys(k for r in rows for k in r))
        return FileInfo(str(path), headers, rows[:8], infer_mapping(headers), json_rows=rows)
    if suffix == ".xlsx":
        import openpyxl
        book = openpyxl.load_workbook(path, read_only=True, data_only=True, keep_links=False)
        try:
            sheets = list(book.sheetnames)
            candidates = [sheet] if sheet else sheets
            best = None
            for name in candidates:
                rows = []
                for index, row in enumerate(book[name].iter_rows()):
                    if index >= 40:
                        break
                    rows.append([_cell_text(c) for c in row])
                if not rows:
                    continue
                result = _find_header(path, rows, name, sheets)
                if best is None or _header_score(result.headers) > _header_score(best.headers):
                    best = result
            if best is None:
                raise ValueError("읽을 수 있는 시트가 없습니다.")
            return best
        finally:
            book.close()
    if suffix == ".xls":
        import xlrd
        book = xlrd.open_workbook(str(path), on_demand=True)
        try:
            sheets = book.sheet_names()
            candidates = [sheet] if sheet else sheets
            best = None
            for name in candidates:
                page = book.sheet_by_name(name)
                rows = [[clean(v) for v in page.row_values(i)] for i in range(min(page.nrows, 40))]
                if not rows:
                    continue
                result = _find_header(path, rows, name, sheets)
                if best is None or _header_score(result.headers) > _header_score(best.headers):
                    best = result
            if best is None:
                raise ValueError("읽을 수 있는 시트가 없습니다.")
            return best
        finally:
            book.release_resources()
    if suffix not in {".csv", ".tsv", ".txt"}:
        raise ValueError("XLSX, XLS, CSV, TSV, JSON 파일을 선택하세요.")
    with path.open("rb") as handle:
        sample_bytes = handle.read(128_000)
    encoding = "utf-8-sig"
    try:
        sample = codecs.getincrementaldecoder(encoding)().decode(sample_bytes, final=False)
    except UnicodeDecodeError:
        encoding = "cp949"
        try:
            sample = codecs.getincrementaldecoder(encoding)().decode(sample_bytes, final=False)
        except UnicodeDecodeError:
            raise ValueError("파일의 문자 인코딩을 읽을 수 없습니다. UTF-8 또는 CP949 CSV로 저장하세요.") from None
    try:
        delimiter = csv.Sniffer().sniff(sample, delimiters=",\t;|").delimiter
    except csv.Error:
        delimiter = "\t" if suffix == ".tsv" else ","
    with path.open(encoding=encoding, newline="") as handle:
        import itertools
        rows = list(itertools.islice(csv.reader(handle, delimiter=delimiter), 40))
    result = _find_header(path, rows)
    result.encoding, result.delimiter = encoding, delimiter
    return result


def _header_score(headers):
    mapping = infer_mapping(headers)
    return 10 * bool(mapping["code"]) + 8 * bool(mapping["name"]) + sum(bool(v) for v in mapping.values())


def _find_header(path, rows, sheet="", sheets=None):
    if not rows:
        raise ValueError("파일이 비어 있습니다.")
    header_row = max(range(min(len(rows), 30)), key=lambda i: _header_score(rows[i]))
    seen = {}
    headers = []
    for i, raw in enumerate(rows[header_row]):
        h = clean(raw).replace("\n", " ") or f"이름없는열{i+1}"
        seen[h] = seen.get(h, 0) + 1
        headers.append(h if seen[h] == 1 else f"{h} ({seen[h]})")
    samples = [dict(zip(headers, (clean(v) for v in row))) for row in rows[header_row+1:header_row+9]]
    return FileInfo(str(path), headers, samples, infer_mapping(headers), sheet, sheets or [], header_row)


def iter_rows(info: FileInfo):
    suffix = Path(info.path).suffix.lower()
    if info.json_rows is not None:
        for i, row in enumerate(info.json_rows, 1):
            yield i, row
    elif suffix == ".xlsx":
        import openpyxl
        book = openpyxl.load_workbook(info.path, read_only=True, data_only=True, keep_links=False)
        try:
            for i, row in enumerate(book[info.sheet].iter_rows(min_row=info.header_row+2), info.header_row+2):
                yield i, dict(zip(info.headers, (_cell_text(c) for c in row)))
        finally:
            book.close()
    elif suffix == ".xls":
        import xlrd
        book = xlrd.open_workbook(info.path, on_demand=True)
        try:
            sheet = book.sheet_by_name(info.sheet)
            for i in range(info.header_row+1, sheet.nrows):
                values = []
                for c in sheet.row(i):
                    values.append(xlrd.xldate.xldate_as_datetime(c.value, book.datemode).strftime("%Y-%m-%d") if c.ctype == xlrd.XL_CELL_DATE else clean(c.value))
                yield i+1, dict(zip(info.headers, values))
        finally:
            book.release_resources()
    else:
        with open(info.path, encoding=info.encoding, newline="") as handle:
            for i, row in enumerate(csv.reader(handle, delimiter=info.delimiter), 1):
                if i > info.header_row+1:
                    yield i, dict(zip(info.headers, (clean(v) for v in row)))


def parse_records(info: FileInfo, mapping: dict | None = None, progress=None, cancelled=None):
    mapping = mapping or info.mapping
    if not mapping.get("code") or not mapping.get("name"):
        raise ValueError("단지코드와 단지명 열을 연결하세요.")
    records: dict[str, CatalogRecord] = {}
    repeated = 0
    for number, raw in iter_rows(info):
        if cancelled and cancelled():
            raise InterruptedError("가져오기를 취소했습니다. 기존 자료는 그대로 유지됩니다.")
        if not any(clean(v) for v in raw.values()):
            continue
        values = {field: clean(raw.get(column, "")) for field, column in mapping.items()}
        code, name = values.get("code", ""), values.get("name", "")
        # A downloaded inventory without details is not proof of a demolished complex.
        if not code or not name:
            raise ValueError(f"{number}행: 단지코드 또는 단지명이 없습니다. 누락된 행을 수정한 후 다시 가져오세요.")
        roads, issues = split_roads(values.get("road", ""))
        province, district = region_from_road(roads)
        item = CatalogRecord(code, name, values.get("road", ""), roads, issues,
            values.get("jibun", ""), province_name(values.get("province") or province), values.get("district") or district,
            values.get("households", ""), values.get("buildings", ""), values.get("use", ""), values.get("approval_date", ""), raw)
        item.road_known = raw.get("_road_known") != "0"
        try:
            item.validate()
        except ValueError as error:
            raise ValueError(f"{number}행: {error}") from None
        old = records.get(code)
        if old:
            keys = ("name", "jibun", "province", "district", "households", "buildings", "use", "approval_date")
            conflicts = [key for key in keys if getattr(old, key) and getattr(item, key) and getattr(old, key) != getattr(item, key)]
            if conflicts:
                raise ValueError(f"{number}행: 같은 코드 {code}의 {', '.join(FIELD_LABELS.get(k,k) for k in conflicts)} 값이 서로 다릅니다. 임의로 덮어쓰지 않았습니다.")
            for key in keys:
                if not getattr(old, key):
                    setattr(old, key, getattr(item, key))
            old.roads = list(dict.fromkeys(old.roads + roads))
            old.road_issues = list(dict.fromkeys(old.road_issues + issues))
            old.road_raw = "\n".join(dict.fromkeys([old.road_raw, item.road_raw])).strip()
            old.raw.setdefault("추가원본행", []).append(raw)
            repeated += 1
        else:
            records[code] = item
        if progress and len(records) % 200 == 0:
            progress(len(records), f"{len(records):,}개 단지 읽음")
    if not records:
        raise ValueError("가져올 단지가 없습니다.")
    return list(records.values()), repeated


def file_sha256(path):
    sha = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(1024*1024):
            sha.update(chunk)
    return sha.hexdigest()
