# 映射页自绘选中按钮无悬停/焦点反馈、容器宽度与其他页不一致

## 复现

- 环境:macOS 27,系统「全键盘控制」开启;`dist/SayAll.app` 调试构建。
- 操作:「按键」页用鼠标悬停遥控器设备卡、动作网格、聚焦策略与自定义 App 选择;用 Tab 键移动焦点;对比「连接/权限/关于」页内容宽度。
- 实际结果:四类选择按钮全部是 `.buttonStyle(.plain)` + 自绘 `accentColor.opacity` 底与描边,悬停无反馈、键盘焦点环不可见;映射页内容最大宽 920pt,其他 grouped Form 页统一 700pt;编辑面板出现/消失无过渡;关系图按键卡选中状态未暴露给辅助功能。
- 预期结果:选择按钮有统一悬停与焦点反馈;内容列与其他页一致;编辑区有系统式过渡;选中状态可被 VoiceOver 读取。

## 日志结论

纯界面交互问题,无专用日志。

## 根因

- 映射页四处选择按钮各自手写选中底与描边,从未实现 hover/focus 状态;页面容器沿用早期 920pt;编辑区直接按 `mappingEditingTarget` 条件挂载,没有过渡修饰;关系图按键卡只有 `accessibilityLabel`。

## 修复

- 新增文件内私有 `SelectableCardButton`:`.plain` 按钮 + 低透明度语义蓝选中态(0.13)+ 悬停加深(0.08)+ 2pt accent 焦点环 + `.isSelected` trait;设备卡(10pt 圆角)、动作网格、聚焦策略、自定义 App 选择(8pt 圆角)四处统一替换,删除各自手写 background/overlay。
- 映射页内容列 920pt → 700pt;关系图画布按 `GeometryReader` 自适应(卡宽 250→245pt),遥控器比例、64pt 模块与连接线不变。
- 编辑面板加 `.transition(.asymmetric(insertion: .opacity + .move(.top), removal: .opacity))`,容器按编辑目标有无做 0.2 秒系统动画。
- `RemoteMappingCanvas` 按键卡补 `.accessibilityAddTraits(selected ? .isSelected : [])`。

## 验证

- 修复前:四处自绘选中底、无 hover/focus;920pt 容器。
- 修复后结构门禁:`SelectableCardButton` 声明与 4 处调用、700pt 容器断言;31 项定向测试、344 项全量测试、成品构建与完整性校验通过。
- 真实窗口「按键」页(遥控器已连接、60% 电量)设备卡全宽选中态正常;中文浅色/深色、英文 `800 × 650` 映射页离屏渲染无裁切、连接线落点不变。

## 验证边界

悬停与焦点环的动态呈现、Tab 焦点顺序未做代理实测(无辅助功能权限),按测试手册人工复核;真实遥控器按键触发与映射执行不在本轮范围。
