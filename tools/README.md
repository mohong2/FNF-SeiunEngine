# tools/

Crash reports are handled by **one file**:

    python tools\crash.py            opens the window (builds + reports)
    python tools\crash.py status     the text report, no window
    python tools\crash.py help       every subcommand

Everything about reports, symbols and symbol generation lives in
`tools/crash.py`. It used to be nine scripts (crash_triage, diag, mapresolve,
verify_map, symbolize_android, gen_linemap, gen_linemap_msvc, linemap_compare,
fnv1a) and the split was the bug: a report could be resolved against a map from
another build and every frame still "resolved", to a real function that was not
the one that crashed.

## Subcommands

| command | answers |
|---|---|
| `crash.py status [--json]` | do the symbols next to each binary belong to that exact binary? |
| `crash.py report <file> [--check-only]` | which build wrote this report, and what do its frames resolve to? |
| `crash.py bundle <file>` | one zip with the report and its manifest |
| `crash.py ui` | the same verdicts in a bilingual (English/Chinese) window |
| `crash.py symbols [--quiet]` | re-publish the bundle for the build that is on disk |
| `crash.py prune [--dry-run]` | delete superseded bundles (`_stale/`, `*.tmp`) |
| `crash.py triage [...]` | the triage engine itself (window UI, `--summary`, `--json`, `--lang en\|zh`) |
| `crash.py resolve <map> <rva...>` | one or more offsets against one linker map |
| `crash.py verify-map <exe> <map>` | prove a .map belongs to an exe |
| `crash.py symbolize <report>` | Android report -> source lines (needs pyelftools) |
| `crash.py linemap <so> <out.bin>` | build the address -> line table from an unstripped .so |
| `crash.py linemap-pdb <exe> <out.bin>` | the same table out of an MSVC PDB |
| `crash.py selm-compare A B` | do two SELM tables describe the same code? |

Exit codes: 0 nothing to do, 1 a problem (stale or missing symbols, failed
check), 2 usage. `report` passes triage's exit code through.

## The invariant: a bundle belongs to one binary

A crash report carries `module + offset`. An offset means nothing without the
link map of the exact link that produced that binary; resolved against any other
map, every frame still resolves, to a real function that is not the one that
crashed. That failure is silent, which is why the freshness check is part of
every path through this file.

| file | location | content |
|---|---|---|
| `ApplicationMain.map` / `.pdb` | `export/symbols/<platform>-<mode>/` | the link byproducts, moved here (not copied) |
| `build.json` | same | machine-readable: exe size, PE `TimeDateStamp`, git commit, artifact list |
| `build-info.txt` | same | the same facts for humans |

`build.json` records `size` and `peStamp`: those two numbers are what a report
prints as `Build: 60396032B@1793431505s`, written into the image by the linker.
`crash.py status` compares the pair against the binary on disk, so "is this map
from this build?" is an integer comparison, not a guess from modification times.

Anything older than the build that just finished is parked in `_stale/`.

## One build, no symbol switch

    haxelib run lime build windows -release

`Project.xml` wires one hook:

    <postbuild haxe="tools.SymbolsAfterBuild" />  publishes map/.pdb + build.json for this build

It is `haxe --interp`, so it needs nothing lime does not already need, and it
cannot fail a build. There is no `-D hxcpp_symbols` and no second "symbol
build".

The revision is not a prebuild any more. `source/BuildStampMacro.hx` runs git
while Haxe compiles and inlines the commit/version/dirty flag into
`source/BuildInfo.hx`, so any `lime build`, IDE build or bare `haxe` call
stamps itself and no checked-in file is rewritten. `SymbolsAfterBuild` reads the
same facts from git after linking.

Consequence: a release report carries `module + offset`, not
`[src/File.cpp:123]`. Inline file:line needed a precomputed table, and the table
changes addresses, so it required generate-then-relink, i.e. a second pass.
`crash.py linemap` / `linemap-pdb` still build that table on demand, and
`Project.xml` documents the one `<assets ... embed="true">` line to re-add; it is
simply not part of a build.

## Credits snapshot

The credits screen fetches GitHub contributors live and falls back to
`assets/preload/data/github_contributors.json` plus the bundled avatars under
`assets/preload/images/credits/github/`. Refresh that fallback after a release or when
the contributor list changes:

    python tools\gen_contributors.py

It reads `GITHUB_TOKEN` / `SEIUN_GITHUB_TOKEN` when present and never forwards the
token to the avatar CDN.

## Files

| file | role |
|---|---|
| `crash.py` | everything above |
| `SymbolsAfterBuild.hx` | `<postbuild>`: files this build's map/.pdb into the symbol store, writes `build-info.txt` + `build.json` |
| `gen_contributors.py` | refreshes the offline GitHub-contributor snapshot and bundled avatars used by the credits screen |

## Where else to read

- `docs/crash-handling.md`: the four funnels, report kinds, encoding rules.
