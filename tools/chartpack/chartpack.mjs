#!/usr/bin/env node
// chartpack.mjs (v2) — streaming, low-memory chart container for huge Psych Engine charts.
//
// Goals of this rewrite:
//   * never hold a whole chart (or a whole sectionNotes string) in memory;
//   * parse sectionNotes as bytes, directly from a file stream or from a ZIP entry;
//   * collapse long runs of identical notes in O(memcmp) instead of one regex match per note;
//   * write chartpacks in the same SEIUNPK1 v1 format the engine already reads.
//
// Container layout (identical to v1, so no engine rebuild is needed):
//   "SEIUNPK1"
//   u32 headerLen, header JSON
//   u32 skelCompLen, u32 skelRawLen, deflate(skeleton)
//   u32 groupCompLen, u32 groupRawLen, deflate(group stream)
//
// The skeleton is every input byte outside each sectionNotes array, with a NUL byte where
// the array was.  The group stream stores one (time delta, lane, sustain, type, repeat)
// record per distinct note inside a section.
//
// Usage:
//   node chartpack.mjs pack    <chart.json> <chart.chartpack> [--time-mode=auto|tick|float]
//   node chartpack.mjs unpack  <chart.chartpack> <chart.json>
//   node chartpack.mjs info    <chart.chartpack>
//   node chartpack.mjs pack-dir <dir> [--replace] [--force] [--jobs=N]
//   node chartpack.mjs pack-zip <archive.zip> [--out-dir=DIR] [--match=TEXT] [--force] [--jobs=N]
//   node chartpack.mjs verify  <chart.chartpack> <chart.json>
//   node chartpack.mjs verify-zip <chart.chartpack> <archive.zip> <entry-name>
//
// No dependencies beyond Node's fs/zlib/crypto.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { pathToFileURL } from 'node:url';

const MAGIC = Buffer.from('SEIUNPK1', 'ascii');
const VERSION = 1;
const MARKER = Buffer.from('"sectionNotes"', 'ascii');
const MARKER_KEEP = MARKER.length - 1;
const NUL = Buffer.from([0]);

const WS = new Uint8Array(256);
for (const c of [32, 9, 10, 13]) WS[c] = 1;

const TICK_TOLERANCE = 1e-6; // milliseconds
const MAX_REPEAT = 0x7fffffff; // engine decodes repeats into a signed 32-bit Int

// ---------------------------------------------------------------------------
// small helpers

function u32(n) { const b = Buffer.allocUnsafe(4); b.writeUInt32LE(n >>> 0); return b; }

function zigzag(n) { return n >= 0 ? n * 2 : -n * 2 - 1; }
function unzigzag(n) { return (n & 1) ? -(n + 1) / 2 : n / 2; }

