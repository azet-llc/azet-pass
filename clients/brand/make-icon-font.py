#!/usr/bin/env python3
# AZET Pass icon font: the upstream bwi-font with each glyph redrawn from Lucide (ISC), same code points, same em
# (1024, descent 128), so every bwi-* class and every \f1xx in upstream CSS keeps working. Map = icon-map.json.
# MARK = rebrand.mjs MARK (brand/mark.svg).
# usage: make-icon-font.py <clients-checkout (pristine tag)> <lucide-static 0.577.0 package dir>
#   -> generated/bwi-font.{ttf,woff,woff2,svg} + generated/bwi-font.json (upstream sha, counts, kept list)
# needs: fontTools, brotli (pip). Outputs are committed so the build needs neither.
import hashlib, json, re, sys
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.pens.areaPen import AreaPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.svgLib.path import parse_path

here = Path(__file__).resolve().parent
clients, lucide = Path(sys.argv[1]), Path(sys.argv[2])
B = clients / 'libs/angular/src/scss/bwicons'
up_ttf = B / 'fonts/bwi-font.ttf'
icon_map = {k: v for k, v in json.loads((here / 'icon-map.json').read_text()).items() if k != '_'}
MARK = 'M13 1a8 8 0 1 1 0 16a8 8 0 0 1 0-16Zm0 5a3 3 0 1 0 0 6a3 3 0 0 0 0-6ZM11 16h4v15h-4ZM15 21h5v3.5h-5ZM15 26.5h4v3.5h-4Z'

# code point -> first name (the glyph's own name; later names are legacy aliases)
scss = (B / 'styles/style.scss').read_text()
names = {}
for n, c in re.findall(r'"([\w-]+)": "\\(\w+)"', re.search(r'\$icons: \((.*?)\);', scss, re.S).group(1)):
    names.setdefault(int(c, 16), n)

bwi, luc = TTFont(up_ttf), TTFont(lucide / 'font/lucide.ttf')
cps = json.loads((lucide / 'font/codepoints.json').read_text())
nodes = json.loads((lucide / 'icon-nodes.json').read_text())
upm, asc = bwi['head'].unitsPerEm, bwi['hhea'].ascent  # 1024, 896
assert upm == 1024 and asc == 896, 'upstream em changed'
lgs, lcmap = luc.getGlyphSet(), luc.getBestCmap()
k24 = upm / 24  # Lucide 24-unit viewBox -> em
svg2font = (k24, 0, 0, -k24, 0, asc)  # y-down viewBox -> y-up font units

def element_path(tag, a):
    f = lambda x: float(a.get(x, 0))
    if tag == 'path': return a['d']
    if tag == 'circle': cx, cy, r = f('cx'), f('cy'), f('r'); return f'M{cx-r} {cy}a{r} {r} 0 1 0 {2*r} 0a{r} {r} 0 1 0 {-2*r} 0Z'
    if tag == 'rect':
        x, y, w, h, r = f('x'), f('y'), f('width'), f('height'), f('rx')
        return f'M{x+r} {y}h{w-2*r}a{r} {r} 0 0 1 {r} {r}v{h-2*r}a{r} {r} 0 0 1 {-r} {r}h{-(w-2*r)}a{r} {r} 0 0 1 {-r} {-r}v{-(h-2*r)}a{r} {r} 0 0 1 {r} {-r}Z'
    raise ValueError(f'cannot fill <{tag}>')

def contours(rec):
    out, cur = [], []
    for op in rec.value:
        if op[0] == 'endPath': op = ('closePath', ())  # a filled shape is closed even when its SVG path is not
        cur.append(op)
        if op[0] == 'closePath': out.append(cur); cur = []
    return out

def area(ops):
    p = AreaPen()
    for o, a in ops: getattr(p, o)(*a)
    return p.value

def lucide_glyph(name, spec):
    if name not in cps: raise SystemExit(f'lucide-static has no "{name}"')
    gname = lcmap[cps[name]]
    rec = RecordingPen()
    lgs[gname].draw(TransformPen(rec, (upm / 1000, 0, 0, upm / 1000, 0, asc - upm)))  # lucide em 1000, y 0..1000
    sign = 1 if area(max(contours(rec), key=lambda c: abs(area(c)))) > 0 else -1
    extra = []
    for i in spec.get('fill', []):
        r = RecordingPen(); parse_path(element_path(*nodes[name][i]), TransformPen(r, svg2font)); extra += [(c, sign) for c in contours(r)]
    for cx, cy, rad in spec.get('holes', []):
        r = RecordingPen(); parse_path(element_path('circle', {'cx': cx, 'cy': cy, 'r': rad}), TransformPen(r, svg2font)); extra += [(c, -sign) for c in contours(r)]
    pen = TTGlyphPen(None)
    for o, a in rec.value: getattr(pen, o)(*a)
    qp = Cu2QuPen(pen, max_err=1, reverse_direction=False)
    for c, s in extra:
        tgt = ReverseContourPen(qp) if (area(c) > 0) != (s > 0) else qp
        for o, a in c: getattr(tgt, o)(*a)
    return pen.glyph()

