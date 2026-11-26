# SPDX-License-Identifier: GPL-3.0-only
"""Desktop-authorized keyboard and pointer output and model-scoped evdev input."""
import fcntl
import os
from pathlib import Path
import struct
import uuid

import dbus
from gi.repository import GLib, Gdk

PORTAL = 'org.freedesktop.portal.Desktop'
REMOTE = 'org.freedesktop.portal.RemoteDesktop'
OBJECT = '/org/freedesktop/portal/desktop'
EMPTY = dbus.Dictionary(signature='sv')
# Use the scan code, which is independent of the user's hwdb overrides.
USAGES = {0xf1: 'back', 0x28: 'ok', 0x35: 'tv', 0x4a: 'home', 0x4f: 'right',
          0x50: 'left', 0x51: 'down', 0x52: 'up', 0x65: 'menu', 0x66: 'power',
          0x7f: 'volume_mute', 0x80: 'volume_up', 0x81: 'volume_down'}
KEY_NAMES = {'control': 'Control_L', 'shift': 'Shift_L', 'alt': 'Alt_L',
             'left_windows': 'Super_L', 'right_windows': 'Super_R', 'enter': 'Return',
             'backspace': 'BackSpace', 'page_up': 'Page_Up', 'page_down': 'Page_Down',
             'apps': 'Menu', 'volume_mute': 'XF86AudioMute', 'volume_up': 'XF86AudioRaiseVolume',
             'volume_down': 'XF86AudioLowerVolume', 'media_prev': 'XF86AudioPrev',
             'media_next': 'XF86AudioNext', 'media_play_pause': 'XF86AudioPlay',
             'numlock': 'Num_Lock', 'num_lock': 'Num_Lock', 'oem102': 'less', 'oem1': 'semicolon', 'oem2': 'slash', 'oem3': 'grave',
             'oem4': 'bracketleft', 'oem5': 'backslash', 'oem6': 'bracketright',
             'oem7': 'apostrophe', 'oem_plus': 'equal', 'oem_minus': 'minus',
             'oem_comma': 'comma', 'oem_period': 'period', 'space': 'space'}
for side, suffix in [('left', 'L'), ('right', 'R')]:
    for modifier in ('control', 'alt', 'shift'):
        KEY_NAMES[f'{side}_{modifier}'] = f'{modifier.title()}_{suffix}'
for digit in range(10):
    KEY_NAMES[f'digit{digit}'] = str(digit)
    KEY_NAMES[f'numpad{digit}'] = f'KP_{digit}'
for name in ('multiply', 'add', 'subtract', 'decimal', 'divide'):
    KEY_NAMES['numpad_' + name] = 'KP_' + name.title()


def keysym(key):
    name = KEY_NAMES.get(key, key if len(key) == 1 else key.capitalize())
    value = Gdk.keyval_from_name(name)
    if not value or value == 0xffffff:
        raise ValueError('Unknown shortcut key')
    return value


