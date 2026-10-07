# gen_console_assets.ps1 -- regenerate server/src/online_server/ConsoleWebAssets.hx from server/web/*.
#
# Why this exists: the built-in web console is served at /console by the dedicated server, which
# finds the page in server/web next to server/bin/server.n. The game client hosts the same server
# in-process ("Open to LAN"), where no server/web directory exists at all -- the game export does
# not ship it -- so the three assets are compiled into the server as generated string constants
# and ConsoleWeb falls back to them when the disk copy is missing.
#
# The generated file is checked in. Rerun this script after editing server/web/* so the embedded
# copy cannot drift; the equality probe in temp/console-web/ catches a forgotten rerun.
#
# Chunking (MSVC C2026): a Haxe string constant becomes ONE C++ string literal under hxcpp, and
# MSVC refuses a string literal larger than ~16380 bytes with
#   error C2026: string literal too big, trailing characters truncated
# so a single literal per asset breaks both cpp targets - the dedicated SeiunServer.exe AND the
# game client (lime builds with hxcpp/MSVC), i.e. the in-client LAN host would not build at all.
# Each asset is therefore emitted as several literals joined with the "+" OPERATOR, which hxcpp
# evaluates at run time and MSVC never sees as one literal. Adjacent-literal concatenation
# ("a" "b") is NOT used: the compiler merges those back into a single literal, which would leave
# C2026 unfixed. $ChunkChars below is the per-literal limit and is hard-coded on purpose.
#
# Determinism: the same inputs always produce byte-identical output. Assets are emitted in a fixed
# order, chunk boundaries are a pure function of the input, the file is UTF-8 without BOM with CRLF
# line endings, and nothing (timestamp, user, path) is recorded. Running the script twice gives the
# same SHA-256.
#
# Safety: every control character except CR / LF / TAB fails the run, and so does any non-BMP
# (astral) character -- hxcpp mangles those in string literals, which is why server/web/index.html
# spells the bell as the HTML entity &#128276;. No literal ever spans a line break, and every chunk
# is asserted to sit at or below $ChunkChars after the escaped text is built.
#
# Usage (from the repository root):
#   pwsh -File server/tools/gen_console_assets.ps1
#   pwsh -File server/tools/gen_console_assets.ps1 -WhatIf    # check inputs, print, write nothing

[CmdletBinding()]
param(
    # Repository root. Defaults to the grandparent of this script's directory.
    [string]$RepoRoot,
    # Output file. Defaults to server/src/online_server/ConsoleWebAssets.hx under the root.
    [string]$OutFile,
    # Analyse the assets and print the result without touching the output file.
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# Per-literal source limit. MSVC's C2026 limit is ~16380 bytes for one string literal; 4000 leaves a
# wide margin and keeps the generated file readable. Do not raise this near the MSVC limit.
$ChunkChars = 4000

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$webDir = Join-Path $RepoRoot 'server\web'
if (-not (Test-Path -LiteralPath $webDir)) {
    throw "fatal: $RepoRoot does not look like the repository root (no server/web directory)"
}
if (-not $OutFile) {
    $OutFile = Join-Path $RepoRoot 'server\src\online_server\ConsoleWebAssets.hx'
}

# The embedded set and the Haxe constant each file becomes. Order is part of the output.
$assets = @(
    [pscustomobject]@{ Name = 'index.html'; Const = 'INDEX_HTML'; Note = 'the console page' },
    [pscustomobject]@{ Name = 'app.js';     Const = 'APP_JS';     Note = 'the console script' },
    [pscustomobject]@{ Name = 'style.css';  Const = 'STYLE_CSS';  Note = 'the console stylesheet' }
)

# throwOnInvalidBytes: damaged UTF-8 must fail loudly instead of being silently replaced.
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false, $false)
$nl = "`r`n"

