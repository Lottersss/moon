import numpy as np
from PIL import Image, ImageDraw, ImageFont

S = 2048
y, x = np.mgrid[0:S, 0:S].astype(np.float32)

def hexc(h):
    return np.array([(h >> 16) & 255, (h >> 8) & 255, h & 255], np.float32) / 255

def disk(cx, cy, r, soft=2.5):
    d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    return np.clip((r - d) / soft + 0.5, 0, 1)

def rrect(cx, cy, w, h, r, soft=2.5):
    qx = np.abs(x - cx) - (w / 2 - r)
    qy = np.abs(y - cy) - (h / 2 - r)
    d = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2) + np.minimum(np.maximum(qx, qy), 0) - r
    return np.clip(-d / soft + 0.5, 0, 1)

def blend(img, color, a):
    return img * (1 - a[..., None]) + color * a[..., None]

def grad(top, bottom):
    t = (y / S)[..., None]
    return hexc(top) * (1 - t) + hexc(bottom) * t

def sparkle(cx, cy, size):
    dx, dy = np.abs(x - cx), np.abs(y - cy)
    return np.clip((1 - ((dx / size) ** 0.5 + (dy / size) ** 0.5)) * 6, 0, 1)

def stars(img, seed, avoid, color=0xFFF6DD, n=30):
    rng = np.random.default_rng(seed)
    for _ in range(n):
        sx, sy = rng.uniform(0, S), rng.uniform(0, S)
        if any(np.hypot(sx - ax, sy - ay) < ar for ax, ay, ar in avoid):
            continue
        img = blend(img, hexc(color), disk(sx, sy, rng.uniform(3, 8), 2) * rng.uniform(0.4, 1))
    return img

def save(img, name):
    im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGB").resize((1024, 1024), Image.LANCZOS)
    im.save(name)
    return im

# A — золотой серп луны и кубик в его «чаше»
img = grad(0x1E2A78, 0x0A0F2E)
mx, my, mr = S * 0.46, S * 0.48, S * 0.34
glow = np.clip(1 - (np.hypot(x - mx, y - my) - mr) / (S * 0.2), 0, 1) ** 2.5
img = blend(img, hexc(0xFFD27A), glow * 0.25 * (1 - disk(mx, my, mr, 40)))
crescent = disk(mx, my, mr) * (1 - disk(mx + mr * 0.42, my - mr * 0.30, mr * 0.86))
t = np.clip((x - (mx - mr)) / (2 * mr), 0, 1)[..., None]
img = blend(img, hexc(0xFFE08A) * (1 - t) + hexc(0xF2A93B) * t, crescent)
img = stars(img, 3, [(mx, my, mr * 1.15)])
for cx, cy, s in [(S * 0.82, S * 0.18, 60), (S * 0.86, S * 0.78, 46), (S * 0.14, S * 0.14, 40)]:
    img = blend(img, hexc(0xFFF3D0), sparkle(cx, cy, s))
# кубик, наклонённый, внутри серпа
dcx, dcy, ds = S * 0.60, S * 0.56, S * 0.25
die = rrect(dcx, dcy, ds, ds, ds * 0.2)
img = blend(img, hexc(0x0A0F2E), rrect(dcx + 18, dcy + 26, ds, ds, ds * 0.2, 30) * 0.5)
img = blend(img, hexc(0xFFFFFF), die)
for px, py in [(-1, -1), (1, -1), (0, 0), (-1, 1), (1, 1)]:
    img = blend(img, hexc(0x1E2A78), disk(dcx + px * ds * 0.27, dcy + py * ds * 0.27, ds * 0.085))
A = save(img, "icon-A.png")

# B — минимализм: белый серп на фиолетово-розовом, две звезды
img = grad(0x6A3DE8, 0xE85D9C)
mx, my, mr = S * 0.5, S * 0.5, S * 0.30
crescent = disk(mx, my, mr) * (1 - disk(mx + mr * 0.48, my - mr * 0.18, mr * 0.88))
img = blend(img, hexc(0x3A1A7A), crescent * 0.0)
img = blend(img, hexc(0xFFFFFF), crescent)
img = blend(img, hexc(0xFFFFFF), sparkle(S * 0.66, S * 0.38, 95))
img = blend(img, hexc(0xFFFFFF), sparkle(S * 0.74, S * 0.58, 55))
B = save(img, "icon-B.png")

# C — луна-планета с кольцом из клеток доски (цвета отраслей)
img = grad(0x0B1026, 0x1B1440)
img = stars(img, 11, [(S * 0.5, S * 0.5, S * 0.42)], n=45)
mx, my, mr = S * 0.5, S * 0.5, S * 0.25
colors = [0xC98B5E, 0x74C6EE, 0xB48AE8, 0xF2A94E, 0xE46D6D, 0xE9C14E, 0x93CF6E, 0x5B8DEF]
# кольцо: эллипс, наклонённый; задняя половина под луной, передняя — поверх
ang = np.deg2rad(-18)
rx = (x - mx) * np.cos(ang) - (y - my) * np.sin(ang)
ry = (x - mx) * np.sin(ang) + (y - my) * np.cos(ang)
e = np.sqrt((rx / (S * 0.43)) ** 2 + (ry / (S * 0.12)) ** 2)
band = np.clip((1 - np.abs(e - 0.86) / 0.11) * 8, 0, 1)
theta = (np.arctan2(ry / (S * 0.12), rx / (S * 0.43)) + np.pi) / (2 * np.pi)
seg = (theta * 32).astype(int)
gap = np.clip((np.abs(theta * 32 - np.round(theta * 32)) - 0.05) * 60, 0, 1)
ringcol = np.zeros((S, S, 3), np.float32)
for i in range(32):
    ringcol[seg == i] = hexc(colors[i % 8])
back = band * gap * (ry < 0)
front = band * gap * (ry >= 0)
img = img * (1 - back[..., None]) + ringcol * back[..., None]
moon_a = disk(mx, my, mr)
nx, ny = (x - mx) / mr, (y - my) / mr
nz = np.sqrt(np.clip(1 - nx ** 2 - ny ** 2, 0, 1))
L = np.array([-0.5, -0.5, 0.7]); L /= np.linalg.norm(L)
sh = (0.3 + 0.7 * np.clip(nx * L[0] + ny * L[1] + nz * L[2], 0, 1))[..., None]
img = blend(img, hexc(0x8C7A9E) * (1 - sh) + hexc(0xF4EEFF) * sh, moon_a)
for cx, cy, r in [(-0.35, -0.25, 0.16), (0.3, 0.1, 0.12), (-0.05, 0.42, 0.10), (0.15, -0.45, 0.07)]:
    img = blend(img, hexc(0x9A8BB0), disk(mx + cx * mr, my + cy * mr, r * mr) * 0.5)
img = img * (1 - front[..., None]) + ringcol * front[..., None]
C = save(img, "icon-C.png")

# Превью: три иконки со скруглением, как на домашнем экране
W = 3 * 300 + 4 * 40
sheet = Image.new("RGB", (W, 400), (245, 245, 247))
mask = Image.new("L", (300, 300), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, 299, 299], 67, fill=255)
draw = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 34)
except Exception:
    font = ImageFont.load_default()
for i, (im, label) in enumerate([(A, "A"), (B, "B"), (C, "C")]):
    xo = 40 + i * 340
    sheet.paste(im.resize((300, 300), Image.LANCZOS), (xo, 30), mask)
    draw.text((xo + 150, 365), label, fill=(30, 30, 40), font=font, anchor="mm")
sheet.save("variants.png")
