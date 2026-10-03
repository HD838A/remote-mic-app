# 常用语列表阻断 CI Release 构建

## 复现与日志

PR #558 的 [CI run 37056169952](https://github.com/HD838A/remote-mic-app/actions/runs/37056169952) 使用 Xcode 26.3 构建产品源码 `86e2a42ccd7bbd9514c3b9545fae405e4defd9c1`。公开、免费组合动作和付费键位方案三个 lane 的 Apple Silicon Release 步骤均失败；日志共同指向 `CommonPhraseSettingsView.swift` 的 `libraryColumn`：`the compiler is unable to type-check this expression in reasonable time`。正常边界是 Debug 测试及本地 Swift 6.4 的 Release 构建通过，因此不是已确认的运行时故障。

先取得失败 run 日志，定位相同错误后再修改。原始失败日志本机保留在 `dist/common-phrases-pr-ci-37056169952-failed.log`，远端原始 run 保留可审计记录。本机没有 CI 的 Xcode 26.3，不能声称在本机复现其编译器失败。

## 根因与最小修复

`libraryColumn` 把词库标题、搜索、整行按钮、嵌套按键标签、拖放、排序和备份组合成单个泛型表达式。失败日志直接确认该表达式超出 CI 编译器的类型推断时限。将原行按钮及其修饰器原样提取为 `libraryRow(_:) -> some View`，外层 ForEach 调用该方法，形成独立类型推断边界；不改变布局、状态、点击、分配、拖放或日志行为。

## 验证与边界

- `swift test --disable-keychain --scratch-path /private/tmp/remote-mic-swiftpm/common-phrases-debug --filter 'CommonPhrase|SettingsPageRegression|RemoteButtons'`：186 tests / 3 suites 通过，记录 `dist/common-phrases-pr-type-check-tests.log`。
- 本地公开 Apple Silicon Release 重建记录：`dist/common-phrases-pr-type-check-release.log`；CI Xcode 26.3 原用例与双架构结果以 PR #558 最新 run 为准，未通过前不称修复已完成。
- `git diff --check` 通过；复核忽略缩进的 diff，行按钮、修饰器及闭包内容保持原样。
- 此修复仅解决编译范围；真实遥控器、第三方上屏、语音及指针验收仍按 [常用语测试手册](../Testing/CommonPhrases.md) 执行，构建不能替代实机结果。
