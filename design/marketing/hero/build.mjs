// Build hero.svg from hero.src.svg: embed the board's fonts and place the chips.
//
// GitHub shows a README's SVG through <img>, which loads nothing from the
// network, so the fonts travel inside the file as data URIs. Run from anywhere:
//
//     node design/marketing/hero/build.mjs
import { readFileSync, writeFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const fonts = join(here, '..', '..', 'proposals', '2026-09-24-ship-v2', 'fonts');

// chip widths, measured against the embedded Barlow Semi Condensed 600 at 18px
const CHIP_X = 64, CHIP_GAP = 12, CHIP_W = [180, 234, 166];

const dataUri = (name) =>
  'data:font/woff2;base64,' + readFileSync(join(fonts, name)).toString('base64');

let svg = readFileSync(join(here, 'hero.src.svg'), 'utf8')
  .replace('__FONT_FELL__', dataUri('im-fell-english-sc-400.woff2'))
  .replace('__FONT_B500__', dataUri('barlow-semi-condensed-500.woff2'))
  .replace('__FONT_B600__', dataUri('barlow-semi-condensed-600.woff2'));
let x = CHIP_X;
CHIP_W.forEach((w, i) => {
  svg = svg.replace(`__X${i + 1}__`, String(x)).replace(`__W${i + 1}__`, String(w));
  x += w + CHIP_GAP;
});
if (svg.includes('__')) throw new Error('unfilled placeholder in hero.src.svg');
const out = join(here, 'hero.svg');
writeFileSync(out, svg);
console.log(`hero.svg: ${statSync(out).size} bytes`);
