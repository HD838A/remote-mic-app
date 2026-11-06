# G9N9N 公开后端候选验收

适用：Jieli G9N9N、macOS、公开构建。遵守 [硬件合同](HardwareCompatibilityContract.md) 与
[语音合同](HardwareVoiceAudioContract.md)。构建和协议测试不替代真机结论。

## 实现边界

- G9N9N 与原装 Google 遥控器共用 VID/PID，不能以名字或 VID/PID 判定型号。
  公开桥仅在 ATVV 服务存在、DIS 型号为 `hid_mouse`、厂商为 `zhuhai_jieli` 时订阅语音。
- 公开构建提供独立的 G9N9N 首次设置入口；原装 Chromecast 的隐藏规则保留。
  带私有 Chromecast 包的构建沿用原后端，不同时启动公开桥，仍需该后端独立验收。
- 语音只声明按住模式，动态重组 247 字节 ADPCM 帧，复用宿主虚拟麦克风与输入工具管线。
  不内置第二个语音识别器，也不改用电脑麦克风。
- 普通键通过厂商筛选的原始 HID 报告回调进入现有手势及映射执行器；按实机描述符分别解析键盘/Consumer 报告，释放只清除对应报告的按住状态。映射打开时通过原服务级映射器抑制原生重复投递，
  读回失败不得执行第二份映射；关闭时恢复原映射。原装 Google 的 HID 不被改写。
- 新档案默认确定=Enter、返回=Esc、四方向=方向键；再次注册复用原档案和用户映射。
  品牌键不猜码，在按键页点“识别按键”后短按并松开实体键学习。首次连接收到未识别报告时，也可先识别确定键，再以一次新的真实按键完成检查。15 秒超时、离页、停用或断连退出学习。
- 运行诊断只复用 `AppLogger` 的有界保留，不另建音频、转写或逐帧转储；学习映射最多 32 项。

## 本地构建与启动

SwiftPM 命令必须带 `--disable-keychain`。公开 fork 的本地安装使用原入口：

```sh
SAYALL_LOCAL_PUBLIC=1 scripts/package-local-test-app.sh
```

显式 public 模式不装入私有包；默认模式保持原私有依赖约束。输出是本地测试包，
不是官方发行版。若本机已有开发签名身份，可通过 `SAYALL_LOCAL_SIGNING_IDENTITY` 使用它，避免每次 ad-hoc 构建改变授权身份；该选项不授予分发身份或改变官方发布签名。驱动仍沿 `scripts/build-doubao-driver.sh` 和
`scripts/install-doubao-driver.sh` 构建、校验及安装。

## 真机步骤

1. 退出旧原型。给本次 SayAll 测试包授予系统要求的蓝牙、输入监控与辅助功能权限。
   首次设置选择 G9N9N，按任意键唤醒已配对的遥控器，等待连接就绪。
2. 按三个不同的普通键。首次设置应观察事件并抑制原有映射，不能把“打开 HID 成功”当作收键成功。
3. 选择实际安装的输入工具，将其麦克风选择为 SayAll/同一虚拟设备，按页面要求配置语音触发键。
4. 按住说短句并松开：观察首字、尾字和真实输入框内容。复核同一 generation 的
   `first_pcm`、宿主 `playback_stop`，确认正常排空、pending=0、interrupted=0。
5. 快速连续两句，再说超过 60 秒的长句。确认第二句首字完整、无旧音频串入；长句需看到
   `G9N9N VOICE phase=sustained` 及实际持续上屏。SYNC 若固件未发送，明确记为未观测。
6. 完成设置，打开按键映射，逐键确认 Enter/Esc/方向动作只发生一次。逐一识别并配置品牌、
   电源和信号源等实体键。对系统未发送 HID 的红外键记录不可用，不伪造通过。
7. 切换映射开关、离开识别页面、断开和唤醒重连，确认无卡住按键、录音或遗留原生抑制。

## 当前证据记录

在 PR 中分别记录构建/自动化、实际 UI、权限、实际虚拟音频绑定、最终文字、逐键与长句结果。
缺任何必要真机证据时保留 Draft，不能以历史 G9Voice 原型的识别结果宣称本实现通过。


## HCI 按键通道（本地 fork，需单独启用）

本样机在 macOS 27 上，三权限通过、HID普通打开成功后仍无value/report回调；
原生映射关闭、冷唤醒也无效。此负结果保留，不要求用户继续重置TCC或重复试旧路径。
HCI通道复用宿主现有PacketLogger内存客户端及签名辅助组件，ATVV语音不变。

先以同一开发签名打包本地app，再运行 `scripts/install-local-hci-helper.sh /absolute/SayAll.app`。
安装器只接受同Apple签名团队与固定SayAll标识；不覆盖其他团队的helper。
在首次连接页或按键页明确打开“启用遥控器按键通道”，可随时关闭并恢复配置。

启停live lease可能令其他蓝牙设备短暂重连。按键模式明确关闭HCIFileTraces/RawAudioTrace，
原始流只在有容量上限的内存解析，不保存或上传。缺组件、授权失败、身份不明时显示失败并停止，
不猜测另一设备的按键。必须以当前已准入G9的DIS序列号匹配新读取响应后绑定HCI连接；
两个连接响应相同序列号则停止，断连清除绑定，重连重新核对。

