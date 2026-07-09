"""
scan_control_panel.py — DeepSonix Scan Control Panel

Dark-tech PyQt5 GUI for wafer ultrasound scanning.
Wraps StageController + VantageClient + ScanOrchestrator.

Run:
    python python/scan_control_panel.py
    python python/scan_control_panel.py --config config/scan_params.json
"""

import sys
import json
import pathlib
import datetime
import logging
import argparse
import numpy as np

from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QGridLayout, QGroupBox, QLabel, QLineEdit, QPushButton,
    QProgressBar, QPlainTextEdit, QFileDialog, QSplitter,
    QStatusBar, QFrame, QSizePolicy,
)
from PyQt5.QtCore import Qt, QThread, pyqtSignal, QTimer
from PyQt5.QtGui import QFont

# ── add python/ to path so stage/vantage packages resolve ─────────────────
_HERE = pathlib.Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

try:
    from stage.StageController import StageController, Axis, StopMode
    from vantage.VantageClient import VantageClient, AcqParams
    _BACKENDS_OK = True
except ImportError as _ie:
    _BACKENDS_OK = False
    _IMPORT_ERR = str(_ie)

# ── DeepSonix brand palette ────────────────────────────────────────────────
C = {
    "bg_win":   "#0a1830",
    "bg_panel": "#112040",
    "bg_input": "#0f1e38",
    "toolbar":  "#07111f",
    "cyan":     "#00c8f0",
    "amber":    "#f59c1a",
    "green":    "#1fbf75",
    "red":      "#e5484d",
    "text":     "#ffffff",
    "muted":    "#9fb2cc",
    "border":   "#22375c",
    "disabled": "#3a4a63",
}

APP_QSS = f"""
* {{
    font-family: "Segoe UI", "Inter", Arial, sans-serif;
}}
QMainWindow, QWidget {{
    background-color: {C['bg_win']};
    color: {C['text']};
    font-size: 13px;
}}
QGroupBox {{
    background-color: {C['bg_panel']};
    border: 1px solid {C['border']};
    border-radius: 6px;
    margin-top: 16px;
    padding: 8px;
    color: {C['amber']};
    font-weight: bold;
    font-size: 12px;
}}
QGroupBox::title {{
    subcontrol-origin: margin;
    subcontrol-position: top left;
    padding: 2px 8px;
    color: {C['amber']};
}}
QLabel {{
    color: {C['muted']};
    font-size: 12px;
    background: transparent;
}}
QLineEdit {{
    background-color: {C['bg_input']};
    border: 1px solid {C['border']};
    border-radius: 4px;
    padding: 4px 8px;
    color: {C['text']};
}}
QLineEdit:focus {{
    border-color: {C['cyan']};
}}
QLineEdit:read-only {{
    color: {C['muted']};
    background-color: {C['bg_win']};
}}
QLineEdit:disabled {{
    color: {C['disabled']};
    background-color: {C['bg_win']};
    border-color: {C['disabled']};
}}
QPushButton {{
    background-color: {C['bg_panel']};
    border: 1px solid {C['border']};
    border-radius: 4px;
    padding: 5px 14px;
    color: {C['text']};
    font-size: 12px;
}}
QPushButton:hover  {{ border-color: {C['cyan']}; color: {C['cyan']}; }}
QPushButton:pressed {{ background-color: {C['bg_input']}; }}
QPushButton:disabled {{ color: {C['disabled']}; border-color: {C['disabled']}; }}
QPushButton#start {{
    background-color: #152e20;
    border: 1px solid {C['green']};
    color: {C['green']};
    font-size: 14px;
    font-weight: bold;
    padding: 9px 28px;
    border-radius: 5px;
}}
QPushButton#start:hover {{ background-color: {C['green']}; color: #07111f; }}
QPushButton#start:disabled {{
    background: transparent;
    border-color: {C['disabled']};
    color: {C['disabled']};
}}
QPushButton#stop {{
    background-color: #2e1515;
    border: 1px solid {C['red']};
    color: {C['red']};
    font-size: 14px;
    font-weight: bold;
    padding: 9px 28px;
    border-radius: 5px;
}}
QPushButton#stop:hover {{ background-color: {C['red']}; color: #ffffff; }}
QPushButton#stop:disabled {{
    background: transparent;
    border-color: {C['disabled']};
    color: {C['disabled']};
}}
QPushButton#home {{
    border: 1px solid {C['cyan']};
    color: {C['cyan']};
    padding: 9px 20px;
    font-size: 13px;
}}
QPushButton#home:hover {{ background-color: {C['cyan']}; color: #07111f; }}
QPushButton#home:disabled {{ border-color: {C['disabled']}; color: {C['disabled']}; }}
QProgressBar {{
    background-color: {C['bg_input']};
    border: 1px solid {C['border']};
    border-radius: 4px;
    height: 14px;
    text-align: center;
    color: {C['text']};
    font-size: 11px;
}}
QProgressBar::chunk {{
    background-color: {C['cyan']};
    border-radius: 3px;
}}
QPlainTextEdit {{
    background-color: {C['toolbar']};
    border: 1px solid {C['border']};
    border-radius: 4px;
    color: {C['muted']};
    font-family: "Consolas", "Courier New", monospace;
    font-size: 11px;
    padding: 4px;
}}
QScrollBar:vertical {{
    background: {C['bg_win']};
    width: 8px;
}}
QScrollBar::handle:vertical {{
    background: {C['border']};
    border-radius: 4px;
    min-height: 20px;
}}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
QStatusBar {{
    background-color: {C['toolbar']};
    color: {C['muted']};
    font-size: 11px;
    border-top: 1px solid {C['border']};
}}
QSplitter::handle {{ background-color: {C['border']}; }}
"""

