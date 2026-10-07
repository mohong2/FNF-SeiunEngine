#!/usr/bin/env python3
"""
SeiunEngine crash triage -- one self-contained tool (Python 3, standard library only).

You choose the crash report and the .map file. No arguments = window UI (tkinter: native file
dialogs, mouse, click a row to pick a report). --tui = terminal UI. Switches = scripting.

WHY THE .MAP MATTERS
  A report is only exact against the .map of the build that produced it, and every 'lime build'
  overwrites export/release/windows/obj/ApplicationMain.map. Snapshot it after a build
  (--keep-map) and this tool reuses the snapshot matching the report's build fingerprint
  (exe size + PE timestamp). Symbols taken from another build's map are marked STALE.

USAGE
  python tools/crash_triage.py                       window UI (falls back to the terminal UI)
  python tools/crash_triage.py --tui                 terminal UI
  python tools/crash_triage.py --no-gui --summary    scripted, no window at all
  python tools/crash_triage.py --crash R [-m MAP]    triage one report
  python tools/crash_triage.py --all                 triage every report in the crash dir
  python tools/crash_triage.py --summary [--json]    one line per report + signature counts
  python tools/crash_triage.py --keep-map            snapshot the current build's .map
  python tools/crash_triage.py --clean [--keep N] [--prune-maps N] [--dry-run]
  python tools/crash_triage.py --help

EXIT CODES
  0  every triaged report matched the map in use
  1  at least one report came from another build (symbols marked STALE)
  2  nothing to triage, or bad input
"""

from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
import time
from datetime import datetime

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOL_DIR)
DEFAULT_CRASH_DIR = os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'bin', 'crash')
def _first_existing(*paths):
    for p in paths:
        if os.path.isfile(p):
            return p
    return paths[0]

# tools/SymbolsAfterBuild.hx MOVES the map into export/symbols/<platform>-<mode>/
# after every lime build, so look there first and keep the old obj/ spot as a
# fallback for a tree where the hook has not run yet.
DEFAULT_MAP = _first_existing(
    os.path.join(REPO_ROOT, 'export', 'symbols', 'windows-release', 'ApplicationMain.map'),
    os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'obj', 'ApplicationMain.map'))
DEFAULT_EXE = os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'bin', 'SeiunEngine.exe')

REPORT_PREFIXES = ('native_crash', 'SeiunEngine_', 'MohonghEngine_')
MAP_LINE = re.compile(r'^\s+[0-9a-fA-F]{4}:[0-9a-fA-F]{8}\s+(\S+)\s+([0-9a-fA-F]{16})\s+([fi ]+?)\s+(\S+)\s*$')
BASE_LINE = re.compile(r'Preferred load address is\s+([0-9a-fA-F]+)')
NAME_DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2})_(\d{2})'(\d{2})'(\d{2})")
NAME_DATE_COMPACT = re.compile(r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})')


# ----------------------------------------------------------------------------
# build fingerprint / paths
# ----------------------------------------------------------------------------

def exe_fingerprint(path):
    if not path or not os.path.isfile(path):
        return None
    size = os.path.getsize(path)
    stamp = 0
    try:
        with open(path, 'rb') as fh:
            fh.seek(0x3C)
            pe_off = struct.unpack('<I', fh.read(4))[0]
            fh.seek(pe_off + 8)
            stamp = struct.unpack('<I', fh.read(4))[0]
    except Exception:
        stamp = 0
    return {
        'path': os.path.abspath(path),
        'size': size,
        'stamp': stamp,
        'modified': datetime.fromtimestamp(os.path.getmtime(path)).strftime('%Y-%m-%d %H:%M:%S'),
        'fingerprint': '%dB@%ds' % (size, stamp),
    }


def date_from_name(name):
    m = NAME_DATE.search(name) or NAME_DATE_COMPACT.search(name)
    if not m:
        return None
    g = m.groups()
    return '%s-%s-%s %s:%s:%s' % g


def report_files(crash_dir):
    if not os.path.isdir(crash_dir):
        return []
    out = []
    for name in os.listdir(crash_dir):
        if not name.endswith('.txt') or name.endswith('.triage.txt'):
            continue
        if not name.startswith(REPORT_PREFIXES):
            continue
        full = os.path.join(crash_dir, name)
        if os.path.isfile(full):
            out.append(full)
    out.sort(key=lambda p: os.path.getmtime(p))
    return out


def repo_defaults():
    return DEFAULT_CRASH_DIR, DEFAULT_MAP, DEFAULT_EXE

# ----------------------------------------------------------------------------
# crash reports (native SEH dump, and the Haxe CrashHandler text)
# ----------------------------------------------------------------------------

def _first(lines, pattern, group=1):
    rx = re.compile(pattern)
    for line in lines:
        m = rx.match(line)
        if m:
            return m.group(group).strip()
    return None


