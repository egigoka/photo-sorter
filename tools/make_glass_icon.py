"""Write the Liquid Glass app icon as an Icon Composer document.

The picture follows the old flat icon (tools/make_icon.py): a pile of prints on a light table.
Each part is a flat vector layer, and the system adds the glass, highlights and shadows. Run from the repository root:

    python3 tools/make_glass_icon.py PhotoSorter/AppIcon.icon
"""
import json
import shutil
import sys
from pathlib import Path

OUT = Path(sys.argv[1])
C = 512  # canvas center, in points

# Same colors as Theme.swift.
PAPER = "#FCFCFC"
SLEEVE = "#D9E1E5"
SLATE = "#96A3AA"
STONE = "#7A878E"
INK = "#263036"
YELLOW = "#ECB21C"

SIDE, BORDER = 380, 28
OUTER = SIDE + 2 * BORDER


def svg(body):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
        f"{body}</svg>\n"
    )


def placed(body, angle, dx, dy):
    """Turns a print around the canvas center, then slides it."""
    return f'<g transform="translate({dx} {dy}) rotate({-angle} {C} {C})">{body}</g>'


def square(side, fill):
    x = C - side / 2
    return f'<rect x="{x}" y="{x}" width="{side}" height="{side}" fill="{fill}"/>'


def polygon(points, fill):
    text = " ".join(f"{x:.1f},{y:.1f}" for x, y in points)
    return f'<polygon points="{text}" fill="{fill}"/>'


def landscape():
    """The sun and two hills inside the top print."""
    x0 = y0 = C - SIDE / 2
    x1 = y1 = C + SIDE / 2
    w = h = SIDE
    r = w * 0.11
    sun = f'<circle cx="{x0 + w * 0.72:.1f}" cy="{y0 + h * 0.28:.1f}" r="{r:.1f}" fill="{YELLOW}"/>'
    far = polygon([(x0 + w * 0.36, y1), (x0 + w * 0.7, y0 + h * 0.62), (x1, y0 + h * 0.88), (x1, y1)], STONE)
    near = polygon([(x0, y1), (x0 + w * 0.34, y0 + h * 0.46), (x0 + w * 0.74, y1)], INK)
    return sun, far, near


# Prints, back to front: angle in degrees (counterclockwise), then offset.
BACK_LEFT = (11, -107.5, 25)
BACK_RIGHT = (-8, 107.5, -10)
FRONT = (2, 0, 5)

sun, far, near = landscape()
art = {
    # The prints underneath are plain tinted panes, so the glass shows few edges.
    "back-left": placed(square(OUTER, SLATE), *BACK_LEFT),
    "back-right": placed(square(OUTER, YELLOW), *BACK_RIGHT),
    "front-paper": placed(square(OUTER, PAPER), *FRONT),
    "front-sky": placed(square(SIDE, SLEEVE), *FRONT),
    "front-sun": placed(sun, *FRONT),
    "front-far-hill": placed(far, *FRONT),
    "front-near-hill": placed(near, *FRONT),
}


def color(hex_value, alpha=1.0):
    r, g, b = (int(hex_value[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"


def layer(name, dark=None):
    entry = {"image-name": f"{name}.svg", "name": name}
    if dark:
        # Dark appearance recolors the layer shape. Light keeps the SVG color.
        entry["fill-specializations"] = [{"appearance": "dark", "value": {"solid": color(dark)}}]
    return entry


def group(name, layers, **glass):
    return {"name": name, "layers": layers, **glass}


document = {
    "fill-specializations": [
        {"value": {"linear-gradient": [color("#F7F9FA"), color("#D3DCE1")],
                   "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}},
        {"appearance": "dark",
         "value": {"linear-gradient": [color("#2C353B"), color("#12171A")],
                   "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}},
    ],
    # Front to back.
    "groups": [
        group("Top print", [
            layer("front-near-hill"),
            layer("front-far-hill"),
            layer("front-sun", dark="#FFC933"),
            layer("front-sky"),
            layer("front-paper"),
        ], shadow={"kind": "neutral", "opacity": 0.5}, specular=True,
           translucency={"enabled": False, "value": 0}),
        group("Back prints", [
            layer("back-right", dark="#FFC933"),
            layer("back-left"),
        ], shadow={"kind": "neutral", "opacity": 0.4}, specular=True,
           translucency={"enabled": True, "value": 0.5}),
    ],
    "supported-platforms": {"squares": "shared"},
}

if OUT.exists():
    shutil.rmtree(OUT)
(OUT / "Assets").mkdir(parents=True)
for name, body in art.items():
    (OUT / "Assets" / f"{name}.svg").write_text(svg(body))
(OUT / "icon.json").write_text(json.dumps(document, indent=2) + "\n")
print(f"wrote {OUT}")
