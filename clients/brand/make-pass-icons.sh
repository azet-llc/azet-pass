#!/usr/bin/env bash
# AZET Pass's own icon (the AZET mark with a keyhole) into every app's icon slots, from this one drawing.
# usage: clients/brand/make-pass-icons.sh   (needs rsvg-convert)
set -euo pipefail
cd "$(dirname "$0")/../.."
GLYPH='<g transform="translate(512 536) scale(.82) translate(-512 -512)"><path d="M262 822 512 196 762 822" fill="none" stroke="#fff" stroke-width="104" stroke-miterlimit="10"/><circle cx="512" cy="612" r="66" fill="#2f6fe8"/><path d="M486 650h52l26 172h-104z" fill="#2f6fe8"/></g>'
# $1 = corner radius of the 1024 square, $2 = how much of the canvas the square fills (1 = edge to edge)
svg() { echo "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\"><g transform=\"translate(512 512) scale($2) translate(-512 -512)\"><rect width=\"1024\" height=\"1024\" rx=\"$1\" fill=\"#0d0d0d\"/>$GLYPH</g></svg>"; }
png() { svg "$1" "$2" | rsvg-convert -w "$3" -h "$3" -o "$4"; }
svg 230 1 > clients/brand/pass-icon.svg
png 0 1 1024 apple/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png            # iOS masks it
# The App Store refuses an icon with an alpha channel: flatten it.
python3 -c "from PIL import Image; p='apple/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png'; Image.open(p).convert('RGB').save(p)"
png 230 1 512 apple/Resources/Assets.xcassets/Mark.imageset/mark.png
mkdir -p android/app/src/main/res/drawable-nodpi && png 230 1 384 android/app/src/main/res/drawable-nodpi/mark.png # welcome screen
for s in 16 32 128 256 512; do
  png 230 .805 $s apple/Mac/MacAssets.xcassets/MacAppIcon.appiconset/mac-$s@1x.png
  png 230 .805 $((s * 2)) apple/Mac/MacAssets.xcassets/MacAppIcon.appiconset/mac-$s@2x.png
done
for s in 48 96 128 256 512; do
  png 230 .8 $s apple/SafariExtension/Resources/images/icon-$s.png
  png 230 .8 $s clients/extension/src/images/icon-$s.png
done
for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  png 230 .8 ${d#*:} android/app/src/main/res/mipmap-${d%:*}/ic_launcher.png
done

# The builds made from the fork (Windows app, web vault): the same drawing in their icon slots
# (signed in / signed out grey / locked with the padlock badge), the Mac and Windows icon files and the web icons.
G=clients/brand/generated
LOCK='<g transform="translate(560 560) scale(8)"><rect x="4" y="22" width="50" height="36" rx="6" fill="#555" stroke="#fff" stroke-width="5"/><path d="M14 22v-8a15 15 0 0 1 30 0v8" fill="none" stroke="#555" stroke-width="8"/></g>'
slot() { echo "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\"><rect width=\"1024\" height=\"1024\" rx=\"144\" fill=\"$1\"/>$2$3</svg>" | rsvg-convert -w "$4" -h "$4" -o "$5"; }
for s in 16 19 32 38 48 64 96 128 256 512 1024; do
  slot '#0d0d0d' "$GLYPH" '' $s $G/blue-$s.png
  slot '#7c7c7c' "${GLYPH//#2f6fe8/#ffffff}" '' $s $G/gray-$s.png
  slot '#0d0d0d' "$GLYPH" "$LOCK" $s $G/locked-$s.png
done
set=$(mktemp -d)/icon.iconset; mkdir -p $set
for s in 16 32 128 256 512; do png 230 .805 $s $set/icon_${s}x${s}.png; png 230 .805 $((s * 2)) $set/icon_${s}x${s}@2x.png; done
iconutil -c icns -o $G/icon.icns $set
magick $G/blue-16.png $G/blue-32.png $G/blue-48.png $G/blue-64.png $G/blue-128.png $G/blue-256.png $G/icon.ico
magick $G/blue-16.png $G/blue-32.png $G/blue-48.png $G/web/favicon.ico
for t in android-chrome-192x192:192 android-chrome-512x512:512 apple-touch-icon:180 favicon-16x16:16 favicon-32x32:32 mstile-150x150:150; do
  slot '#0d0d0d' "$GLYPH" '' ${t#*:} $G/web/${t%:*}.png
done