def read_report(path):
    path = os.path.abspath(path)
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        lines = fh.read().splitlines()

    # Classification only ever looks at the report's own header. Reports used to
    # paste the previous crash files verbatim inside themselves, and a full-file
    # scan then found an embedded native dump and mislabelled the Haxe report it
    # sat in. The embed is gone, but the header window keeps that class of bug
    # from coming back.
    head = lines[:40]
    exc = _first(head, r'^Exception code:\s*(0x[0-9a-fA-F]+)')
    fault_text = _first(head, r'^Fault offset:\s*(0x[0-9a-fA-F]+)')
    if exc or fault_text:
        kind = 'native'
    elif _first(head, r'^(=== .*Crash Report ===)'):
        kind = 'haxe'
    else:
        kind = 'unknown'

    build_raw = _first(lines, r'^Build:\s*SeiunEngine\.exe=(\d+B@\d+s#[0-9a-fA-F]+)')
    build_size = build_stamp = build_hash = None
    if build_raw:
        m = re.match(r'^(\d+)B@(\d+)s#([0-9a-fA-F]+)$', build_raw)
        if m:
            build_size = int(m.group(1))
            build_stamp = int(m.group(2))
            build_hash = m.group(3)

    context = _first(lines, r'^Context:\s*(.+)$')
    ctx_state = ctx_song = None
    if context:
        m = re.search(r'state=([^|\s]+)', context)
        if m:
            ctx_state = m.group(1)
        m = re.search(r'song=([^|\s]+)', context)
        if m:
            ctx_song = m.group(1)

    frames = []
    in_bt = False
    for line in lines:
        # Section banners ("--- Backtrace ... ---") are accepted too, so the
        # report layout can gain headings without silently killing frame parsing.
        if re.match(r'^(---\s*)?Backtrace', line):
            in_bt = True
            continue
        if in_bt and re.match(r'^(---\s*)?Stack scan', line):
            break
        if not in_bt:
            continue
        m = re.match(r'^\s+#(\d+)\s+(\S+?)\+0x([0-9a-fA-F]+)', line)
        if m:
            frames.append({'index': int(m.group(1)), 'module': m.group(2), 'offset': int(m.group(3), 16)})

    error_text = ''
    for i, line in enumerate(lines):
        if re.match(r'^Error:\s*$', line):
            chunks = []
            for nxt in lines[i + 1:]:
                if not nxt.strip():
                    break
                chunks.append(nxt.strip())
            error_text = ' '.join(chunks).strip()
            break

    haxe_stack = []
    for i, line in enumerate(lines):
        if re.match(r'^Stack Trace:\s*$', line):
            for nxt in lines[i + 1:]:
                if nxt.startswith('=== '):
                    break
                if nxt.strip():
                    haxe_stack.append(nxt.strip())
            break
    # Release builds run without HXCPP_STACK_TRACE, so the section carries an
    # explanatory note instead of frames - that is not a stack.
    if haxe_stack and haxe_stack[0].startswith('(empty'):
        haxe_stack = []

    date = _first(lines, r'^Date:\s*(.+)$') or date_from_name(os.path.basename(path))
    return {
        'path': path,
        'name': os.path.basename(path),
        'kind': kind,
        'date': date,
        'exception': exc,
        'exception_name': _first(lines, r'^Exception code:\s*0x[0-9a-fA-F]+\s*\(([^)]*)\)'),
        'fault_offset': int(fault_text, 16) if fault_text else None,
        'faulting_module': _first(lines, r'^Faulting module:\s*(.+)$'),
        'app': _first(lines, r'^App:\s*(.+)$'),
        'engine': _first(lines, r'^Engine:\s*(.+)$'),
        'build_raw': build_raw,
        'build_size': build_size,
        'build_stamp': build_stamp,
        'build_hash': build_hash,
        'context': context,
        'state': ctx_state,
        'song': ctx_song,
        'backtrace': frames,
        'error': error_text,
        'haxe_stack': haxe_stack,
    }


def report_fingerprint(report):
    if report.get('build_size') is None:
        return None
    return '%dB@%ds' % (report['build_size'], report['build_stamp'])

# ----------------------------------------------------------------------------
# .map parsing (~337k lines / ~80k functions / ~2-3 s) + binary-search lookup
# ----------------------------------------------------------------------------

def name_score(name):
    if name.startswith('$') or name.startswith('__real@') or name.startswith('__xmm@') or name.startswith('__guard_'):
        return 0
    if name.startswith('?'):
        return 3
    if name.startswith('_'):
        return 2
    return 1


def human_name(name):
    '''Cheap MSVC mangling -> Namespace::Class_obj::method (same idea as tools/mapresolve.py).'''
    if not name.startswith('?'):
        return name
    m = re.match(r'^\?([^@]+)@(.*?)@@', name)
    if not m:
        return name[1:]
    scope = [part for part in m.group(2).split('@') if part]
    scope.reverse()
    return '::'.join(scope + [m.group(1)])


class MapData:
    '''Sorted RVA list + {rva: (mangled name, .obj)} for one linker .map.'''

    def __init__(self, path, base, names, size, elapsed):
        self.path = path
        self.base = base
        self.names = names
        self.keys = sorted(names)
        self.size = size
        self.elapsed = elapsed


def read_map(path, log=None):
    path = os.path.abspath(path)
    size = os.path.getsize(path)
    if log:
        log('  loading map %s (%.1f MB)...' % (os.path.basename(path), size / (1024.0 * 1024.0)))
    started = time.time()
    base = 0
    names = {}
    score = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            if not base:
                m = BASE_LINE.search(line)
                if m:
                    base = int(m.group(1), 16)
            m = MAP_LINE.match(line)
            if not m:
                continue
            if 'f' not in m.group(3):
                continue
            rva = int(m.group(2), 16) - base
            name = m.group(1)
            prev = names.get(rva)
            if prev is not None:
                if name_score(name) <= score[rva]:
                    continue
            names[rva] = (name, m.group(4))
            score[rva] = name_score(name)
    if not base:
        raise ValueError('not a linker .map (no preferred load address): %s' % path)
    return MapData(path, base, names, size, time.time() - started)


def resolve_offset(map_data, offset):
    import bisect
    keys = map_data.keys
    idx = bisect.bisect_right(keys, offset) - 1
    if idx < 0:
        return None
    rva = keys[idx]
    name, obj = map_data.names[rva]
    return {'symbol': human_name(name), 'obj': obj, 'displacement': offset - rva}


def format_hit(hit, stale=False):
    if not hit:
        return '(below the first symbol in this map)'
    text = '%s + 0x%X' % (hit['symbol'], hit['displacement'])
    if hit['obj']:
        text += '   [%s]' % hit['obj']
    if stale:
        text += '   (STALE)'
    return text

# ----------------------------------------------------------------------------
# map selection
# ----------------------------------------------------------------------------

def maps_dir(crash_dir):
    return os.path.join(crash_dir, 'maps')


def select_map(report, forced_map, current, crash_dir, default_map=None):
    default_map = default_map or DEFAULT_MAP
    fp = report_fingerprint(report) if report else None
    if forced_map:
        if not os.path.isfile(forced_map):
            raise FileNotFoundError('map not found: %s' % forced_map)
        path = os.path.abspath(forced_map)
        exact = bool(fp) and os.path.splitext(os.path.basename(path))[0] == fp
        quality = 'chosen by you (matches the report build)' if exact else 'chosen by you (cannot verify against this report)'
        return {'path': path, 'exact': exact, 'quality': quality}
    if fp:
        snap = os.path.join(maps_dir(crash_dir), fp + '.map')
        if os.path.isfile(snap):
            return {'path': snap, 'exact': True, 'quality': 'snapshot for this build'}
    if os.path.isfile(default_map):
        exact = bool(fp and current and fp == current['fingerprint'])
        if exact:
            quality = 'current build'
        elif not fp:
            quality = 'current build (report has no build stamp)'
        else:
            quality = 'current build (MISMATCH - this report is from another build)'
        return {'path': os.path.abspath(default_map), 'exact': exact, 'quality': quality}
    return None


