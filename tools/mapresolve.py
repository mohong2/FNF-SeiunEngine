#!/usr/bin/env python3
"""Resolve SeiunEngine crash offsets using the linker .map file only.

Official release builds do NOT enable HXCPP_DEBUG_LINK: it passes /DEBUG to the
linker, which makes MSVC write debug directory data into the image (release exe
grows ~29.6 MB -> ~47.1 MB). Without /DEBUG the exe carries no CodeView (RSDS)
record, so dbghelp cannot pair it with a PDB by GUID and the crash report's
inline frames degrade to export-table guesses like "<sprintf>+0x20413".

The .map file is unaffected by that trade-off: the linker produces it from the
same objects and it carries the exact address of every function, so a report's
"Fault offset" resolves offline to a real function name.

Map line format (note the flags column - only 'f' entries are real functions,
'f i' means the symbol was folded into an identical one by /OPT:ICF):

 0001:0132bfa0       ??$?0VGfxLru_obj@backend@@@...  000000014132cfa0 f i obj.obj

Usage:
  python tools/mapresolve.py <map> 0x1340289 0x133429A
  python tools/mapresolve.py --crash-dir export/release/windows/bin/crash <map>
"""
from __future__ import annotations

import os
import re
import sys

BASE_RE = re.compile(r"Preferred load address is\s+([0-9a-fA-F]+)")
# <seg>:<off> <name> <abs addr> <flags> <obj>
LINE_RE = re.compile(
    r"^\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{8})\s+(\S+)\s+([0-9a-fA-F]{16})\s+([fi ]+?)\s+(\S+)\s*$"
)


def load_map(path):
    """Return (base, {rva: (name, obj)}).

    The .map public-symbol block lists several entries per address: the real
    function (flags 'f'), /OPT:ICF-folded aliases ('f i') and compiler-internal
    labels ($LN<n> line numbers, $unwind$, $pdata$, __real@<double>, ...).
    Only one entry per address may survive, so collisions are resolved by
    preferring the most informative name and recorded for inspection.
    """
    base = 0x140000000
    funcs = {}
    collisions = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if base == 0x140000000:
                m = BASE_RE.search(line)
                if m:
                    base = int(m.group(1), 16)
            m = LINE_RE.match(line.rstrip("\n"))
            if not m:
                continue
            _seg, _off, name, addr, flags, obj = m.groups()
            if "f" not in flags:
                continue
            rva = int(addr, 16) - base
            prev = funcs.get(rva)
            if prev is None:
                funcs[rva] = (name, obj)
            else:
                collisions += 1
                if score(name) > score(prev[0]):
                    funcs[rva] = (name, obj)
    return base, funcs


def score(name: str) -> int:
    """Higher = more useful as a symbolication anchor."""
    if name.startswith("$"):
        return 0
    if name.startswith("__real@") or name.startswith("__xmm@") or name.startswith("__guard_"):
        return 0
    if name.startswith("?"):
        return 3          # mangled C++ function
    if name.startswith("_"):
        return 2          # C function
    return 1


def demangle(name: str) -> str:
    """Cheap MSVC mangling -> readable 'Namespace::Class_obj::method'."""
    if not name.startswith("?"):
        return name
    body = name[1:]
    m = re.match(r"\?([^@]+)@(.*?)@@", name)
    if m:
        method = m.group(1)
        scope = [p for p in m.group(2).split("@") if p]
        scope.reverse()
        return "::".join(scope + [method])
    return body


def resolve(sorted_rvas, funcs, rva):
    import bisect

    i = bisect.bisect_right(sorted_rvas, rva) - 1
    if i < 0:
        return None
    srva = sorted_rvas[i]
    name, obj = funcs[srva]
    return srva, name, obj, rva - srva


def main() -> int:
    args = sys.argv[1:]
    crash_dir = None
    if "--crash-dir" in args:
        i = args.index("--crash-dir")
        crash_dir = args[i + 1]
        del args[i : i + 2]
    if not args:
        print(__doc__)
        return 2

    map_path = args[0]
    base, funcs = load_map(map_path)
    sorted_rvas = sorted(funcs)
    print(f"map={map_path}\n  base=0x{base:X}  functions={len(funcs)}\n")

    if "find" in args:
        needle = args[args.index("find") + 1]
        hits = 0
        for rva in sorted_rvas:
            if needle.lower() in funcs[rva][0].lower():
                print(f"  rva 0x{rva:X}  {demangle(funcs[rva][0])}")
                hits += 1
                if hits >= 40:
                    break
        print(f"({hits} shown)")
        return 0

    if crash_dir:
        targets = []
        for fn in sorted(os.listdir(crash_dir)):
            if not fn.startswith("native_crash") or not fn.endswith(".txt"):
                continue
            text = open(os.path.join(crash_dir, fn), "r", encoding="utf-8", errors="replace").read()
            mod = re.search(r"Faulting module:\s*(.+)", text)
            if mod and os.path.basename(mod.group(1).strip()).lower() != "seiunengine.exe":
                continue
            m = re.search(r"Fault offset:\s*0x([0-9A-Fa-f]+)", text)
            if m:
                targets.append((fn, int(m.group(1), 16)))
    else:
        targets = []
        for a in args[1:]:
            # Tolerate "0xA,0xB" (PowerShell passes a -Offset array as one item).
            for part in str(a).split(","):
                part = part.strip()
                if not part:
                    continue
                targets.append((part, int(part, 16)))

    for label, rva in targets:
        hit = resolve(sorted_rvas, funcs, rva)
        if hit is None:
            print(f"{label}: rva 0x{rva:X}  <below first function>")
            continue
        srva, name, obj, disp = hit
        print(f"{label}: rva 0x{rva:X}")
        print(f"    {demangle(name)} + 0x{disp:X}   [func rva 0x{srva:X}, {obj}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
