from __future__ import annotations

import json
import datetime as dt
import math
from pathlib import Path

from PySide6.QtCore import QAbstractTableModel, QModelIndex, QObject, Qt, QThread, QTimer, QUrl, QSettings, Signal
from PySide6.QtGui import QColor, QDesktopServices, QFont, QKeySequence, QShortcut, QPalette
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog,
    QFormLayout, QFrame, QGridLayout, QHBoxLayout, QHeaderView, QLabel, QLineEdit,
    QListWidget, QListWidgetItem, QMainWindow, QMessageBox, QPlainTextEdit,
    QProgressBar, QPushButton, QScrollArea, QSizePolicy, QSplitter, QTableView,
    QTableWidget, QTableWidgetItem, QTabWidget, QToolButton, QVBoxLayout, QWidget,
)

from . import APP_NAME, VERSION
from .importer import FIELD_LABELS, FileInfo, inspect_file
from .storage import CatalogStore, PAGE_SIZE, STATUSES


COLORS = {"확정":"#08634b", "제외":"#526176", "주소 공란":"#526176", "재검토":"#8a4809", "수록 확인":"#8a4809", "주소 확인":"#8a4809"}
STYLE = """
QWidget {font-size:15px;color:#172538;}
QMainWindow,QDialog {background:#f3f6fa;color:#172538;}
QLabel {background:transparent;}
QFrame#sidebar {background:#162b42;border:0;}
QFrame#sidebar QLabel {color:#e3edf7;background:transparent;}
QFrame#sidebar QPushButton {color:#e3edf7;background:transparent;border:0;text-align:left;padding:12px 12px;border-radius:7px;font-weight:500;}
QFrame#sidebar QPushButton:checked {color:white;background:#315d80;font-weight:700;}
QFrame#sidebar QPushButton:hover {background:#264a6b;}
QLabel#eyebrow {color:#40536c;font-size:14px;font-weight:700;}
QLabel#title {font-size:27px;font-weight:700;color:#162b42;}
QLabel#subtitle {color:#475b73;font-size:14px;}
QLabel#sectionTitle {font-size:17px;font-weight:700;color:#1d3651;}
QFrame#card,QFrame#section {background:white;border:1px solid #cfd9e5;border-radius:10px;}
QFrame#nextStep {background:#eaf3fc;border:1px solid #b7d0e9;border-radius:8px;}
QLabel#cardNumber {font-size:30px;font-weight:700;color:#183b59;}
QLabel#cardLabel {color:#43566d;font-size:14px;}
QPushButton,QToolButton {background:white;color:#243b55;border:1px solid #bac8d8;border-radius:6px;padding:8px 13px;min-height:20px;}
QPushButton:hover,QToolButton:hover {background:#edf4fb;border-color:#577fa8;}
QPushButton:focus,QToolButton:focus {border:2px solid #286197;}
QPushButton:disabled,QToolButton:disabled {color:#73839a;background:#eef2f7;border-color:#d8e0e9;}
QPushButton#primary {background:#0f766e;color:white;border:1px solid #0f766e;font-weight:700;}
QPushButton#primary:hover {background:#095f59;}
QLineEdit,QComboBox,QPlainTextEdit {background:white;color:#172538;border:1px solid #b9c8d9;border-radius:5px;padding:7px;selection-background-color:#cce4fa;selection-color:#11243a;}
QLineEdit,QComboBox {min-height:22px;}
QLineEdit:focus,QComboBox:focus,QPlainTextEdit:focus {border:2px solid #26749a;}
QComboBox QAbstractItemView {background:white;color:#172538;selection-background-color:#dbeafe;selection-color:#11243a;border:1px solid #b9c8d9;outline:0;}
QScrollArea {background:#f3f6fa;border:0;}
QWidget#importBody,QWidget#reviewBody {background:#f3f6fa;}
QTableView,QTableWidget,QListWidget {background:white;alternate-background-color:#f6f9fc;color:#172538;border:1px solid #c6d3e1;border-radius:6px;gridline-color:#e2e9f1;selection-background-color:#dbeafe;selection-color:#102c49;outline:0;}
QHeaderView::section {background:#e7eef7;color:#263f5b;border:0;border-bottom:1px solid #b9c9db;padding:10px;text-align:left;font-weight:700;}
QTableCornerButton::section {background:#e7eef7;border:0;}
QTableView::item {padding:7px;border-bottom:1px solid #e6edf5;}
QTableView::item:selected {background:#dbeafe;color:#102c49;}
QScrollBar:vertical {background:#edf2f7;width:12px;}
QScrollBar:horizontal {background:#edf2f7;height:12px;}
QScrollBar::handle:vertical {background:#9dafc3;min-height:30px;border-radius:5px;}
QScrollBar::handle:horizontal {background:#9dafc3;min-width:30px;border-radius:5px;}
QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical {height:0;}
QScrollBar::add-line:horizontal,QScrollBar::sub-line:horizontal {width:0;}
QScrollBar::add-page,QScrollBar::sub-page {background:transparent;}
QTabWidget::pane {border:1px solid #cfd9e5;background:white;}
QTabBar::tab {padding:10px 15px;background:#e7eef7;color:#334e6d;border:0;}
QTabBar::tab:selected {background:white;color:#0f766e;font-weight:700;}
QProgressBar {border:1px solid #becddd;border-radius:4px;height:12px;text-align:center;background:#e5edf5;}
QProgressBar::chunk {background:#0f766e;}
QCheckBox {spacing:9px;background:transparent;color:#172538;}
QCheckBox::indicator {width:18px;height:18px;}
QCheckBox::indicator:unchecked {border:2px solid #72869f;border-radius:3px;background:white;}
QCheckBox::indicator:checked {border:2px solid #0f766e;border-radius:3px;background:#0f766e;image:url("__CHECK_ICON__");}
QLabel#notice {background:#e9f4f1;color:#235c52;padding:12px;border-radius:7px;}
QToolTip {background:#20364e;color:white;border:0;padding:6px;font-size:14px;}
"""


def apply_theme(app, text_size=None):
    """A complete application palette keeps Windows dark mode from leaking into light panels."""
    import re
    size=int(text_size or app.property("textSize") or 15)
    size=max(15,min(19,size));app.setProperty("textSize",size)
    palette=QPalette()
    colors={QPalette.Window:"#f3f6fa",QPalette.WindowText:"#172538",QPalette.Base:"#ffffff",
        QPalette.AlternateBase:"#f6f9fc",QPalette.Text:"#172538",QPalette.Button:"#ffffff",
        QPalette.ButtonText:"#243b55",QPalette.Highlight:"#dbeafe",QPalette.HighlightedText:"#102c49",
        QPalette.ToolTipBase:"#20364e",QPalette.ToolTipText:"#ffffff",QPalette.PlaceholderText:"#53677f",
        QPalette.Light:"#ffffff",QPalette.Midlight:"#e7eef7",QPalette.Mid:"#b9c8d9",QPalette.Dark:"#72869f",QPalette.Shadow:"#c6d3e1"}
    for role,color in colors.items():palette.setColor(role,QColor(color))
    for role in [QPalette.Text,QPalette.WindowText,QPalette.ButtonText]:palette.setColor(QPalette.Disabled,role,QColor("#73839a"))
    app.setStyle("Fusion");app.setPalette(palette)
    stylesheet=STYLE.replace("__CHECK_ICON__",(Path(__file__).parent/"assets"/"check.svg").resolve().as_posix())
    app.setStyleSheet(re.sub(r"font-size:(\d+)px",lambda m:f"font-size:{round(int(m[1])*size/15)}px",stylesheet))