# Escapes one asset into one or more Haxe string literals, each at most $ChunkChars source
# characters long and always ending at a complete escape sequence (a chunk boundary can therefore
# never cut "\n" into "\" + "n").
function ConvertTo-HaxeChunks {
    param([string]$Text, [string]$Source)

    $chunks = [System.Collections.Generic.List[string]]::new()
    $sb = [System.Text.StringBuilder]::new($ChunkChars + 8)
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ([char]::IsHighSurrogate($ch)) {
            if ($i + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) {
                $cp = [char]::ConvertToUtf32($ch, $Text[$i + 1])
                throw ("fatal: {0} contains the astral codepoint U+{1:X} at char index {2}; " +
                       "non-BMP characters cannot be embedded (hxcpp mangles them) -- " +
                       "spell it as an HTML entity such as &#128276; instead") -f $Source, $cp, $i
            }
            throw "fatal: $Source contains a lone high surrogate at char index $i"
        }
        if ([char]::IsLowSurrogate($ch)) {
            throw "fatal: $Source contains a lone low surrogate at char index $i"
        }

        $code = [int]$ch
        $piece = $null
        switch ($code) {
            9   { $piece = '\t' }
            10  { $piece = '\n' }
            13  { $piece = '\r' }
            34  { $piece = '\"' }
            92  { $piece = '\\' }
            default {
                if ([char]::IsControl($ch)) {
                    throw ("fatal: {0} contains the control character U+{1:X4} at char index {2}; " +
                           "only CR, LF and TAB can be escaped into the generated literal") -f $Source, $code, $i
                }
                $piece = [string]$ch
            }
        }

        # Close the current literal before it could pass the MSVC limit. $piece is at most 2 chars,
        # so the new chunk always fits (the guard below would fire on a mis-set $ChunkChars).
        if ($sb.Length + $piece.Length -gt $ChunkChars) {
            if ($sb.Length -eq 0) {
                throw "fatal: cannot split $Source at char index $i with a $ChunkChars-character chunk limit"
            }
            $chunks.Add($sb.ToString())
            [void]$sb.Clear()
        }
        [void]$sb.Append($piece)
    }
    $chunks.Add($sb.ToString())
    return $chunks
}

# Inverse of the escaping above, used to assert that joining the chunks reproduces the source text
# exactly (an escape split across a chunk boundary would show up here).
function ConvertFrom-HaxeChunks {
    param([string[]]$Chunks)

    $s = $Chunks -join ''
    $sb = [System.Text.StringBuilder]::new($s.Length)
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($c -ne '\') {
            [void]$sb.Append($c)
            continue
        }
        $i++
        if ($i -ge $s.Length) {
            throw 'fatal: a generated literal ends inside an escape sequence'
        }
        switch ($s[$i]) {
            't' { [void]$sb.Append([char]9) }
            'n' { [void]$sb.Append([char]10) }
            'r' { [void]$sb.Append([char]13) }
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            default { throw "fatal: unexpected escape sequence in a generated literal" }
        }
    }
    return $sb.ToString()
}

$entries = @()
foreach ($a in $assets) {
    $path = Join-Path $webDir $a.Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "fatal: missing asset $path"
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $text = $utf8Strict.GetString($bytes)

    # Byte-identity guard: what the literals hold must re-encode to exactly the bytes on disk,
    # CRLF included. This is the same equality the probe in temp/console-web/ re-checks at runtime.
    $roundTrip = $utf8Strict.GetBytes($text)
    if ($roundTrip.Length -ne $bytes.Length) {
        throw "fatal: $path did not survive the UTF-8 round-trip ($($bytes.Length) -> $($roundTrip.Length) bytes)"
    }
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($roundTrip[$i] -ne $bytes[$i]) {
            throw "fatal: $path byte $i changed during the UTF-8 round-trip"
        }
    }

    $chunks = @(ConvertTo-HaxeChunks -Text $text -Source $a.Name)

    # Every emitted literal must stay below the MSVC limit, and joining them must give the text back.
    foreach ($c in $chunks) {
        if ($c.Length -gt $ChunkChars) {
            throw "fatal: $($a.Name) emitted a literal of $($c.Length) characters; the limit is $ChunkChars"
        }
        if ($c.Length -eq 0) {
            throw "fatal: $($a.Name) emitted an empty literal"
        }
    }
    if ((ConvertFrom-HaxeChunks -Chunks $chunks) -cne $text) {
        throw "fatal: $($a.Name) does not survive the literal round-trip (escaping or chunking lost bytes)"
    }

    $entries += [pscustomobject]@{
        Name    = $a.Name
        Const   = $a.Const
        Note    = $a.Note
        Bytes   = $bytes.Length
        Chunks  = $chunks
        Sha256  = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
    }
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('// GENERATED FILE -- do not edit by hand.')
$lines.Add('// Regenerate with:  pwsh -File server/tools/gen_console_assets.ps1')
$lines.Add('//')
$lines.Add('// The built-in web console (server/web/{index.html,app.js,style.css}) is compiled into the')
$lines.Add('// server so /console also works where no server/web directory exists next to the process:')
$lines.Add('// the game client hosts this server in-process for "Open to LAN" and never ships server/web.')
$lines.Add('// ConsoleWeb serves server/web first when it is there (live editing keeps working) and falls')
$lines.Add('// back to these constants otherwise.')
$lines.Add('//')
$lines.Add('// Each asset is several Haxe string literals joined with the "+" OPERATOR. MSVC refuses one')
$lines.Add('// C++ string literal larger than ~16380 bytes (error C2026 "string literal too big, trailing')
$lines.Add('// characters truncated"), and hxcpp emits a Haxe string constant as one such literal, so a')
$lines.Add('// single literal per asset breaks the cpp targets - the dedicated SeiunServer.exe and the')
$lines.Add('// game client itself (lime builds with hxcpp/MSVC). "+" concatenates at run time; adjacent')
$lines.Add('// literals ("a" "b") would be merged back into one literal by the compiler and would NOT')
$lines.Add('// fix C2026. Each literal holds at most 4000 source characters.')
$lines.Add('//')
$lines.Add('// Only the escapes \\ \" \r \n \t appear inside a literal, so no raw control character or')
$lines.Add('// literal newline can hide in the generated code. The bytes are identical to the files on disk')
$lines.Add('// (CRLF included); the equality probe in temp/console-web/ re-checks that at runtime.')
$lines.Add('//')
foreach ($e in $entries) {
    $lines.Add(('// {0}  {1} bytes  {2} literal(s)  sha256 {3}' -f $e.Name, $e.Bytes, $e.Chunks.Count, $e.Sha256))
}
$lines.Add('package online_server;')
$lines.Add('')
$lines.Add('class ConsoleWebAssets {')

