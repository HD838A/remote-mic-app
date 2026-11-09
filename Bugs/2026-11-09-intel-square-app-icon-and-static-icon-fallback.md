# Intel 包在「应用程序」和启动台里不是圆角，退出 App 后图标又变回几何鸭

- 时间：2026-11-09
- 状态：已修复（候选，等待 Intel 真机复验与覆盖安装缓存验收）
- 影响范围：macOS；Apple Silicon 与 Intel 两个发布变体的静态包图标，以及运行时图标默认值与资源缺失回退
- 功能点：App 图标资源、打包脚本、发布校验、设置页「通用 → 应用图标」
- 简单描述：Intel 包在 Finder「应用程序」列表和启动台中显示的是方形黑底图标而不是圆角；托盘（Dock）里已经换成彩色鸭，但 App 退出后 Finder 和启动台又显示回几何鸭。
- 原始记录：用户现场反馈（微信截图 + 本机剪贴板截图），针对 `~/Downloads/SayAll-intel/SayAll.app`（build 336，x86_64）。

## 现场证据

两张截图指向同一个静态图标问题：

1. Finder「应用程序」列表面板：红框内「无线麦 SayAll.app」是方形黑底白鸭图标。
2. 启动台网格：右下「无线麦 SayAll」是**硬边黑色方块 + 白色几何鸭**，周围其他 App 全部是圆角。

同时用户反馈：Dock（托盘）中的图标已经改成彩色鸭，但**退出 App 以后又变回几何鸭**。

对用户安装包做逐字节取证，结果如下：

| 路径 | SHA-256 | 结论 |
| --- | --- | --- |
| `SayAll.app/Contents/Resources/AppIcon.icns` | `faeaede5b238bd8e0dd8142c65e25686f7927b8388dcfd28b9d58e0688d7e66f` | **方形不透明黑底**，且是 `CFBundleIconFile=AppIcon` 唯一命中的文件 |
| `SayAll.app/Contents/Resources/AppIcon-intel.icns` | `2862f7405887d4722e32866fad3e22951086f620f4fe3afffdbd13cf97684977` | 圆角透明版，但**闲置**（`CFBundleIconFile` 只认 `AppIcon.icns`） |

仓库侧资产：

| 路径 | SHA-256 | 结论 |
| --- | --- | --- |
| `Resources/AppIcon.icns` | `faeaede5…` | 方形不透明黑底（alpha 包围盒 `0x0+1024+1024`，四角 `srgba(21,22,23,1)`） |
| `Resources/AppIcon.png` | `3061fdc5…` | 同上，全画布不透明 |
| `Resources/AppIcon-intel.icns` | `2862f740…` | 圆角透明，十档图层齐全 |
| `Resources/AppIcons/faceted-duck.png` | `569101…` | **本身就是圆角黑底**（alpha 包围盒 `1011x1024+0+0`） |
| `Resources/AppIcons/standard.png` | `356044…` | 彩色经典鸭，四角透明（alpha 包围盒 `902x964+86+32`） |

关键判断：`Resources/AppIcons/faceted-duck.png` 本身已经是圆角的，所以「要不要圆角」从来不是资产问题，**是打包时写进了方形版**。

## 根因

两个缺陷叠加，分别对应用户的两句话。

### 一、静态包图标不圆角：包内同时存在两份 ICNS，`CFBundleIconFile` 命中了错的那份

`Resources/Info.plist` 固定 `CFBundleIconFile = AppIcon`，macOS 只会去包内找 `AppIcon.icns`。

- `scripts/build-app.sh` 正式发布路径**是对的**：它按架构用 `ditto` 只覆盖写入唯一正确的 `AppIcon.icns`，不把 `AppIcon-intel.icns` 带进包。实测 `dist/intel/SayAll.app` 内 `AppIcon.icns` 的 SHA-256 = `2862f740…`（正确）。
- `scripts/package-local-test-app.sh` 是 `AGENTS.md` 指定的**唯一本地测试包入口**，它用整目录 rsync 拷贝资源：

  ```bash
  rsync -a --exclude Info.plist Resources/ "$APP/Contents/Resources/"
  ```

  于是 `AppIcon.icns` 与 `AppIcon-intel.icns` **一起进包**，`AppIcon.icns` 命中方形黑底版，`AppIcon-intel.icns` 形同虚设。用户的 Intel 包正是这样产出的（仓库外手工组装流程的资源拷贝方式与此同构）。

这一条解释了「应用程序」和「启动台」里的方块图标：Finder 与启动台读的是**静态包图标**，与运行期无关。

### 二、退出后又变回几何鸭：运行时覆盖不影响静态图标，而运行时默认本来就是几何鸭

`AppIconController` 通过 `NSApplication.applicationIconImage` + `NSImage.applicationIconName` + `dockTile.display()` 做运行时覆盖。这套机制**只影响 Dock、应用切换器和原生弹窗**，完全不改变 Finder 与启动台读取的静态包图标。

所以 App 运行时看到彩色鸭、退出后看到几何鸭，是两个来源：运行期是覆盖后的经典鸭，退出后是静态包图标里的几何鸭。