function fmtTime(t) {
  // Same textual form the v1 packer used for tick charts: six decimals, trailing zeros
  // trimmed, and a kept ".0" for whole numbers.
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

function mix32(x) {
  x ^= x >>> 16;
  x = Math.imul(x, 0x7feb352d);
  x ^= x >>> 15;
  x = Math.imul(x, 0x846ca68b);
  x ^= x >>> 16;
  return x >>> 0;
}

class TimeGridMismatch extends Error {
  constructor(message) { super(message); this.code = 'TIMEGRID'; }
}

// ---------------------------------------------------------------------------
// growable byte buffer with fast varint/double writers

class ByteWriter {
  constructor(cap = 1024) {
    this.buf = Buffer.allocUnsafe(Math.max(16, cap));
    this.len = 0;
  }
  ensure(n) {
    const need = this.len + n;
    if (need <= this.buf.length) return;
    let cap = this.buf.length * 2;
    while (cap < need) cap *= 2;
    const b = Buffer.allocUnsafe(cap);
    this.buf.copy(b, 0, 0, this.len);
    this.buf = b;
  }
  bytes(src, start = 0, end = src.length) {
    const n = end - start;
    if (n <= 0) return;
    this.ensure(n);
    src.copy(this.buf, this.len, start, end);
    this.len += n;
  }
  u8(v) { this.ensure(1); this.buf[this.len++] = v & 0xff; }
  varint(v) {
    this.ensure(10);
    v = Math.floor(v);
    while (v >= 0x80) {
      this.buf[this.len++] = (v & 0x7f) | 0x80;
      v = Math.floor(v / 128);
    }
    this.buf[this.len++] = v;
  }
  f64(v) {
    this.ensure(8);
    this.buf.writeDoubleLE(v, this.len);
    this.len += 8;
  }
  view() { return this.buf.subarray(0, this.len); }
}

// ---------------------------------------------------------------------------
// open-addressing group table (one instance = one section)

class GroupTable {
  constructor() {
    this.floatMode = false;
    this.cap = 256;
    this.mask = this.cap - 1;
    this.slots = new Int32Array(this.cap).fill(-1);
    this.size = 0;
    this.tick = new Int32Array(this.cap);
    this.time = new Float64Array(this.cap);
    this.lane = new Int32Array(this.cap);
    this.si = new Int32Array(this.cap);
    this.ti = new Int32Array(this.cap);
    this.count = new Float64Array(this.cap);
    this.lastIndex = -1;
    this._f64 = new Float64Array(1);
    this._u32 = new Uint32Array(this._f64.buffer);
  }

  reset() {
    this.cap = 256;
    this.mask = this.cap - 1;
    this.slots = new Int32Array(this.cap).fill(-1);
    this.size = 0;
    this.tick = new Int32Array(this.cap);
    this.time = new Float64Array(this.cap);
    this.lane = new Int32Array(this.cap);
    this.si = new Int32Array(this.cap);
    this.ti = new Int32Array(this.cap);
    this.count = new Float64Array(this.cap);
    this.lastIndex = -1;
  }

  _hash(tick, time, lane, si, ti) {
    let h;
    if (this.floatMode) {
      this._f64[0] = time;
      h = this._u32[0] ^ Math.imul(this._u32[1], 0x9e3779b1);
    } else {
      h = Math.imul(tick, 0x9e3779b1);
    }
    h ^= Math.imul(lane, 0x85ebca6b);
    h ^= Math.imul(si, 0xc2b2ae35);
    h ^= Math.imul(ti, 0x27d4eb2f);
    return mix32(h);
  }

  _grow() {
    const oldCap = this.cap;
    this.cap = oldCap * 2;
    this.mask = this.cap - 1;
    const nt = new Int32Array(this.cap);
    const ntime = new Float64Array(this.cap);
    const nl = new Int32Array(this.cap);
    const ns = new Int32Array(this.cap);
    const nty = new Int32Array(this.cap);
    const nc = new Float64Array(this.cap);
    nt.set(this.tick); ntime.set(this.time); nl.set(this.lane); ns.set(this.si); nty.set(this.ti); nc.set(this.count);
    this.tick = nt; this.time = ntime; this.lane = nl; this.si = ns; this.ti = nty; this.count = nc;
    this.slots = new Int32Array(this.cap).fill(-1);
    for (let i = 0; i < this.size; i++) {
      let idx = this._hash(nt[i], ntime[i], nl[i], ns[i], nty[i]) & this.mask;
      while (this.slots[idx] !== -1) idx = (idx + 1) & this.mask;
      this.slots[idx] = i;
    }
  }

  /** Returns the entry index; this.lastIndex is always set. */
  add(tick, time, lane, si, ti) {
    const n = this.size;
    if (n > 0) {
      const j = n - 1; // groups are appended, so this is the most recently created group
      if (this.tick[j] === tick && this.lane[j] === lane && this.si[j] === si && this.ti[j] === ti
          && (!this.floatMode || this.time[j] === time)) {
        this.count[j]++;
        this.lastIndex = j;
        return j;
      }
    }
    if ((n + 1) * 10 >= this.cap * 7) this._grow();
    let idx = this._hash(tick, time, lane, si, ti) & this.mask;
    for (;;) {
      const e = this.slots[idx];
      if (e === -1) break;
      if (this.tick[e] === tick && this.lane[e] === lane && this.si[e] === si && this.ti[e] === ti
          && (!this.floatMode || this.time[e] === time)) {
        this.count[e]++;
        this.lastIndex = e;
        return e;
      }
      idx = (idx + 1) & this.mask;
    }
    const e = this.size++;
    this.tick[e] = tick;
    this.time[e] = time;
    this.lane[e] = lane;
    this.si[e] = si;
    this.ti[e] = ti;
    this.count[e] = 1;
    this.slots[idx] = e;
    this.lastIndex = e;
    return e;
  }

  bump(n) {
    if (this.lastIndex >= 0) this.count[this.lastIndex] += n;
  }
}

// ---------------------------------------------------------------------------
// streaming chart scanner: consumes arbitrary chunks, produces skeleton + group stream

class ChartScanner {
  constructor(opts = {}) {
    this.opts = opts;
    this.timeModeOpt = opts.timeMode || 'auto';
    this.collect = !!opts.collect; // verification mode: build Maps instead of bytes
    this.collected = [];

    this.state = 'out'; // out | in
    this.pendingSep = false;
    this.needMore = false;
    this.buf = null;
    this.leftover = Buffer.alloc(0);
    this.bytesRead = 0;

    this.skel = new ByteWriter(4096);
    this.md5 = crypto.createHash('md5');
    this.groupRaw = new ByteWriter(1 << 20);
    this.sections = [];
    this.sustains = [''];
    this.susMap = new Map([['', 0]]);
    this.types = [{ kind: 0 }];
    this.typeMap = new Map([['0:', 0]]);

    this.noteCount = 0;
    this.groupCount = 0;
    this.sectionCount = 0;
    this.mode = 'unknown'; // tick | float
    this.bpm = null;
    this.base = null;
    this.headParsed = false;

    this.table = new GroupTable();
    this.orderSorted = true;
    this.hasLastNew = false;
    this.lastNew = { tick: 0, time: 0, lane: 0, si: 0, ti: 0 };

    this.t0 = Date.now();
  }

  push(chunk) {
    this.bytesRead += chunk.length;
    const buf = this.leftover.length ? Buffer.concat([this.leftover, chunk]) : chunk;
    this.buf = buf;
    this._run();
    if (this.pos < buf.length) this.leftover = Buffer.from(buf.subarray(this.pos));
    else this.leftover = Buffer.alloc(0);
    this.buf = null;
  }

  _run() {
    const buf = this.buf;
    const len = buf.length;
    let pos = 0;
    for (;;) {
      this.needMore = false;
      if (this.state === 'out') {
        pos = this._scanOut(buf, pos, len);
      } else {
        pos = this._scanArray(buf, pos, len);
      }
      this.pos = pos;
      if (this.needMore) return;
      if (pos >= len) { this.needMore = true; return; }
    }
  }

  _skel(buf, start, end) {
    if (end <= start) return;
    const s = buf.subarray(start, end);
    this.skel.bytes(s);
    this.md5.update(s);
  }

  _skelByte(v) {
    this.skel.u8(v);
    this.md5.update(NUL);
  }

  _scanOut(buf, pos, len) {
    for (;;) {
      if (pos >= len) { this.needMore = true; return pos; }
      const idx = buf.indexOf(MARKER, pos);
      if (idx < 0) {
        const keep = Math.min(MARKER_KEEP, len - pos);
        this._skel(buf, pos, len - keep);
        this.needMore = true;
        return len - keep;
      }
      let q = idx + MARKER.length;
      const limit = Math.min(len, q + 4096);
      while (q < limit && (WS[buf[q]] || buf[q] === 58)) q++;
      if (q >= len) {
        // Wait for more bytes to see whether this is a real key.
        this._skel(buf, pos, idx);
        this.needMore = true;
        return idx;
      }
      if (buf[q] !== 91) {
        // A string that merely contains "sectionNotes"; keep it as skeleton.
        this._skel(buf, pos, idx + MARKER.length);
        pos = idx + MARKER.length;
        continue;
      }
      // bytes before '[' (key, colon, whitespace), then NUL placeholder
      this._skel(buf, pos, q);
      this._skelByte(0);
      this._beginSection();
      return q + 1;
    }
  }

  _beginSection() {
    if (!this.headParsed) this._parseHead();
    if (this.mode === 'unknown') {
      if (this.base != null && this.timeModeOpt !== 'float') this.mode = 'tick';
      else this.mode = 'float';
    }
    if (this.mode === 'tick' && this.base == null) throw new TimeGridMismatch('tick mode without bpm');
    this.table.floatMode = (this.mode === 'float');
    this.table.reset();
    this.orderSorted = true;
    this.hasLastNew = false;
    this.pendingSep = false;
    this.state = 'in';
  }

  _parseHead() {
    this.headParsed = true;
    const n = Math.min(this.skel.len, 65536);
    const txt = this.skel.buf.toString('latin1', 0, n);
    const m = /"bpm"\s*:\s*("?)(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\1/.exec(txt);
    if (m) {
      const bpm = Number(m[2]);
      if (Number.isFinite(bpm) && bpm > 0) {
        this.bpm = bpm;
        this.base = 60000 / bpm / 3072;
      }
    }
    if (this.timeModeOpt === 'tick' && this.base == null) {
      throw new TimeGridMismatch('chart has no usable bpm for tick time mode');
    }
  }

  _scanArray(buf, pos, len) {
    for (;;) {
      while (pos < len && WS[buf[pos]]) pos++;
      if (pos >= len) { this.needMore = true; return pos; }
      if (this.pendingSep) {
        const c = buf[pos];
        if (c === 44) { pos++; this.pendingSep = false; continue; }
        if (c === 93) { this._endSection(); return pos + 1; }
        throw new Error('bad array separator at byte ' + pos);
      }
      if (buf[pos] === 93) { this._endSection(); return pos + 1; }
      if (buf[pos] !== 91) throw new Error('expected note array at byte ' + pos);

      const noteStart = pos;
      pos = this._parseNote(buf, pos, len);
      if (pos < 0) { this.needMore = true; return noteStart; }
      // The note was added by _parseNote.
      if (buf[pos] === 44 && pos + 1 < len && buf[pos + 1] === 91) {
        const stride = (pos - noteStart) + 1;
        const units = this._countRun(buf, noteStart, stride, len);
        if (units > 1) {
          const extra = units - 1;
          this.table.bump(extra);
          this.noteCount += extra;
          pos = noteStart + units * stride;
          continue;
        }
      }
      // consume separator
      while (pos < len && WS[buf[pos]]) pos++;
      if (pos >= len) { this.pendingSep = true; this.needMore = true; return pos; }
      const c = buf[pos];
      if (c === 44) { pos++; continue; }
      if (c === 93) { this._endSection(); return pos + 1; }
      throw new Error('expected , or ] after note at byte ' + pos);
    }
  }

  _countRun(buf, s, stride, len) {
    let units = 1;
    for (;;) {
      const span = units * stride;
      if (s + span * 2 > len) break;
      if (buf.compare(buf, s, s + span, s + span, s + span * 2) !== 0) break;
      units *= 2;
    }
    let step = units;
    while (step >= 1) {
      const span = step * stride;
      const b = s + units * stride;
      if (b + span <= len && buf.compare(buf, s, s + span, b, b + span) === 0) units += step;
      step >>= 1;
    }
    return units;
  }

  _getSus(raw) {
    let si = this.susMap.get(raw);
    if (si === undefined) {
      si = this.sustains.length;
      this.sustains.push(raw);
      this.susMap.set(raw, si);
    }
    return si;
  }

  _getType(kind, value) {
    const key = kind + ':' + String(value);
    let ti = this.typeMap.get(key);
    if (ti === undefined) {
      ti = this.types.length;
      this.types.push({ kind, value });
      this.typeMap.set(key, ti);
    }
    return ti;
  }

  _parseNote(buf, start, len) {
    let p = start + 1;
    while (p < len && WS[buf[p]]) p++;
    if (p >= len) return -1;

    const t0 = p;
    p = numEnd(buf, p, len);
    if (p < 0) return -1;
    const time = Number(buf.toString('latin1', t0, p));
    if (!Number.isFinite(time)) throw new Error('bad time at byte ' + t0);

    while (p < len && WS[buf[p]]) p++;
    if (p >= len) return -1;
    if (buf[p] !== 44) throw new Error('expected , after time at byte ' + p);
    p++;
    while (p < len && WS[buf[p]]) p++;
    if (p >= len) return -1;

    const l0 = p;
    p = numEnd(buf, p, len);
    if (p < 0) return -1;
    const lane = Number(buf.toString('latin1', l0, p));
    if (!Number.isInteger(lane)) throw new Error('non-integer lane at byte ' + l0);

    while (p < len && WS[buf[p]]) p++;
    if (p >= len) return -1;
    if (buf[p] !== 44) throw new Error('expected , after lane at byte ' + p);
    p++;
    while (p < len && WS[buf[p]]) p++;
    if (p >= len) return -1;

    const s0 = p;
    p = numEnd(buf, p, len);
    if (p < 0) return -1;
    const sus = buf.toString('latin1', s0, p);
    const si = this._getSus(sus);

    let ti = 0;
    while (p < len && WS[buf[p]]) p++;
    if (p >= len) return -1;
    if (buf[p] === 44) {
      p++;
      while (p < len && WS[buf[p]]) p++;
      if (p >= len) return -1;
      if (buf[p] === 34) {
        const q0 = p;
        let q = p + 1, esc = false;
        while (q < len) {
          const c = buf[q];
          if (esc) { esc = false; q++; }
          else if (c === 92) { esc = true; q++; }
          else if (c === 34) { q++; break; }
          else q++;
        }
        if (q >= len) return -1;
        const raw = buf.toString('latin1', q0, q);
        const val = JSON.parse(raw);
        ti = this._getType(1, val);
        p = q;
      } else if (buf[p] === 110 && p + 4 <= len && buf.toString('latin1', p, p + 4) === 'null') {
        p += 4;
      } else {
        const v0 = p;
        p = numEnd(buf, p, len);
        if (p < 0) return -1;
        const val = Number(buf.toString('latin1', v0, p));
        ti = this._getType(2, val);
      }
      while (p < len && WS[buf[p]]) p++;
      if (p >= len) return -1;
    }
    if (buf[p] !== 93) throw new Error('unsupported note shape at byte ' + p);

    const end = p + 1;
    this._addNote(time, lane, si, ti, start, end);
    return end;
  }

  _addNote(time, lane, si, ti, start, end) {
    let tick = 0;
    if (this.mode === 'tick') {
      tick = Math.round(time / this.base);
      const recon = tick * this.base;
      if (!Number.isSafeInteger(tick) || Math.abs(recon - time) > TICK_TOLERANCE
          || tick < -2147483648 || tick > 2147483647) {
        throw new TimeGridMismatch('time ' + time + ' is not on the bpm tick grid (tick ' + tick + ', err ' + (recon - time) + ')');
      }
    }
    const before = this.table.size;
    this.table.add(tick, this.mode === 'tick' ? 0 : time, lane, si, ti);
    const isNew = this.table.size !== before;
    if (isNew) {
      if (this.hasLastNew) {
        let cmp;
        if (this.mode === 'tick') {
          cmp = tick - this.lastNew.tick;
          if (cmp === 0) cmp = lane - this.lastNew.lane;
          if (cmp === 0) cmp = si - this.lastNew.si;
          if (cmp === 0) cmp = ti - this.lastNew.ti;
        } else {
          cmp = time - this.lastNew.time;
          if (cmp === 0) cmp = lane - this.lastNew.lane;
          if (cmp === 0) cmp = si - this.lastNew.si;
          if (cmp === 0) cmp = ti - this.lastNew.ti;
        }
        if (cmp < 0) this.orderSorted = false;
      }
      this.hasLastNew = true;
      this.lastNew.tick = tick;
      this.lastNew.time = this.mode === 'tick' ? 0 : time;
      this.lastNew.lane = lane;
      this.lastNew.si = si;
      this.lastNew.ti = ti;
    }
    this.noteCount++;
  }

  _typeKey(ti) {
    const ty = this.types[ti];
    if (ty == null || ty.kind === 0) return '0:';
    if (ty.kind === 1) return '1:' + JSON.stringify(ty.value);
    return '2:' + String(ty.value);
  }

  _endSection() {
    this._encodeSection();
    this.sectionCount++;
    this.state = 'out';
    this.pendingSep = false;
  }

  _encodeSection() {
    const t = this.table;
    const n = t.size;
    if (this.collect) {
      const m = new Map();
      for (let i = 0; i < n; i++) {
        const time = this.mode === 'tick' ? t.tick[i] * this.base : t.time[i];
        const key = Math.round(time * 100) + '\u0001' + t.lane[i] + '\u0001'
          + this.sustains[t.si[i]] + '\u0001' + this._typeKey(t.ti[i]);
        m.set(key, (m.get(key) || 0) + t.count[i]);
      }
      this.collected.push(m);
      this.sections.push(n);
      this.groupCount += n;
      return;
    }

    let order = null;
    if (!this.orderSorted && n > 1) {
      order = new Uint32Array(n);
      for (let i = 0; i < n; i++) order[i] = i;
      if (this.mode === 'tick') {
        order.sort((a, b) => (t.tick[a] - t.tick[b]) || (t.lane[a] - t.lane[b])
          || (t.si[a] - t.si[b]) || (t.ti[a] - t.ti[b]));
      } else {
        order.sort((a, b) => (t.time[a] - t.time[b]) || (t.lane[a] - t.lane[b])
          || (t.si[a] - t.si[b]) || (t.ti[a] - t.ti[b]));
      }
    }

    const w = this.groupRaw;
    let prevTick = 0;
    for (let k = 0; k < n; k++) {
      const i = order ? order[k] : k;
      let count = t.count[i];
      // Extremely defensive: a single record must fit the engine's signed-32 varint.
      while (count > MAX_REPEAT) {
        if (this.mode === 'tick') {
          const d0 = t.tick[i] - prevTick;
          w.varint(zigzag(d0));
          prevTick = t.tick[i];
        } else {
          w.f64(t.time[i]);
        }
        w.varint(zigzag(t.lane[i]));
        w.varint(t.si[i]);
        w.varint(t.ti[i]);
        w.varint(MAX_REPEAT);
        count -= MAX_REPEAT;
        this.groupCount++;
      }
      if (this.mode === 'tick') {
        const d = t.tick[i] - prevTick;
        w.varint(zigzag(d));
        prevTick = t.tick[i];
      } else {
        w.f64(t.time[i]);
      }
      w.varint(zigzag(t.lane[i]));
      w.varint(t.si[i]);
      w.varint(t.ti[i]);
      w.varint(count);
      this.groupCount++;
    }
    this.sections.push(n);
  }

  finish() {
    if (this.state !== 'out') throw new Error('unterminated sectionNotes array');
    if (this.leftover.length) {
      // No more input can arrive, so a partial marker at EOF is ordinary skeleton text.
      this._skel(this.leftover, 0, this.leftover.length);
      this.leftover = Buffer.alloc(0);
    }
    this.skelRaw = this.skel.view();
    this.skelLen = this.skel.len;
    this.skelCrc = this.md5.digest('hex');
    this.groupRawView = this.groupRaw.view();
    this.ms = Date.now() - this.t0;
    return this;
  }
}

function numEnd(b, p, len) {
  let q = p;
  if (q < len && b[q] === 45) q++;
  let digits = 0;
  while (q < len) {
    const c = b[q];
    if (c < 48 || c > 57) break;
    q++; digits++;
  }
  if (q < len && b[q] === 46) {
    q++;
    while (q < len) {
      const c = b[q];
      if (c < 48 || c > 57) break;
      q++; digits++;
    }
  }
  if (digits === 0) return -1;
  if (q < len && (b[q] === 101 || b[q] === 69)) {
    q++;
    if (q < len && (b[q] === 43 || b[q] === 45)) q++;
    let ed = 0;
    while (q < len) {
      const c = b[q];
      if (c < 48 || c > 57) break;
      q++; ed++;
    }
    if (ed === 0) return -1;
  }
  // A number that reaches the chunk end may continue in the next chunk.
  if (q >= len) return -1;
  return q;
}

// ---------------------------------------------------------------------------
// pack / unpack

export async function packFromSource(makeStream, outFile, opts = {}) {
  const attempts = (opts.timeMode && opts.timeMode !== 'auto') ? 1 : 2;
  let lastErr = null;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const timeMode = attempt === 0 ? (opts.timeMode || 'auto') : 'float';
    const scan = new ChartScanner({ ...opts, timeMode });
    const t0 = Date.now();
    try {
      const stream = await makeStream();
      for await (const chunk of stream) scan.push(chunk);
      scan.finish();
      if (opts.size != null && scan.bytesRead !== opts.size) {
        throw new Error('input size changed or stream truncated: got ' + scan.bytesRead + ', expected ' + opts.size);
      }
    } catch (e) {
      if (e && e.code === 'TIMEGRID' && attempt + 1 < attempts) {
        lastErr = e;
        continue;
      }
      throw e;
    }

    const tComp = Date.now();
    const skelRaw = scan.skelRaw;
    const groupRaw = scan.groupRawView;
    const skelComp = zlib.deflateSync(skelRaw, { level: 9 });
    const groupComp = zlib.deflateSync(groupRaw, { level: 9 });
    const header = {
      v: VERSION,
      bpm: scan.bpm,
      base: scan.base,
      timeMode: scan.mode,
      sustains: scan.sustains,
      types: scan.types,
      sectionGroups: scan.sections,
      notes: scan.noteCount,
      groups: scan.groupCount,
      skelLen: skelRaw.length,
      skelCrc: scan.skelCrc,
    };
    const headerBytes = Buffer.from(JSON.stringify(header), 'utf8');
    const w = new ByteWriter(headerBytes.length + skelComp.length + groupComp.length + 64);
    w.bytes(MAGIC);
    w.bytes(u32(headerBytes.length));
    w.bytes(headerBytes);
    w.bytes(u32(skelComp.length)); w.bytes(u32(skelRaw.length)); w.bytes(skelComp);
    w.bytes(u32(groupComp.length)); w.bytes(u32(groupRaw.length)); w.bytes(groupComp);
    const out = w.view();
    const tmp = outFile + '.tmp-' + process.pid + '-' + Date.now();
    fs.writeFileSync(tmp, out);
    fs.renameSync(tmp, outFile);

    const totalMs = Date.now() - t0;
    const jsonBytes = opts.size != null ? opts.size : scan.bytesRead;
    return {
      file: opts.source || null,
      outFile,
      outBytes: out.length,
      jsonBytes,
      skeletonRaw: skelRaw.length,
      skeletonComp: skelComp.length,
      groupRaw: groupRaw.length,
      groupComp: groupComp.length,
      notes: scan.noteCount,
      groups: scan.groupCount,
      sections: scan.sectionCount,
      timeMode: scan.mode,
      bpm: scan.bpm,
      ratio: out.length > 0 ? jsonBytes / out.length : 0,
      ms: scan.ms,
      totalMs,
      compMs: Date.now() - tComp,
      mbps: scan.bytesRead / 1048576 / (scan.ms / 1000),
      notesPerSec: scan.noteCount / (scan.ms / 1000),
      attempts: attempt + 1,
      retryReason: lastErr ? lastErr.message : undefined,
    };
  }
  throw lastErr || new Error('pack failed');
}

export async function packFile(file, outFile, opts = {}) {
  const st = fs.statSync(file);
  return packFromSource(
    () => fs.createReadStream(file, { highWaterMark: opts.chunk || (8 << 20) }),
    outFile,
    { ...opts, source: file, size: st.size }
  );
}

class Reader {
  constructor(buf) { this.b = buf; this.p = 0; }
  u32() { const v = this.b.readUInt32LE(this.p); this.p += 4; return v; }
  varint() {
    let n = 0, mul = 1, c;
    do {
      c = this.b[this.p++];
      n += (c & 0x7f) * mul;
      mul *= 128;
    } while (c & 0x80);
    return n;
  }
  double() { const v = this.b.readDoubleLE(this.p); this.p += 8; return v; }
  bytes(n) { const v = this.b.subarray(this.p, this.p + n); this.p += n; return v; }
}

export function readHeader(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.allocUnsafe(12);
    if (fs.readSync(fd, head, 0, 12, 0) !== 12) throw new Error('short pack header');
    if (!head.subarray(0, 8).equals(MAGIC)) throw new Error('not a chartpack');
    const hlen = head.readUInt32LE(8);
    const hb = Buffer.allocUnsafe(hlen);
    let off = 0;
    while (off < hlen) {
      const n = fs.readSync(fd, hb, off, hlen - off, 12 + off);
      if (!n) throw new Error('short header');
      off += n;
    }
    const stat = fs.fstatSync(fd);
    return { header: JSON.parse(hb.toString('utf8')), size: stat.size };
  } finally {
    fs.closeSync(fd);
  }
}

