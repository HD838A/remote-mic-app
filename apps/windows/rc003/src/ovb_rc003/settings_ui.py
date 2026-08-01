"""使用 Python 标准库 Tk 的最小 Windows 设置窗口。"""

from __future__ import annotations

import os
import subprocess
import sys
import webbrowser

from . import audio_output, config

VB_CABLE_URL = "https://vb-audio.com/Cable/"


def _bridge_command() -> list[str]:
    if getattr(sys, "frozen", False):
        return [sys.executable, "--bridge"]
    return [sys.executable, "-m", "ovb_rc003", "--bridge"]


def _start_bridge() -> None:
    creationflags = 0
    if sys.platform == "win32":
        creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    subprocess.Popen(
        _bridge_command(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=(sys.platform != "win32"),
        creationflags=creationflags,
    )


def run_settings() -> None:
    import tkinter as tk
    from tkinter import messagebox, ttk

    root = tk.Tk()
    root.title("Remote Mic · RC003（Windows）")
    root.geometry("680x390")
    root.minsize(620, 360)

    current = config.load_config()
    endpoints: list[audio_output.AudioEndpoint] = []
    endpoint_labels: list[str] = []

    frame = ttk.Frame(root, padding=20)
    frame.pack(fill="both", expand=True)
    ttk.Label(frame, text="小米 RC003 无线麦克风", font=("Segoe UI", 16, "bold")).pack(
        anchor="w"
    )
    ttk.Label(
        frame,
        text=(
            "第一版只处理 RC003 BLE 语音，不注入系统进程，也不随包安装驱动。\n"
            "若需要系统虚拟麦克风，请从 VB-Audio 官网自行安装 VB-CABLE，"
            "然后在这里选择 CABLE Input。"
        ),
        wraplength=620,
    ).pack(anchor="w", pady=(8, 18))

    ttk.Label(frame, text="语音输出设备").pack(anchor="w")
    endpoint_var = tk.StringVar()
    endpoint_box = ttk.Combobox(frame, textvariable=endpoint_var, state="readonly")
    endpoint_box.pack(fill="x", pady=(4, 12))

    gain_row = ttk.Frame(frame)
    gain_row.pack(fill="x", pady=(0, 14))
    ttk.Label(gain_row, text="数字增益（-24 至 24 dB）").pack(side="left")
    gain_var = tk.DoubleVar(value=float(current["gain_db"]))
    ttk.Spinbox(gain_row, from_=-24, to=24, increment=1, textvariable=gain_var, width=8).pack(
        side="right"
    )

    status_var = tk.StringVar(value="尚未枚举音频设备")
    ttk.Label(frame, textvariable=status_var, foreground="#555555").pack(anchor="w")

    def refresh_endpoints() -> None:
        nonlocal endpoints, endpoint_labels
        try:
            endpoints = audio_output.enumerate_output_endpoints()
            endpoint_labels = [f"{item.name}  [{item.host_api}]" for item in endpoints]
            endpoint_box["values"] = endpoint_labels
            selected_index = next(
                (
                    index
                    for index, item in enumerate(endpoints)
                    if item.name == current["output_endpoint_name"]
                    and (
                        not current["output_endpoint_host_api"]
                        or item.host_api == current["output_endpoint_host_api"]
                    )
                ),
                -1,
            )
            if selected_index >= 0:
                endpoint_box.current(selected_index)
            elif endpoints:
                cable_index = next(
                    (
                        index
                        for index, item in enumerate(endpoints)
                        if audio_output.is_cable_input_endpoint(item.name)
                    ),
                    0,
                )
                endpoint_box.current(cable_index)
            status_var.set(f"检测到 {len(endpoints)} 个播放端点")
        except Exception as exc:  # noqa: BLE001 - visible settings error
            endpoints = []
            endpoint_labels = []
            endpoint_box["values"] = []
            status_var.set(f"枚举失败：{exc}")

    def save() -> bool:
        index = endpoint_box.current()
        if index < 0 or index >= len(endpoints):
            messagebox.showwarning("Remote Mic · RC003", "请先选择一个语音输出设备。")
            return False
        selected = endpoints[index]
        try:
            saved = config.save_config(
                {
                    **current,
                    "output_endpoint_name": selected.name,
                    "output_endpoint_host_api": selected.host_api,
                    "gain_db": gain_var.get(),
                }
            )
            current.update(saved)
            status_var.set("配置已保存")
            return True
        except Exception as exc:  # noqa: BLE001
            messagebox.showerror("Remote Mic · RC003", f"保存失败：{exc}")
            return False

    def save_and_start() -> None:
        if not save():
            return
        try:
            _start_bridge()
            status_var.set("桥接进程已启动；再次启动会被单实例保护阻止")
        except OSError as exc:
            messagebox.showerror("Remote Mic · RC003", f"启动失败：{exc}")

    def open_logs() -> None:
        folder = config.config_root()
        folder.mkdir(parents=True, exist_ok=True)
        if sys.platform == "win32":
            os.startfile(folder)  # type: ignore[attr-defined]

    buttons = ttk.Frame(frame)
    buttons.pack(fill="x", pady=(22, 0))
    ttk.Button(buttons, text="刷新设备", command=refresh_endpoints).pack(side="left")
    ttk.Button(buttons, text="VB-CABLE 官网", command=lambda: webbrowser.open(VB_CABLE_URL)).pack(
        side="left", padx=(8, 0)
    )
    ttk.Button(buttons, text="打开日志", command=open_logs).pack(side="left", padx=(8, 0))
    ttk.Button(buttons, text="保存", command=save).pack(side="right")
    ttk.Button(buttons, text="保存并启动桥接", command=save_and_start).pack(
        side="right", padx=(0, 8)
    )

    refresh_endpoints()
    root.mainloop()
