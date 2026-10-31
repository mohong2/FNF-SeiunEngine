#!/usr/bin/env python3
"""tools/crash.py - crash reports, symbols and symbol generation, in one file.

Subcommands
    crash.py                       opens the window (text when stdout is a pipe)
    crash.py status [--json]       is the symbol bundle from this binary?
    crash.py report <file> [...]   freshness check, then resolve the frames
    crash.py bundle <file>         report + manifest as one zip
    crash.py ui                    bilingual window (English / Chinese)
    crash.py symbols [--quiet]     re-publish the bundle for the build on disk
    crash.py prune [--dry-run]     drop superseded bundles (_stale/, *.tmp)
    crash.py triage [...]          the triage engine that 'report' runs
    crash.py resolve <map> <rva>   one offset against one linker map
    crash.py verify-map [...]      prove a .map belongs to an exe
    crash.py symbolize [...]       Android report -> source lines (needs pyelftools)
    crash.py linemap [...]         build the SELM address -> line table from a .so
    crash.py linemap-pdb [...]     the same table out of an MSVC PDB (needs dbghelp)
    crash.py selm-compare A B      do two SELM tables describe the same code?
    crash.py help                  this text

Why one file. Every one of these used to be its own script, and the split was
the bug: a report could be resolved against a map from a different build, and
every frame still "resolved", to a real function that was not the one that
crashed. The pieces share one invariant - an offset only means something
against the exact link that produced the binary - so they live together and
share one freshness check.
"""

from __future__ import annotations

import os
import sys
import re
import struct
import bisect
import glob
import argparse
import ctypes
import hashlib
try:
    from ctypes import wintypes
except ImportError:  # only the PDB subcommand needs it, and only on Windows
    wintypes = None
import json
import locale
import time
from datetime import datetime
import shutil
import subprocess
import zipfile


# ============================================================================
# fnv1a.py - the build fingerprint hash (first/last 64 KiB)
# ============================================================================

fnv_FNV_OFFSET = 0x811C9DC5
fnv_FNV_PRIME = 0x01000193
CHUNK = 65536


def fnv1a(data, h=fnv_FNV_OFFSET):
    for b in data:
        h ^= b
        h = (h * fnv_FNV_PRIME) & 0xFFFFFFFF
    return h


def hash_head_tail(path):
    """First 64 KB, plus the last 64 KB when the file is larger than 128 KB."""
    size = os.path.getsize(path)
    h = fnv_FNV_OFFSET
    with open(path, "rb") as f:
        h = fnv1a(f.read(CHUNK), h)
        if size > CHUNK * 2:
            f.seek(size - CHUNK)
            h = fnv1a(f.read(CHUNK), h)
    return h


def hash_whole(path):
    h = fnv_FNV_OFFSET
    with open(path, "rb") as f:
        while True:
            data = f.read(1 << 20)
            if not data:
                break
            h = fnv1a(data, h)
    return h


def fnv_main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("file", "whole"):
        print(USAGE)
        return 2
    mode, path = sys.argv[1], sys.argv[2]
    if not os.path.isfile(path):
        sys.exit("ERROR: not a file: %s" % path)
    size = os.path.getsize(path)
    if mode == "file":
        print("%dB@%ds#%08x" % (size, int(os.path.getmtime(path)), hash_head_tail(path)))
    else:
        print("%dB#%08x" % (size, hash_whole(path)))
    return 0


# ============================================================================
# mapresolve.py - one offset against one linker map
# ============================================================================

map_BASE_RE = re.compile(r"Preferred load address is\s+([0-9a-fA-F]+)")
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
                m = map_BASE_RE.search(line)
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


def map_main() -> int:
    args = sys.argv[1:]
    crash_dir = None
    if "--crash-dir" in args:
        i = args.index("--crash-dir")
        crash_dir = args[i + 1]
        del args[i : i + 2]
    if not args:
        print(USAGE)
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


# ============================================================================
# verify_map.py - does this .map belong to this exe
# ============================================================================

TIMESTAMP_RE = re.compile(r"^\s*Timestamp is\s+([0-9a-fA-F]{8})")
BASE_RE = re.compile(r"^\s*Preferred load address is\s+([0-9a-fA-F]+)")
SECTION_RE = re.compile(
    r"^\s*([0-9a-fA-F]{4}):([0-9a-fA-F]{8})\s+([0-9a-fA-F]+)H\s+(\S+)\s+(\S+)\s*$"
)


# ---------------------------------------------------------------- readers


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


def verify(pe, mp):
    """Return a list of (name, ok, detail, why) tuples - shared by CLI and GUI."""
    checks = []
    checks.append((
        "build stamp",
        pe["timestamp"] == mp["timestamp"],
        f"map Timestamp=0x{mp['timestamp']:08X}  exe TimeDateStamp=0x{pe['timestamp']:08X}",
        "the map was produced by a different link - do not use it",
    ))
    checks.append((
        "image base",
        pe["image_base"] == mp["base"],
        f"map base=0x{mp['base']:X}  exe ImageBase=0x{pe['image_base']:X}",
        "absolute addresses in the map do not apply to this image",
    ))
    # The map numbers offsets from the start of each PE section, so its segment-1
    # ".text*" block starts at 0 no matter what RVA the PE gave .text.
    text_ok = (mp["text_start"] == 0 and mp["text_len"] > 0
               and abs(mp["text_len"] - pe["text"]["vsize"])
               <= max(pe["section_align"], 0x1000))
    checks.append((
        ".text extent",
        text_ok,
        f"map .text size=0x{mp['text_len']:X}  exe .text rva=0x{pe['text']['vaddr']:X} "
        f"size=0x{pe['text']['vsize']:X}",
        "the code the map describes is not the code in this image",
    ))
    return checks


# ---------------------------------------------------------------- GUI


def vm_run_gui():
    import tkinter as tk
    from tkinter import ttk, filedialog

    # ---- palette ----
    C_OK      = "#1b7f3b"
    C_FAIL    = "#c62828"
    C_MUTED   = "#6b7280"
    C_BG      = "#fbfbfb"
    MONO      = ("Consolas", 10)

    root = tk.Tk()
    root.title("Verify Map — 验证 .map 是否属于这个 exe")
    root.geometry("860x540")
    root.minsize(680, 420)

    style = ttk.Style()
    for theme in ("vista", "clam", "default"):
        try:
            style.theme_use(theme)
            break
        except tk.TclError:
            continue

    outer = ttk.Frame(root, padding=14)
    outer.pack(fill="both", expand=True)

    exe_var = tk.StringVar()
    map_var = tk.StringVar()

    # ---- file pickers ----
    files = ttk.LabelFrame(outer, text="文件", padding=10)
    files.pack(fill="x")
    files.columnconfigure(1, weight=1)

    def pick_exe():
        path = filedialog.askopenfilename(
            title="选择要验证的 exe",
            filetypes=[("PE executable", "*.exe"), ("All files", "*.*")])
        if not path:
            return
        exe_var.set(path)
        # 顺手猜一个同目录同名的 .map，省一步操作
        if not map_var.get().strip():
            guess = os.path.splitext(path)[0] + ".map"
            if os.path.exists(guess):
                map_var.set(guess)

    def pick_map():
        path = filedialog.askopenfilename(
            title="选择对应的 .map",
            filetypes=[("Map file", "*.map"), ("All files", "*.*")])
        if path:
            map_var.set(path)

    ttk.Label(files, text="exe:").grid(row=0, column=0, sticky="w", padx=(0, 8), pady=4)
    ttk.Entry(files, textvariable=exe_var).grid(row=0, column=1, sticky="ew", pady=4)
    ttk.Button(files, text="浏览…", command=pick_exe).grid(
        row=0, column=2, padx=(8, 0), pady=4)

    ttk.Label(files, text="map:").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=4)
    ttk.Entry(files, textvariable=map_var).grid(row=1, column=1, sticky="ew", pady=4)
    ttk.Button(files, text="浏览…", command=pick_map).grid(
        row=1, column=2, padx=(8, 0), pady=4)

    # ---- results ----
    result_frame = ttk.LabelFrame(outer, text="结果", padding=8)
    result_frame.pack(fill="both", expand=True, pady=(12, 0))

    text = tk.Text(result_frame, wrap="word", borderwidth=0, height=12,
                   font=MONO, padx=10, pady=8, background=C_BG,
                   state="disabled", cursor="arrow")
    text.pack(fill="both", expand=True)
    text.tag_configure("ok",       foreground=C_OK)
    text.tag_configure("fail",     foreground=C_FAIL)
    text.tag_configure("muted",    foreground=C_MUTED)
    text.tag_configure("head",     font=("Consolas", 10, "bold"))
    text.tag_configure("why",      foreground=C_FAIL, font=("Consolas", 9, "italic"))
    text.tag_configure("match",    foreground=C_OK,   font=("Consolas", 10, "bold"))
    text.tag_configure("mismatch", foreground=C_FAIL, font=("Consolas", 10, "bold"))

    # ---- bottom bar ----
    bar = ttk.Frame(outer)
    bar.pack(fill="x", pady=(12, 0))
    status = ttk.Label(bar, text="选择 exe 和 map，然后点「验证」。")
    status.pack(side="left")
    verify_btn = ttk.Button(bar, text="验证", command=lambda: do_verify())
    verify_btn.pack(side="right")

    def set_text(chunks):
        text.configure(state="normal")
        text.delete("1.0", "end")
        for s, tag in chunks:
            text.insert("end", s, tag or ())
        text.configure(state="disabled")

    def do_verify():
        exe = exe_var.get().strip()
        mp = map_var.get().strip()
        if not exe or not mp:
            status.configure(text="请先选择 exe 和 map 两个文件。")
            set_text([("请先选择 exe 和 map 两个文件。\n", "muted")])
            return

        try:
            pe = read_pe(exe)
        except OSError as exc:
            status.configure(text="读取 exe 失败")
            set_text([(f"error: cannot read exe {exe}: {exc}\n", "fail")])
            return
        try:
            m = read_map_head(mp)
        except OSError as exc:
            status.configure(text="读取 map 失败")
            set_text([(f"error: cannot read map {mp}: {exc}\n", "fail")])
            return

        if pe is None:
            status.configure(text="不是 PE 文件")
            set_text([(f"error: {exe} is not a PE image\n", "fail")])
            return
        if m["timestamp"] is None or m["base"] is None:
            status.configure(text="map 头部无效")
            set_text([(f"error: {mp} has no MSVC map header "
                       f"(Timestamp/Preferred load address)\n", "fail")])
            return

        checks = verify(pe, m)
        failed = [c for c in checks if not c[1]]

        chunks = [
            (f"exe: {pe['path']}  ({pe['size']} bytes)\n", "head"),
            (f"map: {m['path']}  ({m['size']} bytes)\n\n", "head"),
        ]
        for name, ok, detail, why in checks:
            chunks.append(("  [OK  ] " if ok else "  [FAIL] ", "ok" if ok else "fail"))
            chunks.append((f"{name:<12} ", "head"))
            chunks.append((f"{detail}\n", None))
            if not ok:
                chunks.append((f"           -> {why}\n", "why"))
        chunks.append(("\n", None))
        if failed:
            chunks.append(("MISMATCH: this map does NOT describe this exe.\n", "mismatch"))
            status.configure(text="不匹配：不要用这个 map。")
        else:
            chunks.append(("MATCH: this map describes this exe.\n", "match"))
            status.configure(text="匹配：这个 map 对应该 exe。")
        set_text(chunks)

    def show_help():
        set_text([
            ("选择 exe 和 .map 后点击「验证」。\n\n", "muted"),
            ("脚本会从两个文件本身校验：\n", "muted"),
            ("  1. build stamp  (map Timestamp == exe TimeDateStamp)\n", "muted"),
            ("  2. image base   (map Preferred load address == exe ImageBase)\n", "muted"),
            ("  3. .text extent (map 的 .text* 总和 ≈ exe 的 .text 大小)\n", "muted"),
        ])

    root.bind("<Return>", lambda e: do_verify())
    root.bind("<Escape>", lambda e: root.destroy())
    show_help()
    root.mainloop()


# ---------------------------------------------------------------- CLI


def vm_main() -> int:
    quiet = "--quiet" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--quiet"]

    # 没有给出两个路径：打开 GUI。若环境没有 tkinter / 无显示器，退回打印用法。
    if len(args) < 2:
        # No paths: show the window only when a human is watching. A script that
        # forgot its arguments must not hang on a Tk event loop.
        if not sys.stdout.isatty():
            print("usage: python tools/crash.py verify-map <exe> <map> [--quiet]")
            return 2
        try:
            import tkinter  # noqa: F401
        except ImportError:
            print(USAGE)
            return 2
        try:
            vm_run_gui()
        except Exception as exc:  # TclError（无显示器）等
            print(f"error: cannot start GUI: {exc}", file=sys.stderr)
            print(USAGE)
            return 2
        return 0

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
        print(f"error: {args[1]} has no MSVC map header "
              f"(Timestamp/Preferred load address)")
        return 2

    checks = verify(pe, mp)
    failed = [c for c in checks if not c[1]]

    if not quiet:
        print(f"exe: {pe['path']}  ({pe['size']} bytes)")
        print(f"map: {mp['path']}  ({mp['size']} bytes)")
        print()
        for name, ok, detail, why in checks:
            print(f"  [{'OK  ' if ok else 'FAIL'}] {name:<12} {detail}")
            if not ok:
                print(f"           -> {why}")
        print()
        print("MATCH: this map describes this exe." if not failed
              else "MISMATCH: this map does NOT describe this exe.")
    return 1 if failed else 0


# ============================================================================
# gen_linemap.py - ELF (DWARF) address -> file:line table
# ============================================================================

try:
    from elftools.elf.elffile import ELFFile
except ImportError:  # optional: only the ELF subcommands need it
    ELFFile = None

selm_MAGIC = b"SELM"
selm_VERSION = 1

# A table that locates almost nothing is worse than no table: it converges,
# compares equal to itself and ships, so every later crash report reads as
# "(no line info)". Refuse it at generation time instead.
MIN_COVERAGE = 0.90


def _as_text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


def _dir_list(lineprog):
    """Directory table as a list of text paths (index 0 == compilation dir placeholder)."""
    header = lineprog.header
    dirs = []
    entries = None
    try:
        entries = header["directory_entry"]  # DWARF 5
    except (KeyError, TypeError):
        pass
    if entries:
        for d in entries:
            dirs.append(_as_text(d.get("DW_LNCT_path")))
        return dirs
    try:
        entries = header["include_directory"]  # DWARF 2-4
    except (KeyError, TypeError):
        pass
    if entries:
        return [_as_text(d) for d in entries]
    return []


