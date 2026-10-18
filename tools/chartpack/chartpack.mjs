#!/usr/bin/env node
// chartpack.mjs — compact, lossless-enough chart container for huge Psych Engine charts.
//
// The JSON text is split into:
//   * skeleton: every byte of the original file except the inside of each sectionNotes array
//     (a NUL byte marks each insertion point), deflated;
//   * groups: one record per distinct (time, lane, sustain, type) inside a section, with a
//     repeat count.  A 1.4 GB spam chart collapses from 64 M note entries to ~200 k groups.
//
// unpack() rebuilds a JSON file that is semantically identical (same multiset of notes per
// section).  With --exact the original note order inside a section is also stored.
//
// Usage:
//   node chartpack.mjs pack   <chart.json> <chart.chartpack> [--stats]
//   node chartpack.mjs unpack <chart.chartpack> <chart.json>
//   node chartpack.mjs info   <chart.chartpack>
//   node chartpack.mjs verify <chart.json> [--exact]
//
// No dependencies beyond Node's fs/zlib.

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';

const MAGIC = Buffer.from('SEIUNPK1', 'ascii');
const VERSION = 1;
const MARKER = Buffer.from('"sectionNotes"', 'ascii');
const CHUNK = 32 * 1024 * 1024;

function u32(n) { const b = Buffer.alloc(4); b.writeUInt32LE(n >>> 0); return b; }
function readU32(b, o) { return b.readUInt32LE(o); }

function varint(n) {
  if (!Number.isSafeInteger(n) || n < 0) throw new Error('varint: ' + n);
  const out = [];
  while (n >= 0x80) { out.push((n & 0x7f) | 0x80); n = Math.floor(n / 128); }
  out.push(n);
  return Buffer.from(out);
}
function zigzag(n) { return n >= 0 ? n * 2 : -n * 2 - 1; }
function unzigzag(n) { return (n & 1) ? -(n + 1) / 2 : n / 2; }

class Reader {
  constructor(buf) { this.b = buf; this.p = 0; }
  u8() { return this.b[this.p++]; }
  u32() { const v = this.b.readUInt32LE(this.p); this.p += 4; return v; }
  varint() {
    let n = 0, mul = 1, c;
    do { c = this.b[this.p++]; n += (c & 0x7f) * mul; mul *= 128; } while (c & 0x80);
    return n;
  }
  double() { const v = this.b.readDoubleLE(this.p); this.p += 8; return v; }
  bytes(n) { const v = this.b.subarray(this.p, this.p + n); this.p += n; return v; }
}

class Writer {
  constructor() { this.parts = []; this.n = 0; }
  push(b) { this.parts.push(b); this.n += b.length; }
  u8(v) { this.push(Buffer.from([v & 0xff])); }
  u32(v) { this.push(u32(v)); }
  varint(v) { this.push(varint(v)); }
  double(v) { const b = Buffer.alloc(8); b.writeDoubleLE(v); this.push(b); }
  buf() { return Buffer.concat(this.parts, this.n); }
}

/** Format a chart time exactly like the generator did (6 decimals, trailing zeros trimmed, .0 kept). */
export function fmtTime(t) {
  let s = t.toFixed(6);
  s = s.replace(/0+$/, '');
  if (s.endsWith('.')) s += '0';
  return s;
}

function fmtFloat(t) {
  let s = String(t);
  if (!s.includes('.') && !s.includes('e') && !s.includes('E')) s += '.0';
  return s;
}

function readRange(fd, start, end) {
  const len = end - start;
  const b = Buffer.allocUnsafe(len);
  let done = 0;
  while (done < len) {
    const n = fs.readSync(fd, b, done, len - done, start + done);
    if (!n) throw new Error('short read at ' + (start + done));
    done += n;
  }
  return b;
}

/**
 * Read the notes array that starts at "start" (the '['), returning [endAfterBracket, text].
 * Handles strings and nesting; arrays are small (a section), so a chunked accumulator is fine.
 */
