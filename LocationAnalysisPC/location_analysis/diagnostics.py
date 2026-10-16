"""Explicit build verification. Never runs on a normal launch or seeds user data."""
from __future__ import annotations

import csv
import json
import platform
import tempfile
from zipfile import ZipFile,ZIP_DEFLATED
from xml.sax.saxutils import escape
from pathlib import Path

from . import VERSION
from .importer import inspect_file
from .models import CatalogRecord, region_from_road, split_roads
from .storage import CatalogStore


def sample_record(code,name,road):
    roads,issues=split_roads(road);p,d=region_from_road(roads)
    return CatalogRecord(code,name,road,roads,issues,province=p,district=d,households="420",buildings="4",use="아파트",raw={"단지코드":code,"단지명":name,"도로명주소":road,"자료종류":"검증용 가상 자료"})


def write_kapt_import_fixture(path):
    """Synthetic provider-format regression fixture; intentionally declares A1."""
    headers=["시도","시군구","읍면","동리","단지코드","단지명","단지분류","법정동주소","우편번호","도로명주소","분양형태","사용승인일","가입일","동수","세대수","총주차대수"]
    headers += [f"추가항목{i}" for i in range(1,73)]
    rows=[["검증용 가상 자료입니다. 실제 단지정보가 아닙니다. "*30],headers]
    for code,name,road in [("TEST-I001","가상 가져오기 단지","대전광역시 서구 예제로 10"),("TEST-I001","가상 가져오기 단지","대전광역시 서구 예제로 12"),("TEST-I002","가상 별개 단지","대전광역시 서구 예제로 10")]:
        rows.append(["대전광역시","서구","","가상동",code,name,"아파트","가상 지번","01234",road,"분양","20000101","20010101","4","420","500"]+[""]*72)
    def column_name(number):
        result=""
        while number:
            number,digit=divmod(number-1,26);result=chr(65+digit)+result
        return result
    sheet_rows=[]
    for i,row in enumerate(rows,1):
        cells="".join(f'<c r="{column_name(j)}{i}" t="inlineStr"><is><t>{escape(str(value))}</t></is></c>' for j,value in enumerate(row,1))
        sheet_rows.append(f'<row r="{i}">{cells}</row>')
    main="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    rel="http://schemas.openxmlformats.org/package/2006/relationships"
    office="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    files={
        "[Content_Types].xml":'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
        "_rels/.rels":f'<Relationships xmlns="{rel}"><Relationship Id="rId1" Type="{office}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
        "xl/workbook.xml":f'<workbook xmlns="{main}" xmlns:r="{office}"><sheets><sheet name="sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
        "xl/_rels/workbook.xml.rels":f'<Relationships xmlns="{rel}"><Relationship Id="rId1" Type="{office}/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
        "xl/worksheets/sheet1.xml":f'<worksheet xmlns="{main}"><dimension ref="A1"/><sheetData>{"".join(sheet_rows)}</sheetData></worksheet>',
    }
    with ZipFile(path,"w",ZIP_DEFLATED) as archive:
        for name,value in files.items():archive.writestr(name,value)


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
    from PySide6.QtCore import QSettings
    from PySide6.QtGui import QPalette,QColor
    from PySide6.QtWidgets import QApplication
    from .gui import MainWindow,ReviewDialog,ImportDialog,apply_theme
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    temporary=tempfile.TemporaryDirectory(prefix="location-gui-test-")
    app=QApplication.instance() or QApplication([])
    dark=QPalette()
    for role in [QPalette.Window,QPalette.Base,QPalette.Button]:dark.setColor(role,QColor("#151515"))
    for role in [QPalette.Text,QPalette.WindowText,QPalette.ButtonText]:dark.setColor(role,QColor("#eeeeee"))
    app.setPalette(dark);apply_theme(app,15)
    assert app.palette().color(QPalette.Window).lightness()>230 and app.palette().color(QPalette.Text).lightness()<70
    settings=QSettings(str(Path(temporary.name)/"display.ini"),QSettings.IniFormat)
    store=CatalogStore(Path(temporary.name)/"catalog.sqlite3")
    empty=MainWindow(store,settings);empty.show();app.processEvents()
    assert store.stats()["total"]==0 and empty.empty.isVisible() and empty.isVisible()
    empty.grab().save(str(output/"empty.png"));empty.close();app.processEvents()
    populate(store)
    window=MainWindow(store,settings);window.show();app.processEvents()
    window.grab().save(str(output/"catalog.png"))
    counts={}
    for _,page in window.PAGES:
        window.change_page(page);app.processEvents();counts[page]=window.total
        assert window.total>=0
    window.change_page("standards");app.processEvents();window.grab().save(str(output/"standards.png"))
    dialog=ReviewDialog(store,"TEST-A001",window);dialog.show();app.processEvents();dialog.grab().save(str(output/"review.png"));dialog.close()
    fixture=Path(temporary.name)/"import.xlsx";write_kapt_import_fixture(fixture)
    info=inspect_file(fixture)
    assert info.header_row==1 and len(info.headers)==88 and len(info.samples)==3
    dialog=ImportDialog(info,"kapt",window);dialog.show();app.processEvents();dialog.grab().save(str(output/"import.png"))
    assert not dialog.mapping_section.isVisible()
    assert dialog.body_scroll.widget().palette().color(QPalette.Window).lightness()>230
    screen=dialog.screen().availableGeometry()
    assert screen.contains(dialog.frameGeometry())
    assert all(dialog.maps[key].currentData() for key in ["code","name","road"])
    assert dialog.controls.isVisible() and dialog.preview.rowCount()==3
    dialog.resize(min(580,screen.width()-32),min(520,screen.height()-48));app.processEvents()
    assert dialog._mapping_columns==1 and dialog.controls.isVisible()
    dialog.grab().save(str(output/"import-narrow.png"))
    dialog.mapping_toggle.setChecked(True);app.processEvents();dialog.grab().save(str(output/"import-mapping-expanded.png"))
    dialog.body_scroll.verticalScrollBar().setValue(dialog.body_scroll.verticalScrollBar().maximum());app.processEvents()
    dialog.grab().save(str(output/"import-narrow-bottom.png"));dialog.close()
    imported=CatalogStore(Path(temporary.name)/"imported.sqlite3")
    summary=imported.import_file(info)
    assert summary["total"]==2 and summary["repeated"]==1 and imported.stats()["candidates"]==2
    window.resize(1180,720);app.processEvents();window.grab().save(str(output/"compact.png"))
    window.text_size.setCurrentIndex(window.text_size.findData(19));app.processEvents();window.grab().save(str(output/"large-text.png"))
    assert settings.value("text_size")==19
    assert window.guide_button.isVisible() and window.table.isVisible()
    assert counts["kapt"]==6 and counts["standards"]==4 and counts["realty"]==3
    window.close();app.processEvents()
    report={"version":VERSION,"status":"passed","platform":platform.platform(),"screen":app.primaryScreen().size().toTuple(),"page_counts":counts,"empty_startup":True,"import_mapping_dialog":True,"review_dialog":True,"import_window_within_screen":True,"narrow_import_controls_accessible":True,"provider_incorrect_dimension_88_columns":True,"dark_system_palette_overridden":True,"manual_mapping_collapsed_when_valid":True,"large_text_preference":True,"next_step_guide":True,"fixture_data_only":True}
    (output/"gui-smoke.json").write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
    temporary.cleanup();return report
