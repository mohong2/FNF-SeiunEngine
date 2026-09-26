#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""linemap_compare.py - do two SELM tables describe the same code?

The build scripts generate a crash linemap from one build and verify it against
the binary that actually embedded it. A relink can move a handful of functions
by a few bytes (the asset blob changes adjacent alignment), so byte equality is
too strict to be useful; this tool reports how many entries moved and by how
much.

Exit code 0: identical, or the drift is within tolerance (<= 0.1% of entries).
Exit code 1: the tables describe different code - regenerate and rebuild.

Usage:
    python tools/linemap_compare.py <embedded.bin> <rebuilt.bin>
"""

import struct
import sys

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


def main():
    if len(sys.argv) != 3:
        print(__doc__)
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


if __name__ == "__main__":
    sys.exit(main())