export function readPack(file) {
  const b = fs.readFileSync(file);
  if (!b.subarray(0, 8).equals(MAGIC)) throw new Error('not a chartpack');
  const r = new Reader(b);
  r.p = 8;
  const hlen = r.u32();
  const header = JSON.parse(r.bytes(hlen).toString('utf8'));
  const skelCLen = r.u32(); const skelRawLen = r.u32();
  const skelComp = r.bytes(skelCLen);
  const groupCLen = r.u32(); const groupRawLen = r.u32();
  const groupComp = r.bytes(groupCLen);
  const skeleton = zlib.inflateSync(skelComp);
  const groupRaw = zlib.inflateSync(groupComp);
  if (skeleton.length !== skelRawLen) throw new Error('skeleton length mismatch');
  if (groupRaw.length !== groupRawLen) throw new Error('group length mismatch');
  return { header, skeleton, groupRaw, packBytes: b.length };
}

class FileBufWriter {
  constructor(fd, cap = 8 << 20) {
    this.fd = fd;
    this.buf = Buffer.allocUnsafe(cap);
    this.len = 0;
  }
  _flush() {
    if (this.len === 0) return;
    let off = 0;
    while (off < this.len) {
      const n = fs.writeSync(this.fd, this.buf, off, this.len - off);
      if (n <= 0) throw new Error('short write');
      off += n;
    }
    this.len = 0;
  }
  u8(v) { if (this.len + 1 > this.buf.length) this._flush(); this.buf[this.len++] = v; }
  bytes(src) {
    if (src.length > this.buf.length) {
      this._flush();
      let off = 0;
      while (off < src.length) {
        const n = fs.writeSync(this.fd, src, off, src.length - off);
        if (n <= 0) throw new Error('short write');
        off += n;
      }
      return;
    }
    if (this.len + src.length > this.buf.length) this._flush();
    src.copy(this.buf, this.len);
    this.len += src.length;
  }
  str(s) { this.bytes(Buffer.from(s, 'latin1')); }
  repeat(unit, times) {
    if (times <= 0) return;
    const unitLen = unit.length;
    if (unitLen === 0) return;
    const maxRep = Math.max(1, Math.floor((1 << 20) / unitLen));
    while (times > 0) {
      const k = Math.min(times, maxRep);
      if (k === 1) this.bytes(unit);
      else {
        const block = Buffer.allocUnsafe(k * unitLen);
        let o = 0;
        for (let i = 0; i < k; i++) { unit.copy(block, o); o += unitLen; }
        this.bytes(block);
      }
      times -= k;
    }
  }
  close() { this._flush(); }
}