# ----------------------------------------------------------------------------
# the triage pipeline (the CI-style steps + the report block)
# ----------------------------------------------------------------------------

def analyze(report_path, forced_map, current, crash_dir, frames=8, map_cache=None,
            default_map=None, write=True, log=None):
    map_cache = map_cache if map_cache is not None else {}
    steps = []

    def step(title, status, detail=''):
        steps.append({'title': title, 'status': status, 'detail': detail})

    report = read_report(report_path)
    step('read report', 'OK', '%s  [%s]%s' % (report['name'], report['kind'],
         ('  ' + report['date']) if report['date'] else ''))

    fp = report_fingerprint(report)
    if fp:
        step('report build fingerprint', 'OK', fp + ('#' + report['build_hash'] if report['build_hash'] else ''))
    else:
        step('report build fingerprint', 'SKIP', 'this older report does not record it')

    info = select_map(report, forced_map, current, crash_dir, default_map)
    if info:
        step('select .map', 'OK', '%s   [%s]' % (info['path'], info['quality']))
    else:
        step('select .map', 'FAIL', 'none found - use -m/--map or snapshot with --keep-map')

    map_data = None
    if info:
        if info['path'] in map_cache:
            map_data = map_cache[info['path']]
            step('load .map', 'OK', 'cached (%d functions)' % len(map_data.keys))
        else:
            map_data = read_map(info['path'], log=None)
            map_cache[info['path']] = map_data
            step('load .map', 'OK', '%.1f MB, %d functions, %.1fs' % (
                map_data.size / (1024.0 * 1024.0), len(map_data.keys), map_data.elapsed))

    stale = not (info and info['exact'])
    if info and info['exact']:
        step('compare builds', 'OK', 'this map is the build that produced the report')
    elif current:
        step('compare builds', 'STALE', 'report %s vs current %s' % (fp or '(none)', current['fingerprint']))
    else:
        step('compare builds', 'STALE', 'current exe not found')

    if map_data and report['fault_offset'] is not None:
        hit = resolve_offset(map_data, report['fault_offset'])
        step('resolve fault offset', 'OK', '0x%X -> %s' % (report['fault_offset'], format_hit(hit, stale)));
    elif map_data:
        step('resolve fault offset', 'SKIP', 'this report has no fault offset (Haxe-level crash)')
    else:
        step('resolve fault offset', 'SKIP', 'no map loaded')

    block = report_block(report, info, map_data, current, frames, stale)

    written = None
    if write:
        try:
            dest = os.path.splitext(report['path'])[0] + '.triage.txt'
            with open(dest, 'w', encoding='utf-8', newline='') as fh:
                fh.write('\n'.join(block) + '\n')
            written = dest
            step('write triage file', 'OK', dest)
        except OSError as exc:
            step('write triage file', 'FAIL', str(exc))
    else:
        step('write triage file', 'SKIP', 'disabled (--no-write)')

    return {'report': report, 'steps': steps, 'block': block, 'stale': stale, 'written': written,
            'map': info, 'fingerprint': fp}

def report_block(report, info, map_data, current, frames, stale):
    out = []
    out.append('=' * 78)
    head = '%s   [%s]' % (report['name'], report['kind'])
    if report['date']:
        head += '   ' + report['date']
    out.append(head)
    out.append('=' * 78)
    if report['app']:
        out.append('  app          : ' + report['app'])
    elif report['engine']:
        out.append('  engine       : ' + report['engine'])
    if report['kind'] == 'native':
        name = ' (%s)' % report['exception_name'] if report['exception_name'] else ''
        out.append('  exception    : %s%s' % (report['exception'], name))
        if report['context']:
            out.append('  context      : ' + report['context'])
        if report['faulting_module']:
            out.append('  fault module : ' + os.path.basename(report['faulting_module']))
    if report['error']:
        out.append('  error        : ' + report['error'])
    for line in report['haxe_stack']:
        out.append('      ' + line)
    out.append('  report build : ' + (report['build_raw'] or '(not recorded in this older report)'))
    out.append('  current exe  : ' + (current['fingerprint'] + '   (' + current['modified'] + ')' if current else '(not built)'))
    if info and info['exact']:
        out.append('  build match  : YES - this map is the build that produced the report')
    else:
        out.append('  build match  : NO - the map is from another build; symbols below are hints only')
    out.append('  map          : ' + ('%s   [%s]' % (info['path'], info['quality']) if info else '(none found)'))

    if map_data and report['fault_offset'] is not None:
        out.append('  fault offset : 0x%X' % report['fault_offset'])
        out.append('        -> ' + format_hit(resolve_offset(map_data, report['fault_offset']), stale))
        app_frames = [f for f in report['backtrace'] if 'SeiunEngine.exe' in f['module']][:frames]
        if app_frames:
            out.append('  call stack (app module, first %d):' % len(app_frames))
            for f in app_frames:
                hit = resolve_offset(map_data, f['offset'])
                out.append('      #%02d 0x%X -> %s' % (f['index'], f['offset'], format_hit(hit, stale)))
    elif map_data:
        out.append('  fault offset : (this report has no fault offset - Haxe-level crash, nothing to symbolise)')
    out.append('')
    return out


# ----------------------------------------------------------------------------
# summary / keep-map / clean
# ----------------------------------------------------------------------------

def summary_rows(crash_dir, current, map_data):
    rows = []
    for path in reversed(report_files(crash_dir)):
        report = read_report(path)
        fp = report_fingerprint(report)
        match = bool(current and fp and fp == current['fingerprint'])
        symbol = ''
        if map_data and report['fault_offset'] is not None:
            hit = resolve_offset(map_data, report['fault_offset'])
            if hit:
                symbol = '%s + 0x%X' % (hit['symbol'], hit['displacement'])
                if not match:
                    symbol = '~ ' + symbol
        rows.append({
            'name': report['name'], 'date': report['date'] or '', 'kind': report['kind'],
            'exception': report['exception'] or '-', 'state': report['state'] or '',
            'song': report['song'], 'buildMatch': match,
            'faultOffset': ('0x%X' % report['fault_offset']) if report['fault_offset'] is not None else None,
            'symbol': symbol,
        })
    return rows


