import { scanChart } from './chartpack.mjs';
import crypto from 'node:crypto';
const a = process.argv[2], b = process.argv[3];
function scan(p) { try { return scanChart(p); } catch (e) { if (e.code === 'TIMEGRID') return scanChart(p, { timeMode: 'float' }); throw e; } }
const A = scan(a); const ah = A.sectionHashes; const an = A.noteCount; const ag = A.groupCount;
const askel = crypto.createHash('md5').update(A.skeleton).digest('hex');
A.sections = null;
const B = scan(b); const bh = B.sectionHashes; const bn = B.noteCount; const bg = B.groupCount;
const bskel = crypto.createHash('md5').update(B.skeleton).digest('hex');
let bad = 0, first = -1;
for (let i = 0; i < Math.max(ah.length, bh.length); i++) if (ah[i] !== bh[i]) { bad++; if (first < 0) first = i; }
console.log(JSON.stringify({ notesA: an, notesB: bn, groupsA: ag, groupsB: bg, sectionsA: ah.length, sectionsB: bh.length, badSections: bad, firstBad: first, skeletonSame: askel === bskel }, null, 2));