def _file_table(lineprog, dirs, comp_dir):
    """File table as a list of resolved absolute-ish paths (index 0 reserved)."""
    header = lineprog.header
    files = [comp_dir]  # DWARF file index 0 means "compilation dir" (v5); index is 1-based otherwise
    entries = None
    try:
        entries = header["file_entry"]  # both DWARF <5 and 5
    except (KeyError, TypeError):
        pass
    if not entries:
        return files

    v5 = False
    if entries and isinstance(entries[0], dict):
        v5 = True

    for f in entries:
        if v5:
            name = _as_text(f.get("DW_LNCT_path"))
            dir_index = f.get("DW_LNCT_directory_index", 0)
        else:
            name = _as_text(f.name)
            dir_index = f.dir_index
        if dir_index and 0 <= dir_index < len(dirs):
            d = dirs[dir_index]
            if d:
                # join without worrying about separators: DWARF paths use '/' on
                # all hosts, Windows toolchains emit forward slashes too
                name = d.rstrip("/") + "/" + name
            elif comp_dir:
                name = comp_dir.rstrip("/") + "/" + name
        files.append(name)
    return files


def selm_collect_rows(lib_path):
    rows = {}  # addr -> (file_str_index, line); file_str_index resolved later
    files_index = {}
    file_strings = []

    def intern(path):
        path = path.replace("\\", "/")
        idx = files_index.get(path)
        if idx is None:
            idx = len(file_strings)
            files_index[path] = idx
            file_strings.append(path)
        return idx

    with open(lib_path, "rb") as f:
        elf = ELFFile(f)
        if not elf.has_dwarf_info():
            sys.exit("ERROR: %s has no DWARF info (stripped build?). Use the unstripped .so from export/<target>/android/obj/" % lib_path)
        dwarf = elf.get_dwarf_info()

        cu_count = 0
        for cu in dwarf.iter_CUs():
            lineprog = dwarf.line_program_for_CU(cu)
            if lineprog is None:
                continue
            cu_count += 1

            comp_dir = ""
            try:
                comp_dir = _as_text(cu.get_top_DIE().attributes["DW_AT_comp_dir"].value)
            except (KeyError, TypeError, AttributeError):
                pass

            dirs = _dir_list(lineprog)
            file_table = _file_table(lineprog, dirs, comp_dir)

            for entry in lineprog.get_entries():
                state = entry.state
                if state is None:
                    continue
                if state.end_sequence:
                    rows[state.address] = (intern(""), 0)  # terminator
                    continue
                line = state.line or 0
                file_idx = state.file or 0
                path = file_table[file_idx] if 0 <= file_idx < len(file_table) else ""
                if not path:
                    rows[state.address] = (intern(""), 0)
                else:
                    rows[state.address] = (intern(path), line)

        if not rows:
            sys.exit("ERROR: no line-table rows found in %s" % lib_path)
        print("CUs parsed: %d, raw rows: %d, unique addresses: %d" % (cu_count, len(rows), len(rows)))

    return rows, file_strings


def selm_build_map(rows, file_strings):
    # sort + collapse constant runs
    addrs = sorted(rows.keys())
    entries = []
    prev = None
    for addr in addrs:
        row = rows[addr]
        if prev is not None and row == prev:
            continue
        entries.append((addr, row))
        prev = row

    str_blob = bytearray()
    str_index = {}
    for path in file_strings:
        str_index[path] = len(str_blob)
        str_blob.extend(path.encode("utf-8", "replace"))
        str_blob.extend(b"\x00")

    str_off = 16 + 12 * len(entries)
    out = bytearray()
    out.extend(selm_MAGIC)
    out.extend(struct.pack("<III", selm_VERSION, len(entries), str_off))
    for addr, (fidx, line) in entries:
        out.extend(struct.pack("<III", addr, line, str_index[file_strings[fidx]]))
    out.extend(str_blob)
    return out, entries


def selm_selftest(out_bytes, entries, lib_path):
    """Round-trip a few entries through the same lookup the C++ handler does."""
    import random
    if not entries:
        return
    random.seed(1234)
    base = 16
    ok = 0
    for _ in range(min(5, len(entries))):
        i = random.randrange(len(entries))
        addr, (fidx, line) = entries[i]
        # find last entry with rel_addr <= addr
        lo, hi = 0, len(entries)
        while lo + 1 < hi:
            mid = lo + (hi - lo) // 2
            a = struct.unpack_from("<I", out_bytes, base + mid * 12)[0]
            if a <= addr:
                lo = mid
            else:
                hi = mid
        found_line = struct.unpack_from("<I", out_bytes, base + lo * 12 + 4)[0]
        str_off = struct.unpack_from("<I", out_bytes, base + lo * 12 + 8)[0]
        str_table = struct.unpack_from("<I", out_bytes, 12)[0]
        end = out_bytes.index(b"\x00", str_table + str_off)
        path = out_bytes[str_table + str_off:end].decode("utf-8", "replace")
        if found_line == line:
            ok += 1
            print("  lookup 0x%08x -> %s:%d" % (addr, path, found_line))
    print("selftest: %d/5 lookups exact" % ok)


def coverage(entries, lib_path):
    """How much of the binary's own code the generated table can locate.

    Every STT_FUNC in the ELF symbol table is looked up exactly the way the
    runtime handler does (last entry <= address). A low ratio means the DWARF
    is missing for most translation units, i.e. the hxcpp object cache was
    populated by builds without -g and is being reused.

    Returns (resolved, total, ratio).
    """
    addrs = [a for a, _ in entries]
    resolved = 0
    total = 0
    with open(lib_path, "rb") as f:
        elf = ELFFile(f)
        symtab = elf.get_section_by_name(".symtab")
        if symtab is None:
            return 0, 0, 1.0
        for sym in symtab.iter_symbols():
            if sym["st_info"]["type"] != "STT_FUNC":
                continue
            addr = sym["st_value"]
            if not addr or not sym["st_size"]:
                continue
            total += 1
            i = bisect.bisect_right(addrs, addr) - 1
            if i >= 0 and entries[i][1][1]:
                resolved += 1
    return resolved, total, (resolved / float(total)) if total else 1.0


def check_objdir(path):
    """Exit 0 when the objects there carry DWARF, 1 when the cache is poisoned.

    hxcpp reuses .obj across builds and its cache key does not include the debug
    flags, so a tree that was ever built without HXCPP_DEBUG_LINK keeps shipping
    objects with no .debug_line no matter how often it is rebuilt. That is the
    real reason a release linemap comes out blind.
    """
    objs = sorted(glob.glob(os.path.join(path, "*.obj")))
    if not objs:
        print("%s: no .obj files" % path)
        return 0
    with_dbg = 0
    for p in objs:
        try:
            with open(p, "rb") as f:
                if ELFFile(f).get_section_by_name(".debug_line") is not None:
                    with_dbg += 1
        except Exception:
            pass
    ratio = with_dbg / float(len(objs))
    print("%s: %d/%d objects carry .debug_line (%.1f%%)"
          % (path, with_dbg, len(objs), ratio * 100.0))
    # A handful of objects (prebuilt extensions, resource blobs) legitimately carry
    # no line table; demanding 100% would purge the cache before every single build.
    return 0 if ratio >= 0.90 else 1


def has_debug(path):
    """True when the ELF carries a DWARF line table (i.e. can feed the linemap)."""
    try:
        with open(path, "rb") as f:
            return ELFFile(f).get_section_by_name(".debug_line") is not None
    except Exception:
        return False


# (abi, unstripped obj dirs used by past/current hxcpp layouts, deployment .so name)
ANDROID_ABIS = (
    ("arm64-v8a", ("androidarm64-64", "android-64"), "libApplicationMain-64.so"),
    ("armeabi-v7a", ("android-v7", "androidarmv7-64"), "libApplicationMain-v7.so"),
)


def find_unstripped(build, abi, objdirs, deployname):
    """Newest DWARF-bearing unstripped lib for one ABI, or None.

    A fixed priority list is how a stale copy wins: the symbol bundle keeps the
    previous build's byproduct while the fresh one sits in obj/obj/<target>/,
    and the resulting table locates nothing while still looking valid.
    """
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cands = [
        os.path.join(root, "export", "symbols", "android-" + build,
                     "libApplicationMain-" + abi + ".so"),
        os.path.join(root, "export", "symbols", "android-" + build, "libApplicationMain.so"),
    ]
    for d in objdirs:
        cands.append(os.path.join(root, "export", build, "android", "obj", "obj", d,
                                  "libApplicationMain.so"))
    cands.append(os.path.join(root, "export", build, "android", "obj", deployname))

    # The binary that will actually run. A DWARF copy older than it cannot describe
    # it: addresses move when the linemap is embedded, so such a table prints WRONG
    # file:line - worse than printing none. Refuse it instead of guessing.
    deploy = os.path.join(root, "export", build, "android", "obj", deployname)
    deploy_mtime = os.path.getmtime(deploy) if os.path.isfile(deploy) else 0

    best = None
    for p in cands:
        if not os.path.isfile(p) or not has_debug(p):
            continue
        if deploy_mtime and os.path.getmtime(p) + 5 < deploy_mtime:
            print("[gen_linemap] ignoring stale DWARF copy %s (older than %s)"
                  % (os.path.relpath(p, root), deployname))
            continue
        if best is None or os.path.getmtime(p) > os.path.getmtime(best):
            best = p
    return best


def run_android(build, min_coverage, only_abi=None):
    """Regenerate every assets/linemap/<abi>.bin from the newest DWARF libs.

    only_abi filters to one ABI: a -arm64 build should not spend minutes parsing
    the armeabi-v7a DWARF for a table that build will not even embed.
    """
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    failed = False
    found_any = False
    for abi, objdirs, deployname in ANDROID_ABIS:
        if only_abi and abi != only_abi:
            continue
        lib = find_unstripped(build, abi, objdirs, deployname)
        if lib is None:
            print("[gen_linemap] %s: no DWARF copy of the binary just linked." % abi)
            print("[gen_linemap]   The build must keep one - Project.xml needs")
            print("[gen_linemap]   <haxedef name=\"HXCPP_DEBUG_LINK_AND_STRIP\" if=\"android\"/>.")
            print("[gen_linemap]   A bare lime build strips the .so and keeps nothing, and a")
            print("[gen_linemap]   table from an OLDER link prints wrong file:line. Nothing written.")
            continue
        found_any = True
        print("[gen_linemap] %s\n  from %s (%d B, %s)"
              % (abi, os.path.relpath(lib, root), os.path.getsize(lib),
                 __import__("time").strftime("%Y-%m-%d %H:%M:%S", __import__("time").localtime(os.path.getmtime(lib)))))
        out = os.path.join(root, "assets", "linemap", abi + ".bin")
        try:
            rows, file_strings = selm_collect_rows(lib)
            out_bytes, entries = selm_build_map(rows, file_strings)
            resolved, total, ratio = coverage(entries, lib)
            print("[gen_linemap]   coverage: %d/%d function entries locatable (%.1f%%)"
                  % (resolved, total, ratio * 100.0))
            if total and ratio < min_coverage:
                failed = True
                print("[gen_linemap]   REFUSED: below the %.0f%% gate - the table would be blind"
                      % (min_coverage * 100.0))
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(out_bytes)
            print("[gen_linemap]   wrote %s (%d entries, %.1f MB)"
                  % (os.path.relpath(out, root), len(entries), len(out_bytes) / 1048576.0))
        except SystemExit as e:
            failed = True
            print("[gen_linemap]   FAILED: %s" % e)
    if not found_any:
        return 1
    return 1 if failed else 0


def selm_main():
    argv = sys.argv[1:]

    if argv and argv[0] == "--android":
        build = argv[1] if len(argv) > 1 else "release"
        min_cov = MIN_COVERAGE
        if "--min-coverage" in argv:
            min_cov = float(argv[argv.index("--min-coverage") + 1])
        only_abi = None
        if "--abi" in argv:
            only_abi = argv[argv.index("--abi") + 1]
        return run_android(build, min_cov, only_abi)

    if argv and argv[0] == "--find-so":
        abi = argv[2] if len(argv) > 2 else "arm64-v8a"
        build = argv[1] if len(argv) > 1 else "release"
        for a, objdirs, deployname in ANDROID_ABIS:
            if a == abi:
                lib = find_unstripped(build, a, objdirs, deployname)
                if lib is None:
                    return 1
                print(lib)
                return 0
        return 1

    if argv and argv[0] == "--check-objdir":
        if len(argv) != 2:
            print(USAGE)
            return 2
        return check_objdir(argv[1])

    min_coverage = MIN_COVERAGE
    positional = []
    i = 0
    while i < len(argv):
        if argv[i] == "--min-coverage":
            i += 1
            if i >= len(argv):
                sys.exit("ERROR: --min-coverage needs a value")
            min_coverage = float(argv[i])
        else:
            positional.append(argv[i])
        i += 1

    if len(positional) != 2:
        print(USAGE)
        sys.exit(2)
    lib_path, out_path = positional
    if not os.path.exists(lib_path):
        sys.exit("ERROR: input not found: %s" % lib_path)

    rows, file_strings = selm_collect_rows(lib_path)
    out_bytes, entries = selm_build_map(rows, file_strings)

    resolved, total, ratio = coverage(entries, lib_path)
    print("coverage: %d/%d function entries locatable (%.1f%%)"
          % (resolved, total, ratio * 100.0))
    if total and ratio < min_coverage:
        sys.exit(
            "ERROR: only %.1f%% of the functions in %s are locatable (need %.0f%%).\n"
            "       Two causes, in order of likelihood:\n"
            "       1. this is a STALE unstripped copy - check the path and mtime printed\n"
            "          above; the fresh one is export/<mode>/android/obj/obj/<target>/\n"
            "          libApplicationMain.so. gen_linemap.bat now picks the newest.\n"
            "       2. the hxcpp object cache was built without -g and is being reused\n"
            "          (hxcpp's cache key ignores the debug flags). Delete\n"
            "          export/<mode>/android/obj/obj/<target> and rebuild, or run\n"
            "          tools/build_android_symbols.ps1 - it purges the poisoned cache.\n"
            "       Pass --min-coverage 0 only to force a blind table."
            % (ratio * 100.0, lib_path, min_coverage * 100.0))

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(out_bytes)

    print("entries kept (after run-collapse): %d" % len(entries))
    print("output: %s (%.1f MB)" % (out_path, len(out_bytes) / 1048576.0))
    selm_selftest(out_bytes, entries, lib_path)


# ============================================================================
# gen_linemap_msvc.py - the same table out of an MSVC PDB
# ============================================================================

pdb_MAGIC = b"SELM"
pdb_VERSION = 1
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


def pdb_collect_rows(exe_path, symbols_dir):
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


def pdb_build_map(rows, root):
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
    out.extend(pdb_MAGIC)
    out.extend(struct.pack("<III", pdb_VERSION, len(out_entries), str_off))
    for addr, line, idx in out_entries:
        out.extend(struct.pack("<III", addr, line, idx))
    out.extend(blob)
    return out, out_entries


def pdb_selftest(out_bytes, entries):
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


def pdb_main():
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

    base, rows = pdb_collect_rows(exe_path, symbols_dir)
    print("module base 0x%X, %d raw line records" % (base, len(rows)))
    out_bytes, entries = pdb_build_map(rows, args.root)
    print("entries kept (after run-collapse): %d" % len(entries))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(out_bytes)
    print("output: %s (%.1f MB)" % (args.out, len(out_bytes) / 1048576.0))
    pdb_selftest(out_bytes, entries)


