#!/usr/bin/env python3
"""Export the approved Cooper V2 PNG masters into the macOS asset catalog.

Run from any directory with Python 3 and Pillow. No API access is required.
"""
import json
from pathlib import Path
import subprocess

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'output/imagegen/v2'
ASSETS = ROOT / 'App/Assets.xcassets'


def main():
    icon = Image.open(SOURCE / 'cooper-v2-app-icon.png').convert('RGBA')
    mark = Image.open(SOURCE / 'cooper-v2-mark.png').convert('RGBA')
    iconset = SOURCE / 'Cooper.iconset'
    iconset.mkdir(exist_ok=True)

    catalog = ASSETS / 'AppIcon.appiconset'
    entries = json.loads((catalog / 'Contents.json').read_text())['images']
    for entry in entries:
        size = int(entry['size'].split('x')[0]) * int(entry['scale'].rstrip('x'))
        image = icon.resize((size, size), Image.Resampling.LANCZOS)
        image.save(catalog / entry['filename'])
        image.save(iconset / entry['filename'])

    catalog = ASSETS / 'CooperMark.imageset'
    entries = json.loads((catalog / 'Contents.json').read_text())['images']
    for entry in entries:
        size = 128 * int(entry['scale'].rstrip('x'))
        # Keep the approved blue/orange identity in both light and dark appearances.
        mark.resize((size, size), Image.Resampling.LANCZOS).save(catalog / entry['filename'])

    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(SOURCE / 'Cooper.icns')], check=True)
    export_menu_bar_icon()
    print('Exported V2 AppIcon (10 sizes), CooperMark (light/dark, 1x/2x), MenuBarIcon (template, 1x/2x), and Cooper.icns.')


def export_menu_bar_icon():
    """Menu bar template image: the mono mark's alpha as a black glyph, 16 pt tall in an 18 pt canvas."""
    mono = Image.open(SOURCE / 'cooper-v2-mono.png').convert('RGBA')
    alpha = mono.getchannel('A')
    glyph = alpha.crop(alpha.getbbox())
    catalog = ASSETS / 'MenuBarIcon.imageset'
    catalog.mkdir(exist_ok=True)
    images = []
    for scale in (1, 2):
        canvas_size = 18 * scale
        height = 16 * scale
        width = round(glyph.width * height / glyph.height)
        mask = glyph.resize((width, height), Image.Resampling.LANCZOS)
        canvas = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
        black = Image.new('RGBA', (width, height), (0, 0, 0, 255))
        canvas.paste(black, ((canvas_size - width) // 2, (canvas_size - height) // 2), mask)
        filename = 'menubar-icon.png' if scale == 1 else 'menubar-icon@2x.png'
        canvas.save(catalog / filename)
        images.append({'filename': filename, 'idiom': 'mac', 'scale': f'{scale}x'})
    contents = {
        'images': images,
        'info': {'author': 'xcode', 'version': 1},
        'properties': {'template-rendering-intent': 'template'},
    }
    (catalog / 'Contents.json').write_text(json.dumps(contents, indent=2) + '\n')


if __name__ == '__main__':
    main()