for ($n = 0; $n -lt $entries.Count; $n++) {
    $e = $entries[$n]
    $lines.Add(('	/** server/web/{0} ({1}) -- {2} bytes in {3} literal(s) joined with "+". */' -f $e.Name, $e.Note, $e.Bytes, $e.Chunks.Count))
    if ($e.Chunks.Count -eq 1) {
        $lines.Add(('	public static var {0}:String = "{1}";' -f $e.Const, $e.Chunks[0]))
    } else {
        $lines.Add(('	public static var {0}:String = "{1}"' -f $e.Const, $e.Chunks[0]))
        for ($k = 1; $k -lt $e.Chunks.Count - 1; $k++) {
            $lines.Add(('		+ "{0}"' -f $e.Chunks[$k]))
        }
        $lines.Add(('		+ "{0}";' -f $e.Chunks[$e.Chunks.Count - 1]))
    }
    if ($n -lt $entries.Count - 1) {
        $lines.Add('')
    }
}

$lines.Add('')
$lines.Add('	/** Relative names of the embedded assets, in the order ConsoleWeb looks them up. */')
$lines.Add('	public static function names():Array<String> {')
$lines.Add(('		return [{0}];' -f (($entries | ForEach-Object { '"' + $_.Name + '"' }) -join ', ')))
$lines.Add('	}')
$lines.Add('')
$lines.Add('	/** The embedded asset with this exact relative name, or null when there is none. */')
$lines.Add('	public static function lookup(name:String):Null<String> {')
$lines.Add('		return switch (name) {')
foreach ($e in $entries) {
    $lines.Add(('			case "{0}": {1};' -f $e.Name, $e.Const))
}
$lines.Add('			default: null;')
$lines.Add('		}');
$lines.Add('	}')
$lines.Add('')
$lines.Add('	/** Number of embedded assets; a build without them would report 0 and adapt its 404 text. */')
$lines.Add(('	public static inline function count():Int return {0};' -f $entries.Count))
$lines.Add('}')

$content = ($lines -join $nl) + $nl
$contentSha = [System.Security.Cryptography.SHA256]::Create()
try {
    $contentHash = ($contentSha.ComputeHash($utf8NoBom.GetBytes($content)) | ForEach-Object { $_.ToString('x2') }) -join ''
} finally {
    $contentSha.Dispose()
}

foreach ($e in $entries) {
    Write-Host ('[gen_console_assets] {0,-10} {1,7} bytes  {2,3} literal(s)  max {3,4} chars  sha256 {4}' -f $e.Name, $e.Bytes, $e.Chunks.Count, (($e.Chunks | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum), $e.Sha256)
}
Write-Host ('[gen_console_assets] chunk limit {0} source characters (MSVC C2026)' -f $ChunkChars)
Write-Host ('[gen_console_assets] -> {0}' -f $OutFile)
Write-Host ('[gen_console_assets] generated {0} bytes  sha256 {1}' -f $utf8NoBom.GetByteCount($content), $contentHash)

if ($WhatIf) {
    Write-Host '[gen_console_assets] -WhatIf: nothing written'
    exit 0
}

$current = $null
if (Test-Path -LiteralPath $OutFile) {
    $current = $utf8NoBom.GetString([System.IO.File]::ReadAllBytes($OutFile))
}
if ($current -ne $null -and $current -eq $content) {
    Write-Host '[gen_console_assets] unchanged'
    exit 0
}

[System.IO.File]::WriteAllText($OutFile, $content, $utf8NoBom)
Write-Host '[gen_console_assets] written'