export function decodePackGroups(pack) {
  const { header, skeleton, groupRaw } = pack;
  const segments = skeleton.toString('latin1').split('\u0000');
  if (segments.length !== header.sectionGroups.length + 1) throw new Error('skeleton markers != sections');
  const r = new Reader(groupRaw);
  const tickMode = header.timeMode !== 'float';
  const sections = [];
  let total = 0;
  for (let si = 0; si < header.sectionGroups.length; si++) {
    const n = header.sectionGroups[si];
    const list = [];
    let prevTick = 0;
    for (let gi = 0; gi < n; gi++) {
      let time;
      if (tickMode) {
        const tick = prevTick + unzigzag(r.varint());
        prevTick = tick;
        time = tick * header.base;
      } else {
        time = r.double();
      }
      const lane = unzigzag(r.varint());
      const sus = header.sustains[r.varint()];
      const ti = r.varint();
      const count = r.varint();
      list.push({ time, lane, sus, ti, count });
      total += count;
    }
    sections.push(list);
  }
  if (r.p !== groupRaw.length) throw new Error('group stream has trailing bytes');
  return { sections, segments, total, tickMode };
}

export function unpackFile(packFile, outFile) {
  const pack = readPack(packFile);
  const { header, skeleton, groupRaw } = pack;
  const segments = skeleton.toString('latin1').split('\u0000');
  if (segments.length !== header.sectionGroups.length + 1) throw new Error('skeleton markers != sections');
  const r = new Reader(groupRaw);
  const tickMode = header.timeMode !== 'float';
  const tmp = outFile + '.tmp-' + process.pid + '-' + Date.now();
  const fd = fs.openSync(tmp, 'w');
  const w = new FileBufWriter(fd);
  try {
    for (let si = 0; si < header.sectionGroups.length; si++) {
      w.str(segments[si]);
      w.u8(91); // [
      const n = header.sectionGroups[si];
      let prevTick = 0;
      let first = true;
      for (let gi = 0; gi < n; gi++) {
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
        const noteBuf = Buffer.from(note, 'latin1');
        if (first) {
          w.bytes(noteBuf);
          const commaNote = Buffer.concat([Buffer.from([44]), noteBuf]);
          if (count > 1) w.repeat(commaNote, count - 1);
          first = false;
        } else {
          w.repeat(Buffer.concat([Buffer.from([44]), noteBuf]), count);
        }
      }
      w.u8(93); // ]
    }
    w.str(segments[segments.length - 1]);
    w.close();
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, outFile);
  return { outFile, bytes: fs.statSync(outFile).size, notes: header.notes, groups: header.groups };
}

