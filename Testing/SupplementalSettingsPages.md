# Supplemental private settings pages

The public host mounts optional private settings pages using the Objective-C class `SayAllSupplementalSettingsProvider`. `pagesForLocaleIdentifier:` returns dictionaries containing stable ASCII `id`, localized `title` and SF Symbol `systemImage`; `viewForPageID:localeIdentifier:` returns an NSView owned by the private implementation. `-ObjC` retains class registration for static private artifacts.

No URLs, web container, product catalog, business copy or page implementation belongs in the public repository. The provider is independent of account/entitlement state. Private page IDs are namespaced as `supplemental:<id>` and inserted after the membership slot. Missing/older artifacts without the class or selectors return no pages and preserve built-in navigation.

Verify default public build, old private artifact, new artifact, locale switch, system light/dark change, page exit/reentry and two independent registered pages. Reject duplicate or invalid metadata; no recording, permission, audio or login action is triggered by registration. The SettingsScreenshotRenderer interactive mode accepts a namespaced raw section ID for review; page IDs remain fixture/runtime input.

Tests/builds, actual window screenshots, deployment and physical-device results must be recorded separately. No runtime trace logging is added.

## 顶部区域回归

1. 在 `1020 × 772` 生产窗口打开一个已注册私有页面。
2. 核对页面延伸到标题栏顶部，没有空白条。
3. 切换到普通设置页，再返回私有页面。
4. 在中英文、浅色和深色下重复检查。

预期：挂载容器覆盖完整窗口高度；页面自己的内容仍由私有实现布局；其他页面导航和窗口尺寸不变。

失败判定：页面顶部出现额外 32pt 空白、返回后内容裁切，或窗口尺寸改变。

自动化用例使用真实 NSWindow 和通用 NSView 提供器，证明宿主挂载几何。嵌套私有 NSHostingView 还须在私有消费者内验证，不能由这个测试替代。
