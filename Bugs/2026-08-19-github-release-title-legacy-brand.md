# GitHub Release 标题回退为旧品牌

- 时间：2026-08-19
- 状态：已修复
- 影响范围：macOS `v1.9.1`、`v1.9.3` Pre-release 的 GitHub Release 页面标题与 Tag 注释
- 功能点：macOS 发布元数据

## 复现

`v1.9.3` 在 2026-08-19 07:05:39 UTC 首次发布后显示为 `Remote Mic 1.9.3`，而产品命名规范要求 `无线麦SayAll.app 1.9.3`。GitHub Release API 及发布事件时间线确认，标题在发布后才被人工修正。

## 日志与证据

- `v1.9.1` 发布于 00:05:33 UTC，Release 最后更新于 00:08:02 UTC。
- `v1.9.3` 发布于 07:05:39 UTC，Release 最后更新于 07:08:32 UTC。
- 两个候选使用的 `scripts/publish-release.sh` 都包含 `--title "Remote Mic $VERSION"`。
- 现有签名、公证、资产和版本测试没有断言 GitHub Release 标题或 Tag 注释的产品名。

## 根因

App bundle 和安装路径品牌迁移时，没有同步发布脚本中的用户可见 Release 标题与快速发布 Tag 注释。前一次发布只人工修正了 GitHub 元数据，没有回写脚本和测试，因此下一次发布再次复发。

## 修复

- 发布脚本统一使用 `PUBLIC_PRODUCT_NAME="无线麦SayAll.app"` 生成 GitHub Release 标题。
- 快速发布脚本使用同一产品名生成 Tag 注释。
- Swift 与 shell 发布测试同时拒绝旧的 `Remote Mic` 标题和 Tag 注释。

## 验证

- 定向 Swift 品牌与安装路径测试通过。
- 发布流水线 shell 回归通过。
- `git diff --check` 通过。
- 本修复不修改既有 Tag、Release 资产、签名或公证字节；现有 `v1.9.3` GitHub Release 标题已单独修正。

## 自动化与人工边界

自动化能够阻止源码再次生成旧标题，但不能证明 GitHub 网页缓存立即刷新。发布完成后仍应通过 Release API 核对标题、Pre-release 状态和资产数量，不以浏览器缓存截图作为唯一证据。
