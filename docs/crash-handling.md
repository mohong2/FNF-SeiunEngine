# Crash handling

One fatal-report entry point, four funnels into it, per-platform native dialogs.
Nothing here is allowed to depend on the report being readable by a human: the
file is the record, the dialog is a courtesy.

## Four funnels

| kind | written by | fires when |
|---|---|---|
| `native` | `source/backend/native_crash.inc` | SEH / signal on the Haxe side of the process |
| `haxe` | `source/Main.hx` (`reportCrash`) | an uncaught Haxe exception reaches the top |
| `lime:*` | `.haxelib/lime/git/project/src/utils/FatalReport.cpp` | window / GL / audio / SDL init failed below Haxe |
| `html5` | `source/backend/Html5Fatal.hx` | no native dialog exists; the report goes into the page |

Every report starts with `Kind:`, so a kind is never guessed from the file name.
`diag report` uses the same field.

## Where the symbols are

```
export/symbols/<platform>-<mode>/
    ApplicationMain.map     the link map (Windows/Linux/macOS/tvOS/iOS)
    *.pdb                   when the linker produced one
    build-info.txt          facts for humans
    build.json              the same facts for tools: exe size + PE TimeDateStamp + git commit
    _stale/                 bundles superseded by a later build of the same target
```

The bundle is written by `tools/SymbolsAfterBuild.hx` on **every** `lime build`.
`source/BuildInfo.hx` stamps itself: `source/BuildStampMacro.hx` asks git while
Haxe compiles and inlines the revision, so there is no prebuild to run and no
generated source file to go stale.

Freshness is an identity check, not a date check. A report prints
`Build: 60396032B@1793431505s`; `build.json` records the same size and the same
PE `TimeDateStamp`, both written by the linker. `python tools\crash.py status` compares the
pair; when they differ it prints `STALE` and refuses to resolve frames.

## Commands

    python tools\crash.py               the window (status / report / ui also work)
    python tools\crash.py status        are the symbols from this exact binary?
    python tools\crash.py report <f>    freshness check, then resolve the frames
    python tools\crash.py bundle <f>    report + manifest as one zip
    python tools\crash.py ui            the same verdicts in a bilingual window
    python tools\crash.py prune         drop _stale/ and *.tmp

All of it is one file, `tools/crash.py`; `python tools\crash.py help` lists every
subcommand (resolution, verification, Android symbolization, table generation).

## Encoding rules

The report file is UTF-8 with a BOM; readers must use `utf-8-sig`. Anything that
reads line 1 with a plain `utf-8` decoder sees a BOM and matches nothing - this
is exactly how a valid report once came out as `[unknown]`.

Windows dialogs are UTF-16 (`MessageBoxW`); POSIX dialogs take UTF-8. Never hand
a narrow string to the Windows dialog API: non-ASCII paths and messages turn into
mojibake, and the report path is the one line the user is supposed to copy.

## Language

Lime-layer reports and dialogs are **English only** - that layer fails below
Haxe and its report is read by developers, not by players. The exe side
(`source/backend/native_crash.inc`) stays bilingual, because that is the text a
player sees. Console output is English; `crash.py ui` is English + Chinese, as is the
triage window and `--lang en|zh`.

## Dialogs

| platform | where the box comes from |
|---|---|
| Windows | `MessageBoxW` (UTF-16, no `A` variant anywhere in the exe) |
| Linux | the native dialog the desktop provides; `lime`'s FatalReport covers startup |
| macOS / iOS | `NSAlert` / `UIAlertController` through the ndll |
| Android | an `AlertDialog` on the UI thread; the report is also in logcat |
| HTML5 | no native box: `Html5Fatal.hx` renders the report into the page |

A dialog never blocks the write: the file is flushed and fsynced first, then the
box is shown, then the process exits.

## Testing levers

    set SEIUN_TEST_FATAL=window     # force the lime window funnel at startup
    set SEIUN_TEST_FATAL=sdl_init   # force the SDL init funnel
    set SEIUN_TEST_FATAL=gl         # force the GL funnel

`source/backend/CrashTestHooks.hx` covers the Haxe and native funnels
(`sehProbe()`, `mainThrow()`).

## Known limits

- Only the Windows chain is verified end to end (report -> manifest -> resolution).
  Android/iOS/macOS symbol locations are wired but not re-tested on device.
- Editing `native_crash.inc` alone does not recompile `NativeCrash.cpp`: hxcpp
  tracks the `.cpp` it generated, not the `#include`d `.inc`. Touch the generated
  `.cpp` (or change a Haxe file) before trusting a rebuild.
- `LastError` is `0 (no error was recorded)` when the failure was not an OS call;
  do not read that as "the system said OK".