# ============================================================================
# symbolize_android.py - resolve an Android report offline
# ============================================================================

sa_TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
sa_REPO_ROOT = os.path.dirname(sa_TOOL_DIR)
sys.path.insert(0, sa_TOOL_DIR)


PC_LINE = re.compile(r'^\s*(?:#\d+\s+)?pc\s+([0-9a-fA-F]{4,16})\s+(\S+)(.*)$')
ANNOTATION = re.compile(r'\[([^\[\]]+?):(\d+)\]\s*$')
BUILD_LINE = re.compile(r'^Build:\s*(.*)$', re.M)
SO_FIELD = re.compile(r'\bso=(\S+)')
SIZE_HASH = re.compile(r'size=(\d+)B@(\d+)s#([0-9a-fA-F]{1,8})')
LINEMAP_FIELD = re.compile(r'linemap=([A-Za-z0-9_\-]+):(\d+)B#([0-9a-fA-F]{1,8})')
ABI_FIELD = re.compile(r'\babi=([A-Za-z0-9_\-]+)')
SELM_MAGIC = b'SELM'


def sa_read_report(path):
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
    if not quiet:
        print('[symbolize] building the line table for %s (one-off, cached)' % os.path.basename(lib))
    rows, strings = selm_collect_rows(lib)
    out, entries = selm_build_map(rows, strings)
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
    export = os.path.join(sa_REPO_ROOT, 'export')
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
            if want_hash is None or hash_head_tail(path) == want_hash:
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


def sa_main():
    ap = argparse.ArgumentParser(description='Resolve an Android crash report offline.')
    ap.add_argument('report', help='the native_crash_*.txt pulled off the device')
    ap.add_argument('--lib', help='unstripped libApplicationMain*.so for that build')
    ap.add_argument('--bin', help='SELM table to use directly (instead of --lib)')
    ap.add_argument('--no-cache', action='store_true', help='do not reuse/write <lib>.selm')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    if not os.path.isfile(args.report):
        sys.exit('ERROR: report not found: %s' % args.report)

    info, frames, _text = sa_read_report(args.report)
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
            print('[symbolize] shipped  %s' % os.path.relpath(shipped, sa_REPO_ROOT))
        if verified:
            print('[symbolize] the report belongs to this build (shipped .so size + hash match)')
        elif shipped:
            print('[symbolize] WARNING: could not match the report so= identity to a local build;'
                  ' the frames below are hints, not proof')
        else:
            print('[symbolize] WARNING: no shipped libApplicationMain*.so under export/ to match against')

    if args.bin:
        selm = load_selm(args.bin)
        print('[symbolize] table    %s' % os.path.relpath(args.bin, sa_REPO_ROOT))
    else:
        if not lib:
            print('[symbolize] ERROR: no unstripped .so found. Build through the Project.xml hook'
                  ' (HXCPP_DEBUG_LINK_AND_STRIP is on for android release), or pass --lib / --bin.')
            return 2
        if not os.path.isfile(lib):
            sys.exit('ERROR: --lib not found: %s' % lib)
        print('[symbolize] symbols  %s (%d B)' % (os.path.relpath(lib, sa_REPO_ROOT), os.path.getsize(lib)))
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
        local = os.path.join(sa_REPO_ROOT, 'assets', 'linemap', '%s.bin' % abi)
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


# ============================================================================
# linemap_compare.py - do two SELM tables describe the same code
# ============================================================================

TOLERANCE = 0.001  # fraction of entries


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"SELM":
        sys.exit("ERROR: %s is not a SELM table" % path)
    count = struct.unpack_from("<I", data, 8)[0]
    str_off = struct.unpack_from("<I", data, 12)[0]
    entries = [struct.unpack_from("<III", data, 16 + i * 12) for i in range(count)]
    return entries


def lc_main():
    if len(sys.argv) != 3:
        print(USAGE)
        return 2
    a = load(sys.argv[1])
    b = load(sys.argv[2])
    if len(a) != len(b):
        print("entries A=%d B=%d diffs=all verdict=mismatch" % (len(a), len(b)))
        return 1
    diffs = 0
    max_shift = 0
    for ea, eb in zip(a, b):
        if ea != eb:
            diffs += 1
            max_shift = max(max_shift, abs(ea[0] - eb[0]))
    ratio = diffs / float(len(a)) if a else 0.0
    if diffs == 0:
        verdict = "exact"
    elif ratio <= TOLERANCE:
        verdict = "benign"
    else:
        verdict = "mismatch"
    print("entries=%d diffs=%d (%.4f%%) max_shift=%dB verdict=%s"
          % (len(a), diffs, ratio * 100.0, max_shift, verdict))
    return 0 if verdict != "mismatch" else 1


# ============================================================================
# crash_triage.py - the triage engine (report -> frames)
# ============================================================================