// ---------------------------------------------------------------------------
// ZIP reading (stored + deflate, ZIP64 central directory)

function readAt(fd, pos, len) {
  const b = Buffer.allocUnsafe(len);
  let off = 0;
  while (off < len) {
    const n = fs.readSync(fd, b, off, len - off, pos + off);
    if (!n) throw new Error('unexpected EOF at ' + (pos + off));
    off += n;
  }
  return b;
}

function findEocd(b) {
  for (let i = b.length - 22; i >= 0; i--) {
    if (b.readUInt32LE(i) === 0x06054b50) return i;
  }
  return -1;
}

export function readZipDirectory(zipPath) {
  const fd = fs.openSync(zipPath, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const tailLen = Math.min(size, 22 + 65535);
    const tail = readAt(fd, size - tailLen, tailLen);
    const eocd = findEocd(tail);
    if (eocd < 0) throw new Error('not a zip (no EOCD): ' + zipPath);
    let count = tail.readUInt16LE(eocd + 10);
    let cdSize = tail.readUInt32LE(eocd + 12);
    let cdOff = tail.readUInt32LE(eocd + 16);
    if (count === 0xffff || cdSize === 0xffffffff || cdOff === 0xffffffff) {
      const loc = (size - tailLen) + eocd - 20;
      if (loc < 0) throw new Error('bad zip64 locator');
      const locBuf = readAt(fd, loc, 20);
      if (locBuf.readUInt32LE(0) !== 0x07064b50) throw new Error('bad zip64 locator signature');
      const z64Off = Number(locBuf.readBigUInt64LE(8));
      const z64 = readAt(fd, z64Off, 56);
      if (z64.readUInt32LE(0) !== 0x06064b50) throw new Error('bad zip64 EOCD');
      count = Number(z64.readBigUInt64LE(32));
      cdSize = Number(z64.readBigUInt64LE(40));
      cdOff = Number(z64.readBigUInt64LE(48));
    }
    const cd = readAt(fd, cdOff, cdSize);
    const entries = [];
    let p = 0;
    for (let i = 0; i < count; i++) {
      if (cd.readUInt32LE(p) !== 0x02014b50) throw new Error('bad central directory entry at ' + p);
      const flags = cd.readUInt16LE(p + 8);
      const method = cd.readUInt16LE(p + 10);
      const crc = cd.readUInt32LE(p + 16);
      let csize = cd.readUInt32LE(p + 20);
      let usize = cd.readUInt32LE(p + 24);
      const fnLen = cd.readUInt16LE(p + 28);
      const extraLen = cd.readUInt16LE(p + 30);
      const commentLen = cd.readUInt16LE(p + 32);
      let localOff = cd.readUInt32LE(p + 42);
      const nameBuf = cd.subarray(p + 46, p + 46 + fnLen);
      const name = nameBuf.toString((flags & 0x800) ? 'utf8' : 'latin1');
      const extra = cd.subarray(p + 46 + fnLen, p + 46 + fnLen + extraLen);
      const needU = usize === 0xffffffff, needC = csize === 0xffffffff, needO = localOff === 0xffffffff;
      if (needU || needC || needO) {
        let ep = 0;
        while (ep + 4 <= extra.length) {
          const id = extra.readUInt16LE(ep);
          const sz = extra.readUInt16LE(ep + 2);
          const data = extra.subarray(ep + 4, ep + 4 + sz);
          if (id === 0x0001) {
            let q = 0;
            if (needU) { usize = Number(data.readBigUInt64LE(q)); q += 8; }
            if (needC) { csize = Number(data.readBigUInt64LE(q)); q += 8; }
            if (needO) { localOff = Number(data.readBigUInt64LE(q)); q += 8; }
            break;
          }
          ep += 4 + sz;
        }
      }
      entries.push({ name, flags, method, crc, csize, usize, localOff });
      p += 46 + fnLen + extraLen + commentLen;
    }
    // Resolve data offsets from local headers.
    for (const e of entries) {
      if (e.name.endsWith('/')) { e.dataStart = -1; continue; }
      const lh = readAt(fd, e.localOff, 30);
      if (lh.readUInt32LE(0) !== 0x04034b50) throw new Error('bad local header for ' + e.name);
      const fnLen = lh.readUInt16LE(26);
      const extraLen = lh.readUInt16LE(28);
      e.dataStart = e.localOff + 30 + fnLen + extraLen;
      if (e.flags & 1) throw new Error('encrypted zip entry not supported: ' + e.name);
      if (e.method !== 0 && e.method !== 8) throw new Error('unsupported zip method ' + e.method + ' for ' + e.name);
    }
    return { zipPath, entries, size };
  } finally {
    fs.closeSync(fd);
  }
}

