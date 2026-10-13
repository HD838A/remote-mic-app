# Supplemental private settings pages

The public host mounts optional private settings pages using the Objective-C class `SayAllSupplementalSettingsProvider`. `pagesForLocaleIdentifier:` returns dictionaries containing stable ASCII `id`, localized `title` and SF Symbol `systemImage`; `viewForPageID:localeIdentifier:` returns an NSView owned by the private implementation. `-ObjC` retains class registration for static private artifacts.

No URLs, web container, product catalog, business copy or page implementation belongs in the public repository. The provider is independent of account/entitlement state. Private page IDs are namespaced as `supplemental:<id>` and inserted after the membership slot. Missing/older artifacts without the class or selectors return no pages and preserve built-in navigation.

Verify default public build, old private artifact, new artifact, locale switch, system light/dark change, page exit/reentry and two independent registered pages. Reject duplicate or invalid metadata; no recording, permission, audio or login action is triggered by registration. The SettingsScreenshotRenderer interactive mode accepts a namespaced raw section ID for review; page IDs remain fixture/runtime input.

Tests/builds, actual window screenshots, deployment and physical-device results must be recorded separately. No runtime trace logging is added.