TRANSLATIONS = {
    'en': {
        'err_not_map': 'not a linker .map (no preferred load address): {v}',
        'err_map_not_found': 'map not found: {v}',
        'err_exe_not_found': 'exe not found: {v}',
        'err_report_not_found': 'report not found: {v}',
        'err_no_reports': 'no crash reports in {v}',
        'err_nothing_picked': 'nothing picked',
        'ok': 'OK', 'fail': 'FAIL', 'skip': 'SKIP', 'stale': 'STALE', 'match': 'match', 'other': 'other',
        'ready': 'ready', 'done': 'done', 'summary_done': 'summary done', 'keep_map_done': 'keep-map done', 'archive_done': 'archive done',
        
        # TUI
        'tui_title': 'SeiunEngine crash triage',
        'tui_crash_dir': '  crash dir : {v}',
        'tui_reports': '  reports   : {v}',
        'tui_current': '  current   : {v}   ({m})',
        'tui_no_current': '  current   : (SeiunEngine.exe not found)',
        'tui_map_chosen': '  map       : {v}   (chosen by you)',
        'tui_map_auto': '  map       : auto (snapshot for the report build, else the current one)',
        'menu_newest': '  1  triage the newest report',
        'menu_listed': '  2  triage a listed report (by number)',
        'menu_dialog': '  3  choose a crash report with a file dialog',
        'menu_all': '  4  triage every report',
        'menu_summary': '  5  summary table',
        'menu_keep_map': '  6  snapshot the current .map now (keep-map)',
        'menu_list_maps': '  7  list .map snapshots',
        'menu_archive': '  8  archive old reports (keep the newest 20)',
        'menu_choose_map': '  9  choose a .map file to use from now on',
        'menu_help_quit': '  h  help        q  quit',
        'tui_help_1': 'A report is only exact against the .map of the build that produced it.',
        'tui_help_2': 'Snapshot after every build (menu 6); symbols from another build are marked STALE.',
        'tui_out_of_range': '  out of range',
        'tui_no_reports_here': '  no reports here',
        'tui_nothing_picked': '  (nothing picked)',
        'tui_nothing_picked_auto': '  (nothing picked - using auto)',
        'tui_map_for_report': 'Map file for this report:',
        'tui_auto_map': '  [Enter] auto  ->  {v}   [{q}]',
        'tui_auto_map_none': '  [Enter] auto  ->  (nothing found)',
        'tui_pick_map_dialog': '  [p]           ->  pick a .map file with a file dialog',
        'tui_paste_map_path': '  [path]        ->  paste the path of a .map file',
        'tui_use_which_map': 'Use which .map from now on?',
        'tui_auto_map_back': '  [Enter] auto  ->  back to auto',
        'tui_triage_result_ok': 'RESULT: {v} report(s), all matched the map',
        'tui_triage_result_stale': 'RESULT: {a} report(s), {b} from another build (symbols are hints)',

        # GUI
        'gui_title': 'SeiunEngine Crash Triage',
        'gui_inputs': ' Inputs  (you pick both files) ',
        'gui_crash_report': 'Crash report',
        'gui_map_file': 'Map file',
        'gui_browse': 'Browse...',
        'gui_use_map': 'use this .map   (unchecked = auto: snapshot for the report build, else the current one)',
        'gui_reports': ' Reports (newest first; click = select, double-click = triage) ',
        'gui_output': ' Output (CI-style steps + report detail) ',
        'btn_triage_selected': 'Triage selected',
        'btn_triage_all': 'Triage ALL reports',
        'btn_summary': 'Summary',
        'btn_snapshot': 'Snapshot current .map',
        'btn_archive': 'Archive old reports',
        'btn_clear': 'Clear output',
        'btn_quit': 'Quit',
        'gui_cur_build': 'current build: {v}  ({m})',
        'gui_no_cur_build': 'current build: (SeiunEngine.exe not found)',
        'gui_auto_map': 'auto map: {v}   [{q}]',
        'gui_auto_map_none': 'auto map: (none found)',
        'gui_note_exe_missing': 'note: SeiunEngine.exe was not found, so build matching cannot be checked.',
        'gui_pick_report_first': 'Pick a crash report (Browse... or click a row), optionally pick a .map, then press a button.',
        'gui_choose_report_title': 'Choose a crash report',
        'gui_choose_map_title': 'Choose a linker .map',
        'gui_all_files': 'All files',
        'gui_crash_reports': 'Crash reports',
        'gui_map_files': 'Map files',

        # 列名
        'col_date': 'date', 'col_name': 'name', 'col_kind': 'kind', 'col_exception': 'exception', 'col_state': 'state', 'col_build': 'build', 'col_symbol': 'faulting function',

        # Steps
        'step_read_report': 'read report',
        'step_fingerprint': 'report build fingerprint',
        'step_select_map': 'select .map',
        'step_load_map': 'load .map',
        'step_compare': 'compare builds',
        'step_resolve_fault': 'resolve fault offset',
        'step_resolve_bt': 'resolve backtrace',
        'step_write': 'write triage file',
        'step_skip_no_stamp': 'this older report does not record it',
        'step_no_map': 'none found - use -m/--map or snapshot with --keep-map',
        'step_map_cached': 'cached ({v} functions)',
        'step_map_loaded': '{a:.1f} MB, {b} functions, {c:.1f}s',
        'step_build_exact': 'this map is the build that produced the report',
        'step_build_stale': 'report {a} vs current {b}',
        'step_build_no_cur': 'current exe not found',
        'step_fault_detail': '0x{a:X} -> {b}',
        'step_bt_detail': 'no fault offset (abort/terminate path); {a} app frame(s), first: 0x{b:X} -> {c}',
        'step_bt_skip': 'the backtrace has no SeiunEngine.exe frames',
        'step_haxe': 'this report has no fault offset (Haxe-level crash)',
        'step_posix': 'no Windows fault offset/backtrace (POSIX report? use tools/symbolize_android.py)',
        'step_no_map_loaded': 'no map loaded',
        'step_write_ok': '{v}',
        'step_write_skip': 'disabled (--no-write)',
        'step_quality_chosen_exact': 'chosen by you (matches the report build)',
        'step_quality_chosen_hint': 'chosen by you (cannot verify against this report)',
        'step_quality_snapshot': 'snapshot for this build',
        'step_quality_current': 'current build',
        'step_quality_current_nostamp': 'current build (report has no build stamp)',
        'step_quality_current_mismatch': 'current build (MISMATCH - this report is from another build)',

        # Report Block
        'rep_app': '  app          : {v}',
        'rep_engine': '  engine       : {v}',
        'rep_exception': '  exception    : {v}{n}',
        'rep_context': '  context      : {v}',
        'rep_fault_module': '  fault module : {v}',
        'rep_error': '  error        : {v}',
        'rep_build': '  report build : {v}',
        'rep_no_build': '(not recorded in this older report)',
        'rep_cur_exe': '  current exe  : {v}',
        'rep_not_built': '(not built)',
        'rep_match_yes': '  build match  : YES - this map is the build that produced the report',
        'rep_match_no': '  build match  : NO - the map is from another build; symbols below are hints only',
        'rep_map': '  map          : {v}',
        'rep_no_map': '(none found)',
        'rep_fault_offset': '  fault offset : 0x{v:X}',
        'rep_fault_hit': '        -> {v}',
        'rep_call_stack': '  call stack (app module, first {v}):',
        'rep_stack_line': '      #{a:02d} 0x{b:X} -> {c}',
        'rep_no_fault_abort': '  fault offset : (none - abort()/terminate() path, no faulting instruction)',
        'rep_no_fault_haxe': '  fault offset : (this report has no fault offset - Haxe-level crash, nothing to symbolise)',
        'rep_no_fault_posix': '  fault offset : (native report without a Windows fault offset/backtrace - use tools/symbolize_android.py for POSIX dumps)',

        # Hit
        'hit_below': '(below the first symbol in this map)',
        'hit_stale': '(STALE)',

        # Summary
        'sum_header': '%-19s %-7s %-11s %-26s %-6s %s',
        'sum_note': "note: a ~ prefix means the symbol came from another build's map (a hint, not proof).",
        'sum_sigs': '--- signatures (exception + faulting function) ---',
        'sum_sig_line': '  {a:4d}x  {b}',

        # CLI
        'cli_desc': 'SeiunEngine crash triage: pick the crash report and the .map, get the crashing function.',
        'cli_epilog': 'With no switches this opens the window UI (tkinter); --tui or --no-gui uses the terminal UI.\nExit codes: 0 all matched, 1 some report is from another build, 2 nothing to do.',
        'help_crash': 'triage this crash report',
        'help_map': 'use this linker .map (default: auto)',
        'help_all': 'triage every report in the crash dir',
        'help_pick': 'choose the report with a file dialog',
        'help_summary': 'one line per report + signature counts',
        'help_json': 'machine-readable summary output',
        'help_keep_map': "snapshot the current build's .map",
        'help_clean': 'archive old reports',
        'help_keep': 'keep the newest N reports (default 20)',
        'help_prune_maps': 'keep only the newest N map snapshots',
        'help_dry_run': '--clean: do not move or delete anything',
        'help_frames': 'how many app frames to symbolise (default 8)',
        'help_crash_dir': 'override the crash directory',
        'help_exe': 'override the exe used for the build fingerprint',
        'help_tui': 'terminal UI (never opens a window)',
        'help_no_gui': 'same as --tui, kept for scripting',
        'help_no_write': 'do not write <report>.triage.txt',
        'help_no_color': 'plain terminal output',
        'help_lang': 'UI language (en, zh)',
        'loading_map': '  loading map {v}...',
        'snapshotted': 'snapshotted: {v}',
        'already_snapshotted': 'already snapshotted: {v}',
        'archive_moved': 'moved {v} item(s)',
        'archive_would_move': 'would move {v} item(s)',
        'and_more': '  ... and {v} more',
        'no_snapshots': '  no snapshots in {v}',
        'summary_crash_dir': 'crash dir : {v}',
        'summary_current': 'current   : {v}   ({m})',
        'summary_reports': 'reports   : {v}',
        'summary_map': 'map       : {v}   [{q}]',
    },
    'zh': {
        'err_not_map': '不是链接器 .map 文件 (没有首选加载地址): {v}',
        'err_map_not_found': '找不到 map 文件: {v}',
        'err_exe_not_found': '找不到 exe 文件: {v}',
        'err_report_not_found': '找不到报告文件: {v}',
        'err_no_reports': '{v} 中没有崩溃报告',
        'err_nothing_picked': '未选择任何文件',
        'ok': '成功', 'fail': '失败', 'skip': '跳过', 'stale': '过期', 'match': '匹配', 'other': '不匹配',
        'ready': '就绪', 'done': '完成', 'summary_done': '摘要完成', 'keep_map_done': '快照完成', 'archive_done': '归档完成',
        
        # TUI
        'tui_title': 'SeiunEngine 崩溃分析',
        'tui_crash_dir': '  崩溃目录 : {v}',
        'tui_reports': '  报告数量 : {v}',
        'tui_current': '  当前构建 : {v}   ({m})',
        'tui_no_current': '  当前构建 : (未找到 SeiunEngine.exe)',
        'tui_map_chosen': '  map 文件 : {v}   (手动选择)',
        'tui_map_auto': '  map 文件 : 自动 (优先匹配报告构建的快照，否则使用当前构建)',
        'menu_newest': '  1  分析最新的报告',
        'menu_listed': '  2  分析列表中的报告 (按编号)',
        'menu_dialog': '  3  通过文件对话框选择崩溃报告',
        'menu_all': '  4  分析全部报告',
        'menu_summary': '  5  摘要表格',
        'menu_keep_map': '  6  立即保存当前 .map 快照 (keep-map)',
        'menu_list_maps': '  7  列出 .map 快照',
        'menu_archive': '  8  归档旧报告 (保留最新 20 个)',
        'menu_choose_map': '  9  选择从此以后使用的 .map 文件',
        'menu_help_quit': '  h  帮助        q  退出',
        'tui_help_1': '报告只有匹配产生它的构建的 .map 时才准确。',
        'tui_help_2': '每次构建后请保存快照 (菜单 6)；来自其他构建的符号会被标记为过期。',
        'tui_out_of_range': '  超出范围',
        'tui_no_reports_here': '  这里没有报告',
        'tui_nothing_picked': '  (未选择)',
        'tui_nothing_picked_auto': '  (未选择 - 使用自动)',
        'tui_map_for_report': '此报告使用的 Map 文件:',
        'tui_auto_map': '  [Enter] 自动  ->  {v}   [{q}]',
        'tui_auto_map_none': '  [Enter] 自动  ->  (未找到)',
        'tui_pick_map_dialog': '  [p]           ->  通过文件对话框选择 .map',
        'tui_paste_map_path': '  [路径]        ->  直接粘贴 .map 文件路径',
        'tui_use_which_map': '从此以后使用哪个 .map？',
        'tui_auto_map_back': '  [Enter] 自动  ->  恢复自动',
        'tui_triage_result_ok': '结果：{v} 个报告，全部匹配该 map',
        'tui_triage_result_stale': '结果：{a} 个报告，{b} 个来自其他构建 (符号仅为提示)',

        # GUI
        'gui_title': 'SeiunEngine 崩溃分析',
        'gui_inputs': ' 输入 (选择崩溃报告和 map 文件) ',
        'gui_crash_report': '崩溃报告',
        'gui_map_file': 'Map 文件',
        'gui_browse': '浏览...',
        'gui_use_map': '使用此 .map (不勾选 = 自动：优先匹配报告构建的快照，否则使用当前构建)',
        'gui_reports': ' 崩溃报告 (最新的在前；单击=选择，双击=分析) ',
        'gui_output': ' 输出 (CI 风格步骤 + 报告详情) ',
        'btn_triage_selected': '分析选中项',
        'btn_triage_all': '分析全部报告',
        'btn_summary': '摘要',
        'btn_snapshot': '保存当前 .map 快照',
        'btn_archive': '归档旧报告',
        'btn_clear': '清空输出',
        'btn_quit': '退出',
        'gui_cur_build': '当前构建: {v}  ({m})',
        'gui_no_cur_build': '当前构建: (未找到 SeiunEngine.exe)',
        'gui_auto_map': '自动 map: {v}   [{q}]',
        'gui_auto_map_none': '自动 map: (未找到)',
        'gui_note_exe_missing': '注意: 未找到 SeiunEngine.exe，无法检查构建匹配。',
        'gui_pick_report_first': '选择一个崩溃报告 (点击浏览或单击列表)，可选选择一个 .map 文件，然后点击按钮。',
        'gui_choose_report_title': '选择崩溃报告',
        'gui_choose_map_title': '选择链接器 .map',
        'gui_all_files': '所有文件',
        'gui_crash_reports': '崩溃报告',
        'gui_map_files': 'Map 文件',

        # 列名
        'col_date': '日期', 'col_name': '名称', 'col_kind': '类型', 'col_exception': '异常', 'col_state': '状态', 'col_build': '构建', 'col_symbol': '崩溃函数',

        # Steps
        'step_read_report': '读取报告',
        'step_fingerprint': '报告构建指纹',
        'step_select_map': '选择 .map',
        'step_load_map': '加载 .map',
        'step_compare': '对比构建',
        'step_resolve_fault': '解析崩溃偏移',
        'step_resolve_bt': '解析调用栈',
        'step_write': '写入分析文件',
        'step_skip_no_stamp': '此旧版报告未记录该信息',
        'step_no_map': '未找到 - 请使用 -m/--map 或 --keep-map 保存快照',
        'step_map_cached': '已缓存 ({v} 个函数)',
        'step_map_loaded': '{a:.1f} MB, {b} 个函数, {c:.1f}s',
        'step_build_exact': '此 map 就是产生此报告的构建',
        'step_build_stale': '报告构建 {a} vs 当前构建 {b}',
        'step_build_no_cur': '未找到当前 exe',
        'step_fault_detail': '0x{a:X} -> {b}',
        'step_bt_detail': '无崩溃偏移 (abort/terminate 路径)；{a} 个应用栈帧，首个: 0x{b:X} -> {c}',
        'step_bt_skip': '调用栈中没有 SeiunEngine.exe 的帧',
        'step_haxe': '此报告没有崩溃偏移 (Haxe 层崩溃)',
        'step_posix': '没有 Windows 崩溃偏移/调用栈 (POSIX 报告？请使用 tools/symbolize_android.py)',
        'step_no_map_loaded': '未加载 map',
        'step_write_ok': '{v}',
        'step_write_skip': '已禁用 (--no-write)',
        'step_quality_chosen_exact': '手动选择 (与报告构建匹配)',
        'step_quality_chosen_hint': '手动选择 (无法针对此报告验证)',
        'step_quality_snapshot': '此构建的快照',
        'step_quality_current': '当前构建',
        'step_quality_current_nostamp': '当前构建 (报告无构建标记)',
        'step_quality_current_mismatch': '当前构建 (不匹配 - 此报告来自其他构建)',

        # Report Block
        'rep_app': '  应用         : {v}',
        'rep_engine': '  引擎         : {v}',
        'rep_exception': '  异常         : {v}{n}',
        'rep_context': '  上下文       : {v}',
        'rep_fault_module': '  崩溃模块     : {v}',
        'rep_error': '  错误         : {v}',
        'rep_build': '  报告构建     : {v}',
        'rep_no_build': '(旧版报告未记录)',
        'rep_cur_exe': '  当前 exe     : {v}',
        'rep_not_built': '(未构建)',
        'rep_match_yes': '  构建匹配     : 是 - 此 map 就是产生此报告的构建',
        'rep_match_no': '  构建匹配     : 否 - 此 map 来自其他构建；下方的符号仅供参考',
        'rep_map': '  map 文件     : {v}',
        'rep_no_map': '(未找到)',
        'rep_fault_offset': '  崩溃偏移     : 0x{v:X}',
        'rep_fault_hit': '        -> {v}',
        'rep_call_stack': '  调用栈 (应用模块，前 {v} 个):',
        'rep_stack_line': '      #{a:02d} 0x{b:X} -> {c}',
        'rep_no_fault_abort': '  崩溃偏移     : (无 - abort()/terminate() 路径，没有触发崩溃的指令)',
        'rep_no_fault_haxe': '  崩溃偏移     : (此报告没有崩溃偏移 - Haxe 层崩溃，无需解析符号)',
        'rep_no_fault_posix': '  崩溃偏移     : (原生报告缺少 Windows 崩溃偏移/调用栈 - POSIX dump 请使用 tools/symbolize_android.py)',

        # Hit
        'hit_below': '(低于此 map 中的第一个符号)',
        'hit_stale': '(过期)',

        # Summary
        'sum_header': '%-19s %-7s %-11s %-26s %-6s %s',
        'sum_note': "注意：带有 ~ 前缀表示该符号来自其他构建的 map (仅供参考，并非确凿证据)。",
        'sum_sigs': '--- 签名 (异常 + 崩溃函数) ---',
        'sum_sig_line': '  {a:4d}x  {b}',

        # CLI
        'cli_desc': 'SeiunEngine 崩溃分析：选择崩溃报告和 .map 文件，找出崩溃的函数。',
        'cli_epilog': '不带参数运行将打开窗口 UI (tkinter)；使用 --tui 或 --no-gui 运行终端 UI。\n退出码：0 全部匹配，1 部分报告来自其他构建，2 没有要处理的内容。',
        'help_crash': '分析此崩溃报告',
        'help_map': '使用此链接 .map 文件 (默认：自动)',
        'help_all': '分析崩溃目录中的全部报告',
        'help_pick': '通过文件对话框选择报告',
        'help_summary': '每个报告一行摘要 + 签名统计',
        'help_json': '输出机器可读的摘要',
        'help_keep_map': '保存当前构建的 .map 快照',
        'help_clean': '归档旧报告',
        'help_keep': '保留最新的 N 个报告 (默认 20)',
        'help_prune_maps': '仅保留最新的 N 个 map 快照',
        'help_dry_run': '--clean：不移动或删除任何内容',
        'help_frames': '解析多少个应用栈帧 (默认 8)',
        'help_crash_dir': '覆盖崩溃目录',
        'help_exe': '覆盖用于构建指纹的 exe',
        'help_tui': '终端 UI (不打开窗口)',
        'help_no_gui': '与 --tui 相同，用于脚本',
        'help_no_write': '不写入 <report>.triage.txt',
        'help_no_color': '纯文本终端输出',
        'help_lang': '界面语言 (en, zh)',
        'loading_map': '  加载 map {v}...',
        'snapshotted': '快照已保存: {v}',
        'already_snapshotted': '快照已存在: {v}',
        'archive_moved': '已移动 {v} 个项目',
        'archive_would_move': '将移动 {v} 个项目',
        'and_more': '  ... 以及另外 {v} 个',
        'no_snapshots': '  {v} 中没有快照',
        'summary_crash_dir': '崩溃目录 : {v}',
        'summary_current': '当前构建 : {v}   ({m})',
        'summary_reports': '报告数量 : {v}',
        'summary_map': 'map 文件 : {v}   [{q}]',
    }
}

def _pre_scan_lang():
    for i, arg in enumerate(sys.argv):
        if arg == '--lang' and i + 1 < len(sys.argv):
            return sys.argv[i+1]
    return None

CURRENT_LANG = _pre_scan_lang()
if not CURRENT_LANG:
    try:
        lang, _ = locale.getdefaultlocale()
        CURRENT_LANG = 'zh' if lang and lang.lower().startswith('zh') else 'en'
    except Exception:
        CURRENT_LANG = 'en'

def _(key, **kwargs):
    """全局翻译函数"""
    lang_dict = TRANSLATIONS.get(CURRENT_LANG, TRANSLATIONS['en'])
    text = lang_dict.get(key, TRANSLATIONS['en'].get(key, key))
    if kwargs:
        try:
            return text.format(**kwargs)
        except Exception:
            return text
    return text

# ============================================================================
# 核心逻辑
# ============================================================================

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOL_DIR)
DEFAULT_CRASH_DIR = os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'bin', 'crash')

def _first_existing(*paths):
    for p in paths:
        if os.path.isfile(p):
            return p
    return paths[0]

def _newest_existing(*paths):
    existing = [p for p in paths if os.path.isfile(p)]
    if not existing:
        return paths[0]
    return max(existing, key=os.path.getmtime)


DEFAULT_MAP = _newest_existing(
    os.path.join(REPO_ROOT, 'export', 'symbols', 'windows-release', 'ApplicationMain.map'),
    os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'obj', 'ApplicationMain.map'))
DEFAULT_EXE = os.path.join(REPO_ROOT, 'export', 'release', 'windows', 'bin', 'SeiunEngine.exe')

# Every writer the engine ships, in one place:
#   native_crash_*        SEH / fatal signal / LuaJIT panic (native_crash.inc)
#   SeiunEngine_*         Haxe-layer dumps and the C++ fatal funnel
#   lime_*                lime's own ndll (SDL init / window / GL / audio, FatalReport.cpp)
#   MohonghEngine_*       historical name, still found in old reports
REPORT_PREFIXES = ('native_crash', 'SeiunEngine_', 'lime_', 'MohonghEngine_')
MAP_LINE = re.compile(r'^\s+[0-9a-fA-F]{4}:[0-9a-fA-F]{8}\s+(\S+)\s+([0-9a-fA-F]{16})\s+([fi ]+?)\s+(\S+)\s*$')
BASE_LINE = re.compile(r'Preferred load address is\s+([0-9a-fA-F]+)')
NAME_DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2})_(\d{2})'(\d{2})'(\d{2})")
NAME_DATE_COMPACT = re.compile(r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})')

FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 0x01000193

def fnv1a_head_tail(path, chunk=65536):
    h = FNV_OFFSET
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        data = fh.read(chunk)
        for b in data:
            h = ((h ^ b) * FNV_PRIME) & 0xFFFFFFFF
        if size > chunk * 2:
            fh.seek(size - chunk)
            data = fh.read(chunk)
            for b in data:
                h = ((h ^ b) * FNV_PRIME) & 0xFFFFFFFF
    return "%08x" % h

