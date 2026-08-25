"""Render every settings page from current QML source for visual review.

This is a development-only screenshot harness.  It does not launch, stop, or
reconfigure the RC003 bridge and writes only to the ignored artifacts folder.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys


def _find_child(root, object_name: str):
    for child in root.children():
        if child.objectName() == object_name:
            return child
        found = _find_child(child, object_name)
        if found is not None:
            return found
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    repository_root = Path(__file__).resolve().parents[4]
    parser.add_argument(
        "--output",
        type=Path,
        default=repository_root / "artifacts" / "ui-review",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    # Qt's offscreen plugin does not enumerate the installed Windows CJK
    # fonts, producing misleading tofu-glyph screenshots.  Native Windows
    # rendering is therefore the review default; non-Windows CI can still
    # use offscreen explicitly.
    os.environ.setdefault(
        "QT_QPA_PLATFORM",
        "windows" if os.name == "nt" else "offscreen",
    )
    source_root = repository_root / "apps" / "windows" / "rc003" / "src"
    sys.path.insert(0, str(source_root))

    from ovb_rc003 import qt_settings_app as app_module

    classes = app_module._load_qt_classes()
    QGuiApplication = classes["QGuiApplication"]
    QQmlApplicationEngine = classes["QQmlApplicationEngine"]
    QQuickStyle = classes["QQuickStyle"]
    QUrl = classes["QUrl"]
    qmlRegisterSingletonInstance = classes["qmlRegisterSingletonInstance"]
    ButtonMappingModel = classes["ButtonMappingModel"]
    SettingsController = classes["SettingsController"]
    UsageStatisticsController = classes["UsageStatisticsController"]
    DiagnosticsController = classes["DiagnosticsController"]

    QQuickStyle.setStyle("FluentWinUI3")
    qt_app = QGuiApplication.instance() or QGuiApplication([])
    model = ButtonMappingModel()
    controller = SettingsController(model)
    usage_controller = UsageStatisticsController(app_module.config.config_root())
    diagnostics_controller = DiagnosticsController(
        controller,
        app_module.config.config_root(),
    )
    qmlRegisterSingletonInstance(
        SettingsController, "OvbRc003Settings", 1, 0, "SettingsController", controller
    )
    qmlRegisterSingletonInstance(
        ButtonMappingModel, "OvbRc003Settings", 1, 0, "ButtonMappingModel", model
    )
    qmlRegisterSingletonInstance(
        UsageStatisticsController,
        "OvbRc003Settings",
        1,
        0,
        "UsageStatisticsController",
        usage_controller,
    )
    qmlRegisterSingletonInstance(
        DiagnosticsController,
        "OvbRc003Settings",
        1,
        0,
        "DiagnosticsController",
        diagnostics_controller,
    )

    engine = QQmlApplicationEngine()
    qml_dir = app_module._qml_directory()
    engine.addImportPath(str(qml_dir))
    engine.load(QUrl.fromLocalFile(str(qml_dir / "main.qml")))
    roots = engine.rootObjects()
    if len(roots) != 1:
        raise RuntimeError("main.qml did not create exactly one root window")

    window = roots[0]
    tab_bar = _find_child(window, "tabBar")
    if tab_bar is None:
        raise RuntimeError("main.qml tabBar automation hook is missing")

    page_names = ("connection", "mapping", "statistics", "permissions", "diagnostics")
    window.show()
    for index, page_name in enumerate(page_names):
        tab_bar.setProperty("currentIndex", index)
        for _ in range(8):
            qt_app.processEvents()
        image = window.grabWindow()
        target = args.output / f"{index + 1:02d}-{page_name}.png"
        if image.isNull() or not image.save(str(target)):
            raise RuntimeError(f"failed to render {target}")
        print(target)

    window.close()
    controller.stopHotkeyCapture()
    controller.stopKeyDetection()
    app_module._shutdown_diagnostics_workers()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
