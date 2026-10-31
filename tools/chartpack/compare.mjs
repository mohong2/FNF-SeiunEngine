import fs from 'node:fs';
import { collectSource } from './chartpack.mjs';

// Semantic comparison of two chart JSONs: same skeleton bytes, same multiset of
// (time, lane, sustain, type) groups with the same repeat counts, per section.
// Times are bucketed at 0.01 ms; the packer's tick reconstruction is within 1e-6 ms.

const a = process.argv[2];
const b = process.argv[3];
if (!a || !b) {
  console.error('usage: node compare.mjs <a.json> <b.json>');
  process.exit(2);
}

function scan(p) {
  return collectSource(() => fs.createReadStream(p, { highWaterMark: 8 << 20 }), { timeMode: 'auto' });
}

const A = await scan(a);
const B = await scan(b);
let bad = 0, first = -1;
const n = Math.max(A.sections.length, B.sections.length);
for (let i = 0; i < n; i++) {
  const x = A.sections[i], y = B.sections[i];
  let differ = !x || !y || x.size !== y.size;
  if (!differ) {
    for (const [k, v] of x) {
      if (y.get(k) !== v) { differ = true; break; }
    }
  }
  if (differ) {
    bad++;
    if (first < 0) first = i;
  }
}

console.log(JSON.stringify({
  notesA: A.notes, notesB: B.notes,
  groupsA: A.groups, groupsB: B.groups,
  sectionsA: A.sections.length, sectionsB: B.sections.length,
  badSections: bad, firstBad: first,
  skeletonSame: A.skeletonMd5 === B.skeletonMd5,
  timeModeA: A.timeMode, timeModeB: B.timeMode,
}, null, 2));
process.exitCode = (bad === 0 && A.skeletonMd5 === B.skeletonMd5) ? 0 : 1;
