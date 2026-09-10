# Agent switcher screenshots

Production UI source commit: `d83037f221249236b66f2ee300b547bcea8a97ac`.
Build: SayAll 1.9.21 (174), local Apple Silicon Debug app, ad-hoc signed.
Date: 2026-09-10.

`runtime-*.jpg` are unmodified CUA captures of the running production app, opened from the button-mapping editor and its Preview Switcher button. They are JPEG bytes returned by the native capture API, not redraws. Only the SayAll window or panel was captured. The system appearance was temporarily changed for light-mode coverage and restored to Dark.

| File | Captured pixels | State |
| --- | --- | --- |
| [runtime-settings-zh-light.jpg](runtime-settings-zh-light.jpg) | 1015×768 | Chinese light settings, Cursor/Codex selected |
| [runtime-settings-zh-dark.jpg](runtime-settings-zh-dark.jpg) | 1015×768 | Chinese dark settings |
| [runtime-zh-light.jpg](runtime-zh-light.jpg) | 420×158 | Runtime panel under Light system appearance |
| [runtime-zh-dark.jpg](runtime-zh-dark.jpg) | 420×158 | Runtime panel, Cursor selected |
| [runtime-zh-dark-codex.jpg](runtime-zh-dark-codex.jpg) | 420×158 | Runtime panel after Right selects Codex |
| [runtime-empty-zh.jpg](runtime-empty-zh.jpg) | 420×158 | Only an uninstalled target selected; empty state |
| [harness-settings-en-light-980x732.png](harness-settings-en-light-980x732.png) | 980×732 | Separate production SettingsView harness at minimum content dimensions, English/light |

The panel uses the system HUD material, which can remain dark under Light appearance. Runtime keyboard Right/Return confirmed Codex as frontmost, and Escape cancelled after repeated openings. The empty-state test selections were restored to Cursor/Codex.

The English image is a harness rendering with isolated test settings; it does not establish real-window English or hardware acceptance. Real remote input remained unavailable because the development app lacked Input Monitoring permission. See [the acceptance guide](../../Testing/AgentSwitcher.md) for remaining checks.
