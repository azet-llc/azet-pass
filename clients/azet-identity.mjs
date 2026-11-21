// AZET identity for the Angular clients (extension popup, web vault, desktop), run by rebrand.mjs as its last step.
// Every value comes from brand/azet-tokens.json (azet-desktop azet-tokens.ts, the tokens AZET Desktop and the phone
// app use), so Pass cannot drift from them. PARITY rows: ~/Code/azet-suite/reference/azet-pass/PARITY.md 17, 51-56.
//  1. colour: every --color-* in upstream tw-theme.css (light :root and .theme_dark) is written from a token; an
//     upstream variable that is neither mapped nor kept stops the build
//  2. type: Geist (OFL-1.1, the face AZET Desktop ships) with Desktop's fallback stack; sizes snapped to the AZET scale
//  3. shape and motion: radius, transition durations and easings from the tokens
//  4. icons: bwi-font redrawn from Lucide (brand/make-icon-font.py), same code points and class names
//  5. what still looked like Bitwarden: the shield on every login field (inline menu button), illustration and
//     legacy-stylesheet blues
// usage: import { identity } from './azet-identity.mjs'; identity(clientsRoot)
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

const here = path.dirname(new URL(import.meta.url).pathname)
export const TOK = JSON.parse(fs.readFileSync(path.join(here, 'brand/azet-tokens.json'), 'utf8'))
const FAM = { brand: 'blue', gray: 'grey', red: 'red', orange: 'amber', yellow: 'amber', green: 'green', purple: 'purple',
  pink: 'purple', coral: 'red', teal: 'green' } // upstream families with no AZET family fold into the nearest hue

// ref: 'grey.900' (palette of the theme being written), '@accent' (semantic of that theme); 'L:'/'D:' pin a theme;
// [light, dark] when the two differ. AZET's dark palette is already flipped (dark grey.50 is darkest), so one step
// number means the same emphasis in both themes; upstream's dark block re-points instead, which is why the dark
// values here are written from AZET dark directly and never from upstream's dark choices.
export const resolve = (ref, theme) => {
  if (Array.isArray(ref)) ref = ref[theme === 'light' ? 0 : 1]
  const m = ref.match(/^(?:([LD]):)?(.*)$/)
  const t = m[1] ? (m[1] === 'L' ? 'light' : 'dark') : theme
  if (m[2].startsWith('@')) { const v = TOK.semantic[t][m[2].slice(1)]; if (!v) throw new Error(`token ${ref}`); return v }
  const [f, s] = m[2].split('.')
  const v = TOK.palette[t][f]?.[s]
  if (!v) throw new Error(`token ${ref}`)
  return v
}
const rgbOf = (v) => {
  let m = v.match(/^#([0-9a-f]{6})$/i)
  if (m) return [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16))
  m = v.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)/)
  if (m) return m.slice(1, 4).map(Number)
  throw new Error(`not a colour: ${v}`)
}
const triplet = (v, sep = ' ') => { if (/^rgba\(.*,\s*0?\.\d+\)$/.test(v)) throw new Error(`alpha token in a triplet var: ${v}`); return rgbOf(v).join(sep) }

