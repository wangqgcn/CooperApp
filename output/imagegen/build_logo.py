"""Build the editable Cooper logo artwork and raster exports. No network access."""
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
NAVY = '#15374B'
MINT = '#67DCC3'
PALE = '#DDF8EF'
PAPER = '#F5F7F6'
# Folder tab + open letter C. Deliberately broad strokes for small-size use.
C_PATH = ('M144 88H206Q220 88 230 98L248 116Q258 126 272 126H388'
          'Q432 126 432 170V188Q432 200 420 200H208'
          'Q160 200 160 248V288Q160 336 208 336H410'
          'Q432 336 432 358V372Q432 416 388 416H160'
          'Q72 416 72 328V160Q72 88 144 88Z')

def mark(body=NAVY, connector=MINT):
    return (f'<path fill="{body}" d="{C_PATH}"/>'
            f'<rect x="320" y="224" width="124" height="88" rx="16" fill="{connector}"/>')

def svg(name, width, height, content):
    (ROOT / name).write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-label="Cooper">{content}</svg>\n')

svg('cooper-mark.svg',512,512,mark())
svg('cooper-mark-mono.svg',512,512,mark(NAVY,NAVY))
svg('cooper-mark-white.svg',512,512,mark('#FFFFFF','#FFFFFF'))
svg('cooper-logo.svg',1210,400,
    f'<g transform="translate(0 -5) scale(.78)">{mark()}</g>'
    f'<text x="406" y="280" font-family="Avenir Next, Avenir, Helvetica, sans-serif" '
    f'font-size="216" font-weight="600" fill="{NAVY}">Cooper</text>')
svg('cooper-app-icon.svg',1024,1024,
    '<rect x="64" y="76" width="896" height="896" rx="204" fill="#102C3B" opacity=".12"/>'
    f'<rect x="64" y="64" width="896" height="896" rx="204" fill="{NAVY}"/>'
    '<rect x="66" y="66" width="892" height="892" rx="202" fill="none" stroke="#91CCDF" stroke-opacity=".2" stroke-width="3"/>'
    f'<g transform="translate(148 148) scale(1.42)">{mark(PALE,MINT)}</g>')

for stem, size in [('cooper-mark',2048),('cooper-mark-mono',1024),
                   ('cooper-mark-white',1024),('cooper-app-icon',1024)]:
    subprocess.run(['magick','-background','none','-density','288',f'MSVG:{ROOT / (stem+".svg")}',
                    '-resize',f'{size}x{size}',str(ROOT / (stem+'.png'))],check=True)

font_path = '/System/Library/Fonts/Avenir Next.ttc'
font = ImageFont.truetype(font_path,216,index=0)
for idx in range(20):
    try:
        candidate=ImageFont.truetype(font_path,216,index=idx)
        if candidate.getname()[1]=='Demi Bold':
            font=candidate
            break
    except OSError:
        break
font_index=font.index

lockup=Image.new('RGBA',(2420,800))
m=Image.open(ROOT/'cooper-mark.png')
m.thumbnail((800,800),Image.Resampling.LANCZOS)
lockup.alpha_composite(m,(0,-10))
d=ImageDraw.Draw(lockup)
d.text((812,560),'Cooper',font=ImageFont.truetype(font_path,432,index=font_index),fill=NAVY,anchor='ls',stroke_width=0)
lockup.save(ROOT/'cooper-logo.png')

icon=Image.open(ROOT/'cooper-app-icon.png').convert('RGBA')
iconset=ROOT/'Cooper.iconset'
iconset.mkdir(exist_ok=True)
for size in (16,32,128,256,512):
    for scale in (1,2):
        suffix='@2x' if scale==2 else ''
        icon.resize((size*scale,size*scale),Image.Resampling.LANCZOS).save(iconset/f'icon_{size}x{size}{suffix}.png')
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(ROOT/'Cooper.icns')],check=True)

# Final presentation uses the exact exported assets, not the generative reference.
board=Image.new('RGB',(1800,1160),PAPER)
d=ImageDraw.Draw(board)
small=ImageFont.truetype(font_path,21,index=font_index)
label=ImageFont.truetype(font_path,17,index=font_index)
title=ImageFont.truetype(font_path,26,index=font_index)
d.text((96,65),'COOPER / BRAND IDENTITY',font=small,fill=NAVY)
d.text((1460,65),'CONCEPT 01',font=small,fill=NAVY)
d.line((96,115,1704,115),fill='#DCE4E2',width=2)
lockup.thumbnail((1020,338),Image.Resampling.LANCZOS)
board.paste(lockup,(65,310),lockup)
icon.thumbnail((540,540),Image.Resampling.LANCZOS)
board.paste(icon,(1170,225),icon)
d.text((96,790),'Cloud storage. At home on your Mac.',font=title,fill=NAVY)
d.line((96,870,1704,870),fill='#DCE4E2',width=2)
for x,stem in [(90,'cooper-mark'),(255,'cooper-mark-mono')]:
    im=Image.open(ROOT/f'{stem}.png');im.thumbnail((125,125),Image.Resampling.LANCZOS)
    board.paste(im,(x,925),im)
d.rounded_rectangle((440,925,565,1050),radius=24,fill=NAVY)
im=Image.open(ROOT/'cooper-mark-white.png');im.thumbnail((110,110),Image.Resampling.LANCZOS)
board.paste(im,(448,933),im)
d.text((96,1082),'COLOR / MONO / REVERSE',font=label,fill='#647B84')
for x,color,name in [(960,NAVY,'DEEP NAVY'),(1220,MINT,'COOL MINT'),(1480,PALE,'PALE MINT')]:
    d.rounded_rectangle((x,948,x+56,1004),radius=14,fill=color)
    d.text((x+74,948),name,font=label,fill=NAVY)
    d.text((x+74,979),color,font=label,fill='#647B84')
board.save(ROOT/'cooper-brand-preview.png')
print('Built Cooper SVG, transparent PNG, ICNS and preview assets.')
print('Wordmark font:',font.getname(),'index',font_index)
