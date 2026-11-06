"""Generate NoteVibe launcher assets, removing only the exterior navy backdrop."""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
logo = Image.open(ROOT / 'app-icon.png').convert('RGBA')
# The supplied artwork has a navy exterior around the cyan rounded square.
# Flood-fill only dark pixels connected to the image edges: dark details inside
# the cyan border remain untouched. The original source is never overwritten.
from collections import deque
pixels = logo.load()
width, height = logo.size
queue = deque([(x, 0) for x in range(width)] + [(x, height - 1) for x in range(width)] +
              [(0, y) for y in range(height)] + [(width - 1, y) for y in range(height)])
seen = set()
while queue:
    x, y = queue.popleft()
    if (x, y) in seen:
        continue
    seen.add((x, y))
    r, g, b, a = pixels[x, y]
    if a == 0 or (r < 40 and g < 85 and b < 140):
        pixels[x, y] = (r, g, b, 0)
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < width and 0 <= ny < height:
                queue.append((nx, ny))
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
render(1024, 1).save(assets / 'app-icon.png')
res = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    render(size * 4, 1).resize((size, size), Image.Resampling.LANCZOS).save(res / f'mipmap-{density}' / 'ic_launcher.png')
foreground = res / 'drawable-nodpi'
foreground.mkdir(exist_ok=True)
render(432, .62).save(foreground / 'ic_launcher_foreground.png')
render(1024, 1).save(ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico', sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
