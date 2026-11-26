#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-only
"""Private stdio transport between the Tauri host and Linux desktop services."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
import gi
gi.require_version('Gdk', '3.0')
from gi.repository import Gio, GLib, Gdk

import accessibility as ax
from bridge import BLUEZ, MANAGER, remotes, stop_process
from input import Output, RemoteInput, keysym

BRIDGE = Path(__file__).resolve().with_name('bridge.py')


def send(message):
    print(json.dumps(message, ensure_ascii=False), flush=True)


def event(name, value):
    send({'event': name, 'data': value})


class Desktop:
    def __init__(self):
        self.models = {}
        self.mapped = True
        self.buttons = set()
        self.suspended = False
        self.input = RemoteInput(event, self.passthrough)
        self.output = Output(self.disable)
        self.address = None
        self.child = None
        self.retry_at = 0
        self.capture = False
        self.listen = True
        self.count = None
        self.gain = 0
        self.recording = False

    def passthrough(self, button, code, value):
        if not self.suspended and button not in self.buttons and self.output.handle:
            self.output.keycode(code, value)

    def scan(self):
        bus = dbus.SystemBus()
        devices = dbus.Interface(bus.get_object(BLUEZ, '/'), MANAGER).GetManagedObjects(timeout=5)
        return [{'id': str(d['Address']), 'name': str(d.get('Alias') or 'MI RC'),
                 'model': self.models.get(str(d['Address']), 'unknown'),
                 'battery': int(devices[p].get('org.bluez.Battery1', {}).get('Percentage', -1))}
                for p, d in remotes(devices, None)]

    def disable(self):
        self.capture = False
        self.input.close()
        self.count = None
        self.output.close()
        self.sync_input()

    def sync_input(self):
        grab = bool(self.capture and self.mapped)
        count = self.input.refresh(self.address, grab) if self.child and self.listen else 0
        state = (count, bool(grab and self.output.handle), self.listen, bool(self.output.handle))
        if state != self.count:
            self.count = state
            event('input', state)

    def disconnect(self):
        self.address = None
        self.output.release_forwarded()
        self.input.close()
        if self.child:
            child, self.child = self.child, None
            child.stdin.close()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                stop_process(child)
        self.count = None
        self.sync_input()

    def start(self):
        proc = subprocess.Popen(['/usr/bin/python3', str(BRIDGE), '--desktop', '--device', self.address],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.child = proc
        self.configure_audio()
        def read():
            try:
                for line in proc.stdout:
                    name, value = json.loads(line)
                    GLib.idle_add(self.from_bridge, proc, name, value)
            finally:
                proc.stdout.close()
                GLib.idle_add(self.from_bridge, proc, 'lost', None)
        threading.Thread(target=read, daemon=True).start()

    def from_bridge(self, proc, name, value):
        if proc is self.child:
            if name == 'model':
                self.models[self.address] = value
            if name == 'lost':
                proc.wait()
                self.child = None
                self.output.release_forwarded()
                self.retry_at = time.monotonic() + 3
                self.input.close()
            event(name, value)
        return False

    def configure_audio(self):
        if self.child and self.child.poll() is None:
            try:
                self.child.stdin.write(json.dumps({'gain': self.gain, 'recording': self.recording}) + '\n')
                self.child.stdin.flush()
            except BrokenPipeError:
                pass

    def tick(self):
        if self.address and not self.child and time.monotonic() >= self.retry_at:
            self.start()
        self.sync_input()
        return True

    def dispatch(self, op, arg):
        if op == 'scan':
            return self.scan()
        if op == 'connect':
            device = next((d for d in self.scan() if d['id'] == arg), None)
            if not device:
                raise RuntimeError('请先在 Ubuntu 蓝牙设置中配对 RC003')
            self.disconnect()
            self.address = arg
            event('connecting', device)
            self.start()
        elif op == 'disconnect':
            self.disconnect()
            event('disconnected', None)
        elif op == 'gain' or op == 'recording':
            if op == 'gain':
                self.gain = max(0, min(24, float(arg)))
            else:
                self.recording = bool(arg)
            self.configure_audio()
        elif op == 'suspend':
            self.suspended = bool(arg)
        elif op == 'mappings':
            self.output.release_forwarded()
            self.buttons = set(arg['buttons'])
            if self.mapped != bool(arg['enabled']):
                self.mapped = bool(arg['enabled'])
                self.input.close()
                self.sync_input()
        elif op == 'listen':
            self.output.release_forwarded()
            self.listen = bool(arg)
            self.input.close()
            self.sync_input()
        elif op == 'capture':
            if arg:
                self.output.authorize()
                self.input.close()
                self.capture = True
                self.sync_input()
            else:
                self.disable()
        elif op in ('tap', 'down', 'up'):
            self.output.chord(arg, op)
        elif op in ('scroll', 'move', 'click'):
            self.output.pointer(op, arg)
        elif op == 'alt_down':
            return keysym('alt') in self.output.pressed
        elif op == 'readiness':
            return ax.readiness(arg)
        elif op == 'learn_point':
            display = Gdk.Display.get_default()
            if not display or 'wayland' in type(display).__name__.lower():
                # Wayland exposes accessible components in window-relative coordinates.
                rect = ax.target_window(arg).get_extents(ax.Atspi.CoordType.WINDOW)
                _, node = ax.editor(target=arg)
                field = node.get_extents(ax.Atspi.CoordType.WINDOW)
                x, y = field.x + field.width // 2 - rect.x, field.y + field.height // 2 - rect.y
            else:
                rect = ax.target_rect(arg)
                _, x, y = display.get_default_seat().get_pointer().get_position()
                x, y = x - rect.x, y - rect.y
            if not (0 <= x < rect.width and 0 <= y < rect.height):
                raise RuntimeError('Pointer is outside the target window')
            return {'xRatio':x/rect.width,'yRatio':y/rect.height,'windowWidth':rect.width,
                    'windowHeight':rect.height,'leftOffset':x,'topOffset':y,
                    'rightOffset':rect.width-x,'bottomOffset':rect.height-y}
        elif op == 'point':
            point = arg['point']
            if not point:
                raise RuntimeError('No recorded point')
            display = Gdk.Display.get_default()
            if not display or 'wayland' in type(display).__name__.lower():
                window = ax.target_window(arg['target'])
                coords = ax.Atspi.CoordType.WINDOW
                rect = window.get_extents(coords)
                x, y = int(rect.x + point['xRatio'] * rect.width), int(rect.y + point['yRatio'] * rect.height)
                node = window
                for _ in range(32):
                    child = node.get_accessible_at_point(x, y, coords)
                    if not child or child == node:
                        break
                    node = child
                if not node.grab_focus():
                    raise RuntimeError('Control at the recorded position declined focus')
                return None
            rect = ax.target_rect(arg['target'])
            pointer = display.get_default_seat().get_pointer()
            screen, _, _ = pointer.get_position()
            pointer.warp(screen, int(rect.x + point['xRatio'] * rect.width),
                         int(rect.y + point['yRatio'] * rect.height))
            self.output.pointer('click', 'left')
        elif op == 'apps':
            return [{'id': id, 'name': app.get_display_name(), 'installed': True} for id, app in
                    sorted(ax.apps().items(), key=lambda val: val[1].get_display_name().casefold())]
        elif op == 'launch':
            app = ax.application(arg)
            if not app or not app.launch([], None):
                raise RuntimeError('Application unavailable')
        elif op == 'snapshot':
            return ax.capture(arg)
        elif op == 'learn':
            _, node = ax.editor()
            return {'controlType': 'edit', 'automationId': node.get_accessible_id() or '', 'name': node.get_name() or ''}
        elif op == 'focus':
            _, node = ax.editor(focused=False, target=arg.get('target'), recorded=arg.get('recorded'))
            if not node.grab_focus():
                raise RuntimeError('Application declined focus')
        elif op == 'active':
            app, _ = ax.active_window()
            info = ax.application(arg)
            return bool(info and app.get_name().casefold() in
                        (info.get_name().casefold(), os.path.basename(info.get_executable()).casefold()))
        else:
            raise ValueError('Unknown desktop operation')
        return None

    def close(self):
        self.disconnect()
        self.output.close()


def main():
    DBusGMainLoop(set_as_default=True)
    Gdk.init_check([])
    service, loop = Desktop(), GLib.MainLoop()
    def handle(line):
        msg = json.loads(line)
        try:
            result = service.dispatch(msg['op'], msg['arg'])
            send({'id': msg['id'], 'result': result})
        except Exception as error:
            reason = error.get_dbus_name() if isinstance(error, dbus.DBusException) else str(error)
            send({'id': msg['id'], 'error': reason})
        return False
    def reader():
        try:
            for line in sys.stdin:
                GLib.idle_add(handle, line)
        finally:
            GLib.idle_add(loop.quit)
    threading.Thread(target=reader, daemon=True).start()
    GLib.timeout_add_seconds(2, service.tick)
    try:
        loop.run()
    finally:
        service.close()


if __name__ == '__main__':
    main()
