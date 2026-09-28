# 内置常用语 / Built-in Common Phrases

> 用途：无线麦SayAll.app 内置常用语的唯一人工编辑源。
> 修改本文件后重新打包，App 内的内置常用语必须随之变化；不得在 Swift 代码里另存一份硬编码列表。

## 机器读取约定

- 构建期由脚本读取下方常用语表，生成 App 实际读取的 JSON 资源；App 运行时不直接解析本文件的散文段落。
- 只有表格数据行是数据来源：`#`、`中文完整句`、`中文短显示`、`English`、`Short Display` 五列都必须非空，`#` 从 1 开始连续且唯一。
- 不得重命名、合并、拆分或调换列顺序；增删行等同于增删内置常用语。
- 表格保持固定的五列，**不得为了标注默认键位而新增列**；默认键位由下方「默认键位」一节单独声明。
- 表格以外的段落只供人工阅读，不进入生成结果。
- 在表格中增删或修改常用语时，必须同步更新下方的「默认键位」「语义覆盖」和「短显示建议」三节，保持条目数量、顺序和内容一一对应。
- 规则：完整句用于实际插入输入框；短显示用于 UI 展示，尽量保持 2–8 个字 / 1–4 个英文单词。

## 常用语表

| # | 中文完整句 | 中文短显示 | English | Short Display |
|---|---|---|---|---|
| 1 | 好的 | 好的 | OK | OK |
| 2 | 继续 | 继续 | Continue | Continue |
| 3 | 看不懂，说清楚一点 | 说清楚一点 | I don't understand. Explain it more clearly | Explain clearly |
| 4 | 按照你的意思做 | 按你的来 | Do it the way you suggested | Follow your lead |
| 5 | 你的思路可以，按照你的思路来，但是我补充一点： | 思路可以，我补充一点 | Your approach works. Let's go with it, but I want to add one thing: | One more thing |
| 6 | 不对吧？为什么？ | 不对吧？ | That doesn't seem right. Why? | Why? |
| 7 | 还有没有别的方案？ | 其他方案 | Are there any other options? | Other options |
| 8 | 如果是你，你会怎么选？ | 你会怎么选？ | What would you choose if it were up to you? | What would you choose? |
| 9 | 总结一下我们刚才的结论 | 总结结论 | Summarize what we just concluded | Summarize |
| 10 | 先别做，告诉我你准备怎么做 | 先说怎么做 | Don't do it yet. Tell me how you plan to approach it | Show me the plan |
| 11 | 你给的方案都不接受，重新考虑 | 都不接受，重新考虑 | I don't accept any of these options. Reconsider | Reconsider |
| 12 | 确认 | 确认 | Confirm | Confirm |

## 默认键位

常用语面板打开时，五个按键各插入一条常用语。这五条由本节**显式声明**，实现不得读取常用语表的行顺序自行推断。

| 按键 | 编号 | 中文完整句 |
|---|---|---|
| OK | 1 | 好的 |
| 左 | 2 | 继续 |
| 上 | 3 | 看不懂，说清楚一点 |
| 右 | 4 | 按照你的意思做 |
| 下 | 5 | 你的思路可以，按照你的思路来，但是我补充一点： |

规则：

- 本节必须恰好覆盖编号 1 至 5：编号有效、互不重复，五个按键各出现一次且不多于一次。
- 常用语表前五行发生变化（增删、调序、改编号或改内容）时，本节必须同步更新，与表格保持一致。
- 编号 6 及以后的条目不进默认键位，只作为内置内容供用户自行选用。
- 构建脚本必须校验本节与常用语表一致；指向不存在的编号、键位重复或数量不为 5 时**构建失败**，不得静默回退到旧数据或按行顺序推断。

## 语义覆盖

> 这里的「方向」指语义方向，**不是遥控器上的方向键**；遥控器方向键的映射见上一节「默认键位」。

1. **确认** — 好的
2. **继续** — 继续
3. **澄清** — 看不懂，说清楚一点
4. **授权执行** — 按照你的意思做
5. **认可 + 补充** — 你的思路可以，按照你的思路来，但是我补充一点：
6. **质疑 + 解释** — 不对吧？为什么？
7. **探索备选** — 还有没有别的方案？
8. **请求判断** — 如果是你，你会怎么选？
9. **总结收敛** — 总结一下我们刚才的结论
10. **先规划后执行** — 先别做，告诉我你准备怎么做
11. **全部否定 + 重新思考** — 你给的方案都不接受，重新考虑
12. **应答确认请求** — 确认

## 短显示建议

如果用于按钮、遥控器或快捷指令，优先显示：

**好的 · 继续 · 说清楚一点 · 按你的来 · 思路可以，我补充一点 · 不对吧？ · 其他方案 · 你会怎么选？ · 总结结论 · 先说怎么做 · 都不接受，重新考虑 · 确认**

英文对应：

**OK · Continue · Explain clearly · Follow your lead · One more thing · Why? · Other options · What would you choose? · Summarize · Show me the plan · Reconsider · Confirm**