# ── Helpers ────────────────────────────────────────────────────────────────

def _dot(color: str) -> QLabel:
    """Small colored status indicator dot."""
    lbl = QLabel("●")
    lbl.setStyleSheet(f"color: {color}; font-size: 14px; background: transparent;")
    lbl.setFixedWidth(20)
    return lbl


def _row(label: str, widget: QWidget) -> QHBoxLayout:
    lbl = QLabel(label)
    lbl.setFixedWidth(76)
    row = QHBoxLayout()
    row.addWidget(lbl)
    row.addWidget(widget)
    return row


def _hline() -> QFrame:
    f = QFrame()
    f.setFrameShape(QFrame.HLine)
    f.setStyleSheet(f"color: {C['border']}; background: {C['border']};")
    f.setFixedHeight(1)
    return f


# ── Scan worker thread ─────────────────────────────────────────────────────

class ScanWorker(QThread):
    progress = pyqtSignal(int, int)   # current_step, total_steps
    log_msg  = pyqtSignal(str)
    done     = pyqtSignal(bool)       # success

    def __init__(self, stage, vantage, params: dict):
        super().__init__()
        self._stage   = stage
        self._vantage = vantage
        self._p       = params
        self._stop    = False

    def request_stop(self):
        self._stop = True
        try:
            self._stage.stop(Axis.X, StopMode.IMMEDIATE)
        except Exception:
            pass

    def run(self):
        step_mm   = self._p["step_mm"]
        range_mm  = self._p["range_mm"]
        n_steps   = int(round(range_mm / step_mm))
        save_dir  = pathlib.Path(self._p["save_dir"])
        prefix    = self._p["prefix"]
        frames    = []

        self.log_msg.emit(f"Scan started: {n_steps} steps × {step_mm} mm = {range_mm} mm")

        try:
            for step in range(n_steps):
                if self._stop:
                    self.log_msg.emit("Scan aborted by user.")
                    self.done.emit(False)
                    return

                self._stage.move(Axis.X, step_mm)
                self._vantage.soft_trigger()
                self._vantage.wait_for_acquisition(timeout_s=2.0)
                self._vantage.copy_buffers()
                buf = self._vantage.get_rcv_buffer(buf_index=1)
                frames.append(buf.data[buf.frame_index].copy())

                self.progress.emit(step + 1, n_steps)
                if (step + 1) % 50 == 0:
                    self.log_msg.emit(f"  step {step + 1}/{n_steps}")

            data = np.stack(frames, axis=0)
            today = datetime.date.today().strftime("%d-%B-%Y")
            out = save_dir / today
            out.mkdir(parents=True, exist_ok=True)
            stem = f"{prefix}_{today}"
            data.tofile(str(out / f"{stem}.txt"))
            np.save(str(out / f"{stem}_size.npy"), np.array(data.shape))
            self.log_msg.emit(f"Saved → {out / stem}.txt")
            self.done.emit(True)

        except Exception as exc:
            self.log_msg.emit(f"ERROR: {exc}")
            self.done.emit(False)


