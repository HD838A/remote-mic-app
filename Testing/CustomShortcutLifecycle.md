# 自定义快捷键修饰键生命周期测试

## 范围与准备

适用分支：`codex/custom-shortcut-modifier-lifecycle`。现有普通自定义组合无需重新录入。准备具有辅助功能权限的正式签名候选包、真实遥控器、实体键盘、至少两个 App 和两个 Codex 会话。不要用未签名本地构建替换用户安装版本。

## 自动化

```sh
swift test --disable-keychain \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter 'ShortcutLifecycleTests|RemoteButtonsTests'
swift test --disable-keychain --skip-build
SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh
```

事件接收器替身检查协议，无真实按键注入。包含失败后释放、有限重试、下一次调用恢复及日志隐私边界。同步事务没有异步取消/超时状态；不增加按住、延时或重复任务。

## 真实流程

1. 在 Codex 先用实体键盘 Control+Tab/Control+Shift+Tab 建立对照：松开 Control 后确认最近会话。用遥控器分别触发同样配置；预期单击完成选择，无须再按 Return。列表停留、方向错误、切换两次均失败。
2. 自定义 Command+Tab：两个普通 App 间连续切回 20 次，每次单击只切一次，切换器不滞留；重复全屏、多屏场景。内置 Command-Tab 仍应保持选择模式并允许确认退出。
3. Control+Option+主键以及 Shift+Command+主键：与实体键盘对照，目标动作只执行一次。测试普通 Command+C/V 等按下即执行的组合。
4. 测试无修饰 Return/方向键、单独左右修饰键、Fn/Command 语音按下与释放；应保持原行为。
5. 实体键盘先按住 Control，再触发 Control+Tab：不得合成该 Control 的松开，选择可保持到用户实际松键；同时按住 Shift/Option 等附加修饰键时按真实组合语义处理，不强制清除物理状态。重复在触发过程中按下实体修饰键，再手动松开，后续输入不得粘键。
6. 撤销辅助功能权限后不得发送事件；重新授权后复测。事件构造/注入失败只由替身覆盖；真实权限和 WindowServer 拒绝不能用替身成功代替。
7. 重启后旧快捷键仍存在，导入导出保持原格式，不要求重新录入。

## 日志

从 App 的“文件 → 打开日志所在文件夹”收集测试时间段，筛选 `SHORTCUT SEQUENCE`，按 operation_id 配对 requested 和唯一 completed。正常结果为 submitted，失败说明 reason/cleanup_failed；submitted_events 仅证明提交次数，user_visible_result=unknown 不代表测试通过。不得收集输入文本、会话标题、设备标识或私有数据。

## 验证边界

自动化可证明构造出的事件类型、顺序、flags、清理和保存格式回归；不能证明目标 App 接受、WindowServer 实际切换、真正物理按键竞态、Intel 或私有模块整合。真实遥控器、第三方 App、全屏/多屏和权限恢复均待人工验收，因此 PR 保持 Draft。