def same_build(report, current):
    if not report or not current:
        return False
    report_hash = report.get("build_hash")
    if report_hash and current.get("hash") and report_hash.lower() == current["hash"].lower():
        return True
    r_stamp, c_stamp = report.get('build_stamp'), current.get('stamp')
    if r_stamp is not None and c_stamp:
        if r_stamp != c_stamp:
            return False
        r_size = report.get('build_size')
        if r_size is None:
            # stamp-only report: the TimeDateStamp already pins the link
            return True
        return r_size == current.get('size')
    return report_fingerprint(report) == current["fingerprint"]

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
    try:
        build_hash = fnv1a_head_tail(path)
    except Exception:
        build_hash = None
    return {
        'path': os.path.abspath(path),
        'size': size,
        'stamp': stamp,
        'hash': build_hash,
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

def _first(lines, pattern, group=1):
    rx = re.compile(pattern)
    for line in lines:
        m = rx.match(line)
        if m:
            return m.group(group).strip()
    return None

def read_report(path):
    path = os.path.abspath(path)
    with open(path, 'r', encoding='utf-8-sig', errors='replace') as fh:
        lines = fh.read().splitlines()

    head = lines[:40]
    exc = _first(head, r'^Exception code:\s*(0x[0-9a-fA-F]+)')
    fault_text = _first(head, r'^Fault offset:\s*(0x[0-9a-fA-F]+)')
    kind_text = _first(head, r'^Kind:\s*(.+)$')
    if exc or fault_text or (kind_text and 'Native crash' in kind_text):
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

    if not build_raw:
        # No "Build:" line: the report was written before Haxe ran, so fall back
        # to the PE header the C reporter always records. A TimeDateStamp is
        # stamped into the image by the linker, so it still identifies the build.
        mstamp = _first(lines, r'^Main module stamp:.*?TimeDateStamp=0x([0-9a-fA-F]+)')
        if mstamp:
            build_stamp = int(mstamp, 16)

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

def name_score(name):
    if name.startswith('$') or name.startswith('__real@') or name.startswith('__xmm@') or name.startswith('__guard_'):
        return 0
    if name.startswith('?'):
        return 3
    if name.startswith('_'):
        return 2
    return 1

def human_name(name):
    if not name.startswith('?'):
        return name
    m = re.match(r'^\?([^@]+)@(.*?)@@', name)
    if not m:
        return name[1:]
    scope = [part for part in m.group(2).split('@') if part]
    scope.reverse()
    return '::'.join(scope + [m.group(1)])

class MapData:
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
        log(_('loading_map', v=os.path.basename(path), m=(size / (1024.0 * 1024.0))))
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
        raise ValueError(_('err_not_map', v=path))
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
        return _('hit_below')
    text = '%s + 0x%X' % (hit['symbol'], hit['displacement'])
    if hit['obj']:
        text += '   [%s]' % hit['obj']
    if stale:
        text += '   ' + _('hit_stale')
    return text

def app_backtrace_frames(report, limit=8):
    out = []
    for frame in report.get('backtrace') or []:
        if 'SeiunEngine.exe' in frame['module']:
            out.append(frame)
            if len(out) >= limit:
                break
    return out

def maps_dir(crash_dir):
    return os.path.join(crash_dir, 'maps')

def select_map(report, forced_map, current, crash_dir, default_map=None):
    default_map = default_map or DEFAULT_MAP
    fp = report_fingerprint(report) if report else None
    if forced_map:
        if not os.path.isfile(forced_map):
            raise FileNotFoundError(_('err_map_not_found', v=forced_map))
        path = os.path.abspath(forced_map)
        exact = bool(fp) and (os.path.splitext(os.path.basename(path))[0] == fp or same_build(report, current))
        quality = _('step_quality_chosen_exact') if exact else _('step_quality_chosen_hint')
        return {'path': path, 'exact': exact, 'quality': quality}
    if fp:
        snap = os.path.join(maps_dir(crash_dir), fp + '.map')
        if os.path.isfile(snap):
            return {'path': snap, 'exact': True, 'quality': _('step_quality_snapshot')}
    if os.path.isfile(default_map):
        exact = same_build(report, current)
        if exact:
            quality = _('step_quality_current')
        elif not fp:
            quality = _('step_quality_current_nostamp')
        else:
            quality = _('step_quality_current_mismatch')
        return {'path': os.path.abspath(default_map), 'exact': exact, 'quality': quality}
    return None

def analyze(report_path, forced_map, current, crash_dir, frames=8, map_cache=None,
            default_map=None, write=True, log=None):
    map_cache = map_cache if map_cache is not None else {}
    steps = []

    def step(title, status, detail=''):
        steps.append({'title': title, 'status': status, 'detail': detail})

    report = read_report(report_path)
    step(_('step_read_report'), 'OK', '%s  [%s]%s' % (report['name'], report['kind'],
         ('  ' + report['date']) if report['date'] else ''))

    fp = report_fingerprint(report)
    if not fp and report.get('build_stamp') is not None:
        fp = '@%ds' % report['build_stamp']
    if fp:
        step(_('step_fingerprint'), 'OK', fp + ('#' + report['build_hash'] if report['build_hash'] else ''))
    else:
        step(_('step_fingerprint'), 'SKIP', _('step_skip_no_stamp'))

    info = select_map(report, forced_map, current, crash_dir, default_map)
    if info:
        step(_('step_select_map'), 'OK', '%s   [%s]' % (info['path'], info['quality']))
    else:
        step(_('step_select_map'), 'FAIL', _('step_no_map'))

    map_data = None
    if info:
        if info['path'] in map_cache:
            map_data = map_cache[info['path']]
            step(_('step_load_map'), 'OK', _('step_map_cached', v=len(map_data.keys)))
        else:
            map_data = read_map(info['path'], log=None)
            map_cache[info['path']] = map_data
            step(_('step_load_map'), 'OK', _('step_map_loaded', a=(map_data.size / (1024.0 * 1024.0)), b=len(map_data.keys), c=map_data.elapsed))

    stale = not (info and info['exact'])
    if info and info['exact']:
        step(_('step_compare'), 'OK', _('step_build_exact'))
    elif current:
        step(_('step_compare'), 'STALE', _('step_build_stale', a=(fp or '(none)'), b=current['fingerprint']))
    else:
        step(_('step_compare'), 'STALE', _('step_build_no_cur'))

    if map_data and report['fault_offset'] is not None:
        hit = resolve_offset(map_data, report['fault_offset'])
        step(_('step_resolve_fault'), 'OK', _('step_fault_detail', a=report['fault_offset'], b=format_hit(hit, stale)))
    elif map_data and report['kind'] == 'native' and report['backtrace']:
        app_frames = app_backtrace_frames(report, frames)
        if app_frames:
            hit = resolve_offset(map_data, app_frames[0]['offset'])
            step(_('step_resolve_bt'), 'OK', _('step_bt_detail', a=len(app_frames), b=app_frames[0]['offset'], c=format_hit(hit, stale)))
        else:
            step(_('step_resolve_bt'), 'SKIP', _('step_bt_skip'))
    elif map_data:
        detail = _('step_haxe')
        if report['kind'] == 'native':
            detail = _('step_posix')
        step(_('step_resolve_fault'), 'SKIP', detail)
    else:
        step(_('step_resolve_fault'), 'SKIP', _('step_no_map_loaded'))

    block = report_block(report, info, map_data, current, frames, stale)

    written = None
    if write:
        try:
            dest = os.path.splitext(report['path'])[0] + '.triage.txt'
            with open(dest, 'w', encoding='utf-8', newline='') as fh:
                fh.write('\n'.join(block) + '\n')
            written = dest
            step(_('step_write'), 'OK', _('step_write_ok', v=dest))
        except OSError as exc:
            step(_('step_write'), 'FAIL', str(exc))
    else:
        step(_('step_write'), 'SKIP', _('step_write_skip'))

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
        out.append(_('rep_app', v=report['app']))
    elif report['engine']:
        out.append(_('rep_engine', v=report['engine']))
        
    if report['kind'] == 'native':
        name = ' (%s)' % report['exception_name'] if report['exception_name'] else ''
        out.append(_('rep_exception', v=report['exception'], n=name))
        if report['context']:
            out.append(_('rep_context', v=report['context']))
        if report['faulting_module']:
            out.append(_('rep_fault_module', v=os.path.basename(report['faulting_module'])))
            
    if report['error']:
        out.append(_('rep_error', v=report['error']))
    for line in report['haxe_stack']:
        out.append('      ' + line)
        
    out.append(_('rep_build', v=(report['build_raw'] or _('rep_no_build'))))
    out.append(_('rep_cur_exe', v=(current['fingerprint'] + '   (' + current['modified'] + ')' if current else _('rep_not_built'))))
    
    if info and info['exact']:
        out.append(_('rep_match_yes'))
    else:
        out.append(_('rep_match_no'))
        
    out.append(_('rep_map', v=('%s   [%s]' % (info['path'], info['quality']) if info else _('rep_no_map'))))

    if map_data and report['fault_offset'] is not None:
        out.append(_('rep_fault_offset', v=report['fault_offset']))
        out.append(_('rep_fault_hit', v=format_hit(resolve_offset(map_data, report['fault_offset']), stale)))
        app_frames = [f for f in report['backtrace'] if 'SeiunEngine.exe' in f['module']][:frames]
        if app_frames:
            out.append(_('rep_call_stack', v=len(app_frames)))
            for f in app_frames:
                hit = resolve_offset(map_data, f['offset'])
                out.append(_('rep_stack_line', a=f['index'], b=f['offset'], c=format_hit(hit, stale)))
    elif map_data:
        if report['kind'] == 'native' and report['backtrace']:
            app_frames = app_backtrace_frames(report, frames)
            out.append(_('rep_no_fault_abort'))
            if app_frames:
                out.append(_('rep_call_stack', v=len(app_frames)))
                for f in app_frames:
                    hit = resolve_offset(map_data, f['offset'])
                    out.append(_('rep_stack_line', a=f['index'], b=f['offset'], c=format_hit(hit, stale)))
        else:
            msg = _('rep_no_fault_haxe')
            if report['kind'] == 'native':
                msg = _('rep_no_fault_posix')
            out.append(msg)
    out.append('')
    return out

def summary_rows(crash_dir, current, map_data):
    rows = []
    for path in reversed(report_files(crash_dir)):
        report = read_report(path)
        fp = report_fingerprint(report)
        match = bool(current and same_build(report, current))
        symbol = ''
        if map_data and report['fault_offset'] is not None:
            hit = resolve_offset(map_data, report['fault_offset'])
            if hit:
                symbol = '%s + 0x%X' % (hit['symbol'], hit['displacement'])
                if not match:
                    symbol = '~ ' + symbol
        elif map_data and report['kind'] == 'native' and report['backtrace']:
            frames = app_backtrace_frames(report, 1)
            hit = resolve_offset(map_data, frames[0]['offset']) if frames else None
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
        raise FileNotFoundError(_('err_map_not_found', v=src))
    current = exe_fingerprint(exe_path)
    if not current:
        raise FileNotFoundError(_('err_exe_not_found', v=exe_path))
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

_CODES = {'reset': '\033[0m', 'dim': '\033[2m', 'bold': '\033[1m', 'red': '\033[31m',
          'green': '\033[32m', 'yellow': '\033[33m', 'cyan': '\033[36m'}
USE_COLOR = False

def enable_ansi():
    global USE_COLOR
    # Judge sys.stdout, not the process: redirected output (a pipe, a file, the
    # StringIO the window captures into) has no colour, and the Windows handle
    # below would otherwise leak ESC sequences into a Tk text widget.
    if not getattr(sys.stdout, 'isatty', lambda: False)():
        USE_COLOR = False
        return False
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

def gui_available():
    try:
        import tkinter  # noqa: F401
        return True
    except Exception:
        return False

# ============================================================================
# GUI
# ============================================================================

def run_gui(crash_dir, exe_path, default_map, forced_map=None, frames=8):
    import queue
    import threading
    import tkinter as tk
    from tkinter import filedialog, ttk

    current = exe_fingerprint(exe_path)
    map_cache = {}
    jobs = queue.Queue()

    root = tk.Tk()
    root.title(_('gui_title'))
    root.geometry('1040x790+60+40')
    root.minsize(880, 640)
    mono = ('Consolas', 10) if os.name == 'nt' else ('Menlo', 11)

    inputs = ttk.LabelFrame(root, text=_('gui_inputs'))
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

    ttk.Label(inputs, text=_('gui_crash_report')).grid(row=0, column=0, sticky='w', padx=6, pady=4)
    ttk.Entry(inputs, textvariable=crash_var).grid(row=0, column=1, sticky='ew', padx=6, pady=4)
    ttk.Button(inputs, text=_('gui_browse'), command=lambda: browse(crash_var, _('gui_choose_report_title'),
        [(_('gui_crash_reports'), '*.txt'), (_('gui_all_files'), '*.*')])).grid(row=0, column=2, padx=6, pady=4)

    ttk.Label(inputs, text=_('gui_map_file')).grid(row=1, column=0, sticky='w', padx=6, pady=4)
    ttk.Entry(inputs, textvariable=map_var).grid(row=1, column=1, sticky='ew', padx=6, pady=4)
    ttk.Button(inputs, text=_('gui_browse'), command=lambda: browse(map_var, _('gui_choose_map_title'),
        [(_('gui_map_files'), '*.map'), (_('gui_all_files'), '*.*')])).grid(row=1, column=2, padx=6, pady=4)

    ttk.Checkbutton(inputs, variable=use_map_var,
        text=_('gui_use_map')).grid(row=2, column=0, columnspan=3, sticky='w', padx=6, pady=(0, 2))
    info = ttk.Label(inputs, text='', foreground='#666666')
    info.grid(row=3, column=0, columnspan=3, sticky='w', padx=6, pady=(0, 6))

    mid = ttk.LabelFrame(root, text=_('gui_reports'))
    mid.pack(fill='both', padx=10, pady=6)
    cols = ('date', 'name', 'kind', 'exception')
    tree = ttk.Treeview(mid, columns=cols, show='headings', height=9)
    for name, width in zip(cols, (150, 430, 80, 130)):
        tree.heading(name, text=_(f'col_{name}'))
        tree.column(name, width=width, anchor='w')
    tree.pack(side='left', fill='both', expand=True, padx=(6, 0), pady=6)
    tree_sb = ttk.Scrollbar(mid, orient='vertical', command=tree.yview)
    tree_sb.pack(side='right', fill='y', pady=6)
    tree.configure(yscrollcommand=tree_sb.set)

    out_frame = ttk.LabelFrame(root, text=_('gui_output'))
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
    status = tk.StringVar(value=_('ready'))
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
                        out.yview(payload)
                except Exception as exc:
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
        tree.yview_moveto(0)
        status.set('%d %s   |   %s' % (len(files), _('tui_reports').split(':')[0].strip(), crash_dir))
        if files and not crash_var.get():
            crash_var.set(files[0])
        update_info()

    def update_info():
        bits = []
        if current:
            bits.append(_('gui_cur_build', v=current['fingerprint'], m=current['modified']))
        else:
            bits.append(_('gui_no_cur_build'))
        report = None
        path = crash_var.get().strip()
        if path and os.path.isfile(path):
            try:
                report = read_report(path)
            except Exception:
                report = None
        auto = select_map(report, None, current, crash_dir, default_map)
        if auto:
            bits.append(_('gui_auto_map', v=auto['path'], q=auto['quality']))
        else:
            bits.append(_('gui_auto_map_none'))
        info.configure(text='        '.join(bits))

    def chosen_map():
        if not use_map_var.get():
            return None
        path = map_var.get().strip()
        if path and not os.path.isfile(path):
            raise FileNotFoundError(_('err_map_not_found', v=path))
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
        start_index = out.index('end-1c')
        def job():
            forced = chosen_map()
            stale_total = 0
            for i, path in enumerate(paths):
                post('line', ruler('%s %d/%d   %s' % (_('tui_title'), i + 1, len(paths), os.path.basename(path))), 'head')
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
                post('line', _('tui_triage_result_ok', v=len(paths)), 'ok')
            else:
                post('line', _('tui_triage_result_stale', a=len(paths), b=stale_total), 'stale')
            post('see', start_index)
            post('status', _('done'))
        run_bg(job)

    def summary():
        def job():
            post('line', ruler(_('menu_summary')), 'head')
            info2 = select_map(None, chosen_map(), current, crash_dir, default_map)
            map_data = None
            if info2:
                if info2['path'] not in map_cache:
                    map_cache[info2['path']] = read_map(info2['path'])
                map_data = map_cache[info2['path']]
            rows = summary_rows(crash_dir, current, map_data)
            post('line', '%-19s %-7s %-11s %-26s %-6s %s' % (_('col_date'), _('col_kind'), _('col_exception'), _('col_state'), _('col_build'), _('col_symbol')), 'plain')
            post('line', '-' * 118, 'dim')
            for row in rows:
                post('line', '%-19s %-7s %-11s %-26s %-6s %s' % (
                    (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
                    _('match') if row['buildMatch'] else _('other'), row['symbol']), 'plain')
            for line in signature_lines(rows):
                post('line', line, 'plain')
            post('line', _('sum_note'), 'dim')
            post('status', _('summary_done'))
        run_bg(job)

    def keep():
        def job():
            post('line', ruler('keep-map'), 'head')
            source = map_var.get().strip() if use_map_var.get() else None
            result = keep_map(source, crash_dir, exe_path)
            if result['skipped']:
                post('line', _('already_snapshotted', v=result['path']), 'ok')
            else:
                post('line', _('snapshotted', v=result['path']), 'ok')
                post('line', 'fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']), 'plain')
            post('status', _('keep_map_done'))
        run_bg(job)

    def archive():
        def job():
            post('line', ruler(_('menu_archive')), 'head')
            moved = clean(crash_dir, keep=20, prune_maps=0, dry_run=False)
            post('line', _('archive_moved', v=len(moved)), 'ok')
            post('refresh', None)
            post('status', _('archive_done'))
        run_bg(job)

    button_widgets = []

    def add_button(text, command):
        widget = ttk.Button(buttons, text=text, command=command)
        widget.pack(side='left', padx=4, pady=4)
        button_widgets.append(widget)
        return widget

    add_button(_('btn_triage_selected'), lambda: triage(selected_paths()))
    add_button(_('btn_triage_all'), lambda: triage(all_reports()))
    add_button(_('btn_summary'), summary)
    add_button(_('btn_snapshot'), keep)
    add_button(_('btn_archive'), archive)
    add_button(_('btn_clear'), lambda: clear_output())
    add_button(_('btn_quit'), root.destroy)

    def clear_output():
        out.configure(state='normal')
        out.delete('1.0', 'end')
        out.configure(state='disabled')

    tree.bind('<<TreeviewSelect>>', on_select)
    tree.bind('<Double-1>', on_double)
    refresh_tree()
    drain()
    write(ruler(_('tui_title')), 'head')
    write(_('gui_pick_report_first'), 'dim')
    if not current:
        write(_('gui_note_exe_missing'), 'stale')
    root.mainloop()
    return 0

