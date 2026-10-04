# 会员与 Plus 按键方案宿主集成测试手册

## 适用版本或分支

- 适用版本：当前待验证 PR 或已合入 `main` 的精确 Commit；原功能分支 `codex/macos-commerce-host-bridge` 只作为历史审计来源。
- 范围：无线麦SayAll.app 的可选会员页面、Plus 按键方案页面，以及实体遥控器、Nearby iPhone / Apple Watch 和 Web Remote 的宿主动作路由。
- 本仓库只维护公开宿主桥接；会员、订单、权益校验和收费方案源码不在公开仓库中。

## 测试前准备

1. 准备不注入任何私有 Package 的公开构建。
2. 准备注入统一私有二进制构件 Package 的内部构建；不把私有源码、二进制构件或本机绝对路径提交到本仓库。
3. 内部构建只通过 `SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH` 注入会员、组合动作和付费键位方案。服务环境由私有 `SayAllMembershipHostAdapter` 管理。本地包设置 `SAYALL_BUILD_CHANNEL=local`，不向公开宿主传入会员服务地址。
4. 准备 Free、Plus、会员刚过期、网络断开但租约仍有效、租约已过期五种脱敏测试状态。
5. 准备真实实体遥控器、Nearby iPhone 或 Apple Watch，以及 Web Remote；分别记录当前公开按键映射作为回退基线。

仅验证内部键位方案而不测试会员时，改用组合动作与键位方案两个源码 Package，并显式设置 `SAYALL_TEST_BUTTON_PROFILES_FREE=1`。该模式不得设置 `SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH`、会员服务地址或 AI Package；构建脚本会拒绝混入统一私有构件，以保证安装包不包含会员资源。

## 自动化与构建命令

公开构建不得依赖私有 Package：

```bash
swift test --disable-keychain
swift build --disable-keychain -c release
```

内部集成构建只注入一个经过校验的私有二进制构件 Package；会员、组合动作和付费键位方案必须来自同一份构件清单：

```bash
SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH=/path/to/prepared-private-artifact-package \
swift test --disable-keychain --scratch-path .build-free-paid

SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH=/path/to/prepared-private-artifact-package \
swift build --disable-keychain --scratch-path .build-free-paid -c release
```

内部免费测试构建：

```bash
SAYALL_COMBINATION_ACTIONS_PATH=/path/to/macos-combination-actions \
SAYALL_BUTTON_PROFILES_PACKAGE_PATH=/path/to/macos-button-profiles \
SAYALL_TEST_BUTTON_PROFILES_FREE=1 \
swift test --disable-keychain --scratch-path .build-button-profiles-test

SAYALL_COMBINATION_ACTIONS_PATH=/path/to/macos-combination-actions \
SAYALL_BUTTON_PROFILES_PACKAGE_PATH=/path/to/macos-button-profiles \
SAYALL_TEST_BUTTON_PROFILES_FREE=1 \
swift build --disable-keychain --scratch-path .build-button-profiles-test -c release
```

路径示例只能留在本机命令记录中，不得写入提交、产物、日志或公开发布说明。

## 用例一：公开构建完全回退

步骤：不设置付费键位方案与会员 Package 路径，构建并启动 App，逐一打开设置侧边栏，并用实体遥控器、Nearby 和 Web Remote 触发单击、双击和长按。官方构建仍应设置免费组合动作路径。

预期：显示免费的“组合动作”，不显示“按键方案”和“会员”页面；App 不创建会员会话、不请求会员服务；未绑定组合动作的按键继续执行原公开映射。

失败判定：公开构建因缺少私有 Package 无法编译或启动，出现空白私有页面，或任意按键被不存在的私有方案吞掉。

## 用例二：会员服务配置边界

步骤：检查构建脚本和最终 `Info.plist`，再启动内部构建。在通用设置中检查服务环境选择器，并分别选择测试和生产环境。

预期：公开宿主没有会员服务地址配置入口。最终包不含 `SayAllMembershipAPIBaseURL`。私有适配器管理环境、凭据命名空间和会员页面。切换环境不改变会员权益规则。

失败判定：公开宿主重新写入会员服务地址、不同环境混用凭据，或 Token、邮箱出现在公开日志中。

## 用例三：账号与会员页面

