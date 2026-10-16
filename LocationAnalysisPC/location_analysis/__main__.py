from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from . import APP_NAME,VERSION


def main(argv=None):
    parser=argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("--version",action="version",version=VERSION)
    parser.add_argument("--data-dir",help="보관함 폴더를 직접 지정합니다.")
    parser.add_argument("--self-test",metavar="OUTPUT_DIR",help="임시 자료로 패키지 무결성을 검사합니다.")
    parser.add_argument("--smoke-test",metavar="OUTPUT_DIR",help="임시 자료로 창과 표를 검사합니다.")
    args=parser.parse_args(argv)
    if args.self_test:
        from .diagnostics import self_test
        self_test(args.self_test);return 0
    from PySide6.QtCore import QLockFile
    from PySide6.QtGui import QFont,QFontDatabase
    from PySide6.QtWidgets import QApplication,QMessageBox
    from .gui import MainWindow,apply_theme
    from .storage import CatalogStore,default_db_path
    app=QApplication.instance() or QApplication(sys.argv[:1]);app.setApplicationName(APP_NAME);app.setApplicationVersion(VERSION);app.setOrganizationName("LocationAnalysisPC")
    family="Malgun Gothic" if sys.platform=="win32" else "sans-serif"
    for font in sorted((Path(__file__).parent/"assets").glob("*.ttf")):
        font_id=QFontDatabase.addApplicationFont(str(font))
        families=QFontDatabase.applicationFontFamilies(font_id)
        if families and sys.platform!="win32": family=families[0]
    app.setFont(QFont(family,11));apply_theme(app)
    if args.smoke_test:
        from .diagnostics import gui_smoke
        gui_smoke(args.smoke_test);return 0
    database=Path(args.data_dir)/"catalog.sqlite3" if args.data_dir else default_db_path();database.parent.mkdir(parents=True,exist_ok=True)
    lock=QLockFile(str(database)+".lock")
    if not lock.tryLock(100):
        QMessageBox.information(None,APP_NAME,"이 보관함을 사용하는 프로그램이 이미 실행 중입니다.");return 1
    try:
        window=MainWindow(CatalogStore(database));window.show();return app.exec()
    except Exception as error:
        QMessageBox.critical(None,APP_NAME,"프로그램을 시작하지 못했습니다.\n"+str(error));return 1
    finally:
        lock.unlock()


if __name__=="__main__":
    sys.exit(main())
