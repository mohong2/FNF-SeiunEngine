#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_linemap_msvc.py - Windows address->file:line table for the crash handler.

The Android linemap is built from the DWARF tables of an unstripped .so
(tools/gen_linemap.py). MSVC release builds keep the equivalent information in
a PDB, and the crash report needs it WITHOUT shipping that PDB (50+ MB):

  build once with -DHXCPP_DEBUG_LINK (cl /Zi, link /DEBUG -> obj/*.pdb),
  read every source line out of that PDB through dbghelp (SymEnumLinesW),
  write assets/linemap/windows-x64.bin in the same SELM format the C++ handler
  binary-searches at crash time,
  build again so the table -- a resident asset in Project.xml -- is embedded in the exe.

The PDB is a build-time input only: it is never copied into bin/ and never
published. The exe's own release layout is unchanged because the symbol build
forces /OPT:REF /OPT:ICF (see the hxcpp config note).

Note on paths: MSVC attributes code that reaches a translation unit through
#include (native_crash.inc, for example) to the generated .cpp that includes it,
so frames are reported as obj/src/... paths. Paths are written repo-relative
when possible, otherwise the basename is used.

Usage:
    python tools/gen_linemap_msvc.py <ApplicationMain.exe> <out.bin> [--symbols DIR] [--root DIR]

Requires: a PDB matching the exe, either next to it or in --symbols DIR.
"""

import argparse
import ctypes
import hashlib
import os
import struct
import sys
from ctypes import wintypes

MAGIC = b"SELM"
VERSION = 1
MAX_PATH = 260

try:
    import ctypes.wintypes  # noqa: F401
except Exception:  # pragma: no cover - only fails on non-Windows
    pass


class SRCCODEINFOW(ctypes.Structure):
    _fields_ = [
        ("SizeOfStruct", wintypes.DWORD),
        ("Key", ctypes.c_void_p),
        ("ModBase", ctypes.c_ulonglong),
        ("Obj", wintypes.WCHAR * (MAX_PATH + 1)),
        ("FileName", wintypes.WCHAR * (MAX_PATH + 1)),
        ("LineNumber", wintypes.DWORD),
        ("Address", ctypes.c_ulonglong),
    ]


SRCCODE_CALLBACK = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.POINTER(SRCCODEINFOW), ctypes.c_void_p)


def _bind():
    if not hasattr(ctypes, "WinDLL"):
        sys.exit("ERROR: this tool needs Windows (dbghelp.dll)")
    dbghelp = ctypes.WinDLL("dbghelp.dll")
    kernel32 = ctypes.WinDLL("kernel32.dll")

    dbghelp.SymSetOptions.argtypes = [wintypes.DWORD]
    dbghelp.SymSetOptions.restype = wintypes.DWORD
    dbghelp.SymInitializeW.argtypes = [wintypes.HANDLE, wintypes.LPCWSTR, wintypes.BOOL]
    dbghelp.SymInitializeW.restype = wintypes.BOOL
    dbghelp.SymLoadModuleExW.argtypes = [
        wintypes.HANDLE, wintypes.HANDLE, wintypes.LPCWSTR, wintypes.LPCWSTR,
        ctypes.c_ulonglong, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
    dbghelp.SymLoadModuleExW.restype = ctypes.c_ulonglong
    dbghelp.SymEnumLinesW.argtypes = [
        wintypes.HANDLE, ctypes.c_ulonglong, wintypes.LPCWSTR, wintypes.LPCWSTR,
        SRCCODE_CALLBACK, ctypes.c_void_p]
    dbghelp.SymEnumLinesW.restype = wintypes.BOOL
    return dbghelp, kernel32


def collect_rows(exe_path, symbols_dir):
    """Returns (base, {rva: (file, line)}) read from the PDB through dbghelp."""
    dbghelp, kernel32 = _bind()
    process = kernel32.GetCurrentProcess()
    # SYMOPT_UNDNAME | SYMOPT_LOAD_LINES
    dbghelp.SymSetOptions(0x00000002 | 0x00000010)
    if not dbghelp.SymInitializeW(process, symbols_dir, False):
        sys.exit("ERROR: SymInitializeW failed (Win32 error %d)" % ctypes.GetLastError())

    base = dbghelp.SymLoadModuleExW(process, None, exe_path, None, 0, 0, None, 0)
    if base == 0:
        err = ctypes.GetLastError()
        sys.exit("ERROR: SymLoadModuleExW could not load %s (Win32 error %d); "
                 "is the matching PDB in %s?" % (exe_path, err, symbols_dir))

    rows = {}

    def on_line(info, _ctx):
        rec = info.contents
        rva = rec.Address - base
        if rva < 0 or rva > 0xFFFFFFFF:
            return True
        name = rec.FileName
        if name:
            rows[rva] = (name, int(rec.LineNumber))
        return True

    if not dbghelp.SymEnumLinesW(process, base, None, None, SRCCODE_CALLBACK(on_line), None):
        sys.exit("ERROR: SymEnumLinesW failed (Win32 error %d)" % ctypes.GetLastError())
    if not rows:
        sys.exit("ERROR: no line records in %s - was it built with -DHXCPP_DEBUG_LINK?" % exe_path)
    return base, rows


def shorten(path, root):
    """Repo-relative path when possible, basename otherwise (report readability).

    cl.exe records paths as given on its command line: real sources (source/**)
    show up project-relative, generated translation units as
    export/release/windows/obj/src/... - both should read as src/... in a report.
    Anything still absolute after that (CRT/SDK sources from another tree) is cut
    down to its basename.
    """
    text = path.replace("\\", "/")
    root_norm = os.path.abspath(root).replace("\\", "/").rstrip("/") + "/"
    if text.lower().startswith(root_norm.lower()):
        text = text[len(root_norm):]
    marker = "export/release/windows/obj/"
    idx = text.lower().find(marker)
    if idx >= 0:
        text = text[idx + len(marker):]
    if ":" in text:
        return os.path.basename(text)
    return text.lstrip("/")


def build_map(rows, root):
    addrs = sorted(rows.keys())
    entries = []
    prev_file = None
    prev_line = None
    strings = {}
    blob = bytearray()
    out_entries = []
    for addr in addrs:
        name, line = rows[addr]
        name = shorten(name, root)
        if name == prev_file and line == prev_line:
            continue
        prev_file, prev_line = name, line
        idx = strings.get(name)
        if idx is None:
            idx = len(blob)
            strings[name] = idx
            blob.extend(name.encode("utf-8", "replace"))
            blob.extend(b"\x00")
        out_entries.append((addr, line, idx))
    str_off = 16 + 12 * len(out_entries)
    out = bytearray()
    out.extend(MAGIC)
    out.extend(struct.pack("<III", VERSION, len(out_entries), str_off))
    for addr, line, idx in out_entries:
        out.extend(struct.pack("<III", addr, line, idx))
    out.extend(blob)
    return out, out_entries


def selftest(out_bytes, entries):
    """Round-trip a few entries through the exact lookup the C++ handler does."""
    import random
    if not entries:
        return
    random.seed(1234)
    str_table = struct.unpack_from("<I", out_bytes, 12)[0]
    ok = 0
    for _ in range(min(5, len(entries))):
        i = random.randrange(len(entries))
        addr = entries[i][0]
        lo, hi = 0, len(entries)
        while lo + 1 < hi:
            mid = lo + (hi - lo) // 2
            a = struct.unpack_from("<I", out_bytes, 16 + mid * 12)[0]
            if a <= addr:
                lo = mid
            else:
                hi = mid
        line = struct.unpack_from("<I", out_bytes, 16 + lo * 12 + 4)[0]
        soff = struct.unpack_from("<I", out_bytes, 16 + lo * 12 + 8)[0]
        end = out_bytes.index(b"\x00", str_table + soff)
        path = out_bytes[str_table + soff:end].decode("utf-8", "replace")
        if line == entries[i][1]:
            ok += 1
            print("  lookup 0x%08x -> %s:%d" % (addr, path, line))
    print("selftest: %d/5 lookups exact" % ok)


def pe_text_sha(path):
    """SHA256 of the .text section of a PE image (verifies two builds link the
    same code at the same addresses, which is what makes a linemap reusable)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ":
        sys.exit("ERROR: not a PE image: %s" % path)
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\x00\x00":
        sys.exit("ERROR: bad PE signature in %s" % path)
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    sec_off = pe + 24 + opt_size
    for i in range(nsec):
        off = sec_off + i * 40
        name = data[off:off + 8].rstrip(b"\x00").decode("ascii", "replace")
        if name != ".text":
            continue
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, off + 8)
        return hashlib.sha256(data[rawptr:rawptr + rawsize]).hexdigest(), vaddr, rawsize
    sys.exit("ERROR: no .text section in %s" % path)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("exe")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--text-sha", action="store_true",
                    help="print the .text section SHA256 and exit (no PDB needed)")
    ap.add_argument("--symbols", default=None,
                    help="directory holding the PDB (default: the exe directory)")
    ap.add_argument("--root", default=os.getcwd(),
                    help="repo root used to shorten paths (default: cwd)")
    args = ap.parse_args()

    exe_path = os.path.abspath(args.exe)
    if not os.path.isfile(exe_path):
        sys.exit("ERROR: exe not found: %s" % exe_path)
    if args.text_sha:
        digest, vaddr, rawsize = pe_text_sha(exe_path)
        print(".text vaddr=0x%X size=%d sha256=%s" % (vaddr, rawsize, digest))
        return
    if not args.out:
        sys.exit("ERROR: missing output path (or use --text-sha)")
    symbols_dir = os.path.abspath(args.symbols or os.path.dirname(exe_path))
    if not os.path.isdir(symbols_dir):
        sys.exit("ERROR: symbol directory not found: %s" % symbols_dir)

    base, rows = collect_rows(exe_path, symbols_dir)
    print("module base 0x%X, %d raw line records" % (base, len(rows)))
    out_bytes, entries = build_map(rows, args.root)
    print("entries kept (after run-collapse): %d" % len(entries))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(out_bytes)
    print("output: %s (%.1f MB)" % (args.out, len(out_bytes) / 1048576.0))
    selftest(out_bytes, entries)


if __name__ == "__main__":
    main()
