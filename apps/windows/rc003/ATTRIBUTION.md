# Windows RC003 来源与改动

本目录是 GPL-3.0-only 派生实现，选择性移植自当前仓库的 Windows PR：

- PR：[`HD838A/remote-mic-app#3`](https://github.com/HD838A/remote-mic-app/pull/3)
- 固定提交：`c8f68611e4d56440a4ae527a10195c18bed1409e`
- PR 所依据的独立 Windows fork：[`miaomiaozii/windows-remote-mic-app`](https://github.com/miaomiaozii/windows-remote-mic-app)
- 更早的协议参考：[`xxb26553663-star/remote-bridge-hub`](https://github.com/xxb26553663-star/remote-bridge-hub)，固定提交 `8a93f321ac71a602300c6cd77f7256fa4b63068e`

选择性保留的能力包括 WinRT BLE/GATT、ATVV 会话、IMA/DVI ADPCM 解码、16 kHz PCM 音频输出、重连、端点选择和单实例保护。

本版本明确删除或不移植以下 PR 能力：

- DJI Mic 2 和其他遥控器；
- Frida Gadget、WUDFHost 注入和调试权限；
- 豆包 `ImeService.exe` 附加；
- Raw Input、SendInput、按键映射和完整 HID tap；
- Qt/QML 设置页；
- VB-CABLE 安装包下载、捆绑或自动安装。

新增内容包括标准库 Tk 设置页、版本化原子配置、用户明确选择播放端点、Windows 独立 PyInstaller/Inno Setup 构建、公开仓库 GitHub Actions、免费自签 Authenticode 脚本和对应测试。

完整软件许可见仓库根目录 [`LICENSE.md`](../../../LICENSE.md)。
