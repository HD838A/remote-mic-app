# 侧边栏整体上移与个人中心未登录态截图证据

- 生成方式：`CONFIGURATION=release REQUIRE_SIRI_REMOTE_SIGNING=0 REQUIRE_SAYALL_PRIVATE_ARTIFACT_PACKAGE=1 ./scripts/build-app.sh`，再使用生成的生产 App 内 `SettingsScreenshotRenderer` 离屏入口渲染。
- 逻辑窗口尺寸：`1020 × 772`
- PNG 像素尺寸：`2040 × 1544`
- 语言：简体中文
- 状态：顶部主导航组整体上移到内容区顶部基准；底部“分享”和未登录个人中心入口保持在底部；未登录文案显示“我”。

## 重点截图

- 浅色按键页：`light/mapping-1020x772.png`，SHA-256 `c869cd56b850c2203e7f4de83e84f480fb0ebafce77a4860602ff686025a3ffa`
- 浅色个人中心页：`light/statistics-1020x772.png`，SHA-256 `341be4d6c141d900762920d410288f7a3f3ac3e53342708d4d645d3f4fb3c473`
- 深色按键页：`dark/mapping-1020x772.png`，SHA-256 `6b6237b244afa9ce787aad6cf74e9b45e557a8d8dd2a48f829004f100bfd8382`
- 深色个人中心页：`dark/statistics-1020x772.png`，SHA-256 `b24ecc58da5d79de932c7661480cfb93785b34bba78e7f7b8c4483c81c0bc194`

其余页面截图由同一次渲染生成，覆盖连接、组合动作、键位方案、回眸、设置和会员页。
