# 个人中心日历按行读取连续日期，导致星期标签与日期错位

- 时间：2026-09-29
- 状态：候选修复；自动化、Release App 与生产截图验证通过
- 关联：Issue #444
- 影响范围：macOS 设置页“个人中心”的最近半年日历

## 复现

在 1.9.21（175）的个人中心查看使用日历。用户截图显示方块日期顺序错误，左侧星期标签与对应日期错位；底部内容重叠是另一项已由 PR #483 修复的问题，本次不重复修改。

正确行为是每一列表示同一周，七行从星期日到星期六；日期随列向右递增。

## 日志

现有运行日志没有统计页静态布局事件。该问题不涉及请求、设备、音频或异步结果，无法通过运行日志进一步缩小范围；本次没有为纯显示索引增加高频日志。

## 根因

`statisticsCalendarDays` 按时间顺序生成数据，并补齐为星期日开头的连续七天周块。月份标记也按 `column * 7` 读取每周数据，但方块网格使用了 `row * columnCount + column`，把连续日期横向排在同一星期行；同时星期标签又被单独旋转成星期一开头，造成方块顺序错误且标签整体错一行。

先加入回归断言并运行，旧实现稳定失败，明确要求网格使用“周列 × 7 + 星期行”的索引。

## 修复

仅将日历单元格索引改为 `column * 7 + row`，并让星期标签保持 `DateFormatter` 的星期日到星期六原始顺序。不改统计数据格式、日历范围、面板布局、滚动行为或底部排行榜。

## 验证

- 修复前：`swift test --disable-keychain --filter SettingsPageRegressionTests/profileMetricsKeepApprovedWideSingleRowLayout` 失败，指出旧实现缺少正确的周列索引。
- 修复后：同一回归通过；完整 `SettingsPageRegressionTests` 46/46 通过；`swift test --disable-keychain --parallel --num-workers 1` 共 731/731 通过；项目自检 48/48 通过。
- Release App：使用仓库原生 `scripts/build-app.sh` 与独立持久构建缓存完成 Release 构建，`scripts/verify-app.sh dist/SayAll.app` 通过。
- UI：从 Release App 的生产 `SettingsView` 生成并逐张检查 `1020 × 772`、`800 × 650` 浅色与深色截图，保存在 `Testing/artifacts/profile-statistics/bugfix-20260929/`。四张 PNG 均已验证格式、像素尺寸和 SHA-256；1020 宽度完整显示日历，800 宽度保留横向滚动，星期顺序均为星期日至星期六。
- 边界：离屏截图和自动化只能证明索引与静态布局；真实窗口点击日期并跳转回眸仍需人工验收。