步骤：完成邮箱验证码登录、刷新、退出登录，再模拟网络失败后恢复；分别检查 Free 和 Plus 账户。同时查看设置侧边栏“个人中心”入口在未登录、已登录、刷新和退出后的文字。

预期：登录态由安全会话恢复；已登录时个人中心入口显示邮箱 `@` 前最多 6 个字符，前缀不足 6 个字符时完整显示；未登录或退出后显示“我”；刷新保留用户名，退出立即清空用户名；退出后本机立即失效，服务端撤销失败时可在网络恢复后补偿；Free 显示升级入口，Plus 显示有效权益。日志和可复制诊断不得包含邮箱、验证码、Token、安装标识或服务响应正文。

失败判定：用户名显示完整邮箱、未按 `@` 前缀截取、超过 6 个字符、退出后仍显示用户名、重启后冒用其他用户会员、本机退出后仍可使用 Plus、网络失败清除了可恢复会话，或敏感信息进入日志。

## 用例四：7 天离线租约

步骤：先在线取得有效 Plus 权益并记录签名租约到期时间，然后断网。分别在租约有效期内、租约到期后和系统时间被明显回拨时启动 App 并触发 Plus 方案。

预期：签名租约有效且未超过会员到期日时，可离线使用最长 7 天；租约到期、验签失败、设备绑定不匹配或时间异常时关闭 Plus 访问并回退公开映射。降级不删除用户已保存的方案。

失败判定：使用未签名或已过期状态继续开启 Plus、把 7 天误当作会员有效期延长、失效时删除方案，或仅修改本机偏好即可冒用会员。

## 用例五：Plus 方案与 Free 回退

步骤：为同一按键创建 Plus 方案，分别绑定宿主内置动作、私有组合动作和私有快捷键；再让宿主 payload 无法解码、动作因权限不足失败，或引用的动作不可用。

预期：有效 Plus 状态优先执行方案动作；私有执行器或宿主动作明确返回失败时，继续执行该按键原有公开映射。Free、会员失效和租约失效状态停止方案自动监听、清除当前活动方案并回退，但保留本地方案数据。

失败判定：失败动作被误报成功并吞掉公开映射，Free 可绕过门禁执行 Plus 方案，或降级破坏用户已有映射和方案。

## 用例五 A：内部免费测试模式

步骤：仅注入组合动作与键位方案源码 Package，设置 `SAYALL_TEST_BUTTON_PROFILES_FREE=1`，不设置统一私有构件、会员服务或 AI Package；构建并启动 App，创建和执行一项键位方案。

预期：键位方案页面可直接编辑和执行，不出现开通会员门槛；“会员”和 AI 页面不出现。App 的 `Info.plist` 同时满足 `SayAllButtonProfilesIncluded=true`、`SayAllButtonProfilesTestAccess=true`、`SayAllPrivateArtifactsIncluded=false`，且资源目录不存在 `SayAllMembership_SayAllMembershipUI.bundle`。

失败判定：仍显示会员门槛、测试标记缺失、公开/正式构建意外获得免费权限，或内部免费测试包包含会员资源。

## 用例六：三类遥控入口一致性

分别验证以下入口的单击、双击和长按：

1. 实体 HID 遥控器。
2. Nearby iPhone 与 Apple Watch。
3. Web Remote。

预期：三类入口都先尝试当前有效 Plus 方案；未绑定、无权限、执行失败或不可用时都回到同一个公开映射语义。手机和网页只能触发 Mac 已保存的动作，不能直接下发任意脚本、键盘数据或私有实现参数。

失败判定：任一入口绕过方案、绕过会员、吞掉回退，或不同入口对同一配置产生不一致动作。

## 用例七：页面与升级回滚

步骤：在真实生产窗口最小尺寸 `1020 × 772` 逐一打开“按键方案”和“会员”，并使用截图 harness 在 `800 × 650` 做窄宽压力渲染，检查中英文、浅色和深色；随后从不含私有 Package 的旧版升级到内部构建，再回滚到公开构建。

预期：侧边栏、页头、主要控件和滚动无裁切，中文字号不小于 12pt；升级保留公开按键映射和私有方案数据；回滚后私有入口隐藏，公开按键继续可用，旧版不会解析私有方案文件。

失败判定：页面裁切或空白、升级覆盖公开映射、回滚无法启动，或公开构建开始依赖私有数据格式。

## 日志收集与判断