def keep_map(map_path, crash_dir, exe_path, force=False):
    src = map_path or DEFAULT_MAP
    if not os.path.isfile(src):
        raise FileNotFoundError('map not found: %s (build the client first, or pass --map)' % src)
    current = exe_fingerprint(exe_path)
    if not current:
        raise FileNotFoundError('exe not found: %s' % exe_path)
    out_dir = maps_dir(crash_dir)
    os.makedirs(out_dir, exist_ok=True)
    dest = os.path.join(out_dir, current['fingerprint'] + '.map')
    if os.path.isfile(dest) and not force:
        return {'path': dest, 'skipped': True, 'fingerprint': current['fingerprint']}
    import hashlib
    import shutil
    shutil.copyfile(src, dest)
    digest = hashlib.sha256(open(dest, 'rb').read()).hexdigest().upper()
    side = {
        'fingerprint': current['fingerprint'], 'exeBytes': current['size'],
        'peTimestamp': current['stamp'], 'exe': current['path'], 'mapSource': os.path.abspath(src),
        'mapBytes': os.path.getsize(dest), 'mapSha256': digest,
        'savedAt': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    }
    with open(os.path.splitext(dest)[0] + '.json', 'w', encoding='utf-8') as fh:
        json.dump(side, fh, indent=2)
    return {'path': dest, 'skipped': False, 'fingerprint': current['fingerprint'],
            'bytes': side['mapBytes'], 'sha256': digest}


def clean(crash_dir, keep=20, prune_maps=0, dry_run=False):
    moved = []
    reports = list(reversed(report_files(crash_dir)))
    for report in reports[keep:]:
        stamp = date_from_name(os.path.basename(report))
        bucket = (stamp or datetime.fromtimestamp(os.path.getmtime(report)).strftime('%Y-%m-%d'))[:7]
        dest_dir = os.path.join(crash_dir, 'archive', bucket)
        trio = [report] + [p for p in [os.path.splitext(report)[0] + '.triage.txt'] if os.path.isfile(p)]
        for item in trio:
            target = os.path.join(dest_dir, os.path.basename(item))
            if not dry_run:
                os.makedirs(dest_dir, exist_ok=True)
                os.replace(item, target)
            moved.append(target)
    if prune_maps > 0:
        out_dir = maps_dir(crash_dir)
        if os.path.isdir(out_dir):
            snaps = [os.path.join(out_dir, n) for n in os.listdir(out_dir) if n.endswith('.map')]
            snaps.sort(key=os.path.getmtime, reverse=True)
            for old in snaps[prune_maps:]:
                if not dry_run:
                    os.remove(old)
                    side = os.path.splitext(old)[0] + '.json'
                    if os.path.isfile(side):
                        os.remove(side)
                moved.append(old)
    return moved

# ----------------------------------------------------------------------------
# colours + CI-style step rendering (shared by the terminal UI and the window log)
# ----------------------------------------------------------------------------

_CODES = {'reset': '\033[0m', 'dim': '\033[2m', 'bold': '\033[1m', 'red': '\033[31m',
          'green': '\033[32m', 'yellow': '\033[33m', 'cyan': '\033[36m'}
USE_COLOR = False


def enable_ansi():
    global USE_COLOR
    if os.name != 'nt':
        USE_COLOR = bool(getattr(sys.stdout, 'isatty', lambda: False)())
        return USE_COLOR
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)
        mode = ctypes.c_uint32()
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            USE_COLOR = False
            return False
        kernel32.SetConsoleMode(handle, mode.value | 0x0004)
        USE_COLOR = True
    except Exception:
        USE_COLOR = False
    return USE_COLOR


def col(text, name):
    if not USE_COLOR:
        return text
    return _CODES.get(name, '') + text + _CODES['reset']


STATUS_COLOR = {'OK': 'green', 'STALE': 'yellow', 'WARN': 'yellow', 'FAIL': 'red', 'SKIP': 'dim'}


def step_plain(steps, width=76):
    '''[(line, status), ...] -- '[ 3/7 ] compare builds .... STALE  detail'.'''
    out = []
    total = len(steps)
    for i, item in enumerate(steps, 1):
        label = '[ %d/%d ] %s ' % (i, total, item['title'])
        dots = '.' * max(2, width - len(label))
        line = label + dots + ' ' + item['status'].ljust(5)
        if item['detail']:
            line += '  ' + item['detail']
        out.append((line, item['status']))
    return out


def step_lines(steps, width=76):
    '''[ 3/7 ] compare builds .......... STALE  detail'''
    out = []
    for line, status in step_plain(steps, width):
        marker = status.ljust(5)
        idx = line.find(marker)
        if idx >= 0:
            line = line[:idx] + col(marker, STATUS_COLOR.get(status, 'reset')) + line[idx + len(marker):]
        out.append(line)
    return out


def ruler(title='', width=78):
    if not title:
        return '=' * width
    pad = width - len(title) - 3
    return '== ' + title + ' ' + '=' * max(0, pad)


# ----------------------------------------------------------------------------
# file dialog (Explorer / native picker); needs tkinter, degrades to None
# ----------------------------------------------------------------------------

def pick_file(title, filetypes, initialdir=None, save=False):
    try:
        import tkinter as tk
        from tkinter import filedialog
    except Exception:
        return None
    try:
        root = tk.Tk()
        root.withdraw()
        try:
            root.attributes('-topmost', True)
        except Exception:
            pass
        opts = {'title': title, 'filetypes': filetypes}
        if initialdir and os.path.isdir(initialdir):
            opts['initialdir'] = initialdir
        path = filedialog.asksaveasfilename(**opts) if save else filedialog.askopenfilename(**opts)
        root.destroy()
        return path or None
    except Exception:
        return None

# ----------------------------------------------------------------------------
# window UI (tkinter): native Explorer dialogs, mouse, CI-style log
# ----------------------------------------------------------------------------

def gui_available():
    try:
        import tkinter  # noqa: F401
        return True
    except Exception:
        return False


