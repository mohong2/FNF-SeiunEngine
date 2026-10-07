# source/_online_libs - vendored third-party source

This directory holds a local copy of third-party library source. It is not engine code.

## Why this is a separate classpath root

- `source/online/import.hx` injects wildcard imports (`online.backend.*`, `online.states.*`, ...)
  into the `online` package and every subpackage. Third-party root packages
  (`io` / `tink` / `haxe` / `json2object` ...) must not be polluted by them.
- `source/import.hx` behaves the same way for `source/` and all of its subdirectories: an
  `import.hx` applies to its own directory and every subdirectory, and nested files accumulate.
  It would leak `flixel.FlxG`, `Paths`, and other engine imports into the third-party libraries.
- This directory is therefore its own classpath root and must be declared explicitly in
  `Project.xml`:

  ```xml
  <classpath name="source/_online_libs" />
  ```

  The line is required: with only `<classpath name="source" />`, `import io.colyseus.Client`
  fails with `Type not found : io.colyseus.Client`. Haxe compiles only reachable modules, so
  this classpath has zero impact on builds with online features disabled.

## Package names

Package names are kept exactly as upstream (`io.colyseus.*` / `tink.*` / `json2object.*` ...):
`json2object`, `hxjsonast`, and `colyseus` all resolve types by package-name string inside
macros, so renaming a package would require editing the macro strings as well.

## Sources and versions

Versions are taken from the upstream project's `hmm.json`:

| Directory | Library | Version | Upstream |
|---|---|---|---|
| `io/` `org/` | colyseus | 0.17.3 | https://github.com/colyseus/colyseus-haxe |
| `haxe/net/` | colyseus-websocket | 1.0.15 | dependency of the same repository (pure Haxe, no native code) |
| `tink/` | tink_anon / tink_chunk / tink_core / tink_http / tink_io / tink_macro / tink_streams / tink_stringly / tink_url | 0.7.0 / 0.4.0 / 2.1.1 / 0.10.0 / 0.9.0 / 1.0.4 / 0.4.0 / 0.6.0 / 0.5.0 | nine libraries sharing the top-level `tink` package; merged |
| `json2object/` | json2object | 3.11.0 | |
| `hxjsonast/` | hxjsonast | 1.1.0 | |
| `htmlparser/` | HtmlParser | 3.4.0 | |
| `httpstatus/` | http-status | 1.4.0 | transitive dependency of tink_http |
| `org/msgpack/` | msgpack-haxe | - | transitive dependency of colyseus; msgpack encode/decode for `ROOM_DATA` |

File count: **220 `.hx`** files plus one reference file (`.hx.txt`).
Pure Haxe: native-code counts (`.ndll` / `.dll` / `.lib` / `.a` / `.so` / `.dylib` / `.h` / `.cpp`) are 0.

## Known issue: Haxe 4.3 `??` syntax in the libraries

The upstream library source contains two expressions using the Haxe 4.3 null-coalescing operator:

| File | Line | Expression |
|---|---|---|
| `io/colyseus/serializer/schema/Decoder.hx` | 328 | `? previousValue ?? refs.get(refId)` |
| `io/colyseus/serializer/schema/types/MapSchema.hx` | 135 | `var items = this.items ?? new OrderedMap<String, T>(...)` |

`??` requires Haxe **4.3**. This engine's toolchain requirement is now Haxe **4.3.7**
(minimum 4.3.0; see `README.md`, `USE HAXE 4.3.7.txt` and the CI workflows), but the
**4.2.5 baseline still passes the same type-check** during the migration, so the
deviation below is kept. Haxe 4.2.5 rejects even `p ?? 1` with `Unexpected ?`.

The copies vendored here use the forward-compatible form `x != null ? x : y`, which is valid
under both 4.2.5 and 4.3.x.

## Local deviation: `haxe/net/impl/SocketSys.hx`

The upstream project has two byte-different versions of this file:

| Variant | SHA256 (first 16) | Traits |
|---|---|---|
| **In use** (source project pinned) | `FBCBA31BC98079EC` | L134 `output.writeBytes(data, 0, data.length); // changed line`<br>L24 `this.impl = new sys.ssl.Socket();` (no python branch) |
| Upstream 1.0.15 (kept as reference) | `927595E7F20B7948` | L134 `output.write(data);`<br>has the `#if python` -> `python.net.SslSocket()` branch |

**Why the source-project version is used:** it carries the `// changed line` comment, i.e. a
deliberate author edit (most likely fixing truncated large-packet sends on Windows). The
implementation logic and protocol are unchanged, so the source-project variant is kept.

The reference copy is named `_upstream_ref/SocketSys.upstream-1.0.15.hx.txt`. It has the same
name and package as the active file, but it is not on any module path and is never resolved.

**Revert to the upstream original:**

```powershell
Copy-Item -Force `
  'source\_online_libs\_upstream_ref\SocketSys.upstream-1.0.15.hx.txt' `
  'source\_online_libs\haxe\net\impl\SocketSys.hx'
```

**Why the deviation is safe:** `haxe/net` does not exist in the Haxe standard library
(`C:\HaxeToolkit\haxe\std\haxe\net` is absent), so nothing in the stdlib is shadowed. The
upstream project keeps the same pinned copy under `source/haxe/net/impl/` as well.

## Not vendored

These upstream libraries are intentionally not vendored: `away3d`, `feathersui`
(`online/s3d/**`), `lumod`, `actuate`, `compiletime`, `interpret` (s3d, `online/gui/import.hx`,
`Deflection`), `SScript` (the engine already ships `hscript-seiun`), `yagp` (GIF avatars),
`UnRAR` (used only under upstream's `#if RAR_SUPPORTED`, which this engine does not define),
`grig.audio`, `funkin.vis`, and `hxdiscord_rpc`. No `#if` placeholders are added for them.
