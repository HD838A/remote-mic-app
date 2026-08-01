import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ovb_rc003 import config, key_mapping


class ConfigRootTests(unittest.TestCase):
    def test_uses_localappdata_when_set(self):
        with mock.patch.dict("os.environ", {"LOCALAPPDATA": "/tmp/fake-appdata"}):
            root = config.config_root()
        self.assertEqual(root, Path("/tmp/fake-appdata") / "RemoteMic" / "RC003")

    def test_falls_back_to_home_without_localappdata(self):
        with mock.patch.dict("os.environ", {}, clear=False):
            import os

            os.environ.pop("LOCALAPPDATA", None)
            root = config.config_root()
        self.assertEqual(root, Path.home() / "RemoteMic" / "RC003")


class DefaultConfigPrivacyTests(unittest.TestCase):
    def test_default_config_preserves_existing_users_on_rc003(self):
        self.assertEqual(config.default_config()["selected_device_profile"], "xiaomi-rc003")
        self.assertEqual(config.default_config()["voice_hotkey"], "ralt+space")
        self.assertEqual(config.default_config()["gain_db"], 10.0)

    def test_default_config_contains_no_forbidden_identity_fields(self):
        defaults = config.default_config()
        self.assertFalse(config.FORBIDDEN_KEYS.intersection(defaults.keys()))

    def test_default_key_bindings_contains_no_forbidden_identity_fields(self):
        defaults = config.default_key_bindings()
        self.assertFalse(config.FORBIDDEN_KEYS.intersection(defaults.keys()))

    def test_output_endpoint_defaults_to_empty_so_voice_fails_closed(self):
        self.assertEqual(config.default_config()["output_endpoint_name"], "")

    def test_load_repairs_a_stale_toggle_right_alt_pair(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(
                json.dumps({"voice_trigger_mode": "toggle", "voice_hotkey": "ralt"}),
                encoding="utf-8",
            )
            loaded = config.load_config(path)
        self.assertEqual(loaded["voice_hotkey"], "ralt+space")

    def test_save_repairs_a_stale_hold_right_alt_space_pair(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            data = config.default_config()
            data.update({"voice_trigger_mode": "hold", "voice_hotkey": "ralt+space"})
            config.save_config(path, data)
            loaded = config.load_config(path)
        self.assertEqual(loaded["voice_hotkey"], "ralt")

    def test_load_preserves_a_user_custom_voice_shortcut(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(
                json.dumps({"voice_trigger_mode": "toggle", "voice_hotkey": "win+h"}),
                encoding="utf-8",
            )
            loaded = config.load_config(path)
        self.assertEqual(loaded["voice_hotkey"], "win+h")

    def test_load_repairs_recorded_left_ctrl_win_to_hold_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(
                json.dumps(
                    {"voice_trigger_mode": "toggle", "voice_hotkey": "lctrl+lwin"}
                ),
                encoding="utf-8",
            )
            loaded = config.load_config(path)
        self.assertEqual(loaded["voice_trigger_mode"], "hold")
        self.assertEqual(loaded["voice_hotkey"], "ralt")

    def test_load_repairs_recorded_left_alt_to_right_alt_in_hold_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(
                json.dumps({"voice_trigger_mode": "hold", "voice_hotkey": "lalt"}),
                encoding="utf-8",
            )
            loaded = config.load_config(path)
        self.assertEqual(loaded["voice_trigger_mode"], "hold")
        self.assertEqual(loaded["voice_hotkey"], "ralt")


class SaveConfigPrivacyGuardTests(unittest.TestCase):
    def test_save_config_rejects_forbidden_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            bad_config = config.default_config()
            bad_config["address"] = "AA:BB:CC:DD:EE:FF"
            with self.assertRaises(config.ConfigPrivacyError):
                config.save_config(path, bad_config)
            self.assertFalse(path.exists())

    def test_save_key_bindings_rejects_device_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "key_bindings.json"
            bad_bindings = config.default_key_bindings()
            bad_bindings["device_token"] = "aabbccddeeff"
            with self.assertRaises(config.ConfigPrivacyError):
                config.save_key_bindings(path, bad_bindings)

    def test_load_config_rejects_a_forbidden_key_found_on_disk(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps({"interface_id": "abc"}), encoding="utf-8")
            with self.assertRaises(config.ConfigPrivacyError):
                config.load_config(path)

    # -- recursive guard (XRBM-014 review RETRY P1 #6): a forbidden key must
    #    be refused no matter how deeply it is nested inside dicts and
    #    dicts-inside-lists, not just at the top level. --------------------

    def test_rejects_forbidden_key_nested_two_levels_deep(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "key_bindings.json"
            bad_bindings = config.default_key_bindings()
            bad_bindings["bindings"]["menu"] = {
                "kind": "key_combo",
                "keys": ["a"],
                "metadata": {"address": "AA:BB:CC:DD:EE:FF"},
            }
            with self.assertRaises(config.ConfigPrivacyError) as ctx:
                config.save_key_bindings(path, bad_bindings)
            self.assertIn("bindings.menu.metadata.address", str(ctx.exception))
            self.assertFalse(path.exists())

    def test_rejects_forbidden_key_nested_inside_a_list_of_dicts(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            bad_config = config.default_config()
            bad_config["history"] = [
                {"note": "fine"},
                {"device_token": "aabbccddeeff"},
            ]
            with self.assertRaises(config.ConfigPrivacyError) as ctx:
                config.save_config(path, bad_config)
            self.assertIn("history[1].device_token", str(ctx.exception))

    def test_rejects_forbidden_key_nested_three_levels_deep_in_mixed_structure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            bad_config = config.default_config()
            bad_config["profiles"] = [
                {"devices": [{"bt_address": "AA:BB:CC:DD:EE:FF"}]},
            ]
            with self.assertRaises(config.ConfigPrivacyError) as ctx:
                config.save_config(path, bad_config)
            self.assertIn("profiles[0].devices[0].bt_address", str(ctx.exception))

    def test_deeply_nested_forbidden_key_found_on_load_from_disk_too(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(
                json.dumps({"a": {"b": [{"mac_address": "AA:BB:CC:DD:EE:FF"}]}}),
                encoding="utf-8",
            )
            with self.assertRaises(config.ConfigPrivacyError):
                config.load_config(path)

    def test_deeply_nested_structure_without_a_forbidden_key_saves_fine(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            good_config = config.default_config()
            good_config["profiles"] = [{"devices": [{"friendly_name": "Speakers"}]}]
            config.save_config(path, good_config)  # must not raise
            self.assertTrue(path.exists())


class RoundTripTests(unittest.TestCase):
    def test_save_config_replaces_an_existing_file_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text('{"old": true}\n', encoding="utf-8")
            updated = config.default_config()
            updated["gain_db"] = 4.0

            config.save_config(path, updated)

            self.assertEqual(config.load_config(path)["gain_db"], 4.0)
            self.assertEqual(list(path.parent.glob(".config.json.*.tmp")), [])

    def test_failed_atomic_replace_does_not_leave_a_temporary_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text('{"old": true}\n', encoding="utf-8")
            with mock.patch.object(config.os, "replace", side_effect=OSError("locked")):
                with self.assertRaisesRegex(OSError, "locked"):
                    config.save_config(path, config.default_config())

            self.assertEqual(path.read_text(encoding="utf-8"), '{"old": true}\n')
            self.assertEqual(list(path.parent.glob(".config.json.*.tmp")), [])

    def test_save_and_load_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            original = config.default_config()
            original["gain_db"] = 3.5
            config.save_config(path, original)
            loaded = config.load_config(path)
            self.assertEqual(loaded["gain_db"], 3.5)

    def test_load_missing_file_returns_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "does-not-exist.json"
            loaded = config.load_config(path)
            self.assertEqual(loaded, config.default_config())

    def test_key_bindings_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "key_bindings.json"
            original = config.default_key_bindings()
            config.save_key_bindings(path, original)
            loaded = config.load_key_bindings(path)
            self.assertEqual(loaded["bindings"], original["bindings"])

    def test_legacy_reference_chords_are_migrated_to_semantic_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "key_bindings.json"
            path.write_text(
                json.dumps(
                    {
                        "bindings": {
                            "up": {"kind": "key_combo", "keys": ["up"]},
                            "home": {
                                "kind": "key_combo",
                                "keys": ["win", "d"],
                            },
                            "tv": {
                                "kind": "key_combo",
                                "keys": ["alt", "esc"],
                            },
                            "power": {
                                "kind": "key_combo",
                                "keys": ["ctrl", "shift", "p"],
                            },
                        }
                    }
                ),
                encoding="utf-8",
            )

            loaded = config.load_key_bindings(path)

        self.assertEqual(
            loaded["bindings"]["up"]["kind"],
            key_mapping.ActionKind.ARROW_UP.value,
        )
        self.assertEqual(
            loaded["bindings"]["home"]["kind"],
            key_mapping.ActionKind.SHOW_DESKTOP.value,
        )
        self.assertEqual(
            loaded["bindings"]["tv"]["kind"],
            key_mapping.ActionKind.APP_SWITCHER.value,
        )
        self.assertEqual(
            loaded["bindings"]["power"],
            {"kind": "key_combo", "keys": ["ctrl", "shift", "p"]},
        )


class MicBindingTruthfulnessTests(unittest.TestCase):
    """XRBM-019 In-scope item 6: the physical mic button is always driven
    directly by the ATVV voice lifecycle - the runtime never consults a
    stored "mic" binding. load_key_bindings() must normalize a stale
    non-voice "mic" entry back to voice, not silently keep it around
    looking like it does something (XRBM-018's independent review
    round 2 product-contract follow-up).
    """

    def test_a_stale_non_voice_mic_binding_on_disk_is_normalized_on_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "key_bindings.json"
            stale = config.default_key_bindings()
            # Simulates a legacy file (or a hand-edited one) that saved an
            # ordinary key-combo for "mic" - something the runtime has
            # never actually honored.
            stale["bindings"]["mic"] = {"kind": "key_combo", "keys": ["a"]}
            path.write_text(json.dumps(stale), encoding="utf-8")

            loaded = config.load_key_bindings(path)

            self.assertEqual(loaded["bindings"]["mic"], {"kind": "voice", "keys": []})

    def test_a_missing_mic_binding_on_disk_is_filled_in_as_voice(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "key_bindings.json"
            stale = config.default_key_bindings()
            del stale["bindings"]["mic"]
            path.write_text(json.dumps(stale), encoding="utf-8")

            loaded = config.load_key_bindings(path)

            self.assertEqual(loaded["bindings"]["mic"], {"kind": "voice", "keys": []})

    def test_default_key_bindings_mic_is_already_voice(self):
        self.assertEqual(
            config.default_key_bindings()["bindings"]["mic"], {"kind": "voice", "keys": []}
        )


if __name__ == "__main__":
    unittest.main()
