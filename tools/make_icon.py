"""Render the 1024px app icon: a pile of prints on a light table, the top print circled in red grease pencil."""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1]
S = 2048  # supersampled, downscaled to 1024

TABLE_EDGE = (220, 228, 232)
TABLE_GLOW = (250, 252, 253)
PAPER = (252, 252, 252, 255)
SLEEVE = (217, 225, 229, 255)
INK = (38, 48, 54, 255)
YELLOW = (236, 178, 28, 255)
RED = (217, 52, 43, 255)


def table():
    """The lit surface: brightest in the middle."""
    small = 256
    base = Image.new("RGB", (small, small))
    px = base.load()
    for y in range(small):
        for x in range(small):
            d = math.hypot(x - small / 2, y - small / 2) / (small * 0.72)
            t = min(1.0, d) ** 1.6
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TABLE_GLOW, TABLE_EDGE))
    return base.resize((S, S), Image.BICUBIC).convert("RGBA")


def print_layer(side, border, paint):
    """A paper print centered on the canvas. `paint` draws the picture inside the border."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    outer = side + 2 * border
    x0 = y0 = (S - outer) // 2
    d.rectangle((x0, y0, x0 + outer, y0 + outer), fill=PAPER)
    box = (x0 + border, y0 + border, x0 + border + side, y0 + border + side)
    picture = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    paint(ImageDraw.Draw(picture), box)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rectangle(box, fill=255)
    layer.paste(picture, (0, 0), mask)
    return layer


def flat(color):
    return lambda d, box: d.rectangle(box, fill=color)


def landscape(d, box):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    d.rectangle(box, fill=SLEEVE)
    r = w * 0.11
    cx, cy = x0 + w * 0.72, y0 + h * 0.28
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=YELLOW)
    d.polygon([(x0 + w * 0.36, y1), (x0 + w * 0.7, y0 + h * 0.62), (x1, y0 + h * 0.88), (x1, y1)], fill=(122, 135, 142, 255))
    d.polygon([(x0, y1), (x0 + w * 0.34, y0 + h * 0.46), (x0 + w * 0.74, y1)], fill=INK)


def place(layer, angle, shift):
    turned = layer.rotate(angle, resample=Image.BICUBIC)
    moved = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    moved.paste(turned, shift, turned)
    return moved


def shadow(layer, blur, offset, alpha):
    a = layer.split()[3].point(lambda v: round(v * alpha))
    sh = Image.new("RGBA", layer.size, (30, 40, 46, 0))
    sh.putalpha(a)
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    out.paste(sh, (0, offset), sh)
    return out


def pencil_loop(center, half, width, phase=1.1, tilt=-0.03, start=-2.5):
    """The same loop as PencilLoop in Theme.swift: a rounded square that overshoots its start."""
    def squared(v):
        return math.copysign(abs(v) ** 0.62, v)

    points = []
    steps = 2400
    for step in range(steps + 1):
        progress = step / steps
        angle = start + 2 * math.pi * 1.1 * progress
        radius = 1 + 0.022 * math.sin(2 * angle + phase) - 0.07 * progress
        x, y = squared(math.cos(angle)) * radius, squared(math.sin(angle)) * radius
        points.append((
            center[0] + (x * math.cos(tilt) - y * math.sin(tilt)) * half,
            center[1] + (x * math.sin(tilt) + y * math.cos(tilt)) * half,
        ))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # Stamp discs along the path: a clean round stroke with no join artifacts.
    for px, py in points:
        d.ellipse((px - width / 2, py - width / 2, px + width / 2, py + width / 2), fill=RED)
    return layer


icon = table()
SIDE, BORDER = 760, 56
pile = (
    (print_layer(SIDE, BORDER, flat((150, 163, 170, 255))), 11, (-215, 50)),
    (print_layer(SIDE, BORDER, flat(YELLOW)), -8, (215, -20)),
    (print_layer(SIDE, BORDER, landscape), 2, (0, 10)),
)
for layer, angle, shift in pile:
    moved = place(layer, angle, shift)
    icon = Image.alpha_composite(icon, shadow(moved, 26, 20, 0.3))
    icon = Image.alpha_composite(icon, moved)
icon = Image.alpha_composite(icon, pencil_loop((S / 2, S / 2 + 10), 560, 56))
icon.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(OUT)