class Output:
    def __init__(self, on_close):
        self.bus = self.portal = None
        self.authorizing = False
        self.handle = None
        self.closed = None
        self.pressed = set()
        self.forwarded = set()
        self.on_close = on_close

    def request(self, method, *args, **options):
        token = 'sayall' + uuid.uuid4().hex
        sender = self.bus.get_unique_name()[1:].replace('.', '_')
        path = f'{OBJECT}/request/{sender}/{token}'
        loop, result = GLib.MainLoop(), []
        def reply(code, data):
            result.append((int(code), data))
            loop.quit()
        signal = self.bus.add_signal_receiver(reply, 'Response', 'org.freedesktop.portal.Request',
                                              bus_name=PORTAL, path=path)
        timeout = GLib.timeout_add_seconds(90, lambda: (loop.quit(), False)[1])
        try:
            method(*args, dbus.Dictionary(dict(options, handle_token=token), signature='sv'))
            if not result:
                loop.run()
            if not result or result[0][0]:
                raise RuntimeError('桌面未授权键盘和鼠标控制')
            return result[0][1]
        finally:
            if GLib.MainContext.default().find_source_by_id(timeout):
                GLib.source_remove(timeout)
            signal.remove()

    def authorize(self):
        if self.handle:
            return
        if self.authorizing:
            raise RuntimeError('Desktop authorization is already in progress')
        self.authorizing = True
        try:
            self.bus = dbus.SessionBus()
            self.portal = dbus.Interface(self.bus.get_object(PORTAL, OBJECT), REMOTE)
            self.open_session()
        finally:
            self.authorizing = False

    def open_session(self):
        handle = dbus.ObjectPath(self.request(self.portal.CreateSession,
            session_handle_token='sayall' + uuid.uuid4().hex)['session_handle'])
        try:
            self.request(self.portal.SelectDevices, handle, types=dbus.UInt32(3))
            result = self.request(self.portal.Start, handle, '')
            if int(result['devices']) & 3 != 3:
                raise RuntimeError('需要键盘和指针授权')
        except Exception:
            dbus.Interface(self.bus.get_object(PORTAL, handle), 'org.freedesktop.portal.Session').Close()
            raise
        self.handle = handle
        def revoked(*args):
            self.handle = None
            self.pressed.clear()
            self.forwarded.clear()
            self.on_close()
        self.closed = self.bus.add_signal_receiver(revoked, 'Closed', 'org.freedesktop.portal.Session',
                                                   bus_name=PORTAL, path=handle)

    def keycode(self, code, pressed):
        if not pressed and code not in self.forwarded:
            return
        self.portal.NotifyKeyboardKeycode(self.handle, EMPTY, dbus.Int32(code), dbus.UInt32(pressed))
        if pressed:
            self.forwarded.add(code)
        else:
            self.forwarded.discard(code)

    def release_forwarded(self):
        if self.handle:
            for code in list(self.forwarded):
                self.keycode(code, 0)
        self.forwarded.clear()

    def key(self, code, pressed):
        if not self.handle:
            raise RuntimeError('请先开启按键控制并允许 Ubuntu 的桌面授权')
        self.portal.NotifyKeyboardKeysym(self.handle, EMPTY, dbus.Int32(code), dbus.UInt32(pressed))
        if pressed:
            self.pressed.add(code)
        else:
            self.pressed.discard(code)

    def chord(self, keys, mode='tap'):
        codes = [keysym(k) for k in keys]
        if mode == 'up':
            for code in reversed(codes):
                self.key(code, 0)
            return
        down = []
        try:
            for code in codes:
                self.key(code, 1)
                down.append(code)
        finally:
            if mode != 'down' or len(codes) != len(down):
                for code in reversed(down):
                    self.key(code, 0)

    def pointer(self, action, payload):
        if not self.handle:
            raise RuntimeError('请先允许桌面控制')
        if action == 'move':
            self.portal.NotifyPointerMotion(self.handle, EMPTY, float(payload[0]), float(payload[1]))
        elif action == 'scroll':
            self.portal.NotifyPointerAxisDiscrete(self.handle, EMPTY, dbus.UInt32(0), dbus.Int32(payload))
        elif action == 'click':
            button = {'left': 272, 'double_left': 272, 'right': 273, 'middle': 274}[payload]
            for _ in range(2 if payload == 'double_left' else 1):
                for state in (1, 0):
                    self.portal.NotifyPointerButton(self.handle, EMPTY, dbus.Int32(button), dbus.UInt32(state))

    def close(self):
        if self.handle:
            handle, self.handle = self.handle, None
            if self.closed:
                self.closed.remove()
            dbus.Interface(self.bus.get_object(PORTAL, handle), 'org.freedesktop.portal.Session').Close()
        self.pressed.clear()
        self.forwarded.clear()


EVENT = struct.Struct('@llHHi')
EVIOCGRAB = 0x40044590

class RemoteInput:
    def __init__(self, notify, passthrough):
        self.passthrough = passthrough
        self.notify = notify
        self.devices = {}

    def refresh(self, address, grab):
        for entry in Path('/sys/class/input').glob('event*'):
            sys = entry / 'device'
            try:
                if (sys/'id/bustype').read_text().strip() != '0005' or (sys/'id/vendor').read_text().strip().lower() != '2717' or (sys/'id/product').read_text().strip().lower() != '32b8':
                    continue
                if (sys/'uniq').read_text().strip().lower() != address.lower():
                    continue
                path = Path('/dev/input') / entry.name
                if path in self.devices:
                    continue
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except (OSError, ValueError):
                continue
            try:
                if grab:
                    fcntl.ioctl(fd, EVIOCGRAB, 1)
                scan = [None]
                def read(source, condition, key=path, current=scan, owned=grab):
                    if condition & (GLib.IO_HUP | GLib.IO_ERR):
                        self.drop(key)
                        return False
                    try:
                        data = os.read(source, EVENT.size * 64)
                    except BlockingIOError:
                        return True
                    except OSError:
                        self.drop(key)
                        return False
                    for _, _, kind, code, value in EVENT.iter_unpack(data):
                        if kind == 4 and code == 4:
                            current[0] = value
                        elif kind == 1:
                            usage = current[0]
                            current[0] = None
                            if value in (0, 1) and usage is not None and usage >> 16 == 7:
                                button = USAGES.get(usage & 0xffff)
                                if button:
                                    if owned:
                                        self.passthrough(button, code, value)
                                    self.notify('edge', {'button': button, 'isPressed': bool(value)})
                    return True
                watch = GLib.io_add_watch(fd, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, read)
                self.devices[path] = fd, watch
            except OSError:
                os.close(fd)
        return len(self.devices)

    def drop(self, path):
        fd, _ = self.devices.pop(path)
        os.close(fd)

    def close(self):
        for path, (_, watch) in list(self.devices.items()):
            GLib.source_remove(watch)
            self.drop(path)