通过“文件 → 打开日志目录”收集受测时间段。实体 HID 使用现有 HID 动作结果日志；Nearby 和 Web Remote 使用现有 `PHONE REMOTE` 动作结果日志。日志只能记录来源分类、按键、触发方式、稳定动作分类和是否处理成功，不得记录会员凭据、邮箱、服务 URL、方案正文、快捷键内容或宿主 payload。

## 验证边界

- 自动化：验证可选 Package、会员服务配置的私有边界、页面显隐、三类入口接线、宿主 payload 只解码公开动作，以及无私有 Package 时返回公开回退。
- 构建：分别验证无额外 Package、仅免费组合动作、免费组合动作加付费键位方案与会员 Package 的 Debug / Release 编译链接，并验证仅设置付费路径时失败关闭。
- 内部免费测试：验证 `SAYALL_TEST_BUTTON_PROFILES_FREE=1` 必须同时提供两个源码 Package，并拒绝统一私有构件；`scripts/verify-app.sh` 必须检查免费测试标记和会员资源缺失。
- 尚不能由自动化替代：真实会员服务、真实支付、签名与公证安装包、RC001 / RC003、iPhone、Apple Watch、Web Remote、双设备、第三方 App、7 天真实时间跨度、升级与回滚现场。
- 部署：生产会员 API 地址、密钥与支付回调均不在本仓库提交，完成部署前不能把本功能描述为生产可用。

## 2026-10-03 2.0.0 本地会员入口验收

- 同步最新 main 后，会员入口按钮采用“会员功能，点击开通”；键位方案只显示一行提示，非会员的编辑与使用门禁保留。
- 连接页“无线麦SayAll移动端”位于右侧顶部，iOS/Watch/Web 使用普通状态文字与行右侧会员按钮；移除扫码优先和重复会员限制说明。
- 设置页回归 54 项通过（SwiftPM --disable-keychain），无私有组件的公开路径可构建；注入统一私有构件的 2.0.0（229）完整包、资源与 Developer ID 深层签名通过。
- 真实中文深色 Mac UI 已验证上述布局、键位方案/iOS 会员按钮导航和 staging 环境选择，原始截图仅保存于本机构件目录，未向公开仓库提交本机设备信息。最终包已启动并停在连接页。
- 本轮不发布服务器或小程序；真实手机/Watch 配对、音频、支付与退款验收仍按本手册执行，本地 UI 结果不替代这些验收。

## 2026-10-03 2.0.0（230）连接页复验

- Phone / Watch / Web 的“尚未开启”统一为现有较小 caption，iOS 明确优先自动连接无需扫码；二维码为备用。
- 授权弹窗采用当前应用图标，二维码刷新说明允许完整换行；权限与信任逻辑保持既有实现。
- 设置页与图标现有测试共 61 项通过，全部 SwiftPM 使用 --disable-keychain；完整内部包构建、资源与深层签名验证通过。
- 已正常启动精确新包；实际浅色中文连接页验证字号一致、自动连接说明可见，设置仍为测试环境。
- 用户反馈前一测试包：已有 Plus 邮箱登录后功能可用，退出后功能禁用，真机通过。未测试的小程序扫码支付 → Plus 开通 → Mac 自动解锁仍保持待测。
- 授权弹窗图标跟随与已开启二维码说明尚未重新真机触发，不能以编译和 UI 静态检查替代。

## 2026-10-03 2.0.0（232）取码与重新连接复验

- Mac 主区域固定为小程序码预留区域，取码时显示加载提示；网页二维码始终保持较小尺寸。加载和失败文案已提供中英文资源。
- 发现真实临时会话过期后，明确重新连接仍复用旧建会幂等键。失败或已过期状态现创建新会话；尚未完成的同一次建会请求保持幂等。
- 设置页54项回归通过，SwiftPM使用 --disable-keychain；232完整本地包、资源和Developer ID深层签名通过，精确新包已启动并确认当前为测试环境。
- 实际启动界面先显示进度，再显示小程序码，没有先展示大网页码。官方小程序开发者工具经真实临时会话完成凭证交换和连接，App收到配对请求；未批准模拟器遥控，未传音频。拒绝探针后重新连接，得到新会话入口。
- 私有实现、二维码、用户数据和日志仍保存在仓库外。Android/iPhone真机配对、按键、音频与支付后自动解锁仍待测试。
