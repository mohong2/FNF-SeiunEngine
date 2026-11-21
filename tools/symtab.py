#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
symtab - turn an ELF or Mach-O binary into the text symbol table a crash report
can be resolved against.

Why this exists
---------------
Windows release links emit an MSVC .map, so tools/crash.py could always turn a
"module+offset" frame back into a function name there. Linux and macOS release
links emit neither a .map nor a dSYM, and for years the published symbol bundle
for those two targets was build.json + build-info.txt - identity, no symbols.

The binary itself has always carried the answer, because hxcpp's release
stripper is narrow (gcc-toolchain.xml, shared by both targets):

  * Linux runs "strip -d" - debugging sections only. The ELF .symtab, which is
    not a debugging section, is still in the shipped executable.
  * macOS runs "strip -u -r -x" - "-x" drops local symbols, so every external
    one survives (hxcpp compiles with default visibility there). A Mach-O nlist
    carries no size, which is why a macOS frame resolves to "name+offset".

Nothing has to be rebuilt and the published binary does not change by a byte;
this tool reads the table out into a few megabytes of text.

Offset convention (the part that must match the crash handler)
-------------------------------------------------------------
source/backend/native_crash.inc prints every POSIX frame as

    pc <offset> <module>          offset = pc - dli_fbase

so the table stores exactly that number:

  * ELF   - st_value as it appears in the file. For an ET_DYN/ET_EXEC image the
            address of a symbol at link-time vaddr V is dli_fbase + V, so
            pc - dli_fbase == V.
  * Mach-O- n_value - __TEXT.vmaddr. dladdr() reports the Mach-O header itself
            as dli_fbase, and the header sits at __TEXT.vmaddr (0x100000000 on
            both slices), so pc - dli_fbase == n_value - __TEXT.vmaddr.

A report from another platform's convention still lands on a symbol, just with
a constant bias, and the header comment states the base used.

Usage
-----
  python tools/symtab.py --platform linux --out export/symbols/linux-release
  python tools/symtab.py --platform macos --binary <app>/Contents/MacOS/SeiunEngine --out DIR
  python tools/symtab.py --self-test

Without --binary the path comes from build.json's exe.path, i.e. the binary the
<postbuild> hook (tools/SymbolsAfterBuild.hx) just recorded, so a bundle can
never describe a different file than its manifest.

