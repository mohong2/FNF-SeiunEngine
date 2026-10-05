#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_linemap.py - generate the crash-time address->file:line table for the
SeiunEngine native crash handler (Android and other POSIX targets).

Reads the DWARF line table from an UNSTRIPPED .so and writes a compact sorted
binary map that native_crash.inc binary-searches at crash time, so an on-device
native crash report can print the exact "[source/File.cpp:123]" for each frame
- no root, no tombstones, no host tools needed after the fact.

Usage:
    python gen_linemap.py <libApplicationMain-64.so> <out.bin> [--min-coverage 0.90]
    python gen_linemap.py --android release
    python gen_linemap.py --check-objdir export/release/android/obj/obj/androidarm64-64

The table is refused (non-zero exit) when it cannot locate most of the binary's
own functions - see MIN_COVERAGE and coverage().

Requires:  pip install pyelftools

Binary format (little endian):
    magic 'SELM' | u32 version=1 | u32 entry_count | u32 str_table_offset
    entries[entry_count]: { u32 rel_addr, u32 line, u32 str_off }  sorted by rel_addr
    string table (NUL-terminated file paths), located at str_table_offset

rel_addr is relative to the module load base (dladdr dli_fbase), i.e. the
link-time virtual address - matching (fault_pc - dli_fbase) at runtime.
Rows with line==0 are "no source info" terminators so a lookup never bleeds
into the next sequence. Only the FIRST row of every constant file:line run is
kept (the runtime lookup returns the last row <= pc, which is then exact).
"""

import bisect
import glob
import struct
import sys
import os

try:
    from elftools.elf.elffile import ELFFile
except ImportError:
    sys.exit("pyelftools is required:  pip install pyelftools")

MAGIC = b"SELM"
VERSION = 1

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


def collect_rows(lib_path):
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


def build_map(rows, file_strings):
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
    out.extend(MAGIC)
    out.extend(struct.pack("<III", VERSION, len(entries), str_off))
    for addr, (fidx, line) in entries:
        out.extend(struct.pack("<III", addr, line, str_index[file_strings[fidx]]))
    out.extend(str_blob)
    return out, entries


def selftest(out_bytes, entries, lib_path):
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
            rows, file_strings = collect_rows(lib)
            out_bytes, entries = build_map(rows, file_strings)
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


def main():
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
            print(__doc__)
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
        print(__doc__)
        sys.exit(2)
    lib_path, out_path = positional
    if not os.path.exists(lib_path):
        sys.exit("ERROR: input not found: %s" % lib_path)

    rows, file_strings = collect_rows(lib_path)
    out_bytes, entries = build_map(rows, file_strings)

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
    selftest(out_bytes, entries, lib_path)


if __name__ == "__main__":
    sys.exit(main())