def label(text, name="", wrap=False):
    widget = QLabel(text)
    if name:
        widget.setObjectName(name)
    widget.setWordWrap(wrap)
    widget.setTextInteractionFlags(Qt.TextSelectableByMouse)
    return widget


def local_time(value):
    try:
        return dt.datetime.fromisoformat(value).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    except (ValueError, TypeError):
        return value or ""


def button(text, callback=None, primary=False):
    item=QPushButton(text)
    if primary:
        item.setObjectName("primary")
    if callback:
        item.clicked.connect(callback)
    return item


class DictTableModel(QAbstractTableModel):
    def __init__(self, columns, rows=()):
        super().__init__(); self.columns=columns; self.rows=list(rows)

    def set_rows(self, rows):
        self.beginResetModel(); self.rows=list(rows); self.endResetModel()

    def rowCount(self,parent=QModelIndex()):
        return 0 if parent.isValid() else len(self.rows)

    def columnCount(self,parent=QModelIndex()):
        return len(self.columns)

    def headerData(self,section,orientation,role=Qt.DisplayRole):
        if role == Qt.DisplayRole and orientation == Qt.Horizontal:
            return self.columns[section][0]
        return None

    def data(self,index,role=Qt.DisplayRole):
        if not index.isValid():
            return None
        row=self.rows[index.row()]; key=self.columns[index.column()][1]
        value=row.get(key,"")
        if role in {Qt.DisplayRole,Qt.ToolTipRole}:
            if key == "kind":
                return "K-apt" if value=="kapt" else "공시가격"
            return "" if value is None else str(value).replace("\n"," · ")
        if role==Qt.ForegroundRole and key=="status":
            return QColor(COLORS.get(value,"#527483"))
        if role==Qt.FontRole and key=="status":
            font=QFont(); font.setBold(True); return font
        if role==Qt.TextAlignmentRole and key in {"households","buildings","linked_count","total","added","changed","blank_roads"}:
            return Qt.AlignRight|Qt.AlignVCenter
        if role==Qt.BackgroundRole and key=="status":
            return QColor("#e6f4ee" if value=="확정" else "#fff2d8" if value in {"주소 확인","재검토","수록 확인"} else "#f0f4f8")
        return None


class WorkThread(QThread):
    completed=Signal(object)
    failed=Signal(str)
    progress=Signal(int,str)

    def __init__(self, work, parent=None):
        super().__init__(parent); self.work=work

    def run(self):
        try:
            self.completed.emit(self.work(self.progress.emit,self.isInterruptionRequested))
        except Exception as error:
            self.failed.emit(str(error))


