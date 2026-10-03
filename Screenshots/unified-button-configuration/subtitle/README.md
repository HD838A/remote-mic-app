# 按键页操作副标题实际截图

2026-10-03，用户指定“点击按键配置设置动作”，英文为“Click a button to configure its action”。共享页头只增加13pt操作副标题，遥控器画布、按钮、连线及执行路径保持。

本轮原生debug构建的生产SettingsView隐藏交互入口，独立Bundle ID、隔离UserDefaults与测试数据，1020×772pt，原始CUA JPEG 2040×1544px。四图覆盖中英文与浅深色，未裁切/缩放/重压缩；格式、尺寸和摘要见manifest.json。该内部ad-hoc副本仅用于UI验证，不作为用户安装包。

最终产品源基于宿主47bb862dc8190d1f07572a2c99aa61da3b318162，加本提交的SettingsView及两份本地化文本；私有87d7c7783297051c7f17a3d52f96a7bd478ba329。构建在本提交落盘前，截图对应本提交产品源码。中文浅色实际点击主页键单击，正常进入对应编辑区；其他截图检查页头、导航、设备区域、画布与滚动，不代表硬件或语音验收。早期布局探索的actual-mapping-zh-hans-light.jpg仅本地保留，不入本提交。