def run_gui(crash_dir, exe_path, default_map, forced_map=None, frames=8):
    import queue
    import threading
    import tkinter as tk
    from tkinter import filedialog, ttk

    current = exe_fingerprint(exe_path)
    map_cache = {}
    jobs = queue.Queue()

    root = tk.Tk()
    root.title('SeiunEngine Crash Triage')
    root.geometry('1040x790+60+40')   # keep the whole window on screen
    root.minsize(880, 640)
    mono = ('Consolas', 10) if os.name == 'nt' else ('Menlo', 11)

    inputs = ttk.LabelFrame(root, text=' Inputs  (you pick both files) ')
    inputs.pack(fill='x', padx=10, pady=(10, 6))
    inputs.columnconfigure(1, weight=1)

    crash_var = tk.StringVar(value='')
    map_var = tk.StringVar(value=forced_map or '')
    use_map_var = tk.BooleanVar(value=bool(forced_map))

    def browse(var, title, patterns):
        initial = os.path.dirname(var.get()) if var.get() else crash_dir
        path = filedialog.askopenfilename(parent=root, title=title, initialdir=initial, filetypes=patterns)
        if path:
            var.set(path)
            if var is crash_var:
                update_info()
        return path

    ttk.Label(inputs, text='Crash report').grid(row=0, column=0, sticky='w', padx=6, pady=4)
    ttk.Entry(inputs, textvariable=crash_var).grid(row=0, column=1, sticky='ew', padx=6, pady=4)
    ttk.Button(inputs, text='Browse...', command=lambda: browse(crash_var, 'Choose a crash report',
        [('Crash reports', '*.txt'), ('All files', '*.*')])).grid(row=0, column=2, padx=6, pady=4)

    ttk.Label(inputs, text='Map file').grid(row=1, column=0, sticky='w', padx=6, pady=4)
    ttk.Entry(inputs, textvariable=map_var).grid(row=1, column=1, sticky='ew', padx=6, pady=4)
    ttk.Button(inputs, text='Browse...', command=lambda: browse(map_var, 'Choose a linker .map',
        [('Map files', '*.map'), ('All files', '*.*')])).grid(row=1, column=2, padx=6, pady=4)

    ttk.Checkbutton(inputs, variable=use_map_var,
        text='use this .map   (unchecked = auto: snapshot for the report build, else the current one)'
        ).grid(row=2, column=0, columnspan=3, sticky='w', padx=6, pady=(0, 2))
    info = ttk.Label(inputs, text='', foreground='#666666')
    info.grid(row=3, column=0, columnspan=3, sticky='w', padx=6, pady=(0, 6))

    mid = ttk.LabelFrame(root, text=' Reports (newest first; click = select, double-click = triage) ')
    mid.pack(fill='both', padx=10, pady=6)
    cols = ('date', 'name', 'kind', 'exception')
    tree = ttk.Treeview(mid, columns=cols, show='headings', height=9)
    for name, width in zip(cols, (150, 430, 80, 130)):
        tree.heading(name, text=name)
        tree.column(name, width=width, anchor='w')
    tree.pack(side='left', fill='both', expand=True, padx=(6, 0), pady=6)
    tree_sb = ttk.Scrollbar(mid, orient='vertical', command=tree.yview)
    tree_sb.pack(side='right', fill='y', pady=6)
    tree.configure(yscrollcommand=tree_sb.set)

    out_frame = ttk.LabelFrame(root, text=' Output (CI-style steps + report detail) ')
    out_frame.pack(fill='both', expand=True, padx=10, pady=6)
    out = tk.Text(out_frame, wrap='none', font=mono, background='#0f1419', foreground='#d8dee9',
                  insertbackground='#d8dee9', height=16)
    out.pack(side='left', fill='both', expand=True, padx=(6, 0), pady=6)
    out_sb = ttk.Scrollbar(out_frame, orient='vertical', command=out.yview)
    out_sb.pack(side='right', fill='y', pady=6)
    out.configure(yscrollcommand=out_sb.set, state='disabled')
    for tag, colour in (('ok', '#7ec699'), ('stale', '#e6c07b'), ('fail', '#e06c75'),
                        ('dim', '#7f8c98'), ('head', '#61afef'), ('plain', '#d8dee9')):
        out.tag_configure(tag, foreground=colour)

    buttons = ttk.Frame(root)
    buttons.pack(fill='x', padx=10)
    status = tk.StringVar(value='ready')
    ttk.Label(root, textvariable=status, anchor='w').pack(fill='x', padx=12, pady=(4, 8))

    def write(text, tag='plain'):
        out.configure(state='normal')
        out.insert('end', text + '\n', tag)
        out.see('end')
        out.configure(state='disabled')

    def post(kind, payload=None, tag='plain'):
        jobs.put((kind, payload, tag))

    def drain():
        try:
            while True:
                kind, payload, tag = jobs.get_nowait()
                try:
                    if kind == 'line':
                        write(payload, tag)
                    elif kind == 'status':
                        status.set(payload)
                    elif kind == 'busy':
                        set_busy(payload)
                    elif kind == 'refresh':
                        refresh_tree()
                    elif kind == 'see':
                        out.yview(payload)   # put that line at the top of the pane
                except Exception as exc:      # never let one bad update kill the poll loop
                    write('UI error: %s' % exc, 'fail')
        except queue.Empty:
            pass
        root.after(60, drain)

    def set_busy(busy):
        state = 'disabled' if busy else 'normal'
        for widget in button_widgets:
            try:
                widget.configure(state=state)
            except Exception:
                pass

    def run_bg(job):
        set_busy(True)

        def worker():
            try:
                job()
            except Exception as exc:
                post('line', 'ERROR: %s' % exc, 'fail')
            finally:
                post('busy', False)

        threading.Thread(target=worker, daemon=True).start()

    def refresh_tree():
        tree.delete(*tree.get_children())
        files = list(reversed(report_files(crash_dir)))
        for path in files:
            try:
                report = read_report(path)
            except Exception:
                continue
            tree.insert('', 'end', iid=path, values=(report['date'] or '', report['name'],
                        report['kind'], report['exception'] or '-'))
        tree.yview_moveto(0)          # newest first, always show the top of the list
        status.set('%d report(s)   |   %s' % (len(files), crash_dir))
        if files and not crash_var.get():
            crash_var.set(files[0])
        update_info()

    def update_info():
        bits = []
        if current:
            bits.append('current build: %s  (%s)' % (current['fingerprint'], current['modified']))
        else:
            bits.append('current build: (SeiunEngine.exe not found)')
        report = None
        path = crash_var.get().strip()
        if path and os.path.isfile(path):
            try:
                report = read_report(path)
            except Exception:
                report = None
        auto = select_map(report, None, current, crash_dir, default_map)
        bits.append(('auto map: %s   [%s]' % (auto['path'], auto['quality'])) if auto else 'auto map: (none found)')
        info.configure(text='        '.join(bits))

    def chosen_map():
        if not use_map_var.get():
            return None
        path = map_var.get().strip()
        if path and not os.path.isfile(path):
            raise FileNotFoundError('map not found: %s' % path)
        return path or None

    def all_reports():
        return list(reversed(report_files(crash_dir)))

    def selected_paths():
        sel = list(tree.selection())
        if sel:
            return sel
        path = crash_var.get().strip()
        if path and os.path.isfile(path):
            return [path]
        files = all_reports()
        return [files[0]] if files else []

    def on_select(_event=None):
        sel = tree.selection()
        if sel:
            crash_var.set(sel[0])
            update_info()

    def on_double(_event=None):
        paths = selected_paths()
        if paths:
            triage(paths)

    def triage(paths):
        start_index = out.index('end-1c')   # where this job's output begins

        def job():
            forced = chosen_map()
            stale_total = 0
            for i, path in enumerate(paths):
                post('line', ruler('triage %d/%d   %s' % (i + 1, len(paths), os.path.basename(path))), 'head')
                result = analyze(path, forced, current, crash_dir, frames=frames, map_cache=map_cache,
                                 default_map=default_map, write=(len(paths) == 1))
                for line, st in step_plain(result['steps']):
                    post('line', line, {'OK': 'ok', 'STALE': 'stale', 'FAIL': 'fail'}.get(st, 'dim'))
                for line in result['block']:
                    post('line', line, 'plain')
                if result['stale']:
                    stale_total += 1
                post('line', '', 'plain')
            if stale_total == 0:
                post('line', 'RESULT: %d report(s), all matched the map' % len(paths), 'ok')
            else:
                post('line', 'RESULT: %d report(s), %d from another build (symbols are hints)' % (len(paths), stale_total), 'stale')
            post('see', start_index)     # leave the view at this job's first line (the CI steps)
            post('status', 'done')
        run_bg(job)

    def summary():
        def job():
            post('line', ruler('summary'), 'head')
            info2 = select_map(None, chosen_map(), current, crash_dir, default_map)
            map_data = None
            if info2:
                if info2['path'] not in map_cache:
                    map_cache[info2['path']] = read_map(info2['path'])
                map_data = map_cache[info2['path']]
            rows = summary_rows(crash_dir, current, map_data)
            post('line', '%-19s %-7s %-11s %-26s %-6s %s' % ('date', 'kind', 'exception', 'state', 'build', 'faulting function'), 'plain')
            post('line', '-' * 118, 'dim')
            for row in rows:
                post('line', '%-19s %-7s %-11s %-26s %-6s %s' % (
                    (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
                    'match' if row['buildMatch'] else 'other', row['symbol']), 'plain')
            for line in signature_lines(rows):
                post('line', line, 'plain')
            post('line', "note: a ~ prefix means the symbol came from another build's map (a hint, not proof).", 'dim')
            post('status', 'summary done')
        run_bg(job)

    def keep():
        def job():
            post('line', ruler('keep-map'), 'head')
            source = map_var.get().strip() if use_map_var.get() else None
            result = keep_map(source, crash_dir, exe_path)
            if result['skipped']:
                post('line', 'already snapshotted: %s' % result['path'], 'ok')
            else:
                post('line', 'snapshotted: %s' % result['path'], 'ok')
                post('line', 'fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']), 'plain')
            post('status', 'keep-map done')
        run_bg(job)

    def archive():
        def job():
            post('line', ruler('archive old reports (keep the newest 20)'), 'head')
            moved = clean(crash_dir, keep=20, prune_maps=0, dry_run=False)
            post('line', 'moved %d item(s)' % len(moved), 'ok')
            post('refresh', None)
            post('status', 'archive done')
        run_bg(job)

    button_widgets = []

    def add_button(text, command):
        widget = ttk.Button(buttons, text=text, command=command)
        widget.pack(side='left', padx=4, pady=4)
        button_widgets.append(widget)
        return widget

    add_button('Triage selected', lambda: triage(selected_paths()))
    add_button('Triage ALL reports', lambda: triage(all_reports()))
    add_button('Summary', summary)
    add_button('Snapshot current .map', keep)
    add_button('Archive old reports', archive)
    add_button('Clear output', lambda: clear_output())
    add_button('Quit', root.destroy)

    def clear_output():
        out.configure(state='normal')
        out.delete('1.0', 'end')
        out.configure(state='disabled')

    tree.bind('<<TreeviewSelect>>', on_select)
    tree.bind('<Double-1>', on_double)
    refresh_tree();
    drain();
    write(ruler('SeiunEngine crash triage'), 'head')
    write('Pick a crash report (Browse... or click a row), optionally pick a .map, then press a button.', 'dim')
    if not current:
        write('note: SeiunEngine.exe was not found, so build matching cannot be checked.', 'stale')
    root.mainloop()
    return 0

