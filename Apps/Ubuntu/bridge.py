#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-only
"""Expose a paired RC003's ATVV audio as a PipeWire microphone."""
import argparse
from contextlib import ExitStack, contextmanager
import fcntl
from functools import wraps
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import dbus
import gi
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

try:
    gi.require_version('GLibUnix', '2.0')
    from gi.repository import GLibUnix
    add_signal = GLibUnix.signal_add
except (ImportError, AttributeError, ValueError):  # Ubuntu 24.04 GI
    add_signal = GLib.unix_signal_add

from audio import Audio

BLUEZ = 'org.bluez'
DEVICE = BLUEZ + '.Device1'
GATT = BLUEZ + '.GattCharacteristic1'
SERVICE = BLUEZ + '.GattService1'
PROPS = 'org.freedesktop.DBus.Properties'
MANAGER = 'org.freedesktop.DBus.ObjectManager'
UUIDS = [f'ab5e000{i}-5a21-4f05-bc7d-af01f617b664' for i in range(1, 5)]
LIB = Path(__file__).resolve().with_name('libatvv.so')


def log(message):
    print(message, file=sys.stderr, flush=True)


def remotes(objects, address):
    matches = []
    for path, interfaces in objects.items():
        device = interfaces.get(DEVICE, {})
        if not device.get('Paired') or not str(device.get('Modalias', '')).lower().startswith('bluetooth:v2717p32b8d'):
            continue
        if not address or device['Address'].upper() == address.upper():
            matches.append((path, device))
    return matches


def characteristics(objects, device):
    services = {p for p, i in objects.items() if i.get(SERVICE, {}).get('Device') == device
                and i[SERVICE]['UUID'].lower() == UUIDS[0]}
    return {str(c['UUID']).lower(): (p, c) for p, i in objects.items()
            if (c := i.get(GATT)) and c['Service'] in services}


def stop_process(child):
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


@contextmanager
def microphone():
    # Explicit target and low priority keep the user's speakers/default source intact.
    sink = 'sayall.rc003.feed'
    source = 'sayall.rc003.mic'
    with ExitStack() as stack:
        nodes = subprocess.Popen(['pw-loopback', '-n', 'sayall.rc003', '-c', '1', '-m', '[ MONO ]',
            '--capture-props', f'media.class=Audio/Sink node.name={sink} priority.session=1 node.description="SayAll feed"',
            '--playback-props', f'media.class=Audio/Source node.name={source} priority.session=1 node.description="SayAll RC003"'])
        stack.callback(stop_process, nodes)
        for _ in range(50):
            available = subprocess.check_output(['pactl', 'list', 'short', 'sinks'], text=True, timeout=2)
            if any(len(row.split()) > 1 and row.split()[1] == sink for row in available.splitlines()):
                break
            if nodes.poll() is not None:
                raise RuntimeError('PipeWire loopback exited')
            time.sleep(0.1)
        else:
            raise RuntimeError('PipeWire loopback did not publish its sink')
        player = subprocess.Popen(['pacat', '--playback', '--raw', '--device', sink,
            '--rate=16000', '--channels=1', '--format=s16le', '--latency-msec=40'], stdin=subprocess.PIPE, bufsize=0)
        stack.callback(stop_process, player)
        log('Microphone ready: SayAll RC003')
        try:
            yield player.stdin, (nodes, player)
        finally:
            player.stdin.close()
            try:
                player.wait(timeout=2)  # natural drain before removing the two nodes
            except subprocess.TimeoutExpired:
                pass


class Stream:
    def __init__(self, audio, send, output):
        self.audio, self.send, self.output = audio, send, output
        self.ready = self.opened = False
        self.session = None
        self.samples = 0

    def write(self, opcode):
        payload = self.audio.command(opcode, self.session or 0)
        if payload:
            self.send(payload)

    def press(self):
        if self.ready and not self.opened and self.session is None:
            self.write(0x0c)
            self.opened = True

    def release(self):
        if self.opened or self.session is not None:
            self.write(0x0d)
            self.opened = False

    def control(self, packet):
        if not packet:
            return
        op = packet[0]
        if op == 0x0b:
            if not self.audio.configure(packet):
                raise RuntimeError('Remote did not negotiate supported 16 kHz audio')
            self.ready = True
            log('ATVV ready: 16000 Hz mono')
        elif self.ready:
            if op == 0x08:
                self.press()
            elif op == 0x04:
                if len(packet) < 4 or packet[2] != 2:
                    raise RuntimeError('Unsupported ATVV stream format')
                if self.session != packet[3]:
                    self.audio.reset()
                    self.session, self.samples = packet[3], 0
                    log('Voice started')
            elif op == 0x0a and len(packet) >= 7:
                self.audio.reset(int.from_bytes(packet[4:6], 'big', signed=True), packet[6])
            elif op == 0x00:
                if self.session is not None:
                    log(f'Voice ended: {self.samples} samples')
                self.opened, self.session = False, None
                self.audio.reset()

    def packet(self, data):
        if self.session is not None:
            pcm = self.audio.decode(data)
            if pcm:
                self.output(pcm)
                self.samples += len(pcm) // 2


