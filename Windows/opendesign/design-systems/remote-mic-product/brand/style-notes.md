# Visual foundations

- Window baseline: 900 × 680, minimum 820 × 620.
- Navigation: 120 px rail, icon above label, 12 px outer inset, 14 px item radius.
- Content: 28 px horizontal inset; 28–32 px page title; 20 px gaps between major groups.
- Cards: white or system surface, 18 px radius, subtle border; shadow only where supported without harming dark mode.
- Type: Segoe UI Variable first, Microsoft YaHei UI fallback. Chinese text is 12 pt or larger. All enabled text uses the fully opaque Windows system foreground colour; express hierarchy with size and weight instead of lighter grey copy. Only disabled controls may use reduced opacity.
- Selection: Windows semantic accent blue on a low-opacity fill. Success, warning and error colors only describe real states.
- Motion: 120–180 ms for selection and hover; no decorative motion.
- Controls: primary action is blue; secondary actions use neutral system controls. Keep related settings on the page.
- Dark mode: derive window, surface, text and border values from the OS palette. Fixed semantic colors must maintain contrast.
- Imagery: use the real RC003 product image at its original aspect ratio; never redraw or distort it.
- App icon: use the shared blue rounded-square microphone mark for the title bar, executable, taskbar, shortcuts and installer. Preserve a clear white silhouette at 16 px.
- Device menus: present one row per logical playback device. Hide host-API jargon and prefer WASAPI internally; never ask users to choose between MME, DirectSound, WASAPI and WDM-KS copies of the same device.
- Usage statistics: use a Monday-aligned 53 × 7 daily heatmap. Let users switch between voice duration and physical-use frequency; count one held button as one press, not its Raw Input repeats.
- Statistics privacy: persist daily aggregates only (date, button presses, voice sessions and voice seconds). Never store audio, recognized text, app names, device identifiers or per-event history.
- Diagnostic results use two stable rows: status dot plus title first, then the full wrapped status/detail copy. Both rows contribute their implicit height; never place a fixed-width title beside variable Chinese or device-status content.
- Diagnostic titles and neutral details use the same Windows system foreground colour and regular weight. Reserve bold for section headings and semantic colours for the status dot or explicit success/warning/error state.
