# App 图标类型遗漏独立自检编译输入

## 复现与日志

- 受影响提交：`72250f128faae6a25cafe0708cd7ccb87187f591`，PR #537。
- CI：[Run 36839668629](https://github.com/HD838A/remote-mic-app/actions/runs/36839668629)，Apple Silicon 与 Intel Ventura 均在 `Run project self-test` 失败。
- 本地执行 `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`，退出码为 1，同样报告 `AppSettings.swift:50:28: cannot find type 'AppIconIdentifier' in scope`。后续 Codable 合成错误属于同一缺失类型的连带错误。
- CI 中前序 SwiftPM 测试及核心首轮语音旅程检查已通过；失败发生在独立自检的编译阶段，不是测试断言失败或硬件运行失败。

## 根因与修复

`AppSettings` 新增了 `AppIconIdentifier` 字段，类型定义在 `AppIconController.swift`。SwiftPM 自动包含该源文件，但 `scripts/test.sh` 使用 `xcrun swiftc` 手工列举文件，遗漏了新增依赖。

在自检脚本的编译清单中补入 `AppIconController.swift`，不改变产品行为、CI 门禁或 SwiftPM 钥匙串参数。搜索仓库脚本、测试与 workflows 后，没有发现其他同类手工 `swiftc` 编译入口。

## 防止同类遗漏

新增 `AppIconControllerTests.standaloneSelfTestIncludesTheAppIconIdentifierSource`，检查独立自检的实际编译清单行。新增测试在修复前已真实失败，补齐脚本后通过；再次移除或注释该行会使 SwiftPM 测试提前失败。

本次验证同时运行独立项目自检与 SwiftPM 全量测试。后续修改自检依赖的共享类型时，也必须检查手工编译输入并执行这两个入口，不能以 `swift test` 通过代替独立自检。此回归只保护已知图标依赖，不宣称自动检查任意未来类型。

## 验证与边界

- `./scripts/test.sh`：自检 `RESULT passed=48 failed=0`，随后 `swift build --disable-keychain` 通过。
- `swift test --disable-keychain --filter standaloneSelfTestIncludesTheAppIconIdentifierSource`：修复前失败，修复后通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：与 CI 相同入口退出码为 0，`RESULT passed=48 failed=0`。
- `swift test --disable-keychain`：779 tests / 60 suites 全部通过；`zsh -n scripts/test.sh` 与 `git diff --check` 通过。
- 远端双架构 CI 需在 Push 本次修复后确认，不能以本地通过替代远端结果。
- 仅验证编译、脚本与自动化回归，不替代 App 图标 UI、Dock、Command-Tab、重启恢复或 Intel 真机视觉验收。