def signature_lines(rows):
    counts = {}
    for row in rows:
        symbol = row['symbol'] or ('(no symbol) ' + (row['state'] or ''))
        key = '%s  |  %s' % (row['exception'], symbol)
        counts[key] = counts.get(key, 0) + 1
    out = ['', '--- signatures (exception + faulting function) ---']
    for key in sorted(counts, key=lambda k: -counts[k]):
        out.append('  %4dx  %s' % (counts[key], key))
    return out


# ----------------------------------------------------------------------------
# terminal UI (ANSI; no curses on Windows)
# ----------------------------------------------------------------------------

def run_tui(crash_dir, exe_path, default_map, forced_map=None, frames=8):
    if not USE_COLOR:
        enable_ansi()
    current = exe_fingerprint(exe_path)
    map_cache = {}
    forced = forced_map

    def ask(prompt):
        try:
            answer = input(prompt)
        except (EOFError, KeyboardInterrupt):
            return None
        # tolerate a BOM / stray whitespace when input is piped from another shell
        return answer.lstrip('\ufeff').strip()

    def ask_map(report):
        auto = select_map(report, None, current, crash_dir, default_map)
        print()
        print(col('Map file for this report:', 'cyan'))
        if auto:
            print('  [Enter] auto  ->  %s   [%s]' % (auto['path'], auto['quality']))
        else:
            print('  [Enter] auto  ->  (nothing found)')
        print('  [p]           ->  pick a .map file with a file dialog')
        print('  [path]        ->  paste the path of a .map file')
        answer = ask('> ')
        if not answer:
            return None
        if answer.lower() == 'p':
            picked = pick_file('Choose a linker .map', [('Map files', '*.map'), ('All files', '*.*')],
                               os.path.dirname(default_map))
            if picked:
                return picked
            print(col('  (nothing picked - using auto)', 'yellow'))
            return None
        return answer.strip('"')

    def do_triage(paths, forced_map_choice):
        stale = 0
        for i, path in enumerate(paths):
            print()
            print(col(ruler('triage %d/%d   %s' % (i + 1, len(paths), os.path.basename(path))), 'cyan'))
            result = analyze(path, forced_map_choice, current, crash_dir, frames=frames, map_cache=map_cache,
                             default_map=default_map, write=(len(paths) == 1))
            for line in step_lines(result['steps']):
                print(line)
            print()
            for line in result['block']:
                print(line)
            if result['stale']:
                stale += 1
        print()
        if stale == 0:
            print(col('RESULT: %d report(s), all matched the map' % len(paths), 'green'))
        else:
            print(col('RESULT: %d report(s), %d from another build (symbols are hints)' % (len(paths), stale), 'yellow'))
        return stale

    while True:
        files = list(reversed(report_files(crash_dir)))
        print()
        print(col(ruler('SeiunEngine crash triage'), 'cyan'))
        print('  crash dir : %s' % crash_dir)
        print('  reports   : %d' % len(files))
        if current:
            print('  current   : %s   (%s)' % (current['fingerprint'], current['modified']))
        else:
            print(col('  current   : (SeiunEngine.exe not found)', 'yellow'))
        if forced:
            print(col('  map       : %s   (chosen by you)' % forced, 'yellow'))
        else:
            print('  map       : auto (snapshot for the report build, else the current one)')
        print()
        print('  1  triage the newest report')
        print('  2  triage a listed report (by number)')
        print('  3  choose a crash report with a file dialog')
        print('  4  triage every report')
        print('  5  summary table')
        print('  6  snapshot the current .map now (keep-map)')
        print('  7  list .map snapshots')
        print('  8  archive old reports (keep the newest 20)')
        print('  9  choose a .map file to use from now on')
        print('  h  help        q  quit')
        choice = ask('> ')
        if choice is None:
            print()
            return 0
        choice = choice.lower()
        if choice == 'q':
            return 0
        elif choice == 'h':
            print('A report is only exact against the .map of the build that produced it.');
            print('Snapshot after every build (menu 6); symbols from another build are marked STALE.')
        elif choice == '1':
            if not files:
                print(col('  no reports here', 'yellow'))
                continue
            report = read_report(files[0])
            picked = ask_map(report)
            if picked:
                forced = picked
            do_triage([files[0]], forced)
        elif choice == '2':
            if not files:
                print(col('  no reports here', 'yellow'))
                continue
            for i, path in enumerate(files[:15], 1):
                print('  %3d) %s   %s' % (i, os.path.basename(path),
                      datetime.fromtimestamp(os.path.getmtime(path)).strftime('%Y-%m-%d %H:%M')))
            sel = ask('number> ')
            if sel and sel.isdigit() and 1 <= int(sel) <= min(15, len(files)):
                target = files[int(sel) - 1]
                report = read_report(target)
                picked = ask_map(report)
                if picked:
                    forced = picked
                do_triage([target], forced)
            elif sel:
                print(col('  out of range', 'yellow'))
        elif choice == '3':
            picked = pick_file('Choose a crash report', [('Crash reports', '*.txt'), ('All files', '*.*')], crash_dir)
            if not picked:
                print(col('  (nothing picked)', 'yellow'))
                continue
            report = read_report(picked)
            map_pick = ask_map(report)
            if map_pick:
                forced = map_pick
            do_triage([picked], forced)
        elif choice == '4':
            if not files:
                print(col('  no reports here', 'yellow'))
                continue
            do_triage(files, forced)
        elif choice == '5':
            info = select_map(None, forced, current, crash_dir, default_map)
            map_data = None
            if info:
                if info['path'] not in map_cache:
                    map_cache[info['path']] = read_map(info['path'])
                map_data = map_cache[info['path']]
            rows = summary_rows(crash_dir, current, map_data)
            print()
            print('%-19s %-7s %-11s %-26s %-6s %s' % ('date', 'kind', 'exception', 'state', 'build', 'faulting function'))
            print('-' * 118)
            for row in rows:
                print('%-19s %-7s %-11s %-26s %-6s %s' % (
                    (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
                    'match' if row['buildMatch'] else 'other', row['symbol']))
            for line in signature_lines(rows):
                print(line)
        elif choice == '6':
            try:
                result = keep_map(forced, crash_dir, exe_path)
            except Exception as exc:
                print(col('  ERROR: %s' % exc, 'red'))
                continue
            if result['skipped']:
                print(col('  already snapshotted: %s' % result['path'], 'green'))
            else:
                print(col('  snapshotted: %s' % result['path'], 'green'))
                print('  fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']))
        elif choice == '7':
            out_dir = maps_dir(crash_dir)
            if not os.path.isdir(out_dir):
                print('  no snapshots in %s' % out_dir)
                continue
            for name in sorted(os.listdir(out_dir)):
                if name.endswith('.map'):
                    full = os.path.join(out_dir, name)
                    print('  %-30s %12d B' % (name, os.path.getsize(full)))
        elif choice == '8':
            moved = clean(crash_dir, keep=20, prune_maps=0, dry_run=False)
            print(col('  moved %d item(s)' % len(moved), 'green'))
        elif choice == '9':
            print()
            print(col('Use which .map from now on?', 'cyan'))
            print('  [Enter] auto  ->  back to auto')
            print('  [p]           ->  pick a .map file with a file dialog')
            print('  [path]        ->  paste the path of a .map file')
            answer = ask('> ')
            if answer is None:
                return 0
            if answer == '':
                forced = None
            elif answer.lower() == 'p':
                picked = pick_file('Choose a linker .map', [('Map files', '*.map'), ('All files', '*.*')],
                                    os.path.dirname(default_map))
                if picked:
                    forced = picked
                else:
                    print(col('  (nothing picked)', 'yellow'))
            else:
                forced = answer.strip('"')
        else:
            print(col('  ?', 'yellow'))

