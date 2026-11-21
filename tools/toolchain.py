#!/usr/bin/env python3
"""Record the C/C++ toolchain that produced this build.

Why this exists
---------------
The binaries a release ships are built on GitHub-hosted runners. The runner
image is not part of this repository, so the compiler is an input nobody
versioned: "windows-latest" moved from Visual Studio 2022 to 2026 and lime's
bundled openal stopped compiling (MSVC 14.5x made copysignf a true intrinsic),
while the same tree still built fine on a developer's machine - which is
running an older toolset. A crash report or a bug that only appears in CI is
unanswerable until you can say which compiler produced the binary.

So every build writes the compiler down:

  toolchain.json     machine readable, merged into build.json by the <postbuild>
                     hook tools/SymbolsAfterBuild.hx, so the published symbol
                     bundle names the toolchain of the binary it describes
  toolchain.txt      one human line, copied into build-info.txt
  toolchain-key.txt  one token identifying the toolchain, hashed into the hxcpp
                     object-cache key: an image upgrade must not reuse objects
                     that a different compiler produced

Run with no arguments. It never fails on a missing probe - an absent compiler
is recorded as "unknown", because a build that cannot describe itself is still
better than a build that does not happen.
"""

import json
import os
import platform
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

VERSION_RE = re.compile(r"(\d+(?:\.\d+)+)")


def run(cmd, timeout: int = 90) -> str:
    """Run a command, returning its combined output; "" when it cannot run."""
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    text = proc.stdout or ""
    if isinstance(text, bytes):  # pragma: no cover - text=True above; belt and braces
        text = text.decode("utf-8", "replace")
    return text.strip()


def first_version(text: str) -> str:
    match = VERSION_RE.search(text or "")
    return match.group(1) if match else "unknown"


def version_tuple(text: str):
    return tuple(int(part) for part in re.findall(r"\d+", text or ""))


def os_version() -> str:
    system = platform.system().lower()
    if system == "darwin":
        return run(["sw_vers", "-productVersion"]) or platform.platform()
    if system == "linux":
        try:
            with open("/etc/os-release", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if line.startswith("PRETTY_NAME="):
                        return line.split("=", 1)[1].strip().strip('"')
        except OSError:
            pass
        return platform.platform()
    edition = getattr(platform, "win32_edition", lambda: "")() or ""
    return ("Windows %s %s" % (edition, platform.version())).strip()


def windows_fingerprint(info: dict) -> None:
    program_files_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    vswhere = os.path.join(program_files_x86, "Microsoft Visual Studio", "Installer", "vswhere.exe")
    compiler = {"family": "msvc", "version": "unknown"}
    info["compiler"] = compiler
    if not os.path.isfile(vswhere):
        return

    # This is the exact query hxcpp's toolchain/msvc64-setup.bat runs, so the
    # fingerprint names the compiler hxcpp will actually invoke rather than any
    # Visual Studio that happens to be installed. It matters more than it looks:
    # vswhere -latest skips instances with isComplete=0, so a machine with a
    # half-installed newer Visual Studio (which is what a dev box usually has)
    # silently keeps compiling with the older one while the CI image does not.
    query = [
        "-latest",
        "-products",
        "*",
        "-requires",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    ]
    install_path = (run([vswhere] + query + ["-property", "installationPath"]).splitlines() or [""])[0].strip()
    install_version = (run([vswhere] + query + ["-property", "installationVersion"]).splitlines() or [""])[0].strip()

    toolset = "unknown"
    tools_dir = os.path.join(install_path, "VC", "Tools", "MSVC") if install_path else ""
    if tools_dir and os.path.isdir(tools_dir):
        candidates = [name for name in os.listdir(tools_dir) if VERSION_RE.match(name)]
        if candidates:
            toolset = max(candidates, key=version_tuple)

    compiler["version"] = toolset
    compiler["vs"] = install_version or "unknown"


def linux_fingerprint(info: dict) -> None:
    info["compiler"] = {
        "family": "gcc",
        "version": first_version(run(["gcc", "--version"])),
        "binutils": first_version(run(["ld", "--version"])),
        "glibc": first_version(run(["ldd", "--version"])),
    }


def darwin_fingerprint(info: dict) -> None:
    # clang is what mac-toolchain.xml drives; Xcode and the SDK decide which
    # headers and linker that clang sees, so all three go in the record.
    xcode = run(["xcodebuild", "-version"]).splitlines()
    info["compiler"] = {
        "family": "clang",
        "version": first_version(run(["clang", "--version"])),
        "xcode": xcode[0].strip() if xcode else "unknown",
        "sdk": run(["xcrun", "--show-sdk-version"]) or "unknown",
    }


def cache_key(info: dict) -> str:
    """One token that changes exactly when the object cache must go cold."""
    compiler = info.get("compiler") or {}
    family = compiler.get("family", "unknown")
    if family == "msvc":
        return "msvc-" + str(compiler.get("version", "unknown"))
    if family == "gcc":
        return "gcc-%s-binutils-%s" % (compiler.get("version"), compiler.get("binutils"))
    return "clang-%s-sdk-%s" % (compiler.get("version"), compiler.get("sdk"))


def human_line(info: dict) -> str:
    compiler = info.get("compiler") or {}
    extra = ""
    if compiler.get("family") == "msvc":
        extra = " (VS %s)" % compiler.get("vs")
    elif compiler.get("family") == "clang":
        extra = " (%s, SDK %s)" % (compiler.get("xcode"), compiler.get("sdk"))
    elif compiler.get("family") == "gcc":
        extra = " (binutils %s, glibc %s)" % (compiler.get("binutils"), compiler.get("glibc"))

    image = info.get("image") or {}
    image_text = " ".join(part for part in (image.get("id"), image.get("version")) if part) or "unknown"
    return "%s %s | %s %s%s | image %s | haxe %s" % (
        info.get("os"),
        info.get("osVersion"),
        compiler.get("family", "unknown"),
        compiler.get("version", "unknown"),
        extra,
        image_text,
        info.get("haxe", "unknown"),
    )


def write(name: str, text: str) -> str:
    path = os.path.join(ROOT, name)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    return path


def main() -> int:
    system = platform.system().lower()
    info = {
        "schema": 1,
        "os": system,
        "osVersion": os_version(),
        "arch": platform.machine(),
        "image": {
            # GitHub sets these on every hosted runner; they are what identifies
            # the image, while the label in the workflow is only an alias.
            "id": os.environ.get("ImageOS", ""),
            "version": os.environ.get("ImageVersion", ""),
        },
        "haxe": first_version(run(["haxe", "--version"])),
    }

    if system == "windows":
        windows_fingerprint(info)
    elif system == "darwin":
        darwin_fingerprint(info)
    else:
        linux_fingerprint(info)

    key = cache_key(info)
    info["cacheKey"] = key

    write("toolchain.json", json.dumps(info, indent=2, sort_keys=True) + "\n")
    write("toolchain.txt", human_line(info) + "\n")
    write("toolchain-key.txt", key + "\n")

    print("toolchain: " + human_line(info))
    print("cache key: " + key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
