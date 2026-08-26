# 千问遥控语音误拒绝搜索框和代码编辑器

- 时间：2026-08-26
- 状态：候选修复完成，自动化通过，等待 RC003 真机复验
- 影响范围：千问兼容模式；Spotlight、Launchpad、飞书搜索和 Sublime 等已聚焦输入位置
- 简单描述：电脑键盘直接触发千问可以正常输入，但遥控器长按会被 SayAll 主动关闭麦克风并转入聊天输入框聚焦，导致搜索框和编辑器无法开始语音。

## 复现与日志

- Spotlight、飞书搜索和 Sublime 均在真实 RC003 会话中复现。
- 失败链路为 `QIANWEN COMMAND UP → ATVV MIC_CLOSE request → QIANWEN FOCUS requested`；Spotlight 和 Sublime随后记录 `composer_not_found`。
- 同期 MiRemoteV 音频状态正常，其他聊天输入框可完成 `ATVV STREAM accepted → QIANWEN CONFIRM F20`，排除千问快捷键、蓝牙和音频设备故障。

## 根因

- `VoiceInputDestinationSnapshot.isSafeEditableDestination` 把 `search / find / filter / 搜索 / 查找 / 筛选` 与密码、密钥等真正敏感字段放在同一个拒绝列表。
- 该判定还只接受三个标准文本角色；Sublime 等使用自定义 Accessibility 角色、但公开可编辑文本属性的编辑器被误判。
- 千问模式将误判结果当作“当前没有输入位置”，因此中断本次语音并调用只面向聊天输入框的自动聚焦。

## 修复

- 继续拒绝系统保护内容、Secure Text Field、密码、密钥、令牌和信用卡字段。
- 允许搜索、查找、筛选、地址栏、设置字段和代码编辑器接收用户主动长按发起的语音。
- 使用 macOS 原生 Accessibility 可写属性判断自定义角色是否真实支持文本编辑，不增加 App 白名单。
- 短按自动聚焦仍使用原有聊天输入框候选规则，不会自动点击搜索框或代码区。

## 验证边界

- 自动化覆盖英文/中文搜索字段、自定义可编辑角色、非可编辑控件和敏感字段。
- 仍需在最终安装包中分别复验 Spotlight、Launchpad、飞书搜索、Sublime 编辑区，以及密码框不启动千问。