export async function packZipEntry(zipPath, entry, outFile, opts = {}) {
  const { Readable } = await import('node:stream');
  const makeStream = () => {
    if (entry.csize === 0) return Readable.from([]);
    const rs = fs.createReadStream(zipPath, {
      start: entry.dataStart,
      end: entry.dataStart + entry.csize - 1,
      highWaterMark: opts.readChunk || (4 << 20),
    });
    if (entry.method === 0) return rs;
    const inf = zlib.createInflateRaw({ chunkSize: opts.inflateChunk || (4 << 20) });
    rs.on('error', (e) => inf.destroy(e));
    rs.pipe(inf);
    return inf;
  };
  return packFromSource(makeStream, outFile, { ...opts, source: zipPath + '!' + entry.name, size: entry.usize });
}

// ---------------------------------------------------------------------------
// verification

function typeKeyOf(ty) {
  if (ty == null || ty.kind === 0) return '0:';
  if (ty.kind === 1) return '1:' + JSON.stringify(ty.value);
  return '2:' + String(ty.value);
}

export function collectPack(packFile) {
  const pack = readPack(packFile);
  const { header, skeleton, groupRaw } = pack;
  const segments = skeleton.toString('latin1').split('\u0000');
  if (segments.length !== header.sectionGroups.length + 1) throw new Error('skeleton markers != sections');
  const r = new Reader(groupRaw);
  const tickMode = header.timeMode !== 'float';
  const sections = [];
  let total = 0;
  for (let si = 0; si < header.sectionGroups.length; si++) {
    const n = header.sectionGroups[si];
    const m = new Map();
    let prevTick = 0;
    for (let gi = 0; gi < n; gi++) {
      let time;
      if (tickMode) {
        const tick = prevTick + unzigzag(r.varint());
        prevTick = tick;
        time = tick * header.base;
      } else {
        time = r.double();
      }
      const lane = unzigzag(r.varint());
      const sus = header.sustains[r.varint()];
      const ti = r.varint();
      const count = r.varint();
      const key = Math.round(time * 100) + '\u0001' + lane + '\u0001' + sus + '\u0001' + typeKeyOf(header.types[ti]);
      m.set(key, (m.get(key) || 0) + count);
      total += count;
    }
    sections.push(m);
  }
  if (r.p !== groupRaw.length) throw new Error('group stream has trailing bytes');
  return {
    header,
    skeletonMd5: crypto.createHash('md5').update(skeleton).digest('hex'),
    skeletonLen: skeleton.length,
    sections,
    notes: total,
  };
}

export async function collectSource(makeStream, opts = {}) {
  const forced = opts.timeMode && opts.timeMode !== 'auto';
  const attempts = forced ? 1 : 2;
  let lastErr = null;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const timeMode = attempt === 0 ? (opts.timeMode || 'auto') : 'float';
    const scan = new ChartScanner({ ...opts, collect: true, timeMode });
    try {
      const stream = await makeStream();
      for await (const chunk of stream) scan.push(chunk);
      scan.finish();
      return {
        skeletonMd5: scan.skelCrc,
        skeletonLen: scan.skelLen,
        sections: scan.collected,
        notes: scan.noteCount,
        groups: scan.groupCount,
        timeMode: scan.mode,
        bpm: scan.bpm,
      };
    } catch (e) {
      if (e && e.code === 'TIMEGRID' && attempt + 1 < attempts) { lastErr = e; continue; }
      throw e;
    }
  }
  throw lastErr || new Error('source scan failed');
}

export async function verifyPack(packFile, makeStream, opts = {}) {
  const pack = collectPack(packFile);
  // Scan the source with the *pack's* time mode.  A float pack stores the exact doubles from
  // the original scan; re-deriving them from ticks here would shift the 0.01 ms comparison
  // buckets by up to 1e-4 ms and produce false mismatches.
  const src = await collectSource(makeStream, {
    ...opts,
    timeMode: pack.header.timeMode === 'float' ? 'float' : 'tick',
  });
  const problems = [];
  if (pack.skeletonMd5 !== src.skeletonMd5) problems.push('skeleton md5 differs');
  if (pack.skeletonLen !== src.skeletonLen) problems.push('skeleton length differs');
  if (pack.sections.length !== src.sections.length) problems.push('section count differs');
  if (pack.notes !== src.notes) problems.push('note count differs: pack=' + pack.notes + ' source=' + src.notes);
  const n = Math.min(pack.sections.length, src.sections.length);
  let firstBad = -1;
  for (let i = 0; i < n; i++) {
    const a = pack.sections[i], b = src.sections[i];
    if (a.size !== b.size) { firstBad = i; problems.push('section ' + i + ' group count ' + a.size + ' != ' + b.size); break; }
    let bad = false;
    for (const [k, v] of a) {
      if (b.get(k) !== v) { bad = true; break; }
    }
    if (bad) { firstBad = i; problems.push('section ' + i + ' content differs'); break; }
  }
  return {
    ok: problems.length === 0,
    problems,
    firstBadSection: firstBad,
    packNotes: pack.notes,
    sourceNotes: src.notes,
    sections: pack.sections.length,
    sourceTimeMode: src.timeMode,
    packTimeMode: pack.header.timeMode,
    bpm: src.bpm,
  };
}

// ---------------------------------------------------------------------------
// helpers for pack-dir / pack-zip

const SKIP_JSON = /^(events|meta)\.json$/i;
const PARTS_JSON = /\.parts\.json$/i;

function wantedJson(name) {
  if (!/\.json$/i.test(name)) return false;
  const base = path.basename(name);
  if (SKIP_JSON.test(base)) return false;
  if (PARTS_JSON.test(base)) return false;
  return true;
}

function packNameFor(name) {
  return path.basename(name).replace(/\.json$/i, '.chartpack');
}

function humanBytes(n) {
  if (n >= 1 << 30) return (n / (1 << 30)).toFixed(2) + ' GiB';
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(2) + ' MiB';
  if (n >= 1 << 10) return (n / (1 << 10)).toFixed(1) + ' KiB';
  return n + ' B';
}

// ---------------------------------------------------------------------------
// worker plumbing