def run(args):
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    manager = dbus.Interface(bus.get_object(BLUEZ, '/'), MANAGER)
    objects = manager.GetManagedObjects()
    matches = remotes(objects, args.device)
    if args.list:
        for _, device in matches:
            print(device['Address'], 'connected' if device.get('Connected') else 'paired')
        return
    if len(matches) != 1:
        raise RuntimeError('Pair an RC003 in Bluetooth settings; for multiple devices select one with --device ADDRESS')
    path, device = matches[0]
    if not device.get('Connected'):
        dbus.Interface(bus.get_object(BLUEZ, path), DEVICE).Connect(timeout=15)
    for _ in range(50):
        chars = characteristics(manager.GetManagedObjects(), path)
        if all(key in chars for key in UUIDS[1:]):
            break
        time.sleep(0.1)
    else:
        raise RuntimeError('ATVV service unavailable; wake or reconnect the remote')
    tx, txprops = chars[UUIDS[1]]
    writer = dbus.Interface(bus.get_object(BLUEZ, tx), GATT)
    mode = 'request' if 'write' in txprops['Flags'] else 'command'

    def send(payload):
        writer.WriteValue(dbus.ByteArray(payload), dbus.Dictionary({'type': mode}, signature='sv'), timeout=4)

    loop = GLib.MainLoop()
    errors = []

    def guard(fn):
        @wraps(fn)
        def wrapped(*params, **kwargs):
            try:
                return fn(*params, **kwargs)
            except Exception as exc:
                errors.append(exc)
                loop.quit()
                return False
        return wrapped

    with ExitStack() as stack:
        runtime = os.environ.get('XDG_RUNTIME_DIR')
        if not runtime:
            raise RuntimeError('Run in the logged-in desktop session (XDG_RUNTIME_DIR is required)')
        lock = stack.enter_context(open(Path(runtime) / 'sayall-ubuntu.lock', 'a'))
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another SayAll bridge is using the remote') from None
        codec = Audio(LIB)
        stack.callback(codec.close)
        if args.pcm or args.probe:
            out, children = sys.stdout.buffer, ()
        else:
            out, children = stack.enter_context(microphone())
        def output(pcm):
            out.write(pcm)
            out.flush()
        stream = Stream(codec, send, output)

        @guard
        def changed(interface, props, invalid, object_path=None):
            if object_path == path and interface == DEVICE and 'Connected' in props and not props['Connected']:
                raise RuntimeError('Remote disconnected; reconnect and restart the bridge')
            if interface != GATT or 'Value' not in props:
                return
            if object_path == chars[UUIDS[3]][0]:
                packet = bytes(props['Value'])
                if args.probe and packet[:1] != b'\x0b':
                    return
                stream.control(packet)
                if args.probe and stream.ready:
                    loop.quit()
            elif object_path == chars[UUIDS[2]][0] and not args.probe:
                stream.packet(bytes(props['Value']))

        subscription = bus.add_signal_receiver(changed, 'PropertiesChanged', PROPS, bus_name=BLUEZ, path_keyword='object_path')
        stack.callback(subscription.remove)
        for uuid in (UUIDS[2], UUIDS[3]):
            char = dbus.Interface(bus.get_object(BLUEZ, chars[uuid][0]), GATT)
            char.StartNotify(timeout=5)
            def unsubscribe(characteristic=char):
                try:
                    characteristic.StopNotify(timeout=2)
                except dbus.DBusException:
                    pass  # Bluetooth already released the subscription on disconnect
            stack.callback(unsubscribe)
        @guard
        def owner_changed(name, old_owner, new_owner):
            if not new_owner:
                raise RuntimeError('BlueZ stopped; restart the bridge after Bluetooth recovers')
        owner = bus.add_signal_receiver(owner_changed, 'NameOwnerChanged', 'org.freedesktop.DBus',
                                        bus_name='org.freedesktop.DBus', arg0=BLUEZ)
        stack.callback(owner.remove)
        def watchdog():
            if any(child.poll() is not None for child in children):
                errors.append(RuntimeError('PipeWire microphone exited'))
                loop.quit()
            elif not stream.ready:
                errors.append(RuntimeError('ATVV capabilities timed out'))
                loop.quit()
            return True
        def extend():
            if stream.session is not None:
                stream.write(0x0e)
            return True
        stack.callback(GLib.source_remove, GLib.timeout_add_seconds(6, watchdog))
        stack.callback(GLib.source_remove, GLib.timeout_add_seconds(35, guard(extend)))
        def interrupt():
            loop.quit()
            return True
        for sig in (signal.SIGTERM, signal.SIGINT):
            stack.callback(GLib.source_remove, add_signal(GLib.PRIORITY_DEFAULT, sig, interrupt))
        stream.write(0x0a)
        try:
            loop.run()
        finally:
            try:
                stream.release()
            except dbus.DBusException:
                if not errors:
                    raise
        if errors:
            raise errors[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', metavar='ADDRESS', help='select one paired RC003')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--list', action='store_true', help='list paired RC003 devices')
    mode.add_argument('--probe', action='store_true', help='verify GATT negotiation and exit')
    mode.add_argument('--pcm', action='store_true', help='write raw 16 kHz mono s16le to stdout')
    try:
        run(parser.parse_args())
    except (OSError, RuntimeError, ValueError, ImportError, dbus.DBusException, subprocess.SubprocessError) as exc:
        # BlueZ may include a device address in the detailed D-Bus exception message.
        log(exc.get_dbus_name() if isinstance(exc, dbus.DBusException) else str(exc))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