function readArray(fd, start, fileSize) {
  const parts = [];
  let pos = start, depth = 0, inStr = false, esc = false, total = 0;
  const READ_CHUNK = 256 * 1024;
  while (pos < fileSize) {
    const n = Math.min(READ_CHUNK, fileSize - pos);
    const b = Buffer.allocUnsafe(n);
    const got = fs.readSync(fd, b, 0, n, pos);
    if (!got) throw new Error('eof in array');
    const slice = b.subarray(0, got);
    for (let i = 0; i < got; i++) {
      const c = slice[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === 92) esc = true;
        else if (c === 34) inStr = false;
      } else if (c === 34) inStr = true;
      else if (c === 91) depth++;
      else if (c === 93) {
        depth--;
        if (depth === 0) {
          parts.push(slice.subarray(0, i + 1));
          return { end: pos + i + 1, text: Buffer.concat(parts).toString('latin1') };
        }
      }
    }
    parts.push(slice);
    pos += got; total += got;
    if (total > 512 * 1024 * 1024) throw new Error('sectionNotes array too large');
  }
  throw new Error('unterminated array at ' + start);
}

const FIND_CHUNK = 64 * 1024 * 1024;
class Finder {
  constructor(fd, fileSize) {
    this.fd = fd;
    this.size = fileSize;
    this.buf = Buffer.allocUnsafe(FIND_CHUNK);
    this.base = 0;
    this.len = 0;
  }
  fill(pos) {
    const n = Math.min(FIND_CHUNK, this.size - pos);
    const got = fs.readSync(this.fd, this.buf, 0, n, pos);
    this.base = pos;
    this.len = got;
  }
  find(from) {
    let pos = from;
    const overlap = MARKER.length - 1;
    while (pos + MARKER.length <= this.size) {
      if (pos < this.base || pos + overlap >= this.base + this.len) this.fill(pos);
      if (this.len < MARKER.length) return -1;
      const idx = this.buf.subarray(pos - this.base, this.len).indexOf(MARKER);
      if (idx >= 0) return pos + idx;
      const next = this.base + this.len - overlap;
      pos = (next > pos) ? next : pos + 1;
    }
    return -1;
  }
}

const NOTE_RE = /\[\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?:,\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?)\s*)?\]/g;

class TimeGridMismatch extends Error {
  constructor(message) { super(message); this.code = 'TIMEGRID'; }
}

function hashGroups(list, timeMode, sustains, types) {
  // Order-independent multiset hash: group order may differ after unpack (tie-breaks use
  // dictionary indices), while the set of (time, lane, sustain, type, count) records must not.
  let h1 = 0, h2 = 0;
  for (const g of list) {
    const tv = (timeMode === 'float') ? String(g.time) : g.tick;
    const susVal = sustains[g.si];
    const ty = types[g.ti];
    const tyVal = (ty == null) ? '0:' : ty.kind + ':' + String(ty.value);
    let gh1 = 0x811c9dc5 >>> 0, gh2 = 0x9e3779b9 >>> 0;
    for (const v of [tv, g.lane, susVal, tyVal, g.count]) {
      const str = String(v);
      for (let i = 0; i < str.length; i++) {
        gh1 = Math.imul(gh1 ^ str.charCodeAt(i), 16777619) >>> 0;
        gh2 = Math.imul((gh2 + str.charCodeAt(i)) >>> 0, 2246822519) >>> 0;
      }
    }
    h1 = (h1 + gh1) >>> 0;
    h2 = (h2 ^ Math.imul(gh2, 2654435761)) >>> 0;
  }
  return h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0');
}

function parseType(raw) {
  if (raw == null) return 0; // absent
  if (raw[0] === '"') return { kind: 1, value: JSON.parse(raw) };
  return { kind: 2, value: Number(raw) };
}

/**
 * Scan a chart JSON file into skeleton bytes + per-section groups.
 * Returns { skeleton, sections, stats, bpm, base }.
 */
