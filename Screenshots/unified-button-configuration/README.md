# 统一按键设置 UI 验证记录

2026-10-03，分支 `codex/unified-button-configuration`，按用户确认的四张设计稿实现。
使用生产 SettingsView、1020 × 772 内容尺寸、隔离 UserDefaults 与脱敏动作库；未修改日常用户数据。
内部 ad-hoc Release App 仅用于 UI 观察，不是用户安装包。

## 交互窗口已检查

浅色窗口保留按键页实物遥控器、两侧卡片、连接曲线和单击／双击／长按格子；
在原有自定义动作区搜索、明确选择组合动作，显示步骤数和选中态。
组合动作库与编辑流程分别显示；编辑隐藏库，基本设置、编排步骤、测试与保存三步可导航，
底栏可见，参数可滚动，输入框学习和单步测试入口保留，高级脚本默认关闭。
新建动作不要求先测试即可在最后保存，保存后仍未绑定；取消不覆盖旧动作。
Siri Remote 方案第二步显示正确实物图片与热点，可选择播放／暂停以及已有组合动作；
该方案最终保存尚未完成，不将截图作为持久化或硬件执行通过的证据。

`actual-*.jpg` 为 CUA 返回的原始 JPEG，原样保存，未缩放或重新编码。
三步截图主要结构已检查；首动作卡片的末次调整之后未能重拍新建基本页。
早期 `actual-action-new-basic-light.jpg` 仅本地留存，不列入有效截图或提交。

## 离屏补充

`offscreen-chromecast-light/` 与 `offscreen-chromecast-dark/` 的三张图由现有生产
SettingsScreenshotRenderer 生成，中文浅色／深色逐张检查。Chromecast 普通按键页显示
专有键与默认系统保留行为；动作库和方案摘要可见，标题、侧栏及主要控件无横向裁切。
`offscreen-siri-dark/mapping-1020x772.png` 补充 Siri 普通按键画布的深色状态。
这些图不包含窗口 chrome，也不证明真实窗口导航、Chromecast 方案热点点击或深色编辑步骤通过。

2026-10-03 末轮 CUA 返回 `Computer Use server error -10005: timeoutReached`，重置后仍超时。
目前只能确认界面控制服务不可用，不能推断机器锁屏。没有改用其他 UI 自动化方式绕过。
完整深色三步、Chromecast 方案交互、最终新建基本页及全部侧栏的末轮点击仍待验证。

## 资产核验

下表全部原始文件已验证格式、尺寸、SHA-256，并逐张查看。像素为 Retina 2040 × 1544，
对应生产 1020 × 772 内容尺寸；离屏截图不能替代生产窗口交互验收。

| 文件 | 格式 | 像素尺寸 | SHA-256 |
| --- | --- | --- | --- |
| [actual-mapping-light.jpg](actual-mapping-light.jpg) | JPEG | 2040 × 1544 | `f4f4ab4656cbb287d303bac9547aaf2b61424cd5ae8e17e648a59748268bc22d` |
| [actual-mapping-action-picker-light.jpg](actual-mapping-action-picker-light.jpg) | JPEG | 2040 × 1544 | `e0d7e9f5983cc76271a6cc8754b0bf6c0bd69dabcabca16366e4549d0f8cfc4c` |
| [actual-action-library-light.jpg](actual-action-library-light.jpg) | JPEG | 2040 × 1544 | `a24bd419582caefa4d8fb75938c65175846124aeb74afe34bd882c6791ff04a7` |
| [actual-action-basic-light.jpg](actual-action-basic-light.jpg) | JPEG | 2040 × 1544 | `d94c1aef1f926a5a4124607fd98dc5aab5fae792a608bca09f47826c6fc75e2a` |
| [actual-action-steps-light.jpg](actual-action-steps-light.jpg) | JPEG | 2040 × 1544 | `d28aa7ecef71f82e51a0b0adef31782d239a893db54397d5ac47842decc9278d` |
| [actual-action-review-light.jpg](actual-action-review-light.jpg) | JPEG | 2040 × 1544 | `8e30578db0297ea7fd5bf507e23d407920836a82841a6169a9c92717c89ef4bf` |
| [actual-profiles-siri-light.jpg](actual-profiles-siri-light.jpg) | JPEG | 2040 × 1544 | `bed74578874ebdcd50df6cd0fb9c6c3ef84f7aba09794aa52834979a3a4bb77b` |
| [offscreen-chromecast-light/mapping-1020x772.png](offscreen-chromecast-light/mapping-1020x772.png) | PNG | 2040 × 1544 | `6068033cdebdca6cb17a4a7533606ace27dae10dffd87c55a6148f426fb57bfa` |
| [offscreen-chromecast-light/macros-1020x772.png](offscreen-chromecast-light/macros-1020x772.png) | PNG | 2040 × 1544 | `4a99f59fa0f9c3d708040bc3f0c2b14163fc0a6ad59df930b3e46734b402e73d` |
| [offscreen-chromecast-light/buttonProfiles-1020x772.png](offscreen-chromecast-light/buttonProfiles-1020x772.png) | PNG | 2040 × 1544 | `d277ff623bed04a7a952df7577c615320525e81816665181a536d1dc986bdc5d` |
| [offscreen-chromecast-dark/mapping-1020x772.png](offscreen-chromecast-dark/mapping-1020x772.png) | PNG | 2040 × 1544 | `28986a9e4ebdad1d3e50a01bccb2daa0f067e77984582805fc4a2abc320bc2ba` |
| [offscreen-chromecast-dark/macros-1020x772.png](offscreen-chromecast-dark/macros-1020x772.png) | PNG | 2040 × 1544 | `d3474d2ac66f267ebfdfebb620feea7cec52d2977bf4bd9404fc0381960b111a` |
| [offscreen-chromecast-dark/buttonProfiles-1020x772.png](offscreen-chromecast-dark/buttonProfiles-1020x772.png) | PNG | 2040 × 1544 | `00824b17eafe02a7e9e192356701173df4dcef782b3c752fa42835cdd0c416ad` |
| [offscreen-siri-dark/mapping-1020x772.png](offscreen-siri-dark/mapping-1020x772.png) | PNG | 2040 × 1544 | `6aabaa8f87902058dc7391d0f0067a76ff437c0c3f6d44fab0b9b13a0426243c` |

## 构建和真实环境边界

三种模块配置的 Release 构建通过；内部 App 的 `codesign --verify --deep --strict` 通过。
`verify-app.sh` 未通过 Siri Developer ID 签名门禁：ad-hoc App 无法连接已安装 HCI helper。
该内部包未作为用户安装包交付，未公证、未发布，也未把签名门禁降低。
真实遥控器、首次系统权限、第三方 App 响应、普通键／连发及语音首尾完整性未验收。
后续操作及失败判定见[测试手册](../../Testing/UnifiedButtonConfiguration.md)。
