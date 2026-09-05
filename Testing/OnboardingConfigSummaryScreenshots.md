# Onboarding 语音测试页配置核对卡截图证据

## 适用范围

- 分支：`codex/onboarding-voice-test-config-summary-20260905`
- 截图日期：2026-09-05
- 渲染来源：生产 `OnboardingView` 的锁屏离屏截图入口，不是设计稿或重绘图
- 窗口内容尺寸：`1020 × 772`；PNG 尺寸：`2040 × 1608`

## 覆盖矩阵

截图证据目录（本地生成目录，因仓库二进制资产门禁不提交 PNG）：

`/Users/andy/Develop/Src/AISrc/.worktrees/open-voice-bridge-onboarding-config-summary-20260905/.codex-screenshots/onboarding-config-summary-20260905-v2`

| 路径 | 浅色 | 深色 | 页面数 |
| --- | ---: | ---: | ---: |
| 实体遥控器 | 9 | 9 | 18 |
| iPhone App | 10 | 10 | 20 |
| 网页版 | 10 | 10 | 20 |
| 豆包语音测试页专项 | 1 | 1 | 2 |
| 微信输入法语音测试页专项 | 1 | 1 | 2 |
| Typeless 语音测试页专项 | 1 | 1 | 2 |
| 其他语音工具语音测试页专项 | 1 | 1 | 2 |

完整目录共生成 112 张 PNG；实体、iPhone、网页三种控制方式的完整流程分别逐张检查，专项页面用于核对不同语音工具的配置卡分支。

## 关键页面检查结论

- 豆包：显示无线麦发送键、SayAll 音频输出、豆包语音识别键、豆包“全局唤起语音”和麦克风确认项。
- 微信输入法：显示长按 Fn/地球键和同一音频设备麦克风确认，不显示不适用的豆包全局唤起项。
- Typeless：显示点按 Fn 开始/结束和同一音频设备麦克风确认，不显示豆包全局唤起项。
- 其他语音工具：显示长按 Fn/地球键，并明确要求工具支持语音输入、用户自行配置麦克风。
- 音频设备存在但未就绪时显示红色“未就绪”，不会被误显示为绿色通过。
- 浅色页面保持浅色左右视觉体系，深色页面保持深色左右视觉体系；配置卡、输入框、实时检查和底部继续按钮均未裁切。

## 代表性文件校验

以下为不同工具与控制方式的语音测试页 SHA-256，便于 PR 审查者核对本地证据：

```text
e96f026520db87fd896bc82a8052e0db47dd57c2fcad1d3a6f13fb6699c0f1dc  tools/weixin/light/07-voice-test.png
f4b5e4c7db21b122b98fd20034a331b109115cb6d1cd0946924f00163e6d23b3  tools/weixin/dark/07-voice-test.png
c638d543c01b1c8cfed89a8f68182c6a97397b5ef1a68b8edb3a10161ac6f469  tools/typeless/light/07-voice-test.png
6fe05dc0b73fd5bd2bf80ffa3e74a563671000ccf526345ce98dcfb7bdd7d626  tools/typeless/dark/07-voice-test.png
98690cde071a1859badedb36f29efe126c38a822375646b2326bb5a4917c7fef  tools/other/light/07-voice-test.png
78266d6701f2a2d16a2f9a3938fc78f877479629d781e373ac478f67b184fe6b  tools/other/dark/07-voice-test.png
1320f3d80bb7da46ce02edf1780a53c5cd4946a11fcbfe51240ef79f229ca8b7  web/light/08-voice-test.png
98b4171180b56c331cfa4ea60895054f1bf25b79be558b80381df0d32622dc45  web/dark/08-voice-test.png
```

截图只能证明生产视图的静态布局和文案分支；不能替代真实遥控器、虚拟音频设备、系统权限或第三方语音工具的麦克风与文字上屏验收。
