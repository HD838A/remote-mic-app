#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Run in an X11 session. Limit screenshots to the test process's own window.
set -eu
app=$(realpath "${1:?path to extracted desktop executable}")
evidence=$(realpath -m "${2:?output directory}")
mkdir -p "$evidence"
profile=$(mktemp -d)
export XDG_RUNTIME_DIR="$profile/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
pid=
finish() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    rm -rf "$profile"
}
trap finish EXIT
for view in welcome dashboard dashboard-en; do
    export XDG_DATA_HOME="$profile/$view/data" XDG_CONFIG_HOME="$profile/$view/config" XDG_CACHE_HOME="$profile/$view/cache"
    conf="$XDG_CONFIG_HOME/app.getsayall.remote-mic.ubuntu"
    mkdir -p "$conf"
    language=zh-Hans
    theme=light
    if [ "$view" = dashboard-en ]; then language=en; theme=dark; fi
    if [ "$view" != welcome ]; then
        printf '{"theme_preference":"%s","application_language":"%s"}\n' "$theme" "$language" > "$conf/settings.json"
    fi
    if [ "$view" != welcome ]; then
        cp "$profile/welcome/config/app.getsayall.remote-mic.ubuntu/launch-state.json" "$conf/"

        echo '{"flow_version":1,"completed_version":1,"step":"complete","migration_version":1,"staged":null}' > "$conf/onboarding.json"
    else
        echo '{"flow_version":1,"completed_version":0,"step":"welcome","migration_version":1,"staged":null}' > "$conf/onboarding.json"
    fi
    WEBKIT_DISABLE_DMABUF_RENDERER=1 LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11 "$app" > "$profile/startup.log" 2>&1 &
    pid=$!
    window=
    for i in $(seq 1 45); do
        kill -0 "$pid" || { cat "$profile/startup.log"; exit 1; }
        window=$(xdotool search --onlyvisible --all --pid "$pid" --name 'SayAll' 2>/dev/null | head -1)
        if [ -n "$window" ] && grep -q 'result=passed reason=initial_ipc_ready' "$XDG_DATA_HOME/SayAll/Logs/sayall-diagnostic.log" 2>/dev/null; then break; fi
        sleep 1
    done
    test -n "$window"
    grep -q 'result=passed reason=initial_ipc_ready' "$XDG_DATA_HOME/SayAll/Logs/sayall-diagnostic.log"
    sleep 1
    scrot -o -z -w "$window" "$evidence/$view.png"
    /usr/bin/python3 -c 'from PIL import Image; import sys; assert len(Image.open(sys.argv[1]).convert("RGB").resize((96, 72)).getcolors(6912)) > 50, "empty window"' "$evidence/$view.png"
    kill "$pid"; wait "$pid" || true; pid=
done
