#!/usr/bin/env bash
# Crop/center docs/characters/dashu.jpg → Resources app + menu bar icons.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="${ICON_VENV:-.icon-venv}"
# uv-managed python3 symlinks break `python3 -m venv` (stdlib home) — use uv
if [[ ! -x "$VENV/bin/python" ]]; then
  command -v uv >/dev/null || { echo "error: uv required for icon venv" >&2; exit 1; }
  uv venv "$VENV"
  uv pip install --python "$VENV" -q pillow
fi

"$VENV/bin/python" << 'PY'
from pathlib import Path
from PIL import Image

img = Image.open("docs/characters/dashu.jpg").convert("RGBA")
w, h = img.size
px = img.load()
corners = [px[2, 2][:3], px[w - 3, 2][:3], px[2, h - 3][:3], px[w - 3, h - 3][:3]]
br = sum(c[0] for c in corners) // 4
bg = sum(c[1] for c in corners) // 4
bb = sum(c[2] for c in corners) // 4

def is_bg(x, y, thr=28):
    r, g, b, a = px[x, y]
    if a < 12:
        return True
    return abs(r - br) < thr and abs(g - bg) < thr and abs(b - bb) < thr

min_x, min_y, max_x, max_y = w, h, 0, 0
found = 0
for y in range(h):
    for x in range(w):
        if not is_bg(x, y):
            found += 1
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
if found < 100:
    min_x, min_y, max_x, max_y = 0, 0, w - 1, h - 1
pad = max(4, int(min(w, h) * 0.02))
min_x = max(0, min_x - pad)
min_y = max(0, min_y - pad)
max_x = min(w - 1, max_x + pad)
max_y = min(h - 1, max_y + pad)
cropped = img.crop((min_x, min_y, max_x + 1, max_y + 1))

def square_pad(im, size, bg=(255, 255, 255, 255), scale=0.90):
    canvas = Image.new("RGBA", (size, size), bg)
    target = int(size * scale)
    ratio = min(target / im.width, target / im.height)
    nw = max(1, int(im.width * ratio))
    nh = max(1, int(im.height * ratio))
    resized = im.resize((nw, nh), Image.Resampling.LANCZOS)
    canvas.paste(resized, ((size - nw) // 2, (size - nh) // 2), resized)
    return canvas

def to_rgb(im, bg=(255, 255, 255)):
    o = Image.new("RGB", im.size, bg)
    o.paste(im, mask=im.split()[3])
    return o

out = Path("Resources")
out.mkdir(exist_ok=True)
chars = Path("docs/characters")

to_rgb(square_pad(cropped, 1024, scale=0.90)).save(out / "AppIcon-1024.png", "PNG")
to_rgb(square_pad(cropped, 1024, scale=0.92)).save(chars / "dashu-appicon.jpg", "JPEG", quality=93)
to_rgb(square_pad(cropped, 1024, scale=0.96)).save(chars / "dashu-centered.jpg", "JPEG", quality=93)

cw, ch = cropped.size
head = cropped.crop((0, 0, cw, max(1, int(ch * 0.62))))
for size, name in [(18, "StatusBarIcon.png"), (36, "diana.k@example.org")]:
    square_pad(head, size, bg=(0, 0, 0, 0), scale=0.96).save(out / name, "PNG")
for size, name in [(18, "StatusBarIcon-full.png"), (36, "StatusBarIcon-full@2x.png")]:
    square_pad(cropped, size, bg=(0, 0, 0, 0), scale=0.94).save(out / name, "PNG")

print(f"cropped {cropped.size} → Resources + docs/characters/dashu-appicon.jpg")
PY

ICONSET=Resources/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
MASTER=Resources/AppIcon-1024.png
for spec in \
  "16:icon_16x16.png" \
  "32:diana.l@example.org" \
  "32:icon_32x32.png" \
  "64:ivan.p@example.net" \
  "128:icon_128x128.png" \
  "256:wendy.h@example.net" \
  "256:icon_256x256.png" \
  "512:wendy.h@example.net" \
  "512:icon_512x512.png" \
  "1024:walt.e@example.net"
do
  size=${spec%%:*}
  name=${spec##*:}
  sips -s format png -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"
echo "Wrote Resources/AppIcon.icns"
