"""与 macOS 信息架构一致的 Windows PySide6 设置窗口。"""

from __future__ import annotations

import os
import subprocess
import sys
import webbrowser

from PySide6.QtCore import QObject, QSize, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QFont
from PySide6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QCheckBox,
    QComboBox,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSlider,
    QStackedWidget,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from . import __version__, audio_output, config, key_mapping, raw_input_windows

VB_CABLE_URL = "https://vb-audio.com/Cable/"
PROJECT_URL = "https://github.com/HD838A/remote-mic-app"


def _bridge_command() -> list[str]:
    if getattr(sys, "frozen", False):
        return [sys.executable, "--bridge"]
    return [sys.executable, "-m", "ovb_rc003", "--bridge"]


def _start_bridge() -> None:
    creationflags = (
        getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        if sys.platform == "win32"
        else 0
    )
    subprocess.Popen(
        _bridge_command(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=(sys.platform != "win32"),
        creationflags=creationflags,
    )


class _RawInputSignal(QObject):
    edge = Signal(str, bool)


class SettingsWindow(QMainWindow):
    PAGE_TITLES = ("连接", "按键", "权限", "关于")

    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Remote Mic · RC003（Windows）")
        self.resize(1040, 720)
        self.setMinimumSize(900, 620)
        self._current = config.load_config()
        self._endpoints: list[audio_output.AudioEndpoint] = []
        self._mapping_combos: dict[tuple[str, str], QComboBox] = {}
        self._remote_buttons: dict[str, QPushButton] = {}
        self._preview_listener: raw_input_windows.RawInputListener | None = None
        self._raw_signal = _RawInputSignal()
        self._raw_signal.edge.connect(self._on_raw_edge)

        root = QWidget()
        root_layout = QHBoxLayout(root)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        self._sidebar = QListWidget()
        self._sidebar.setObjectName("sidebar")
        self._sidebar.setFixedWidth(132)
        self._sidebar.setSpacing(5)
        self._sidebar.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self._sidebar.setSelectionMode(QAbstractItemView.SingleSelection)
        for index, title in enumerate(self.PAGE_TITLES):
            item = QListWidgetItem(("↔", "⌨", "◆", "ⓘ")[index] + f"\n{title}")
            item.setTextAlignment(Qt.AlignCenter)
            item.setSizeHint(QSize(110, 72))
            item.setData(Qt.UserRole, index)
            self._sidebar.addItem(item)
        self._sidebar.currentRowChanged.connect(self._select_page)

        self._pages = QStackedWidget()
        self._pages.addWidget(self._build_connection_page())
        self._pages.addWidget(self._build_mapping_page())
        self._pages.addWidget(self._build_permissions_page())
        self._pages.addWidget(self._build_about_page())

        root_layout.addWidget(self._sidebar)
        root_layout.addWidget(self._pages, 1)
        self.setCentralWidget(root)
        self._apply_style()
        self._sidebar.setCurrentRow(0)
        self._refresh_endpoints()
        self._start_button_preview()

    def _apply_style(self) -> None:
        self.setStyleSheet(
            """
            QMainWindow, QStackedWidget, QScrollArea { background: #f4f5f7; color: #202124; font-family: 'Segoe UI'; font-size: 14px; }
            QLabel, QCheckBox { background: transparent; }
            QListWidget#sidebar { background: #e9ebef; border: none; padding: 12px 8px; outline: none; }
            QListWidget#sidebar::item { border-radius: 12px; padding: 12px 4px; margin: 2px; color: #4b4f56; }
            QListWidget#sidebar::item:selected { background: #ffffff; color: #1264d8; font-weight: 600; }
            QFrame#card { background: #ffffff; border: 1px solid #dfe2e7; border-radius: 14px; }
            QLabel#pageTitle { font-size: 24px; font-weight: 700; color: #17191c; }
            QLabel#pageSubtitle, QLabel#secondary { color: #69707a; }
            QLabel#sectionTitle { font-size: 16px; font-weight: 650; }
            QPushButton { min-height: 32px; padding: 0 13px; border-radius: 8px; border: 1px solid #cfd4dc; background: #ffffff; }
            QPushButton:hover { background: #f0f5ff; border-color: #8bb7f3; }
            QPushButton#primary { background: #1769d2; color: white; border-color: #1769d2; font-weight: 600; }
            QPushButton#remoteKey { min-width: 54px; min-height: 36px; background: #f6f7f9; }
            QPushButton#remoteKey:checked { background: #dceaff; border: 2px solid #2878dc; color: #1557a5; font-weight: 700; }
            QPushButton#micKey { min-height: 42px; background: #fff0f0; border-color: #ef9a9a; color: #b42318; font-weight: 700; }
            QPushButton#micKey:checked { background: #ffd8d8; border: 2px solid #d92d20; }
            QComboBox { min-height: 32px; padding: 0 8px; border: 1px solid #cfd4dc; border-radius: 7px; background: white; }
            QTableWidget { background: white; border: 1px solid #dfe2e7; border-radius: 10px; gridline-color: #eceef1; }
            QHeaderView::section { background: #f2f4f7; border: none; border-bottom: 1px solid #dfe2e7; padding: 8px; font-weight: 600; }
            QCheckBox { spacing: 8px; font-weight: 600; }
            """
        )

    def _page(self, title: str, subtitle: str) -> tuple[QScrollArea, QVBoxLayout]:
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(26, 22, 26, 26)
        layout.setSpacing(16)
        title_label = QLabel(title)
        title_label.setObjectName("pageTitle")
        subtitle_label = QLabel(subtitle)
        subtitle_label.setObjectName("pageSubtitle")
        subtitle_label.setWordWrap(True)
        layout.addWidget(title_label)
        layout.addWidget(subtitle_label)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setWidget(content)
        return scroll, layout

    @staticmethod
    def _card() -> tuple[QFrame, QVBoxLayout]:
        card = QFrame()
        card.setObjectName("card")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(18, 17, 18, 17)
        layout.setSpacing(12)
        return card, layout

    @staticmethod
    def _section_title(text: str) -> QLabel:
        label = QLabel(text)
        label.setObjectName("sectionTitle")
        return label

    @staticmethod
    def _secondary(text: str) -> QLabel:
        label = QLabel(text)
        label.setObjectName("secondary")
        label.setWordWrap(True)
        return label

    def _build_connection_page(self) -> QWidget:
        page, layout = self._page(
            "连接与语音", "连接 RC003，并配置语音输出设备与数字增益"
        )
        columns = QHBoxLayout()
        columns.setSpacing(15)

        device_card, device_layout = self._card()
        device_card.setFixedWidth(235)
        device_layout.addWidget(
            self._section_title("RC003 语音遥控器"), alignment=Qt.AlignHCenter
        )
        remote = QLabel("●\n\n  ↑\n←  OK  →\n  ↓\n\n返回   主页\n\n音量 +\n音量 −\n\n🎙")
        remote.setAlignment(Qt.AlignCenter)
        remote.setFont(QFont("Segoe UI", 13))
        remote.setStyleSheet(
            "background:#202124;color:white;border-radius:28px;padding:18px;"
        )
        device_layout.addWidget(remote, 1)
        device_layout.addWidget(
            self._secondary(
                "蓝牙：由 Windows 设置完成配对\n语音：等待麦克风键\n按键：标准 Raw Input"
            )
        )
        reconnect = QPushButton("保存并启动桥接")
        reconnect.setObjectName("primary")
        reconnect.clicked.connect(self._save_and_start)
        device_layout.addWidget(reconnect)

        audio_card, audio_layout = self._card()
        audio_layout.addWidget(self._section_title("音频设置"))
        audio_layout.addWidget(QLabel("语音输出设备"))
        self._endpoint_combo = QComboBox()
        audio_layout.addWidget(self._endpoint_combo)

        gain_row = QHBoxLayout()
        gain_row.addWidget(QLabel("数字增益"))
        self._gain_slider = QSlider(Qt.Horizontal)
        self._gain_slider.setRange(-24, 24)
        self._gain_slider.setValue(round(float(self._current["gain_db"])))
        self._gain_value = QLabel(f"{self._gain_slider.value()} dB")
        self._gain_value.setMinimumWidth(52)
        self._gain_slider.valueChanged.connect(
            lambda value: self._gain_value.setText(f"{value} dB")
        )
        gain_row.addWidget(self._gain_slider, 1)
        gain_row.addWidget(self._gain_value)
        audio_layout.addLayout(gain_row)
        audio_layout.addWidget(
            self._secondary(
                "0 dB 保持原始音量；建议从 6–12 dB 开始。数值越高，也会放大环境噪声。"
            )
        )

        self._audio_status = QLabel("尚未枚举音频设备")
        self._audio_status.setObjectName("secondary")
        audio_layout.addWidget(self._audio_status)
        button_row = QHBoxLayout()
        refresh = QPushButton("刷新音频设备")
        refresh.clicked.connect(self._refresh_endpoints)
        cable = QPushButton("获取 VB-CABLE")
        cable.clicked.connect(lambda: webbrowser.open(VB_CABLE_URL))
        logs = QPushButton("打开日志")
        logs.clicked.connect(self._open_logs)
        save = QPushButton("保存")
        save.setObjectName("primary")
        save.clicked.connect(lambda: self._save_all())
        for button in (refresh, cable, logs):
            button_row.addWidget(button)
        button_row.addStretch(1)
        button_row.addWidget(save)
        audio_layout.addLayout(button_row)
        audio_layout.addWidget(
            self._secondary(
                "应用只把 RC003 语音写入所选播放端点，不会修改 Windows 默认输入或输出。若要作为系统麦克风，请自行安装 VB-CABLE，并在此选择 CABLE Input。"
            )
        )

        columns.addWidget(device_card)
        columns.addWidget(audio_card, 1)
        layout.addLayout(columns)
        layout.addStretch(1)
        return page

    def _build_mapping_page(self) -> QWidget:
        page, layout = self._page(
            "按键映射", "自定义 RC003 按键功能，并保留麦克风键的固定核心行为"
        )
        control_card, control_layout = self._card()
        control_row = QHBoxLayout()
        self._mapping_enabled = QCheckBox("启用 RC003 自定义按键映射")
        self._mapping_enabled.setChecked(bool(self._current["custom_mapping_enabled"]))
        self._mapping_enabled.stateChanged.connect(self._save_mapping_silently)
        reset = QPushButton("恢复默认")
        reset.clicked.connect(self._reset_mappings)
        control_row.addWidget(self._mapping_enabled)
        control_row.addStretch(1)
        control_row.addWidget(reset)
        control_layout.addLayout(control_row)
        self._mapping_status = self._secondary(
            "等待检测 RC003 实体按键；映射修改后自动保存。"
        )
        control_layout.addWidget(self._mapping_status)
        layout.addWidget(control_card)

        body = QHBoxLayout()
        body.setSpacing(15)
        remote_card, remote_layout = self._card()
        remote_card.setFixedWidth(245)
        remote_layout.addWidget(self._section_title("实体遥控器"))
        remote_layout.addWidget(
            self._secondary("点击示意键，或直接按下真实遥控器按键定位。")
        )
        remote_grid = QGridLayout()
        remote_grid.setSpacing(7)
        positions = {
            "power": (0, 0, 1, 3),
            "up": (1, 1, 1, 1),
            "left": (2, 0, 1, 1),
            "ok": (2, 1, 1, 1),
            "right": (2, 2, 1, 1),
            "down": (3, 1, 1, 1),
            "back": (4, 0, 1, 1),
            "home": (4, 1, 1, 1),
            "menu": (4, 2, 1, 1),
            "tv": (5, 0, 1, 3),
            "volume_up": (6, 0, 1, 3),
            "volume_down": (7, 0, 1, 3),
            "mic": (8, 0, 1, 3),
        }
        for button in key_mapping.REMOTE_BUTTONS:
            widget = QPushButton(button.display_name)
            widget.setCheckable(True)
            widget.setObjectName("micKey" if button.button_id == "mic" else "remoteKey")
            widget.clicked.connect(
                lambda _checked=False, value=button.button_id: self._select_button(
                    value
                )
            )
            self._remote_buttons[button.button_id] = widget
            remote_grid.addWidget(widget, *positions[button.button_id])
        remote_layout.addLayout(remote_grid)
        remote_layout.addStretch(1)
        body.addWidget(remote_card)

        mapping_card, mapping_layout = self._card()
        mapping_layout.addWidget(self._section_title("按键动作"))
        mapping_layout.addWidget(
            self._secondary(
                "单击、双击和长按可以分别配置；输入例如 Ctrl+Shift+P 可创建自定义快捷键。"
            )
        )
        self._mapping_table = QTableWidget(len(key_mapping.REMOTE_BUTTONS), 4)
        self._mapping_table.setHorizontalHeaderLabels(("按键", "单击", "双击", "长按"))
        self._mapping_table.verticalHeader().setVisible(False)
        self._mapping_table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self._mapping_table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self._mapping_table.horizontalHeader().setSectionResizeMode(
            0, QHeaderView.ResizeToContents
        )
        for column in range(1, 4):
            self._mapping_table.horizontalHeader().setSectionResizeMode(
                column, QHeaderView.Stretch
            )
        self._mapping_table.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self._mapping_table.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self._mapping_table.setMinimumHeight(525)
        bindings = self._current["button_bindings"]
        for row, button in enumerate(key_mapping.REMOTE_BUTTONS):
            item = QTableWidgetItem(button.display_name)
            item.setData(Qt.UserRole, button.button_id)
            self._mapping_table.setItem(row, 0, item)
            for column, trigger in enumerate(key_mapping.TRIGGERS, start=1):
                combo = QComboBox()
                combo.setEditable(button.button_id != "mic")
                combo.addItems(
                    [
                        label
                        for action, label in key_mapping.ACTION_LABELS.items()
                        if button.button_id == "mic" or action != "voice"
                    ]
                )
                action = bindings[button.button_id][trigger]
                combo.setCurrentText(key_mapping.action_to_display(action))
                if button.button_id == "mic":
                    combo.setEnabled(False)
                else:
                    combo.activated.connect(self._save_mapping_silently)
                    if combo.lineEdit() is not None:
                        combo.lineEdit().editingFinished.connect(
                            self._save_mapping_silently
                        )
                self._mapping_combos[(button.button_id, trigger)] = combo
                self._mapping_table.setCellWidget(row, column, combo)
        self._mapping_table.cellClicked.connect(
            lambda row, _column: self._select_button(
                key_mapping.REMOTE_BUTTONS[row].button_id
            )
        )
        mapping_layout.addWidget(self._mapping_table, 1)
        mapping_layout.addWidget(
            self._secondary(
                "标准 Raw Input 不需要管理员权限，但受 Windows HID 暴露方式和 UIPI 限制；系统已消费的按键可能无法完整识别或拦截。"
            )
        )
        body.addWidget(mapping_card, 1)
        layout.addLayout(body, 1)
        self._select_button("ok")
        return page

    def _build_permissions_page(self) -> QWidget:
        page, layout = self._page(
            "权限与说明", "Windows 版使用普通用户权限，不安装或注入系统组件"
        )
        items = (
            (
                "蓝牙与 RC003 配对",
                "在 Windows 设置中完成配对；Remote Mic 使用 WinRT BLE/GATT 读取 ATVV 语音。",
                "打开蓝牙设置",
                "ms-settings:bluetooth",
            ),
            (
                "麦克风隐私",
                "Remote Mic 自身写入播放端点；最终读取 CABLE Output 的输入法或语音应用仍受麦克风隐私设置影响。",
                "打开麦克风设置",
                "ms-settings:privacy-microphone",
            ),
            (
                "语音识别",
                "如果目标功能使用 Windows 听写或在线语音识别，请确认系统语音设置已启用。",
                "打开语音设置",
                "ms-settings:speech",
            ),
        )
        for title, detail, button_text, uri in items:
            card, card_layout = self._card()
            row = QHBoxLayout()
            copy = QVBoxLayout()
            copy.addWidget(self._section_title(title))
            copy.addWidget(self._secondary(detail))
            button = QPushButton(button_text)
            button.clicked.connect(
                lambda _checked=False, value=uri: QDesktopServices.openUrl(QUrl(value))
            )
            row.addLayout(copy, 1)
            row.addWidget(button)
            card_layout.addLayout(row)
            layout.addWidget(card)
        note_card, note_layout = self._card()
        note_layout.addWidget(self._section_title("按键映射权限边界"))
        note_layout.addWidget(
            self._secondary(
                "Raw Input 和 SendInput 在普通权限下运行，不触发 UAC。普通权限应用不能向以管理员身份运行的目标应用注入按键（UIPI）；标准方案也不能保证捕获或屏蔽 RC003 的全部隐藏 HID 报告。当前版本不使用 Frida、WUDFHost 注入或内核驱动。"
            )
        )
        logs = QPushButton("打开日志目录")
        logs.clicked.connect(self._open_logs)
        note_layout.addWidget(logs, alignment=Qt.AlignLeft)
        layout.addWidget(note_card)
        layout.addStretch(1)
        return page

    def _build_about_page(self) -> QWidget:
        page, layout = self._page(
            "关于 Remote Mic", "小米 RC003 的 Windows 无线麦克风与遥控器桥接"
        )
        card, card_layout = self._card()
        title = QLabel("Remote Mic · RC003")
        title.setObjectName("pageTitle")
        card_layout.addWidget(title)
        card_layout.addWidget(QLabel(f"版本 {__version__}"))
        card_layout.addWidget(
            self._secondary(
                "Windows 版与 macOS 版使用独立代码入口、依赖、签名、安装器和发布产物。Windows 发布使用免费自签 Authenticode；普通电脑仍可能显示未知发布者或 SmartScreen 提示。"
            )
        )
        links = QHBoxLayout()
        project = QPushButton("打开项目主页")
        project.clicked.connect(lambda: webbrowser.open(PROJECT_URL))
        cable = QPushButton("VB-CABLE 官网")
        cable.clicked.connect(lambda: webbrowser.open(VB_CABLE_URL))
        links.addWidget(project)
        links.addWidget(cable)
        links.addStretch(1)
        card_layout.addLayout(links)
        layout.addWidget(card)
        layout.addStretch(1)
        return page

    def _select_page(self, index: int) -> None:
        if index >= 0:
            self._pages.setCurrentIndex(index)

    def _refresh_endpoints(self) -> None:
        try:
            self._endpoints = audio_output.enumerate_output_endpoints()
            self._endpoint_combo.clear()
            self._endpoint_combo.addItems(
                f"{item.name}  [{item.host_api}]" for item in self._endpoints
            )
            selected = next(
                (
                    index
                    for index, endpoint in enumerate(self._endpoints)
                    if endpoint.name == self._current["output_endpoint_name"]
                    and (
                        not self._current["output_endpoint_host_api"]
                        or endpoint.host_api
                        == self._current["output_endpoint_host_api"]
                    )
                ),
                -1,
            )
            if selected < 0 and self._endpoints:
                selected = next(
                    (
                        index
                        for index, item in enumerate(self._endpoints)
                        if audio_output.is_cable_input_endpoint(item.name)
                    ),
                    0,
                )
            if selected >= 0:
                self._endpoint_combo.setCurrentIndex(selected)
            self._audio_status.setText(f"检测到 {len(self._endpoints)} 个播放端点")
        except Exception as exc:  # noqa: BLE001 - visible settings error
            self._endpoints = []
            self._endpoint_combo.clear()
            self._audio_status.setText(f"枚举失败：{exc}")

    def _collect_settings(self) -> dict[str, object]:
        index = self._endpoint_combo.currentIndex()
        endpoint = self._endpoints[index] if 0 <= index < len(self._endpoints) else None
        bindings = key_mapping.default_button_bindings()
        for button in key_mapping.REMOTE_BUTTONS:
            for trigger in key_mapping.TRIGGERS:
                combo = self._mapping_combos[(button.button_id, trigger)]
                bindings[button.button_id][trigger] = key_mapping.display_to_action(
                    combo.currentText()
                )
        return {
            **self._current,
            "output_endpoint_name": endpoint.name
            if endpoint
            else self._current["output_endpoint_name"],
            "output_endpoint_host_api": endpoint.host_api
            if endpoint
            else self._current["output_endpoint_host_api"],
            "gain_db": self._gain_slider.value(),
            "custom_mapping_enabled": self._mapping_enabled.isChecked(),
            "button_bindings": bindings,
        }

    def _save_all(self, *, visible: bool = True) -> bool:
        try:
            saved = config.save_config(self._collect_settings())
            self._current.update(saved)
            self._audio_status.setText("配置已保存")
            self._mapping_status.setText(
                "按键映射已保存；运行中的桥接会在下一次按键时读取新配置。"
            )
            return True
        except Exception as exc:  # noqa: BLE001
            if visible:
                QMessageBox.critical(self, "Remote Mic · RC003", f"保存失败：{exc}")
            else:
                self._mapping_status.setText(f"按键映射尚未保存：{exc}")
            return False

    def _save_mapping_silently(self, *_args) -> None:
        self._save_all(visible=False)

    def _save_and_start(self) -> None:
        if not self._save_all():
            return
        if not self._current["output_endpoint_name"]:
            QMessageBox.warning(
                self, "Remote Mic · RC003", "请先选择一个语音输出设备。"
            )
            return
        try:
            _start_bridge()
            self._audio_status.setText(
                "桥接进程已启动；已有实例时会由单实例保护阻止重复启动"
            )
        except OSError as exc:
            QMessageBox.critical(self, "Remote Mic · RC003", f"启动失败：{exc}")

    def _reset_mappings(self) -> None:
        defaults = key_mapping.default_button_bindings()
        for button_id, gestures in defaults.items():
            for trigger, action in gestures.items():
                self._mapping_combos[(button_id, trigger)].setCurrentText(
                    key_mapping.action_to_display(action)
                )
        self._mapping_enabled.setChecked(True)
        self._save_mapping_silently()
        self._select_button("ok")

    def _select_button(self, button_id: str) -> None:
        for value, button in self._remote_buttons.items():
            button.setChecked(value == button_id)
        row = next(
            index
            for index, button in enumerate(key_mapping.REMOTE_BUTTONS)
            if button.button_id == button_id
        )
        self._mapping_table.selectRow(row)
        self._mapping_table.scrollToItem(self._mapping_table.item(row, 0))

    def _start_button_preview(self) -> None:
        if sys.platform != "win32":
            return
        try:
            self._preview_listener = raw_input_windows.RawInputListener(
                lambda button_id, pressed: self._raw_signal.edge.emit(
                    button_id, pressed
                )
            )
            self._preview_listener.start()
        except Exception as exc:  # noqa: BLE001 - settings remains usable
            self._preview_listener = None
            self._mapping_status.setText(f"实时按键检测不可用：{exc}")

    def _on_raw_edge(self, button_id: str, pressed: bool) -> None:
        if button_id not in self._remote_buttons:
            return
        if pressed:
            self._select_button(button_id)
            self._mapping_status.setText(
                f"已检测：{key_mapping.BUTTON_NAMES[button_id]}（标准 Raw Input）"
            )
        self._remote_buttons[button_id].setDown(pressed)

    def _open_logs(self) -> None:
        folder = config.config_root()
        folder.mkdir(parents=True, exist_ok=True)
        if sys.platform == "win32":
            os.startfile(folder)  # type: ignore[attr-defined]
        else:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(folder)))

    def closeEvent(self, event) -> None:  # noqa: N802 - Qt API
        if self._preview_listener is not None:
            self._preview_listener.stop()
            self._preview_listener = None
        super().closeEvent(event)


def run_settings() -> None:
    application = QApplication.instance() or QApplication(sys.argv)
    application.setApplicationName("Remote Mic · RC003")
    application.setStyle("Fusion")
    window = SettingsWindow()
    window.show()
    application.exec()
