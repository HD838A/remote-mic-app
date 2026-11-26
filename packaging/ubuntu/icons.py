#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-only
"""Render two original microphone icons in the formats required by the public UI."""
from pathlib import Path
import sys
from PIL import Image, ImageDraw

root = Path(sys.argv[1])
for alternate in (False, True):
    icon = Image.new('RGBA', (512, 512))
    draw = ImageDraw.Draw(icon)
    draw.rounded_rectangle((12, 12, 500, 500), 100, fill='#12615c' if alternate else '#344052')
    draw.rounded_rectangle((207, 85, 305, 286), 48, fill='white')
    draw.arc((164, 129, 348, 332), 0, 180, fill='white', width=20)
    draw.line((256, 325, 256, 387), fill='white', width=20)
    draw.rounded_rectangle((196, 380, 316, 397), 8, fill='white')
    public = 'app-icon-faceted-duck' if alternate else 'app-logo'
    for ext in ('png', 'webp'):
        icon.resize((256, 256), Image.Resampling.LANCZOS).save(root/'public'/f'{public}.{ext}')
    icons = root/'src-tauri/icons'
    targets = {icons/f'app-icons/faceted-duck-{n}.png': n for n in (16, 20, 24, 32, 256)} if alternate else {
        icons/'icon.png': 256, icons/'32x32.png': 32, icons/'128x128.png': 128,
        icons/'128x128@2x.png': 256, root/'public/favicon.png': 32}
    for path, size in targets.items():
        icon.resize((size, size), Image.Resampling.LANCZOS).save(path)
    icon.save(icons/('app-icons/faceted-duck.ico' if alternate else 'icon.ico'), sizes=[(n,n) for n in (16,32,48,64,128,256)])