而静态包图标当时是方形黑底的几何鸭（`Resources/AppIcon.icns` 就是 `faceted-duck` 的方形版），于是用户看到的是「方块 + 几何鸭」。

再往下一层，运行时默认与回退也都是几何鸭：

- `AppSettings` 的 `appIconIdentifier` 默认值是 `AppIconIdentifier.facetedDuck`；
- `AppIconCatalog.resolvedIdentifier(for:)` 在目标标识不可用时**优先回退** `facetedDuck`。

即使静态包图标修好，只要运行时默认仍与静态包图标不一致，退出后仍会出现「运行期和退出后不是同一个鸭」。

## 修复

### 静态包图标统一为「经典鸭」圆角透明 ICNS

不重新绘制素材，而是**恢复仓库历史上真机验证过的那一份资产**：

```
git checkout 689e17b0^ -- Resources/AppIcon.icns Resources/AppIcon.png
```

`689e17b0^`（v2 几何鸭上线之前）的包图标就是「经典鸭」，且其 ICNS 的 1024 图层与 `Resources/AppIcons/standard.png` **逐字节相同**（SHA-256 `356044…`）。这证明「经典鸭作包图标」是仓库既有先例，而不是本轮新造的方案。

改完后：

- `Resources/AppIcon.png` 与 `Resources/AppIcons/standard.png` 逐字节相同；
- `Resources/AppIcon.icns` 十档图层齐全（16/32/64/128/256/512/1024 + @2x），**全部四角透明、中心不透明**；
- 删除架构分叉资产 `Resources/AppIcon-intel.icns` 与 `Resources/AppIcon-intel.png`；
- `Resources/AppIcons/faceted-duck.png` 保留，只作为设置页的运行时图标选项。

### 打包与校验脚本去掉架构分叉

- `scripts/build-app.sh`：删除 `ICON_ICNS_RESOURCE` 的架构分支，两个变体统一复制 `Resources/AppIcon.icns`。
- `scripts/package-local-test-app.sh`：rsync 显式排除 `AppIcon-*.icns` 与 `AppIcon.png`，保证包内只有唯一一份静态图标。
- `scripts/verify-app.sh`：
  - 取消按架构切换图标来源，统一校验仓库 `Resources/AppIcon.icns`；
  - 静态图标角检查固定为**四角透明、中心不透明**（原来 Apple Silicon 分支要求四角不透明）；
  - 新增门禁：包内 `Contents/Resources` 下除 `AppIcon.icns` 外**不得存在任何 `AppIcon*` 普通文件**，直接堵死「两份 ICNS 并存」这条复发路径。

### 运行时默认与回退对齐静态包图标

- `AppSettings`：`appIconIdentifier` 默认值由 `facetedDuck` 改为 `standard`；
- `AppIconController.resolvedIdentifier(for:)`：目标标识不可用时回退顺序由「优先几何鸭」改为「优先经典鸭」。

这样即使运行期选了「几何鸭」，退出后回到静态包图标也仍是「经典鸭」，两端至少是同一个可预期的 Duck，而不是「方块几何鸭 vs 彩色鸭」。

## 验证

- `swift test --filter 'BuildSigningTests|AppIconControllerTests|settingsPageUsesAnInlineAppIconPickerWithoutUnavailablePlaceholders'`：图标相关用例全部通过。
  - `appIconUsesOneSharedRoundedStaticAsset` 覆盖：母版 1024×1024 且四角透明中心不透明、母版与 `AppIcons/standard.png` 逐字节相同、ICNS 十档图层尺寸集合为 `{16,32,64,128,256,512,1024}` 且每档四角透明、ICNS 的 1024 图层与母版**逐像素一致**、`AppIcon-intel.*` 已下线、发布脚本与本地打包脚本不再残留分叉逻辑。
  - `appSettingsPersistTheSelectedIcon` 覆盖默认值为经典鸭；`catalogOnlyOffersImagesThatAreActuallyAvailable` 覆盖缺失标识回退经典鸭。
- 反向验证：把 `resolvedIdentifier` 的回退顺序改回几何鸭、用例变红；把母版换回不透明方形版、用例变红。
- 未覆盖（需要真机）：
  - 真实 Intel Mac 上 Finder「应用程序」列表与启动台的实际显示；
  - 覆盖安装旧包后的图标缓存刷新；
  - `Bugs/2026-10-05-macos-app-icon-system-wrapper.html` 记录的「Intel Finder/Quick Look 会在透明圆角 ICNS 外再绘制白色圆角底板」风险，本轮未在真机复验，仍按未闭环处理。

## 验收要点

1. 全新安装（不是覆盖安装）后，Finder「应用程序」列表与启动台中的「无线麦 SayAll」均为**圆角**图标，四角透明，无方形底板、无白色底板。
2. Dock 中可切换经典鸭 / 几何鸭，两种都是圆角；退出 App 后 Finder 与启动台的静态图标保持为经典鸭，不出现几何鸭方块。
3. 两架构（Apple Silicon / Intel）包内 `Contents/Resources` 只有一份 `AppIcon.icns`，且与仓库 `Resources/AppIcon.icns` 逐字节一致。
4. 覆盖安装旧版本后图标仍需刷新为圆角；若 macOS 沿用旧图标缓存，需在真机确认缓存刷新路径。
