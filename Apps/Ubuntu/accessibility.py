# SPDX-License-Identifier: GPL-3.0-only
"""Focused, editable controls exposed by Ubuntu's public accessibility API."""
from collections import deque
import os
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, Gio

Atspi.set_timeout(250, 250)
ALIASES = {'vscode': 'code.desktop', 'chrome': 'google-chrome.desktop',
           'cursor': 'cursor.desktop', 'wechat': 'wechat.desktop',
           'terminal': 'org.gnome.Terminal.desktop', 'settings': 'org.gnome.Settings.desktop'}


def apps():
    return {app.get_id(): app for app in Gio.AppInfo.get_all() if app.should_show() and app.get_id()}


def application(target):
    available = apps()
    entry = available.get(ALIASES.get(target, target)) or available.get(target + '.desktop')
    if not entry and target == 'vokie':
        return next((app for app in available.values() if app.get_name().casefold() == 'vokie'
                     or os.path.basename(app.get_executable()).casefold() == 'vokie'), None)
    return entry


def active_window():
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if not app or app.get_process_id() in (os.getpid(), os.getppid()):
            continue
        for j in range(app.get_child_count()):
            window = app.get_child_at_index(j)
            if window and window.get_state_set().contains(Atspi.StateType.ACTIVE):
                return app, window
    raise RuntimeError('No active accessible application')


def editor(focused=True, recorded=None, target=None):
    app, window = active_window()
    if target:
        info = application(target)
        names = (info.get_name().casefold(), os.path.basename(info.get_executable()).casefold()) if info else ()
        if app.get_name().casefold() not in names:
            raise RuntimeError('Target application is not active')
    queue = deque([window])
    deadline = time.monotonic() + 0.75
    visited = 0
    while queue and visited < 1200 and time.monotonic() < deadline:
        node = queue.popleft()
        visited += 1
        if not node:
            continue
        state, role = node.get_state_set(), node.get_role()
        if role == Atspi.Role.PASSWORD_TEXT:
            if state.contains(Atspi.StateType.FOCUSED):
                raise RuntimeError('Password field')
            continue
        if role in (Atspi.Role.ENTRY, Atspi.Role.TEXT) and all(state.contains(flag) for flag in
                (Atspi.StateType.SHOWING, Atspi.StateType.EDITABLE, Atspi.StateType.ENABLED)) and (
                not focused or state.contains(Atspi.StateType.FOCUSED)):
            if not recorded or (recorded.get('automationId') and node.get_accessible_id() == recorded['automationId']
                    or recorded.get('name') and node.get_name() == recorded['name']):
                return app, node
        queue.extend(node.get_child_at_index(i) for i in range(min(node.get_child_count(), 250)))
    raise RuntimeError('No matching editable field in the active application')


def capture(expected=None):
    app, node = editor()
    identity = f'{app.get_process_id()}:{node.path}'
    if expected and identity != expected:
        raise RuntimeError('Focus changed')
    text = node.get_text_iface()
    if not text or not 0 <= text.get_character_count() <= 8000:
        raise RuntimeError('Text unavailable')
    selection = None
    if text.get_n_selections() == 1:
        selected = text.get_selection(0)
        selection = text.get_text(selected.start_offset, selected.end_offset)
    return {'focus': identity, 'app': app.get_name(), 'text': text.get_text(0, -1), 'selection': selection}


def readiness(target):
    info = application(target)
    if not info:
        return None
    names = {info.get_name().casefold(), os.path.basename(info.get_executable()).casefold()}
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app and app.get_name().casefold() in names:
            visible = any(child and child.get_state_set().contains(Atspi.StateType.SHOWING)
                          for child in (app.get_child_at_index(j) for j in range(app.get_child_count())))
            return [True, visible]
    return [False, False]


def target_window(target):
    app, window = active_window()
    info = application(target)
    if not info or app.get_name().casefold() not in {
            info.get_name().casefold(), os.path.basename(info.get_executable()).casefold()}:
        raise RuntimeError('Activate the target application')
    return window


def target_rect(target):
    rect = target_window(target).get_extents(Atspi.CoordType.SCREEN)
    if rect.width <= 0 or rect.height <= 0 or rect.x < -100000 or rect.y < -100000:
        raise RuntimeError('Desktop does not expose global window coordinates')
    return rect
