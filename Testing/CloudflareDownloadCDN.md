# Cloudflare Mac 下载 CDN 测试手册

## 适用范围

- 适用版本：macOS `1.9.21` Pre-release 及后续版本
- 官网：`https://sayall.app/`、`https://sayall.app/en/`
- 固定下载入口：`https://download.sayall.app/mac`

## 测试前准备

1. 确认 `sayall-download` Worker 已绑定 `download.sayall.app`。
2. 确认 GitHub 当前 latest full release 仍是预期正式版，候选 Release 为公开、非 Draft 的 Pre-release。
3. 准备当前正式版 App、候选版最终 ZIP、DMG、安装与卸载 PKG、SHA256、appcast 和中英文更新说明。
4. 不清除用户 App 偏好；Sparkle 候选测试只覆盖当前 CLI 调用的固定 appcast URL。

## 用例 1：固定正式版入口

1. 对 `https://download.sayall.app/mac` 发起 `HEAD`。
2. 记录状态码和 `Location`。
3. 对 Location 再发起 `HEAD`。

预期结果：首次响应为 `302` 且 `Cache-Control: no-store`；Location 为同域名 `/mac/releases/vX.Y.Z/Remote-Mic-X.Y.Z.dmg`，其中版本等于 GitHub latest full release，不等于任何 Pre-release；最终响应为 200、文件名正确，并包含 `x-remote-mic-cdn: cloudflare`。

失败判定：跳到 GitHub 页面、跳到预览版、循环跳转、文件名错误、状态码不是 302/200，或返回 HTML 错误页。

## 用例 2：stable 与 preview appcast 通道

1. 分别请求 `/mac/channels/stable/appcast.xml`、`/mac/channels/preview/appcast.xml`、`/mac/channels/stable/appcast-intel.xml` 和 `/mac/channels/preview/appcast-intel.xml`，不自动跟随重定向。
2. 记录 `Location`、`Cache-Control`，再跟随下载并与对应 GitHub 固定 Tag appcast 比较。
3. Preview 发布后重复检查四个入口；Stable 晋升后再次检查两个 stable 入口。

预期结果：四个入口均返回 `302` 和 `Cache-Control: no-store`；stable 只指向最新正式 Release，preview 只指向最新公开 Pre-release；Apple Silicon 与 Intel 始终使用各自 appcast。最终字节与 GitHub 固定 Tag 完全相同。

失败判定：客户端需要直接调用 GitHub Releases API、stable 指向 Pre-release、preview 回退到 stable、架构交叉、缓存旧通道超过发布脚本等待窗口，或最终 appcast 字节不同。

## 用例 3：版本化资产完整性

对候选标签分别下载 ZIP、DMG、安装 PKG、卸载 PKG、SHA256、appcast、中英文说明和 candidate provenance。

预期结果：Cloudflare 与 GitHub 固定标签下载的每个文件大小和 SHA-256 完全相同；签名、公证、staple、DMG 校验和 Sparkle helper 权限与符号链接均通过。

失败判定：任意字节不同、缺少资产、缓存旧版本、返回压缩/转换后的不同字节、签名或公证失效。

## 用例 4：HEAD 与断点续传

1. 对版本化 DMG 发起 `HEAD`。
2. 发起 `Range: bytes=0-1023`。
3. 将返回的 1024 字节与本地 DMG 前 1024 字节比较。

预期结果：HEAD 无响应体并提供正确长度；Range 返回 `206` 和有效 `Content-Range`；字节完全相同。

失败判定：Range 被忽略、返回完整文件、状态不是 206、长度错误或字节不同。

## 用例 5：路径与方法限制

测试任意 URL、其他仓库、版本不匹配文件名、未知资产、查询参数、POST 和上游不存在资产。

预期结果：分别返回 400、404、405 或 502；错误响应使用 `no-store`，不包含 GitHub Cookie、Token 或可执行文件内容。

失败判定：可借 Worker 代理任意 URL、版本路径和文件名不一致仍成功、错误页以 200 或安装包类型返回。

## 用例 6：官网中英文下载入口

1. 打开 `https://sayall.app/?analytics=qa`。
2. 检查页头、Hero、安装要求和底部下载按钮。
3. 重复检查 `https://sayall.app/en/?analytics=qa`。
4. 点击任意 Mac 下载按钮。

预期结果：所有按钮均为 `https://download.sayall.app/mac`；中文说明提到 Cloudflare CDN 与 GitHub 源文件，英文语义一致；点击产生 `macos_download_clicked`，目标为 `cloudflare_mac_download`；页面布局和其他链接不变。

失败判定：仍有 Mac CTA 指向 GitHub latest、中文或英文漏改、下载事件丢失、按钮跳到预览版或页面布局回归。

## 用例 7：Sparkle 候选发现和下载

1. 使用当前正式版最终 ZIP 解压的 App。
2. 使用 Sparkle 官方 CLI 对候选 GitHub 固定标签 appcast 执行一次性 `--probe`。
3. 确认 appcast enclosure 指向 Cloudflare 固定标签 ZIP。
4. 下载 enclosure，验证 Ed25519 签名、目标版本、Build、helper 权限和符号链接。

预期结果：正式版能发现 `1.9.21`；ZIP 经 Cloudflare 下载且与 GitHub 资产逐字节一致；不修改用户偏好。

失败判定：旧版无法发现候选、enclosure 使用 `/mac` 或 `latest`、下载后签名失败、默认稳定 feed 被修改。

## 稳定功能回归

- [x] App 内置 `SUFeedURL` 使用 Cloudflare stable 通道，客户端不直接访问 GitHub Releases API。
- [ ] 发布后 preview 通道两架构均指向 `1.9.21`，stable 通道两架构仍指向动态读取的正式版。
- [x] 预发布开关缺失/默认关闭、明确关闭、开启、使用后再关闭的相关自动化回归通过；候选 UI 更新尚未执行。
- [x] 当前 Stable latest 由 GitHub `releases/latest` 动态确认，Worker 与官网部署没有改变正式版。
- [x] GitHub Release 页面和当前稳定 Tag 的 DMG 可直接下载，并与 CDN 字节一致。
- [ ] 官网 GitHub、TestFlight、社群、版本历史和其他作品链接保持正常。
- [x] Mac App 蓝牙、HID、音频、权限和 Onboarding 代码未被本功能修改；完整自动化与硬件事件模拟回归通过。

## 日志与证据收集

- Worker：Cloudflare Workers Logs 中筛选 `sayall-download`，不记录完整 IP、Cookie 或任意上游 URL。
- 发布：保存 GitHub Release JSON、candidate provenance、两条下载路径的 SHA-256 清单和 `curl -I` / Range 结果。
- Sparkle：保存 CLI `--verbose` 输出；退出码 0 表示发现更新，4 表示没有更高版本。
- App：`~/Library/Logs/RemoteMic/runtime.log`；崩溃报告位于 `~/Library/Logs/DiagnosticReports/`。

## 自动化、代理实测和用户实测边界

自动化验证路径白名单、响应头、Range 转发、脚本 URL、构建和资产字节；代理可部署公开 Worker/官网并完成真实 GitHub 回源、签名、公证和 Sparkle 探测。不同国家和运营商网络、长时间大规模缓存命中率、中断后跨网络恢复，以及用户浏览器和企业代理策略仍属于真实用户环境验收边界。
