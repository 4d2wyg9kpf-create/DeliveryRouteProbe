from __future__ import annotations

import csv
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import Qt,QRect,QSettings
from PySide6.QtGui import QFontDatabase, QFont,QPalette,QColor
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialog

from location_analysis.diagnostics import populate,write_kapt_import_fixture
from location_analysis.gui import ImportDialog, MainWindow, ReviewDialog, RealtyPicker,apply_theme
from location_analysis.importer import inspect_file,FileInfo,infer_mapping
from location_analysis.storage import CatalogStore


class GuiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        apply_theme(cls.app,15)
        root = Path(__file__).resolve().parents[1]
        for path in (root / "location_analysis" / "assets").glob("*.ttf"):
            number = QFontDatabase.addApplicationFont(str(path))
            families = QFontDatabase.applicationFontFamilies(number)
            if families and os.name!="nt":cls.app.setFont(QFont(families[0],11))
        if os.name=="nt":cls.app.setFont(QFont("Malgun Gothic",11))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.store = CatalogStore(self.root / "catalog.sqlite3")
        self.records = populate(self.store)
        self.settings=QSettings(str(self.root/"display.ini"),QSettings.IniFormat)
        self.window = MainWindow(self.store,self.settings)
        self.window.show()
        self.app.processEvents()

    def tearDown(self):
        if self.window.job:
            self.window.job.requestInterruption()
            self.window.job.wait(5000)
        self.window.close()
        self.app.processEvents()
        self.temporary.cleanup()

    def test_dark_os_palette_is_replaced_for_import_and_review_bodies(self):
        dark=QPalette()
        for role in [QPalette.Window,QPalette.Base,QPalette.Button]:dark.setColor(role,QColor("#151515"))
        for role in [QPalette.Text,QPalette.WindowText,QPalette.ButtonText]:dark.setColor(role,QColor("#eeeeee"))
        self.app.setPalette(dark);apply_theme(self.app,15)
        path=self.root/"provider.xlsx";write_kapt_import_fixture(path)
        imported=ImportDialog(inspect_file(path),"kapt",self.window)
        reviewed=ReviewDialog(self.store,"TEST-A001",self.window)
        imported.show();reviewed.show();self.app.processEvents()
        for body in [imported.body_scroll.widget(),reviewed.findChild(type(imported.body_scroll.widget()),"reviewBody")]:
            self.assertGreater(body.palette().color(QPalette.Window).lightness(),230)
            self.assertLess(body.palette().color(QPalette.WindowText).lightness(),70)
        self.assertGreater(imported.maps["road"].palette().color(QPalette.Base).lightness(),240)
        imported.close();reviewed.close()

    def test_text_size_is_persisted_without_changing_catalog(self):
        before=self.store.stats()
        self.window.text_size.setCurrentIndex(self.window.text_size.findData(19));self.app.processEvents()
        self.assertEqual(self.app.property("textSize"),19)
        reopened=MainWindow(self.store,self.settings)
        self.assertEqual(reopened.text_size.currentData(),19)
        self.assertEqual(reopened.store.stats(),before)
        self.assertEqual(self.window.table.verticalHeader().defaultSectionSize(),61)
        reopened.close()

    def test_next_step_navigation_clears_search_and_region_filters(self):
        self.window.search.setText("없는 단지");self.window.search_timer.stop()
        self.window.province.setCurrentIndex(self.window.province.findData("부산광역시"))
        QTest.mouseClick(self.window.guide_button,Qt.LeftButton)
        self.assertEqual((self.window.page,self.window.total),("duplicates",3))
        self.assertEqual(self.window.search.text(),"")
        self.assertEqual(self.window.province.currentData(),"")
        QTest.mouseClick(self.window.guide_button,Qt.LeftButton)
        self.assertEqual((self.window.page,self.window.total),("standards",4))
        self.window.change_page("realty")
        self.assertIn("추후",self.window.guide_body.text())

    def wait_for(self, predicate, timeout=4):
        deadline = time.monotonic() + timeout
        while not predicate() and time.monotonic() < deadline:
            QTest.qWait(10)
        self.assertTrue(predicate())

    def test_enter_search_and_region_filter(self):
        self.window.search.setText("해오름")
        QTest.keyClick(self.window.search, Qt.Key_Return)
        self.assertEqual(self.window.total, 1)
        self.window.search.clear()
        self.window.search_timer.stop()
        self.window.province.setCurrentIndex(self.window.province.findData("대전광역시"))
        self.assertEqual(self.window.total, 3)
        self.assertEqual(self.window.district.itemText(1), "서구")

    def test_sidebar_and_candidate_counts(self):
        QTest.mouseClick(self.window.nav["standards"], Qt.LeftButton)
        self.assertEqual((self.window.page, self.window.total), ("standards", 4))
        QTest.mouseClick(self.window.nav["duplicates"], Qt.LeftButton)
        self.assertEqual(self.window.total, 3)
        QTest.mouseClick(self.window.nav["realty"], Qt.LeftButton)
        self.assertEqual(self.window.total, 3)
        self.assertFalse(self.window.review_button.isVisible())
        self.assertTrue(self.window.manual_button.isVisible())

    def test_single_address_preselected_but_multiple_require_choice(self):
        one = ReviewDialog(self.store, "TEST-A002", self.window)
        several = ReviewDialog(self.store, "TEST-A003", self.window)
        self.assertTrue(one.road.currentData())
        # A003 already has a reviewed choice; an unreviewed multiple-address source does not.
        self.store.save_review("TEST-A003", verdict="pending")
        pending = ReviewDialog(self.store, "TEST-A003", self.window)
        self.assertEqual(pending.road.currentData(), "")
        one.close(); several.close(); pending.close()

    def test_review_save_and_invalid_coordinate_feedback(self):
        dialog = ReviewDialog(self.store, "TEST-A001", self.window)
        dialog.lat.setText("invalid")
        with patch("location_analysis.gui.QMessageBox.warning") as warning:
            dialog.save()
            self.assertTrue(warning.called)
        self.assertEqual(self.store.get_complex("TEST-A001")["status"], "확정")
        dialog.verdict.setCurrentIndex(dialog.verdict.findData("excluded"))
        dialog.reason.setCurrentText("중복 등록")
        dialog.save()
        self.assertEqual(dialog.result(), QDialog.Accepted)
        self.assertEqual(self.store.get_complex("TEST-A001")["status"], "제외")
        dialog.close()

    def test_import_mapping_validation_and_explicit_full_snapshot(self):
        path = self.root / "sample.csv"
        with path.open("w", encoding="utf-8-sig", newline="") as handle:
            csv.writer(handle).writerows([["단지코드", "단지명", "도로명주소"], ["A001", "가상", "서울 강서구 예제로 1"]])
        dialog = ImportDialog(inspect_file(path), "kapt", self.window)
        dialog.show();self.app.processEvents()
        self.assertFalse(dialog.full.isChecked())
        self.assertFalse(dialog.mapping_section.isVisible())
        self.assertEqual([dialog.preview.horizontalHeaderItem(i).text() for i in range(3)],["단지명","단지코드","도로명주소"])
        dialog.maps["road"].setCurrentIndex(0)
        self.assertTrue(dialog.mapping_section.isVisible())
        with patch("location_analysis.gui.QMessageBox.warning") as warning:
            dialog.validate()
            self.assertTrue(warning.called)
        dialog.maps["road"].setCurrentIndex(dialog.maps["road"].findData("도로명주소"))
        dialog.validate()
        self.assertEqual(dialog.result(), QDialog.Accepted)
        dialog.close()

    def test_import_long_headers_and_sheet_names_stay_within_screen(self):
        long_header="안내문을 포함한 매우 긴 열 이름입니다. "*120
        headers=["단지코드","단지명","도로명주소",long_header]
        info=FileInfo("길고_긴_파일명_"*50+".xlsx",headers,[],infer_mapping(headers),sheet="긴 시트 이름"*20,sheets=["긴 시트 이름"*20])
        dialog=ImportDialog(info,"kapt",self.window);dialog.show();self.app.processEvents()
        self.assertTrue(dialog.screen().availableGeometry().contains(dialog.frameGeometry()))
        self.assertLessEqual(dialog.width(),980)
        self.assertLess(dialog.minimumSizeHint().width(),500)
        self.assertEqual(dialog.maps["road"].currentData(),"도로명주소")
        selector=dialog.maps["road"]
        selector.setCurrentIndex(selector.findData(long_header))
        self.assertEqual(selector.currentData(),long_header)
        self.assertEqual(selector.toolTip(),long_header)
        self.app.processEvents()
        self.assertTrue(dialog.screen().availableGeometry().contains(dialog.frameGeometry()))
        dialog.close()

    def test_import_narrow_scrolls_content_and_keeps_actions_visible(self):
        path=self.root/"provider.xlsx";write_kapt_import_fixture(path)
        dialog=ImportDialog(inspect_file(path),"kapt",self.window);dialog.show()
        dialog.mapping_toggle.setChecked(True)
        dialog.resize(580,500);self.app.processEvents()
        self.assertEqual(dialog._mapping_columns,1)
        self.assertEqual((dialog.preview.rowCount(),dialog.preview.columnCount()),(3,88))
        self.assertTrue(dialog.controls.isVisible())
        self.assertTrue(dialog.rect().contains(dialog.controls.geometry()))
        scroll=dialog.body_scroll.verticalScrollBar()
        self.assertGreater(scroll.maximum(),0)
        scroll.setValue(scroll.maximum());self.app.processEvents()
        visible_full=dialog.full.mapTo(dialog.body_scroll.viewport(),dialog.full.rect().center())
        self.assertTrue(dialog.body_scroll.viewport().rect().contains(visible_full))
        for key,expected in [("code","단지코드"),("name","단지명"),("road","도로명주소")]:
            self.assertEqual(dialog.maps[key].currentData(),expected)
        dialog.validate()
        self.assertEqual(dialog.result(),QDialog.Accepted)
        dialog.close()

    def test_import_mapping_reflows_to_two_columns_on_wide_screen(self):
        path=self.root/"provider.xlsx";write_kapt_import_fixture(path)
        screen=self.window.screen()
        with patch.object(screen,"availableGeometry",return_value=QRect(0,0,1280,800)):
            dialog=ImportDialog(inspect_file(path),"kapt",self.window)
            dialog.resize(980,720);dialog.show();self.app.processEvents()
            self.assertEqual(dialog._mapping_columns,2)
            self.assertTrue(screen.availableGeometry().contains(dialog.frameGeometry()))
            self.assertEqual(dialog.preview_caption.text(),"미리보기 · 처음 3개 행 · 전체 88개 열 · 제목은 2행")
        dialog.close()

    def test_realty_picker_enter_search(self):
        dialog = RealtyPicker(self.store, [], self.window)
        dialog.search.setText("TEST-P003")
        QTest.keyClick(dialog.search, Qt.Key_Return)
        self.assertEqual(len(dialog.model.rows), 1)
        dialog.table.setCurrentIndex(dialog.model.index(0, 0))
        dialog.choose()
        self.assertEqual(dialog.chosen["code"], "TEST-P003")
        dialog.close()

    def test_worker_allows_navigation_and_blocks_review_until_completion(self):
        release = threading.Event()
        finished = []
        def work(progress, cancelled):
            release.wait(2)
            return "done"
        self.window.run_job(work, finished.append)
        self.window.change_page("standards")
        self.app.processEvents()
        self.assertFalse(self.window.review_button.isEnabled())
        self.assertFalse(self.window.import_button.isEnabled())
        self.assertEqual(self.window.total, 4)
        release.set()
        self.wait_for(lambda: self.window.job is None)
        self.assertEqual(finished, ["done"])
        self.assertTrue(self.window.import_button.isEnabled())

    def test_worker_cancel_rolls_back_without_modal_error(self):
        started = threading.Event()
        def work(progress, cancelled):
            started.set()
            while not cancelled():
                threading.Event().wait(0.01)
            return self.store.import_records([self.records[0]], cancelled=cancelled)
        with patch("location_analysis.gui.QMessageBox.warning") as warning:
            self.window.run_job(work, lambda _: self.fail("Cancelled work succeeded"))
            self.assertTrue(started.wait(2))
            self.window.cancel_job()
            self.wait_for(lambda: self.window.job is None)
            self.assertFalse(warning.called)
        self.assertEqual(self.store.stats()["total"], 6)


if __name__ == "__main__":
    unittest.main()
