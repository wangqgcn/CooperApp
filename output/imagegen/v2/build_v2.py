"""Prepare Cooper v2 design previews from the generated logo. No network calls."""
from pathlib import Path
import json
import zipfile
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
BLUE = '#485BFF'
ORANGE = '#FF965F'
INK = '#202238'
PAPER = '#FAFAF8'

raw = Image.open(ROOT / 'cooper-v2-symbol-generated.png').convert('RGBA')
pixels = np.array(raw)
alpha = pixels[:, :, 3]
_, labels, stats, _ = cv2.connectedComponentsWithStats((alpha > 32).astype('uint8'), connectivity=8)
largest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
mask = cv2.dilate((labels == largest).astype('uint8'), np.ones((3, 3), np.uint8))
pixels[:, :, 3] = alpha * mask
clean = Image.fromarray(pixels)
# Preserve native resolution; remove only disconnected generation speckles.
clean.save(ROOT / 'cooper-v2-mark.png')
alpha_image = clean.getchannel('A')

def recolor(color):
    result = Image.new('RGBA', clean.size, color)
    result.putalpha(alpha_image)
    return result

mono = recolor(INK)
white = recolor('#FFFFFF')
blue = recolor(BLUE)
mono.save(ROOT / 'cooper-v2-mono.png')
white.save(ROOT / 'cooper-v2-white.png')
blue.save(ROOT / 'cooper-v2-blue.png')

def resized(image, dimensions):
    result = image.copy()
    result.thumbnail(dimensions, Image.Resampling.LANCZOS)
    return result

def paste(canvas, image, xy):
    canvas.paste(image, xy, image)

# The white tile follows the macOS icon inset; no changes to application resources.
icon = Image.new('RGBA', (2048, 2048))
shadow = Image.new('RGBA', icon.size)
d = ImageDraw.Draw(shadow)
d.rounded_rectangle((140, 164, 1908, 1932), radius=408, fill=(35, 37, 61, 32))
icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(24)))
d = ImageDraw.Draw(icon)
d.rounded_rectangle((128, 128, 1920, 1920), radius=408, fill='#FFFFFF', outline='#EAEBF0', width=4)
symbol = resized(clean, (1590, 1590))
icon.alpha_composite(symbol, ((2048-symbol.width)//2, (2048-symbol.height)//2))
icon = icon.resize((1024, 1024), Image.Resampling.LANCZOS)
icon.save(ROOT / 'cooper-v2-app-icon.png')

font_path = '/System/Library/Fonts/Avenir Next.ttc'
def font(size, bold=True):
    return ImageFont.truetype(font_path, size, index=2 if bold else 7)

lockup = Image.new('RGBA', (2400, 800))
symbol = resized(clean, (800, 800))
lockup.alpha_composite(symbol, (0, 0))
d = ImageDraw.Draw(lockup)
d.text((850, 566), 'Cooper', font=font(420), fill=INK, anchor='ls')
lockup.save(ROOT / 'cooper-v2-logo.png')

board = Image.new('RGB', (1800, 1160), PAPER)
d = ImageDraw.Draw(board)
d.text((92, 62), 'COOPER', font=font(25), fill=INK)
d.text((1490, 68), 'FOLDED C / 02', font=font(18), fill='#7B7C89')
d.line((92, 120, 1708, 120), fill='#E7E7EB', width=2)
paste(board, resized(lockup, (1100, 367)), (62, 295))
paste(board, resized(icon, (550, 550)), (1180, 218))
d.text((100, 760), 'A familiar idea. A distinct shape.', font=font(26,False), fill='#666878')
d.line((92, 854, 1708, 854), fill='#E7E7EB', width=2)
for x, image in ((98, clean),(290, mono),(482, blue)):
    paste(board, resized(image, (138,138)), (x, 910))
d.rounded_rectangle((684, 910, 824, 1050), radius=30, fill=BLUE)
paste(board, resized(white, (140,140)), (684,910))
d.text((100, 1080), 'COLOR / MONO / ONE COLOR / REVERSE', font=font(15), fill='#858694')
for x,color,title in ((1120,BLUE,'INDIGO'),(1430,ORANGE,'APRICOT')):
    d.rounded_rectangle((x,947,x+64,1011),radius=18,fill=color)
    d.text((x+85,947),title,font=font(18),fill=INK)
    d.text((x+85,980),color,font=font(17,False),fill='#858694')
board.save(ROOT / 'cooper-v2-preview.png')

# Actual pixel-size exports for visual inspection.
small = Image.new('RGB', (1000, 270), PAPER)
d=ImageDraw.Draw(small)
for x,size in ((70,16),(200,24),(360,32),(540,64),(750,128)):
    paste(small,resized(clean,(size,size)),(x,110-size//2))
    d.text((x,205),f'{size} px',font=font(17,False),fill='#858694')
small.save(ROOT/'cooper-v2-size-check.png')

metadata = {
    'version':'v2',
    'status':'adopted',
    'model_alias':'gpt-image-2.5-sunburst',
    'native_symbol_size':list(raw.size),
    'method':'imagegen CLI generate + edit; raster cleanup and layout',
    'application_asset_export':'python3 scripts/update-brand-assets.py',
}
(ROOT/'generation.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n')
print('Prepared v2 transparent logos, macOS icon preview, and size checks.')
