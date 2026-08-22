#!/usr/bin/env python3
"""TidyMac app icon generator.

Two artwork variants share one base treatment:
  full  — for 64px and up: broom, sweep trail, three sparkles.
  small — for 16/32px: broom only, scaled up, one sparkle, no blur.
Apple ships per-size artwork for exactly this reason; detail that reads at
512px turns to mush at 16px.
"""
import json, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_OUT = (HERE.parent.parent / "Sources/TidyMac/Resources/Assets.xcassets/AppIcon.appiconset")

# Exact continuous-corner squircle Apple uses for macOS app icons: an 824x824
# body centred in a 1024 canvas. Regenerate with `swift squircle.swift`.
SQ = (HERE / "squircle.path").read_text().strip()

DEFS = """
  <linearGradient id="base" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#3E352C"/>
    <stop offset="0.52" stop-color="#221D18"/>
    <stop offset="1" stop-color="#120F0C"/>
  </linearGradient>
  <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.11"/>
    <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
  </linearGradient>
  <radialGradient id="glow" cx="0.46" cy="0.52" r="0.52">
    <stop offset="0" stop-color="#ED8A3C" stop-opacity="0.26"/>
    <stop offset="1" stop-color="#ED8A3C" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.24"/>
    <stop offset="0.45" stop-color="#ffffff" stop-opacity="0.06"/>
    <stop offset="1" stop-color="#ffffff" stop-opacity="0.04"/>
  </linearGradient>
  <linearGradient id="wood" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#9E8365"/>
    <stop offset="0.24" stop-color="#FFF4E4"/>
    <stop offset="0.58" stop-color="#EAD6BC"/>
    <stop offset="1" stop-color="#8F7355"/>
  </linearGradient>
  <linearGradient id="collar" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#6B4A2F"/>
    <stop offset="0.28" stop-color="#D0A170"/>
    <stop offset="1" stop-color="#5E4029"/>
  </linearGradient>
  <linearGradient id="bristle" x1="0.1" y1="0" x2="0.85" y2="1">
    <stop offset="0" stop-color="#FFD08C"/>
    <stop offset="0.42" stop-color="#F2953F"/>
    <stop offset="1" stop-color="#D2661B"/>
  </linearGradient>
  <linearGradient id="trail" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#F2953F" stop-opacity="0.85"/>
    <stop offset="1" stop-color="#F2953F" stop-opacity="0"/>
  </linearGradient>
"""

DROP = """
  <filter id="drop" x="-30%" y="-30%" width="170%" height="170%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="18"/>
    <feOffset dy="16" result="s"/>
    <feFlood flood-color="#000000" flood-opacity="0.50"/>
    <feComposite in2="s" operator="in"/>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
"""

def broom(transform, shadow, detail):
    """detail=True draws the stitch band and bristle separators."""
    inner = ""
    if detail:
        inner = """
      <path d="M -92 124 Q 0 136 92 124" fill="none" stroke="#000000" stroke-opacity="0.22" stroke-width="22" stroke-linecap="round"/>
      <g stroke="#000000" stroke-opacity="0.24" stroke-width="12" stroke-linecap="round">
        <path d="M -54 168 L -84 302"/><path d="M -18 172 L -28 310"/>
        <path d="M 18 172 L 28 310"/><path d="M 54 168 L 84 302"/>
      </g>"""
    else:
        # One heavy separator survives downsampling; four turn to grey mush.
        inner = """
      <path d="M -92 124 Q 0 136 92 124" fill="none" stroke="#000000" stroke-opacity="0.28" stroke-width="26" stroke-linecap="round"/>"""
    f = ' filter="url(#drop)"' if shadow else ''
    return f"""    <g transform="{transform}"{f}>
      <rect x="-25" y="-292" width="50" height="356" rx="25" fill="url(#wood)"/>
      <rect x="-72" y="36" width="144" height="58" rx="21" fill="url(#collar)"/>
      <path d="M -88 86 L 88 86 L 158 264 Q 170 294 138 299 Q 0 317 -138 299 Q -170 294 -158 264 Z" fill="url(#bristle)"/>{inner}
    </g>"""

FULL_EXTRAS = """
    <g fill="none" stroke="url(#trail)" stroke-linecap="round">
      <path d="M 372 812 Q 560 856 762 774" stroke-width="30"/>
      <path d="M 404 726 Q 582 768 742 700" stroke-width="20" stroke-opacity="0.55"/>
    </g>
    <g fill="#FFDFB0">
      <path d="M 262 336 q 26 -122 52 0 q 122 26 0 52 q -26 122 -52 0 q -122 -26 0 -52 Z"/>
      <path d="M 372 236 q 14 -66 28 0 q 66 14 0 28 q -14 66 -28 0 q -66 -14 0 -28 Z" fill-opacity="0.78"/>
      <path d="M 232 494 q 9 -44 18 0 q 44 9 0 18 q -9 44 -18 0 q -44 -9 0 -18 Z" fill-opacity="0.55"/>
    </g>"""

TINY_EXTRAS = ""

SMALL_EXTRAS = """
    <g fill="#FFE3B8">
      <path d="M 286 356 q 30 -140 60 0 q 140 30 0 60 q -30 140 -60 0 q -140 -30 0 -60 Z"/>
    </g>"""

ART = {"full": FULL_EXTRAS, "small": SMALL_EXTRAS, "tiny": TINY_EXTRAS}
TRANSFORM = {
    "full":  "translate(578,466) rotate(29) scale(0.88)",
    "small": "translate(596,470) rotate(29) scale(1.00)",
    "tiny":  "translate(544,486) rotate(29) scale(1.16)",
}

def build(variant):
    full = variant == "full"
    art = ART[variant]
    tf = TRANSFORM[variant]
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>{DEFS}{DROP if full else ''}
  <clipPath id="body"><path d="{SQ}"/></clipPath>
</defs>
  <path d="{SQ}" fill="url(#base)"/>
  <g clip-path="url(#body)">
    <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
    <rect x="100" y="100" width="824" height="440" fill="url(#sheen)"/>{art}
{broom(tf, shadow=full, detail=full)}
  </g>
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="3"/>
</svg>
"""

OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
# (size, scale) -> px, and which artwork variant reads best at that pixel size.
SPEC = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
        (256, 1), (256, 2), (512, 1), (512, 2)]

def variant(px):
    if px <= 16:  return "tiny"
    if px <= 32:  return "small"
    return "full"

# Write the three artwork variants next to this script, then rasterise.
svg_paths = {}
for v in ("full", "small", "tiny"):
    p = HERE / f"icon-{v}.svg"
    p.write_text(build(v))
    svg_paths[v] = str(p)

OUT.mkdir(parents=True, exist_ok=True)
images = []
for size, scale in SPEC:
    px = size * scale
    name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
    src = svg_paths[variant(px)]
    subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px), src, "-o", str(OUT / name)], check=True)
    images.append({"filename": name, "idiom": "mac",
                   "scale": f"{scale}x", "size": f"{size}x{size}"})

(OUT / "Contents.json").write_text(
    json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
print(f"{len(images)} images -> {OUT}")
