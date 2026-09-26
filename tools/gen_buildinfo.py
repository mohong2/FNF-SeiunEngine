#!/usr/bin/env python3
"""Refresh source/BuildInfo.hx from git + Project.xml.

Run before a release build (tools/build_windows_symbols.ps1 and
tools/build_android_symbols.ps1 do this) so the in-game watermark and the
cold-start notice report the revision the binary was actually built from.

The checked-in BuildInfo.hx keeps COMMIT = "unknown" and doubles as the
template: only the three constant lines are rewritten, so the file keeps its
documentation and a release build produces a three-line diff.

Usage:
    python tools/gen_buildinfo.py            # rewrite source/BuildInfo.hx
    python tools/gen_buildinfo.py --check    # exit 1 when it is out of date
    python tools/gen_buildinfo.py --print    # only print the values

The dirty check ignores source/BuildInfo.hx itself: this generator writes it,
so counting it as a local change would mark every build after the first one as
dirty.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'source', 'BuildInfo.hx')
PROJECT = os.path.join(ROOT, 'Project.xml')
SELF_PATH = 'source/BuildInfo.hx'

FIELDS = (
    ('COMMIT', re.compile(r'(public static inline var COMMIT:String = )"[^"]*"')),
    ('VERSION', re.compile(r'(public static inline var VERSION:String = )"[^"]*"')),
    ('DIRTY', re.compile(r'(public static inline var DIRTY:Bool = )(?:true|false)')),
)


def git(*args):
    try:
        out = subprocess.check_output(('git',) + args, cwd=ROOT, stderr=subprocess.DEVNULL)
        return out.decode('utf-8', 'replace').strip()
    except Exception:
        return ''


def read_version():
    """Project.xml is read textually on purpose.

    It uses an undeclared config: prefix that PowerShell's [xml] rejects even
    though lime's own parser accepts it (ONLINE_PORT_HANDOFF 127.12).
    """
    try:
        with open(PROJECT, 'r', encoding='utf-8') as handle:
            match = re.search(r'<app\b[^>]*\bversion="([^"]*)"', handle.read())
        if match:
            return match.group(1)
    except Exception:
        pass
    return 'unknown'


def git_state():
    commit = git('rev-parse', '--short', 'HEAD') or 'unknown'
    dirty = False
    for line in git('status', '--porcelain').splitlines():
        path = line[3:].strip().replace('\\', '/')
        if path == SELF_PATH:
            continue
        dirty = True
        break
    return commit, dirty


def render(text, values):
    for name, pattern in FIELDS:
        if name == 'DIRTY':
            wanted = 'true' if values[name] else 'false'
        else:
            wanted = '"%s"' % values[name]
        text, count = pattern.subn(lambda match, wanted=wanted: match.group(1) + wanted, text, count=1)
        if count != 1:
            raise SystemExit('gen_buildinfo: cannot find %s in %s' % (name, OUT))
    return text


def main():
    commit, dirty = git_state()
    values = {'COMMIT': commit, 'VERSION': read_version(), 'DIRTY': dirty}

    with open(OUT, 'r', encoding='utf-8') as handle:
        current = handle.read()
    wanted = render(current, values)

    print('gen_buildinfo: commit=%s version=%s dirty=%s' % (commit, values['VERSION'], dirty))

    if '--print' in sys.argv:
        return 0
    if '--check' in sys.argv:
        if wanted != current:
            print('FAIL: source/BuildInfo.hx is out of date; run python tools/gen_buildinfo.py')
            return 1
        print('OK: source/BuildInfo.hx matches git')
        return 0

    if wanted != current:
        with open(OUT, 'w', encoding='utf-8', newline='') as handle:
            handle.write(wanted)
        print('gen_buildinfo: source/BuildInfo.hx updated')
    else:
        print('gen_buildinfo: source/BuildInfo.hx already up to date')
    return 0


if __name__ == '__main__':
    sys.exit(main())
