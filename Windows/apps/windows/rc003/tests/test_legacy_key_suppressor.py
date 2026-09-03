import threading
import time
import unittest

from ovb_rc003 import legacy_key_suppressor_windows as suppressor


class LegacyKeySuppressorDecisionTests(unittest.TestCase):
    def test_right_alt_transform_event_has_one_physical_identity(self):
        target = suppressor.PhysicalKeyTarget(
            vk_code=0xA5,
            scan_code=0x38,
            extended=True,
            system_key=True,
        )

        down, down_message = suppressor.build_physical_key_event(target, True, 123)
        up, up_message = suppressor.build_physical_key_event(target, False, 124)

        self.assertEqual((down.vkCode, down.scanCode, down.flags, down.time), (0xA5, 0x38, suppressor.LLKHF_EXTENDED, 123))
        self.assertEqual((up.vkCode, up.scanCode, up.flags, up.time), (0xA5, 0x38, suppressor.LLKHF_EXTENDED | suppressor.LLKHF_UP, 124))
        self.assertEqual(down_message, suppressor.WM_SYSKEYDOWN)
        self.assertEqual(up_message, suppressor.WM_SYSKEYUP)

    def test_suppresses_configured_non_injected_vk(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        self.assertTrue(gate.should_suppress(0x74, 0))

    def test_does_not_suppress_sendinput_injected_vk(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        self.assertFalse(gate.should_suppress(0x74, suppressor.LLKHF_INJECTED))

    def test_physicalizes_only_marked_right_alt_event(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        event = suppressor.KBDLLHOOKSTRUCT(
            vkCode=0xA5,
            scanCode=0x38,
            flags=(
                suppressor.LLKHF_EXTENDED
                | suppressor.LLKHF_INJECTED
                | suppressor.LLKHF_LOWER_IL_INJECTED
            ),
            time=123,
            dwExtraInfo=suppressor.VOICE_EVENT_EXTRA_INFO,
        )

        self.assertTrue(gate.physicalize_injected_event(event))
        self.assertEqual(event.flags, suppressor.LLKHF_EXTENDED)
        self.assertEqual(event.dwExtraInfo, 0)

    def test_does_not_physicalize_unmarked_or_other_injected_events(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        for vk_code, extra_info in (
            (0xA5, 0),
            (0xA4, suppressor.VOICE_EVENT_EXTRA_INFO),
        ):
            event = suppressor.KBDLLHOOKSTRUCT(
                vkCode=vk_code,
                scanCode=0x38,
                flags=suppressor.LLKHF_EXTENDED | suppressor.LLKHF_INJECTED,
                time=123,
                dwExtraInfo=extra_info,
            )
            original = (int(event.flags), int(event.dwExtraInfo))
            self.assertFalse(gate.physicalize_injected_event(event))
            self.assertEqual((int(event.flags), int(event.dwExtraInfo)), original)


class LegacyKeySuppressorVoiceHotkeyPhysicalizeTests(unittest.TestCase):
    """Real-device acceptance under commit ``e91b9c2`` confirmed that the
    press/release TAP and the HOLD-mode sustained DOWN/UP paths both
    delivered the bridge-injected ``lctrl`` / ``lalt`` edges to the
    foreground application, but Typeless (and every other toggle-style
    target on the supported set) silently dropped every event because
    the events still carried ``LLKHF_INJECTED``.  The hook must drop
    that flag for any VK in the configured voice hotkey so the target
    reacts to the toggle.  The two halves of the physicalize patch are
    a backward-compatible extension of the existing ralt path, so the
    right-alt baseline tests above keep their semantics unchanged.
    """

    def _marked_event(self, vk_code, flags_extra=0):
        return suppressor.KBDLLHOOKSTRUCT(
            vkCode=vk_code,
            scanCode=0x1D if vk_code == 0xA2 else 0x38,
            flags=(
                (suppressor.LLKHF_EXTENDED if flags_extra else 0)
                | suppressor.LLKHF_INJECTED
                | suppressor.LLKHF_LOWER_IL_INJECTED
            ),
            time=123,
            dwExtraInfo=suppressor.VOICE_EVENT_EXTRA_INFO,
        )

    def test_physicalizes_lctrl_when_voice_hotkey_lists_lctrl(self):
        gate = suppressor.LegacyKeySuppressor(
            {0x74}, voice_physicalize_vk_codes=frozenset({0xA2, 0xA4})
        )
        event = self._marked_event(0xA2)
        self.assertTrue(gate.physicalize_injected_event(event))
        self.assertFalse(int(event.flags) & suppressor.LLKHF_INJECTED)
        self.assertFalse(int(event.flags) & suppressor.LLKHF_LOWER_IL_INJECTED)
        self.assertEqual(event.dwExtraInfo, 0)

    def test_physicalizes_lalt_when_voice_hotkey_lists_lalt(self):
        gate = suppressor.LegacyKeySuppressor(
            {0x74}, voice_physicalize_vk_codes=frozenset({0xA2, 0xA4})
        )
        event = self._marked_event(0xA4)
        self.assertTrue(gate.physicalize_injected_event(event))
        self.assertFalse(int(event.flags) & suppressor.LLKHF_INJECTED)
        self.assertEqual(event.dwExtraInfo, 0)

    def test_does_not_physicalize_voice_hotkey_vk_without_marker(self):
        gate = suppressor.LegacyKeySuppressor(
            {0x74}, voice_physicalize_vk_codes=frozenset({0xA2, 0xA4})
        )
        event = suppressor.KBDLLHOOKSTRUCT(
            vkCode=0xA2,
            scanCode=0x1D,
            flags=suppressor.LLKHF_INJECTED,
            time=123,
            dwExtraInfo=0,
        )
        original = (int(event.flags), int(event.dwExtraInfo))
        self.assertFalse(gate.physicalize_injected_event(event))
        self.assertEqual((int(event.flags), int(event.dwExtraInfo)), original)

    def test_does_not_physicalize_unrelated_vk_even_with_marker(self):
        gate = suppressor.LegacyKeySuppressor(
            {0x74}, voice_physicalize_vk_codes=frozenset({0xA2, 0xA4})
        )
        # ``H`` is not part of the voice hotkey and not the legacy ralt
        # physicalize candidate - so the hook must NOT strip its INJECTED
        # flag, otherwise an unrelated screen reader or touch-typing tool's
        # injected ``H`` would silently start looking like a physical key.
        event = self._marked_event(0x48)
        original = (int(event.flags), int(event.dwExtraInfo))
        self.assertFalse(gate.physicalize_injected_event(event))
        self.assertEqual((int(event.flags), int(event.dwExtraInfo)), original)

    def test_empty_voice_physicalize_set_keeps_ralt_path_only(self):
        # An explicitly empty voice_physicalize set must not regress the
        # legacy ralt path - the gate still physicalises the right-alt
        # single-key edge that Doubao depends on.
        gate = suppressor.LegacyKeySuppressor(
            {0x74}, voice_physicalize_vk_codes=frozenset()
        )
        event = self._marked_event(0xA5)
        self.assertTrue(gate.physicalize_injected_event(event))

    def test_ralt_physicalize_unchanged_when_voice_hotkey_set_is_none(self):
        # Default callers never pass voice_physicalize_vk_codes - the
        # original ralt physicalize behaviour must keep working as a
        # baseline.
        gate = suppressor.LegacyKeySuppressor({0x74})
        event = self._marked_event(0xA5)
        self.assertTrue(gate.physicalize_injected_event(event))

    def test_does_not_suppress_unconfigured_vk_codes(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        self.assertFalse(gate.should_suppress(0x5B, 0))  # VK_LWIN
        self.assertFalse(gate.should_suppress(0x48, 0))  # H

    def test_suppressed_physical_edge_is_forwarded_without_forwarding_injected_input(self):
        events = []
        gate = suppressor.LegacyKeySuppressor(
            {0x74}, on_key_event=lambda vk_code, is_pressed: events.append(
                (vk_code, is_pressed)
            )
        )

        self.assertTrue(gate.handle_key_event(0x74, 0, True))
        self.assertTrue(gate.handle_key_event(0x74, 0, False))
        self.assertFalse(gate.handle_key_event(0x74, suppressor.LLKHF_INJECTED, True))
        self.assertEqual(events, [(0x74, True), (0x74, False)])

    def test_armed_raw_input_edge_is_consumed_once_and_only_with_exact_identity(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        gate.arm_key_event(0x26, 0x48, True, True)

        self.assertFalse(gate.consume_armed_key_event(0x26, 0x48, False, True))
        self.assertTrue(gate.consume_armed_key_event(0x26, 0x48, True, True))
        self.assertFalse(gate.consume_armed_key_event(0x26, 0x48, True, True))

    def test_armed_five_is_left_to_the_dedicated_voice_suppressor(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        gate.arm_key_event(0x74, 0x3F, False, True)
        self.assertFalse(gate.consume_armed_key_event(0x74, 0x3F, False, True))


class LegacyKeySuppressorRaceTests(unittest.TestCase):
    """The low-level hook and the Raw Input thread race for the same physical
    press. The consumer must wait briefly for an arming edge that is in
    flight, without blocking ordinary keyboard input."""

    def test_consume_waits_for_an_arm_that_arrives_right_afterward(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        # The hook fires before the Raw Input thread delivers the same
        # physical press, so the arming edge lands a moment later. The
        # consumer must wait for it instead of releasing a double action.
        def raw_input_thread():
            import time

            time.sleep(0.01)
            gate.arm_key_event(0x26, 0x48, True, True)

        thread = threading.Thread(target=raw_input_thread)
        thread.start()
        try:
            matched = gate.consume_armed_key_event(
                0x26, 0x48, True, True, wait_seconds=0.200
            )
        finally:
            thread.join(timeout=2)
        self.assertTrue(matched)
        # The edge is consumed exactly once.
        self.assertFalse(gate.consume_armed_key_event(0x26, 0x48, True, True))

    def test_no_recent_arm_returns_immediately_without_blocking(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        # No RC003 press has been armed recently; the hook must pass an
        # unrelated physical key straight through after the short wait.
        self.assertFalse(gate.consume_armed_key_event(0x26, 0x48, True, True))

    def test_unrelated_key_does_not_wait_for_a_pending_arm(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        gate.arm_key_event(0x26, 0x48, True, True)
        # A different key passing through the hook must not be blocked or
        # consumed just because some RC003 edge is armed.
        self.assertFalse(gate.consume_armed_key_event(0x27, 0x49, True, True))

    def test_key_outside_rc003_set_passes_through_immediately(self):
        gate = suppressor.LegacyKeySuppressor(
            {0x74},
            rc003_vk_codes=frozenset({0x74, 0x26, 0x27, 0x25, 0x28}),
            consume_wait_seconds=10.0,
        )
        # Ordinary keyboard letters are not part of the RC003 surface, so the
        # hook must not wait (or block) for an arming edge at all.
        start = time.monotonic()
        self.assertFalse(gate.consume_armed_key_event(0x4E, 0x31, False, True))
        self.assertLess(time.monotonic() - start, 0.25)

    def test_rc003_key_waits_for_a_late_arming_edge_by_default(self):
        gate = suppressor.LegacyKeySuppressor(
            {0x74},
            rc003_vk_codes=frozenset({0x74, 0x26, 0x27, 0x25, 0x28}),
        )

        def raw_input_thread():
            time.sleep(0.03)
            gate.arm_key_event(0x26, 0x48, True, True)

        thread = threading.Thread(target=raw_input_thread)
        thread.start()
        try:
            matched = gate.consume_armed_key_event(0x26, 0x48, True, True)
        finally:
            thread.join(timeout=2)
        self.assertTrue(matched)

    def test_direct_hid_mode_can_disable_wait_for_overlapping_pc_key(self):
        gate = suppressor.LegacyKeySuppressor(
            {0x74},
            rc003_vk_codes=frozenset({0x0D, 0x26, 0x27}),
            consume_wait_seconds=10.0,
        )
        gate.set_consume_wait_seconds(0.0)

        start = time.monotonic()
        self.assertFalse(gate.consume_armed_key_event(0x27, 0x4D, True, True))
        self.assertLess(time.monotonic() - start, 0.05)

    def test_direct_hid_mode_still_consumes_an_already_armed_edge(self):
        gate = suppressor.LegacyKeySuppressor(
            {0x74},
            rc003_vk_codes=frozenset({0x0D, 0x26, 0x27}),
        )
        gate.arm_key_event(0x27, 0x4D, True, True)
        gate.set_consume_wait_seconds(0.0)

        self.assertTrue(gate.consume_armed_key_event(0x27, 0x4D, True, True))


class LegacyKeySuppressorLifecycleTests(unittest.TestCase):
    def test_empty_suppressor_is_a_noop(self):
        gate = suppressor.LegacyKeySuppressor(set())
        gate.start(_run_target=lambda: None)
        self.assertFalse(gate.is_running)

    def test_rejects_second_start_while_thread_is_running(self):
        gate = suppressor.LegacyKeySuppressor({0x74})
        release = threading.Event()

        def fake_run():
            gate._ready_event.set()
            release.wait()

        try:
            gate.start(_run_target=fake_run)
            with self.assertRaises(suppressor.LegacyKeySuppressorUnavailableError):
                gate.start(_run_target=fake_run)
        finally:
            release.set()
            gate.stop()


if __name__ == "__main__":
    unittest.main()