// legacy variables are "r g b" triplets (tailwind rgb(var() / <alpha>))
const LEGACY = {
  shadow: ['L:grey.300', 'D:grey.50'],
  background: '@surfaceDefault', 'background-alt': '@surfaceLower', 'background-alt2': ['@accent', 'grey.200'],
  'background-alt3': ['blue.600', 'grey.300'], 'background-alt4': ['blue.800', 'grey.50'],
  'primary-100': 'blue.100', 'primary-300': 'blue.300', 'primary-600': ['blue.500', 'blue.700'], 'primary-700': ['blue.600', 'blue.800'],
  'secondary-100': ['grey.200', 'grey.300'], 'secondary-300': 'grey.400', 'secondary-500': 'grey.500', 'secondary-600': 'grey.600', 'secondary-700': 'grey.700',
  'info-100': 'blue.100', 'info-600': '@statusInfo', 'info-700': 'blue.800',
  'warning-100': 'amber.100', 'warning-600': '@statusWarning', 'warning-700': 'amber.800',
  'danger-100': 'red.100', 'danger-600': '@statusDanger', 'danger-700': 'red.800',
  'success-100': 'green.100', 'success-600': '@statusSuccess', 'success-700': 'green.800',
  'notification-100': 'purple.100', 'notification-600': 'purple.600',
  'text-main': '@textPrimary', 'text-muted': '@textSecondary', 'text-contrast': ['@surfaceDefault', '@surfaceFloated1'], 'text-alt2': '@textOnAccent', 'text-code': 'purple.600',
  'marketing-logo': ['@accent', '@textPrimary'], 'bw-blue': '@accent',
  'illustration-outline': 'grey.800', 'illustration-bg-primary': 'blue.100', 'illustration-bg-secondary': 'blue.200',
  'illustration-bg-tertiary': '@surfaceDefault', 'illustration-tertiary': ['amber.400', 'amber.600'], 'illustration-logo': ['@accent', '@textPrimary'],
}
// full-value variables (hex or rgba)
const FULL = {
  'transparent-hover': '@surfaceOverlay', 'hover-default': '@surfaceOverlay', 'hover-contrast': 'D:@surfaceOverlay',
  'fg-white': 'L:@textOnAccent', 'fg-dark': 'L:grey.900', 'fg-contrast': '@textOnAccent', 'fg-contrast-strong': 'L:grey.200',
  'fg-heading': '@textPrimary', 'fg-body': 'grey.700', 'fg-body-subtle': ['@textSecondary', '@textTertiary'], 'fg-inactive': '@textDisabled',
  'fg-brand-soft': 'blue.300', 'fg-brand': ['blue.600', 'blue.700'], 'fg-brand-strong': ['blue.700', 'blue.800'],
  'fg-success': '@statusSuccess', 'fg-success-strong': 'green.800', 'fg-danger': '@statusDanger', 'fg-danger-strong': 'red.800',
  'fg-warning': ['amber.800', '@statusWarning'], 'fg-warning-strong': ['amber.900', 'amber.800'], 'fg-sensitive': 'purple.600',
  'bg-white': 'L:@surfaceDefault', 'bg-dark': 'L:grey.800',
  'bg-primary': ['@surfaceDefault', '@surfaceFloated1'], 'bg-secondary': ['@surfaceLower', '@surfaceDefault'], 'bg-tertiary': ['@surfaceLower', '@surfaceDefault'],
  'bg-quaternary': ['grey.200', '@surfaceFloated2'], 'bg-inactive': ['grey.100', '@surfaceLower'],
  'bg-gray': 'grey.500', 'bg-gray-strong': 'grey.600',
  'bg-contrast-soft': ['grey.700', 'grey.300'], 'bg-contrast': ['grey.800', 'grey.400'], 'bg-contrast-strong': ['grey.900', 'grey.500'],
  'bg-brand-softer': 'blue.50', 'bg-brand-soft': 'blue.100', 'bg-brand-medium': 'blue.200', 'bg-brand': '@accentFill',
  'bg-brand-strong': ['blue.600', 'blue.400'], 'bg-brand-stronger': ['blue.700', 'blue.300'],
  'bg-hover': '@surfaceOverlay', 'bg-hover-contrast': 'D:@surfaceOverlay', 'bg-overlay': '@surfaceDim',
  'border-muted': ['grey.100', '@border'], 'border-light': '@border', 'border-base': '@borderInput', 'border-strong': '@borderStrong',
  'border-stronger': ['grey.800', 'grey.600'], 'border-buffer': '@surfaceDefault',
  'border-brand-soft': 'blue.200', 'border-brand': '@accent', 'border-brand-strong': ['blue.600', 'blue.400'],
  // Desktop draws focus with --ring = border-strong (main.css)
  'border-focus': '@borderStrong', 'border-focus-contrast': ['L:@surfaceDefault', 'L:grey.900'],
  // side nav (web vault, desktop): AZET layers instead of a brand-blue column; lower surface, primary text
  'nav-border': '@border', 'nav-fg-body': '@textPrimary', 'nav-fg-heading': '@textSecondary', 'nav-border-focus': '@borderStrong',
  'nav-bg-brand-soft': 'blue.100', 'nav-bg-brand': '@surfaceLower', 'nav-bg-brand-hover': '@surfaceOverlay',
  'nav-bg-admin-soft': 'blue.100', 'nav-bg-admin': '@surfaceLower', 'nav-bg-admin-hover': '@surfaceOverlay',
  'nav-fg-primary': '@textPrimary', 'nav-fg-secondary': '@textPrimary', 'nav-bg-primary': '@surfaceLower', 'nav-bg-secondary': '@surfaceLower',
  'nav-bg-primary-strong': 'blue.100', 'nav-bg-secondary-strong': 'blue.100',
  'nav-bg-primary-hover': '@surfaceOverlay', 'nav-bg-secondary-hover': '@surfaceOverlay',
  'nav-bg-primary-hover-strong': 'grey.200', 'nav-bg-secondary-hover-strong': 'grey.200',
  'nav-border-primary': '@border', 'nav-border-secondary': '@border', 'nav-border-primary-focus': '@borderStrong', 'nav-border-secondary-focus': '@borderStrong',
}
// status, accent, avatar and decorative families: one rule per family
for (const [k, f] of [['success', 'green'], ['danger', 'red'], ['warning', 'amber']]) Object.assign(FULL, {
  [`bg-${k}-soft`]: `${f}.50`, [`bg-${k}-medium`]: `${f}.100`, [`bg-${k}`]: [`${f}.600`, `${f}.500`], [`bg-${k}-strong`]: [`${f}.700`, `${f}.400`],
  [`border-${k}-soft`]: `${f}.200`, [`border-${k}`]: [`${f}.600`, `${f}.500`], [`border-${k}-strong`]: [`${f}.700`, `${f}.400`] })