Only the Python standard library is used: this runs on a bare CI runner, and a
missing pyelftools must not be able to turn into an empty symbol bundle.
"""

import argparse
import json
import os
import struct
import sys

FNV_OFFSET = 2166136261
FNV_PRIME = 16777619

SYM_SUFFIX = ".sym"
SYM_HEADER = "# world  SeiunEngine symbol table"

ELF_MAGIC = b"\x7fELF"
SHT_SYMTAB = 2
SHT_DYNSYM = 11
STT_FILE = 4
STT_SECTION = 3

MACH_MAGIC = 0xFEEDFACE
MACH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
N_STAB = 0xE0
N_TYPE = 0x0E
N_SECT = 0x0E
N_ABS = 0x02

CPU_NAMES = {
    7: "i386",
    0x01000007: "x86_64",
    12: "arm",
    0x0100000C: "arm64",
    0x01000012: "ppc",
    18: "ppc",
}


class SymtabError(Exception):
    pass


# --------------------------------------------------------------------- ELF

def _elf_sections(fh, shoff, shentsize, shnum, shstrndx):
    """[(name, type, offset, size, link, entsize)] plus the header string table."""
    fh.seek(shoff)
    raw = fh.read(shentsize * shnum)
    if len(raw) < shentsize * shnum:
        raise SymtabError("section header table is truncated")
    out = []
    for i in range(shnum):
        b = raw[i * shentsize:(i + 1) * shentsize]
        sh_name, sh_type = struct.unpack_from("<II", b, 0)
        sh_offset, sh_size = struct.unpack_from("<QQ", b, 0x18)
        sh_link, = struct.unpack_from("<I", b, 0x28)
        sh_entsize, = struct.unpack_from("<Q", b, 0x38)
        out.append({"name_off": sh_name, "type": sh_type, "offset": sh_offset,
                    "size": sh_size, "link": sh_link, "entsize": sh_entsize})
    if shstrndx >= len(out):
        raise SymtabError("e_shstrndx points past the section table")
    strtab_hdr = out[shstrndx]
    fh.seek(strtab_hdr["offset"])
    names = fh.read(strtab_hdr["size"])
    for s in out:
        end = names.find(b"\x00", s["name_off"])
        s["name"] = names[s["name_off"]:end if end >= 0 else None].decode("utf-8", "replace")
    return out


def read_elf(path):
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        hdr = fh.read(64)
        if len(hdr) < 64 or hdr[:4] != ELF_MAGIC:
            raise SymtabError("not an ELF file")
        if hdr[4] != 2:
            raise SymtabError("only 64-bit ELF is supported (ei_class=%d)" % hdr[4])
        if hdr[5] != 1:
            raise SymtabError("only little-endian ELF is supported (ei_data=%d)" % hdr[5])
        e_type, e_machine = struct.unpack_from("<HH", hdr, 0x10)
        e_shoff, = struct.unpack_from("<Q", hdr, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", hdr, 0x3A)
        if e_shoff == 0 or e_shentsize < 64:
            raise SymtabError("ELF has no section header table (stripped?)")

        # e_shnum == 0 means "count lives in section 0's sh_size" (extended indexing)
        if e_shnum == 0:
            fh.seek(e_shoff + 0x20)
            e_shnum, = struct.unpack("<Q", fh.read(8))

        sections = _elf_sections(fh, e_shoff, e_shentsize, e_shnum, e_shstrndx)
        symtab = next((s for s in sections if s["type"] == SHT_SYMTAB), None)
        source = "symtab"
        if symtab is None:
            symtab = next((s for s in sections if s["type"] == SHT_DYNSYM), None)
            source = "dynsym"
        if symtab is None:
            raise SymtabError("neither .symtab nor .dynsym is present (fully stripped binary)")
        if symtab["link"] >= len(sections):
            raise SymtabError(".symtab has no string table (sh_link=%d)" % symtab["link"])
        strsec = sections[symtab["link"]]
        fh.seek(strsec["offset"])
        strs = fh.read(strsec["size"])

        entsize = symtab["entsize"] or 24
        fh.seek(symtab["offset"])
        blob = fh.read(symtab["size"])
        entries = []
        for off in range(0, len(blob) - entsize + 1, entsize):
            st_name, st_info, _other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", blob, off)
            if st_name == 0 or st_value == 0 or st_shndx == 0:
                continue
            st_type = st_info & 0xF
            if st_type in (STT_FILE, STT_SECTION):
                continue
            end = strs.find(b"\x00", st_name)
            name = strs[st_name:end if end >= 0 else None]
            if not name:
                continue
            entries.append((st_value, st_size, name.decode("utf-8", "replace")))

    machine = {62: "x86_64", 183: "arm64", 40: "arm"}.get(e_machine, "machine-%d" % e_machine)
    kind = {1: "ET_REL", 2: "ET_EXEC", 3: "ET_DYN", 4: "ET_CORE"}.get(e_type, "ET_%d" % e_type)
    return {
        "format": "ELF64",
        "arch": machine,
        "kind": kind,
        "source": source,
        "base": 0,
        "base_note": "ELF st_value is stored as-is (a crash report prints pc - dli_fbase)",
        "entries": entries,
    }


# ------------------------------------------------------------------- Mach-O

def _macho_at(fh, offset, want_arch=None):
    fh.seek(offset)
    head = fh.read(32)
    if len(head) < 28:
        raise SymtabError("truncated Mach-O header")
    magic_le, = struct.unpack_from("<I", head, 0)
    if magic_le == MACH_MAGIC_64:
        is64, endian = True, "<"
    elif magic_le == MACH_MAGIC:
        is64, endian = False, "<"
    else:
        magic_be, = struct.unpack_from(">I", head, 0)
        if magic_be == MACH_MAGIC_64:
            is64, endian = True, ">"
        elif magic_be == MACH_MAGIC:
            is64, endian = False, ">"
        else:
            raise SymtabError("not a Mach-O image (magic=0x%08x)" % magic_le)
    if not is64:
        raise SymtabError("only 64-bit Mach-O is supported")

    cputype, _sub, _ftype, ncmds, sizeofcmds = struct.unpack_from(endian + "iiIII", head, 4)
    fh.seek(offset + 32)
    cmds = fh.read(sizeofcmds)
    if len(cmds) < sizeofcmds:
        raise SymtabError("load commands are truncated")

    text_vmaddr = None
    symtab = None
    pos = 0
    while pos + 8 <= len(cmds):
        cmd, cmdsize = struct.unpack_from(endian + "II", cmds, pos)
        if cmdsize < 8:
            raise SymtabError("load command with cmdsize=%d" % cmdsize)
        body = cmds[pos:pos + cmdsize]
        if cmd == LC_SEGMENT_64 and len(body) >= 72:
            segname = body[8:24].split(b"\x00")[0].decode("ascii", "replace")
            vmaddr, = struct.unpack_from(endian + "Q", body, 24)
            if segname == "__TEXT" and text_vmaddr is None:
                text_vmaddr = vmaddr
        elif cmd == LC_SYMTAB and len(body) >= 24:
            symoff, nsyms, stroff, strsize = struct.unpack_from(endian + "IIII", body, 8)
            symtab = (symoff, nsyms, stroff, strsize)
        pos += cmdsize
    if symtab is None:
        raise SymtabError("no LC_SYMTAB (the image has no symbol table; was it stripped?)")
    if text_vmaddr is None:
        raise SymtabError("no __TEXT segment to anchor the offsets to")

    arch = CPU_NAMES.get(cputype, "cpu-%d" % cputype)
    if want_arch and arch != want_arch:
        raise SymtabError("slice is %s, not %s" % (arch, want_arch))

    symoff, nsyms, stroff, strsize = symtab
    fh.seek(offset + strsize and 0 or 0)  # no-op, keeps the reads below readable
    fh.seek(offset + stroff)
    strs = fh.read(strsize)
    fh.seek(offset + symoff)
    blob = fh.read(nsyms * 16)
    entries = []
    for i in range(min(nsyms, len(blob) // 16)):
        n_strx, n_type, _n_sect, _n_desc, n_value = struct.unpack_from(endian + "IBBHQ", blob, i * 16)
        if n_type & N_STAB:
            continue  # debug-map entry, not a symbol
        kind = n_type & N_TYPE
        if kind not in (N_SECT, N_ABS):
            continue  # N_UNDF (imported) or N_INDR
        if n_strx == 0 or n_value == 0:
            continue
        end = strs.find(b"\x00", n_strx)
        name = strs[n_strx:end if end >= 0 else None]
        if not name:
            continue
        rva = n_value - text_vmaddr
        if rva < 0:
            continue
        entries.append((rva, 0, name.decode("utf-8", "replace")))

    return {
        "format": "Mach-O64",
        "arch": arch,
        "kind": "dylib/executable",
        "source": "symtab",
        "base": text_vmaddr,
        "base_note": "__TEXT.vmaddr 0x%x subtracted (a crash report prints pc - dli_fbase)" % text_vmaddr,
        "entries": entries,
    }


def read_macho(path, want_arch=None):
    with open(path, "rb") as fh:
        magic, = struct.unpack("<I", fh.read(4))
        if magic in (FAT_MAGIC, FAT_MAGIC_64):
            fh.seek(0)
            nfat, = struct.unpack_from(">I", fh.read(8), 4)
            wide = magic == FAT_MAGIC_64
            entsize = 32 if wide else 20
            arches = []
            for i in range(nfat):
                raw = fh.read(entsize)
                if wide:
                    cputype, _sub, off, size, _align, _res = struct.unpack(">iiQQII", raw)
                else:
                    cputype, _sub, off, size, _align = struct.unpack(">iiIII", raw)
                arches.append((cputype, off, size))
            if not arches:
                raise SymtabError("fat header with no slices")
            if want_arch:
                pick = [a for a in arches if CPU_NAMES.get(a[0]) == want_arch]
                if not pick:
                    raise SymtabError("fat image has no %s slice (has: %s)" % (
                        want_arch, ", ".join(CPU_NAMES.get(a[0], str(a[0])) for a in arches)))
            elif len(arches) == 1:
                pick = arches
            else:
                raise SymtabError("fat image with %d slices - pass --arch (%s)" % (
                    len(arches), ", ".join(CPU_NAMES.get(a[0], str(a[0])) for a in arches)))
            info = _macho_at(fh, pick[0][1], want_arch)
            info["kind"] = "fat (%d slices)" % len(arches)
            return info
        return _macho_at(fh, 0, want_arch)


def read_binary(path, want_arch=None):
    with open(path, "rb") as fh:
        magic = fh.read(4)
    if magic == ELF_MAGIC:
        return read_elf(path)
    try:
        return read_macho(path, want_arch)
    except SymtabError as e:
        raise SymtabError("neither ELF nor Mach-O: %s" % e)


# ------------------------------------------------------------------ writing

def normalize(entries):
    """Drop duplicates, sort by offset. Same address keeps the more specific name."""
    seen = {}
    for rva, size, name in entries:
        key = (rva, name)
        if key in seen:
            continue
        seen[key] = size
    out = sorted(seen.items(), key=lambda kv: (kv[0][0], kv[0][1]))
    return [(rva, size, name) for (rva, name), size in out]


def write_sym(path, info, entries, binary, fp=None, extra=()):
    lines = [
        "# SeiunEngine symbol table",
        "# format   : <offset-hex> <size-hex> <name>",
        "# offset   : pc - module base (exactly the number a POSIX crash frame prints)",
        "# resolve  : python tools/crash.py sym %s 0x<offset>" % os.path.basename(path),
        "# binary   : %s" % binary,
        "# kind     : %s %s (%s, %s)" % (info["format"], info["arch"], info["kind"], info["source"]),
        "# base     : %s" % info["base_note"],
        "# symbols  : %d" % len(entries),
    ]
    if fp:
        lines.insert(5, "# build    : %s" % fp)
    for e in extra:
        lines.append("# %s" % e)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
        for rva, size, name in entries:
            fh.write("%016x %08x %s\n" % (rva, size, name))


def read_sym(path):
    """(offset, size, name) rows from a .sym file. Mirrors crash.py's reader."""
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line or line[0] == "#":
                continue
            parts = line.rstrip("\r\n").split(" ", 2)
            if len(parts) != 3:
                continue
            try:
                out.append((int(parts[0], 16), int(parts[1], 16), parts[2]))
            except ValueError:
                continue
    return out