验收需观察：helper准备成功、系统授权完成、身份已核对、实际按键边沿、原生副作用与自定义动作，
最后关闭通道确认helper lease释放且原诊断配置恢复。全量/逐键/HCI handle/ATT型号表仍以本样机实测为准；
公开参考的legacy按键表和attribute `0x002B` 只是候选，不能由代码覆盖宣称全部键通过。
公开参考：[同型号的macOS限制](https://github.com/anyshu/vokie-plugin-chromecast-remote/blob/main/spec/hid-macos-limitations.md)、
[HCI按键方案](https://github.com/anyshu/vokie-plugin-chromecast-remote/blob/main/spec/hci-button-source.md)。


HCI授权交接补充：macOS 27的系统服务在导入external form之后仍查询授权数据库并验证规则。
G9严格路径必须先取得实际grantedRights、提交凭证，收到服务的RequiresAuth=false或合法packet后，
再恢复临时强规则并对上层宣布ready；恢复失败不交付数据。不能在提交之前删除规则，
否则会出现客户端granted/sealed/submitted、系统Error authenticating、无packet的断层。
超时/停止仍释放原lease恢复原配置；Apple旧音频路径保留原默认交接顺序，需独立回归。


## 当前 G9N9N 真机已确认项

- HCI 通道经 DIS 身份绑定后，普通按键已真实进入宿主：方向、确定、返回、主页、静音、
  YouTube、Netflix、电源和音量。右键实际Consumer Usage `0x0045`；信源实际为 `0x0189`，
  保留高字节，不能截为原装表的 `0x0089`。原装值继续兼容，不把 VID/PID 相同当同固件。
- 右/信源学习后均已保存，再次按下产生规范化边沿。学习超时零报告不作为设备永久无能力的结论。
- 豆包 Fn 按住+SayAll 麦克风路径已有真实文字，向导 attempt 终态 passed；两次普通短句正常排空，
  无入队失败、pending=0、interrupted=0。连续/长句与重连结果见下方独立记录。
- 自定义按键开关控制正式动作，首次设置抑制动作；品牌/信源没有配置动作时显示未设置，
  不能把键码已识别与动作已配置混为一谈。


## 本地 fork 验收记录（2026-11-06）

范围为本只 Jieli G9N9N、macOS 27.0.1 arm64、SayAll public 本地包和豆包输入法 1.0.3；
不推导其他固件、Windows、私有 Chromecast 后端或官方发行兼容性。

| 项目 | 实际结果与证据边界 |
| --- | --- |
| 普通键识别 | 上述普通键均收到真实规范化边沿；右键 `0x0045`、信源 `0x0189` 已学习并再次观察 |
| 正式动作 | 自定义按键开启后，用户确认确定=Enter、返回=Esc、右=→，各执行一次且正确 |
| 未配置动作 | YouTube、Netflix、信源事件可读，当前动作未设置；不能报告成已执行某个 App 动作 |
| 首次语音 | 首次设置真实转写通过，终态 passed；两次短句自然排空，样本分别为 43,264 / 85,504，入队失败、pending、interrupted 均为 0 |
| 首 PCM 延迟 | 本地语音日志按硬件触发至首 PCM 记录为 347–363 ms；外部豆包首字未作精确计时，不以向导内部时间代替 |
| 连续会话 | build 17 日志有两次 generation，先前会话排空后下一次启动；用户确认两句首尾完整、第二句无丢首字 |
| 超过 60 秒 | 用户明确确认长段完整、未中途停止；现有机器摘录不能独立证明该长段时长或固件接受 MIC_EXTEND，不把短会话 sustained 标记当成长段证据 |
| 关闭恢复 | build 18 关闭 HCI 后 helper `lease_released active_leases=0`，原诊断配置恢复，无 HCITraces 键；关闭自定义按键后该 G9 UserKeyMapping 恢复为空 |
| 重开与断连恢复 | 自动化覆盖身份重绑、断连和句柄复用；最终关闭后的重新开启仍需系统认证及新鲜设备身份核对，单独记录结果 |

本机最终产品源码为 `ee8be95e14b2a4841f33a9a313f9883a3e7ef0de`（本地 build 18）。
公开全量 1,260 项 / 92 套件、独立 self-test 48 项通过；该 head 的 GitHub 公开测试、
双架构构建和仓库治理均通过。截图证据与真实设备结果分别标注，图片字节不入仓库。

仍未完成实体多设备隔离、另一型号切换、全部按住/双击/长按手势及 Windows 实机矩阵；
本地日常路径通过不能替代这些发布矩阵，不将本包标为官方发布候选。


## 后续回归：连接页重连与录音失效

2026-11-06 用户在 Mac 焦点/Deskflow 场景报告录音键无浮窗，旧 build 18 的“已连接”
不代表新一次 ATVV 会话已经到达；不得沿用 09:33 的旧录音作为本次成功。
连接页重连只调用小米桥的缺陷已确认，修复及原始现场见
[G9N9N 重连目标记录](../Bugs/2026-11-06-g9n9n-reconnect-target.md)。build 19 的该按钮已实测完成 G9 新鲜握手。其后第一句上屏、第二句无响应；正常结束后的宿主清理被误判为取消，见 [第二次语音记录](../Bugs/2026-11-06-g9n9n-second-voice-session.md)，修复后的两句与最终文字待复验。
