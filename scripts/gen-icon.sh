#!/usr/bin/env bash
#
# Regenerate the Parquet icon assets:
#
#   assets/icon.svg         monochrome, fill="currentColor" — for theming / packaging
#   assets/icon-color.svg   two-tone oak — for the README and GitHub
#   assets/preview.png      512px render of icon-color.svg
#
# The icon is a hand-drawn-looking custom window layout: one main pane and a
# few smaller zones, the kind of thing you'd draw in Parquet's editor. The bar
# chip draws the *actual* focused-workspace layout live (ZoneMark.qml); this is
# just the static brand mark. Needs rsvg-convert (librsvg).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p assets

SIZE=96
GAP=3          # space between zones, in viewBox units
INSET=5        # margin inside the rounded frame

# Zones as "x y w h main?" in 0..1 of the inner area. `main` gets the strong
# colour; the rest are lighter. An intentionally lopsided split-tree — one big
# pane, two slivers bottom-left, a strip and a stack on the right.
ZONES=$(cat <<'EOF'
0.00 0.00 0.62 0.55 1
0.00 0.55 0.28 0.45 0
0.28 0.55 0.34 0.45 0
0.62 0.00 0.38 0.30 0
0.62 0.30 0.38 0.42 0
0.62 0.72 0.38 0.28 0
EOF
)

# $1 main colour, $2 secondary colour, $3 = "opacity" to vary mono by fill-opacity
zone_rects() {
  awk -v size="$SIZE" -v gap="$GAP" -v inset="$INSET" \
      -v cmain="$1" -v csec="$2" -v mono="$3" '
    {
      x = $1; y = $2; w = $3; h = $4; main = $5
      area = size - 2 * inset
      rx = inset + x * area + gap / 2
      ry = inset + y * area + gap / 2
      rw = w * area - gap
      rh = h * area - gap
      if (mono == "1") {
        op = main ? "1" : "0.38"
        printf "  <rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" rx=\"2.5\" fill=\"%s\" fill-opacity=\"%s\"/>\n", rx, ry, rw, rh, cmain, op
      } else {
        printf "  <rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" rx=\"2.5\" fill=\"%s\"/>\n", rx, ry, rw, rh, (main ? cmain : csec)
      }
    }' <<<"$ZONES"
}

svg() {  # $1 main, $2 secondary, $3 mono-flag, $4 optional background
  local bg="${4:-}"
  {
    printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s">\n' "$SIZE" "$SIZE" "$SIZE" "$SIZE"
    [[ -n $bg ]] && printf '  <rect width="%s" height="%s" rx="16" fill="%s"/>\n' "$SIZE" "$SIZE" "$bg"
    zone_rects "$1" "$2" "$3"
    printf '</svg>\n'
  }
}

svg 'currentColor' 'currentColor' 1        > assets/icon.svg
svg '#7a5230'      '#c79a63'       0 '#efe6d6' > assets/icon-color.svg

rsvg-convert -w 512 -h 512 assets/icon-color.svg -o assets/preview.png

echo "wrote assets/icon.svg  assets/icon-color.svg  assets/preview.png"
