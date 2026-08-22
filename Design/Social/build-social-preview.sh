#!/usr/bin/env bash
# Render the GitHub social preview: background and wordmark from SVG, with the
# app icon and a real screenshot composited on top.
#
# Requires: librsvg and ImageMagick (brew install librsvg imagemagick).
set -euo pipefail
cd "$(dirname "$0")"

ROOT=$(cd ../.. && pwd)
ICON="$ROOT/Sources/TidyMac/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png"
SHOT="$ROOT/docs/screenshot-home.png"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

rsvg-convert -w 1280 -h 640 social-preview.svg -o "$TMP/bg.png"
magick "$ICON" -resize 150x150 "$TMP/icon.png"

# Screenshot with rounded corners, a hairline edge and a soft drop shadow, so
# it reads as a window floating on the background rather than a pasted rectangle.
magick "$SHOT" -resize 660x "$TMP/shot.png"
W=$(magick identify -format '%w' "$TMP/shot.png")
H=$(magick identify -format '%h' "$TMP/shot.png")
# White shape on black: CopyOpacity reads this as luminance, so drawing onto a
# transparent canvas would flatten to black everywhere and erase the image.
magick -size "${W}x${H}" xc:black -fill white \
  -draw "roundrectangle 0,0,$((W-1)),$((H-1)),14,14" "$TMP/mask.png"
magick "$TMP/shot.png" "$TMP/mask.png" -alpha off -compose CopyOpacity -composite "$TMP/rounded.png"
magick "$TMP/rounded.png" \( +clone -background black -shadow 55x24+0+10 \) \
  +swap -background none -layers merge +repage "$TMP/shadowed.png"

magick "$TMP/bg.png" \
  "$TMP/icon.png"     -geometry +78+96   -composite \
  "$TMP/shadowed.png" -geometry +592+118 -composite \
  -strip social-preview.png

# JPEG alternate: some upload paths are happier with a smaller payload.
magick social-preview.png -quality 92 -strip social-preview.jpg

echo "wrote $(pwd)/social-preview.png and social-preview.jpg"