# ── Main window ────────────────────────────────────────────────────────────

class ScanControlPanel(QMainWindow):

    def __init__(self, config_path: str = None):
        super().__init__()
        self._stage   = None
        self._vantage = None
        self._worker  = None
        self._cfg_path = config_path

        self._params = {
            "stage_ip":   "192.168.0.30",
            "stage_port": "8088",
            "stage_dll":  "FMC4030-Dll.dll",
            "vantage_lib": "libVantageInterface.dll",
            "step_mm":    0.05,
            "range_mm":   60.0,
            "save_dir":   "E:\\issac\\chip_scan",
            "prefix":     "RFbatch_5angle_PI_single_step0.05mm",
        }
        if config_path:
            self._load_config(config_path)

        self._build_ui()
        self._apply_params_to_ui()

        self._pos_timer = QTimer(self)
        self._pos_timer.setInterval(500)
        self._pos_timer.timeout.connect(self._poll_position)

        if not _BACKENDS_OK:
            self._log(f"WARNING: backend import failed — {_IMPORT_ERR}")
            self._log("GUI is in demo mode; connect/scan will not work.")

    # ── Config helpers ─────────────────────────────────────────────────────

    def _load_config(self, path: str):
        try:
            cfg = json.loads(pathlib.Path(path).read_text())
            s = cfg.get("stage", {})
            sc = cfg.get("scan", {})
            sv = cfg.get("save", {})
            self._params.update({
                "stage_ip":   s.get("ip",   self._params["stage_ip"]),
                "stage_port": str(s.get("port", self._params["stage_port"])),
                "step_mm":    sc.get("step_mm",  self._params["step_mm"]),
                "range_mm":   sc.get("range_mm", self._params["range_mm"]),
                "save_dir":   sv.get("base_dir", self._params["save_dir"]),
                "prefix":     sv.get("filename_prefix", self._params["prefix"]),
            })
            self._log(f"Config loaded: {path}")
        except Exception as exc:
            self._log(f"Config load error: {exc}")

    def _apply_params_to_ui(self):
        p = self._params
        self._e_ip.setText(p["stage_ip"])
        self._e_port.setText(str(p["stage_port"]))
        self._e_dll.setText(p["stage_dll"])
        self._e_vlib.setText(p["vantage_lib"])
        self._e_step.setText(str(p["step_mm"]))
        self._e_range.setText(str(p["range_mm"]))
        self._e_savedir.setText(p["save_dir"])
        self._e_prefix.setText(p["prefix"])

    # ── UI construction ────────────────────────────────────────────────────

    def _build_ui(self):
        self.setWindowTitle("DeepSonix — Scan Control Panel")
        self.setMinimumSize(900, 700)
        self.resize(1060, 780)

        root = QWidget()
        self.setCentralWidget(root)
        vbox = QVBoxLayout(root)
        vbox.setContentsMargins(0, 0, 0, 0)
        vbox.setSpacing(0)

        vbox.addWidget(self._make_header())
        vbox.addWidget(self._make_divider())

        body = QWidget()
        body_h = QHBoxLayout(body)
        body_h.setContentsMargins(12, 12, 12, 12)
        body_h.setSpacing(12)
        body_h.addWidget(self._make_left_panel(), stretch=4)
        body_h.addWidget(self._make_right_panel(), stretch=3)
        vbox.addWidget(body, stretch=1)

        vbox.addWidget(self._make_divider())
        vbox.addWidget(self._make_action_bar())
        vbox.addWidget(self._make_log_area())

        self._build_status_bar()
        self._update_buttons()

    def _make_header(self) -> QWidget:
        w = QWidget()
        w.setFixedHeight(56)
        w.setStyleSheet(f"background-color: {C['toolbar']}; border-bottom: 1px solid {C['border']};")
        h = QHBoxLayout(w)
        h.setContentsMargins(16, 0, 16, 0)

        brand = QLabel("Deep<span style='color:{};'>Sonix</span>".format(C['cyan']))
        brand.setTextFormat(Qt.RichText)
        brand.setStyleSheet(f"color: {C['text']}; font-size: 20px; font-weight: bold; background: transparent;")

        sep = QLabel(" | ")
        sep.setStyleSheet(f"color: {C['border']}; font-size: 18px; background: transparent;")

        title = QLabel("Scan Control Panel")
        title.setStyleSheet(f"color: {C['muted']}; font-size: 16px; background: transparent;")

        self._status_dot = _dot(C['disabled'])
        self._status_lbl = QLabel("Idle")
        self._status_lbl.setStyleSheet(f"color: {C['muted']}; font-size: 12px; background: transparent;")

        h.addWidget(brand)
        h.addWidget(sep)
        h.addWidget(title)
        h.addStretch()
        h.addWidget(self._status_dot)
        h.addWidget(self._status_lbl)
        return w

    def _make_divider(self) -> QFrame:
        f = QFrame()
        f.setFrameShape(QFrame.HLine)
        f.setFixedHeight(1)
        f.setStyleSheet(f"background-color: {C['border']}; border: none;")
        return f

    # ── Left panel: connections + position ────────────────────────────────

    def _make_left_panel(self) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(10)
        v.addWidget(self._make_stage_group())
        v.addWidget(self._make_vantage_group())
        v.addWidget(self._make_position_group())
        v.addStretch()
        return w

    def _make_stage_group(self) -> QGroupBox:
        g = QGroupBox("Stage  (FMC4030)")
        v = QVBoxLayout(g)
        v.setSpacing(6)

        self._e_ip   = QLineEdit()
        self._e_port = QLineEdit(); self._e_port.setFixedWidth(64)
        self._e_dll  = QLineEdit()

        ip_row = QHBoxLayout()
        ip_lbl = QLabel("IP"); ip_lbl.setFixedWidth(30)
        pt_lbl = QLabel("Port"); pt_lbl.setFixedWidth(34)
        ip_row.addWidget(ip_lbl); ip_row.addWidget(self._e_ip)
        ip_row.addWidget(pt_lbl); ip_row.addWidget(self._e_port)

        dll_row = QHBoxLayout()
        dll_lbl = QLabel("DLL"); dll_lbl.setFixedWidth(30)
        btn_dll = QPushButton("…"); btn_dll.setFixedWidth(28)
        btn_dll.clicked.connect(lambda: self._browse_file(self._e_dll, "DLL (*.dll)"))
        dll_row.addWidget(dll_lbl); dll_row.addWidget(self._e_dll); dll_row.addWidget(btn_dll)

        btn_row = QHBoxLayout()
        self._btn_stage_con  = QPushButton("Connect")
        self._btn_stage_dis  = QPushButton("Disconnect")
        self._stage_dot      = _dot(C['disabled'])
        btn_row.addWidget(self._stage_dot)
        btn_row.addWidget(self._btn_stage_con)
        btn_row.addWidget(self._btn_stage_dis)
        btn_row.addStretch()

        self._btn_stage_con.clicked.connect(self._on_stage_connect)
        self._btn_stage_dis.clicked.connect(self._on_stage_disconnect)

        v.addLayout(ip_row)
        v.addLayout(dll_row)
        v.addLayout(btn_row)
        return g

    def _make_vantage_group(self) -> QGroupBox:
        g = QGroupBox("Vantage  (Ultrasound)")
        v = QVBoxLayout(g)
        v.setSpacing(6)

        self._e_vlib = QLineEdit()
        lib_row = QHBoxLayout()
        lib_lbl = QLabel("Lib"); lib_lbl.setFixedWidth(30)
        btn_lib = QPushButton("…"); btn_lib.setFixedWidth(28)
        btn_lib.clicked.connect(lambda: self._browse_file(self._e_vlib, "DLL/SO (*.dll *.so)"))
        lib_row.addWidget(lib_lbl); lib_row.addWidget(self._e_vlib); lib_row.addWidget(btn_lib)

        btn_row = QHBoxLayout()
        self._btn_van_init  = QPushButton("Initialize")
        self._btn_van_shut  = QPushButton("Shutdown")
        self._van_dot       = _dot(C['disabled'])
        btn_row.addWidget(self._van_dot)
        btn_row.addWidget(self._btn_van_init)
        btn_row.addWidget(self._btn_van_shut)
        btn_row.addStretch()

        self._btn_van_init.clicked.connect(self._on_vantage_init)
        self._btn_van_shut.clicked.connect(self._on_vantage_shutdown)

        v.addLayout(lib_row)
        v.addLayout(btn_row)
        return g

    def _make_position_group(self) -> QGroupBox:
        g = QGroupBox("Stage Position")
        grid = QGridLayout(g)
        grid.setSpacing(6)

        def _pos_field():
            e = QLineEdit("— mm")
            e.setReadOnly(True)
            e.setStyleSheet(
                f"color: {C['cyan']}; font-family: Consolas, monospace; "
                f"font-size: 14px; font-weight: bold; "
                f"background: {C['bg_win']}; border: 1px solid {C['border']};"
            )
            e.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
            return e

        self._pos_x = _pos_field()
        self._pos_y = _pos_field()
        self._pos_z = _pos_field()

        for row, (ax, fld) in enumerate(
            [("X", self._pos_x), ("Y", self._pos_y), ("Z", self._pos_z)]
        ):
            lbl = QLabel(ax)
            lbl.setStyleSheet(f"color: {C['amber']}; font-weight: bold; font-size: 14px;")
            lbl.setAlignment(Qt.AlignCenter)
            grid.addWidget(lbl, row, 0)
            grid.addWidget(fld, row, 1)

        self._btn_refresh = QPushButton("Refresh")
        self._btn_refresh.clicked.connect(self._poll_position)
        grid.addWidget(self._btn_refresh, 3, 0, 1, 2)
        return g

    # ── Right panel: scan parameters ───────────────────────────────────────

    def _make_right_panel(self) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(10)
        v.addWidget(self._make_params_group())
        v.addWidget(self._make_config_group())
        v.addStretch()
        return w

    def _make_params_group(self) -> QGroupBox:
        g = QGroupBox("Scan Parameters")
        grid = QGridLayout(g)
        grid.setSpacing(8)
        grid.setColumnMinimumWidth(0, 90)

        self._e_step   = QLineEdit()
        self._e_range  = QLineEdit()
        self._e_savedir = QLineEdit()
        self._e_prefix = QLineEdit()

        rows = [
            ("Step (mm)",    self._e_step),
            ("Range (mm)",   self._e_range),
            ("Save dir",     self._e_savedir),
            ("Prefix",       self._e_prefix),
        ]
        for i, (lbl, w_) in enumerate(rows):
            grid.addWidget(QLabel(lbl), i, 0)
            if lbl == "Save dir":
                h = QHBoxLayout()
                btn = QPushButton("…"); btn.setFixedWidth(28)
                btn.clicked.connect(self._browse_savedir)
                h.addWidget(w_); h.addWidget(btn)
                grid.addLayout(h, i, 1)
            else:
                grid.addWidget(w_, i, 1)

        # Derived info labels
        self._lbl_steps = QLabel("— steps")
        self._lbl_steps.setStyleSheet(f"color: {C['cyan']}; font-size: 11px;")
        grid.addWidget(self._lbl_steps, len(rows), 1)

        self._e_step.textChanged.connect(self._update_steps_label)
        self._e_range.textChanged.connect(self._update_steps_label)
        return g

    def _make_config_group(self) -> QGroupBox:
        g = QGroupBox("Config File")
        v = QVBoxLayout(g)
        v.setSpacing(6)

        self._e_cfg = QLineEdit()
        self._e_cfg.setReadOnly(True)
        self._e_cfg.setPlaceholderText("(no config loaded)")
        if self._cfg_path:
            self._e_cfg.setText(self._cfg_path)

        btn_load = QPushButton("Load config/scan_params.json")
        btn_load.clicked.connect(self._on_load_config)

        v.addWidget(self._e_cfg)
        v.addWidget(btn_load)
        return g

    # ── Action bar: home / start / stop / progress ─────────────────────────

    def _make_action_bar(self) -> QWidget:
        w = QWidget()
        w.setStyleSheet(f"background-color: {C['bg_panel']};")
        v = QVBoxLayout(w)
        v.setContentsMargins(16, 12, 16, 12)
        v.setSpacing(10)

        btn_row = QHBoxLayout()
        self._btn_home  = QPushButton("⌂  Home X")
        self._btn_start = QPushButton("▶  Start Scan")
        self._btn_stop  = QPushButton("■  Stop")
        self._btn_home.setObjectName("home")
        self._btn_start.setObjectName("start")
        self._btn_stop.setObjectName("stop")

        self._btn_home.clicked.connect(self._on_home)
        self._btn_start.clicked.connect(self._on_start_scan)
        self._btn_stop.clicked.connect(self._on_stop_scan)

        btn_row.addWidget(self._btn_home)
        btn_row.addStretch()
        btn_row.addWidget(self._btn_start)
        btn_row.addSpacing(12)
        btn_row.addWidget(self._btn_stop)

        self._progress = QProgressBar()
        self._progress.setValue(0)
        self._progress.setFormat("%v / %m steps")
        self._progress.setFixedHeight(18)

        v.addLayout(btn_row)
        v.addWidget(self._progress)
        return w

    def _make_log_area(self) -> QWidget:
        w = QWidget()
        w.setFixedHeight(160)
        v = QVBoxLayout(w)
        v.setContentsMargins(12, 4, 12, 8)
        v.setSpacing(2)

        hdr = QLabel("Log")
        hdr.setStyleSheet(f"color: {C['amber']}; font-weight: bold; font-size: 11px;")

        self._log_box = QPlainTextEdit()
        self._log_box.setReadOnly(True)
        self._log_box.setMaximumBlockCount(500)

        v.addWidget(hdr)
        v.addWidget(self._log_box)
        return w

    def _build_status_bar(self):
        sb = self.statusBar()
        self._sb_stage   = QLabel("Stage: —")
        self._sb_vantage = QLabel("Vantage: —")
        self._sb_state   = QLabel("Idle")
        sb.addPermanentWidget(self._sb_stage)
        sb.addPermanentWidget(QLabel("|"))
        sb.addPermanentWidget(self._sb_vantage)
        sb.addPermanentWidget(QLabel("|"))
        sb.addPermanentWidget(self._sb_state)

    # ── Slot implementations ───────────────────────────────────────────────

    def _on_stage_connect(self):
        if not _BACKENDS_OK:
            self._log("Backend not available."); return
        try:
            self._stage = StageController(
                dll_path  = self._e_dll.text(),
                device_id = 1,
                ip        = self._e_ip.text(),
                port      = int(self._e_port.text()),
            )
            self._stage.connect()
            self._stage_dot.setText("●")
            self._stage_dot.setStyleSheet(f"color: {C['green']}; font-size: 14px; background: transparent;")
            self._sb_stage.setText("Stage: Connected")
            self._log(f"Stage connected ({self._e_ip.text()}:{self._e_port.text()})")
            self._pos_timer.start()
            self._poll_position()
        except Exception as exc:
            self._log(f"Stage connect error: {exc}")
        self._update_buttons()

    def _on_stage_disconnect(self):
        self._pos_timer.stop()
        if self._stage:
            try:
                self._stage.disconnect()
            except Exception as exc:
                self._log(f"Stage disconnect: {exc}")
            self._stage = None
        self._stage_dot.setText("●")
        self._stage_dot.setStyleSheet(f"color: {C['disabled']}; font-size: 14px; background: transparent;")
        self._sb_stage.setText("Stage: —")
        for f in (self._pos_x, self._pos_y, self._pos_z):
            f.setText("— mm")
        self._log("Stage disconnected.")
        self._update_buttons()

    def _on_vantage_init(self):
        if not _BACKENDS_OK:
            self._log("Backend not available."); return
        try:
            self._vantage = VantageClient(lib_path=self._e_vlib.text())
            self._vantage.initialize()
            self._van_dot.setText("●")
            self._van_dot.setStyleSheet(f"color: {C['green']}; font-size: 14px; background: transparent;")
            self._sb_vantage.setText("Vantage: Ready")
            self._log("Vantage initialized.")
        except Exception as exc:
            self._log(f"Vantage init error: {exc}")
        self._update_buttons()

    def _on_vantage_shutdown(self):
        if self._vantage:
            try:
                self._vantage.shutdown()
            except Exception as exc:
                self._log(f"Vantage shutdown: {exc}")
            self._vantage = None
        self._van_dot.setText("●")
        self._van_dot.setStyleSheet(f"color: {C['disabled']}; font-size: 14px; background: transparent;")
        self._sb_vantage.setText("Vantage: —")
        self._log("Vantage shut down.")
        self._update_buttons()

    def _on_home(self):
        if not self._stage:
            self._log("Stage not connected."); return
        self._log("Homing X axis...")
        try:
            self._stage.home(Axis.X)
            self._log("Home complete.")
            self._poll_position()
        except Exception as exc:
            self._log(f"Home error: {exc}")

    def _on_start_scan(self):
        if not (self._stage and self._vantage):
            self._log("Connect Stage and Vantage before scanning."); return
        try:
            step_mm  = float(self._e_step.text())
            range_mm = float(self._e_range.text())
        except ValueError:
            self._log("Invalid step or range value."); return

        params = {
            "step_mm":  step_mm,
            "range_mm": range_mm,
            "save_dir": self._e_savedir.text(),
            "prefix":   self._e_prefix.text(),
        }
        n_steps = int(round(range_mm / step_mm))
        self._progress.setMaximum(n_steps)
        self._progress.setValue(0)
        self._set_scanning(True)

        self._worker = ScanWorker(self._stage, self._vantage, params)
        self._worker.progress.connect(self._on_scan_progress)
        self._worker.log_msg.connect(self._log)
        self._worker.done.connect(self._on_scan_done)
        self._worker.start()

    def _on_stop_scan(self):
        if self._worker and self._worker.isRunning():
            self._worker.request_stop()
            self._log("Stop requested…")
        else:
            self._log("No scan running.")

    def _on_scan_progress(self, step: int, total: int):
        self._progress.setValue(step)
        self._poll_position()

    def _on_scan_done(self, success: bool):
        self._set_scanning(False)
        self._log("Scan finished." if success else "Scan ended (not complete).")

    def _poll_position(self):
        if not self._stage:
            return
        try:
            pos = self._stage.get_position()
            self._pos_x.setText(f"{pos.x:+.4f} mm")
            self._pos_y.setText(f"{pos.y:+.4f} mm")
            self._pos_z.setText(f"{pos.z:+.4f} mm")
        except Exception:
            pass

    def _on_load_config(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Load config", str(pathlib.Path.cwd()), "JSON (*.json)"
        )
        if path:
            self._e_cfg.setText(path)
            self._load_config(path)
            self._apply_params_to_ui()

    # ── UI helpers ─────────────────────────────────────────────────────────

    def _log(self, msg: str):
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        self._log_box.appendPlainText(f"[{ts}]  {msg}")

    def _update_steps_label(self):
        try:
            n = int(round(float(self._e_range.text()) / float(self._e_step.text())))
            self._lbl_steps.setText(f"{n} steps")
        except (ValueError, ZeroDivisionError):
            self._lbl_steps.setText("— steps")

    def _update_buttons(self):
        stage_ok   = self._stage   is not None
        vantage_ok = self._vantage is not None
        scanning   = self._worker is not None and self._worker.isRunning()

        self._btn_stage_con.setEnabled(not stage_ok)
        self._btn_stage_dis.setEnabled(stage_ok)
        self._btn_van_init.setEnabled(not vantage_ok)
        self._btn_van_shut.setEnabled(vantage_ok)
        self._btn_home.setEnabled(stage_ok and not scanning)
        self._btn_start.setEnabled(stage_ok and vantage_ok and not scanning)
        self._btn_stop.setEnabled(scanning)
        self._btn_refresh.setEnabled(stage_ok)

    def _set_scanning(self, active: bool):
        color  = C['cyan'] if active else C['disabled']
        label  = "Scanning…" if active else "Idle"
        self._status_dot.setStyleSheet(f"color: {color}; font-size: 14px; background: transparent;")
        self._status_lbl.setText(label)
        self._sb_state.setText(label)
        self._update_buttons()

    def _browse_file(self, field: QLineEdit, filt: str):
        path, _ = QFileDialog.getOpenFileName(self, "Select file", "", filt)
        if path:
            field.setText(path)

    def _browse_savedir(self):
        path = QFileDialog.getExistingDirectory(self, "Select save directory")
        if path:
            self._e_savedir.setText(path)

    def closeEvent(self, event):
        if self._worker and self._worker.isRunning():
            self._worker.request_stop()
            self._worker.wait(2000)
        self._on_stage_disconnect()
        self._on_vantage_shutdown()
        super().closeEvent(event)


# ── Entry point ────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="DeepSonix Scan Control Panel")
    parser.add_argument("--config", default=None, help="Path to scan_params.json")
    args = parser.parse_args()

    app = QApplication(sys.argv)
    app.setStyleSheet(APP_QSS)
    app.setFont(QFont("Segoe UI", 10))

    win = ScanControlPanel(config_path=args.config)
    win.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
