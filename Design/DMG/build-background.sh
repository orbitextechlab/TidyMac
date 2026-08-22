#!/usr/bin/env bash
# Render dmg-background.svg into the multi-resolution TIFF that create-dmg uses.
# The TIFF carries both a 1x and a 2x representation so the installer window
# stays sharp on Retina displays.
#
# Requires: librsvg (brew install librsvg). tiffutil ships with macOS.
set -euo pipefail
cd "$(dirname "$0")"

rsvg-convert -w 660  -h 400 dmg-background.svg -o /tmp/dmg-bg-1x.png
rsvg-convert -w 1320 -h 800 dmg-background.svg -o /tmp/dmg-bg-2x.png
tiffutil -cathidpicheck /tmp/dmg-bg-1x.png /tmp/dmg-bg-2x.png -out dmg-background.tiff
rm -f /tmp/dmg-bg-1x.png /tmp/dmg-bg-2x.png

echo "wrote $(pwd)/dmg-background.tiff"
