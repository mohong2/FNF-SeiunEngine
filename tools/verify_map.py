#!/usr/bin/env python3
"""Prove that a linker .map belongs to a given exe, before anyone resolves a crash with it.

WHY
  Offsets from a crash report are only meaningful against the .map produced by the
  link that built that exact exe. Reach for the wrong map - a stale one from before
  the last commit, or the release map after a rebuild moved .text - and every frame
  resolves to a plausible-looking function that is simply wrong. A wrong symbol is
  worse than no symbol: it sends the investigation in the wrong direction.

WHAT IS CHECKED (all from the two files themselves, no build metadata needed)
  1. TimeDateStamp   - the .map header records "Timestamp is <hex>", which IS the
                       PE TimeDateStamp of the image that link produced. Exact match.
  2. Image base      - "Preferred load address is <hex>" vs the PE ImageBase. The map
                       stores absolute addresses, so a different base shifts everything.
  3. .text extent    - the map's segment-1 ".text*" entries vs the PE .text section.
                       Both bodies of code must be the same size, within one section
                       alignment (the map splits .text into .text/.text$mn/.text$x/...,
                       so the entries are summed, not compared one by one). This is
                       what confirms the addresses the map stores point at code that
                       actually exists in this image.

  Checks 1 and 2 are exact and are what makes a map identifiable. Check 3 confirms the
  addresses the map actually stores still point into code in this image.

USAGE
  python tools/verify_map.py <exe> <map> [--quiet]
  python tools/verify_map.py export/release/windows/bin/SeiunEngine.exe \
                             export/release/windows/symbols/ApplicationMain.map

EXIT CODES
  0  the map describes this exe
  1  the map does NOT describe this exe - do not use it
  2  could not read one of the files
"""
from __future__ import annotations

import os
import re
import struct
import sys

TIMESTAMP_RE = re.compile(r"^\s*Timestamp is\s+([0-9a-fA-F]{8})")
BASE_RE = re.compile(r"^\s*Preferred load address is\s+([0-9a-fA-F]+)")
SECTION_RE = re.compile(r"^\s*([0-9a-fA-F]{4}):([0-9a-fA-F]{8})\s+([0-9a-fA-F]+)H\s+(\S+)\s+(\S+)\s*$")


def read_pe(path):
    """Return the fields a .map can be checked against, or None."""
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 0x40 or data[:2] != b"MZ":
        return None
    (pe_off,) = struct.unpack_from("<I", data, 0x3C)
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        return None
    coff = pe_off + 4
    (_machine, nsec, timestamp) = struct.unpack_from("<HHI", data, coff)[:3]
    (opt_size,) = struct.unpack_from("<H", data, coff + 16)
    opt = coff + 20
    (magic,) = struct.unpack_from("<H", data, opt)
    if magic == 0x20B:          # PE32+
        (image_base,) = struct.unpack_from("<Q", data, opt + 24)
        (section_align,) = struct.unpack_from("<I", data, opt + 32)
        (size_of_image,) = struct.unpack_from("<I", data, opt + 56)
    elif magic == 0x10B:        # PE32
        (image_base,) = struct.unpack_from("<I", data, opt + 28)
        (section_align,) = struct.unpack_from("<I", data, opt + 32)
        (size_of_image,) = struct.unpack_from("<I", data, opt + 56)
    else:
        return None
    text = None
    sec = opt + opt_size
    for i in range(nsec):
        off = sec + i * 40
        name = data[off:off + 8].rstrip(b"\0").decode("ascii", "replace")
        (vsize, vaddr, rawsize) = struct.unpack_from("<III", data, off + 8)
        if name == ".text":
            text = {"vaddr": vaddr, "vsize": vsize, "rawsize": rawsize}
    if text is None:
        return None
    return {"path": os.path.abspath(path), "timestamp": timestamp, "image_base": image_base,
            "section_align": section_align, "size_of_image": size_of_image, "text": text,
            "size": len(data)}


def read_map_head(path, max_lines=400):
    """Return the .map header fields (timestamp, base, .text* extent)."""
    timestamp = None
    base = None
    text_start = None
    text_len = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh):
            if n > max_lines:
                break
            if timestamp is None:
                m = TIMESTAMP_RE.match(line)
                if m:
                    timestamp = int(m.group(1), 16)
                    continue
            if base is None:
                m = BASE_RE.match(line)
                if m:
                    base = int(m.group(1), 16)
                    continue
            m = SECTION_RE.match(line.rstrip("\n"))
            if not m:
                continue
            seg, off, length, name, _cls = m.groups()
            if seg != "0001" or not name.startswith(".text"):
                continue
            o = int(off, 16)
            if text_start is None:
                text_start = o
            text_len = max(text_len, o + int(length, 16)) - text_start
    return {"path": os.path.abspath(path), "timestamp": timestamp, "base": base,
            "text_start": text_start, "text_len": text_len, "size": os.path.getsize(path)}


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    quiet = "--quiet" in sys.argv
    if len(args) < 2:
        print(__doc__)
        return 2

    try:
        pe = read_pe(args[0])
    except OSError as exc:
        print(f"error: cannot read exe {args[0]}: {exc}")
        return 2
    try:
        mp = read_map_head(args[1])
    except OSError as exc:
        print(f"error: cannot read map {args[1]}: {exc}")
        return 2
    if pe is None:
        print(f"error: {args[0]} is not a PE image")
        return 2
    if mp["timestamp"] is None or mp["base"] is None:
        print(f"error: {args[1]} has no MSVC map header (Timestamp/Preferred load address)")
        return 2

    os.system("")  # no-op; keeps colour codes harmless on old consoles
    def mark(ok):
        return "OK  " if ok else "FAIL"

    checks = []
    checks.append(("build stamp", pe["timestamp"] == mp["timestamp"],
                   f"map Timestamp=0x{mp['timestamp']:08X}  exe TimeDateStamp=0x{pe['timestamp']:08X}",
                   "the map was produced by a different link - do not use it"))
    checks.append(("image base", pe["image_base"] == mp["base"],
                   f"map base=0x{mp['base']:X}  exe ImageBase=0x{pe['image_base']:X}",
                   "absolute addresses in the map do not apply to this image"))
    # The map numbers offsets from the start of each PE section, so its segment-1
    # ".text*" block starts at 0 no matter what RVA the PE gave .text.
    text_ok = (mp["text_start"] == 0 and mp["text_len"] > 0
               and abs(mp["text_len"] - pe["text"]["vsize"]) <= max(pe["section_align"], 0x1000))
    checks.append((".text extent", text_ok,
                   f"map .text size=0x{mp['text_len']:X}  exe .text rva=0x{pe['text']['vaddr']:X} "
                   f"size=0x{pe['text']['vsize']:X}",
                   "the code the map describes is not the code in this image"))

    failed = [c for c in checks if not c[1]]
    if not quiet:
        print(f"exe: {pe['path']}  ({pe['size']} bytes)")
        print(f"map: {mp['path']}  ({mp['size']} bytes)")
        print()
        for name, ok, detail, why in checks:
            print(f"  [{mark(ok)}] {name:<12} {detail}")
            if not ok:
                print(f"           -> {why}")
        print()
        print("MATCH: this map describes this exe." if not failed
              else "MISMATCH: this map does NOT describe this exe.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