async function runTask(task) {
  if (task.kind === 'file') return packFile(task.file, task.out, task.opts || {});
  if (task.kind === 'zip') return packZipEntry(task.zipPath, task.entry, task.out, task.opts || {});
  throw new Error('unknown task ' + task.kind);
}

if (!isMainThread && workerData && workerData.task) {
  runTask(workerData.task).then(
    (result) => parentPort.postMessage({ ok: true, result }),
    (e) => parentPort.postMessage({ ok: false, error: e && e.stack ? e.stack : String(e) })
  );
}

function runInWorker(task) {
  return new Promise((resolve, reject) => {
    const w = new Worker(new URL(import.meta.url), { workerData: { task } });
    let settled = false;
    w.once('message', (m) => {
      settled = true;
      w.terminate();
      if (m.ok) resolve(m.result);
      else reject(new Error(m.error));
    });
    w.once('error', (e) => { if (!settled) { settled = true; reject(e); } });
    w.once('exit', (code) => { if (!settled) { settled = true; reject(new Error('worker exited with code ' + code)); } });
  });
}

const PROGRESS_PREFIX = '@@CP@@';

/** Machine-readable progress line for the GUI. Human output keeps working. */
function emitProgress(flags, obj) {
  if (!flags || !flags['progress-json']) return;
  try { process.stdout.write(PROGRESS_PREFIX + JSON.stringify(obj) + '\n'); } catch (e) {}
}

async function runQueue(tasks, jobs, onDone, onStart) {
  let next = 0;
  let failed = 0;
  const results = [];
  async function slot() {
    for (;;) {
      const i = next++;
      if (i >= tasks.length) return;
      const task = tasks[i];
      if (onStart) { try { onStart(task, i); } catch (e) {} }
      try {
        const r = await runInWorker(task);
        results[i] = r;
        onDone(task, r, i);
      } catch (e) {
        failed++;
        results[i] = { error: e.message };
        onDone(task, null, i, e);
      }
    }
  }
  await Promise.all(Array.from({ length: Math.max(1, Math.min(jobs, tasks.length)) }, slot));
  return { results, failed };
}

// ---------------------------------------------------------------------------
// CLI

function parseArgs(argv) {
  const flags = { _: [] };
  for (const a of argv) {
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      if (eq >= 0) flags[a.slice(2, eq)] = a.slice(eq + 1);
      else flags[a.slice(2)] = true;
    } else flags._.push(a);
  }
  return flags;
}

async function cmdPack(flags) {
  const [inFile, outFile] = flags._;
  if (!inFile || !outFile) throw new Error('usage: pack <in.json> <out.chartpack>');
  const opts = { timeMode: flags['time-mode'] || 'auto', chunk: flags.chunk ? Number(flags.chunk) : undefined };
  const st = fs.statSync(inFile);
  const name = path.basename(inFile);
  const t0 = Date.now();
  emitProgress(flags, { event: 'plan', kind: 'file', input: inFile, output: outFile, totalFiles: 1, totalBytes: st.size, jobs: 1, skipped: 0 });
  emitProgress(flags, { event: 'file-start', index: 0, name: name, inputBytes: st.size, output: outFile, total: 1 });
  try {
    const r = await packFile(inFile, outFile, opts);
    emitProgress(flags, Object.assign({ event: 'file-done', index: 0, name: name }, r));
    emitProgress(flags, { event: 'summary', kind: 'file', input: inFile, output: outFile, totalFiles: 1, packed: 1, failed: 0, totalBytes: st.size, totalOut: r.outBytes, ratio: r.ratio, elapsedMs: Date.now() - t0, jobs: 1 });
    if (!flags.quiet) console.log(JSON.stringify(r, null, 2));
    if (flags.stats) console.error('ratio', r.ratio.toFixed(1) + 'x', r.mbps.toFixed(0) + ' MB/s');
    return r;
  } catch (e) {
    emitProgress(flags, { event: 'file-error', index: 0, name: name, error: (e && e.message) ? e.message : String(e) });
    throw e;
  }
}

async function cmdUnpack(flags) {
  const [inFile, outFile] = flags._;
  if (!inFile || !outFile) throw new Error('usage: unpack <in.chartpack> <out.json>');
  const r = unpackFile(inFile, outFile);
  if (!flags.quiet) console.log(JSON.stringify(r, null, 2));
  return r;
}

async function cmdInfo(flags) {
  const [file] = flags._;
  if (!file) throw new Error('usage: info <file.chartpack>');
  const { header, size } = readHeader(file);
  const out = {
    v: header.v, bpm: header.bpm, base: header.base, timeMode: header.timeMode,
    notes: header.notes, groups: header.groups,
    sections: Array.isArray(header.sectionGroups) ? header.sectionGroups.length : null,
    sustains: header.sustains, types: header.types,
    skelLen: header.skelLen, packBytes: size,
    sectionGroups: Array.isArray(header.sectionGroups) ? header.sectionGroups.slice(0, 32) : null,
  };
  console.log(JSON.stringify(out, null, 2));
  return out;
}

async function cmdPackDir(flags) {
  const dir = flags._[0];
  if (!dir) throw new Error('usage: pack-dir <dir> [--replace] [--force] [--jobs=N] [--out-dir=DIR]');
  const files = fs.readdirSync(dir).filter(wantedJson).sort();
  const cores = os.availableParallelism ? os.availableParallelism() : os.cpus().length;
  const jobs = Number(flags.jobs || Math.max(2, Math.min(4, Math.floor(cores / 2))));
  const outDir = flags['out-dir'] ? path.resolve(String(flags['out-dir'])) : path.resolve(dir);
  fs.mkdirSync(outDir, { recursive: true });
  const tasks = [];
  let skipped = 0, totalBytes = 0;
  const t0 = Date.now();
  for (const f of files) {
    const src = path.join(dir, f);
    const out = path.join(outDir, f.replace(/\.json$/i, '.chartpack'));
    if (fs.existsSync(out) && !flags.force) { skipped++; console.error('skip (exists)', f); continue; }
    const size = fs.statSync(src).size;
    totalBytes += size;
    tasks.push({ kind: 'file', file: src, out, opts: { timeMode: flags['time-mode'] || 'auto' }, _name: f, _bytes: size });
  }
  const basePlan = { event: 'plan', kind: 'dir', input: dir, outputDir: outDir, totalFiles: tasks.length, totalBytes, jobs, skipped };
  if (!tasks.length) {
    emitProgress(flags, basePlan);
    emitProgress(flags, { event: 'summary', kind: 'dir', input: dir, outputDir: outDir, totalFiles: 0, packed: 0, failed: 0, skipped, totalBytes: 0, totalOut: 0, ratio: 0, elapsedMs: Date.now() - t0, jobs });
    console.log(JSON.stringify({ dir, files: files.length, skipped, packed: 0 }, null, 2));
    return;
  }
  emitProgress(flags, basePlan);
  const width = String(tasks.length).length;
  let totalIn = 0, totalOut = 0;
  const { failed } = await runQueue(tasks, jobs, (task, r, i, e) => {
    if (e) {
      emitProgress(flags, { event: 'file-error', index: i, name: task._name, inputBytes: task._bytes, error: e.message });
      console.error('FAIL', task.file, e.message);
      return;
    }
    totalIn += r.jsonBytes; totalOut += r.outBytes;
    emitProgress(flags, Object.assign({ event: 'file-done', index: i, name: task._name, inputBytes: task._bytes }, r));
    console.log('[' + String(i + 1).padStart(width) + '/' + tasks.length + ']', path.basename(task.file),
      humanBytes(r.jsonBytes), '->', humanBytes(r.outBytes), '(' + r.ratio.toFixed(1) + 'x)',
      r.notes + ' notes /', r.groups + ' groups', r.timeMode, r.mbps.toFixed(0) + ' MB/s');
    if (flags.replace) { try { fs.unlinkSync(task.file); } catch (e2) { console.error('could not delete', task.file, e2.message); } }
  }, (task, i) => {
    emitProgress(flags, { event: 'file-start', index: i, name: task._name, inputBytes: task._bytes, output: task.out, total: tasks.length });
  });
  emitProgress(flags, { event: 'summary', kind: 'dir', input: dir, outputDir: outDir, totalFiles: tasks.length, packed: tasks.length - failed, failed, skipped, totalBytes, totalOut, ratio: totalOut > 0 ? totalBytes / totalOut : 0, elapsedMs: Date.now() - t0, jobs });
  console.log(JSON.stringify({ dir, files: files.length, skipped, packed: tasks.length - failed, failed, totalIn, totalOut, ratio: totalOut > 0 ? totalIn / totalOut : 0 }, null, 2));
  if (failed) process.exitCode = 1;
}