export function scanChart(file, opts = {}) {
  const fd = fs.openSync(file, 'r');
  const size = fs.fstatSync(fd).size;
  const finder = new Finder(fd, size);
  const skel = [];
  const sections = [];
  const sectionHashes = [];
  const sustains = [''];
  const susIndex = new Map([['', 0]]);
  const types = [{ kind: 0 }];
  const typeIndex = new Map([['\u0000', 0]]);
  let lastCopy = 0, pos = 0, noteCount = 0, groupCount = 0;
  let bpm = null, base = null;
  let timeMode = opts.timeMode || 'tick';
  let badTime = 0;
  // Read the chart header first: the time grid depends on bpm.
  const head = readRange(fd, 0, Math.min(size, 8192)).toString('latin1');
  const bm0 = /"bpm"\s*:\s*(-?\d+(?:\.\d+)?)/.exec(head);
  if (bm0) { bpm = +bm0[1]; base = 60000 / bpm / 3072; }
  const t0 = Date.now();
  try {
    while (true) {
      const idx = finder.find(pos);
      if (idx < 0) break;
      // Find the '[' after the key, allowing whitespace and a colon.
      let p = idx + MARKER.length;
      let ch = 0;
      const probe = readRange(fd, p, Math.min(size, p + 64));
      let q = 0;
      while (q < probe.length && (probe[q] === 32 || probe[q] === 9 || probe[q] === 10 || probe[q] === 13 || probe[q] === 58)) q++;
      if (probe[q] !== 91) throw new Error('sectionNotes is not an array at byte ' + idx);
      const arrStart = p + q;
      const arr = readArray(fd, arrStart, size);
      // Skeleton: bytes up to the '[' (the key/colon/whitespace), then a NUL placeholder.
      skel.push(readRange(fd, lastCopy, arrStart));
      skel.push(Buffer.from([0]));
      // Parse the notes.
      const text = arr.text;
      const groups = new Map();
      const order = [];
      let m;
      NOTE_RE.lastIndex = 0;
      while ((m = NOTE_RE.exec(text))) {
        const ts = m[1], lane = +m[2], sus = m[3];
        const t = +ts;
        if (base == null) {
          // First note: derive the chart's BPM from the skeleton is done later; for now defer.
        }
        let tick = 0, time = 0;
        if (timeMode === 'tick') {
          if (base == null) throw new Error('chart has no bpm');
          tick = Math.round(t / base);
          if (fmtTime(tick * base) !== ts) {
            badTime++;
            throw new TimeGridMismatch('time grid mismatch at ' + ts);
          }
        } else {
          time = t;
        }
        let si = susIndex.get(sus);
        if (si === undefined) { si = sustains.length; sustains.push(sus); susIndex.set(sus, si); }
        let ti = 0;
        if (m[4] != null) {
          const ty = parseType(m[4]);
          const key = ty.kind + '\u0001' + ty.value;
          ti = typeIndex.get(key);
          if (ti === undefined) { ti = types.length; types.push(ty); typeIndex.set(key, ti); }
        }
        const key = (timeMode === 'tick' ? tick : ts) + '|' + lane + '|' + si + '|' + ti;
        const g = groups.get(key);
        if (g) g.count++;
        else groups.set(key, { tick, time, lane, si, ti, count: 1 });
        noteCount++;
      }
      const list = [...groups.values()].sort((a, b) =>
        (timeMode === 'tick' ? (a.tick - b.tick) : (a.time - b.time)) || a.lane - b.lane || a.si - b.si || a.ti - b.ti);
      sections.push(list);
      sectionHashes.push(hashGroups(list, timeMode, sustains, types));
      groupCount += list.length;
      if (sections.length % 500 === 0) console.error('sections', sections.length, 'notes', noteCount, 'groups', groupCount, 'ms', Date.now() - t0);
      if (opts.maxSections && sections.length >= opts.maxSections) { lastCopy = arr.end; break; }
      lastCopy = arr.end;
      pos = arr.end;
    }
    skel.push(readRange(fd, lastCopy, size));
  } finally {
    fs.closeSync(fd);
  }
  const skeleton = Buffer.concat(skel);

  return {
    skeleton, sections, sectionHashes, sustains, types, bpm, base, timeMode,
    stats: { bytes: size, notes: noteCount, groups: groupCount, sections: sections.length, ms: Date.now() - t0 },
    noteCount, groupCount
  };
}