def signature_lines(rows):
    counts = {}
    for row in rows:
        symbol = row['symbol'] or ('(no symbol) ' + (row['state'] or ''))
        key = '%s  |  %s' % (row['exception'], symbol)
        counts[key] = counts.get(key, 0) + 1
    out = ['', _('sum_sigs')]
    for key in sorted(counts, key=lambda k: -counts[k]):
        out.append(_('sum_sig_line', a=counts[key], b=key))
    return out

# ============================================================================
# TUI
# ============================================================================

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
        return answer.lstrip('\ufeff').strip()

    def ask_map(report):
        auto = select_map(report, None, current, crash_dir, default_map)
        print()
        print(col(_('tui_map_for_report'), 'cyan'))
        if auto:
            print(_('tui_auto_map', v=auto['path'], q=auto['quality']))
        else:
            print(_('tui_auto_map_none'))
        print(_('tui_pick_map_dialog'))
        print(_('tui_paste_map_path'))
        answer = ask('> ')
        if not answer:
            return None
        if answer.lower() == 'p':
            picked = pick_file(_('gui_choose_map_title'), [(_('gui_map_files'), '*.map'), (_('gui_all_files'), '*.*')],
                               os.path.dirname(default_map))
            if picked:
                return picked
            print(col(_('tui_nothing_picked_auto'), 'yellow'))
            return None
        return answer.strip('"')

    def do_triage(paths, forced_map_choice):
        stale = 0
        for i, path in enumerate(paths):
            print()
            print(col(ruler('%s %d/%d   %s' % (_('tui_title'), i + 1, len(paths), os.path.basename(path))), 'cyan'))
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
            print(col(_('tui_triage_result_ok', v=len(paths)), 'green'))
        else:
            print(col(_('tui_triage_result_stale', a=len(paths), b=stale), 'yellow'))
        return stale

    while True:
        files = list(reversed(report_files(crash_dir)))
        print()
        print(col(ruler(_('tui_title')), 'cyan'))
        print(_('tui_crash_dir', v=crash_dir))
        print(_('tui_reports', v=len(files)))
        if current:
            print(_('tui_current', v=current['fingerprint'], m=current['modified']))
        else:
            print(col(_('tui_no_current'), 'yellow'))
        if forced:
            print(col(_('tui_map_chosen', v=forced), 'yellow'))
        else:
            print(_('tui_map_auto'))
        print()
        print(_('menu_newest'))
        print(_('menu_listed'))
        print(_('menu_dialog'))
        print(_('menu_all'))
        print(_('menu_summary'))
        print(_('menu_keep_map'))
        print(_('menu_list_maps'))
        print(_('menu_archive'))
        print(_('menu_choose_map'))
        print(_('menu_help_quit'))
        choice = ask('> ')
        if choice is None:
            print()
            return 0
        choice = choice.lower()
        if choice == 'q':
            return 0
        elif choice == 'h':
            print(_('tui_help_1'))
            print(_('tui_help_2'))
        elif choice == '1':
            if not files:
                print(col(_('tui_no_reports_here'), 'yellow'))
                continue
            report = read_report(files[0])
            picked = ask_map(report)
            if picked:
                forced = picked
            do_triage([files[0]], forced)
        elif choice == '2':
            if not files:
                print(col(_('tui_no_reports_here'), 'yellow'))
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
                print(col(_('tui_out_of_range'), 'yellow'))
        elif choice == '3':
            picked = pick_file(_('gui_choose_report_title'), [(_('gui_crash_reports'), '*.txt'), (_('gui_all_files'), '*.*')], crash_dir)
            if not picked:
                print(col(_('tui_nothing_picked'), 'yellow'))
                continue
            report = read_report(picked)
            map_pick = ask_map(report)
            if map_pick:
                forced = map_pick
            do_triage([picked], forced)
        elif choice == '4':
            if not files:
                print(col(_('tui_no_reports_here'), 'yellow'))
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
            print('%-19s %-7s %-11s %-26s %-6s %s' % (_('col_date'), _('col_kind'), _('col_exception'), _('col_state'), _('col_build'), _('col_symbol')))
            print('-' * 118)
            for row in rows:
                print('%-19s %-7s %-11s %-26s %-6s %s' % (
                    (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
                    _('match') if row['buildMatch'] else _('other'), row['symbol']))
            for line in signature_lines(rows):
                print(line)
        elif choice == '6':
            try:
                result = keep_map(forced, crash_dir, exe_path)
            except Exception as exc:
                print(col('  ERROR: %s' % exc, 'red'))
                continue
            if result['skipped']:
                print(col(_('already_snapshotted', v=result['path']), 'green'))
            else:
                print(col(_('snapshotted', v=result['path']), 'green'))
                print('  fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']))
        elif choice == '7':
            out_dir = maps_dir(crash_dir)
            if not os.path.isdir(out_dir):
                print(_('no_snapshots', v=out_dir))
                continue
            for name in sorted(os.listdir(out_dir)):
                if name.endswith('.map'):
                    full = os.path.join(out_dir, name)
                    print('  %-30s %12d B' % (name, os.path.getsize(full)))
        elif choice == '8':
            moved = clean(crash_dir, keep=20, prune_maps=0, dry_run=False)
            print(col(_('archive_moved', v=len(moved)), 'green'))
        elif choice == '9':
            print()
            print(col(_('tui_use_which_map'), 'cyan'))
            print(_('tui_auto_map_back'))
            print(_('tui_pick_map_dialog'))
            print(_('tui_paste_map_path'))
            answer = ask('> ')
            if answer is None:
                return 0
            if answer == '':
                forced = None
            elif answer.lower() == 'p':
                picked = pick_file(_('gui_choose_map_title'), [(_('gui_map_files'), '*.map'), (_('gui_all_files'), '*.*')],
                                    os.path.dirname(default_map))
                if picked:
                    forced = picked
                else:
                    print(col(_('tui_nothing_picked'), 'yellow'))
            else:
                forced = answer.strip('"')
        else:
            print(col('  ?', 'yellow'))

# ============================================================================
# CLI
# ============================================================================

def print_summary(crash_dir, current, map_data, rows, map_info=None):
    print(_('summary_crash_dir', v=crash_dir))
    if current:
        print(_('summary_current', v=current['fingerprint'], m=current['modified']))
    print(_('summary_reports', v=len(rows)))
    if map_info:
        print(_('summary_map', v=map_info['path'], q=map_info['quality']))
    print()
    print('%-19s %-7s %-11s %-26s %-6s %s' % (_('col_date'), _('col_kind'), _('col_exception'), _('col_state'), _('col_build'), _('col_symbol')))
    print('-' * 118)
    for row in rows:
        print('%-19s %-7s %-11s %-26s %-6s %s' % (
            (row['date'] or '')[:18], row['kind'], row['exception'], (row['state'] or '')[:25],
            _('match') if row['buildMatch'] else _('other'), row['symbol']))
    for line in signature_lines(rows):
        print(line)
    print()
    print(col(_('sum_note'), 'dim'))

def build_parser():
    parser = argparse.ArgumentParser(
        prog='crash_triage.py',
        description=_('cli_desc'),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=_('cli_epilog'))
    parser.add_argument('--crash', '-c', metavar='REPORT', help=_('help_crash'))
    parser.add_argument('--map', '-m', metavar='MAP', help=_('help_map'))
    parser.add_argument('--all', action='store_true', help=_('help_all'))
    parser.add_argument('--pick', action='store_true', help=_('help_pick'))
    parser.add_argument('--summary', action='store_true', help=_('help_summary'))
    parser.add_argument('--json', action='store_true', help=_('help_json'))
    parser.add_argument('--keep-map', action='store_true', help=_('help_keep_map'))
    parser.add_argument('--clean', action='store_true', help=_('help_clean'))
    parser.add_argument('--keep', type=int, default=20, metavar='N', help=_('help_keep'))
    parser.add_argument('--prune-maps', type=int, default=0, metavar='N', help=_('help_prune_maps'))
    parser.add_argument('--dry-run', action='store_true', help=_('help_dry_run'))
    parser.add_argument('--frames', type=int, default=8, metavar='N', help=_('help_frames'))
    parser.add_argument('--crash-dir', metavar='DIR', help=_('help_crash_dir'))
    parser.add_argument('--exe', metavar='EXE', help=_('help_exe'))
    parser.add_argument('--tui', action='store_true', help=_('help_tui'))
    parser.add_argument('--no-gui', action='store_true', help=_('help_no_gui'))
    parser.add_argument('--no-write', action='store_true', help=_('help_no_write'))
    parser.add_argument('--no-color', action='store_true', help=_('help_no_color'))
    parser.add_argument('--lang', choices=['en', 'zh'], help=_('help_lang'))
    return parser

def tri_main(argv=None):
    global USE_COLOR, CURRENT_LANG
    args = build_parser().parse_args(argv)
    
    if args.lang:
        CURRENT_LANG = args.lang
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
            print(col(_('already_snapshotted', v=result['path']), 'green'))
        else:
            print(col(_('snapshotted', v=result['path']), 'green'))
            print('fingerprint %s   %d B   sha256=%s' % (result['fingerprint'], result['bytes'], result['sha256']))
        return 0

    if args.clean:
        enable_ansi()
        moved = clean(crash_dir, keep=args.keep, prune_maps=args.prune_maps, dry_run=args.dry_run)
        verb = _('archive_would_move', v=len(moved)) if args.dry_run else _('archive_moved', v=len(moved))
        print(col(verb, 'green'))
        for item in moved[:20]:
            print('  ' + item)
        if len(moved) > 20:
            print(_('and_more', v=(len(moved) - 20)))
        return 0

    if args.summary:
        enable_ansi()
        info = select_map(None, args.map, current, crash_dir, DEFAULT_MAP)
        map_data = None
        if info:
            print(col(_('loading_map', v=os.path.basename(info['path'])), 'dim'))
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
                print(col(_('err_report_not_found', v=args.crash), 'red'))
                return 2
            targets = [os.path.abspath(args.crash)]
        elif args.pick:
            picked = pick_file(_('gui_choose_report_title'), [(_('gui_crash_reports'), '*.txt'), (_('gui_all_files'), '*.*')], crash_dir)
            if not picked:
                print(col(_('err_nothing_picked'), 'yellow'))
                return 2
            targets = [picked]
        else:
            targets = list(reversed(report_files(crash_dir)))
        if not targets:
            print(_('err_no_reports', v=crash_dir))
            return 2
        stale = 0
        cache = {}
        for i, path in enumerate(targets):
            print(ruler('%s %d/%d   %s' % (_('tui_title'), i + 1, len(targets), os.path.basename(path))))
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


# ============================================================================
# diag.py - the gate: symbols vs binary, then dispatch
# ============================================================================

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))
EXE_APP = "SeiunEngine"

OK, STALE, MISSING, NOBIN = "OK", "STALE", "MISSING", "NO BINARY"
COLOR = {"OK": "\033[32m", STALE: "\033[33m", MISSING: "\033[31m", NOBIN: "\033[90m"}
RED, DIM, BOLD, RESET = "\033[31m", "\033[90m", "\033[1m", "\033[0m"


def use_color():
    return sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def c(text, code):
    return code + str(text) + RESET if use_color() else str(text)