for (const [k, up] of [['primary', 'teal'], ['secondary', 'coral'], ['tertiary', 'purple']]) {
  const f = FAM[up]
  Object.assign(FULL, { [`fg-accent-${k}-soft`]: `${f}.300`, [`fg-accent-${k}`]: `${f}.500`, [`fg-accent-${k}-strong`]: `${f}.700`,
    [`bg-accent-${k}-soft`]: `${f}.50`, [`bg-accent-${k}-medium`]: `${f}.100`, [`bg-accent-${k}`]: `${f}.500`,
    [`border-accent-${k}-soft`]: `${f}.200`, [`border-accent-${k}`]: `${f}.500` })
  if (k === 'primary') FULL['bg-accent-primary-strong'] = [`${f}.700`, `${f}.300`]
}
for (const up of ['teal', 'coral', 'brand', 'green', 'purple'])
  Object.assign(FULL, { [`bg-avatar-${up}`]: [`${FAM[up]}.600`, `${FAM[up]}.500`], [`bg-avatar-${up}-hover`]: [`${FAM[up]}.700`, `${FAM[up]}.400`] })
for (const up of ['brand', 'teal', 'green', 'orange', 'red', 'purple', 'gray']) {
  const f = FAM[up]
  Object.assign(FULL, { [`bg-decorative-${up}`]: `${f}.100`, [`fg-decorative-${up}`]: `${f}.700`, [`border-decorative-${up}`]: `${f}.200`,
    [`bg-decorative-${up}-bold`]: [`${f}.600`, `${f}.500`], [`fg-decorative-${up}-bold`]: 'L:@textOnAccent', [`border-decorative-${up}-bold`]: [`${f}.500`, `${f}.400`] })
}
const KEEP = new Set(['white', 'white-rgb', 'black', 'black-rgb'])

const primitive = (name) => { // light :root only; upstream's dark block never re-points primitives
  const m = name.match(/^(\w+)-(\d{3})(-rgb)?$/)
  if (!m || !FAM[m[1]]) return null
  const step = m[2] === '950' ? '900' : String(Number(m[2]) || 50)
  const v = resolve(`${FAM[m[1]]}.${step}`, 'light')
  return m[3] ? triplet(v, ', ') : v
}