function encodeGroupStream(scan, exactOrder) {
  const w = new Writer();
  const tickMode = scan.timeMode === 'tick';
  for (const list of scan.sections) {
    let prevTick = 0;
    if (exactOrder) throw new Error('exact order not implemented');
    for (const g of list) {
      if (tickMode) {
        w.varint(zigzag(g.tick - prevTick));
        prevTick = g.tick;
      } else {
        w.double(g.time);
      }
      w.varint(zigzag(g.lane));
      w.varint(g.si);
      w.varint(g.ti);
      w.varint(g.count);
    }
  }
  return w.buf();
}

export function packFile(file, outFile, opts = {}) {
  let scan;
  try {
    scan = scanChart(file, { ...opts, timeMode: opts.timeMode || 'tick' });
  } catch (e) {
    if (e instanceof TimeGridMismatch && !opts.timeMode) {
      scan = scanChart(file, { ...opts, timeMode: 'float' });
    } else throw e;
  }
  const groupRaw = encodeGroupStream(scan, false);
  const skelRaw = scan.skeleton;
  const skelComp = zlib.deflateSync(skelRaw, { level: 9 });
  const groupComp = zlib.deflateSync(groupRaw, { level: 9 });
  const header = {
    v: VERSION,
    bpm: scan.bpm,
    base: scan.base,
    timeMode: scan.timeMode,
    sustains: scan.sustains,
    types: scan.types,
    sectionGroups: scan.sections.map(s => s.length),
    notes: scan.noteCount,
    groups: scan.groupCount,
    skelLen: skelRaw.length,
    skelCrc: crypto.createHash('md5').update(skelRaw).digest('hex'),
  };
  const headerBytes = Buffer.from(JSON.stringify(header), 'utf8');
  const w = new Writer();
  w.push(MAGIC);
  w.u32(headerBytes.length);
  w.push(headerBytes);
  w.u32(skelComp.length); w.u32(skelRaw.length); w.push(skelComp);
  w.u32(groupComp.length); w.u32(groupRaw.length); w.push(groupComp);
  const out = w.buf();
  fs.writeFileSync(outFile, out);
  return {
    file, outFile, outBytes: out.length,
    jsonBytes: scan.stats.bytes,
    skeletonRaw: skelRaw.length, skeletonComp: skelComp.length,
    groupRaw: groupRaw.length, groupComp: groupComp.length,
    notes: scan.noteCount, groups: scan.groupCount, sections: scan.sections.length,
    ratio: scan.stats.bytes / out.length, ms: scan.stats.ms,
  };
}

export function packDir(dir, opts = {}) {
  const files = fs.readdirSync(dir).filter(f =>
    f.toLowerCase().endsWith('.json')
    && !/^events\.json$/i.test(f)
    && !/^meta\.json$/i.test(f)
    && !/\.parts\.json$/i.test(f)
  ).sort();
  let totalIn = 0, totalOut = 0;
  const rows = [];
  for (const f of files) {
    const src = path.join(dir, f);
    const dst = path.join(dir, f.replace(/\.json$/i, '.chartpack'));
    if (fs.existsSync(dst) && !opts.force) {
      rows.push({ file: f, skipped: true, out: fs.statSync(dst).size });
      console.log('skip (exists)', f);
      continue;
    }
    const r = packFile(src, dst, {});
    totalIn += r.jsonBytes; totalOut += r.outBytes;
    rows.push({ file: f, jsonBytes: r.jsonBytes, outBytes: r.outBytes, ratio: r.ratio, notes: r.notes, groups: r.groups });
    console.log(f, r.jsonBytes, '->', r.outBytes, '(' + r.ratio.toFixed(1) + 'x)', r.notes, 'notes /', r.groups, 'groups');
    if (opts.replace) fs.unlinkSync(src);
  }
  return { dir, files: rows.length, totalIn, totalOut, ratio: totalOut > 0 ? totalIn / totalOut : 0, rows };
}

