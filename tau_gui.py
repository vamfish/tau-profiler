#!/usr/bin/env python3
"""
Tau-Profiler Professional GUI
─────────────────────────────
PyQt6 + pyqtgraph hacker-terminal dark theme.
Cache / TLB / PageFault / CtxSwitch charts + PDF/HTML report export.
"""

import sys
import os
import subprocess
import json
import math
import shutil
from pathlib import Path
from datetime import datetime
from typing import Optional

# ── Qt ──────────────────────────────────────────────────────────────
from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QTabWidget, QPushButton, QLabel, QFrame, QSplitter,
    QGridLayout, QFileDialog, QMessageBox, QStatusBar, QComboBox,
    QCheckBox, QProgressBar, QScrollArea, QGroupBox, QTextEdit,
    QToolBar, QMenu, QToolButton, QStyleFactory, QDialog,
    QSpinBox, QDoubleSpinBox, QFormLayout,
)
from PyQt6.QtCore import (
    Qt, QTimer, QThread, pyqtSignal, QSize, QUrl, QRectF,
)
from PyQt6.QtGui import (
    QFont, QColor, QPalette, QIcon, QAction, QFontDatabase, QFontInfo,
    QPixmap, QPainter, QBrush, QPen, QCursor,
)

# ── pyqtgraph ───────────────────────────────────────────────────────
import pyqtgraph as pg
pg.setConfigOptions(antialias=True, foreground=(0, 220, 0))

# ── Report ──────────────────────────────────────────────────────────
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm, cm
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Image, Table, TableStyle, PageBreak
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.graphics.shapes import Drawing, Rect, String, Line
from reportlab.graphics.charts.barcharts import VerticalBarChart
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics import renderPDF

# ─────────────────────────────────────────────────────────────────────
#  HACKER DARK THEME
# ─────────────────────────────────────────────────────────────────────

THEME = {
    "bg":         "#0a0a0a",
    "bg2":        "#111111",
    "bg3":        "#1a1a1a",
    "panel":      "#0d0d0d",
    "border":     "#1a3a1a",
    "text":       "#b0ffb0",
    "text_dim":   "#508050",
    "accent":     "#00ff41",
    "accent2":    "#00cc88",
    "cyan":       "#00e5ff",
    "warning":    "#ffaa00",
    "error":      "#ff3355",
    "chart_bg":   "#0d0d0d",
    "grid":       "#1a2a1a",
    "plot_color": "#00ff41",
    "colors": [
        "#00ff41", "#00e5ff", "#ffaa00", "#ff3355",
        "#aa66ff", "#ff66aa", "#66ffaa", "#ffaa66",
    ],
}

# ─────────────────────────────────────────────────────────────────────
#  ENGINE WRAPPER
# ─────────────────────────────────────────────────────────────────────