export function themeCss(upstreamCss) {
  const block = (sel) => upstreamCss.match(new RegExp(`(^|\\n)${sel.replace('.', '\\.')} \\{([\\s\\S]*?)\\n\\}`))[2]
  const names = (b) => [...b.matchAll(/--color-([\w-]+):/g)].map((m) => m[1])
  const up = { light: names(block(':root')), dark: names(block('.theme_dark')) }
  const missing = [...new Set([...up.light, ...up.dark])].filter((n) => !KEEP.has(n) && !LEGACY[n] && !FULL[n] && !primitive(n))
  if (missing.length) throw new Error(`azet-identity: upstream colour variables with no AZET token: ${missing.join(', ')}`)
  const out = {}
  for (const theme of ['light', 'dark']) {
    const lines = []
    if (theme === 'light') for (const n of up.light) { const v = primitive(n); if (v) lines.push(`--color-${n}: ${v};`) }
    for (const [n, r] of Object.entries(LEGACY)) lines.push(`--color-${n}: ${triplet(resolve(r, theme))};`)
    for (const [n, r] of Object.entries(FULL)) lines.push(`--color-${n}: ${resolve(r, theme)};`)
    lines.push(`--tw-ring-offset-color: ${resolve('@surfaceDefault', theme)};`)
    out[theme] = lines
  }
  return `\n/* AZET Pass identity (clients/azet-identity.mjs, generated from brand/azet-tokens.json) */\n:root {\n  ${out.light.join('\n  ')}\n}\n.theme_dark {\n  ${out.dark.join('\n  ')}\n}\nhtml:lang(ko) body { word-break: keep-all; overflow-wrap: anywhere; }\n/* AZET app look: groups are soft panels, not outlined boxes (focus keeps its ring) */\nbit-item, bit-card, bit-card-segmented { border-color: transparent !important; }\n/* dark favicons (GitHub, Apple, X) vanish on a dark card: sit every site icon on a light plate */\n.theme_dark app-vault-icon img { background: #f4f4f5; border-radius: 7px; padding: 2px; box-sizing: border-box; }\n`
}

// WCAG contrast of the pairs people read; the build stops if a token change makes one unreadable
const lum = (v) => rgbOf(v).map((c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4 }).reduce((a, c, i) => a + c * [0.2126, 0.7152, 0.0722][i], 0)
export const contrast = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05) }
export function contrastReport() {
  const v = (n, t) => resolve(FULL[n] ?? LEGACY[n], t)
  const pairs = [['fg-heading', 'bg-primary'], ['fg-body', 'bg-primary'], ['fg-body-subtle', 'bg-primary'], ['fg-heading', 'bg-tertiary'],
    ['fg-body-subtle', 'bg-tertiary'], ['fg-contrast', 'bg-brand'], ['fg-contrast', 'bg-brand-strong'], ['fg-brand', 'bg-primary'],
    ['fg-danger', 'bg-primary'], ['fg-success', 'bg-primary'], ['fg-warning', 'bg-primary'], ['fg-contrast', 'bg-danger'],
    ['fg-contrast', 'bg-contrast'], ['nav-fg-body', 'nav-bg-brand'], ['text-main', 'background'], ['text-muted', 'background'],
    ['fg-decorative-brand', 'bg-decorative-brand'], ['fg-decorative-brand-bold', 'bg-decorative-brand-bold']]
  const rows = []
  for (const t of ['light', 'dark']) for (const [f, b] of pairs) rows.push({ t, f, b, r: contrast(v(f, t), v(b, t)), min: 4.5 })
  for (const t of ['light', 'dark']) rows.push({ t, f: 'border-focus', b: 'bg-primary', r: contrast(v('border-focus', t), v('bg-primary', t)), min: 3 })
  return rows
}