def find_root(start):
    """Walk up to the directory that owns Project.xml."""
    d = os.path.abspath(start)
    for _ in range(8):
        if os.path.isfile(os.path.join(d, "Project.xml")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


ROOT = find_root(TOOLS) or os.path.dirname(TOOLS)


def rel(p):
    try:
        return os.path.relpath(p, ROOT).replace("\\", "/")
    except ValueError:
        return p


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def pe_stamp(path):
    """(file size, PE TimeDateStamp) for a PE image, or (size, None)."""
    size = os.path.getsize(path)
    try:
        with open(path, "rb") as fh:
            fh.seek(0x3C)
            lfanew = struct.unpack("<I", fh.read(4))[0]
            fh.seek(lfanew)
            if fh.read(4) != b"PE\0\0":
                return size, None
            fh.seek(lfanew + 8)
            return size, struct.unpack("<I", fh.read(4))[0]
    except Exception:
        return size, None


def fingerprint(size, stamp):
    """<size>B@<stamp>s, or the parts the report actually recorded."""
    if stamp is None:
        return "%dB" % size if size is not None else "unknown"
    if size is None:
        return "@%ds" % stamp
    return "%dB@%ds" % (size, stamp)


def stat_line(path):
    st = os.stat(path)
    return "%s  %s  %s" % (datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M"),
                           human(st.st_size), rel(path))


# --------------------------------------------------------------------- layout

def app_name():
    try:
        with open(os.path.join(ROOT, "Project.xml"), "r", encoding="utf-8", errors="replace") as fh:
            m = re.search(r'<app\s+file="([^"]+)"', fh.read())
            if m:
                return m.group(1)
    except Exception:
        pass
    return EXE_APP


def binary_for(plat, mode):
    base = os.path.join(ROOT, "export", mode, plat, "bin")
    app = app_name()
    if not os.path.isdir(base):
        return None
    cand = {
        "windows": [os.path.join(base, app + ".exe")],
        "linux": [os.path.join(base, app)],
        "macos": [os.path.join(base, app + ".app")],
    }.get(plat, [])
    for p in cand:
        if os.path.exists(p):
            return p
    if plat == "android":
        apks = []
        for dirpath, dirnames, filenames in os.walk(base):
            if dirpath[len(base):].count(os.sep) > 6:
                dirnames[:] = []
                continue
            apks += [os.path.join(dirpath, f) for f in filenames if f.endswith(".apk")]
        return max(apks, key=os.path.getmtime) if apks else None
    if plat == "html5":
        p = os.path.join(base, "index.html")
        return p if os.path.exists(p) else None
    return None


def symbol_dir(plat, mode):
    return os.path.join(ROOT, "export", "symbols", "%s-%s" % (plat, mode))


def read_manifest(plat, mode):
    p = os.path.join(symbol_dir(plat, mode), "build.json")
    if not os.path.isfile(p):
        return None, None
    try:
        with open(p, "r", encoding="utf-8") as fh:
            return json.load(fh), p
    except Exception as e:
        return {"_error": str(e)}, p


def builds():
    """Every export/<mode>/<plat> that has a bin/ directory."""
    out = []
    exp = os.path.join(ROOT, "export")
    for mode in sorted(os.listdir(exp)) if os.path.isdir(exp) else []:
        md = os.path.join(exp, mode)
        if not os.path.isdir(md):
            continue
        for plat in sorted(os.listdir(md)):
            b = os.path.join(md, plat, "bin")
            if os.path.isdir(b):
                out.append((plat, mode))
    return out


SYMBOL_PLATFORMS = ("windows", "linux", "macos", "ios", "android", "tvos")


def last_publish():
    """Newest build.json anywhere: anything built before it is history, not a bug."""
    newest = 0.0
    store = os.path.join(ROOT, "export", "symbols")
    if not os.path.isdir(store):
        return 0.0
    for name in os.listdir(store):
        man = os.path.join(store, name, "build.json")
        if os.path.isfile(man):
            newest = max(newest, os.stat(man).st_mtime)
    return newest


def judge(plat, mode):
    """One row: what the binary is, what the symbols claim, and the verdict."""
    binary = binary_for(plat, mode)
    man, man_path = read_manifest(plat, mode)
    row = {"platform": plat, "mode": mode, "binary": binary, "manifest": man_path,
           "verdict": NOBIN, "reason": "", "binary_fp": None, "symbols_fp": None,
           "binary_when": None, "symbols_when": None, "artifacts": []}
    if man_path:
        st = os.stat(man_path)
        row["symbols_when"] = datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
    if binary is None:
        row["reason"] = "no binary in export/%s/%s/bin" % (mode, plat)
        return row
    if plat not in SYMBOL_PLATFORMS:
        row["verdict"] = NOBIN
        row["reason"] = "%s needs no offset symbols" % plat
        return row
    row["binary_when"] = datetime.fromtimestamp(os.stat(binary).st_mtime).strftime("%Y-%m-%d %H:%M")
    if plat == "windows":
        size, stamp = pe_stamp(binary)
        row["binary_fp"] = fingerprint(size, stamp)
    else:
        row["binary_fp"] = "%dB" % os.path.getsize(binary)

    if man is None:
        if os.stat(binary).st_mtime < last_publish():
            row["verdict"] = NOBIN
            row["reason"] = "old build, no symbols kept (rebuild to get them)"
        else:
            row["verdict"] = MISSING
            row["reason"] = "this build has no export/symbols/%s-%s/build.json - run 'diag symbols'" % (plat, mode)
        return row
    if "_error" in man:
        row["verdict"] = MISSING
        row["reason"] = "build.json is unreadable (%s) - run 'diag symbols'" % man["_error"]
        return row

    exe = man.get("exe") or {}
    ssize, sstamp = exe.get("size"), exe.get("peStamp")
    row["symbols_fp"] = fingerprint(ssize, sstamp) if ssize is not None else None
    row["artifacts"] = [a.get("role", "?") for a in man.get("artifacts", [])];
    row["git"] = man.get("git") or {};

    if row["symbols_fp"] != row["binary_fp"]:
        row["verdict"] = STALE
        row["reason"] = "symbols were published for a different binary"
        return row

    obj_map = os.path.join(ROOT, "export", mode, plat, "obj", "ApplicationMain.map")
    if os.path.isfile(obj_map) and man_path:
        if os.stat(obj_map).st_mtime > os.stat(man_path).st_mtime + 1:
            row["verdict"] = STALE
            row["reason"] = "a newer map is sitting in obj/ - the last build did not publish"
            return row

    if not man.get("artifacts"):
        row["verdict"] = MISSING
        row["reason"] = "build.json lists no symbol files"
        return row

    row["verdict"] = OK
    row["reason"] = "symbols belong to this binary"
    return row


# ------------------------------------------------------------------- commands

def cmd_status(args):
    rows = [judge(p, m) for p, m in builds()]
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return 0 if all(r["verdict"] in (OK, NOBIN) for r in rows) else 1
    if not rows:
        print("no export/*/*/bin directories - run a build first")
        return 1
    bad = 0
    for r in rows:
        head = "%-8s %-7s" % (r["platform"], r["mode"])
        line = "%s  %s  %s" % (head, c("%-10s" % r["verdict"], COLOR.get(r["verdict"], "")), r["reason"])
        print(c(line, DIM) if r["verdict"] == NOBIN else line)
        if r["binary"]:
            print("         binary  %s" % stat_line(r["binary"]))
            print("                 build %s" % (r["binary_fp"] or "?"))
        if r["manifest"]:
            print("         symbols %s" % stat_line(r["manifest"]))
            print("                 build %s  (%s)" % (r["symbols_fp"] or "?",
                                                       ", ".join(r["artifacts"]) or "no files"))
        g = r.get("git") or {}
        if g.get("commit") and g["commit"] != "unknown":
            print("                 commit %s%s  %s" % (g["commit"], "+" if g.get("dirty") else "",
                                                        g.get("version", "")));
        if r["verdict"] not in (OK, NOBIN):
            bad += 1
        print()
    total = sum_dir_size(os.path.join(ROOT, "export", "symbols"))
    print("symbol store: %s in export/symbols/" % human(total))
    if bad:
        print(c("-> %d build(s) are not covered by their symbols. Run: tools\\diag symbols" % bad, BOLD))
        return 1
    return 0


def sum_dir_size(path):
    total = 0
    for base, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(base, f))
            except OSError:
                pass
    return total


def cmd_symbols(args):
    """Publish the symbol bundle. This is what the build calls after linking."""
    haxe = shutil.which("haxe")
    if not haxe:
        print("haxe is not on PATH - cannot publish symbols", file=sys.stderr)
        return 1
    cmd = [haxe, "-main", "tools.SymbolsAfterBuild", "--interp"]
    proc = subprocess.run(cmd, cwd=ROOT,
                          stdout=subprocess.PIPE if args.quiet else None,
                          stderr=subprocess.STDOUT if args.quiet else None,
                          text=True)
    if args.quiet and proc.stdout:
        for line in proc.stdout.splitlines():
            if "error" in line.lower() or "warning" in line.lower():
                print(line)
    if proc.returncode != 0:
        print("symbol publisher failed (exit %d)" % proc.returncode, file=sys.stderr)
        return 1
    return cmd_status(argparse.Namespace(json=False))


REPORT_BUILD = re.compile(r'^Build:\s*\S*?=(\d+)B@(\d+)s', re.M)
REPORT_STAMP = re.compile(r'^Main module stamp:.*?TimeDateStamp=0x([0-9a-fA-F]+)', re.M)
REPORT_SIZE = re.compile(r'^Main module:.*$', re.M)


