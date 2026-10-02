# Environment selection UI evidence

Captured on 2026-10-02 from production `WebRemoteSessionView` at private component
commit `4b3c4156fe6083570acf54e800993dbc041dbdc9`, with localization resources
from public host commit `e205d9ba8f5fdb6428d220099c096214262e5c9f`.

The unchanged production component runs in an NSWindow/NSHostingView harness:
440×680 pt (the component's fixed size), 880×1360 px PNG output, English and
Simplified Chinese, light and dark. These are component runtime screenshots,
not screenshots of a packaged App or the complete 1020×772 settings window.
They do not prove settings navigation, real WeChat scanning, membership
authorization, microphone capture, or end-to-end voice/text output.

All data is synthetic. The solid blue square is a fake network image for
release-response detection, not a real mini program code. URL QR codes contain
only example.invalid and synthetic session/token values. No credentials,
accounts, device identities, local paths, or private implementation files are
included.

- `staging`: pending trial response, URL QR fallback, no bypass switch.
- `production`: release image after switching the same model's environment.
- `production-plus`: QR remains visible alongside the Plus notice.
- `disconnected`: old QR cleared; reconnect action visible.

A deliberately late trial response was also checked for each language/appearance.
The before/after production PNGs had identical SHA-256 hashes, so duplicate
images are not committed. Original bytes were copied without resizing,
redrawing or recompression. Each committed image was visually reviewed and
verified as PNG/880×1360; all are below 5 MB. The temporary harness remains
outside version control and is not a required product or CI entrypoint.

| Image | SHA-256 |
| --- | --- |
| [disconnected-en-dark.png](disconnected-en-dark.png) | `a5561962600f8a15ac4c110bf10e2a337d5dff3aeeac746d3d35590ce85a92d9` |
| [disconnected-en-light.png](disconnected-en-light.png) | `2563ac29e3570c65ad05a693df22f983e36126042c4ab28e98a96e2ec765226d` |
| [disconnected-zh-hans-dark.png](disconnected-zh-hans-dark.png) | `558a0211727ff8b48f45fa7dd7af92bae9d85174d28a8d4eba33403607375ebf` |
| [disconnected-zh-hans-light.png](disconnected-zh-hans-light.png) | `948ca286c37cb7b8fca780df59044ffad815e23a7fd4a46782348358e0f39980` |
| [production-en-dark.png](production-en-dark.png) | `155d966b11ce9de96f6e20ace343c57345d3bce9061734a4dd27395bf34720f8` |
| [production-en-light.png](production-en-light.png) | `2294a345cb6927896418c987519b094de7cad12445cae88459a9b9630614f6cd` |
| [production-plus-en-dark.png](production-plus-en-dark.png) | `e35eca7a81dca4557f3deb83e3aff58fc77f194203095a9f1d0ad5bc99c2eccb` |
| [production-plus-en-light.png](production-plus-en-light.png) | `b00e7044c4311f5202c7b7ab78c7dfd85eaddde816eb656f3f690f2fdbae7fe8` |
| [production-plus-zh-hans-dark.png](production-plus-zh-hans-dark.png) | `1dd025a056424ee9c7882c840acfb04e7cc99163b5ab7db4e67285499e6ce48f` |
| [production-plus-zh-hans-light.png](production-plus-zh-hans-light.png) | `26c8cb932a3368d2753fe7f799946fc1c9975798e9655e67638f17250fb377c6` |
| [production-zh-hans-dark.png](production-zh-hans-dark.png) | `02bc8021747aadbd0c5cb2f65ff31bd3caa174fc093ab3fd2e98d759f1b69950` |
| [production-zh-hans-light.png](production-zh-hans-light.png) | `f1e8a6cbac4a70d390dfbcdcced9c4b127f0d537ab20d6df4fc8601bd74cf260` |
| [staging-en-dark.png](staging-en-dark.png) | `9499f1f4e65d9d2a53527872a3fd80b1829bab02aee4660ecc0c1c55b9b920f7` |
| [staging-en-light.png](staging-en-light.png) | `2b3e8b8647efb120d1965be1acc247eb1d0ede06920af6255d596b7bab75f261` |
| [staging-zh-hans-dark.png](staging-zh-hans-dark.png) | `304ea47922110db794c5529bc5a1a46a4618cc855d478f161ced232258758781` |
| [staging-zh-hans-light.png](staging-zh-hans-light.png) | `c0f294f2b7bce4526c5eacadcfb1cca003241200c51d6a8304af303fb602d88e` |