// one map from upstream hard-coded hex (illustrations, legacy SCSS, content-script styles) to AZET token values
const BW_HEX = {
  '175ddc': 'L:@accent', '1252a3': 'L:blue.600', '0e3781': 'L:blue.800', '0c3276': 'L:blue.800', '0d43af': 'L:blue.600',
  'dbe5f6': 'L:blue.100', 'dbeafe': 'L:blue.100', 'eef6ff': 'L:blue.50', 'aac3ef': 'L:blue.200', '99baf4': 'L:blue.300',
  '79a1e9': 'L:blue.400', '65abff': 'L:blue.400', '007fde': 'L:blue.600', '1452c1': 'L:blue.600', '6f9df1': 'D:blue.700',
  'ffbf00': 'L:amber.400', 'fdc700': 'L:amber.400', 'ff6550': 'L:red.400', 'a2f4fd': 'L:green.200',
  'c40800': 'L:red.600', 'b80017': 'L:red.600', 'c71800': 'L:red.600', 'a81400': 'L:red.700', 'ff8d85': 'D:red.700',
  '8200db': 'L:purple.600', '6e11b0': 'L:purple.700', 'c01176': 'L:purple.600', 'f08dc7': 'D:purple.700',
  '008236': 'L:green.600', '016630': 'L:green.700', '007c95': 'L:blue.700', '006278': 'L:blue.800',
  '017e45': 'L:@statusSuccess', '52e07c': 'D:@statusSuccess', '8db89b': 'D:@statusSuccess',
  'c83522': 'L:@statusDanger', 'ee9792': 'D:@statusDanger', '8b6609': 'L:amber.800', 'ffeb66': 'D:@statusWarning',
  '1b2029': 'L:@textPrimary', '212529': 'L:@textPrimary', '0f172b': 'L:grey.900', '6c747c': 'L:@textSecondary', '5a6d91': 'L:grey.600',
  '6b7280': 'L:grey.500', '8496b0': 'L:grey.400', 'a8b3c8': 'L:grey.400', 'c7c7cd': 'L:grey.400', 'c3c5c7': 'L:grey.300', 'ced4dc': 'L:@border',
  'd8e2eb': 'L:grey.200', 'e6e9ef': 'L:grey.200', 'ededed': 'L:grey.200', 'eeeeee': 'L:@border', 'f0f0f0': 'L:@surfaceLower',
  'f3f6f9': 'L:grey.100', 'f3f4f6': 'L:grey.100', 'f8f9fa': 'L:grey.50', 'f9f9f9': 'L:grey.50', 'fbfbfb': 'L:grey.50',
  '1f242e': 'D:@surfaceDefault', '202733': 'D:@surfaceDefault', '2f343d': 'D:@surfaceFloated1', '303946': 'D:grey.300',
  '15181e': 'D:@surfaceLower', '161c26': 'D:@surfaceLower', '3c424e': 'D:@surfaceFloated2', '4c525f': 'D:grey.400', '272b32': 'D:grey.200',
  '6e788a': 'D:grey.500', '6e7689': 'D:grey.500', '8d94a5': 'D:grey.600', 'a4b0c6': 'D:grey.600', 'bac0ce': 'D:@textSecondary',
}
const BW_HEX3 = { ddd: 'L:grey.300', '555': 'L:grey.700', '777': 'L:@textSecondary' }
export const recolour = (s) => s
  .replace(/#([0-9a-f]{6})\b/gi, (m, h) => BW_HEX[h.toLowerCase()] ? resolve(BW_HEX[h.toLowerCase()]) : m)
  .replace(/#([0-9a-f]{3})\b(?![0-9a-f])/gi, (m, h) => BW_HEX3[h.toLowerCase()] ? resolve(BW_HEX3[h.toLowerCase()]) : m)

const FONT_STACK = `"Geist", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif` // azet-desktop app-font-family.ts
const px = (n) => `${n / 16}rem` // popup, web and desktop keep the 16px root
const ms = (n) => `${n}ms`

export function identity(root) {
  const p = (...a) => path.join(root, ...a)
  const edit = (file, fn) => {
    if (!fs.existsSync(p(file))) return false
    const before = fs.readFileSync(p(file), 'utf8'), after = fn(before)
    if (after === before) throw new Error(`azet-identity: no change in ${file} (upstream moved?)`)
    fs.writeFileSync(p(file), after)
    return true
  }
  const must = (s, a, b) => { if (!(a instanceof RegExp ? a.test(s) : s.includes(a))) throw new Error(`azet-identity: ${String(a).slice(0, 70)} not found`); return s.replace(a, b) }

  // 1. colour
  for (const r of contrastReport()) if (r.r < r.min) throw new Error(`azet-identity: ${r.f} on ${r.b} (${r.t}) contrast ${r.r.toFixed(2)} < ${r.min}`)
  edit('libs/components/src/tw-theme.css', (s) => s + themeCss(s))

  // 2. type: Geist instead of Inter; sizes snapped to the AZET scale (body 14, the Toss/AZET centre; headings keep rank)
  fs.copyFileSync(path.join(here, 'brand/fonts/Geist-Variable.woff2'), p('libs/components/src/webfonts/geist.woff2'))
  edit('libs/components/src/theme.css', (s) => must(must(s, /font-family: Inter;\s*src:\s*url\("~@bitwarden\/components\/src\/webfonts\/inter\.woff2"\) format\("woff2"\) tech\(variations\),\s*url\("~@bitwarden\/components\/src\/webfonts\/inter\.woff2"\) format\("woff2-variations"\);/,
    'font-family: Geist;\n  src:\n    url("~@bitwarden/components/src/webfonts/geist.woff2") format("woff2") tech(variations),\n    url("~@bitwarden/components/src/webfonts/geist.woff2") format("woff2-variations");'),
    /--font-sans:\s*Inter, "Helvetica Neue", Helvetica, Arial, sans-serif,/, `--font-sans:\n    ${FONT_STACK},`))
  const z = TOK.type.size, lh = TOK.type.lineHeight
  const fs_ = (n, h) => `[${JSON.stringify(px(n))}, "${h}"]`
  const D = TOK.motion.durationsMs, E = TOK.motion.easing, R = TOK.radiusPx
  edit('libs/components/tailwind.config.base.js', (s) => must(must(s,
    /      fontSize: \{\n        "3xl": \["1\.875rem", "150%"\],\n        "2xl": \["1\.5rem", "150%"\],\n        xl: \["1\.25rem", "150%"\],\n        lg: \["1\.125rem", "150%"\],\n        md: \["1rem", "150%"\],\n        base: \["1rem", "150%"\],\n        sm: \["0\.875rem", "150%"\],\n        xs: \["\.75rem", "150%"\],\n/,
    `      // AZET type scale (azet-tokens type.size); xxs (8px count dot) is below the scale and stays
      fontSize: {
        "3xl": ${fs_(z['5xl'], lh.tight)},
        "2xl": ${fs_(z['4xl'], lh.tight)},
        xl: ${fs_(z['3xl'], lh.normal)},
        lg: ${fs_(z['2xl'], lh.normal)},
        md: ${fs_(z.xl, lh.normal)},
        base: ${fs_(z.base, lh.normal)},
        sm: ${fs_(z.md, lh.normal)},
        xs: ${fs_(z.sm, lh.normal)},
`),
    // 3. shape and motion
    /      animation: \{\n        "slide-up": "slideUp 0\.3s ease-out",\n        "slide-down": "slideDown 0\.3s ease-out",\n      \},\n/,
    `      animation: {
        "slide-up": "slideUp ${ms(D.slower)} ${E.emphasized}",
        "slide-down": "slideDown ${ms(D.slower)} ${E.emphasized}",
      },
      // AZET radius and motion (azet-tokens radiusPx, motion): frame-based durations, three curves
      borderRadius: { sm: "${R.xs}px", DEFAULT: "${R.xs}px", md: "${R.sm}px", lg: "${R.md}px", xl: "${R.lg}px", "2xl": "${R.xl}px", "3xl": "${R['2xl']}px", full: "${R.pill}px" },
      transitionDuration: { DEFAULT: "${ms(D.moderate)}", 75: "${ms(D.instant)}", 100: "${ms(D.fast)}", 150: "${ms(D.moderate)}", 200: "${ms(D.slow)}", 300: "${ms(D.slower)}", 500: "${ms(D.slower)}", 700: "${ms(D.slower)}", 1000: "${ms(D.slower)}" },
      transitionTimingFunction: { DEFAULT: "${E.snappy}", in: "${E.exit}", out: "${E.emphasized}", "in-out": "${E.snappy}" },
`))

  // 4. icons: same file names, so style.scss/style.css and every bwi-* class stay upstream's
  const meta = JSON.parse(fs.readFileSync(path.join(here, 'brand/generated/bwi-font.json'), 'utf8'))
  const fontDir = 'libs/angular/src/scss/bwicons/fonts/'
  const sha = crypto.createHash('sha256').update(fs.readFileSync(p(fontDir + 'bwi-font.ttf'))).digest('hex')
  if (sha !== meta.upstreamTtfSha256) throw new Error('azet-identity: upstream bwi-font.ttf changed; rerun brand/make-icon-font.py on this tag')
  for (const ext of ['ttf', 'woff', 'woff2', 'svg']) fs.copyFileSync(path.join(here, `brand/generated/bwi-font.${ext}`), p(fontDir + `bwi-font.${ext}`))

  // 5. the shield on every login field (inline menu button) -> our mark on an accent tile, same 14/16 px boxes
  const MARK = 'M13 1a8 8 0 1 1 0 16a8 8 0 0 1 0-16Zm0 5a3 3 0 1 0 0 6a3 3 0 0 0 0-6ZM11 16h4v15h-4ZM15 21h5v3.5h-5ZM15 26.5h4v3.5h-4Z'
  const A = resolve('L:@accent')
  const tile = `<rect width="14" height="14" rx="${R.xs - 1}" fill="${A}"/><path fill="#fff" fill-rule="evenodd" transform="translate(2.94 2) scale(0.3125)" d="${MARK}"/>`
  edit('apps/browser/src/autofill/utils/svg-icons.ts', (s) => {
    const shield = /<path fill="#175DDC" d="M12\.66\.175A[^"]*"\/><path fill="#fff" d="M7 12\.365s4\.306-2\.18 4\.306-4\.717V1\.5H7v10\.865Z"\/>/g
    if ((s.match(shield) || []).length !== 2) throw new Error('azet-identity: inline menu shield moved')
    return recolour(s.replace(shield, tile))
  })
  // ...and the upstream snapshot tests of those inline-menu pages, which print the same SVGs attribute by attribute
  const snapTile = (i) => `${i}<rect${i}  fill="${A}"${i}  height="14"${i}  rx="${R.xs - 1}"${i}  width="14"${i}/>${i}<path${i}  d="${MARK}"${i}  fill="#fff"${i}  fill-rule="evenodd"${i}  transform="translate(2.94 2) scale(0.3125)"${i}/>`
  for (const k of ['button/__snapshots__/autofill-inline-menu-button.spec.ts.snap', 'list/__snapshots__/autofill-inline-menu-list.spec.ts.snap'])
    edit('apps/browser/src/autofill/overlay/inline-menu/pages/' + k, (s) => recolour(s.replace(
      /(\n\s*)<path\1  d="M12\.66\.175A[^"]*"\1  fill="#175DDC"\1\/>\1<path\1  d="M7 12\.365s4\.306-2\.18 4\.306-4\.717V1\.5H7v10\.865Z"\1  fill="#fff"\1\/>/g, (m, i) => snapTile(i))))
  // popup tab bar: Lucide drawings (stroke 2, the AZET Desktop icon style); active = brand stroke + soft fill
  const nodes = JSON.parse(fs.readFileSync(path.join(here, 'brand/generated/lucide-nodes.json'), 'utf8'))
  const lucideSvg = (name, active) => `
  <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="${active ? 'tw-text-fg-brand' : 'tw-text-fg-body'}">
    ${nodes[name].map(([tag, a], i) => `<${tag} ${Object.entries(a).map(([k, v]) => `${k}="${v}"`).join(' ')}${active && i === 0 && name !== 'refresh-cw' ? ' class="tw-fill-fg-brand-soft"' : ''}/>`).join('\n    ')}
  </svg>
`
  for (const [file, name, base] of [['vault', 'vault', 'Vault'], ['generator', 'refresh-cw', 'Generator'], ['send', 'send', 'Send'], ['settings', 'settings', 'Settings']])
    edit(`libs/assets/src/svg/svgs/${file}.ts`, (s) => ['Inactive', 'Active'].reduce((t, k) =>
      must(t, new RegExp(`(export const ${base}${k} = svg\`)[\\s\\S]*?(\`;)`), `$1${lucideSvg(name, k === 'Active')}$2`), s))
  // illustrations and icons drawn with hard-coded upstream colours
  for (const f of ['apps/browser/src/autofill/content/components/illustrations/celebrate.ts', 'apps/browser/src/autofill/content/components/illustrations/keyhole.ts',
    'apps/browser/src/autofill/popup/default-password-manager/default-password-manager-illustrations.ts', 'libs/assets/src/svg/svgs/extension-mock-login.ts',
    'libs/components/src/avatar/avatar.component.ts', 'libs/components/src/icon-tile/icon-tile.component.ts', 'libs/components/src/icon-tile/icon-tile.ts'])
    edit(f, recolour)
  // legacy stylesheets (popup, desktop, inline menu and notification bar pages): colours, font, radius
  for (const f of ['apps/browser/src/popup/scss/variables.scss', 'apps/desktop/src/scss/variables.scss', 'apps/browser/src/autofill/shared/styles/variables.scss'])
    edit(f, (s) => recolour(s).replace(/\$font-family-sans-serif: Inter, "Helvetica Neue", Helvetica, Arial, sans-serif;/, `$font-family-sans-serif: ${FONT_STACK};`).replace(/\$border-radius: 3px;/, `$border-radius: ${R.xs}px;`))
  // notification bar / inline menu web components (content scripts): the legacy palette as JS objects
  edit('apps/browser/src/autofill/content/components/constants/styles.ts', (s) => {
    const obj = (t) => { const c = (r) => `rgba(${triplet(resolve(r, t), ', ')})`, L = (k) => c(LEGACY[k])
      return `{\n  transparent: {\n    hover: \`${resolve('@surfaceOverlay', t)}\`,\n  },\n  shadow: \`${L('shadow')}\`,\n` +
        ['primary', 'secondary', 'success', 'danger', 'warning', 'info'].map((g) => `  ${g}: {\n${Object.keys(LEGACY).filter((k) => k.startsWith(g + '-')).map((k) => `    ${k.slice(g.length + 1)}: \`${L(k)}\`,`).join('\n')}\n  },\n`).join('') +
        `  art: {\n    primary: \`${L('illustration-outline')}\`,\n    accent: \`${L('illustration-tertiary')}\`,\n  },\n` +
        `  text: {\n${['main', 'muted', 'contrast', 'alt2', 'code'].map((k) => `    ${k}: \`${L('text-' + k)}\`,`).join('\n')}\n  },\n` +
        `  background: {\n    DEFAULT: \`${L('background')}\`,\n${['alt', 'alt2', 'alt3', 'alt4'].map((k) => `    ${k}: \`${L('background-' + k)}\`,`).join('\n')}\n  },\n` +
        `  brandLogo: \`${L('marketing-logo')}\`,\n  passwordSpecial: \`${c('red.600')}\`,\n  passwordNumber: \`${c('blue.600')}\`,\n}` }
    return must(must(s, /const lightTheme = \{[\s\S]*?\n\};\n\nconst darkTheme = \{[\s\S]*?\n\};\n/, `const lightTheme = ${obj('light')};\n\nconst darkTheme = ${obj('dark')};\n`),
      /    large: `8px`,/, `    large: \`${R.md}px\`,`).replaceAll('font-family: Inter, sans-serif;', `font-family: ${FONT_STACK};`)
  })
  for (const f of ['apps/browser/src/autofill/content/components/notification/at-risk-password/message.ts', 'apps/browser/src/autofill/content/components/notification/confirmation/message.ts',
    'apps/browser/src/autofill/content/components/notification/header-message.ts'])
    edit(f, (s) => s.replaceAll('font-family: Inter, sans-serif;', `font-family: ${FONT_STACK};`))
  // the extension-wide button radius change of the earlier violet theme is gone: buttons keep upstream rounded-xl = AZET lg
}
