# 私有功能组件集成

## 为什么开发

部分非公开能力需要独立维护源码、资源、测试和内部文档，同时不能让公开源码仓库失去可构建性或影响稳定功能。

## 用户功能介绍

公开版本在没有私有组件时不显示相关入口。包含私有组件的预览构建默认同样隐藏邀请入口；受邀用户在“关于”页连续点击当前版本号 5 次后，可以原地输入邀请码，不需要通过命令行重新启动 App。

## 范围与非目标

- 本仓库只维护可选 Swift Package 接入、页面委托、语音会话生命周期和发布门禁。
- 私有功能实现、资格管理、服务配置、专属本地化和专属测试由独立私有仓库维护。
- 本次不修改蓝牙、HID、虚拟音频、手机遥控、网页版遥控或稳定语音路径。
- 本次不重写公开仓库既有 Git 历史。

## 关键设计

- 通过 `SAYALL_AI_PACKAGE_PATH` 在构建时选择性加载私有 Swift Package。
- 未提供路径时使用无操作适配，公开源码仍可测试和构建。
- 正式发布必须设置 `REQUIRE_SAYALL_AI_PACKAGE=1`，并在产物中验证私有组件标记，避免发布残缺安装包。
- App 只向私有组件转发启动、前台、休眠恢复、语言变化、语音开始和语音结束事件。
- “关于”页只负责五击计数；第五次点击调用私有组件的通用展示接口，不创建匿名设备 ID、不验证邀请码，也不触发网络请求。资格请求仍必须由用户输入邀请码并手动确认。

## 涉及文件

- `Package.swift`
- `Sources/RemoteMic/PrivateFeatureIntegration.swift`
- `Sources/RemoteMic/BridgeAppModel.swift`
- `Sources/RemoteMic/SettingsView.swift`
- `Sources/RemoteMic/RemoteMicApp.swift`
- `.github/workflows/mac-ci.yml`
- `.github/workflows/mac-preview-candidate.yml`
- `scripts/build-app.sh`
- `scripts/verify-app.sh`
- `scripts/notarize-release.sh`

## 隐私与兼容边界

- 公开 fallback 不加载、展示或访问私有功能数据。
- 私有组件继续使用既有偏好键、Keychain 标识和本地文件位置，已授权用户不需要迁移数据。
- 公开仓库旧提交仍包含迁出前实现；本次按要求不处理历史清理。

## 验证

- 私有组件独立单元测试与 Release 构建。
- 公开仓库不含私有组件时的完整 Swift 测试与 Release 构建。
- 注入私有组件后的完整 Swift 测试、Release 构建、Self Test 和 App 结构校验。
- RC003、Fn、Nearby、Web Remote 和虚拟音频稳定基线保持原有测试门禁。

## 当前状态和已知限制

当前状态：已完成拆分和构建边界，等待两个仓库 CI 验证。

下一预览版代码基线已加入“关于页版本号五击显示邀请入口”，本次不修改版本号或生成发布安装包。

自动化不能替代真实 RC003、真实第三方输入工具、生产资格服务和真实模型请求验收。
