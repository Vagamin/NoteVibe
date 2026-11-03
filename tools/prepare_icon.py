"""Generate launcher assets from the supplied blue NoteVibe logo (Pillow)."""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
source = Image.open(ROOT / 'app-icon.png').convert('RGB')
logo = source.convert('RGBA')
# The supplied image has a baked-in neutral checkerboard. Blue chroma separates
# the mark from it, including antialiased edge pixels.
pixels = []
for r, g, b in source.getdata():
    alpha = round(255 * max(0, min(1, (b - r - 12) / 30)))
    pixels.append((r, g, b, alpha))
logo.putdata(pixels)
logo = logo.crop(logo.getbbox())
background = (245, 247, 250, 255)


def render(size, fraction, tile=False):
    canvas = Image.new('RGBA', (size, size))
    if tile:
        ImageDraw.Draw(canvas).rounded_rectangle(
            (0, 0, size - 1, size - 1), radius=size * .22, fill=background)
    mark = logo.resize((round(size * fraction), round(size * fraction * logo.height / logo.width)), Image.Resampling.LANCZOS)
    canvas.alpha_composite(mark, ((size - mark.width) // 2, (size - mark.height) // 2))
    return canvas


assets = ROOT / 'docs' / 'branding'
assets.mkdir(parents=True, exist_ok=True)
logo.save(assets / 'logo-transparent.png')
render(1024, .8).save(assets / 'app-icon.png')
res = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    render(size * 4, .8).resize((size, size), Image.Resampling.LANCZOS).save(res / f'mipmap-{density}' / 'ic_launcher.png')
foreground = res / 'drawable-nodpi'
foreground.mkdir(exist_ok=True)
render(432, .62).save(foreground / 'ic_launcher_foreground.png')
render(1024, .8).save(ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico', sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
