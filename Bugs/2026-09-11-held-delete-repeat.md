# 长按退格只删除一次

手势识别器在 550 ms 后发出一次 longPress；processGestureCommands 执行动作后未启动重复任务，因此一直按住也只有一次退格。

对 longPress 的 deleteBackward 复用 repeatTimers：首次执行后每 150 ms 重复一次。松手、断连、停止、权限失效沿用既有取消路径；前台 App 或映射变化、动作失败也停止。其他长按和语音路径不变，私有覆盖动作不自动重复。

回归 heldDeleteRepeatsAtFixedRateAndStops 使用模拟 HID 报告与确定性调度器，覆盖速率以及六种停止条件。未接入重复调用时六种用例均失败（计数 1，期望 3），接入后通过。没有发送实体删除事件。

实体测试：Testing/HeldDelete.md。