def report_identity(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    m = REPORT_BUILD.search(text)
    if m:
        return int(m.group(1)), int(m.group(2)), "Build:"
    m = REPORT_STAMP.search(text)
    if m:
        return None, int(m.group(1), 16), "Main module stamp:"
    return None, None, None


def cmd_report(args):
    path = args.file
    if os.path.isdir(path):
        cands = [os.path.join(path, f) for f in os.listdir(path)
                 if f.lower().endswith(".txt")
                 and not f.lower().endswith(".triage.txt")
                 and f.startswith(("native_crash", "SeiunEngine", "lime_", "MohonghEngine_"))]
        if not cands:
            print("no crash report in %s" % path, file=sys.stderr)
            return 2
        path = max(cands, key=os.path.getmtime)
        print("newest report: %s" % rel(path))
    if not os.path.isfile(path):
        print("no such report: %s" % path, file=sys.stderr)
        return 2

    size, stamp, src = report_identity(path)
    mode = "release"
    man, _ = read_manifest("windows", mode)
    verdict = None
    if man and "_error" not in man and man.get("exe"):
        exe = man["exe"]
        if stamp is None:
            # A lime-layer report is written below Haxe and never sees the exe's
            # fingerprint, so "no stamp" means unknown, not stale.
            print("%s the report records no build stamp - symbols below are hints only" % c("WARN", BOLD))
        elif exe.get("peStamp") == stamp and (size is None or exe.get("size") == size):
            verdict = OK
            print("%s report build matches the symbol bundle (%s)" % (c("ok", BOLD), fingerprint(size or exe.get("size"), stamp)))
        else:
            verdict = STALE
            print("%s this report is from a DIFFERENT build than export/symbols/windows-release/" % c("STALE SYMBOLS", c(RED, BOLD) if use_color() else BOLD))
            print("     report : %s" % (fingerprint(size, stamp) if stamp is not None else "no build stamp (%s)" % (src or "unreadable")))
            print("     symbols: %s" % fingerprint(exe.get("size"), exe.get("peStamp")))
            print("     offsets below would resolve to the wrong names. Rebuild the reported")
            print("     binary, or get its map+manifest from the machine that built it.")
    elif stamp is None:
        print("%s the report records no build stamp - symbols below are hints only" % c("WARN", BOLD))

    if args.check_only:
        return 0 if verdict in (OK, None) else 1

    extra = list(getattr(args, "extra", []) or [])
    argv = ["--crash", path] + extra
    if not any(t in ("--tui", "--no-gui") for t in extra):
        argv.append("--no-gui")
    sys.stdout.flush()
    return run_triage(argv)


def cmd_bundle(args):
    path = args.file
    if not os.path.isfile(path):
        print("no such report: %s" % path, file=sys.stderr)
        return 2
    size, stamp, _ = report_identity(path)
    out_dir = os.path.join(os.path.dirname(os.path.abspath(path)), "bundles")
    os.makedirs(out_dir, exist_ok=True)
    tag = fingerprint(size, stamp).replace("@", "_") if stamp is not None else "nostamp"
    out = os.path.join(out_dir, "%s-%s.zip" % (os.path.splitext(os.path.basename(path))[0], tag))
    man = os.path.join(symbol_dir("windows", "release"), "build.json")
    info = os.path.join(symbol_dir("windows", "release"), "build-info.txt")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(path, os.path.basename(path))
        if os.path.isfile(man):
            z.write(man, "symbols/build.json")
        if os.path.isfile(info):
            z.write(info, "symbols/build-info.txt")
        z.writestr("HOW-TO-READ.txt",
                   "Crash report bundle\n"
                   "  report            %s\n"
                   "  build fingerprint %s\n"
                   "  symbols           %s\n"
                   "The offsets in the report only resolve correctly against the\n"
                   "ApplicationMain.map listed in symbols/build-info.txt of the SAME build.\n"
                   % (os.path.basename(path), fingerprint(size, stamp) if stamp is not None else "unknown",
                      "included" if os.path.isfile(man) else "NOT AVAILABLE on this machine"))
    print("wrote %s (%s)" % (rel(out), human(os.path.getsize(out))))
    return 0


def cmd_prune(args):
    """Drop superseded bundles. The store grows with every build (a map is ~80 MB)."""
    store = os.path.join(ROOT, "export", "symbols")
    targets = []
    if os.path.isdir(store):
        for base, dirs, files in os.walk(store):
            if os.path.basename(base) == "_stale":
                targets.append(base)
                dirs[:] = []
                continue
            for f in files:
                if f.endswith(".tmp"):
                    targets.append(os.path.join(base, f))
    total = 0
    for t in targets:
        size = sum_dir_size(t) if os.path.isdir(t) else os.path.getsize(t)
        total += size
        print(("would remove " if args.dry_run else "removed ") + rel(t) + "  (" + human(size) + ")")
        if not args.dry_run:
            if os.path.isdir(t):
                shutil.rmtree(t, ignore_errors=True)
            else:
                try:
                    os.remove(t)
                except OSError:
                    pass
    print("%s %s  (%d item(s))" % ("would free" if args.dry_run else "freed", human(total), len(targets)))
    return 0


def cmd_doctor(args):
    print("repo      %s" % ROOT)
    print("python    %s" % sys.version.split()[0])
    for tool in ("haxe", "haxelib", "python", "git"):
        p = shutil.which(tool)
        print("%-9s %s" % (tool, p or "MISSING"))
    rows = [judge(p, m) for p, m in builds()]
    stale = [r for r in rows if r["verdict"] not in (OK, NOBIN)]
    print("builds    %d, without current symbols: %d" % (len(rows), len(stale)))
    if stale:
        print("next      tools\\diag symbols      (publish symbols for the last build)")
    else:
        print("next      tools\\diag report <crash file>   (or tools\\diag status)")
    return 0 if not stale else 1


def run_diag(argv=None):
    """The console side: one branch per subcommand, all of them on this file."""
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        return default_entry()
    if argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "status":
        ap = argparse.ArgumentParser(prog="crash.py status")
        ap.add_argument("--json", action="store_true")
        return cmd_status(ap.parse_args(rest))
    if cmd == "symbols":
        ap = argparse.ArgumentParser(prog="crash.py symbols")
        ap.add_argument("--quiet", action="store_true")
        return cmd_symbols(ap.parse_args(rest))
    if cmd == "report":
        ap = argparse.ArgumentParser(prog="crash.py report")
        ap.add_argument("file")
        ap.add_argument("--check-only", action="store_true",
                        help="stop after the freshness check (exit 1 if the symbols are stale)")
        ns, extra = ap.parse_known_args(rest)
        ns.extra = extra
        return cmd_report(ns)
    if cmd == "bundle":
        ap = argparse.ArgumentParser(prog="crash.py bundle")
        ap.add_argument("file")
        return cmd_bundle(ap.parse_args(rest))
    if cmd == "prune":
        ap = argparse.ArgumentParser(prog="crash.py prune")
        ap.add_argument("--dry-run", action="store_true")
        return cmd_prune(ap.parse_args(rest))
    if cmd == "ui":
        ap = argparse.ArgumentParser(prog="crash.py ui")
        ap.add_argument("report", nargs="?")
        return cmd_ui(ap.parse_args(rest))
    if cmd == "doctor":
        return cmd_doctor(argparse.Namespace())
    print("unknown command %r - try 'python tools\\crash.py help'" % cmd, file=sys.stderr)
    return 2


def cmd_ui(args):
    """The window: builds, reports, and the actions that need both.

    Two tabs, because there are two questions and they are answered by different
    halves of this file:

      Builds  - does the symbol bundle on disk belong to the binary on disk?
      Report  - what does this report actually say?

    Both call the same functions as the console subcommands (judge(), the same
    freshness gate, the same triage), so the window cannot drift from the CLI.
    Labels are English + Chinese: the people who open this read one or the other.
    """
    try:
        import contextlib
        import io
        import tkinter as tk
        from tkinter import filedialog, ttk
    except Exception as exc:
        print("tkinter is unavailable (%s) - use 'python tools\\crash.py status'" % exc, file=sys.stderr)
        return 2

    crash_dir, default_map, exe_path = repo_defaults()

    win = tk.Tk()
    win.title("SeiunEngine - crash reports & symbols  |  崩溃报告与符号")
    win.geometry("1080x680")
    win.minsize(820, 520)

    head = tk.Frame(win)
    head.pack(fill="x", padx=10, pady=(10, 2))
    tk.Label(head, text="SeiunEngine", font=("Segoe UI", 13, "bold")).pack(side="left")
    tk.Label(head, text="crash reports & symbols  |  崩溃报告与符号", font=("Segoe UI", 10)).pack(side="left", padx=6)

    nb = ttk.Notebook(win)
    nb.pack(fill="both", expand=True, padx=10, pady=(6, 0))

    # ---------------------------------------------------------------- builds tab
    tab_builds = tk.Frame(nb)
    nb.add(tab_builds, text=" Builds 构建 ")

    cols = ("platform", "mode", "verdict", "build", "commit")
    titles = {"platform": "platform 平台", "mode": "mode 模式", "verdict": "symbols 符号",
              "build": "binary 构建指纹", "commit": "revision 版本"}
    tree = ttk.Treeview(tab_builds, columns=cols, show="headings", height=9)
    for c in cols:
        tree.heading(c, text=titles[c])
        tree.column(c, width=240 if c == "build" else 140, anchor="w")
    tree.tag_configure(OK, foreground="#1f7a1f")
    tree.tag_configure(STALE, foreground="#b06a00")
    tree.tag_configure(MISSING, foreground="#b00020")
    tree.tag_configure(NOBIN, foreground="#808080")
    tree.pack(fill="x", padx=6, pady=(6, 0))

    builds_out = tk.Text(tab_builds, height=8, wrap="word", font=("Consolas", 9))
    builds_scroll = ttk.Scrollbar(tab_builds, command=builds_out.yview)
    builds_out.configure(yscrollcommand=builds_scroll.set)
    builds_scroll.pack(side="right", fill="y", pady=6)
    builds_out.pack(side="left", fill="both", expand=True, padx=(6, 0), pady=6)

    # ---------------------------------------------------------------- report tab
    tab_report = tk.Frame(nb)
    nb.add(tab_report, text=" Report 报告 ")

    pick = tk.Frame(tab_report)
    pick.pack(fill="x", padx=6, pady=(8, 2))
    tk.Label(pick, text="report 报告", width=12, anchor="w").pack(side="left")
    report_var = tk.StringVar(value="")
    report_entry = tk.Entry(pick, textvariable=report_var)
    report_entry.pack(side="left", fill="x", expand=True, padx=4)

    pick2 = tk.Frame(tab_report)
    pick2.pack(fill="x", padx=6, pady=2)
    tk.Label(pick2, text="map (optional) 映射", width=12, anchor="w").pack(side="left")
    map_var = tk.StringVar(value="")
    map_entry = tk.Entry(pick2, textvariable=map_var)
    map_entry.pack(side="left", fill="x", expand=True, padx=4)

    buttons = tk.Frame(tab_report)
    buttons.pack(fill="x", padx=6, pady=4)

    body = tk.Frame(tab_report)
    body.pack(fill="both", expand=True, padx=6, pady=(0, 6))
    listing = tk.Listbox(body, width=42, font=("Consolas", 9), activestyle="dotbox")
    body_scroll = ttk.Scrollbar(body, command=listing.yview)
    listing.configure(yscrollcommand=body_scroll.set)
    listing.pack(side="left", fill="y")
    body_scroll.pack(side="left", fill="y")
    out = tk.Text(body, wrap="word", font=("Consolas", 9))
    out_scroll = ttk.Scrollbar(body, command=out.yview)
    out.configure(yscrollcommand=out_scroll.set)
    out.pack(side="left", fill="both", expand=True, padx=(6, 0))
    out_scroll.pack(side="right", fill="y")

    store = tk.Label(win, anchor="w", font=("Segoe UI", 9))
    store.pack(fill="x", padx=10, pady=(4, 8))

    state = {"rows": {}, "reports": []}

    def rel(p):
        try:
            return os.path.relpath(p, ROOT)
        except Exception:
            return p

    def refresh_builds():
        tree.delete(*tree.get_children())
        rows = [judge(p, m) for p, m in builds()]
        state["rows"] = {}
        for r in rows:
            g = r.get("git") or {}
            commit = (g.get("commit") or "-") + ("+" if g.get("dirty") else "")
            iid = tree.insert("", "end", values=(r["platform"], r["mode"], r["verdict"],
                                                 r["binary_fp"] or "-", commit), tags=(r["verdict"],))
            state["rows"][iid] = r
        total = sum_dir_size(os.path.join(ROOT, "export", "symbols"))
        store.config(text="symbol store 符号库: %s   |   %d build(s) 构建" % (human(total), len(rows)))
        kids = tree.get_children()
        good = [i for i in kids if state["rows"][i]["verdict"] == OK]
        pick = (good or kids)[0] if kids else None
        if pick:
            tree.selection_set(pick)
            tree.focus(pick)
            tree.see(pick)
            render_build_row(state["rows"][pick])

    def render_build_row(r):
        lines = ["%s %s  ->  %s   %s" % (r["platform"], r["mode"], r["verdict"], r["reason"]), ""]
        for key in ("binary", "manifest"):
            if r.get(key):
                lines.append("%-9s %s" % (key, rel(r[key])))
        for key in ("binary_fp", "symbols_fp"):
            if r.get(key):
                lines.append("%-9s %s" % (key, r[key]))
        g = r.get("git") or {}
        if g.get("commit"):
            lines.append("%-9s %s%s  %s" % ("commit", g["commit"], "+" if g.get("dirty") else "",
                                            g.get("version", "")))
        if r.get("artifacts"):
            lines.append("%-9s %s" % ("files", ", ".join(r["artifacts"])))
        builds_out.delete("1.0", "end")
        builds_out.insert("end", "\n".join(lines))

    def show_build_row(_event=None):
        sel = tree.selection()
        if sel and sel[0] in state["rows"]:
            render_build_row(state["rows"][sel[0]])

    def refresh_reports():
        listing.delete(0, "end")
        paths = sorted(report_files(crash_dir), key=os.path.getmtime, reverse=True) if os.path.isdir(crash_dir) else []
        state["reports"] = paths
        for path in paths:
            name = os.path.basename(path)
            kind = "?"
            try:
                with open(path, encoding="utf-8-sig", errors="replace") as fh:
                    for line in fh:
                        if line.startswith("Kind:"):
                            kind = line.split(":", 1)[1].strip().split()[0]
                            break
                        if line.startswith("==="):
                            continue
            except Exception:
                pass
            when = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%m-%d %H:%M")
            listing.insert("end", "%-16s %-12s %s" % (when, kind, name))
        if not paths:
            listing.insert("end", "(no report in %s)" % rel(crash_dir))

    def pick_report(_event=None):
        sel = listing.curselection()
        if sel and sel[0] < len(state["reports"]):
            report_var.set(state["reports"][sel[0]])

    def browse_report():
        path = filedialog.askopenfilename(title="Pick a crash report  选择崩溃报告",
                                          initialdir=crash_dir,
                                          filetypes=[("Crash report", "*.txt"), ("All files", "*.*")])
        if path:
            report_var.set(path)

    def browse_map():
        path = filedialog.askopenfilename(title="Pick a linker map  选择 map",
                                          initialdir=os.path.join(ROOT, "export", "symbols"),
                                          filetypes=[("Map file", "*.map"), ("All files", "*.*")])
        if path:
            map_var.set(path)

    def analyze():
        path = report_var.get().strip()
        if not path:
            out.delete("1.0", "end")
            out.insert("end", "pick a report first  先选一份报告\n")
            return
        extra = ["--crash", path]
        if map_var.get().strip():
            extra += ["-m", map_var.get().strip()]
        extra += ["--summary", "--no-gui", "--no-color"]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = cmd_report(argparse.Namespace(file=path, check_only=True, extra=[]))
            if code == 0:
                run_triage(extra)
            else:
                buf.write("\nnot resolved: the symbols are not from this build.\n"
                          "未解析: 符号不属于这份报告对应的构建, 先看 Builds 标签。\n")
        out.delete("1.0", "end")
        out.insert("end", buf.getvalue())

    def triage_window():
        """The full triage window in its own process (it owns a Tk mainloop)."""
        exe = sys.executable
        pythonw = os.path.join(os.path.dirname(exe), "pythonw.exe")
        if os.path.isfile(pythonw):
            exe = pythonw
        argv = [exe, os.path.abspath(__file__), "triage"]
        if report_var.get().strip():
            argv += ["--crash", report_var.get().strip()]
        if map_var.get().strip():
            argv += ["-m", map_var.get().strip()]
        try:
            subprocess.Popen(argv, cwd=ROOT)
        except Exception as exc:
            out.insert("end", "\ncannot start the triage window: %s\n" % exc)

    def bundle():
        path = report_var.get().strip()
        if not path:
            out.insert("end", "\npick a report first  先选一份报告\n")
            return
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            cmd_bundle(argparse.Namespace(file=path))
        out.insert("end", "\n" + buf.getvalue())

    def open_symbols():
        path = os.path.join(ROOT, "export", "symbols")
        if not os.path.isdir(path):
            out.insert("end", "\nno symbol store yet - run a build first.\n还没有符号库, 先构建一次。\n")
            return
        try:
            os.startfile(path)
        except Exception:
            out.insert("end", "\n%s\n" % path)

    for label, fn in (("Analyze 分析", analyze), ("Triage window 分析窗口", triage_window),
                      ("Bundle 打包", bundle), ("Symbols 符号目录", open_symbols),
                      ("Refresh 刷新", lambda: (refresh_builds(), refresh_reports()))):
        tk.Button(buttons, text=label, command=fn, width=22).pack(side="left", padx=(0, 6))
    tk.Button(pick, text="Browse 浏览", command=browse_report, width=14).pack(side="left")
    tk.Button(pick2, text="Browse 浏览", command=browse_map, width=14).pack(side="left")

    tree.bind("<<TreeviewSelect>>", show_build_row)
    listing.bind("<<ListboxSelect>>", pick_report)
    listing.bind("<Double-Button-1>", lambda _e: analyze())

    refresh_builds()
    refresh_reports()
    if getattr(args, "report", None):
        report_var.set(os.path.abspath(args.report))
        nb.select(tab_report)
        analyze()
    win.mainloop()
    return 0


USAGE = "usage: python tools/crash.py <command> ...   (python tools/crash.py help)"


def _legacy(fn, rest):
    """Run an entry point that reads sys.argv, and turn SystemExit into a code."""
    saved = sys.argv
    sys.argv = [saved[0]] + list(rest)
    try:
        return fn() or 0
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 0
    finally:
        sys.argv = saved


def run_elf(fn, rest):
    """The ELF subcommands need pyelftools; say so instead of failing on None."""
    if ELFFile is None:
        print("pyelftools is required:  pip install pyelftools", file=sys.stderr)
        return 2
    return _legacy(fn, rest)


def run_triage(rest):
    """In-process triage. 'report' and the window both go through here.

    English by default: the reports and the CLI are English (the Lime layer has
    no other language), and a Chinese console under a Chinese Windows locale is
    how a bug report ends up half-translated. --lang zh still switches it.
    """
    argv = list(rest)
    if "--lang" not in argv:
        argv += ["--lang", "en"]
    return _legacy(lambda: tri_main(argv), list(rest))


_ENTRY = {
    "triage": run_triage,
    "resolve": lambda rest: _legacy(map_main, rest),
    "verify-map": lambda rest: _legacy(vm_main, rest),
    "symbolize": lambda rest: run_elf(sa_main, rest),
    "linemap": lambda rest: run_elf(selm_main, rest),
    "linemap-pdb": lambda rest: _legacy(pdb_main, rest),
    "selm-compare": lambda rest: _legacy(lc_main, rest),
}


def default_entry():
    """No arguments: open the window.

    Running the file - double-click, a shortcut, 'python tools/crash.py' - should
    show something. If stdout is a pipe (a CI step, '| grep', a wrapper script)
    a window would block with nobody watching, so that case gets the text report
    instead; 'python tools/crash.py status' always gives the text.
    """
    try:
        interactive = sys.stdout is None or sys.stdout.isatty()
    except Exception:
        interactive = False
    if interactive and gui_available():
        try:
            return cmd_ui(argparse.Namespace(report=None))
        except Exception as exc:
            print("cannot open the window (%s) - text report instead" % exc, file=sys.stderr)
    return cmd_status(argparse.Namespace(json=False))


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        return default_entry()
    if argv[0] in ("help", "-h", "--help"):
        print(__doc__.strip())
        return 0
    # Dropping a report on the script opens it in the window.
    if argv[0].lower().endswith(".txt") and os.path.isfile(argv[0]):
        return cmd_ui(argparse.Namespace(report=argv[0]))
    if argv[0] in _ENTRY:
        return _ENTRY[argv[0]](argv[1:])
    return run_diag(argv)


if __name__ == "__main__":
    sys.exit(main())