# ----------------------------------------------------------------------------
# command line
# ----------------------------------------------------------------------------

def print_summary(crash_dir, current, map_data, rows, map_info=None):
    print('crash dir : %s' % crash_dir)
    if current:
        print('current   : %s   (%s)' % (current['fingerprint'], current['modified']))
    print('reports   : %d' % len(rows))
    if map_info:
        print('map       : %s   [%s]' % (map_info['path'], map_info['quality']))
    print()
    print('%-19s %-7s %-11s %-26s %-6s %s' % ('date', 'kind', 'exception', 'state', 'build', 'faulting function'))
    print('-' * 118)
    for row in rows:
        print('%-19s %-7s %-11s %-26s %-6s %s' % (
            (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
            'match' if row['buildMatch'] else 'other', row['symbol']))
    for line in signature_lines(rows):
        print(line)
    print()
    print(col("note: a ~ prefix means the symbol came from another build's map (a hint, not proof).", 'dim'))


def build_parser():
    parser = argparse.ArgumentParser(
        prog='crash_triage.py',
        description='SeiunEngine crash triage: pick the crash report and the .map, get the crashing function.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='With no switches this opens the window UI (tkinter); --tui or --no-gui uses the terminal UI.\n'
               'Exit codes: 0 all matched, 1 some report is from another build, 2 nothing to do.')
    parser.add_argument('--crash', '-c', metavar='REPORT', help='triage this crash report')
    parser.add_argument('--map', '-m', metavar='MAP', help='use this linker .map (default: auto)')
    parser.add_argument('--all', action='store_true', help='triage every report in the crash dir')
    parser.add_argument('--pick', action='store_true', help='choose the report with a file dialog')
    parser.add_argument('--summary', action='store_true', help='one line per report + signature counts')
    parser.add_argument('--json', action='store_true', help='machine-readable summary output')
    parser.add_argument('--keep-map', action='store_true', help="snapshot the current build's .map")
    parser.add_argument('--clean', action='store_true', help='archive old reports')
    parser.add_argument('--keep', type=int, default=20, metavar='N', help='keep the newest N reports (default 20)')
    parser.add_argument('--prune-maps', type=int, default=0, metavar='N', help='keep only the newest N map snapshots')
    parser.add_argument('--dry-run', action='store_true', help='--clean: do not move or delete anything')
    parser.add_argument('--frames', type=int, default=8, metavar='N', help='how many app frames to symbolise (default 8)')
    parser.add_argument('--crash-dir', metavar='DIR', help='override the crash directory')
    parser.add_argument('--exe', metavar='EXE', help='override the exe used for the build fingerprint')
    parser.add_argument('--tui', action='store_true', help='terminal UI (never opens a window)')
    parser.add_argument('--no-gui', action='store_true', help='same as --tui, kept for scripting')
    parser.add_argument('--no-write', action='store_true', help='do not write <report>.triage.txt')
    parser.add_argument('--no-color', action='store_true', help='plain terminal output')
    return parser


def main(argv=None):
    global USE_COLOR
    args = build_parser().parse_args(argv)
    if args.no_color:
        USE_COLOR = False

    crash_dir = args.crash_dir or DEFAULT_CRASH_DIR
    exe_path = args.exe or DEFAULT_EXE
    current = exe_fingerprint(exe_path)

    if args.keep_map:
        enable_ansi()
        try:
            result = keep_map(args.map, crash_dir, exe_path)
        except Exception as exc:
            print(col('ERROR: %s' % exc, 'red'))
            return 2
        if result['skipped']:
            print(col('already snapshotted: %s' % result['path'], 'green'))
        else:
            print(col('snapshotted: %s' % result['path'], 'green'))
            print('fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']))
        return 0

    if args.clean:
        enable_ansi()
        moved = clean(crash_dir, keep=args.keep, prune_maps=args.prune_maps, dry_run=args.dry_run)
        verb = 'would move' if args.dry_run else 'moved'
        print(col('%s %d item(s)' % (verb, len(moved)), 'green'))
        for item in moved[:20]:
            print('  ' + item)
        if len(moved) > 20:
            print('  ... and %d more' % (len(moved) - 20))
        return 0

    if args.summary:
        enable_ansi()
        info = select_map(None, args.map, current, crash_dir, DEFAULT_MAP)
        map_data = None
        if info:
            print(col('  loading map %s...' % os.path.basename(info['path']), 'dim'))
            map_data = read_map(info['path'])
        rows = summary_rows(crash_dir, current, map_data)
        if args.json:
            print(json.dumps(rows, indent=2))
            return 0
        print_summary(crash_dir, current, map_data, rows, info)
        return 0

    if args.crash or args.all or args.pick:
        enable_ansi()
        if args.crash:
            if not os.path.isfile(args.crash):
                print(col('report not found: %s' % args.crash, 'red'))
                return 2
            targets = [os.path.abspath(args.crash)]
        elif args.pick:
            picked = pick_file('Choose a crash report', [('Crash reports', '*.txt'), ('All files', '*.*')], crash_dir)
            if not picked:
                print(col('nothing picked', 'yellow'))
                return 2
            targets = [picked]
        else:
            targets = list(reversed(report_files(crash_dir)))
        if not targets:
            print('no crash reports in %s' % crash_dir)
            return 2
        stale = 0
        cache = {}
        for i, path in enumerate(targets):
            print(ruler('triage %d/%d   %s' % (i + 1, len(targets), os.path.basename(path))))
            result = analyze(path, args.map, current, crash_dir, frames=args.frames, map_cache=cache,
                             default_map=DEFAULT_MAP, write=(not args.no_write and len(targets) == 1))
            for line in step_lines(result['steps']):
                print(line)
            print()
            for line in result['block']:
                print(line)
            if result['stale']:
                stale += 1
        return 1 if stale else 0

    interactive_terminal = False
    try:
        interactive_terminal = bool(sys.stdin and sys.stdin.isatty() and sys.stdout and sys.stdout.isatty())
    except Exception:
        interactive_terminal = False
    if args.tui or args.no_gui or not gui_available() or not interactive_terminal:
        return run_tui(crash_dir, exe_path, DEFAULT_MAP, forced_map=args.map, frames=args.frames)
    return run_gui(crash_dir, exe_path, DEFAULT_MAP, forced_map=args.map, frames=args.frames)


if __name__ == '__main__':
    sys.exit(main())