class ImportDialog(QDialog):
    def __init__(self,info:FileInfo,kind,parent=None):
        super().__init__(parent); self.info=info; self.kind=kind; self.mapping={}
        self.setWindowTitle("K-apt 단지정보 가져오기" if kind=="kapt" else "공시가격 단지목록 가져오기")
        self.resize(980,720)
        self._mapping_columns = 0
        self._screen_connected = False
        layout=QVBoxLayout(self);layout.setContentsMargins(20,18,20,16);layout.setSpacing(12)
        layout.addWidget(label("단지정보 가져오기","title"))
        filename=label(Path(info.path).name,"subtitle",True)
        filename.setSizePolicy(QSizePolicy.Ignored,QSizePolicy.Preferred)
        filename.setToolTip(Path(info.path).name);layout.addWidget(filename)
        self.body_scroll=QScrollArea();self.body_scroll.setWidgetResizable(True)
        self.body_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.body_scroll.setFrameShape(QFrame.NoFrame)
        body=QWidget();body.setObjectName("importBody");body.setSizePolicy(QSizePolicy.Ignored,QSizePolicy.Preferred)
        self.body_scroll.setWidget(body);layout.addWidget(self.body_scroll,1)
        content=QVBoxLayout(body);content.setContentsMargins(0,0,8,0);content.setSpacing(12)
        content.addWidget(label("미리보기에서 단지명과 주소를 확인한 뒤 가져오세요. 같은 코드의 여러 주소는 한 단지로 모읍니다.","notice",True))
        if info.sheets:
            line=QHBoxLayout(); line.addWidget(label("시트")); self.sheet=self.bounded_selector(); self.sheet.addItems(info.sheets); self.sheet.setCurrentText(info.sheet)
            line.addWidget(self.sheet,1); content.addLayout(line); self.sheet.currentTextChanged.connect(self.change_sheet)
        self.mapping_summary=label("","sectionTitle",True);content.addWidget(self.mapping_summary)
        self.mapping_toggle=QToolButton();self.mapping_toggle.setCheckable(True)
        self.mapping_toggle.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        content.addWidget(self.mapping_toggle,0,Qt.AlignLeft)
        self.mapping_section=QWidget();self.mapping_section.setSizePolicy(QSizePolicy.Ignored,QSizePolicy.Preferred)
        self.mapping_grid=QGridLayout(self.mapping_section);self.mapping_grid.setContentsMargins(0,4,0,8)
        self.mapping_widgets=[];self.maps={}
        for i,(key,title) in enumerate(FIELD_LABELS.items()):
            selector=self.bounded_selector(); selector.addItem("사용 안 함","")
            for header in info.headers:
                selector.addItem(header,header)
                selector.setItemData(selector.count()-1,header,Qt.ToolTipRole)
            selector.setCurrentIndex(max(0,selector.findData(info.mapping.get(key,""))))
            selector.setToolTip(selector.currentText())
            self.maps[key]=selector
            caption=label(title + (" *" if key in {"code","name"} or (key=="road" and kind=="kapt") else ""))
            self.mapping_widgets.append((caption,selector))
        content.addWidget(self.mapping_section);self.reflow_mapping()
        self.mapping_toggle.toggled.connect(self.show_mapping)
        self.preview_caption=label("","subtitle",True);content.addWidget(self.preview_caption)
        self.preview=QTableWidget();self.preview.setSizePolicy(QSizePolicy.Ignored,QSizePolicy.Expanding)
        self.preview.setMinimumSize(0,190);self.preview.setMaximumHeight(250)
        self.preview.setAlternatingRowColors(True);self.preview.verticalHeader().setDefaultSectionSize(42)
        self.preview.setWordWrap(False);self.preview.setTextElideMode(Qt.ElideRight)
        self.preview.setHorizontalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        self.populate_preview();content.addWidget(self.preview,1)
        for selector in self.maps.values():selector.currentIndexChanged.connect(self.mapping_changed)
        self.update_mapping_state();self.mapping_toggle.setChecked(not self.mapping_valid())
        self.show_mapping(self.mapping_toggle.isChecked())
        form=QFormLayout(); self.source_date=QLineEdit(); self.source_date.setPlaceholderText("선택: YYYY-MM-DD · 원본 자료의 기준일")
        form.addRow("자료 기준일",self.source_date);content.addLayout(form)
        self.full=QCheckBox("전국 전체 목록으로 갱신")
        self.full.setToolTip("체크하지 않으면 선택한 지역이나 일부 단지를 추가·갱신합니다. 빠진 단지를 자동으로 삭제하거나 멸실 처리하지 않습니다.")
        content.addWidget(self.full)
        content.addWidget(label("전체 목록에서 이전 코드가 빠지면 ‘수록 확인’으로 표시합니다. 지역·일부 자료는 체크하지 마세요.","subtitle",True))
        self.controls=QDialogButtonBox(QDialogButtonBox.Ok|QDialogButtonBox.Cancel)
        self.controls.button(QDialogButtonBox.Ok).setText("가져오기 시작");self.controls.button(QDialogButtonBox.Ok).setObjectName("primary")
        self.controls.button(QDialogButtonBox.Cancel).setText("취소")
        self.controls.accepted.connect(self.validate);self.controls.rejected.connect(self.reject);layout.addWidget(self.controls)
        self.fit_to_screen()

    def bounded_selector(self):
        selector=QComboBox()
        selector.setSizeAdjustPolicy(QComboBox.AdjustToMinimumContentsLengthWithIcon)
        selector.setMinimumContentsLength(10)
        selector.setMinimumWidth(100)
        selector.setSizePolicy(QSizePolicy.Ignored,QSizePolicy.Fixed)
        selector.view().setTextElideMode(Qt.ElideRight)
        selector.view().setHorizontalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        selector.currentTextChanged.connect(selector.setToolTip)
        return selector

    def reflow_mapping(self):
        columns=1 if self.width()<840 else 2
        if columns==self._mapping_columns:return
        self._mapping_columns=columns
        while self.mapping_grid.count():self.mapping_grid.takeAt(0)
        for column in range(4):self.mapping_grid.setColumnStretch(column,0)
        for i,(caption,selector) in enumerate(self.mapping_widgets):
            self.mapping_grid.addWidget(caption,i//columns,(i%columns)*2)
            self.mapping_grid.addWidget(selector,i//columns,(i%columns)*2+1)
        for column in range(columns):self.mapping_grid.setColumnStretch(column*2+1,1)

    def fit_to_screen(self):
        parent=self.parentWidget()
        screen=self.windowHandle().screen() if self.windowHandle() else parent.screen() if parent else self.screen()
        available=screen.availableGeometry().adjusted(16,32,-16,-16)
        self.setMinimumSize(min(480,available.width()),min(340,available.height()))
        self.setMaximumSize(available.size())
        self.resize(min(self.width(),available.width()),min(self.height(),available.height()))
        for selector in [*self.maps.values(),*([self.sheet] if hasattr(self,"sheet") else [])]:
            selector.view().setMaximumWidth(available.width()-24)
        frame=self.frameGeometry();frame.moveCenter(screen.availableGeometry().center());self.move(frame.topLeft())

    def showEvent(self,event):
        super().showEvent(event);self.fit_to_screen()
        if not self._screen_connected and self.windowHandle():
            self.windowHandle().screenChanged.connect(lambda _:self.fit_to_screen())
            self._screen_connected=True

    def resizeEvent(self,event):
        super().resizeEvent(event)
        if hasattr(self,"mapping_grid"):self.reflow_mapping()

    def populate_preview(self):
        self.preview_caption.setText(f"미리보기 · 처음 {len(self.info.samples)}개 행 · 전체 {len(self.info.headers)}개 열 · 제목은 {self.info.header_row+1}행")
        first=[self.maps[key].currentData() for key in ["name","code","road"] if self.maps[key].currentData()]
        headers=list(dict.fromkeys(first+self.info.headers))
        self.preview.clear();self.preview.setColumnCount(len(headers));self.preview.setRowCount(len(self.info.samples));self.preview.setHorizontalHeaderLabels(headers)
        for i,row in enumerate(self.info.samples):
            for j,key in enumerate(headers):
                value=str(row.get(key,""));cell=QTableWidgetItem(value);cell.setToolTip(value);cell.setFlags(cell.flags() & ~Qt.ItemIsEditable);self.preview.setItem(i,j,cell)
        self.preview.resizeColumnsToContents()
        for i in range(len(headers)):
            self.preview.setColumnWidth(i,min(320,max(120,self.preview.columnWidth(i))))

    def mapping_valid(self):
        required=["code","name"]+(["road"] if self.kind=="kapt" else [])
        chosen=[selector.currentData() for selector in self.maps.values() if selector.currentData()]
        return all(self.maps[key].currentData() for key in required) and len(chosen)==len(set(chosen))

    def show_mapping(self,visible):
        self.mapping_section.setVisible(visible)
        self.mapping_toggle.setArrowType(Qt.DownArrow if visible else Qt.RightArrow)
        self.mapping_toggle.setText("열 연결 접기" if visible else "열 연결 확인·수정")

    def update_mapping_state(self):
        valid=self.mapping_valid()
        self.mapping_summary.setText("✓ 필요한 열이 연결되었습니다" if valid else "열 연결을 확인해 주세요")
        if not valid:self.mapping_toggle.setChecked(True)

    def mapping_changed(self):
        self.update_mapping_state();self.populate_preview()

    def change_sheet(self,name):
        try:
            info=inspect_file(self.info.path,name); self.info=info
            for key,selector in self.maps.items():
                selector.blockSignals(True)
                selector.clear();selector.addItem("사용 안 함","")
                for h in info.headers:
                    selector.addItem(h,h);selector.setItemData(selector.count()-1,h,Qt.ToolTipRole)
                selector.setCurrentIndex(max(0,selector.findData(info.mapping.get(key,""))))
                selector.blockSignals(False);selector.setToolTip(selector.currentText())
            self.update_mapping_state();self.mapping_toggle.setChecked(not self.mapping_valid());self.populate_preview()
        except Exception as error:
            QMessageBox.warning(self,"시트 읽기",str(error))

    def validate(self):
        self.mapping={k:c.currentData() for k,c in self.maps.items()}
        required=["code","name"]+(["road"] if self.kind=="kapt" else [])
        if any(not self.mapping[k] for k in required):
            QMessageBox.warning(self,"열 연결 확인","단지코드·단지명과 K-apt 도로명주소 열을 연결하세요.");return
        selected=[v for v in self.mapping.values() if v]
        if len(selected)!=len(set(selected)):
            QMessageBox.warning(self,"열 연결 확인","같은 원본 열을 여러 항목에 중복 연결하지 마세요.");return
        self.accept()


class RealtyPicker(QDialog):
    def __init__(self,store,selected,parent=None):
        super().__init__(parent);self.store=store;self.existing=set(selected);self.chosen=None;self.offset=0
        self.resize(850,530);self.setWindowTitle("연결할 공시가격 단지 선택")
        layout=QVBoxLayout(self);layout.addWidget(label("공시가격 단지 연결","title"))
        layout.addWidget(label("한 K-apt 단지에 여러 공시가격 단지를 연결할 수 있고, 같은 공시가격 단지를 다른 K-apt 단지도 사용할 수 있습니다.","notice",True))
        self.search=QLineEdit();self.search.setPlaceholderText("단지명·코드·도로명주소·지번주소 검색");layout.addWidget(self.search)
        self.model=DictTableModel([("단지명","name"),("공시가격 ID","code"),("도로명주소","road_raw"),("연결 단지 수","linked_count")])
        self.table=QTableView();self.table.setModel(self.model);self.table.setSelectionBehavior(QTableView.SelectRows);self.table.setSelectionMode(QTableView.SingleSelection);self.table.setEditTriggers(QTableView.NoEditTriggers)
        self.table.horizontalHeader().setSectionResizeMode(2,QHeaderView.Stretch);layout.addWidget(self.table,1)
        page=QHBoxLayout();self.previous=button("이전",lambda:self.move(-1));self.next=button("다음",lambda:self.move(1));self.count=label("")
        page.addWidget(self.previous);page.addWidget(self.next);page.addWidget(self.count);page.addStretch();layout.addLayout(page)
        controls=QDialogButtonBox(QDialogButtonBox.Ok|QDialogButtonBox.Cancel);controls.button(QDialogButtonBox.Ok).setText("선택한 단지 연결");controls.button(QDialogButtonBox.Cancel).setText("닫기")
        controls.accepted.connect(self.choose);controls.rejected.connect(self.reject);layout.addWidget(controls)
        self.search.returnPressed.connect(self.reset);self.table.doubleClicked.connect(lambda _:self.choose());self.refresh()

    def reset(self): self.offset=0;self.refresh()
    def move(self,delta): self.offset=max(0,self.offset+delta*PAGE_SIZE);self.refresh()
    def refresh(self):
        rows,total=self.store.list_realty(self.search.text().strip(),self.offset);self.model.set_rows(rows)
        self.count.setText(f"{total:,}개 중 {self.offset+1 if total else 0:,}–{min(self.offset+PAGE_SIZE,total):,}")
        self.previous.setEnabled(self.offset>0);self.next.setEnabled(self.offset+PAGE_SIZE<total);self.table.resizeColumnsToContents();self.table.horizontalHeader().setSectionResizeMode(2,QHeaderView.Stretch)
    def choose(self):
        current=self.table.currentIndex()
        if not current.isValid():return
        row=self.model.rows[current.row()]
        if row["code"] in self.existing:
            QMessageBox.information(self,"이미 연결됨","이미 이 단지에 연결된 공시가격 원본입니다.");return
        self.chosen=row;self.accept()


class ReviewDialog(QDialog):
    def __init__(self,store,code,parent=None):
        super().__init__(parent);self.store=store;self.record=store.get_complex(code);self.links=list(self.record["links"])
        r=self.record;self.setWindowTitle("단지·표준지 검토 — "+r["name"]);self.resize(920,800)
        layout=QVBoxLayout(self);layout.addWidget(label(r["name"],"title"));layout.addWidget(label(f"K-apt {code}  ·  현재 상태: {r['status']}","subtitle"))
        scroll=QScrollArea();scroll.setWidgetResizable(True);body=QWidget();body.setObjectName("reviewBody");content=QVBoxLayout(body);layout.addWidget(scroll,1);scroll.setWidget(body)
        if r["shared_address"]:
            content.addWidget(label("주소를 함께 사용하는 등록: "+" / ".join(f"{x['name']} ({x['code']})" for x in r["shared_address"])+"\n주소가 같아도 자동으로 합치지 않습니다.","notice",True))
        content.addWidget(label("1. 등록 상태 확인","sectionTitle"))
        form=QFormLayout();self.verdict=QComboBox()
        for title,value in [("검토 대기","pending"),("실재하는 유효 단지로 확인","valid"),("중복·멸실 등으로 제외","excluded")]: self.verdict.addItem(title,value)
        self.verdict.setCurrentIndex(max(0,self.verdict.findData(r["verdict"] or "pending")));form.addRow("등록 판정",self.verdict)
        self.reason=QComboBox();self.reason.setEditable(True);self.reason.addItems(["","유효 단지 확인","중복 등록","재건축 전·멸실","다른 단지로 대체","기타"]);self.reason.setCurrentText(r["reason"] or "");form.addRow("확인 / 제외 사유",self.reason)
        self.note=QPlainTextEdit(r["note"] or "");self.note.setPlaceholderText("직접 확인한 근거, 다른 단지와 구분한 이유, 중복이면 채택한 K-apt 코드 등을 기록하세요.");self.note.setMaximumHeight(90);form.addRow("검토 근거·메모",self.note);content.addLayout(form)
        content.addWidget(label("2. 공시가격 단지 연결","sectionTitle"));self.link_list=QListWidget();self.link_list.setMaximumHeight(115);content.addWidget(self.link_list)
        actions=QHBoxLayout();actions.addWidget(button("연결 추가",self.add_link));actions.addWidget(button("선택 연결 해제",self.remove_link));actions.addStretch();content.addLayout(actions);self.refresh_links()
        content.addWidget(label("3. 단지당 표준 건물 하나","sectionTitle"));form=QFormLayout()
        self.road=QComboBox();self.road.addItem("대표 주소를 선택하세요","")
        for road in json.loads(r["roads"]): self.road.addItem(road,road)
        if r["selected_road"]: self.road.setCurrentIndex(max(0,self.road.findData(r["selected_road"])))
        elif r["address_count"]==1: self.road.setCurrentIndex(1)
        form.addRow("대표 도로명주소",self.road)
        self.building=QLineEdit(r["building_name"] or "");self.building.setPlaceholderText("확인한 개별 건물·동 명칭, 예: 101동");form.addRow("표준 건물·동",self.building)
        self.building_id=QLineEdit(r["building_id"] or "");self.building_id.setPlaceholderText("선택: 건축물대장 관리 PK 등");form.addRow("건물 식별자",self.building_id)
        self.member=QCheckBox("이 건물이 해당 K-apt 관리단지에 속함을 확인했습니다.");self.member.setChecked(bool(r["member_confirmed"]));form.addRow("건물 소속",self.member)
        coordinates=QHBoxLayout();self.lat=QLineEdit("" if r["latitude"] is None else str(r["latitude"]));self.lon=QLineEdit("" if r["longitude"] is None else str(r["longitude"]));self.lat.setPlaceholderText("위도, 예: 36.35");self.lon.setPlaceholderText("경도, 예: 127.38");coordinates.addWidget(self.lat);coordinates.addWidget(self.lon);form.addRow("건물 입구 좌표",coordinates)
        self.entrance=QCheckBox("선택한 개별 건물의 입구 좌표를 직접 확인했습니다.");self.entrance.setChecked(bool(r["entrance_confirmed"]));form.addRow("입구 확인",self.entrance);content.addLayout(form)
        content.addWidget(label("한 단지에 주소가 여러 개여도 표준지는 하나입니다. 동·입구를 아직 확인하지 않았으면 비워 두고 검토 상태로 저장할 수 있습니다.","notice",True))
        raw=QPlainTextEdit();raw.setReadOnly(True);raw.setPlainText("\n".join(f"{k}: {v}" for k,v in json.loads(r["raw"]).items()));raw.setMinimumHeight(110)
        content.addWidget(label("가져온 원본 정보","eyebrow"));content.addWidget(raw)
        controls=QDialogButtonBox(QDialogButtonBox.Save|QDialogButtonBox.Cancel);controls.button(QDialogButtonBox.Save).setText("검토 저장");controls.button(QDialogButtonBox.Cancel).setText("취소")
        controls.accepted.connect(self.save);controls.rejected.connect(self.reject);layout.addWidget(controls)
    def refresh_links(self):
        self.link_list.clear()
        for row in self.links:self.link_list.addItem(f"{row['name']}  ·  {row['code']}  ·  {row['road_raw'] or row['jibun']}")
        if not self.links:self.link_list.setToolTip("공시가격 단지목록을 먼저 가져오거나 대조 화면에서 직접 등록하세요.")
    def add_link(self):
        picker=RealtyPicker(self.store,[x["code"] for x in self.links],self)
        if picker.exec()==QDialog.Accepted:self.links.append(picker.chosen);self.refresh_links()
    def remove_link(self):
        i=self.link_list.currentRow()
        if i>=0:self.links.pop(i);self.refresh_links()
    def save(self):
        try:
            self.store.save_review(self.record["code"],verdict=self.verdict.currentData(),reason=self.reason.currentText(),note=self.note.toPlainText(),
                selected_road=self.road.currentData() or "",building_name=self.building.text(),building_id=self.building_id.text(),member_confirmed=self.member.isChecked(),
                latitude=self.lat.text().strip(),longitude=self.lon.text().strip(),entrance_confirmed=self.entrance.isChecked(),
                realty_codes=[x["code"] for x in self.links],expected_scope=self.record["scope_hash"])
            self.accept()
        except Exception as error:QMessageBox.warning(self,"검토 저장",str(error))


class ManualRealtyDialog(QDialog):
    def __init__(self,store,parent=None):
        super().__init__(parent);self.store=store;self.setWindowTitle("공시가격 단지 직접 등록");self.resize(620,300)
        layout=QVBoxLayout(self);layout.addWidget(label("공시가격 원본 단지 등록","title"));form=QFormLayout();self.fields={}
        for key,title in [("code","공시가격 고유 ID"),("name","단지명"),("road","도로명주소"),("jibun","지번주소")]:
            field=QLineEdit();self.fields[key]=field;form.addRow(title,field)
        self.fields["code"].setPlaceholderText("공시가격 사이트의 지역을 포함한 고유 코드")
        layout.addLayout(form);layout.addWidget(label("연결용 원본을 직접 기록합니다. K-apt 코드와 다른 식별자를 사용하세요.","subtitle",True))
        controls=QDialogButtonBox(QDialogButtonBox.Save|QDialogButtonBox.Cancel);controls.button(QDialogButtonBox.Save).setText("등록");controls.button(QDialogButtonBox.Cancel).setText("취소");controls.accepted.connect(self.save);controls.rejected.connect(self.reject);layout.addWidget(controls)
    def save(self):
        from .models import CatalogRecord,region_from_road,split_roads
        try:
            f={k:v.text().strip() for k,v in self.fields.items()};roads,issues=split_roads(f["road"]);p,d=region_from_road(roads)
            record=CatalogRecord(f["code"],f["name"],f["road"],roads,issues,f["jibun"],p,d,raw={"공시가격ID":f["code"],"단지명":f["name"],"도로명주소":f["road"],"지번주소":f["jibun"]})
            existing,_=self.store.list_realty(f["code"],limit=-1)
            if any(r["code"]==f["code"] for r in existing):raise ValueError("이미 존재하는 ID입니다. 원본 파일 가져오기로 갱신하세요.")
            self.store.import_records([record],kind="realty");self.accept()
        except Exception as error:QMessageBox.warning(self,"등록",str(error))


class MainWindow(QMainWindow):
    PAGES=[("단지정보","kapt"),("표준지 목록","standards"),("주소 중복 검토","duplicates"),("공시가격 대조","realty"),("가져오기 기록","imports")]
    def __init__(self,store:CatalogStore,settings=None):
        super().__init__();self.store=store;self.page="kapt";self.offset=0;self.total=0;self.job=None;self._closing=False
        self.settings=settings if settings is not None else QSettings("LocationAnalysisPC","Display")
        try:size=int(self.settings.value("text_size",15))
        except (ValueError,TypeError):size=15
        if size not in {15,17,19}:size=15
        apply_theme(QApplication.instance(),size)
        self.setWindowTitle(f"{APP_NAME} {VERSION}");self.resize(1440,920);self.setMinimumSize(1000,680)
        root=QWidget();self.setCentralWidget(root);outer=QHBoxLayout(root);outer.setContentsMargins(0,0,0,0);outer.setSpacing(0)
        sidebar=QFrame();sidebar.setObjectName("sidebar");sidebar.setFixedWidth(192);side=QVBoxLayout(sidebar);side.setContentsMargins(16,30,16,20)
        brand=label("입지분석","title");brand.setStyleSheet("color:white;font-size:23px;font-weight:700;");side.addWidget(brand)
        side.addWidget(label("표준지 목록 관리"));side.addSpacing(26);self.nav={}
        for title,key in self.PAGES:
            item=QPushButton(title);item.setCheckable(True);item.clicked.connect(lambda checked=False,p=key:self.change_page(p));self.nav[key]=item;side.addWidget(item)
        side.addStretch();side.addWidget(label("전국 단지 · PC에 보관\n검토 내용 자동 저장",wrap=True));side.addSpacing(15);side.addWidget(label("버전 "+VERSION));outer.addWidget(sidebar)
        main=QWidget();content=QVBoxLayout(main);content.setContentsMargins(22,20,22,14);content.setSpacing(10);outer.addWidget(main,1)
        titleline=QHBoxLayout();self.heading=label("단지정보","title");titleline.addWidget(self.heading);titleline.addStretch()
        titleline.addWidget(label("글자 크기","subtitle"));self.text_size=QComboBox()
        for name,value in [("기본",15),("크게",17),("더 크게",19)]:self.text_size.addItem(name,value)
        self.text_size.setCurrentIndex(self.text_size.findData(size));self.text_size.currentIndexChanged.connect(self.change_text_size)
        titleline.addWidget(self.text_size)
        self.backup_button=button("백업",self.backup);self.backup_button.setToolTip("원본·검토·연결 기록 전체 백업")
        self.restore_button=button("복원",self.restore);titleline.addWidget(self.backup_button);titleline.addWidget(self.restore_button)
        titleline.addWidget(button("사용 안내",self.help));content.addLayout(titleline)
        self.subtitle=label("K-apt 단지정보를 가져와 표준지 후보를 관리합니다.","subtitle",True);content.addWidget(self.subtitle)
        cards=QHBoxLayout();cards.setSpacing(12);self.cards={}
        for key,title in [("total","가져온 K-apt 단지"),("candidates","표준지 후보"),("confirmed","확정 표준지"),("needs_review","확인할 후보")]:
            frame=QFrame();frame.setObjectName("card");box=QVBoxLayout(frame);box.setContentsMargins(14,9,14,9);box.setSpacing(2);number=label("0","cardNumber");box.addWidget(number);box.addWidget(label(title,"cardLabel"));self.cards[key]=number;cards.addWidget(frame,1)
        content.addLayout(cards)
        tools=QHBoxLayout();self.import_button=button("＋ K-apt 파일 가져오기",lambda:self.choose_import("kapt"),True);tools.addWidget(self.import_button)
        self.realty_import=button("공시가격 목록 가져오기",lambda:self.choose_import("realty"));tools.addWidget(self.realty_import)
        self.export_button=button("표준지 내보내기",self.export);tools.addWidget(self.export_button);tools.addStretch()
        content.addLayout(tools)
        filters=QHBoxLayout();self.search=QLineEdit();self.search.setClearButtonEnabled(True);self.search.setPlaceholderText("단지명 · K-apt 코드 · 도로명주소 · 지번주소");filters.addWidget(self.search,3)
        self.province=QComboBox();self.province.addItem("전국","");self.district=QComboBox();self.district.addItem("시군구 전체","");self.status=QComboBox();self.status.addItem("상태 전체","")
        for s in STATUSES:self.status.addItem(s,s)
        for x in [self.province,self.district,self.status]:
            x.setSizeAdjustPolicy(QComboBox.AdjustToMinimumContentsLengthWithIcon);x.setMinimumContentsLength(5);filters.addWidget(x,1)
        self.clear_filters=button("초기화",self.reset_filters);filters.addWidget(self.clear_filters)
        content.addLayout(filters)
        guide=QFrame();guide.setObjectName("nextStep");guide_layout=QHBoxLayout(guide);guide_layout.setContentsMargins(14,10,14,10)
        guide_text=QVBoxLayout();guide_text.setSpacing(4)
        self.guide_title=label("","sectionTitle",True);self.guide_body=label("","subtitle",True)
        for item in [self.guide_title,self.guide_body]:item.setSizePolicy(QSizePolicy.Ignored,QSizePolicy.Preferred);guide_text.addWidget(item)
        guide_layout.addLayout(guide_text,1);self.guide_button=button("",self.follow_guide);guide_layout.addWidget(self.guide_button)
        content.addWidget(guide)
        self.empty=label("아직 단지정보가 없습니다.\n‘K-apt 파일 가져오기’에서 내려받은 전국 단지정보 엑셀을 선택하세요.",wrap=True);self.empty.setAlignment(Qt.AlignCenter);self.empty.setStyleSheet("padding:28px;color:#6a8291;font-size:15px;");content.addWidget(self.empty)
        self.splitter=QSplitter();self.splitter.setChildrenCollapsible(False);content.addWidget(self.splitter,1)
        self.table=QTableView();self.table.setSelectionBehavior(QTableView.SelectRows);self.table.setSelectionMode(QTableView.SingleSelection);self.table.setEditTriggers(QTableView.NoEditTriggers);self.table.setAlternatingRowColors(True);self.table.setWordWrap(False);self.table.setTextElideMode(Qt.ElideRight);self.table.verticalHeader().setVisible(False);self.table.verticalHeader().setDefaultSectionSize(round(48*size/15))
        self.table.setHorizontalScrollMode(QTableView.ScrollPerPixel);self.table.setVerticalScrollMode(QTableView.ScrollPerPixel)
        self.model=DictTableModel([]);self.table.setModel(self.model);self.splitter.addWidget(self.table)
        details=QFrame();details.setObjectName("card");details.setMinimumWidth(260);self.details_layout=QVBoxLayout(details);self.detail_title=label("단지를 선택하세요","sectionTitle",wrap=True);self.details_layout.addWidget(self.detail_title)
        self.detail_info=QPlainTextEdit();self.detail_info.setReadOnly(True);self.detail_info.setStyleSheet("border:0;background:white;");self.details_layout.addWidget(self.detail_info,1)
        self.review_button=button("단지·표준지 검토",self.review,True);self.details_layout.addWidget(self.review_button)
        self.manual_button=button("공시가격 단지 직접 등록",self.manual_realty);self.details_layout.addWidget(self.manual_button);self.splitter.addWidget(details);self.splitter.setSizes([900,330]);self.detail_panel=details
        pages=QHBoxLayout();self.page_count=label("");pages.addWidget(self.page_count);pages.addStretch();self.previous=button("‹ 이전",lambda:self.move(-1));self.next=button("다음 ›",lambda:self.move(1));pages.addWidget(self.previous);pages.addWidget(self.next);content.addLayout(pages)
        self.progress_bar=QProgressBar();self.progress_bar.hide();content.addWidget(self.progress_bar)
        footer=QHBoxLayout();self.message=label("로컬 보관함을 사용합니다.","subtitle");self.cancel=button("가져오기 취소",self.cancel_job);self.cancel.hide();footer.addWidget(self.message,1);footer.addWidget(self.cancel);content.addLayout(footer)
        self.search_timer=QTimer(self);self.search_timer.setSingleShot(True);self.search_timer.setInterval(250);self.search_timer.timeout.connect(self.reset)
        self.search.textChanged.connect(lambda _:self.search_timer.start());self.search.returnPressed.connect(self.reset)
        self.province.currentIndexChanged.connect(self.province_changed);self.district.currentIndexChanged.connect(self.reset);self.status.currentIndexChanged.connect(self.reset)
        self.table.selectionModel().currentChanged.connect(self.selection_changed);self.table.doubleClicked.connect(lambda _:self.review())
        QShortcut(QKeySequence.Find,self,activated=self.search.setFocus)
        self.refresh_regions();self.change_page("kapt")

    def change_text_size(self):
        size=self.text_size.currentData();self.settings.setValue("text_size",size)
        apply_theme(QApplication.instance(),size)
        self.table.verticalHeader().setDefaultSectionSize(round(48*size/15))

    def reset_filters(self):
        self.search.blockSignals(True);self.search.clear();self.search.blockSignals(False);self.search_timer.stop()
        for selector in [self.province,self.district,self.status]:
            selector.blockSignals(True);selector.setCurrentIndex(0);selector.blockSignals(False)
        self.refresh_regions();self.reset()

    def update_guide(self,stats):
        if not stats["total"]:
            title="1. 전국 단지정보 파일부터 가져오세요"
            body="다운로드한 K-apt 엑셀을 선택하면 표준지 후보 목록이 만들어집니다."
            action="import";caption="K-apt 파일 선택"
        elif self.page=="kapt":
            title="2. 같은 주소의 등록부터 비교하세요"
            body="중복·멸실 등록만 근거를 남겨 제외하고, 실제 별개 관리단지는 각각 유지합니다."
            action="duplicates";caption="주소 중복 검토로"
        elif self.page=="duplicates":
            title="단지 선택 → ‘단지·표준지 검토’에서 판정"
            body="주소가 같다는 이유만으로 제외하지 마세요. 중복은 채택할 코드를 메모하고 제외합니다."
            action="standards";caption="표준지 후보 확인"
        elif self.page=="standards":
            title="3. 후보 목록은 지금 저장할 수 있습니다"
            body="확정에는 유효 판정·공시가격 연결·표준 건물과 입구 확인이 필요합니다. 미확인 값은 비워 둬도 됩니다."
            action="export";caption="표준지 내보내기"
        elif self.page=="realty":
            title="공시가격 목록 준비 → 단지 검토 창에서 연결"
            body="현재는 파일 가져오기·직접 등록과 수동 연결을 지원합니다. 도로명·지번 자동 검색은 추후 추가합니다."
            action="realty_import";caption="공시가격 파일 선택"
        else:
            title="가져오기 결과와 자료 기준일을 확인하세요"
            body="검토는 자동 저장됩니다. 다른 PC로 옮기거나 별도 보관하려면 오른쪽 위 ‘백업’을 사용하세요."
            action="kapt";caption="단지 목록으로"
        self.guide_title.setText(title);self.guide_body.setText(body);self.guide_button.setText(caption)
        self.guide_action=action;self.guide_button.setEnabled(self.job is None)

    def follow_guide(self):
        if self.job:return
        action=self.guide_action
        if action=="import":self.choose_import("kapt")
        elif action=="realty_import":self.choose_import("realty")
        elif action=="export":self.export()
        else:self.reset_filters();self.change_page(action)

    def refresh_regions(self):
        p=self.province.currentData() or "";d=self.district.currentData() or "";provinces,districts=self.store.regions(p)
        self.province.blockSignals(True);self.province.clear();self.province.addItem("전국","")
        for v in provinces:self.province.addItem(v,v)
        self.province.setCurrentIndex(max(0,self.province.findData(p)));self.province.blockSignals(False)
        self.district.blockSignals(True);self.district.clear();self.district.addItem("시군구 전체","")
        for v in districts:self.district.addItem(v,v)
        self.district.setCurrentIndex(max(0,self.district.findData(d)));self.district.blockSignals(False)
    def province_changed(self):self.refresh_regions();self.reset()
    def reset(self):self.offset=0;self.refresh()
    def move(self,delta):self.offset=max(0,self.offset+delta*PAGE_SIZE);self.refresh()
    def change_page(self,page):
        self.page=page;self.offset=0
        for key,item in self.nav.items():item.setChecked(key==page)
        self.heading.setText(dict((key,title) for title,key in self.PAGES)[page])
        messages={"kapt":"다운로드한 단지정보와 검토 상태를 한곳에서 확인합니다.","standards":"유효한 K-apt 단지별 후보 하나를 유지하고 건물·입구까지 확인한 표준지를 확정합니다.","duplicates":"주소가 겹치는 등록을 비교해 중복·과거 등록과 실제 별개 단지를 구분합니다.","realty":"공시가격 단지 원본을 가져와 K-apt 단지와 직접 연결합니다.","imports":"가져온 파일, 자료 기준일, 추가·변경 건수를 기록합니다."}
        self.subtitle.setText(messages[page]);self.refresh()

    def refresh(self):
        stats=self.store.stats()
        for key,item in self.cards.items():item.setText(f"{stats[key]:,}")
        self.update_guide(stats)
        is_catalog=self.page not in {"realty","imports"}
        for x in [self.province,self.district,self.status]:x.setVisible(is_catalog)
        self.search.setVisible(self.page!="imports");self.clear_filters.setVisible(self.page!="imports");self.review_button.setVisible(is_catalog);self.manual_button.setVisible(self.page=="realty")
        if is_catalog:
            rows,total=self.store.list_complexes(self.page,self.search.text().strip(),self.province.currentData() or "",self.district.currentData() or "",self.status.currentData() or "",self.offset)
            columns=[("단지명","name"),("검토 상태","status"),("K-apt 코드","code"),("도로명주소","road_raw"),("세대수","households"),("동수","buildings")]
        elif self.page=="realty":
            rows,total=self.store.list_realty(self.search.text().strip(),self.offset)
            columns=[("단지명","name"),("공시가격 ID","code"),("도로명주소","road_raw"),("지번주소","jibun"),("연결 수","linked_count")]
        else:
            all_rows=self.store.imports();total=len(all_rows);rows=all_rows[self.offset:self.offset+PAGE_SIZE]
            columns=[("원본 파일","filename"),("자료 종류","kind"),("자료 기준일","source_date"),("단지 수","total"),("신규","added"),("변경","changed"),("주소 공란","blank_roads")]
        self.total=total;self.model.beginResetModel();self.model.columns=columns;self.model.rows=rows;self.model.endResetModel()
        header=self.table.horizontalHeader();header.setSectionResizeMode(QHeaderView.Interactive);header.setStretchLastSection(False)
        self.table.resizeColumnsToContents()
        minimums={"name":220,"status":115,"code":145,"road_raw":310,"jibun":230,"filename":260}
        for i,(_,key) in enumerate(columns):
            self.table.setColumnWidth(i,min(340,max(minimums.get(key,85),self.table.columnWidth(i))))
        self.page_count.setText(f"{total:,}개  ·  {self.offset+1 if total else 0:,}–{min(self.offset+PAGE_SIZE,total):,}")
        self.previous.setEnabled(self.offset>0);self.next.setEnabled(self.offset+PAGE_SIZE<total)
        self.empty.setVisible(total==0);self.empty.setText("아직 단지정보가 없습니다.\n‘K-apt 파일 가져오기’에서 전국 단지정보 엑셀을 선택하세요." if stats["total"]==0 and is_catalog else "표시할 항목이 없습니다. 검색어·지역·상태 조건을 확인하거나 원본 파일을 가져오세요.")
        self.splitter.setVisible(total>0 or self.page=="realty");self.detail_title.setText("항목을 선택하세요");self.detail_info.clear();self.review_button.setEnabled(False)
        if rows:self.table.setCurrentIndex(self.model.index(0,0))

    def selection_changed(self,current,previous=QModelIndex()):
        if not current.isValid() or current.row()>=len(self.model.rows):return
        row=self.model.rows[current.row()]
        self.detail_title.setText(row.get("name",row.get("filename","")));self.review_button.setEnabled(self.job is None and self.page not in {"realty","imports"})
        if self.page=="imports":
            text=f"자료 종류: {'K-apt' if row['kind']=='kapt' else '공시가격'}\n자료 기준일: {row['source_date'] or '미지정'}\n가져온 시각: {local_time(row['imported_at'])}\n\n단지 수: {row['total']:,}\n신규: {row['added']:,}\n변경: {row['changed']:,}\n동일: {row['unchanged']:,}\n주소 공란: {row['blank_roads']:,}\n주소 확인: {row['unparsed_roads']:,}\n같은 코드 추가 행: {row['repeated']:,}\n\n원본 확인값\n{row['sha256']}"
        elif self.page=="realty":
            text=f"공시가격 ID: {row['code']}\n연결 K-apt 단지: {row['linked_count']}개\n\n도로명주소\n{row['road_raw'] or '미제공'}\n\n지번주소\n{row['jibun'] or '미제공'}\n\n원본 정보\n"+"\n".join(f"{k}: {v}" for k,v in json.loads(row["raw"]).items())
        else:
            r=self.store.get_complex(row["code"])
            text=f"K-apt {r['code']}\n{r['status']}\n\n도로명주소\n{r['road_raw'] or '공란'}\n\n지번주소\n{r['jibun'] or '미제공'}\n\n단지분류: {r['use_type'] or '미제공'}\n세대수: {r['households'] or '미제공'}\n동수: {r['buildings'] or '미제공'}\n사용승인일: {r['approval_date'] or '미제공'}\n자료 기준일: {r['source_date'] or '미지정'}\n\n연결 공시가격: {len(r['links'])}개\n표준 건물: {r['building_name'] or '확인 전'}\n대표 주소: {r['selected_road'] or '선택 전'}\n"
            if r["road_issues"]!="[]":text+="\n해석을 확인할 주소\n"+"\n".join(json.loads(r["road_issues"]))+"\n"
            if r["shared_address"]:text+="\n같은 주소의 등록\n"+"\n".join(f"{x['name']} · {x['code']}" for x in r["shared_address"])+"\n"
            if r["note"]:text+="\n검토 메모\n"+r["note"]+"\n"
            if r["history"]:text+="\n최근 검토 기록\n"+"\n".join(f"{local_time(x['at'])} · {x['action']}" for x in r["history"])
        self.detail_info.setPlainText(text)

    def review(self):
        current=self.table.currentIndex()
        if self.job or self.page in {"realty","imports"} or not current.isValid():return
        dialog=ReviewDialog(self.store,self.model.rows[current.row()]["code"],self)
        if dialog.exec()==QDialog.Accepted:self.refresh();self.message.setText("검토 내용과 표준지 선택을 저장했습니다.")
    def manual_realty(self):
        if self.job:return
        if ManualRealtyDialog(self.store,self).exec()==QDialog.Accepted:self.refresh()

    def set_busy(self,busy):
        for item in [self.import_button,self.realty_import,self.backup_button,self.restore_button,self.export_button,self.review_button,self.manual_button,self.guide_button]:item.setEnabled(not busy)
        self.progress_bar.setVisible(busy);self.cancel.setVisible(busy)
        if busy:self.progress_bar.setRange(0,0)
        if not busy:self.review_button.setEnabled(self.page not in {"realty","imports"} and self.table.currentIndex().isValid())
    def run_job(self,work,on_success):
        if self.job:return
        task=WorkThread(work,self);self.job=task;self.set_busy(True)
        task.progress.connect(lambda count,text:self.message.setText(text))
        def finish(value):
            task.wait();self.job=None;self.set_busy(False);task.deleteLater()
            if self._closing:self.close();return
            on_success(value)
        def fail(message):
            task.wait();self.job=None;self.set_busy(False);task.deleteLater();self.message.setText(message)
            if self._closing:self.close();return
            if not message.startswith("가져오기를 취소"):QMessageBox.warning(self,"작업 확인",message)
        task.completed.connect(finish);task.failed.connect(fail);task.start()
    def cancel_job(self):
        if self.job:self.job.requestInterruption();self.cancel.setEnabled(False);self.message.setText("취소하는 중입니다. 기존 자료는 보존됩니다.")
    def choose_import(self,kind):
        path,_=QFileDialog.getOpenFileName(self,"단지정보 파일 선택","","단지정보 (*.xlsx *.xls *.csv *.tsv *.txt *.json)")
        if path:self.run_job(lambda progress,cancel:inspect_file(path),lambda info:self.confirm_import(info,kind))
    def confirm_import(self,info,kind):
        dialog=ImportDialog(info,kind,self)
        if dialog.exec()!=QDialog.Accepted:return
        self.cancel.setEnabled(True)
        self.run_job(lambda progress,cancel:self.store.import_file(dialog.info,kind,dialog.mapping,dialog.source_date.text().strip(),dialog.full.isChecked(),progress,cancel),self.import_done)
    def import_done(self,result):
        self.refresh_regions();self.refresh();text=f"가져오기 완료 · 신규 {result['added']:,} / 변경 {result['changed']:,} / 동일 {result['unchanged']:,}개"
        self.message.setText(text)
        QMessageBox.information(self,"단지정보 가져오기",text+f"\n\n도로명주소 공란 {result['blank_roads']:,}개\n주소 형식 확인 {result['unparsed_roads']:,}개\n\n다음: ‘주소 중복 검토’에서 같은 주소의 등록을 비교하세요.\n‘표준지 목록’에서는 후보 전체를 Excel로 내보낼 수 있습니다.\n검토 기록은 유지하며, 변경된 단지 범위는 재검토로 표시합니다.")
    def export(self):
        if not self.store.stats()["candidates"]:QMessageBox.information(self,"표준지 내보내기","K-apt 단지정보를 먼저 가져오세요.");return
        choice=QMessageBox(self);choice.setWindowTitle("표준지 내보내기");choice.setText("내보낼 표준지 범위를 선택하세요.")
        all_button=choice.addButton("후보 전체",QMessageBox.AcceptRole);confirmed=choice.addButton("확정 표준지만",QMessageBox.AcceptRole);choice.addButton("취소",QMessageBox.RejectRole);choice.exec()
        if choice.clickedButton() not in {all_button,confirmed}:return
        only=choice.clickedButton()==confirmed
        path,_=QFileDialog.getSaveFileName(self,"표준지 내보내기","표준지목록.xlsx","Excel (*.xlsx);;CSV (*.csv)")
        if path:self.run_job(lambda p,c:self.store.export_standards(path,only),lambda count:self.message.setText(f"표준지 {count:,}개를 내보냈습니다."))
    def backup(self):
        path,_=QFileDialog.getSaveFileName(self,"보관함 백업","입지분석-보관함.sqlite3","입지분석 보관함 (*.sqlite3)")
        if path:self.run_job(lambda p,c:self.store.backup(path),lambda _:self.message.setText("원본·연결·검토 기록을 백업했습니다."))
    def restore(self):
        path,_=QFileDialog.getOpenFileName(self,"보관함 복원","","입지분석 보관함 (*.sqlite3)")
        if not path:return
        if QMessageBox.question(self,"보관함 복원","선택한 백업으로 현재 보관함을 교체할까요?\n현재 보관함도 복원 직전 백업으로 자동 보존합니다.",QMessageBox.Yes|QMessageBox.No,QMessageBox.No)!=QMessageBox.Yes:return
        self.run_job(lambda p,c:self.store.restore(path),lambda _:self.restore_done())
    def restore_done(self):self.refresh_regions();self.offset=0;self.refresh();self.message.setText("보관함을 복원했습니다. 복원 전 자료도 자동 백업했습니다.")
    def help(self):
        dialog=QDialog(self);dialog.setWindowTitle("입지분석 PC 사용 안내");dialog.resize(720,600);layout=QVBoxLayout(dialog)
        layout.addWidget(label("표준지 목록부터 시작합니다","title"))
        text=QPlainTextEdit();text.setReadOnly(True);text.setPlainText("1. K-apt 파일 가져오기\n공식 전국 단지 기본정보 엑셀(XLSX/XLS) 또는 CSV를 선택하세요. 열 이름을 자동 연결하고 미리보기를 제공합니다.\n\n2. 주소 중복 검토\n같은 주소라도 별개 관리단지라면 각각 유지합니다. 중복·멸실 등록은 사유와 함께 제외합니다. 원본은 보존합니다.\n\n3. 공시가격 단지 대조\n공시가격 목록을 파일로 가져오거나 고유 ID로 직접 등록하고, 각 K-apt 단지 검토 창에서 연결하세요. 다대다 연결을 지원합니다. 자동으로 연결을 승인하지 않습니다.\n\n4. 단지당 표준지 하나\n대표 도로명주소와 개별 건물·동을 선택하세요. 입구 좌표와 소속은 직접 확인할 수 있으며, 미확인 값은 비워 두어도 후보 목록을 저장합니다. 유효 판정·공시가격 연결·건물 소속·입구 좌표가 모두 확인되면 ‘확정’입니다.\n\n5. 다시 가져오기\n코드가 같은 원본만 갱신합니다. 수동 검토·제외는 유지하며 범위가 변경되면 재검토로 표시합니다. 전체 목록에서 빠진 코드는 ‘수록 확인’으로 남깁니다.\n\n6. 보관과 내보내기\n표준지 목록은 Excel/CSV로, 전체 보관함은 SQLite 백업으로 저장합니다. PC를 바꿀 때는 백업 파일을 복원하세요.\n\n이번 버전은 표준지 관리 전용입니다. 소분류 평가·도로/시설 자료·자동 수집·모바일 서버 연결은 다음 단계입니다. API 키 없이 동작합니다.\n\n현재 보관함\n"+str(self.store.path));layout.addWidget(text)
        links=QHBoxLayout();links.addWidget(button("K-apt 공식 자료 페이지",lambda:QDesktopServices.openUrl(QUrl("https://www.data.go.kr/data/15073271/fileData.do"))));links.addWidget(button("데이터 폴더 열기",lambda:QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.store.path.parent)))));layout.addLayout(links)
        close=button("닫기",dialog.accept);layout.addWidget(close);dialog.exec()
    def closeEvent(self,event):
        if self.job:
            self._closing=True;self.job.requestInterruption();self.message.setText("작업을 정리한 뒤 종료합니다.");event.ignore()
        else:event.accept()
