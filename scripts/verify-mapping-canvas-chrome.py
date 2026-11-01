#!/usr/bin/env python3
"""校验按键画布的「按住」胶囊是否仍按同一份视觉规格实现。

三种遥控器的画布由三份代码绘制：宿主的小米画布、私有包的 Siri 与 Chromecast 画布。
2026-10-31 把按住胶囊收敛成与三个动作格子一致的灰底时只改了宿主，另外两处仍是
浅橙底，导致同一页面切到其他遥控器时「按住」样式不同。这个脚本用来阻止第二次漂移。

用法：
  scripts/verify-mapping-canvas-chrome.py
  scripts/verify-mapping-canvas-chrome.py --private-root /path/to/sayall-private-platform

私有源码目录也可以通过 SAYALL_MAPPING_PRIVATE_CANVAS_ROOT 或
SAYALL_PRIVATE_PLATFORM_PACKAGE_PATH 指定。找不到私有源码时（公开 CI 的常态）
只校验宿主侧，并明确打印跳过原因——不静默通过。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOST_CANVAS = ROOT / "Sources/RemoteMic/RemoteMappingCanvas.swift"

# 合同规定值：Testing/HardwareCompatibilityContract.md「按键设置页共享合同」。
# 私有画布直接写字面量，宿主画布必须把同一组数字放进 RemoteMappingCardChrome。
EXPECTED_CHIP = {
    "font size": r"size:\s*12\b",
    "font weight": r"weight:\s*\.semibold",
    "horizontal padding": r"padding\(\.horizontal,\s*6\)",
    "vertical padding": r"padding\(\.vertical,\s*2\)",
    "corner radius": r"cornerRadius:\s*5\b",
}
EXPECTED_CHROME_CONSTANTS = {
    "font size": r"fontSize:\s*CGFloat\s*=\s*12\b",
    "font weight": r"fontWeight\s*=\s*Font\.Weight\.semibold",
    "horizontal padding": r"horizontalPadding:\s*CGFloat\s*=\s*6\b",
    "vertical padding": r"verticalPadding:\s*CGFloat\s*=\s*2\b",
    "corner radius": r"cornerRadius:\s*CGFloat\s*=\s*5\b",
    "neutral background": r"background\s*=\s*AnyShapeStyle\(\.quaternary\)",
}
NEUTRAL_BACKGROUND = r"quaternary"

CHIP_BLOCK = re.compile(
    r"Text\((?:summary|holdSummary\([^)]*\))\)(.*?)\n\s*\}",
    re.DOTALL,
)


def fail(message: str) -> int:
    print(f"CHROME VERIFY FAIL: {message}", file=sys.stderr)
    return 1


def chip_block(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = CHIP_BLOCK.search(text)
    if match is None:
        raise SystemExit(
            f"CHROME VERIFY FAIL: 在 {path} 里找不到「按住」胶囊的修饰链"
        )
    return match.group(1)


def check_host() -> int:
    text = HOST_CANVAS.read_text(encoding="utf-8")
    if "RemoteMappingCardChrome.HoldChip" not in text:
        return fail(
            "小米画布的按住胶囊必须引用 RemoteMappingCardChrome.HoldChip，"
            "不能再写死数值"
        )
    block = chip_block(HOST_CANVAS)
    if "RemoteMappingCardChrome.HoldChip" not in block:
        return fail("小米画布的按住胶囊修饰链没有使用共享规格常量")
    for name, pattern in EXPECTED_CHROME_CONSTANTS.items():
        if not re.search(pattern, text):
            return fail(f"RemoteMappingCardChrome 缺少 {name} 的规定值（应为 {pattern}）")
    for name, pattern in EXPECTED_CHIP.items():
        if re.search(pattern, block):
            return fail(
                f"小米画布的按住胶囊仍写死了 {name}（{pattern}）；"
                "必须引用 RemoteMappingCardChrome.HoldChip"
            )
    return 0


def private_canvases(root: Path) -> list[Path]:
    candidates = [
        root / "packages/audio-input-kit/chromecast/Sources/SayAllChromecast/ChromecastMappingPage.swift",
        root / "packages/audio-input-kit/siri-remote/Sources/SayAllSiriRemote/SiriRemoteMappingPage.swift",
    ]
    if all(path.is_file() for path in candidates):
        return candidates
    alt = [
        root / "Sources/SayAllChromecast/ChromecastMappingPage.swift",
        root / "Sources/SayAllSiriRemote/SiriRemoteMappingPage.swift",
    ]
    return [path for path in alt if path.is_file()]


def resolve_private_root(explicit: str | None) -> Path | None:
    for value in (
        explicit,
        os.environ.get("SAYALL_MAPPING_PRIVATE_CANVAS_ROOT"),
        os.environ.get("SAYALL_PRIVATE_PLATFORM_PACKAGE_PATH"),
    ):
        if not value:
            continue
        path = Path(value).expanduser()
        if private_canvases(path):
            return path
    return None


def check_private(root: Path) -> int:
    failures: list[str] = []
    for path in private_canvases(root):
        try:
            block = chip_block(path)
        except SystemExit as error:
            failures.append(str(error))
            continue
        for name, pattern in EXPECTED_CHIP.items():
            if not re.search(pattern, block):
                failures.append(f"{path.name} 的按住胶囊 {name} 不是合同规定值")
        if not re.search(NEUTRAL_BACKGROUND, block):
            failures.append(
                f"{path.name} 的按住胶囊底色不是中性灰（合同要求 {NEUTRAL_BACKGROUND}，"
                "不要用强调色）"
            )
    if failures:
        for item in failures:
            print(f"CHROME VERIFY DRIFT: {item}", file=sys.stderr)
        return 2
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--private-root",
        help="私有平台源码根目录；缺省时读 SAYALL_MAPPING_PRIVATE_CANVAS_ROOT / "
        "SAYALL_PRIVATE_PLATFORM_PACKAGE_PATH",
    )
    arguments = parser.parse_args()

    if not HOST_CANVAS.is_file():
        return fail(f"找不到宿主画布 {HOST_CANVAS}")
    host_status = check_host()
    if host_status != 0:
        return host_status

    private_root = resolve_private_root(arguments.private_root)
    if private_root is None:
        print(
            "CHROME VERIFY SKIP: 未提供私有平台源码目录，只校验了宿主小米画布；"
            "Siri / Chromecast 画布需在私有仓或指定 --private-root 后复查"
        )
        return 0

    private_status = check_private(private_root)
    if private_status != 0:
        print(
            "CHROME VERIFY FAIL: 私有画布与合同不一致；需要私有仓同步"
            "（宿主侧规格定义在 RemoteMappingCardChrome）",
            file=sys.stderr,
        )
        return private_status

    print(f"CHROME VERIFY PASS: 宿主 + {len(private_canvases(private_root))} 个私有画布")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
