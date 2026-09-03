"""Exercises win32_input.py's batching/rollback logic with an injected fake
``_sender`` callable, so it runs on any OS without needing ``ctypes.windll``
(which does not exist off Windows) - see the module docstring in
win32_input.py for why this dependency-injection seam exists.
"""

import unittest
from unittest import mock

from ovb_rc003 import win32_input


class RecordingSender:
    """A fake RawSender: returns a scripted "sent count" for each call (or
    the full length if the script runs out) and records every call.
    """

    def __init__(self, sent_counts=None):
        self._sent_counts = list(sent_counts or [])
        self.calls = []

    def __call__(self, events):
        self.calls.append(list(events))
        if self._sent_counts:
            return self._sent_counts.pop(0)
        return len(events)


class RaiseOnceThenRecordSender:
    """A fake RawSender simulating XRBM-020's exact scenario: the initial
    batch call raises a generic exception (delivery is now unknown, not
    "nothing landed"), and every SUBSEQUENT call (the best-effort release
    fallback) succeeds and is recorded - so a test can assert exactly which
    individual release calls the fallback made, in what order.
    """

    def __init__(self, exception=None):
        self.exception = exception or RuntimeError("simulated driver hiccup")
        self.calls = []
        self._raised = False

    def __call__(self, events):
        self.calls.append(list(events))
        if not self._raised:
            self._raised = True
            raise self.exception
        return len(events)