# ------------------------------------------------------------- build.json

def manifest_path(sym_dir):
    return os.path.join(sym_dir, "build.json")


def read_manifest(sym_dir):
    p = manifest_path(sym_dir)
    if not os.path.isfile(p):
        return None, p
    try:
        with open(p, "r", encoding="utf-8") as fh:
            return json.load(fh), p
    except Exception as e:
        raise SymtabError("%s is unreadable (%s)" % (p, e))


def record_in_manifest(sym_dir, name, count, size, info, binary):
    """Tell build.json/build-info.txt that this bundle now carries a table.

    The hook (tools/SymbolsAfterBuild.hx) writes both files and knows nothing
    about this step, so the two are amended here rather than left lying about
    the bundle's contents.
    """
    man, path = read_manifest(sym_dir)
    if man is None:
        return
    man["symtab"] = {
        "file": name,
        "symbols": count,
        "size": size,
        "format": info["format"],
        "arch": info["arch"],
        "source": info["source"],
        "binary": binary,
    }
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(man, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)

    info_txt = os.path.join(sym_dir, "build-info.txt")
    if os.path.isfile(info_txt):
        with open(info_txt, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        line = "symtab   %s  %d symbols, %s, %s %s -> offset = pc - module base" % (
            name, count, human(size), info["format"], info["arch"])
        if line not in text:
            if not text.endswith("\n"):
                text += "\n"
            with open(info_txt, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text + line + "\n")


def human(n):
    if n >= 1 << 30:
        return "%.2f GB" % (n / float(1 << 30))
    if n >= 1 << 20:
        return "%.2f MB" % (n / float(1 << 20))
    if n >= 1 << 10:
        return "%.2f KB" % (n / float(1 << 10))
    return "%d B" % n


# --------------------------------------------------------------------- main

def pick_binary(sym_dir, explicit, plat):
    """(the file to read symbols from, the shipped binary's repo-relative path).

    They differ when the build kept a pre-strip copy: on macOS the shipped .app
    keeps only the exported names, so the table has to come from the unstripped
    link output instead. Strip removes sections and never moves code, so the
    offsets are the same in both files.
    """
    if explicit:
        if not os.path.isfile(explicit):
            raise SymtabError("--binary %s does not exist" % explicit)
        return explicit, None
    man, path = read_manifest(sym_dir)
    if man is None:
        raise SymtabError("%s is missing - the <postbuild> hook did not run for this build, "
                          "so there is nothing to say which binary to read" % path)
    exe = man.get("exe") or {}
    shipped = exe.get("path") or ""
    if not shipped:
        raise SymtabError("%s names no exe - tools/SymbolsAfterBuild.hx did not record the "
                          "shipped binary for %s" % (path, plat))
    full = next((a.get("path") for a in man.get("artifacts", [])
                 if a.get("role") == "unstripped"), None)
    chosen = full or shipped
    root = repo_root(sym_dir)
    cand = chosen if os.path.isabs(chosen) else os.path.join(root, chosen)
    if not os.path.isfile(cand):
        raise SymtabError("build.json points at %s, which does not exist" % chosen)
    return cand, shipped


def repo_root(sym_dir):
    """export/symbols/<plat>-<mode> -> the project root that owns export/."""
    p = os.path.abspath(sym_dir)
    for _ in range(4):
        p = os.path.dirname(p)
        if os.path.isfile(os.path.join(p, "Project.xml")):
            return p
    return os.getcwd()


def run(args):
    sym_dir = os.path.abspath(args.out)
    os.makedirs(sym_dir, exist_ok=True)

    binary, shipped = pick_binary(sym_dir, args.binary, args.platform)
    info = read_binary(binary, args.arch)
    entries = normalize(info["entries"])
    if not entries:
        raise SymtabError("%s carries no usable symbols (%s, %s)" % (binary, info["format"], info["source"]))
    if len(entries) < args.min_symbols:
        raise SymtabError("%s carries only %d symbols (min %d) - a table this sparse cannot "
                          "resolve a real crash report" % (binary, len(entries), args.min_symbols))

    name = args.name or (os.path.basename(binary) + SYM_SUFFIX)
    out = os.path.join(sym_dir, name)

    man, _ = read_manifest(sym_dir)
    fp = ((man or {}).get("exe") or {}).get("fp")
    extra = []
    if shipped and rel_to(repo_root(sym_dir), binary) != shipped:
        extra.append("shipped  : %s" % shipped)
        extra.append("note     : this table was read from the pre-strip link output; strip removes")
        extra.append("           sections only, so every offset below is valid in that file too")
    write_sym(out, info, entries, rel_to(repo_root(sym_dir), binary), fp, extra)
    record_in_manifest(sym_dir, name, len(entries), os.path.getsize(out), info, rel_to(repo_root(sym_dir), binary))

    if not args.quiet:
        print("%s: %d symbols from the %s %s (%s) of %s" % (
            rel_to(repo_root(sym_dir), out), len(entries), info["format"], info["arch"],
            info["source"], rel_to(repo_root(sym_dir), binary)))
        print("%s -> %s" % (human(os.path.getsize(binary)), human(os.path.getsize(out))))
        first = entries[0]
        print("first   0x%x %s" % (first[0], first[2]))
    return 0


def rel_to(root, path):
    try:
        return os.path.relpath(os.path.abspath(path), root).replace("\\", "/")
    except ValueError:
        return path


def self_test():
    """Round-trip the writer/reader and check the offset convention on fixtures."""
    import tempfile

    entries = [(0x1000, 0x10, "alpha"), (0x1000, 0x10, "alpha"), (0x2000, 0, "beta")]
    norm = normalize(entries)
    assert len(norm) == 2, norm
    assert norm[0][0] == 0x1000 and norm[1][0] == 0x2000, norm

    tmp = tempfile.mkdtemp()
    p = os.path.join(tmp, "t.sym")
    info = {"format": "ELF64", "arch": "x86_64", "kind": "ET_DYN", "source": "symtab",
            "base": 0, "base_note": "test"}
    write_sym(p, info, norm, "bin/app", fp="12B#deadbeef")
    back = read_sym(p)
    assert back == norm, (back, norm)
    text = open(p, "r", encoding="utf-8").read()
    assert "# build    : 12B#deadbeef" in text, text.splitlines()[:8]

    seen = 0
    for cand in ("ndll/Linux64/lime.ndll", "ndll/Mac64/lime.ndll"):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".haxelib", "lime", "8,0,1", cand)
        if not os.path.isfile(path):
            continue
        got = read_binary(path)
        rows = normalize(got["entries"])
        assert rows, path
        print("ok  %-22s %-8s %-8s %6d symbols  first 0x%x %s" % (
            cand, got["format"], got["arch"], len(rows), rows[0][0], rows[0][2][:48]))
        seen += 1
    if not seen:
        print("ok  writer/reader round-trip (no .haxelib lime ndll available for the binary fixtures)")
    return 0


def build_parser():
    p = argparse.ArgumentParser(
        prog="symtab", description="Extract an ELF/Mach-O symbol table into a text .sym file")
    p.add_argument("--platform", default=None, help="linux / macos (only used for messages)")
    p.add_argument("--binary", default=None, help="binary to read; defaults to build.json's exe.path")
    p.add_argument("--out", default=None, help="symbol directory (e.g. export/symbols/linux-release)")
    p.add_argument("--name", default=None, help="output file name (default <binary>.sym)")
    p.add_argument("--arch", default=None, help="pick this slice out of a fat Mach-O")
    p.add_argument("--min-symbols", type=int, default=100,
                   help="fail when fewer symbols than this are found (default 100)")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--self-test", action="store_true")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.out:
        print("--out is required (e.g. export/symbols/linux-release)", file=sys.stderr)
        return 2
    try:
        return run(args)
    except SymtabError as e:
        print("symtab: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
