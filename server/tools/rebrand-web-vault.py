#!/usr/bin/env python3
"""rebrand-web-vault.py <web-vault dir>: puts the current AZET Pass mark (black tile, white A, blue keyhole) into a built
web vault: every inline logo that still draws the old key mark, the favicon and home-screen icons, and the logo image files.
Run it on the built folder before deploying the gateway (server/gw). Prints what it changed; exits 1 if a bundle still
holds the old mark afterwards."""
import glob, os, re, shutil, subprocess, sys

W = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
BRAND = os.path.join(HERE, "..", "..", "clients", "brand")
KEY = "M13 1a8 8 0 1 1 0 16a8 8 0 0 1 0-16Zm0 5a3 3 0 1 0 0 6a3 3 0 0 0 0-6ZM11 16h4v15h-4ZM15 21h5v3.5h-5ZM15 26.5h4v3.5h-4Z"
# The 1024 icon (clients/brand/pass-icon.svg) drawn in the old mark's 26 x 32 box: a 26 px tile from y = 3.
A = ('<path d="M7.8 23.07 13 10.04 18.2 23.07" fill="none" stroke="#fff" stroke-width="2.17" stroke-miterlimit="10"/>'
     '<circle cx="13" cy="18.7" r="1.37" fill="#2f6fe8"/><path d="M12.46 19.48h1.09l.54 3.59h-2.17z" fill="#2f6fe8"/>')
TILE = '<rect y="3" width="26" height="26" rx="5.84" fill="#0d0d0d"/>'

def swap(m):
    attrs = m.group(1)
    t = re.search(r'transform="([^"]*)"', attrs)
    g = f'<g transform="{t.group(1)}">' if t else "<g>"
    if 'fill="#fff"' in attrs:  # already on its own tile (the small square icon): only the glyph changes
        return g + A + "</g>"
    return g + TILE + A + "</g>"

changed = 0
for f in glob.glob(os.path.join(W, "**", "*.js"), recursive=True):
    s = open(f, encoding="utf-8").read()
    if KEY not in s: continue
    n = re.sub(r'<path((?:\s+[a-z-]+="[^"]*")*?)\s+d="' + re.escape(KEY) + r'"\s*/>', swap, s)
    n = n.replace('<rect class="tw-fill-bw-blue" width="20" height="20" rx="3"/>', '<rect fill="#0d0d0d" width="20" height="20" rx="4.5"/>')
    if n != s:
        open(f, "w", encoding="utf-8").write(n); changed += 1; print("mark", os.path.relpath(f, W), s.count(KEY), "->", n.count(KEY))

web = os.path.join(BRAND, "generated", "web")
for name in os.listdir(web):
    if os.path.exists(os.path.join(W, "images", name)): shutil.copy(os.path.join(web, name), os.path.join(W, "images", name)); print("icon images/" + name)
if os.path.exists(os.path.join(web, "favicon.ico")): shutil.copy(os.path.join(web, "favicon.ico"), os.path.join(W, "favicon.ico")); print("icon favicon.ico")

# Logo image files (left from the upstream build): the tile and "AZET Pass" in the given colour.
def wordmark(color):
    icon = open(os.path.join(BRAND, "pass-icon.svg")).read()
    inner = re.sub(r"^<svg[^>]*>|</svg>\s*$", "", icon.strip())
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1300 320"><g transform="scale(.3125)">{inner}</g>'
            f'<text x="380" y="232" font-family="Helvetica, Arial, sans-serif" font-size="210" font-weight="700" fill="{color}">AZET Pass</text></svg>')
for name, color in (("logo.svg", "#0d0d0d"), ("logo-white.svg", "#ffffff")):
    p = os.path.join(W, "images", name)
    if os.path.exists(p): open(p, "w").write(wordmark(color)); print("logo images/" + name)
for name, color in (("logo-dark@2x.png", "#0d0d0d"), ("logo-primary@2x.png", "#0d0d0d"), ("logo-white@2x.png", "#ffffff")):
    p = os.path.join(W, "images", name)
    if os.path.exists(p):
        subprocess.run(["rsvg-convert", "-h", "86", "-o", p], input=wordmark(color).encode(), check=True); print("logo images/" + name)

left = [f for f in glob.glob(os.path.join(W, "**", "*.js"), recursive=True) if KEY in open(f, encoding="utf-8").read()]
print("bundles changed", changed, "| still old:", left)
sys.exit(1 if left else 0)
