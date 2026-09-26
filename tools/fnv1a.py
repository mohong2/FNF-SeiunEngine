#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fnv1a.py - SeiunEngine build-fingerprint hash for one file.

The native crash handler identifies a build with a 32-bit FNV-1a hash: the
Android boot hook (source/backend/native_crash.inc, seiun_android_self_build_id)
and NativeCrash.fnv1aFile hash the first and last 64 KB of a binary, while the
linemap identity appended by NativeCrash.applyLinemap hashes the whole table.
This tool prints exactly the fragments a report's "Build:" line shows, so a
published symbol bundle can be matched against a user's crash report without
guessing which build it came from.

Usage:
    python tools/fnv1a.py file  <path>    ->  <size>B@<mtime>s#<8hex>
    python tools/fnv1a.py whole <path>    ->  <size>B#<8hex>

Constants are identical on all three sides (C++, Haxe, here).
"""

import os
import sys

FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 0x01000193
CHUNK = 65536


def fnv1a(data, h=FNV_OFFSET):
    for b in data:
        h ^= b
        h = (h * FNV_PRIME) & 0xFFFFFFFF
    return h


def hash_head_tail(path):
    """First 64 KB, plus the last 64 KB when the file is larger than 128 KB."""
    size = os.path.getsize(path)
    h = FNV_OFFSET
    with open(path, "rb") as f:
        h = fnv1a(f.read(CHUNK), h)
        if size > CHUNK * 2:
            f.seek(size - CHUNK)
            h = fnv1a(f.read(CHUNK), h)
    return h


def hash_whole(path):
    h = FNV_OFFSET
    with open(path, "rb") as f:
        while True:
            data = f.read(1 << 20)
            if not data:
                break
            h = fnv1a(data, h)
    return h


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("file", "whole"):
        print(__doc__)
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


if __name__ == "__main__":
    sys.exit(main())