def mark_glyph():
    h = upm * 20 / 24; kk = h / 32; dx = (upm - 26 * kk) / 2; dy = (upm - h) / 2  # same 2-unit padding as Lucide
    pen = TTGlyphPen(None)
    parse_path(MARK, Cu2QuPen(TransformPen(pen, (kk, 0, 0, -kk, dx, asc - dy)), max_err=1))
    return pen.glyph()

glyf, hmtx, cmap = bwi['glyf'], bwi['hmtx'], bwi.getBestCmap()
assert set(cmap) == set(names), 'upstream code points and style.scss differ'
assert set(icon_map) == set(names.values()), f'icon-map.json out of step with upstream: {sorted(set(names.values()) ^ set(icon_map))}'
mapped, kept, table = 0, [], []
for cp, n in sorted(names.items()):
    spec = icon_map[n]
    spec = {'lucide': spec} if isinstance(spec, str) else spec
    if 'keep' in spec: kept.append((n, spec['keep'])); table.append((hex(cp), n, 'kept: ' + spec['keep'])); continue
    g = mark_glyph() if spec.get('mark') else lucide_glyph(spec['lucide'], spec)
    gn = cmap[cp]; glyf[gn] = g; g.recalcBounds(glyf); hmtx[gn] = (upm, getattr(g, 'xMin', 0))
    mapped += 1; table.append((hex(cp), n, 'AZET mark' if spec.get('mark') else spec['lucide'] + (' (solid)' if 'fill' in spec else '')))
for t in ('hdmx', 'LTSH', 'VDMX', 'DSIG'):
    if t in bwi: del bwi[t]
for r in bwi['name'].names:
    if r.nameID == 0: r.string = 'Glyphs: Lucide 0.577.0 (ISC, lucide.dev) and Bitwarden bwi-font (GPL-3.0); AZET Pass'

out = here / 'generated'
bwi.save(out / 'bwi-font.ttf')
for fl in ('woff', 'woff2'):
    f = TTFont(out / 'bwi-font.ttf'); f.flavor = fl; f.save(out / f'bwi-font.{fl}')
# SVG font (first in upstream's src list; no current engine loads it, kept so no Bitwarden drawing ships in any format)
f = TTFont(out / 'bwi-font.ttf'); gs = f.getGlyphSet(); rows = []
for cp, gn in sorted(f.getBestCmap().items()):
    p = SVGPathPen(gs); gs[gn].draw(p)
    rows.append(f'<glyph unicode="&#x{cp:x};" glyph-name="{names.get(cp, gn)}" horiz-adv-x="{upm}" d="{p.getCommands()}" />')
(out / 'bwi-font.svg').write_text(f'<?xml version="1.0" standalone="no"?>\n<svg xmlns="http://www.w3.org/2000/svg"><defs><font id="bwi-font" horiz-adv-x="{upm}"><font-face font-family="bwi-font" units-per-em="{upm}" ascent="{asc}" descent="{asc - upm}" />\n<missing-glyph horiz-adv-x="{upm}" />\n' + '\n'.join(rows) + '\n</font></defs></svg>\n')
# Lucide drawings the identity step writes as inline SVG (popup tab bar), so the build needs no lucide package
(out / 'lucide-nodes.json').write_text(json.dumps({n: nodes[n] for n in ('vault', 'refresh-cw', 'send', 'settings')}) + '\n')
(out / 'bwi-font.json').write_text(json.dumps({'upstreamTtfSha256': hashlib.sha256(up_ttf.read_bytes()).hexdigest(), 'source': 'lucide-static@0.577.0',
  'glyphs': len(names), 'lucide': mapped - 1, 'mark': 1, 'kept': dict(kept), 'table': table}, indent=1) + '\n')
print(f'bwi-font: {len(names)} glyphs, {mapped - 1} Lucide + 1 mark, kept {len(kept)}: {[k for k, _ in kept]}')
