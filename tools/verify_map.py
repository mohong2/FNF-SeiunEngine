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
                       so the entries are summed, not compared one by one).

USAGE
  # GUI: just run it with no arguments (or double-click on Windows)
  python tools/verify_map.py

  # CLI: give it an exe and a map, optionally --quiet
  python tools/verify_map.py <exe> <map> [--quiet]
  python tools/verify_map.py export/release/windows/bin/SeiunEngine.exe \
                             export/release/windows/symbols/ApplicationMain.map

EXIT CODES (CLI mode)
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


def run_gui():
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


def main() -> int:
    quiet = "--quiet" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--quiet"]

    # 没有给出两个路径：打开 GUI。若环境没有 tkinter / 无显示器，退回打印用法。
    if len(args) < 2:
        try:
            import tkinter  # noqa: F401
        except ImportError:
            print(__doc__)
            return 2
        try:
            run_gui()
        except Exception as exc:  # TclError（无显示器）等
            print(f"error: cannot start GUI: {exc}", file=sys.stderr)
            print(__doc__)
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


if __name__ == "__main__":
    sys.exit(main())