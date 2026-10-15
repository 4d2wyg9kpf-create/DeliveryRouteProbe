"""Explicit build verification. Never runs on a normal launch or seeds user data."""
from __future__ import annotations

import csv
import json
import platform
import tempfile
from pathlib import Path

from . import VERSION
from .importer import inspect_file
from .models import CatalogRecord, region_from_road, split_roads
from .storage import CatalogStore


def sample_record(code,name,road):
    roads,issues=split_roads(road);p,d=region_from_road(roads)
    return CatalogRecord(code,name,road,roads,issues,province=p,district=d,households="420",buildings="4",use="아파트",raw={"단지코드":code,"단지명":name,"도로명주소":road,"자료종류":"검증용 가상 자료"})


def populate(store):
    records=[
        sample_record("TEST-A001","가상 새봄아파트","대전광역시 서구 예제로 10"),
        sample_record("TEST-A002","가상 새봄아파트 2단지","대전광역시 서구 예제로 10"),
        sample_record("TEST-A003","가상 푸른마을","서울특별시 강서구 가상로 120, 122"),
        sample_record("TEST-A004","가상 이전 등록","대전광역시 서구 예제로 10"),
        sample_record("TEST-A005","가상 주소 공란 단지",""),
        sample_record("TEST-A006","가상 해오름아파트","부산광역시 해운대구 시험로 55"),
    ]
    store.import_records(records,source_date="2026-01-01",full_snapshot=True,filename="검증용 가상 자료")
    prices=[sample_record("TEST-P001","가상 새봄 공시가격 원본","대전광역시 서구 예제로 10"),sample_record("TEST-P002","가상 푸른마을 동측","서울특별시 강서구 가상로 120"),sample_record("TEST-P003","가상 푸른마을 서측","서울특별시 강서구 가상로 122")]
    store.import_records(prices,kind="realty",filename="검증용 가상 자료")
    store.save_review("TEST-A001",verdict="valid",reason="검증용 확인",selected_road=records[0].roads[0],building_name="101동",member_confirmed=True,latitude=36.35,longitude=127.38,entrance_confirmed=True,realty_codes=["TEST-P001"])
    store.save_review("TEST-A002",verdict="valid",reason="동일 주소의 별개 단지",selected_road=records[1].roads[0],realty_codes=["TEST-P001"])
    store.save_review("TEST-A003",verdict="valid",reason="두 주소가 한 관리단지",selected_road=records[2].roads[0],realty_codes=["TEST-P002","TEST-P003"])
    store.save_review("TEST-A004",verdict="excluded",reason="중복 등록",note="TEST-A001 채택")
    return records


def self_test(output):
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="location-self-test-") as temporary:
        root=Path(temporary);store=CatalogStore(root/"catalog.sqlite3");populate(store)
        stats=store.stats();assert stats["total"]==6 and stats["candidates"]==4 and stats["confirmed"]==1
        _,duplicates=store.list_complexes(page="duplicates");assert duplicates==3
        assert len(store.get_complex("TEST-A003")["links"])==2
        store.export_standards(root/"표준지.xlsx");store.export_standards(root/"표준지.csv")
        import openpyxl
        book=openpyxl.load_workbook(root/"표준지.xlsx",read_only=True);assert book.active.max_row==5;book.close()
        store.backup(root/"backup.sqlite3");CatalogStore.validate_backup(root/"backup.sqlite3")
        copy=CatalogStore(root/"restored.sqlite3");copy.restore(root/"backup.sqlite3");assert copy.stats()==stats
    report={"version":VERSION,"status":"passed","platform":platform.platform(),"python":platform.python_version(),"checks":["same-address-distinct-kapt","one-standard-per-kapt","many-to-many-links","blank-road-exclusion","verified-entrance","xlsx-csv-export","sqlite-backup-restore"],"fixture_data_only":True}
    (output/"self-test.json").write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
    return report


def gui_smoke(output):
    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication
    from .gui import MainWindow,ReviewDialog,ImportDialog,STYLE
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    temporary=tempfile.TemporaryDirectory(prefix="location-gui-test-")
    app=QApplication.instance() or QApplication([]);app.setStyle("Fusion");app.setStyleSheet(STYLE)
    store=CatalogStore(Path(temporary.name)/"catalog.sqlite3")
    empty=MainWindow(store);empty.show();app.processEvents()
    assert store.stats()["total"]==0 and empty.empty.isVisible() and empty.isVisible()
    empty.grab().save(str(output/"empty.png"));empty.close();app.processEvents()
    populate(store)
    window=MainWindow(store);window.show();app.processEvents()
    window.grab().save(str(output/"catalog.png"))
    counts={}
    for _,page in window.PAGES:
        window.change_page(page);app.processEvents();counts[page]=window.total
        assert window.total>=0
    window.change_page("standards");app.processEvents();window.grab().save(str(output/"standards.png"))
    dialog=ReviewDialog(store,"TEST-A001",window);dialog.show();app.processEvents();dialog.grab().save(str(output/"review.png"));dialog.close()
    fixture=Path(temporary.name)/"import.csv"
    with fixture.open("w",encoding="utf-8-sig",newline="") as handle:
        csv.writer(handle).writerows([["단지코드","단지명","도로명주소","세대수","동수"],["TEST-I001","가상 가져오기 단지","서울특별시 강서구 예제로 1","420","4"]])
    dialog=ImportDialog(inspect_file(fixture),"kapt",window);dialog.show();app.processEvents();dialog.grab().save(str(output/"import.png"));dialog.close()
    window.resize(1180,720);app.processEvents();window.grab().save(str(output/"compact.png"))
    assert counts["kapt"]==6 and counts["standards"]==4 and counts["realty"]==3
    window.close();app.processEvents()
    report={"version":VERSION,"status":"passed","platform":platform.platform(),"screen":app.primaryScreen().size().toTuple(),"page_counts":counts,"empty_startup":True,"import_mapping_dialog":True,"review_dialog":True,"fixture_data_only":True}
    (output/"gui-smoke.json").write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
    temporary.cleanup();return report