async function cmdPackZip(flags) {
  const zip = flags._[0];
  if (!zip) throw new Error('usage: pack-zip <archive.zip> [--out-dir=DIR] [--match=TEXT] [--force] [--jobs=N]');
  const dir = readZipDirectory(zip);
  const outDir = path.resolve(flags['out-dir'] || path.dirname(path.resolve(zip)));
  fs.mkdirSync(outDir, { recursive: true });
  const match = flags.match ? String(flags.match).toLowerCase() : null;
  const only = flags.only ? new Set(String(flags.only).split(',').map((s) => s.trim().toLowerCase())) : null;
  const tasks = [];
  let skipped = 0, totalBytes = 0;
  const t0 = Date.now();
  for (const e of dir.entries) {
    if (e.dataStart < 0) continue;
    const base = path.basename(e.name);
    if (!wantedJson(base)) continue;
    if (match && !e.name.toLowerCase().includes(match)) continue;
    if (only && !only.has(base.toLowerCase())) continue;
    const out = path.join(outDir, packNameFor(base));
    if (fs.existsSync(out) && !flags.force) { skipped++; console.error('skip (exists)', base); continue; }
    totalBytes += e.usize;
    tasks.push({ kind: 'zip', zipPath: zip, entry: e, out, opts: { timeMode: flags['time-mode'] || 'auto' }, _name: base, _bytes: e.usize });
  }
  const basePlan = { event: 'plan', kind: 'zip', input: zip, outputDir: outDir, totalFiles: tasks.length, totalBytes, jobs: Number(flags.jobs || 0), skipped, entries: dir.entries.length };
  if (!tasks.length) {
    emitProgress(flags, basePlan);
    emitProgress(flags, { event: 'summary', kind: 'zip', input: zip, outputDir: outDir, totalFiles: 0, packed: 0, failed: 0, skipped, totalBytes: 0, totalOut: 0, ratio: 0, elapsedMs: Date.now() - t0, jobs: 0 });
    console.log(JSON.stringify({ zip, outDir, entries: dir.entries.length, skipped, packed: 0 }, null, 2));
    return;
  }
  const cores = os.availableParallelism ? os.availableParallelism() : os.cpus().length;
  const jobs = Number(flags.jobs || Math.max(2, Math.min(4, Math.floor(cores / 2))));
  basePlan.jobs = jobs;
  emitProgress(flags, basePlan);
  const width = String(tasks.length).length;
  let totalIn = 0, totalOut = 0;
  const { failed } = await runQueue(tasks, jobs, (task, r, i, e) => {
    if (e) {
      emitProgress(flags, { event: 'file-error', index: i, name: task._name, inputBytes: task._bytes, error: e.message });
      console.error('FAIL', task._name, e.message);
      return;
    }
    totalIn += r.jsonBytes; totalOut += r.outBytes;
    emitProgress(flags, Object.assign({ event: 'file-done', index: i, name: task._name, inputBytes: task._bytes }, r));
    console.log('[' + String(i + 1).padStart(width) + '/' + tasks.length + ']', task._name,
      humanBytes(r.jsonBytes), '->', humanBytes(r.outBytes), '(' + r.ratio.toFixed(1) + 'x)',
      r.notes + ' notes /', r.groups + ' groups', r.timeMode,
      r.mbps.toFixed(0) + ' MB/s', (r.totalMs / 1000).toFixed(2) + 's');
  }, (task, i) => {
    emitProgress(flags, { event: 'file-start', index: i, name: task._name, inputBytes: task._bytes, output: task.out, total: tasks.length });
  });
  emitProgress(flags, { event: 'summary', kind: 'zip', input: zip, outputDir: outDir, totalFiles: tasks.length, packed: tasks.length - failed, failed, skipped, totalBytes, totalOut, ratio: totalOut > 0 ? totalBytes / totalOut : 0, elapsedMs: Date.now() - t0, jobs });
  console.log(JSON.stringify({ zip, outDir, entries: dir.entries.length, skipped, packed: tasks.length - failed, failed, totalIn, totalOut, ratio: totalOut > 0 ? totalIn / totalOut : 0 }, null, 2));
  if (failed) process.exitCode = 1;
}

async function cmdVerify(flags) {
  const [pack, src] = flags._;
  if (!pack || !src) throw new Error('usage: verify <pack> <source.json>');
  const r = await verifyPack(pack, () => fs.createReadStream(src, { highWaterMark: 8 << 20 }), { timeMode: flags['time-mode'] || 'auto' });
  console.log(JSON.stringify(r, null, 2));
  if (!r.ok) process.exitCode = 1;
  return r;
}

async function cmdVerifyZip(flags) {
  const [pack, zip, entryName] = flags._;
  if (!pack || !zip || !entryName) throw new Error('usage: verify-zip <pack> <zip> <entry-name>');
  const dir = readZipDirectory(zip);
  const entry = dir.entries.find((e) => e.name === entryName || path.basename(e.name) === entryName);
  if (!entry) throw new Error('zip entry not found: ' + entryName);
  const r = await verifyPack(pack, () => {
    const rs = fs.createReadStream(zip, { start: entry.dataStart, end: entry.dataStart + entry.csize - 1, highWaterMark: 4 << 20 });
    if (entry.method === 0) return rs;
    const inf = zlib.createInflateRaw({ chunkSize: 4 << 20 });
    rs.on('error', (e) => inf.destroy(e));
    rs.pipe(inf);
    return inf;
  }, { timeMode: flags['time-mode'] || 'auto' });
  console.log(JSON.stringify(r, null, 2));
  if (!r.ok) process.exitCode = 1;
  return r;
}

async function main() {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  const flags = parseArgs(argv.slice(1));
  try {
    if (cmd === 'pack') await cmdPack(flags);
    else if (cmd === 'unpack') await cmdUnpack(flags);
    else if (cmd === 'info') await cmdInfo(flags);
    else if (cmd === 'pack-dir') await cmdPackDir(flags);
    else if (cmd === 'pack-zip' || cmd === 'unzip-pack') await cmdPackZip(flags);
    else if (cmd === 'verify') await cmdVerify(flags);
    else if (cmd === 'verify-zip') await cmdVerifyZip(flags);
    else {
      console.error('usage: chartpack.mjs pack|unpack|info|pack-dir|pack-zip|verify|verify-zip ...');
      process.exit(2);
    }
  } catch (e) {
    console.error(e && e.stack ? e.stack : String(e));
    process.exit(1);
  }
}

if (isMainThread && process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();