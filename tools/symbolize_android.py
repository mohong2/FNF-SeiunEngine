#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""symbolize_android.py - resolve an Android crash report offline.

    python tools/symbolize_android.py <report.txt>
    python tools/symbolize_android.py <report.txt> --lib export/symbols/android-release/libApplicationMain-arm64-v8a.so
    python tools/symbolize_android.py <report.txt> --bin assets/linemap/arm64-v8a.bin

An Android crash report carries module-relative offsets ("pc 000000000034abcd
libApplicationMain.so"), because HXCPP_MAP_FILE is an MSVC-toolchain thing and a
release .so links stripped. The engine embeds a SELM address -> file:line table
so the report is annotated on-device, but a table built for a different link
annotates wrongly, and a plain release build used to leave no symbols at all.

This tool does the offline half:
  1. read the report's "Build:" identity (so=<size>B@<mtime>s#<hash>),
  2. find the UNSTRIPPED .so of that build under export/symbols/ (the postbuild
     hook puts it there), proving the report came from it by matching the
     shipped .so size + hash when possible,
  3. build (and cache) a SELM table from it with tools/gen_linemap.py,
  4. resolve every frame against it.

Requires pyelftools (pip install pyelftools); no NDK, no llvm-symbolizer.
Exit 0 = resolved and verified, 1 = resolved but unverified, 2 = could not run.
"""

import argparse
import bisect
import os
import re
import struct
import sys

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOL_DIR)
sys.path.insert(0, TOOL_DIR)

import fnv1a  # noqa: E402

PC_LINE = re.compile(r'^\s*(?:#\d+\s+)?pc\s+([0-9a-fA-F]{4,16})\s+(\S+)(.*)$')
ANNOTATION = re.compile(r'\[([^\[\]]+?):(\d+)\]\s*$')
BUILD_LINE = re.compile(r'^Build:\s*(.*)$', re.M)
SO_FIELD = re.compile(r'\bso=(\S+)')
SIZE_HASH = re.compile(r'size=(\d+)B@(\d+)s#([0-9a-fA-F]{1,8})')
LINEMAP_FIELD = re.compile(r'linemap=([A-Za-z0-9_\-]+):(\d+)B#([0-9a-fA-F]{1,8})')
ABI_FIELD = re.compile(r'\babi=([A-Za-z0-9_\-]+)')
SELM_MAGIC = b'SELM'


def read_report(path):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()

    info = {'path': path}
    m = BUILD_LINE.search(text)
    if m:
        info['build'] = m.group(1).strip()
        for key, rx in (('so', SO_FIELD), ('abi', ABI_FIELD), ('linemap', LINEMAP_FIELD)):
            mm = rx.search(info['build'])
            if mm:
                info[key] = mm.groups()
        mm = SIZE_HASH.search(info['build'])
        if mm:
            info['so_size'] = int(mm.group(1))
            info['so_hash'] = int(mm.group(3), 16)

    frames = []
    for line in text.splitlines():
        m = PC_LINE.match(line)
        if not m:
            continue
        tail = m.group(3) or ''
        ann = ANNOTATION.search(tail)
        frames.append({
            'offset': int(m.group(1), 16),
            'lib': m.group(2),
            'symbol': tail.strip(),
            'annotation': (ann.group(1) + ':' + ann.group(2)) if ann else None,
        })
    return info, frames, text


def load_selm(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] != SELM_MAGIC:
        raise ValueError('%s is not a SELM table' % path)
    version, count, str_off = struct.unpack_from('<III', data, 4)
    addrs, rows = [], []
    for i in range(count):
        a, line, so = struct.unpack_from('<III', data, 16 + i * 12)
        addrs.append(a)
        rows.append((line, so))
    return {'addrs': addrs, 'rows': rows, 'str_off': str_off, 'data': data, 'path': path}


def lookup(selm, offset):
    i = bisect.bisect_right(selm['addrs'], offset) - 1
    if i < 0:
        return None
    line, so = selm['rows'][i]
    if line == 0:
        return None
    start = selm['str_off'] + so
    end = selm['data'].index(b'\x00', start)
    return selm['data'][start:end].decode('utf-8', 'replace'), line


def build_selm(lib, cache=True, quiet=False):
    selm = lib + '.selm'
    if cache and os.path.isfile(selm) and os.path.getmtime(selm) >= os.path.getmtime(lib):
        return selm
    import gen_linemap
    if not quiet:
        print('[symbolize] building the line table for %s (one-off, cached)' % os.path.basename(lib))
    rows, strings = gen_linemap.collect_rows(lib)
    out, entries = gen_linemap.build_map(rows, strings)
    with open(selm, 'wb') as f:
        f.write(out)
    if not quiet:
        print('[symbolize] %d entries -> %s' % (len(entries), selm))
    return selm


def find_shipped_and_symbols(info):
    """Pair the report's shipped .so identity with an unstripped one.

    -> (shipped_path, symbols_path, mode-when-verified)
    """
    want_size = info.get('so_size')
    want_hash = info.get('so_hash')
    candidates = []
    export = os.path.join(REPO_ROOT, 'export')
    if os.path.isdir(export):
        for mode in ('release', 'debug'):
            obj = os.path.join(export, mode, 'android', 'obj')
            if not os.path.isdir(obj):
                continue
            for name in sorted(os.listdir(obj)):
                if not (name.startswith('libApplicationMain') and name.endswith('.so')):
                    continue
                if name.startswith('libApplicationMain-debug'):
                    continue
                candidates.append((mode, os.path.join(obj, name)))

    shipped = verified = None
    for mode, path in candidates:
        if want_size is not None and os.path.getsize(path) == want_size:
            if want_hash is None or fnv1a.hash_head_tail(path) == want_hash:
                shipped, verified = path, mode
                break
    if shipped is None:
        for mode, path in candidates:
            if shipped is None or os.path.getmtime(path) > os.path.getmtime(shipped):
                shipped, verified = path, None

    abi = info.get('abi')
    if isinstance(abi, tuple):
        abi = abi[0]

    # 1) the bundle the postbuild hook fills, 2) hxcpp's own unstripped copy if the
    # hook never ran (no haxe on PATH), 3) the per-target leftovers of older layouts.
    explicit = []
    modes = [verified] if verified else []
    for mode in ('release', 'debug'):
        if mode not in modes:
            modes.append(mode)
    for mode in modes:
        explicit.append(os.path.join(export, mode, 'android', 'obj', 'libApplicationMain.so'))
        objobj = os.path.join(export, mode, 'android', 'obj', 'obj')
        if os.path.isdir(objobj):
            for sub in sorted(os.listdir(objobj)):
                explicit.append(os.path.join(objobj, sub, 'libApplicationMain.so'))
    symbols = None
    search_dirs = []
    for mode in modes:
        search_dirs.append(os.path.join(export, 'symbols', 'android-%s' % mode))
    for d in search_dirs:
        if not os.path.isdir(d):
            continue
        names = sorted(os.listdir(d))
        wanted = []
        if abi:
            wanted.append('libApplicationMain-%s.so' % abi)
        wanted.append('libApplicationMain.so')
        for want in wanted:
            if want in names:
                symbols = os.path.join(d, want)
                break
        if not symbols:
            for n in names:
                if n.startswith('libApplicationMain') and n.endswith('.so'):
                    symbols = os.path.join(d, n)
                    break
        if symbols:
            break
    if symbols:
        return shipped, symbols, verified

    # The hook never ran (no haxe on PATH): hxcpp's own unstripped copies are the
    # only symbols there are. Note these are NOT named after the ABI.
    for path in explicit:
        if os.path.isfile(path):
            return shipped, path, verified
    return shipped, None, verified


def main():
    ap = argparse.ArgumentParser(description='Resolve an Android crash report offline.')
    ap.add_argument('report', help='the native_crash_*.txt pulled off the device')
    ap.add_argument('--lib', help='unstripped libApplicationMain*.so for that build')
    ap.add_argument('--bin', help='SELM table to use directly (instead of --lib)')
    ap.add_argument('--no-cache', action='store_true', help='do not reuse/write <lib>.selm')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    if not os.path.isfile(args.report):
        sys.exit('ERROR: report not found: %s' % args.report)

    info, frames, _text = read_report(args.report)
    if not info.get('build'):
        print('[symbolize] no "Build:" line: this does not look like a POSIX/Android report')
    else:
        print('[symbolize] report   %s' % os.path.basename(args.report))
        print('[symbolize] build    %s' % info['build'])
    if not frames:
        print('[symbolize] no "pc <offset> <lib>" frames in this report')
        return 0

    verified = None
    explicit_source = bool(args.lib or args.bin)
    lib = args.lib
    if not lib and not args.bin:
        shipped, lib, verified = find_shipped_and_symbols(info)
        if shipped:
            print('[symbolize] shipped  %s' % os.path.relpath(shipped, REPO_ROOT))
        if verified:
            print('[symbolize] the report belongs to this build (shipped .so size + hash match)')
        elif shipped:
            print('[symbolize] WARNING: could not match the report so= identity to a local build;'
                  ' the frames below are hints, not proof')
        else:
            print('[symbolize] WARNING: no shipped libApplicationMain*.so under export/ to match against')

    if args.bin:
        selm = load_selm(args.bin)
        print('[symbolize] table    %s' % os.path.relpath(args.bin, REPO_ROOT))
    else:
        if not lib:
            print('[symbolize] ERROR: no unstripped .so found. Build through the Project.xml hook'
                  ' (HXCPP_DEBUG_LINK_AND_STRIP is on for android release), or pass --lib / --bin.')
            return 2
        if not os.path.isfile(lib):
            sys.exit('ERROR: --lib not found: %s' % lib)
        print('[symbolize] symbols  %s (%d B)' % (os.path.relpath(lib, REPO_ROOT), os.path.getsize(lib)))
        try:
            selm_path = build_selm(lib, cache=not args.no_cache, quiet=args.quiet)
        except SystemExit as e:
            print('[symbolize] ERROR: could not build the line table: %s' % e)
            print('[symbolize]        a release .so with no DWARF means the build was stripped -'
                  ' rebuild so HXCPP_DEBUG_LINK_AND_STRIP keeps a copy')
            return 2
        except Exception as e:
            print('[symbolize] ERROR: could not build the line table: %s' % e)
            return 2
        selm = load_selm(selm_path)

    print()
    if info.get('linemap'):
        abi, size, h = info['linemap']
        print('[symbolize] report carries an embedded linemap (%s, %s B, #%s)' % (abi, size, h))
        local = os.path.join(REPO_ROOT, 'assets', 'linemap', '%s.bin' % abi)
        if os.path.isfile(local) and str(os.path.getsize(local)) != size:
            print('[symbolize] local assets/linemap/%s.bin is %d B - NOT the table in this build'
                  % (abi, os.path.getsize(local)))
    print()

    unresolved = 0
    for i, fr in enumerate(frames):
        got = lookup(selm, fr['offset'])
        ondevice = fr['annotation'] or ''
        where = ('%s:%d' % got) if got else '(no line info)'
        if not got:
            unresolved += 1
        agree = ''
        if got and ondevice:
            agree = '  [device linemap: %s%s]' % (ondevice, '' if ondevice == where else '  <-- DISAGREES')
        elif ondevice:
            agree = '  [device linemap: %s]' % ondevice
        print('  #%02d  0x%08x  %-28s %s%s'
              % (i, fr['offset'], os.path.basename(fr['lib']), where, agree))

    print()
    if unresolved:
        print('[symbolize] %d of %d frames had no line info (other module, or no DWARF there)'
              % (unresolved, len(frames)))
    if verified:
        print('[symbolize] symbols match the build in the report')
        return 0
    if explicit_source:
        print('[symbolize] used the symbol source you named (not checked against the report)')
        return 0
    print('[symbolize] symbols are UNVERIFIED against this report - check the so= size#hash first')
    return 1


if __name__ == '__main__':
    sys.exit(main())