def find_engine() -> str:
    candidates = [
        "./zig-out/bin/tau_profiler",
        "./tau_profiler",
        str(Path(__file__).parent / "zig-out" / "bin" / "tau_profiler"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return ""


def run_engine(engine_path: str, progress_cb=None) -> dict:
    proc = subprocess.Popen(
        [engine_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stderr_text = proc.stderr.read()
    stdout_text = proc.stdout.read()
    proc.wait()

    if progress_cb:
        for line in stderr_text.split("\n"):
            if line.strip():
                progress_cb(line.strip())

    if proc.returncode != 0:
        raise RuntimeError(f"Engine exited with code {proc.returncode}\n{stderr_text[:500]}")

    try:
        data = json.loads(stdout_text)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"JSON parse error: {e}")

    # Normalise v1 → v2 format
    if data.get("version", 1) < 2:
        results = data.pop("results", [])
        data["cache"] = [r for r in results if "tlb" not in r.get("label","").lower()]
        tlb_results = [r for r in results if "tlb" in r.get("label","").lower() or "reach" in r.get("label","").lower()]
        if tlb_results:
            data["tlb"] = tlb_results
        if "pagefault" not in data:
            data["pagefault"] = []
        if "ctxswitch" not in data:
            data["ctxswitch"] = []
        data["version"] = 2

    # Normalise size_bytes -> size for backward compat
    for category in ("cache", "tlb", "pagefault", "ctxswitch"):
        for item in data.get(category, []):
            if "size_bytes" in item and "size" not in item:
                item["size"] = item["size_bytes"]

    return data


# ─────────────────────────────────────────────────────────────────────
#  STYLESHEET
# ─────────────────────────────────────────────────────────────────────

STYLESHEET = f"""
QMainWindow, QWidget {{
    background-color: {THEME['bg']};
    color: {THEME['text']};
    font-family: 'Fira Code', 'JetBrains Mono', 'Cascadia Code', 'Consolas', 'Courier New', monospace;
    font-size: 13px;
}}
QTabWidget::pane {{
    border: 1px solid {THEME['border']};
    background: {THEME['bg2']};
}}
QTabBar::tab {{
    background: {THEME['bg3']};
    color: {THEME['text_dim']};
    border: 1px solid {THEME['border']};
    border-bottom: none;
    padding: 8px 18px;
    margin-right: 2px;
    font-weight: bold;
    font-size: 12px;
}}
QTabBar::tab:selected {{
    background: {THEME['bg']};
    color: {THEME['accent']};
    border-bottom: 2px solid {THEME['accent']};
}}
QTabBar::tab:hover {{
    color: {THEME['text']};
}}
QPushButton {{
    background: {THEME['bg3']};
    color: {THEME['accent']};
    border: 1px solid {THEME['accent']};
    border-radius: 4px;
    padding: 6px 16px;
    font-weight: bold;
    font-size: 12px;
}}
QPushButton:hover {{
    background: {THEME['accent']};
    color: {THEME['bg']};
}}
QPushButton:pressed {{
    background: {THEME['accent2']};
}}
QPushButton:disabled {{
    border-color: {THEME['text_dim']};
    color: {THEME['text_dim']};
    background: {THEME['bg3']};
}}
QLabel {{
    color: {THEME['text']};
    background: transparent;
}}
QFrame {{
    border-color: {THEME['border']};
}}
QComboBox {{
    background: {THEME['bg3']};
    color: {THEME['text']};
    border: 1px solid {THEME['border']};
    border-radius: 4px;
    padding: 4px 8px;
}}
QComboBox::drop-down {{
    border: none;
}}
QComboBox::item:selected {{
    background: {THEME['accent']};
    color: {THEME['bg']};
}}
QProgressBar {{
    border: 1px solid {THEME['border']};
    background: {THEME['bg3']};
    border-radius: 4px;
    text-align: center;
    color: {THEME['text']};
    height: 20px;
}}
QProgressBar::chunk {{
    background: {THEME['accent']};
    border-radius: 3px;
}}
QTextEdit {{
    background: {THEME['bg']};
    color: {THEME['text']};
    border: 1px solid {THEME['border']};
    border-radius: 4px;
    font-family: 'Fira Code', 'JetBrains Mono', 'Consolas', monospace;
    selection-background-color: {THEME['accent']};
    selection-color: {THEME['bg']};
}}
QGroupBox {{
    border: 1px solid {THEME['border']};
    border-radius: 6px;
    margin-top: 12px;
    padding-top: 16px;
    font-weight: bold;
    color: {THEME['accent']};
}}
QGroupBox::title {{
    subcontrol-origin: margin;
    left: 12px;
    padding: 0 6px;
}}
QCheckBox {{
    spacing: 8px;
}}
QCheckBox::indicator {{
    width: 16px;
    height: 16px;
    border: 1px solid {THEME['border']};
    border-radius: 3px;
}}
QCheckBox::indicator:checked {{
    background: {THEME['accent']};
}}
QScrollBar:vertical {{
    background: {THEME['bg2']};
    width: 10px;
}}
QScrollBar::handle:vertical {{
    background: {THEME['border']};
    border-radius: 5px;
    min-height: 20px;
}}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{
    height: 0px;
}}
QStatusBar {{
    background: {THEME['bg2']};
    color: {THEME['text_dim']};
    border-top: 1px solid {THEME['border']};
    font-size: 11px;
}}
QToolBar {{
    background: {THEME['bg2']};
    border-bottom: 1px solid {THEME['border']};
    spacing: 6px;
    padding: 4px;
}}
QMenu {{
    background: {THEME['bg3']};
    color: {THEME['text']};
    border: 1px solid {THEME['border']};
}}
QMenu::item:selected {{
    background: {THEME['accent']};
    color: {THEME['bg']};
}}
QSpinBox, QDoubleSpinBox {{
    background: {THEME['bg3']};
    color: {THEME['text']};
    border: 1px solid {THEME['border']};
    border-radius: 4px;
    padding: 4px;
}}
"""


# ─────────────────────────────────────────────────────────────────────
#  RUNNER THREAD
# ─────────────────────────────────────────────────────────────────────

class EngineRunner(QThread):
    progress = pyqtSignal(str)
    finished = pyqtSignal(dict)
    error = pyqtSignal(str)

    def __init__(self, engine_path: str):
        super().__init__()
        self.engine_path = engine_path

    def run(self):
        try:
            data = run_engine(self.engine_path, self.progress.emit)
            self.finished.emit(data)
        except Exception as e:
            self.error.emit(str(e))


# ─────────────────────────────────────────────────────────────────────
#  UTILITY HELPERS
# ─────────────────────────────────────────────────────────────────────

def fmt_ns(ns: float) -> str:
    if ns < 0.001:
        return f"{ns*1000:.2f} ps"
    if ns < 1:
        return f"{ns*1000:.1f} ps"
    if ns < 1000:
        return f"{ns:.2f} ns"
    return f"{ns/1000:.3f} µs"


def fmt_size(b: int) -> str:
    if b >= 1024**3:
        return f"{b/(1024**3):.1f} GB"
    if b >= 1024**2:
        return f"{b//(1024**2)} MB"
    if b >= 1024:
        return f"{b//1024} KB"
    return f"{b} B"


def stat_value(values, suffix=""):
    """Format a single stat line."""
    if not values:
        return "—"
    return f"{values:.2f}{suffix}"


# ─────────────────────────────────────────────────────────────────────
#  CUSTOM WIDGETS
# ─────────────────────────────────────────────────────────────────────

class HackerLabel(QLabel):
    """Label with monospace font and dim/green color options."""
    def __init__(self, text="", dim=False, accent=False, bold=False, size=12):
        super().__init__(text)
        self.h_dim = dim
        self.h_accent = accent
        self.h_bold = bold
        self.h_size = size
        self._apply_style()

    def _apply_style(self):
        c = THEME["accent"] if self.h_accent else (THEME["text_dim"] if self.h_dim else THEME["text"])
        w = "bold" if self.h_bold else "normal"
        self.setStyleSheet(f"color: {c}; font-weight: {w}; font-size: {self.h_size}px;")


class HackerFrame(QFrame):
    """Bordered frame with hacker theme."""
    def __init__(self, title=""):
        super().__init__()
        self.setFrameShape(QFrame.Shape.Box)
        self.setStyleSheet(f"""
            QFrame {{
                background: {THEME['panel']};
                border: 1px solid {THEME['border']};
                border-radius: 6px;
                padding: 8px;
            }}
        """)
        self.layout = QVBoxLayout(self)
        self.layout.setSpacing(4)
        self.layout.setContentsMargins(10, 8, 10, 8)
        if title:
            lbl = HackerLabel(f"# {title}", accent=True, bold=True, size=11)
            self.layout.addWidget(lbl)


# ─────────────────────────────────────────────────────────────────────
#  MAIN WINDOW
# ─────────────────────────────────────────────────────────────────────

class TauProfilerGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("⫸ TAU-PROFILER v2  ⫷")
        self.setMinimumSize(1280, 860)
        self.setStyleSheet(STYLESHEET)
        self.data: Optional[dict] = None
        self.engine_path = find_engine()
        self.current_report_image = None

        self._build_ui()
        self._connect_signals()

        # Auto-run if engine found
        if self.engine_path:
            QTimer.singleShot(300, self._run_benchmark)
        else:
            self._show_no_engine()

    # ── UI Construction ─────────────────────────────────────────

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setSpacing(0)
        layout.setContentsMargins(0, 0, 0, 0)

        # ── Header ──
        header = self._build_header()
        layout.addWidget(header)

        # ── Toolbar ──
        toolbar = self._build_toolbar()
        layout.addWidget(toolbar)

        # ── Tab content ──
        self.tabs = QTabWidget()
        layout.addWidget(self.tabs, 1)

        # Build tabs
        self.tab_dashboard = self._build_dashboard_tab()
        self.tab_cache = self._build_cache_tab()
        self.tab_tlb = self._build_tlb_tab()
        self.tab_pagefault = self._build_pagefault_tab()
        self.tab_ctxswitch = self._build_ctxswitch_tab()
        self.tab_report = self._build_report_tab()

        self.tabs.addTab(self.tab_dashboard, "  🖥  DASHBOARD  ")
        self.tabs.addTab(self.tab_cache, "  📊  CACHE  ")
        self.tabs.addTab(self.tab_tlb, "  📖  TLB  ")
        self.tabs.addTab(self.tab_pagefault, "  📄  PAGE FAULT  ")
        self.tabs.addTab(self.tab_ctxswitch, "  🔄  CTX SWITCH  ")
        self.tabs.addTab(self.tab_report, "  📋  REPORT  ")

        # ── Status bar ──
        self.status = QStatusBar()
        self.setStatusBar(self.status)
        self.lbl_status = QLabel("⏳ 等待运行...")
        self.lbl_status.setStyleSheet(f"color: {THEME['text_dim']};")
        self.status.addWidget(self.lbl_status)

        # ── Progress bar (hidden) ──
        self.progress = QProgressBar()
        self.progress.setMaximum(0)
        self.progress.setMinimum(0)
        self.progress.setFixedHeight(3)
        self.progress.setTextVisible(False)
        self.progress.hide()
        layout.addWidget(self.progress)

    def _build_header(self):
        h = QFrame()
        h.setFixedHeight(52)
        h.setStyleSheet(f"""
            QFrame {{
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0,
                    stop:0 #001a00, stop:0.5 #002200, stop:1 #001a00);
                border-bottom: 1px solid {THEME['accent']};
            }}
        """)
        hl = QHBoxLayout(h)
        hl.setContentsMargins(16, 4, 16, 4)

        title = QLabel("⫸  TAU  PROFILER  ⫷")
        title.setStyleSheet(f"""
            color: {THEME['accent']};
            font-size: 22px;
            font-weight: bold;
            letter-spacing: 4px;
            background: transparent;
        """)
        hl.addWidget(title)

        hl.addStretch()

        self.lbl_version = QLabel("v2.0  |  READY")
        self.lbl_version.setStyleSheet(f"color: {THEME['text_dim']}; font-size: 11px; background: transparent;")
        hl.addWidget(self.lbl_version)

        return h

    def _build_toolbar(self):
        tb = QToolBar()
        tb.setMovable(False)

        self.btn_run = QPushButton("▶ RUN BENCHMARK")
        self.btn_run.setIconSize(QSize(16, 16))
        tb.addWidget(self.btn_run)

        tb.addSeparator()

        self.btn_export_pdf = QPushButton("📄 EXPORT PDF")
        tb.addWidget(self.btn_export_pdf)

        self.btn_export_html = QPushButton("🌐 EXPORT HTML")
        tb.addWidget(self.btn_export_html)

        tb.addSeparator()

        self.btn_save_chart = QPushButton("💾 SAVE CHART")
        tb.addWidget(self.btn_save_chart)

        tb.addWidget(QLabel("   "))

        self.engine_status = QLabel("● ENGINE: READY" if self.engine_path else "● ENGINE: NOT FOUND")
        self.engine_status.setStyleSheet(f"""
            color: {THEME['accent'] if self.engine_path else THEME['error']};
            font-size: 11px; font-weight: bold; background: transparent;
        """)
        tb.addWidget(self.engine_status)

        return tb

    def _build_dashboard_tab(self):
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        inner = QWidget()
        scroll.setWidget(inner)
        layout = QVBoxLayout(inner)
        layout.setSpacing(12)
        layout.setContentsMargins(16, 16, 16, 16)

        # Platform Info
        self.dash_platform = HackerFrame("Platform Info")
        self.dash_platform_grid = QGridLayout()
        self.dash_platform_grid.setSpacing(6)
        self.dash_platform.layout.addLayout(self.dash_platform_grid)
        self.dash_platform_labels = {}
        for i, key in enumerate(["OS", "Arch", "CPU", "Vendor", "Cores", "Page Size", "Virtualized"]):
            lbl_k = HackerLabel(f"  {key}", dim=True, size=11)
            lbl_v = HackerLabel("—", accent=True, size=11)
            self.dash_platform_grid.addWidget(lbl_k, i, 0)
            self.dash_platform_grid.addWidget(lbl_v, i, 1)
            self.dash_platform_labels[key] = lbl_v
        layout.addWidget(self.dash_platform)

        # Calibration
        self.dash_cal = HackerFrame("Timer Calibration")
        self.dash_cal_grid = QGridLayout()
        self.dash_cal_grid.setSpacing(6)
        self.dash_cal.layout.addLayout(self.dash_cal_grid)
        self.dash_cal_labels = {}
        for i, key in enumerate(["TSC Frequency", "τ_cycle", "Timer Source", "Calibrated"]):
            lbl_k = HackerLabel(f"  {key}", dim=True, size=11)
            lbl_v = HackerLabel("—", accent=True, size=11)
            self.dash_cal_grid.addWidget(lbl_k, i, 0)
            self.dash_cal_grid.addWidget(lbl_v, i, 1)
            self.dash_cal_labels[key] = lbl_v
        layout.addWidget(self.dash_cal)

        # Tau Constants
        self.dash_tau = HackerFrame("τ Constants (Critical Latency Tiers)")
        self.dash_tau_grid = QGridLayout()
        self.dash_tau_grid.setSpacing(6)
        self.dash_tau.layout.addLayout(self.dash_tau_grid)
        self.dash_tau_labels = {}
        for i, key in enumerate(["τ_L1", "τ_L2", "τ_L3 (LLC)", "τ_DRAM", "τ_CTX_SWITCH", "τ_TLB_MISS"]):
            lbl_k = HackerLabel(f"  {key}", dim=True, size=11)
            lbl_v = HackerLabel("—", accent=True, size=11)
            self.dash_tau_grid.addWidget(lbl_k, i, 0)
            self.dash_tau_grid.addWidget(lbl_v, i, 1)
            self.dash_tau_labels[key] = lbl_v
        layout.addWidget(self.dash_tau)

        # Warnings
        self.dash_warnings = HackerFrame("Warnings")
        self.dash_warnings_labels = []
        self.dash_warnings.layout.addWidget(QLabel("   (no warnings)"))
        layout.addWidget(self.dash_warnings)

        layout.addStretch()
        return scroll

    def _build_cache_tab(self):
        w = QWidget()
        layout = QVBoxLayout(w)
        layout.setContentsMargins(16, 16, 16, 16)

        top = QHBoxLayout()
        self.cache_chart_type = QComboBox()
        self.cache_chart_type.addItems(["Bar Chart", "Line Chart", "Scatter"])
        top.addWidget(QLabel("Chart Type:"))
        top.addWidget(self.cache_chart_type)
        top.addStretch()
        layout.addLayout(top)

        self.cache_plot = pg.PlotWidget()
        self.cache_plot.setBackground(THEME["chart_bg"])
        self.cache_plot.showGrid(x=True, y=True, alpha=0.15)
        self.cache_plot.setLabel("left", "Latency", units="ns", color=THEME["text"])
        self.cache_plot.setLabel("bottom", "Cache Level", color=THEME["text"])
        self.cache_plot.addLegend(offset=(-10, 10))
        layout.addWidget(self.cache_plot, 1)

        # Stats table
        self.cache_info = QTextEdit()
        self.cache_info.setReadOnly(True)
        self.cache_info.setMaximumHeight(120)
        layout.addWidget(self.cache_info)

        self.cache_chart_type.currentTextChanged.connect(self._update_cache_chart)
        return w

    def _build_tlb_tab(self):
        w = QWidget()
        layout = QVBoxLayout(w)
        layout.setContentsMargins(16, 16, 16, 16)

        self.tlb_plot = pg.PlotWidget()
        self.tlb_plot.setBackground(THEME["chart_bg"])
        self.tlb_plot.showGrid(x=True, y=True, alpha=0.15)
        self.tlb_plot.setLabel("left", "Latency", units="ns", color=THEME["text"])
        self.tlb_plot.setLabel("bottom", "TLB Pages", color=THEME["text"])
        self.tlb_plot.addLegend(offset=(-10, 10))
        layout.addWidget(self.tlb_plot, 1)

        self.tlb_info = QTextEdit()
        self.tlb_info.setReadOnly(True)
        self.tlb_info.setMaximumHeight(120)
        layout.addWidget(self.tlb_info)
        return w

    def _build_pagefault_tab(self):
        w = QWidget()
        layout = QVBoxLayout(w)
        layout.setContentsMargins(16, 16, 16, 16)

        self.pf_plot = pg.PlotWidget()
        self.pf_plot.setBackground(THEME["chart_bg"])
        self.pf_plot.showGrid(x=True, y=True, alpha=0.15)
        self.pf_plot.setLabel("left", "Overhead", units="ns", color=THEME["text"])
        self.pf_plot.setLabel("bottom", "Benchmark", color=THEME["text"])
        self.pf_plot.addLegend(offset=(-10, 10))
        layout.addWidget(self.pf_plot, 1)

        self.pf_info = QTextEdit()
        self.pf_info.setReadOnly(True)
        self.pf_info.setMaximumHeight(120)
        layout.addWidget(self.pf_info)
        return w

    def _build_ctxswitch_tab(self):
        w = QWidget()
        layout = QVBoxLayout(w)
        layout.setContentsMargins(16, 16, 16, 16)

        self.ctx_plot = pg.PlotWidget()
        self.ctx_plot.setBackground(THEME["chart_bg"])
        self.ctx_plot.showGrid(x=True, y=True, alpha=0.15)
        self.ctx_plot.setLabel("left", "Latency", units="ns", color=THEME["text"])
        self.ctx_plot.setLabel("bottom", "Method", color=THEME["text"])
        self.ctx_plot.addLegend(offset=(-10, 10))
        layout.addWidget(self.ctx_plot, 1)

        self.ctx_info = QTextEdit()
        self.ctx_info.setReadOnly(True)
        self.ctx_info.setMaximumHeight(120)
        layout.addWidget(self.ctx_info)
        return w

    def _build_report_tab(self):
        w = QWidget()
        layout = QVBoxLayout(w)
        layout.setContentsMargins(16, 16, 16, 16)

        # Options
        opt_frame = HackerFrame("Export Options")
        grid = QGridLayout()
        grid.setSpacing(8)

        self.report_include_charts = QCheckBox("Include charts")
        self.report_include_charts.setChecked(True)
        grid.addWidget(self.report_include_charts, 0, 0)

        self.report_include_raw = QCheckBox("Include raw data")
        self.report_include_raw.setChecked(True)
        grid.addWidget(self.report_include_raw, 0, 1)

        grid.addWidget(QLabel(""), 1, 0)

        btn_row = QHBoxLayout()
        self.btn_export_pdf_r = QPushButton("📄  Export to PDF")
        self.btn_export_html_r = QPushButton("🌐  Export to HTML")
        btn_row.addWidget(self.btn_export_pdf_r)
        btn_row.addWidget(self.btn_export_html_r)
        btn_row.addStretch()
        grid.addLayout(btn_row, 2, 0, 1, 3)

        opt_frame.layout.addLayout(grid)
        layout.addWidget(opt_frame)

        # Preview
        self.report_preview = QTextEdit()
        self.report_preview.setReadOnly(True)
        self.report_preview.setPlaceholderText("Run a benchmark first, then export here...")
        layout.addWidget(self.report_preview, 1)

        return w

    # ── Signal Connections ────────────────────────────────────────

    def _connect_signals(self):
        self.btn_run.clicked.connect(self._run_benchmark)
        self.btn_export_pdf.clicked.connect(lambda: self._export_report("pdf"))
        self.btn_export_html.clicked.connect(lambda: self._export_report("html"))
        self.btn_export_pdf_r.clicked.connect(lambda: self._export_report("pdf"))
        self.btn_export_html_r.clicked.connect(lambda: self._export_report("html"))
        self.btn_save_chart.clicked.connect(self._save_current_chart)

    # ── Run Benchmark ────────────────────────────────────────────

    def _run_benchmark(self):
        if not self.engine_path:
            QMessageBox.warning(self, "Engine Not Found",
                "Tau-Profiler engine binary not found.\n\n"
                "Build it first:\n  $ zig build")
            return

        self._set_busy(True)
        self.lbl_status.setText("⏳ Running benchmark...")
        self.progress.show()

        self.runner = EngineRunner(self.engine_path)
        self.runner.progress.connect(lambda m: self.lbl_status.setText(f"⚙  {m}"))
        self.runner.finished.connect(self._on_data)
        self.runner.error.connect(self._on_error)
        self.runner.start()

    def _on_data(self, data: dict):
        self.data = data
        self._set_busy(False)
        self._populate_dashboard(data)
        self._populate_cache(data)
        self._populate_tlb(data)
        self._populate_pagefault(data)
        self._populate_ctxswitch(data)
        self._populate_report(data)
        self.lbl_status.setText(f"✅ Done — {datetime.now():%H:%M:%S}")
        self.tabs.setCurrentIndex(0)

    def _on_error(self, msg: str):
        self._set_busy(False)
        self.lbl_status.setText("❌ Error")
        QMessageBox.critical(self, "Benchmark Error", msg)

    def _set_busy(self, busy: bool):
        self.btn_run.setEnabled(not busy)
        self.btn_export_pdf.setEnabled(not busy)
        self.btn_export_html.setEnabled(not busy)
        self.progress.setVisible(busy)

    def _show_no_engine(self):
        self.lbl_status.setText("⚠ Engine not found — build with `zig build`")

    # ── Dashboard Population ─────────────────────────────────────

    def _populate_dashboard(self, data: dict):
        plat = data.get("platform", {})
        cal = data.get("calibration", {})

        mapping = {
            "OS": f"{plat.get('os', '?')}",
            "Arch": f"{plat.get('arch', '?')}",
            "CPU": f"{plat.get('cpu_brand', '?')}",
            "Vendor": f"{plat.get('cpu_vendor', '?')}",
            "Cores": f"{plat.get('physical_cores', '?')}P / {plat.get('logical_cores', '?')}L",
            "Page Size": fmt_size(plat.get('page_size', 4096)),
            "Virtualized": f"{plat.get('is_virtualized', '?')} ({plat.get('virtualized_under', '?')})",
        }
        for k, v in mapping.items():
            if k in self.dash_platform_labels:
                self.dash_platform_labels[k].setText(f"  {v}")

        # Calibration
        if cal.get("calibrated"):
            hz = cal["tsc_hz"]
            cpu_ps = (1.0 / hz) * 1e12
            self.dash_cal_labels["TSC Frequency"].setText(f"  {hz/1_000_000:.2f} MHz")
            self.dash_cal_labels["τ_cycle"].setText(f"  {cpu_ps:.2f} ps")
            self.dash_cal_labels["Timer Source"].setText(f"  {cal.get('source', 'tsc')}")
            self.dash_cal_labels["Calibrated"].setText("  ✓ YES")
        else:
            self.dash_cal_labels["Calibrated"].setText("  ✗ NO")

        # Tau constants
        tau_values = self._compute_tau(data)
        labels_map = {"τ_L1": "τ_L1", "τ_L2": "τ_L2", "τ_L3 (LLC)": "τ_L3", "τ_DRAM": "τ_DRAM"}
        for label, key in labels_map.items():
            val = tau_values.get(key)
            self.dash_tau_labels[label].setText(f"  {fmt_ns(val) if val else '—'}")

        # Context switch Tau
        ctx_results = data.get("ctxswitch", [])
        if ctx_results:
            valid = [r for r in ctx_results if r.get("latency_ns", 0) > 0]
            if valid:
                avg_cs = sum(r["latency_ns"] for r in valid) / len(valid)
                self.dash_tau_labels["τ_CTX_SWITCH"].setText(f"  {fmt_ns(avg_cs)}")
        else:
            self.dash_tau_labels["τ_CTX_SWITCH"].setText("  —")

        # TLB miss tau
        tlb_results = data.get("tlb", [])
        if tlb_results:
            max_pages = max(r.get("pages", 0) for r in tlb_results)
            biggest = [r for r in tlb_results if r.get("pages", 0) == max_pages]
            if biggest:
                self.dash_tau_labels["τ_TLB_MISS"].setText(f"  {fmt_ns(biggest[0]['latency_ns'])}")
        else:
            self.dash_tau_labels["τ_TLB_MISS"].setText("  —")

        # Warnings
        w = data.get("warnings", [])
        w_frame = self.dash_warnings
        # Clear old
        for i in reversed(range(w_frame.layout.count())):
            item = w_frame.layout.itemAt(i)
            if item and item.widget():
                item.widget().deleteLater()
        if w:
            for msg in w:
                w_frame.layout.addWidget(HackerLabel(f"  ⚠  {msg}", dim=True, size=11))
        else:
            w_frame.layout.addWidget(HackerLabel("   ✓ All clean", dim=True, size=11))

    def _compute_tau(self, data: dict) -> dict:
        results = data.get("cache", [])
        if not results:
            return {}

        def avg_by_size(min_s, max_s):
            items = [r for r in results if min_s <= r.get("size", 0) <= max_s]
            if not items:
                return None
            return sum(r["latency_ns"] for r in items) / len(items)

        return {
            "τ_L1": avg_by_size(0, 32 * 1024),
            "τ_L2": avg_by_size(64 * 1024, 256 * 1024),
            "τ_L3": avg_by_size(512 * 1024, 4 * 1024 * 1024),
            "τ_DRAM": avg_by_size(32 * 1024 * 1024, 10**12),
        }

    # ── Cache Charts ──────────────────────────────────────────────

    def _populate_cache(self, data: dict):
        self._update_cache_chart()

    def _update_cache_chart(self):
        self.cache_plot.clear()
        if not self.data:
            return

        results = self.data.get("cache", [])
        if not results:
            self.cache_info.setText("(no cache data)")
            return

        labels = [r.get("label", f"L{i}") for i, r in enumerate(results)]
        lats = [r["latency_ns"] for r in results]
        sizes = [r.get("size", 0) for r in results]
        confs = [r.get("confidence", 0) for r in results]
        cycles = [r.get("latency_cycles", 0) for r in results]

        chart_type = self.cache_chart_type.currentText()
        colors_c = THEME["colors"]

        if chart_type in ("Bar Chart",):
            bg = pg.BarGraphItem(
                x=list(range(len(results))),
                height=lats,
                width=0.6,
                brushes=[colors_c[i % len(colors_c)] for i in range(len(results))],
            )
            self.cache_plot.addItem(bg)
            self.cache_plot.getAxis("bottom").setTicks([list(enumerate(labels))])

        elif chart_type == "Line Chart":
            x = range(len(results))
            self.cache_plot.plot(x, lats, pen=pg.mkPen(color=THEME["accent"], width=2),
                                symbol="o", symbolSize=10, symbolBrush=THEME["accent"],
                                name="Latency (ns)")
            self.cache_plot.getAxis("bottom").setTicks([list(enumerate(labels))])

        elif chart_type == "Scatter":
            scatter = pg.ScatterPlotItem(
                x=list(range(len(results))),
                y=lats,
                size=14,
                brush=pg.mkBrush(THEME["accent"]),
                pen=pg.mkPen(THEME["accent2"]),
            )
            self.cache_plot.addItem(scatter)
            self.cache_plot.getAxis("bottom").setTicks([list(enumerate(labels))])

        # Info text
        info = []
        info.append(f"{'Level':<20} {'Size':<10} {'Latency':<12} {'Cycles':<10} {'Conf':<8}")
        info.append("-" * 60)
        for r in results:
            info.append(
                f"{r.get('label', ''):<20} {fmt_size(r.get('size', 0)):<10} "
                f"{fmt_ns(r['latency_ns']):<12} {r['latency_cycles']:<10.1f} "
                f"{r.get('confidence', 0):.0%}"
            )
        self.cache_info.setText("\n".join(info))

    # ── TLB Charts ─────────────────────────────────────────────────

    def _populate_tlb(self, data: dict):
        self.tlb_plot.clear()
        results = data.get("tlb", [])
        if not results:
            self.tlb_info.setText("(no TLB data)")
            return

        labels = [r.get("label", f"TLB-{i}") for i, r in enumerate(results)]
        lats = [r["latency_ns"] for r in results]
        pages = [r.get("pages", 0) for r in results]

        # Bar chart
        bg = pg.BarGraphItem(
            x=list(range(len(results))),
            height=lats,
            width=0.6,
            brushes=THEME["colors"][:len(results)],
        )
        self.tlb_plot.addItem(bg)

        # Also show as scatter line
        self.tlb_plot.plot(list(range(len(results))), lats,
                          pen=pg.mkPen(color=THEME["cyan"], width=1.5, style=Qt.PenStyle.DashLine),
                          symbol="d", symbolSize=8, symbolBrush=THEME["cyan"],
                          name="Latency trend")

        self.tlb_plot.getAxis("bottom").setTicks([list(enumerate(pages))])
        self.tlb_plot.setLabel("bottom", "Pages (count)")

        info = []
        info.append(f"{'Level':<20} {'Pages':<8} {'Latency':<12} {'Cycles':<10} {'Conf':<8}")
        info.append("-" * 58)
        for r in results:
            info.append(
                f"{r.get('label', ''):<20} {r['pages']:<8} {fmt_ns(r['latency_ns']):<12} "
                f"{r['latency_cycles']:<10.1f} {r.get('confidence', 0):.0%}"
            )
        self.tlb_info.setText("\n".join(info))

    # ── Page Fault Charts ──────────────────────────────────────────

    def _populate_pagefault(self, data: dict):
        self.pf_plot.clear()
        results = data.get("pagefault", [])
        if not results:
            self.pf_info.setText("(no page fault data)")
            return

        # Group: minor faults vs shootdown
        minor = [r for r in results if "Minor" in r["label"]]
        shootdown = [r for r in results if "Shootdown" in r["label"] or "Ping-Pong" in r["label"]]

        idx = 0
        info_parts = []

        if minor:
            lats = [r["fault_overhead_ns"] for r in minor]
            labels = [fmt_size(r.get("total_bytes", 0)) for r in minor]
            bg = pg.BarGraphItem(
                x=list(range(idx, idx + len(minor))),
                height=lats,
                width=0.6,
                brushes=[THEME["accent"]] * len(minor),
                name="Minor Fault Overhead",
            )
            self.pf_plot.addItem(bg)
            info_parts.append("── Minor Page Faults ──")
            info_parts.append(f"{'Size':<15} {'Pages':<8} {'1st Touch':<12} {'2nd Touch':<12} {'Overhead':<12}")
            info_parts.append("-" * 59)
            for r in minor:
                info_parts.append(
                    f"{fmt_size(r['total_bytes']):<15} {r['pages']:<8} "
                    f"{fmt_ns(r['first_touch_ns']):<12} {fmt_ns(r['second_touch_ns']):<12} "
                    f"{fmt_ns(r['fault_overhead_ns']):<12}"
                )
            self.pf_plot.getAxis("bottom").setTicks([list(zip(range(idx, idx + len(minor)), labels))])
            idx += len(minor) + 1

        if shootdown:
            lats_sd = [r["fault_overhead_ns"] for r in shootdown]
            labels_sd = [fmt_size(r.get("total_bytes", 0)) for r in shootdown]
            bg2 = pg.BarGraphItem(
                x=list(range(idx, idx + len(shootdown))),
                height=lats_sd,
                width=0.6,
                brushes=[THEME["error"]] * len(shootdown),
                name="TLB Shootdown",
            )
            self.pf_plot.addItem(bg2)

            if not minor:
                self.pf_plot.getAxis("bottom").setTicks([list(zip(range(idx, idx + len(shootdown)), labels_sd))])

            info_parts.append("")
            info_parts.append("── TLB Shootdown ──")
            info_parts.append(f"{'Size':<15} {'Pages':<8} {'Ping-Pong':<12} {'Sequential':<12} {'Overhead':<12}")
            info_parts.append("-" * 59)
            for r in shootdown:
                info_parts.append(
                    f"{fmt_size(r['total_bytes']):<15} {r['pages']:<8} "
                    f"{fmt_ns(r['first_touch_ns']):<12} {fmt_ns(r['second_touch_ns']):<12} "
                    f"{fmt_ns(r['fault_overhead_ns']):<12}"
                )

        self.pf_info.setText("\n".join(info_parts))

    # ── Context Switch Charts ─────────────────────────────────────

    def _populate_ctxswitch(self, data: dict):
        self.ctx_plot.clear()
        results = data.get("ctxswitch", [])
        if not results:
            self.ctx_info.setText("(no context switch data)")
            return

        valid = [r for r in results if r.get("latency_ns", 0) > 0]
        if not valid:
            self.ctx_info.setText("(all context switch results pending)")
            return

        labels = [r.get("label", f"CS-{i}") for i, r in enumerate(valid)]
        lats = [r["latency_ns"] for r in valid]

        bg = pg.BarGraphItem(
            x=list(range(len(valid))),
            height=lats,
            width=0.6,
            brushes=THEME["colors"][:len(valid)],
        )
        self.ctx_plot.addItem(bg)

        # Horizontal reference lines
        if lats:
            min_lat = min(lats)
            max_lat = max(lats)
            median_line = pg.InfiniteLine(pos=sum(lats)/len(lats), angle=0,
                                          pen=pg.mkPen(THEME["cyan"], width=1, style=Qt.PenStyle.DashLine))
            self.ctx_plot.addItem(median_line)

        self.ctx_plot.getAxis("bottom").setTicks([list(enumerate(labels))])

        info = []
        info.append(f"{'Method':<30} {'Latency':<15} {'Cycles':<10} {'Conf':<8}")
        info.append("-" * 63)
        for r in valid:
            info.append(
                f"{r.get('method', r.get('label', '')):<30} {fmt_ns(r['latency_ns']):<15} "
                f"{r['latency_cycles']:<10.1f} {r.get('confidence', 0):.0%}"
            )
        self.ctx_info.setText("\n".join(info))

    # ── Report Tab ──────────────────────────────────────────────────

    def _populate_report(self, data: dict):
        text = self._generate_report_text(data)
        self.report_preview.setText(text)

    def _generate_report_text(self, data: dict) -> str:
        lines = []
        lines.append("=" * 72)
        lines.append("  TAU-PROFILER v2  —  SYSTEM ANALYSIS REPORT")
        lines.append("=" * 72)
        ts = datetime.fromtimestamp(data.get("timestamp", 0))
        lines.append(f"  Generated: {ts:%Y-%m-%d %H:%M:%S}")
        lines.append("")

        # Platform
        plat = data.get("platform", {})
        lines.append("── Platform ──────────────────────────────")
        lines.append(f"  OS:       {plat.get('os', '?')}")
        lines.append(f"  Arch:     {plat.get('arch', '?')}")
        lines.append(f"  CPU:      {plat.get('cpu_brand', '?')}")
        lines.append(f"  Cores:    {plat.get('physical_cores', '?')}P / {plat.get('logical_cores', '?')}L")
        lines.append("")

        # Calibration
        cal = data.get("calibration", {})
        if cal.get("calibrated"):
            lines.append(f"  TSC:      {cal['tsc_hz']/1_000_000:.2f} MHz")
            lines.append("")

        # Cache results
        cache = data.get("cache", [])
        if cache:
            lines.append("── Cache Hierarchy ───────────────────────")
            lines.append(f"  {'Level':<20} {'Size':<10} {'Latency':<12} {'Cycles':<10}")
            lines.append("  " + "-" * 52)
            for r in cache:
                lines.append(
                    f"  {r.get('label', ''):<20} {fmt_size(r.get('size', 0)):<10} "
                    f"{fmt_ns(r['latency_ns']):<12} {r['latency_cycles']:<10.1f}"
                )
            lines.append("")

        # TLB
        tlb = data.get("tlb", [])
        if tlb:
            lines.append("── TLB Hierarchy ─────────────────────────")
            for r in tlb:
                lines.append(
                    f"  {r.get('label', ''):<20} pages={r['pages']:<6} "
                    f"lat={fmt_ns(r['latency_ns']):<12} conf={r.get('confidence', 0):.0%}"
                )
            lines.append("")

        # Page Fault
        pf = data.get("pagefault", [])
        if pf:
            lines.append("── Page Fault Analysis ───────────────────")
            for r in pf:
                lines.append(
                    f"  {r.get('label', ''):<25} "
                    f"ovh={fmt_ns(r['fault_overhead_ns']):<12} ({fmt_size(r['total_bytes'])})"
                )
            lines.append("")

        # Context Switch
        cs = data.get("ctxswitch", [])
        if cs:
            lines.append("── Context Switch ────────────────────────")
            for r in cs:
                if r.get("latency_ns", 0) > 0:
                    lines.append(
                        f"  {r.get('method', r.get('label', '')):<25} "
                        f"lat={fmt_ns(r['latency_ns']):<12} conf={r.get('confidence', 0):.0%}"
                    )
            lines.append("")

        # Warnings
        warns = data.get("warnings", [])
        if warns:
            lines.append("── Warnings ──────────────────────────────")
            for w in warns:
                lines.append(f"  ⚠ {w}")

        lines.append("")
        lines.append("=" * 72)
        lines.append("  END OF REPORT")
        lines.append("=" * 72)
        return "\n".join(lines)

    # ── Export ─────────────────────────────────────────────────────

    def _export_report(self, fmt: str):
        if not self.data:
            QMessageBox.warning(self, "No Data", "Run a benchmark first.")
            return

        if fmt == "pdf":
            path, _ = QFileDialog.getSaveFileName(self, "Save PDF Report", "tau_report.pdf", "PDF (*.pdf)")
            if path:
                self._export_pdf(path)
        elif fmt == "html":
            path, _ = QFileDialog.getSaveFileName(self, "Save HTML Report", "tau_report.html", "HTML (*.html)")
            if path:
                self._export_html(path)

    def _export_pdf(self, path: str):
        """Generate a professional PDF report using ReportLab."""
        from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
        from reportlab.lib.styles import ParagraphStyle
        from reportlab.lib.enums import TA_LEFT, TA_CENTER
        from reportlab.lib.units import mm

        data = self.data
        plat = data.get("platform", {})
        cal = data.get("calibration", {})
        ts = datetime.fromtimestamp(data.get("timestamp", 0))

        doc = SimpleDocTemplate(
            path, pagesize=A4,
            leftMargin=20*mm, rightMargin=20*mm,
            topMargin=20*mm, bottomMargin=20*mm,
        )

        styles = getSampleStyleSheet()
        title_style = ParagraphStyle(
            "TauTitle", parent=styles["Title"],
            textColor=colors.Color(0, 0.8, 0),
            fontSize=22, fontName="Courier-Bold",
            spaceAfter=6,
        )
        h1_style = ParagraphStyle(
            "H1", parent=styles["Heading1"],
            textColor=colors.Color(0, 0.8, 0),
            fontSize=14, fontName="Courier-Bold",
            spaceBefore=12, spaceAfter=6,
        )
        body_style = ParagraphStyle(
            "Body", parent=styles["Normal"],
            textColor=colors.Color(0.7, 0.9, 0.7),
            fontSize=9, fontName="Courier",
            spaceBefore=2, spaceAfter=2,
        )
        header_style = ParagraphStyle(
            "Header", parent=body_style,
            textColor=colors.Color(0, 1, 0),
            fontSize=10, fontName="Courier-Bold",
        )

        elements = []

        # Title
        elements.append(Paragraph("TAU-PROFILER v2", title_style))
        elements.append(Paragraph(f"SYSTEM ANALYSIS REPORT — {ts:%Y-%m-%d %H:%M:%S}", header_style))
        elements.append(Spacer(1, 6*mm))

        # Platform table
        platform_data = [
            ["OS", plat.get('os', '?')],
            ["Architecture", plat.get('arch', '?')],
            ["CPU", plat.get('cpu_brand', '?')],
            ["Cores", f"{plat.get('physical_cores', '?')}P / {plat.get('logical_cores', '?')}L"],
            ["Page Size", fmt_size(plat.get('page_size', 4096))],
            ["Virtualized", f"{plat.get('is_virtualized', '?')}"],
        ]
        if cal.get("calibrated"):
            platform_data.append(["TSC Frequency", f"{cal['tsc_hz']/1_000_000:.2f} MHz"])
        t = Table(platform_data, colWidths=[100, 300])
        t.setStyle(TableStyle([
            ("TEXTCOLOR", (0, 0), (-1, -1), colors.Color(0.7, 0.9, 0.7)),
            ("FONTNAME", (0, 0), (-1, -1), "Courier"),
            ("FONTSIZE", (0, 0), (-1, -1), 9),
            ("ALIGN", (0, 0), (0, -1), "RIGHT"),
            ("ALIGN", (1, 0), (1, -1), "LEFT"),
            ("TOPPADDING", (0, 0), (-1, -1), 2),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
            ("LINEBELOW", (0, 0), (-1, -1), 0.5, colors.Color(0, 0.3, 0)),
            ("LINEBELOW", (0, -1), (-1, -1), 1, colors.Color(0, 0.6, 0)),
        ]))
        elements.append(Paragraph("── PLATFORM ──", h1_style))
        elements.append(t)
        elements.append(Spacer(1, 4*mm))

        # Cache
        cache = data.get("cache", [])
        if cache:
            elements.append(Paragraph("── CACHE HIERARCHY ──", h1_style))
            cache_data = [["Level", "Size", "Latency (ns)", "Cycles", "Confidence"]]
            for r in cache:
                cache_data.append([
                    r.get('label', ''),
                    fmt_size(r.get('size', 0)),
                    f"{r['latency_ns']:.2f}",
                    f"{r['latency_cycles']:.1f}",
                    f"{r.get('confidence', 0):.0%}",
                ])
            t = Table(cache_data, colWidths=[120, 70, 90, 70, 70])
            t.setStyle(TableStyle([
                ("TEXTCOLOR", (0, 0), (-1, -1), colors.Color(0.7, 0.9, 0.7)),
                ("FONTNAME", (0, 0), (-1, -1), "Courier"),
                ("FONTSIZE", (0, 0), (-1, -1), 8),
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("BACKGROUND", (0, 0), (-1, 0), colors.Color(0, 0.2, 0)),
                ("LINEBELOW", (0, 0), (-1, 0), 1, colors.Color(0, 0.6, 0)),
                ("LINEBELOW", (0, 1), (-1, -1), 0.3, colors.Color(0, 0.2, 0)),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                ("GRID", (0, 0), (-1, -1), 0.3, colors.Color(0, 0.3, 0)),
            ]))
            elements.append(t)
            elements.append(Spacer(1, 4*mm))

        # TLB
        tlb = data.get("tlb", [])
        if tlb:
            elements.append(Paragraph("── TLB HIERARCHY ──", h1_style))
            tlb_data = [["Level", "Pages", "Latency (ns)", "Cycles", "Conf."]]
            for r in tlb:
                tlb_data.append([
                    r.get('label', ''),
                    str(r['pages']),
                    f"{r['latency_ns']:.2f}",
                    f"{r['latency_cycles']:.1f}",
                    f"{r.get('confidence', 0):.0%}",
                ])
            t = Table(tlb_data, colWidths=[120, 70, 90, 70, 60])
            t.setStyle(TableStyle([
                ("TEXTCOLOR", (0, 0), (-1, -1), colors.Color(0.7, 0.9, 0.7)),
                ("FONTNAME", (0, 0), (-1, -1), "Courier"),
                ("FONTSIZE", (0, 0), (-1, -1), 8),
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("BACKGROUND", (0, 0), (-1, 0), colors.Color(0, 0.2, 0)),
                ("LINEBELOW", (0, 0), (-1, 0), 1, colors.Color(0, 0.6, 0)),
                ("GRID", (0, 0), (-1, -1), 0.3, colors.Color(0, 0.3, 0)),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]))
            elements.append(t)
            elements.append(Spacer(1, 4*mm))

        # Page Fault
        pf = data.get("pagefault", [])
        if pf:
            elements.append(Paragraph("── PAGE FAULT ANALYSIS ──", h1_style))
            pf_data = [["Benchmark", "Pages", "1st Touch", "2nd Touch", "Overhead"]]
            for r in pf:
                pf_data.append([
                    r.get('label', ''),
                    str(r['pages']),
                    f"{r['first_touch_ns']:.2f}",
                    f"{r['second_touch_ns']:.2f}",
                    f"{r['fault_overhead_ns']:.2f}",
                ])
            t = Table(pf_data, colWidths=[100, 60, 90, 90, 90])
            t.setStyle(TableStyle([
                ("TEXTCOLOR", (0, 0), (-1, -1), colors.Color(0.7, 0.9, 0.7)),
                ("FONTNAME", (0, 0), (-1, -1), "Courier"),
                ("FONTSIZE", (0, 0), (-1, -1), 8),
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("BACKGROUND", (0, 0), (-1, 0), colors.Color(0, 0.2, 0)),
                ("LINEBELOW", (0, 0), (-1, 0), 1, colors.Color(0, 0.6, 0)),
                ("GRID", (0, 0), (-1, -1), 0.3, colors.Color(0, 0.3, 0)),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]))
            elements.append(t)
            elements.append(Spacer(1, 4*mm))

        # Context Switch
        cs = data.get("ctxswitch", [])
        if cs:
            valid_cs = [r for r in cs if r.get("latency_ns", 0) > 0]
            if valid_cs:
                elements.append(Paragraph("── CONTEXT SWITCH ──", h1_style))
                cs_data = [["Method", "Latency (ns)", "Cycles", "Conf."]]
                for r in valid_cs:
                    cs_data.append([
                        r.get('method', r.get('label', '')),
                        f"{r['latency_ns']:.2f}",
                        f"{r['latency_cycles']:.1f}",
                        f"{r.get('confidence', 0):.0%}",
                    ])
                t = Table(cs_data, colWidths=[180, 90, 70, 60])
                t.setStyle(TableStyle([
                    ("TEXTCOLOR", (0, 0), (-1, -1), colors.Color(0.7, 0.9, 0.7)),
                    ("FONTNAME", (0, 0), (-1, -1), "Courier"),
                    ("FONTSIZE", (0, 0), (-1, -1), 8),
                    ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                    ("BACKGROUND", (0, 0), (-1, 0), colors.Color(0, 0.2, 0)),
                    ("LINEBELOW", (0, 0), (-1, 0), 1, colors.Color(0, 0.6, 0)),
                    ("GRID", (0, 0), (-1, -1), 0.3, colors.Color(0, 0.3, 0)),
                    ("TOPPADDING", (0, 0), (-1, -1), 3),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                ]))
                elements.append(t)
                elements.append(Spacer(1, 4*mm))

        # Tau constants
        tau = self._compute_tau(data)
        if tau:
            elements.append(Paragraph("── τ CONSTANTS ──", h1_style))
            tau_data = [["Tier", "Latency"]]
            for k, v in tau.items():
                if v:
                    tau_data.append([k, fmt_ns(v)])
            cs_valid = [r for r in data.get("ctxswitch", []) if r.get("latency_ns", 0) > 0]
            if cs_valid:
                avg_cs = sum(r["latency_ns"] for r in cs_valid) / len(cs_valid)
                tau_data.append(["τ_CTX_SWITCH", fmt_ns(avg_cs)])
            t = Table(tau_data, colWidths=[120, 150])
            t.setStyle(TableStyle([
                ("TEXTCOLOR", (0, 0), (-1, -1), colors.Color(0.7, 0.9, 0.7)),
                ("FONTNAME", (0, 0), (-1, -1), "Courier"),
                ("FONTSIZE", (0, 0), (-1, -1), 9),
                ("BACKGROUND", (0, 0), (-1, 0), colors.Color(0, 0.2, 0)),
                ("LINEBELOW", (0, 0), (-1, 0), 1, colors.Color(0, 0.6, 0)),
                ("LINEBELOW", (0, 1), (-1, -1), 0.3, colors.Color(0, 0.2, 0)),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]))
            elements.append(t)

        # Warnings
        warns = data.get("warnings", [])
        if warns:
            elements.append(Spacer(1, 4*mm))
            elements.append(Paragraph("── WARNINGS ──", h1_style))
            for w in warns:
                elements.append(Paragraph(f"⚠ {w}", body_style))

        # Footer
        elements.append(Spacer(1, 10*mm))
        elements.append(Paragraph("─" * 60, body_style))
        elements.append(Paragraph("Generated by Tau-Profiler v2 — github.com/vamfish/tau-profiler", body_style))

        doc.build(elements)
        self.lbl_status.setText(f"✅ PDF exported: {path}")
        QMessageBox.information(self, "Export Complete", f"PDF report saved to:\n{path}")

    def _export_html(self, path: str):
        """Generate a geeky HTML report."""
        data = self.data
        plat = data.get("platform", {})
        cal = data.get("calibration", {})
        ts = datetime.fromtimestamp(data.get("timestamp", 0))

        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Tau-Profiler Report — {ts:%Y-%m-%d}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;700&display=swap');
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    background: #0a0a0a;
    color: #b0ffb0;
    font-family: 'JetBrains Mono', 'Courier New', monospace;
    padding: 40px;
    line-height: 1.6;
  }}
  h1 {{ color: #00ff41; font-size: 28px; letter-spacing: 4px; border-bottom: 1px solid #00ff41; padding-bottom: 8px; }}
  h2 {{ color: #00ff41; font-size: 18px; margin-top: 30px; border-left: 3px solid #00ff41; padding-left: 10px; }}
  table {{ border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 13px; }}
  th {{ background: #002200; color: #00ff41; text-align: left; padding: 6px 10px; font-weight: bold; border: 1px solid #1a3a1a; }}
  td {{ padding: 4px 10px; border: 1px solid #1a3a1a; }}
  tr:nth-child(even) {{ background: #0d0d0d; }}
  tr:hover {{ background: #112211; }}
  .dim {{ color: #508050; }}
  .accent {{ color: #00ff41; }}
  .warn {{ color: #ffaa00; }}
  .error {{ color: #ff3355; }}
  .section {{ margin: 24px 0; }}
  hr {{ border: none; border-top: 1px solid #1a3a1a; margin: 20px 0; }}
  .footer {{ margin-top: 40px; padding-top: 16px; border-top: 1px solid #1a3a1a; color: #508050; font-size: 12px; }}
  .blink {{ animation: blink 1s step-end infinite; }}
  @keyframes blink {{ 50% {{ opacity: 0; }} }}
</style>
</head>
<body>
<h1>⫸ TAU-PROFILER v2  ⫷</h1>
<p class="dim blink">▌ SYSTEM ANALYSIS REPORT — {ts:%Y-%m-%d %H:%M:%S}</p>
<hr>
"""
        # Platform
        html += '<div class="section">\n<h2>🖥  Platform</h2>\n<table>\n'
        for key, val in [("OS", plat.get('os', '?')),
                         ("Arch", plat.get('arch', '?')),
                         ("CPU", plat.get('cpu_brand', '?')),
                         ("Cores", f"{plat.get('physical_cores', '?')}P / {plat.get('logical_cores', '?')}L"),
                         ("Page Size", fmt_size(plat.get('page_size', 4096))),
                         ("Virtualized", f"{plat.get('is_virtualized', '?')}")]:
            html += f'<tr><td class="dim">{key}</td><td>{val}</td></tr>\n'
        if cal.get("calibrated"):
            html += f'<tr><td class="dim">TSC Frequency</td><td>{cal["tsc_hz"]/1_000_000:.2f} MHz</td></tr>\n'
        html += '</table>\n</div>\n'

        # Cache
        cache = data.get("cache", [])
        if cache:
            html += '<div class="section">\n<h2>📊  Cache Hierarchy</h2>\n<table>\n<tr><th>Level</th><th>Size</th><th>Latency (ns)</th><th>Cycles</th><th>Confidence</th></tr>\n'
            for r in cache:
                html += f'<tr><td>{r.get("label","")}</td><td>{fmt_size(r.get("size",0))}</td><td>{r["latency_ns"]:.2f}</td><td>{r["latency_cycles"]:.1f}</td><td>{r.get("confidence",0):.0%}</td></tr>\n'
            html += '</table>\n</div>\n'

        # TLB
        tlb = data.get("tlb", [])
        if tlb:
            html += '<div class="section">\n<h2>📖  TLB Hierarchy</h2>\n<table>\n<tr><th>Level</th><th>Pages</th><th>Latency (ns)</th><th>Cycles</th><th>Confidence</th></tr>\n'
            for r in tlb:
                html += f'<tr><td>{r.get("label","")}</td><td>{r["pages"]}</td><td>{r["latency_ns"]:.2f}</td><td>{r["latency_cycles"]:.1f}</td><td>{r.get("confidence",0):.0%}</td></tr>\n'
            html += '</table>\n</div>\n'

        # Page Fault
        pf = data.get("pagefault", [])
        if pf:
            html += '<div class="section">\n<h2>📄  Page Fault Analysis</h2>\n<table>\n<tr><th>Benchmark</th><th>Pages</th><th>1st Touch (ns)</th><th>2nd Touch (ns)</th><th>Overhead (ns)</th></tr>\n'
            for r in pf:
                html += f'<tr><td>{r.get("label","")}</td><td>{r["pages"]}</td><td>{r["first_touch_ns"]:.2f}</td><td>{r["second_touch_ns"]:.2f}</td><td>{r["fault_overhead_ns"]:.2f}</td></tr>\n'
            html += '</table>\n</div>\n'

        # Context Switch
        cs = data.get("ctxswitch", [])
        valid_cs = [r for r in cs if r.get("latency_ns", 0) > 0]
        if valid_cs:
            html += '<div class="section">\n<h2>🔄  Context Switch</h2>\n<table>\n<tr><th>Method</th><th>Latency (ns)</th><th>Cycles</th><th>Confidence</th></tr>\n'
            for r in valid_cs:
                html += f'<tr><td>{r.get("method", r.get("label",""))}</td><td class="accent">{r["latency_ns"]:.2f}</td><td>{r["latency_cycles"]:.1f}</td><td>{r.get("confidence",0):.0%}</td></tr>\n'
            html += '</table>\n</div>\n'

        # Tau
        tau = self._compute_tau(data)
        if tau:
            html += '<div class="section">\n<h2>📈  τ Constants</h2>\n<table>\n<tr><th>Tier</th><th>Latency</th></tr>\n'
            for k, v in tau.items():
                if v:
                    html += f'<tr><td class="dim">{k}</td><td class="accent">{fmt_ns(v)}</td></tr>\n'
            if valid_cs:
                avg_cs = sum(r["latency_ns"] for r in valid_cs) / len(valid_cs)
                html += f'<tr><td class="dim">τ_CTX_SWITCH</td><td class="accent">{fmt_ns(avg_cs)}</td></tr>\n'
            html += '</table>\n</div>\n'

        # Warnings
        warns = data.get("warnings", [])
        if warns:
            html += '<div class="section">\n<h2>⚠  Warnings</h2>\n'
            for w in warns:
                html += f'<p class="warn">⚠ {w}</p>\n'
            html += '</div>\n'

        html += """
<hr>
<div class="footer">
  <p>Generated by Tau-Profiler v2  |  <span class="dim">github.com/vamfish/tau-profiler</span></p>
</div>
</body>
</html>
"""
        with open(path, "w", encoding="utf-8") as f:
            f.write(html)

        self.lbl_status.setText(f"✅ HTML exported: {path}")
        QMessageBox.information(self, "Export Complete", f"HTML report saved to:\n{path}")

    # ── Save Chart Image ───────────────────────────────────────────

    def _save_current_chart(self):
        if not self.data:
            QMessageBox.warning(self, "No Data", "Run a benchmark first.")
            return

        path, _ = QFileDialog.getSaveFileName(self, "Save Chart Image", "tau_chart.png", "PNG (*.png)")
        if not path:
            return

        # Get the current visible plot
        current_tab = self.tabs.currentWidget()
        plot_widget = None
        for name in ["cache_plot", "tlb_plot", "pf_plot", "ctx_plot"]:
            w = getattr(self, name, None)
            if w and self._is_widget_visible(w):
                plot_widget = w
                break

        if plot_widget is None:
            # Default to cache plot
            plot_widget = self.cache_plot

        # Export
        exporter = pg.exporters.ImageExporter(plot_widget.plotItem)
        exporter.export(path)
        self.lbl_status.setText(f"✅ Chart saved: {path}")

    def _is_widget_visible(self, widget) -> bool:
        """Check if a widget is currently visible in the active tab."""
        if not widget:
            return False
        p = widget.parent()
        while p:
            if isinstance(p, QTabWidget):
                return p.currentWidget() and self._is_descendant(p.currentWidget(), widget)
            p = p.parent()
        return False

    def _is_descendant(self, parent, child) -> bool:
        while child:
            if child is parent:
                return True
            child = child.parent()
        return False


# ─────────────────────────────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────────────────────────────

def main():
    # Allow running without display (for headless export)
    if "TAU_HEADLESS" in os.environ:
        engine = find_engine()
        if not engine:
            print("Engine not found.")
            sys.exit(1)
        data = run_engine(engine)
        print(json.dumps(data, indent=2))
        sys.exit(0)

    app = QApplication(sys.argv)
    app.setStyle("Fusion")

    # Dark palette
    palette = QPalette()
    palette.setColor(QPalette.ColorRole.Window, QColor(THEME["bg"]))
    palette.setColor(QPalette.ColorRole.WindowText, QColor(THEME["text"]))
    palette.setColor(QPalette.ColorRole.Base, QColor(THEME["bg2"]))
    palette.setColor(QPalette.ColorRole.Text, QColor(THEME["text"]))
    app.setPalette(palette)

    # Monospace font as default
    font = QFont("Fira Code", 11)
    if QFontInfo(font).family() != "Fira Code":
        font = QFont("Courier New", 11)
    app.setFont(font)

    win = TauProfilerGUI()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
