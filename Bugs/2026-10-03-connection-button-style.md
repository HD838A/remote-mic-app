# 连接按钮样式不一致

- 用户现场：iOS、Watch 和网页连接按钮的颜色与尺寸不一致，要求以普通白底黑字按钮为准。
- 代码证据：iOS 未开启状态使用 prominent，其他入口使用 standard。
- 修复：三个入口均用 standard 和 regular 控件尺寸，保留原连接动作及状态文案。
- 验证：swift build --disable-keychain 通过；宿主无私有 Package 可以构建。该构建不证明设备连接或语音通过。
- 用户报告：Android 小程序及 iOS 语音通过；Watch 连接成功但录音无波动，后者单独排查。