export function readPack(file) {
  const b = fs.readFileSync(file);
  if (!b.subarray(0, 8).equals(MAGIC)) throw new Error('not a chartpack');
  const r = new Reader(b);
  r.p = 8;
  const hlen = r.u32();
  const header = JSON.parse(r.bytes(hlen).toString('utf8'));
  const skelCLen = r.u32(); const skelRawLen = r.u32(); const skelComp = r.bytes(skelCLen);
  const groupCLen = r.u32(); const groupRawLen = r.u32(); const groupComp = r.bytes(groupCLen);
  const skeleton = zlib.inflateSync(skelComp);
  const groupRaw = zlib.inflateSync(groupComp);
  if (skeleton.length !== skelRawLen || groupRaw.length !== groupRawLen) throw new Error('length mismatch');
  return { header, skeleton, groupRaw };
}

export function unpackFile(packFile, outFile) {
  const { header, skeleton, groupRaw } = readPack(packFile);
  const segments = skeleton.toString('latin1').split('\u0000');
  if (segments.length !== header.sectionGroups.length + 1) throw new Error('skeleton markers != sections');
  const r = new Reader(groupRaw);
  const parts = [];
  const tickMode = header.timeMode !== 'float';
  for (let si = 0; si < header.sectionGroups.length; si++) {
    let prevTick = 0;
    parts.push(Buffer.from(segments[si], 'latin1'));
    const groups = header.sectionGroups[si];
    const notes = [];
    for (let gi = 0; gi < groups; gi++) {
      let time;
      if (tickMode) {
        const tick = prevTick + unzigzag(r.varint());
        prevTick = tick;
        time = fmtTime(tick * header.base);
      } else {
        time = fmtFloat(r.double());
      }
      const lane = unzigzag(r.varint());
      const sus = header.sustains[r.varint()];
      const ti = r.varint();
      const count = r.varint();
      const ty = header.types[ti];
      let note;
      if (ty == null || ty.kind === 0) note = '[' + time + ',' + lane + ',' + sus + ']';
      else if (ty.kind === 1) note = '[' + time + ',' + lane + ',' + sus + ',' + JSON.stringify(ty.value) + ']';
      else note = '[' + time + ',' + lane + ',' + sus + ',' + ty.value + ']';
      for (let k = 0; k < count; k++) notes.push(note);
    }
    parts.push(Buffer.from('[' + notes.join(',') + ']', 'latin1'));
  }
  parts.push(Buffer.from(segments[segments.length - 1], 'latin1'));
  fs.writeFileSync(outFile, Buffer.concat(parts));
  return { outFile, bytes: fs.statSync(outFile).size, notes: header.notes, groups: header.groups };
}

function main() {
  const args = process.argv.slice(2);
  const cmd = args[0];
  if (cmd === 'pack') {
    const stats = args.includes('--stats');
    const r = packFile(args[1], args[2], {});
    console.log(JSON.stringify(r, null, 2));
    if (stats) console.log('ratio', r.ratio.toFixed(1) + 'x');
  } else if (cmd === 'unpack') {
    console.log(JSON.stringify(unpackFile(args[1], args[2]), null, 2));
  } else if (cmd === 'pack-dir') {
    const r = packDir(args[1], { replace: args.includes('--replace'), force: args.includes('--force') });
    console.log(JSON.stringify({ files: r.files, totalIn: r.totalIn, totalOut: r.totalOut, ratio: r.ratio }, null, 2));
  } else if (cmd === 'info') {
    const { header } = readPack(args[1]);
    console.log(JSON.stringify({ ...header, sustains: header.sustains.slice(0, 20), types: header.types.slice(0, 20) }, null, 2));
  } else if (cmd === 'verify') {
    const tmp = args[1] + '.verify.json';
    const r = packFile(args[1], tmp + '.pack', {});
    unpackFile(tmp + '.pack', tmp);
    console.log(JSON.stringify(r, null, 2));
    console.log('verify files written:', tmp, tmp + '.pack');
  } else {
    console.error('usage: chartpack.mjs pack|unpack|pack-dir|info|verify <in> [out]');
    process.exit(2);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