class SendKeyComboDownTests(unittest.TestCase):
    def test_full_delivery_sends_one_batched_call_in_order(self):
        sender = RecordingSender()
        win32_input.send_key_combo_down(("win", "d"), _sender=sender)
        self.assertEqual(len(sender.calls), 1)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        vk_d = win32_input.win32_keys.VK_CODES["d"]
        self.assertEqual(sender.calls[0], [(vk_win, False), (vk_d, False)])

    def test_partial_delivery_rolls_back_exactly_the_keys_that_went_down(self):
        # 2-key combo, only the first key-down "lands" (sent=1).
        sender = RecordingSender(sent_counts=[1])
        with self.assertRaises(OSError):
            win32_input.send_key_combo_down(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        # Second call must be the rollback: release exactly the one key that
        # went down (win), not the one that never landed (d).
        self.assertEqual(len(sender.calls), 2)
        self.assertEqual(sender.calls[1], [(vk_win, True)])

    def test_zero_delivery_rolls_back_nothing_but_still_raises(self):
        sender = RecordingSender(sent_counts=[0])
        with self.assertRaises(OSError):
            win32_input.send_key_combo_down(("a",), _sender=sender)
        self.assertEqual(len(sender.calls), 1)  # no rollback call needed

    def test_generic_failure_after_submission_releases_every_key_individually(self):
        # XRBM-020 (fixing the XRBM-019 REPLAN gap - see
        # XRBM-019's independent review round 2): a generic
        # exception raised by the batch call itself does not prove zero
        # key-downs landed - every key must get its OWN best-effort release
        # attempt (one call each), not be skipped just because the initial
        # batch raised instead of reporting a partial count.
        sender = RaiseOnceThenRecordSender()
        with self.assertRaises(OSError):
            win32_input.send_key_combo_down(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        vk_d = win32_input.win32_keys.VK_CODES["d"]
        self.assertEqual(len(sender.calls), 3)  # failed batch + 2 individual releases
        self.assertEqual(sender.calls[1], [(vk_d, True)])
        self.assertEqual(sender.calls[2], [(vk_win, True)])

    def test_generic_failure_chains_the_original_exception(self):
        original = RuntimeError("simulated driver hiccup")

        def failing_sender(events):
            raise original

        with self.assertRaises(OSError) as ctx:
            win32_input.send_key_combo_down(("a",), _sender=failing_sender)
        self.assertIs(ctx.exception.__cause__, original)

    def test_one_fallback_release_failure_does_not_skip_the_other_key(self):
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        calls = []

        def sender(events):
            calls.append(list(events))
            if len(events) > 1:
                raise RuntimeError("simulated driver hiccup")
            if events[0][0] == vk_win:
                raise RuntimeError("simulated fallback release failure")
            return 1

        # The original OSError must still surface - a fallback release
        # failure is swallowed internally, never replaces the observable
        # delivery failure.
        with self.assertRaises(OSError):
            win32_input.send_key_combo_down(("win", "d"), _sender=sender)
        # Both individual release attempts were still made despite the
        # "win" one failing.
        self.assertEqual(len(calls), 3)


class SendKeyComboUpTests(unittest.TestCase):
    def test_full_delivery_releases_in_reverse_order(self):
        sender = RecordingSender()
        win32_input.send_key_combo_up(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        vk_d = win32_input.win32_keys.VK_CODES["d"]
        self.assertEqual(sender.calls[0], [(vk_d, True), (vk_win, True)])

    def test_partial_delivery_retries_the_remaining_keys_then_reports_failure(self):
        # XRBM-019 review round 1 P1 #4: a partial key-up delivery still
        # gets its best-effort retry of whatever didn't land, but must now
        # be OBSERVABLE to the caller (app.py's _cleanup_once) instead of
        # silently reporting success it cannot back up.
        sender = RecordingSender(sent_counts=[1])
        with self.assertRaises(OSError):
            win32_input.send_key_combo_up(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        self.assertEqual(len(sender.calls), 2)
        self.assertEqual(sender.calls[1], [(vk_win, True)])

    def test_generic_failure_now_raises_after_swallowing_used_to_hide_it(self):
        # XRBM-019 review round 1 P1 #4: this used to swallow every generic
        # failure so "cleanup must survive" - but that also meant a failed
        # HOLD-mode KEY_UP left the host key physically down while the
        # caller's own state already recorded it as released. Cleanup must
        # still survive by wrapping this call (see app.py's
        # _cleanup_once/win32_input.py's own module docstring), not by this
        # function pretending the release worked.
        def failing_sender(events):
            raise RuntimeError("simulated driver hiccup")

        with self.assertRaises(OSError):
            win32_input.send_key_combo_up(("a",), _sender=failing_sender)

    def test_generic_failure_after_submission_releases_every_key_individually(self):
        # XRBM-020 (fixing the XRBM-019 REPLAN gap - see
        # XRBM-019's independent review round 2): the round-2
        # adversarial probe found this exact branch raised OSError with NO
        # rollback attempt at all - `calls=1`, containing only the failed
        # batch, for a two-key combo. Every key must now get its own
        # best-effort release attempt.
        sender = RaiseOnceThenRecordSender()
        with self.assertRaises(OSError):
            win32_input.send_key_combo_up(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        vk_d = win32_input.win32_keys.VK_CODES["d"]
        self.assertEqual(len(sender.calls), 3)  # failed batch + 2 individual releases
        # send_key_combo_up already reverses key order once (releases most-
        # recently-pressed first) - the fallback reuses that same order.
        self.assertEqual(sender.calls[1], [(vk_d, True)])
        self.assertEqual(sender.calls[2], [(vk_win, True)])

    def test_generic_failure_chains_the_original_exception(self):
        original = RuntimeError("simulated driver hiccup")

        def failing_sender(events):
            raise original

        with self.assertRaises(OSError) as ctx:
            win32_input.send_key_combo_up(("a",), _sender=failing_sender)
        self.assertIs(ctx.exception.__cause__, original)

    def test_one_fallback_release_failure_does_not_skip_the_other_key(self):
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        calls = []

        def sender(events):
            calls.append(list(events))
            if len(events) > 1:
                raise RuntimeError("simulated driver hiccup")
            if events[0][0] == vk_win:
                raise RuntimeError("simulated fallback release failure")
            return 1

        with self.assertRaises(OSError):
            win32_input.send_key_combo_up(("win", "d"), _sender=sender)
        self.assertEqual(len(calls), 3)

    def test_still_raises_win32_input_unavailable_error(self):
        def unavailable_sender(events):
            raise win32_input.Win32InputUnavailableError("not on windows")

        with self.assertRaises(win32_input.Win32InputUnavailableError):
            win32_input.send_key_combo_up(("a",), _sender=unavailable_sender)


class SendKeyComboTapTests(unittest.TestCase):
    def test_full_delivery_is_one_batched_call_down_then_up_reversed(self):
        sender = RecordingSender()
        win32_input.send_key_combo_tap(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        vk_d = win32_input.win32_keys.VK_CODES["d"]
        self.assertEqual(len(sender.calls), 1)
        self.assertEqual(
            sender.calls[0],
            [(vk_win, False), (vk_d, False), (vk_d, True), (vk_win, True)],
        )

    def test_partial_delivery_during_down_half_rolls_back_only_landed_downs(self):
        # 2-key tap => 4 events total (2 down + 2 up). Only 1 lands.
        sender = RecordingSender(sent_counts=[1])
        with self.assertRaises(OSError):
            win32_input.send_key_combo_tap(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        self.assertEqual(len(sender.calls), 2)
        self.assertEqual(sender.calls[1], [(vk_win, True)])

    def test_partial_delivery_during_up_half_finishes_releasing_remaining_ups(self):
        # 2-key tap => 4 events (down win, down d, up d, up win). 3 land
        # (both downs + first up); the final "up win" doesn't.
        sender = RecordingSender(sent_counts=[3])
        with self.assertRaises(OSError):
            win32_input.send_key_combo_tap(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        self.assertEqual(len(sender.calls), 2)
        self.assertEqual(sender.calls[1], [(vk_win, True)])

    def test_full_up_delivery_needs_no_rollback_call(self):
        sender = RecordingSender()  # always "delivers everything"
        win32_input.send_key_combo_tap(("a",), _sender=sender)
        self.assertEqual(len(sender.calls), 1)

    def test_generic_failure_after_submission_releases_every_key_individually(self):
        # XRBM-020 (fixing the XRBM-019 REPLAN gap): a generic exception
        # raised by the combined down+up batch call does not prove zero
        # events landed - every key in the tap must get its own
        # best-effort release attempt before OSError is raised.
        sender = RaiseOnceThenRecordSender()
        with self.assertRaises(OSError):
            win32_input.send_key_combo_tap(("win", "d"), _sender=sender)
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        vk_d = win32_input.win32_keys.VK_CODES["d"]
        self.assertEqual(len(sender.calls), 3)  # failed batch + 2 individual releases
        self.assertEqual(sender.calls[1], [(vk_d, True)])
        self.assertEqual(sender.calls[2], [(vk_win, True)])

    def test_generic_failure_chains_the_original_exception(self):
        original = RuntimeError("simulated driver hiccup")

        def failing_sender(events):
            raise original

        with self.assertRaises(OSError) as ctx:
            win32_input.send_key_combo_tap(("a",), _sender=failing_sender)
        self.assertIs(ctx.exception.__cause__, original)

    def test_one_fallback_release_failure_does_not_skip_the_other_key(self):
        vk_win = win32_input.win32_keys.VK_CODES["win"]
        calls = []

        def sender(events):
            calls.append(list(events))
            if len(events) > 1:
                raise RuntimeError("simulated driver hiccup")
            if events[0][0] == vk_win:
                raise RuntimeError("simulated fallback release failure")
            return 1

        with self.assertRaises(OSError):
            win32_input.send_key_combo_tap(("win", "d"), _sender=sender)
        self.assertEqual(len(calls), 3)

    def test_still_raises_win32_input_unavailable_error(self):
        def unavailable_sender(events):
            raise win32_input.Win32InputUnavailableError("not on windows")

        with self.assertRaises(win32_input.Win32InputUnavailableError):
            win32_input.send_key_combo_tap(("a",), _sender=unavailable_sender)


class VoiceKeyComboTests(unittest.TestCase):
    def test_down_uses_virtual_key_edges_in_order(self):
        calls = []

        win32_input.send_voice_key_combo_down(
            ("ralt", "space"), _sender=lambda vk, key_up: calls.append((vk, key_up))
        )

        self.assertEqual(
            calls,
            [
                (win32_input.win32_keys.VK_CODES["ralt"], False),
                (win32_input.win32_keys.VK_CODES["space"], False),
            ],
        )

    def test_up_releases_virtual_key_edges_in_reverse_order(self):
        calls = []

        win32_input.send_voice_key_combo_up(
            ("ralt", "space"), _sender=lambda vk, key_up: calls.append((vk, key_up))
        )

        self.assertEqual(
            calls,
            [
                (win32_input.win32_keys.VK_CODES["space"], True),
                (win32_input.win32_keys.VK_CODES["ralt"], True),
            ],
        )

    def test_tap_holds_the_virtual_key_shortcut_before_releasing(self):
        calls = []

        with mock.patch.object(win32_input.time, "sleep") as sleep:
            win32_input.send_voice_key_combo_tap(
                ("ralt",), _sender=lambda vk, key_up: calls.append((vk, key_up))
            )

        vk = win32_input.win32_keys.VK_CODES["ralt"]
        self.assertEqual(calls, [(vk, False), (vk, True)])
        sleep.assert_called_once_with(0.07)

    def test_down_failure_releases_only_keys_already_pressed(self):
        calls = []

        def sender(vk, key_up):
            calls.append((vk, key_up))
            if len(calls) == 2:
                raise RuntimeError("simulated voice sender failure")

        with self.assertRaises(OSError):
            win32_input.send_voice_key_combo_down(("ralt", "space"), _sender=sender)

        self.assertEqual(
            calls,
            [
                (win32_input.win32_keys.VK_CODES["ralt"], False),
                (win32_input.win32_keys.VK_CODES["space"], False),
                (win32_input.win32_keys.VK_CODES["ralt"], True),
            ],
        )

    def test_unavailable_voice_sender_is_re_raised(self):
        def unavailable_sender(vk, key_up):
            raise win32_input.Win32InputUnavailableError("not on windows")

        with self.assertRaises(win32_input.Win32InputUnavailableError):
            win32_input.send_voice_key_combo_down(("ralt",), _sender=unavailable_sender)


class VolumeTests(unittest.TestCase):
    def test_volume_up_taps_the_volume_up_key(self):
        sender = RecordingSender()
        win32_input.send_volume_up(_sender=sender)
        vk = win32_input.win32_keys.VK_CODES["volume_up"]
        self.assertEqual(sender.calls[0], [(vk, False), (vk, True)])

    def test_volume_down_taps_the_volume_down_key(self):
        sender = RecordingSender()
        win32_input.send_volume_down(_sender=sender)
        vk = win32_input.win32_keys.VK_CODES["volume_down"]
        self.assertEqual(sender.calls[0], [(vk, False), (vk, True)])


if __name__ == "__main__":
    unittest.main()
