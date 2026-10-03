# Remote Mic First-Install Guide

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xiaomi Bluetooth Remote 2 Pro

After opening `Remote-Mic-<version>.dmg`, double-click the only `Install SayAll.pkg`. The installer places SayAll.app in Applications and checks the compatible microphone. New installations use SayAll. A healthy existing MiRemoteV 2ch is kept in place. Repairs and updates keep its old name. Installation stops if the name cannot be determined safely. The installer then restarts the system audio service and launches SayAll for the current desktop user.

Advanced users who need only the app and already use another loopback device such as BlackHole 2ch can download the app-only ZIP from the same Release.

Allow Bluetooth access when Remote Mic first launches. To customize normal buttons, also grant Input Monitoring and Accessibility in the **Permissions** page.
