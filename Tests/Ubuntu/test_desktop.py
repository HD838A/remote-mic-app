# SPDX-License-Identifier: GPL-3.0-only
import unittest
from unittest.mock import MagicMock, patch

from bridge import GATT, SERVICE, model_number
from desktop import Desktop
from input import keysym


class DesktopTests(unittest.TestCase):
    def test_offline_settings_do_not_require_bluez_or_a_portal(self):
        with patch('dbus.SystemBus', side_effect=RuntimeError), patch('dbus.SessionBus', side_effect=RuntimeError):
            desktop = Desktop()
            self.assertIsNone(desktop.dispatch('gain', 37))
            self.assertEqual(desktop.gain, 24)
            desktop.close()

    def test_only_unmapped_remote_keys_pass_through_once(self):
        desktop = Desktop()
        desktop.buttons = {'back'}
        desktop.output.handle = '/test/session'
        desktop.output.portal = MagicMock()
        desktop.passthrough('back', 1, 1)
        desktop.passthrough('ok', 28, 0)
        desktop.output.portal.NotifyKeyboardKeycode.assert_not_called()
        desktop.passthrough('ok', 28, 1)
        desktop.output.release_forwarded()
        self.assertEqual([int(c.args[-1]) for c in desktop.output.portal.NotifyKeyboardKeycode.call_args_list], [1, 0])
        desktop.passthrough('ok', 28, 0)
        self.assertEqual(desktop.output.portal.NotifyKeyboardKeycode.call_count, 2)

    def test_model_number_only_uses_selected_device_information_service(self):
        def uuid(code):
            return f'0000{code}-0000-1000-8000-00805f9b34fb'
        objects = {'/s': {SERVICE: {'Device': '/other', 'UUID': uuid('180a')}},
                   '/c': {GATT: {'Service': '/s', 'UUID': uuid('2a24')}}}
        self.assertEqual(model_number(objects, '/selected', None), '')

    def test_keysym_conversion(self):
        self.assertEqual(keysym('right_alt'), 0xffea)
        self.assertEqual(keysym('f13'), 0xffca)
        self.assertEqual(keysym('oem102'), ord('<'))
        with self.assertRaises(ValueError):
            keysym('invalid_key')
