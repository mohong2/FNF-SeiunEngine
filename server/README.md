# SeiunEngine Online Server

A Colyseus-compatible game server written in **Haxe** and compiled either to **neko** (default) or
to a standalone native **hxcpp** executable. It serves SeiunEngine's online mode: rooms, song
selection, per-player state sync, scoring and the session lifecycle (reconnect, ping, IP lock).

It has no Node.js / TypeScript / `colyseus-server` dependency. HTTP, WebSocket, the Colyseus frame
format and schema PATCH encoding are all implemented in this repository; persistence is **SQLite**,
reached through Haxe's `sys.db.Sqlite` (neko ships `sqlite.ndll`, hxcpp links its bundled
sqlite). The requirements are **Haxe 4.3.7** (4.3.0 minimum), **neko** and, for the native target,
**hxcpp + a C++ toolchain**.

Ports: HTTP **2567** (matchmaking + REST), WebSocket **2568** (room connections).

## Quick start

```powershell
# 1) Build. The script locates the repository root itself.
#    Output: server/bin/server.n and server/bin/server.exe
powershell -NoProfile -File server/build.ps1

#    Native hxcpp target:  powershell -NoProfile -File server/build.ps1 -Target cpp
#                          -> server/bin/SeiunServer.exe (standalone, no neko needed)
#    Both targets:         powershell -NoProfile -File server/build.ps1 -Target both
#    Types only:           powershell -NoProfile -File server/build.ps1 -TypeCheck

# 2) Run. Default is foreground: live logs, Ctrl+C stops.
powershell -NoProfile -File server/start.ps1

#    Detached:   powershell -NoProfile -File server/start.ps1 -Background
#    Double-click launcher: server/start.cmd (pauses on exit, does not close instantly)

# 3) Health check / stop
powershell -NoProfile -File server/start.ps1 -Status
powershell -NoProfile -File server/start.ps1 -Stop
```

### Build output

* `server/bin/server.n` - the neko artifact (default target).
* `server/bin/server.exe` - optional launcher produced by `build.ps1` via `nekotools boot`, wrapping
  the `.n` inside a `neko.exe` shell. It can be started by double-click or with `start.ps1 -Exe`,
  but it is **not self-contained**: the machine still needs the Haxe/neko toolchain (in particular
  `neko` on `PATH`), otherwise it exits immediately. Skip it with `server/build.ps1 -NoBoot`.
* `server/bin/SeiunServer.exe` - **standalone native executable** built by the hxcpp target
  (`server/server-cpp.hxml`, `build.ps1 -Target cpp`). It needs no Haxe/neko runtime on the target
  machine, only the OS. The hxcpp build compiles the C++ runtime the first time, so expect a few
  minutes for the first build and seconds afterwards; run only one hxcpp/lime build per machine at a
  time. Intermediate C++ lives in `server/bin/cpp/` (gitignored).

Artifacts, pid and logs all live under `server/`: `server/bin/server.n`, `server/bin/server.exe`,
`server/logs/p5_server.pid`, `server/logs/p5_server.out.log`, `server/logs/p5_server.err.log`, and
`server/bin`, `server/logs` and `server/data` are gitignored.

### Manual equivalents

```powershell
$env:HAXELIB_PATH = (Get-Location).Path + '\.haxelib'
haxe server/server.hxml                                          # -> server/bin/server.n
& 'C:\HaxeToolkit\neko\nekotools.exe' boot server/bin/server.n   # optional -> server/bin/server.exe
server\bin\server.exe                                            # run the exe (foreground; Ctrl+C stops)
& 'C:\HaxeToolkit\neko\neko.exe' server/bin/server.n             # run the .n (foreground; Ctrl+C stops)

haxe server/server-cpp.hxml                                      # -> server/bin/SeiunServer.exe
server\bin\SeiunServer.exe                                       # native run (foreground; Ctrl+C stops)
haxe server/server.hxml --no-output; haxe server/server-cpp.hxml --no-output   # typecheck only
```

### build.ps1 parameters

| Parameter | Meaning |
|---|---|
| _(none)_ | neko target: `server/server.hxml` -> `server/bin/server.n` (+ `server.exe`). |
| `-Target neko\|cpp\|both` | Which target(s) to build. Default `neko`, so existing invocations are unchanged. |
| `-TypeCheck` | `--no-output` type check of the selected target(s); nothing is written. |
| `-NoBoot` | neko only: skip `nekotools boot` (no `server.exe`). |

For `-Target cpp` the script reports the produced `server/bin/SeiunServer.exe` and its size; a
missing C++ toolchain makes haxe fail, and the script prints the raw exit code.

### start.ps1 parameters

| Parameter | Meaning |
|---|---|
| `-Lan` | Bind `0.0.0.0` (LAN play). |
| `-BindHost <ip>` | Bind address explicitly (takes priority over `-Lan`). |
| `-HttpPort <n>` / `-WsPort <n>` | Override the default ports. |
| `-NoBuild` | Skip compilation and run the existing `server.n` (or `server.exe` with `-Exe`). |
| `-Exe` | Run `server/bin/server.exe` instead of `neko server/bin/server.n`; flags, ports, logs and pid are identical. Prints a hint to run `build.ps1` if the exe is missing. |
| `-Background` | `Start-Process` with pid file and separate `out.log` / `err.log`; suitable for scripts and CI. |
| `-AdminEmail <email>` | Forwarded as `--admin-email`: that account becomes a console administrator. |
| `-DataDir <dir>` | Forwarded as `--data-dir`: replace the runtime data directory. |
| `-Status` | Print `pid=... http=... ws=... onlinecount=...`. |
| `-Stop` | Stop by pid; if the pid file is gone, fall back to processes whose command line matches this server and the same `--http-port`, so instances on other ports are not killed. |

Startup pre-checks ports 2567/2568. If one is already in use the script prints
`port <n> is already in use on 127.0.0.1 -- ... (-Status / -Stop)` and exits, instead of letting
neko raise a raw bind error or overwriting a log that is still being written.

### Server flags

| Flag | Default | Meaning |
|---|---|---|
| `--host <ip>` | `127.0.0.1` | Bind address. Use `0.0.0.0` for LAN play. |
| `--http-port <n>` | `2567` | Matchmaking / REST port. |
| `--ws-port <n>` | `2568` | Room WebSocket port. |
| `--public-host <ip>` | HTTP `Host` echo | Address advertised to clients, overriding the `Host` header echo. Useful behind NAT or with multiple interfaces. |
| `--disable-ip-lock` | off | Disable the "at most N sessions per IP" rule. Needed to run several clients from one machine. |
| `--ip-lock-limit <n>` | `4` | Session cap per IP. |
| `--disable-reconnect-guard` | off | Disable the reconnect-storm guard (more than 12 attaches from one session within 5 s is rejected and the session is removed). |
| `--reconnect-limit <n>` | `12` | Attach cap for the storm guard (fixed 5 s window). |
| `--data-dir <dir>` | `server/data` | Data directory: holds `seiun.sqlite3`, `config.toml`, `images/` and `mail.log`. |
| `--admin-email <email>` | none | The account with this e-mail automatically gets `["*"]` access (`/api/admin/*`, `/api/console/*`). |
| `--console-local-readonly` | off | Serve `GET /api/console/*` to **loopback peers only** without a credential (the embedded LAN host uses this; it has no admin account). Writes and non-loopback peers still go through the normal four-step `requireAccess` check. |
| `--fixture-dir <dir>` | none | Dump every outbound frame's hex here (wire-format regression fixtures). |
| `--smtp-host <host>` | none | SMTP host. Mail is only sent when this and `--smtp-mail` are both set; otherwise verification codes are appended to `<data-dir>/mail.log`. |
| `--smtp-port <n>` | `25` | SMTP port. Only implicit TLS (465) is usable; 587 STARTTLS is not available in the Haxe standard library. |
| `--smtp-user <user>` | none | SMTP user (may be empty for anonymous relay). |
| `--smtp-pass <pass>` | none | SMTP password. |
| `--smtp-mail <from>` | none | Envelope sender. Required together with `--smtp-host`. |
| `--auth-ttl-minutes <n>` | `[auth]` then `43200` | Credential lifetime in minutes. `0` means never expires. When given on the command line the value is also pinned (`ttl_locked`). |
| `--ng-app-id <id>` | none | Newgrounds gateway app id. Without it `/api/account/link/newgrounds` returns 400. |
| `--discord-webhook <url>` | none | Outbound mirror for network-room chat. Without it the mirror is a no-op. |
| `--log-dir <dir>` | `server/logs` | Directory for the structured JSON Lines log (`server-YYYYMMDD.jsonl`). |
| `--log-level <level>` | `info` | `debug` \| `info` \| `warn` \| `error`; filters the structured log only. |
| `--import-legacy-json` | off | Re-run the JSON -> SQLite import from scratch (see "Legacy JSON import"). Refuses to run when the database holds data this importer did not create. |

## Directory layout

```
server/
+-- README.md            this file
+-- server.hxml          canonical neko compilation entry (-cp server/src + source + source/_online_libs)
+-- server-cpp.hxml      hxcpp compilation entry -> server/bin/SeiunServer.exe
+-- build.ps1            one-shot build (-Target neko|cpp|both; -TypeCheck; -NoBoot)
+-- start.ps1            run (foreground by default; -Exe runs the booted exe) / health check / stop
+-- start.cmd            double-click launcher
+-- bin/                 build output (gitignored)
+-- logs/                pid + logs + structured server-YYYYMMDD.jsonl (gitignored)
+-- data/                runtime data: seiun.sqlite3 + config.toml + images/ + mail.log (gitignored)
+-- web/                 web console front end (index.html, style.css, app.js)
+-- src/online_server/   server sources
+-- src/online_server/db/  storage layer: Sqlite.hx, Db.hx, Migrations.hx, *Repo.hx, LegacyImport.hx
```

The compilation closure is this directory plus `source/online/backend/schema/**` (the Colyseus
schema classes shared with the client) and `source/_online_libs/**` (`io.colyseus.*`,
`org.msgpack.*`). The client build does not compile the server: `-main online_server.Main` appears
only in `server/server.hxml` and `server/server-cpp.hxml`.

## Storage (`--data-dir`, default `server/data`)

Accounts, leaderboard, clubs, mods, admin data and the public counters live in **SQLite**
(`sys.db.Sqlite`, available on both neko and hxcpp). There is no whole-document JSON rewrite
anymore: each mutation is a single-row `UPDATE`/`INSERT`/`DELETE` inside one transaction, and the
connection runs with `journal_mode=WAL`, `busy_timeout=5000` and `synchronous=NORMAL`.

| Path | Purpose |
|---|---|
| `seiun.sqlite3` (+ `-wal`, `-shm`) | The database. Schema version is tracked with SQLite's `user_version` (`db/Migrations.hx`); `/api/health` reports it. |
| `config.toml` | Console-managed runtime configuration (see below). Still TOML, not SQLite. |
| `images/` | One binary file per avatar / background (`ImageStore`), unchanged by the migration. |
| `mail.log` | Outbox for verification codes and outbound mail, appended to on every send attempt. |
| `*.json.imported-<epoch-ms>` | Legacy JSON files, kept after import (see below). Never deleted. |
| `backups/` | Config snapshots (`config-<epoch-ms>.toml`) written before each save. |

### Tables

`meta` (key/value: schema-independent settings, counters, the credential HMAC key, the import
marker), `accounts`, `sessions`, `scores`, `comments`, `reports`, `clubs`, `mods`, `warns`,
`admin_logs`, `front_messages`, `day_players`, `public_state`.

Scalars are typed columns so SQLite can index, order and compare them (`idx_accounts_email`,
`idx_scores_player`, `idx_clubs_tag`, ...). List-valued fields that are never queried
element-wise -- `access`, `notifications`, `friends`, `friend_requests`, `ips`, club
`members`/`pending`/`leaders`, mod `keywords`/`images`/`favorited`/`downloads` -- are stored as
JSON arrays in TEXT columns, which keeps the exact legacy shape without a join per read.

### Credentials and sessions

* A credential is a **session**: login/register/refresh inserts a row into `sessions` and deletes
  the account's previous rows, so the old token stops working immediately. `accounts.current_session_id`
  points at the active one and gives the account projection its `tokenIssuedAt` / `tokenExpiresAt` /
  `tokenTtlMinutes` values.
* Only `HMAC-SHA256(installation key, token)` and an 8-character lookup prefix are stored. The
  plaintext token exists in memory only for the response that issued it.
* Comparison is constant-time (`Crypto.equals`). The installation key lives in `meta`
  (`auth.secret`), generated on first start.
* Verification codes are hashed with the same key; the plaintext copy only ever goes to
  `mail.log` / SMTP, which is the delivery channel.
* Honest boundary: the key sits in the same database, so this protects against a leaked row or a
  log dump, not against an attacker who already has the whole file. It is a self-hosted,
  single-process server, and the trade-off is stated rather than implied.

### Randomness

Tokens and ids come from `Crypto` (`server/src/online_server/Crypto.hx`). It prefers
`/dev/urandom`; where that device does not exist (Windows) Haxe offers no OS CSPRNG binding for
neko/cpp, so it falls back to an **HMAC-SHA256 DRBG** seeded from a mixed entropy pool
(high-resolution clock, process/thread data, working directory, environment, a monotonic counter
and earlier output). That fallback is not a hardware CSPRNG and `/api/health` reports it as
`entropy: "hmac-sha256-drbg"` (versus `"os-urandom"`).

### Legacy JSON import

On first start, when every legacy table is still empty and at least one of `accounts.json`,
`leaderboard.json`, `admin.json`, `clubs.json`, `mods.json`, `public.json` exists in the data
directory, the server imports it automatically:

1. everything runs in one transaction; a failure rolls back, aborts startup and leaves the JSON
   files untouched (no silent data loss);
2. `seq` counters are taken from the legacy documents (`accounts.seq`, `leaderboard.seq`,
   `admin.seq`, `clubs.seq`), so newly generated `uN`/`sN`/`cN`/`wN`/`rN` ids cannot collide;
3. plaintext account tokens are hashed and stored as each account's first session, so existing
   logins keep working after the migration;
4. after COMMIT each source file is renamed to `<name>.imported-<epoch-ms>` -- user data is never
   deleted;
5. a summary (per-file byte sizes, row counts, timestamps) is written to `meta.legacy.source`.

`--import-legacy-json` re-runs the import from scratch: it clears the rows a previous import
created and imports again. If the database holds data this importer did not create, it refuses to
run and tells the operator to move the database aside first.

## Configuration file (`<data-dir>/config.toml`)

```toml
[server]
announcement = ""
ip_lock = true
ip_lock_limit = 4
reconnect_guard = true
reconnect_limit = 12
max_clients = 6

[smtp]                 # optional; only host + from enable outgoing mail
host = ""
port = 25
user = ""
pass = ""
from = ""
ssl = false            # implicit TLS; 465 only

[auth]
ttl_minutes = 43200    # 0 = never expires
ttl_locked = false     # true ignores the minutes requested by the client

[permissions]
member = [ "/api/sez", "/api/account/*", ... ]
helper = [ ... ]
moderator = [ ... ]
admin = [ "*" ]
banned = [  ]
```

* **Priority.** Command-line flags win at startup; a console save takes effect immediately. When a
  value is absent the code default applies.
* A missing file means all code defaults and the `[permissions]` table is left untouched.
* `[permissions]` overrides role access; roles that are not listed keep their code defaults. `admin`
  is the root role (`["*"]`).
* Values are clamped on load: `max_clients` 1-64, `ip_lock_limit` 1-1024, `reconnect_limit`
  1-10000, `ttl_minutes` 0-525600.
* Every save first copies the previous effective file into `<data-dir>/backups/`, then writes a
  temporary file and renames it into place.

## HTTP surface

| Area | Endpoints |
|---|---|
| Matchmaking | `/matchmake/create`, `/matchmake/joinOrCreate`, `/matchmake/joinById`, `/matchmake/reconnect/<roomId>` |
| Rooms | `/rooms/room` (room list with full metadata), `/api/onlinecount`, `/api/config` |
| Health | `GET /api/health` -- read-only: `status`, `uptime`, `rooms`, `version`, `dbSchemaVersion`, `dbPath` (plus `publicRooms`, `online`, `protocol`, `engine`, `dbJournalMode`, `dbCounts`, `entropy`, `logPath`). Added endpoint; no existing response shape changed. |
| Auth | `/api/auth/register`, `/api/auth/login`, `/api/auth/refresh`, `/api/auth/cookie`, `/api/auth/logout` |
| Account | `/api/account/me`, `/rename`, `/email/set`, `/delete`, `/friends`, `/notifications`, `/info`, `/profile/set`, `/resetsecret`, `/club`, `/avatar`, `/background`, `/removeimages`, `/link/newgrounds`, `/unlink/newgrounds` |
| Clubs | `/api/club/details`, `/pending`, `/create`, `/join`, `/accept`, `/reject`, `/kick`, `/promote`, `/demote`, `/leave`, `/edit`, `/banner` |
| Users | `/api/user/info`, `/friends/request`, `/friends/remove`, `/details`, `/scores` |
| Mods | `/api/mod/dl/submit`, `/dl/edit`, `/dl/delete`, `/fav`, `/submit`, `/edit`, `/delete` |
| Search | `/api/search/mods`, `/songs`, `/users` |
| Public data | `/api/sezdetal`, `/api/online`, `/api/nextweekreset`, `/api/front` (also returns the current `announcement`), `/api/sez`, `/api/song/comment`, `/api/song/comments` |
| Scores / tops | `/api/score/submit`, `/report`, `/replay`, `/delete`, `/set/modurl`, `/api/top/song`, `/api/top/players`, `/api/top/clubs` |
| Stats | `/api/stats/day_players`, `/api/stats/country_players` |
| Admin | `/api/admin/*` (songs, users, clubs, players, reports, logs, cooldown, weekly reset); requires `["*"]` |
| Console | `/api/console/*` (see the web console section) |

`/matchmake/reconnect/<roomId>` reuses the old session from the token and returns the same seat
reservation (body `{reconnectionToken}`). Sessions that were kicked, left voluntarily or timed out
get 400. `/api/config` is a read-only snapshot of the effective constants: `maxClients`,
`ipLock`, `maxSessionsPerIp`, `reconnectWindow`, `pingInterval`, `reconnectGuard`,
`reconnectLimit`, `reconnectStormWindow`, `networkRoomId`, `networkProtocol` and `auth`.
`GET /api/health` is the operational counterpart: it needs no authentication, never writes, and
reports the database file, schema version, journal mode, per-table row counts and which entropy
source the process is using.

### Announcements

`POST /api/console/announce` (console, needs write access) stores the text as
`[server] announcement = "..."` in `<data-dir>/config.toml`, pushes it to every acked connection of
the network room as a `notification` frame (the response reports how many received it as `sent`), and
the stored value is also returned by `GET /api/front` as `announcement`, so a player who was not
connected when it was published still sees the current announcement in the online menu. Unset -> `""`.
The push and the stored value are independent: a restart does not re-broadcast.

Announcement and message caps count UTF-8 **codepoints**, never bytes: a CJK or emoji payload can no
longer be cut mid-character (which used to write invalid UTF-8 into `config.toml`, broadcast a broken
frame and make `/api/console/status` fail until the config was re-saved). A value damaged by an older
build is repaired when the config is loaded, and a failed `config.toml` write now returns an error
instead of a false `200`.

### Text encoding guarantee

Every user-supplied text field (account name/bio/email, club name and content, mod title/description,
song comments, warn reasons, notifications, front messages) is normalised **when it is written** and
repaired again **when it is read**, so a row damaged by an older build (or written directly into
SQLite by an external tool) is still served as valid UTF-8. The validation is strict: overlong
encodings (`C0 80`, `E0 80 80`, `F0 80 80 80`), UTF-8-encoded surrogates (`ED A0 .. ED BF`), code
points above U+10FFFF, orphan/truncated continuations and NUL are all rejected, while a CESU-8
surrogate pair (what some JSON encoders emit for an emoji) is folded back into the real codepoint.
Both JSON funnels (`Api.json`, `ConsoleApi.json`) pass every response through the same repair, so no
endpoint can return a body that is not valid UTF-8.

On the hxcpp build (`SeiunServer.exe`) `haxe.Json.stringify` renders astral characters as U+FFFD, so
the JSON encoder there substitutes a JSON surrogate-pair escape and the real emoji comes back to the
client. Note that hxcpp may decode a **raw** (non-escaped) invalid request body leniently before the
server code sees it; JSON-escaped client bodies, which is what real clients send, are handled exactly,
and the on-disk / echoed-body guarantee holds either way.

## Room protocol

The game room handles 36 explicit message cases in `RoomLogic.handle`; anything else falls through
to a generic forward.

* Song / chart: `setSong`, `setStage`, `verifyChart`
* Round start: `playerReady`, `startGame`, `playerEnded`, `requestEndSong`
* Scoring: `addScore`, `addHitJudge`, `addMiss`, `updateMaxCombo`, `updateSongFP`, `updateFP`
* State: `status`, `noteHold`, `botplay`, `updateHealth`, `pong`
* Room switches: `togglePrivate`, `toggleNetworkOnly`, `anarchyMode`, `togglePlayersCanChoose`,
  `toggleGF`, `toggleSkins`, `swapSides`, `teamMode`, `royalMode`, `royalModeDadSide`
* Win condition: `nextWinCondition` (cycles 0..4; host or `anarchyMode`)
* Pause policy: `nextPauseMode` (cycles 0..2; host or `anarchyMode`) + `pauseGame` / `resumeGame`.
  `Room.pauseMode`: 0 = host only (pausing freezes everyone else too), 1 = anyone (default),
  2 = legacy local pauses. The server arbitrates: it echoes `pauseGame` to everyone including the
  sender (so two simultaneous requests settle), only the pause owner (or the host in mode 0) may
  `resumeGame`, and the pause is released automatically when its owner leaves or a round resets.
* Chat / skins / targeting: `chat` (broadcasts `log`), `command` (`/roll`, `/help`, `/kick`),
  `notifyInstall`, `setSkin`, `updateNoteSkinData`, `custom`, `customTo`

**Generic forwarding** (`RoomLogic.forward`) broadcasts a message under the same name to everyone
else in the room, excludes the sender and appends the sender's sid. Purely forwarded messages such
as `noteHit`, `noteMiss`, `strumPlay` and `charPlay` work through this path.

The `network` lobby room has the fixed id `0` and implements `chat`, `loggedMessagesAfter`
(answers `batchLog`, a JSON array string, latest 100 messages kept in memory), `inviteplayertoroom`
(target receives `roominvite`, sender receives `notification`) and `pong`. It is pre-registered
and never swept, and it does not appear in `/rooms/room`. Identity comes from the join option
`name` (falling back to `networkId`, then `sessionId`); there is no account lookup.

### Lifecycle semantics

* `checkChart` fires once immediately after a new player's ack and once one second later; this is
  what triggers the client's chart / mod validation.
* When the host leaves, `host` moves to the first remaining player and a patch is broadcast.
* A network drop in a game room keeps the session and the player for 20 seconds.
  `POST /matchmake/reconnect/<roomId>` looks the session up by token and returns the same seat
  reservation; the WebSocket reconnect validates the token, binds the existing session and resends
  the full state. Kicked / voluntarily-left / expired sessions cannot reconnect (HTTP 400 or WS 4010).
* Leave (voluntary, kicked, or non-game room) calls `removePlayer` immediately: it broadcasts
  `log "<name> has left the room!"`, sets `isReady = false` for everyone when the round has not
  started, emits map DELETE patches and re-packs `ox`. Empty rooms are swept.
* `ping` is broadcast every 3 seconds. A client `pong` writes the RTT into `Player.ping` (and into
  `metadata.ping` for the host). No pong for 60 seconds or no activity for 20 minutes results in a kick.
* At most 4 sessions per IP across all rooms; change the cap with `--ip-lock-limit`, disable with
  `--disable-ip-lock`.
* `maxClients = 6`; `isPrivate` defaults to `true` on the first frame.
* The reconnect-storm guard removes a session and closes it with WS 4010 when the same session
  attaches more than 12 times within 5 seconds. `--disable-reconnect-guard` and
  `--reconnect-limit <n>` adjust this. Normal play reconnects once or twice, so it never trips.
* Room ids are 4 uppercase letters with a uniqueness check.
* `/rooms/room` items carry top-level `clients` / `maxClients` plus
  `metadata.{name,clients,maxClients,points,verified,ping,networkOnly}`.
* `publicAddress` echoes the HTTP `Host` header (port stripped, `--ws-port` appended) and can be
  overridden with `--public-host`.

Two deliberate design decisions: `removePlayer` does **not** restart the game itself, because
starting a round is driven by the client's `startGame` message; and the business `ping` broadcast
only targets game rooms, so rooms opened by a client that sends no engine handshake are left alone.

## Web console

The server ships a dependency-free dark web console on the same process and HTTP port (default 2567):

```
http://<host>:2567/console
```

* **Sign in** with an existing account through `/api/auth/login` (e-mail + verification code; without
  `--smtp-*` configured the code is written to `<data-dir>/mail.log`), or paste an `id` / `token`
  directly. Authorization is decided by the server: only accounts with `["*"]` (for instance the one
  named by `--admin-email`) pass the four-step `requireAccess` check. The page performs no
  authorization of its own.
* **Read-only panels**: overview (version, uptime, memory, HTTP/WS counters, store entry counts),
  room and player snapshots, accounts / leaderboard / clubs / mods / comments, the action log and
  the tail of the server log, and the effective configuration.
* **Writable**: the `[server]` limits in `config.toml` (IP lock switch and cap, reconnect guard and
  cap, room capacity, announcement), `[smtp]` mail settings (host, port, user, pass, from, ssl;
  plain or implicit TLS on 465, after which codes are really sent - 587 STARTTLS is unavailable, so
  QQ / 163 / Gmail need 465 + SSL), and the `[permissions]` role table. Actions:
  `POST /api/console/kick`, `POST /api/console/room/close`, `POST /api/console/announce`,
  `POST /api/console/mod/delete`, `POST /api/console/account/revoke`. Ban, cooldown and weekly
  reset reuse the existing `/api/admin/*` endpoints.
* **Write cooldowns**: every write endpoint spends a named 1-3 s cooldown (a rejected call still
  consumes it); read endpoints have none so the page can poll.
* **Server log**: `GET /api/console/logs?source=server` reads `server/logs/p5_server.out.log`. When
  the server was started with `start.ps1 -Background` that file is UTF-16LE (from the
  `Start-Process` redirection); when it was started with `cmd > file` it is UTF-8. The endpoint
  detects BOM / NUL bytes and returns the detected `encoding` field, so both read correctly.
* **Front end**: `server/web/{index.html,style.css,app.js}` - plain HTML/CSS/JS, no CDN, no external
  fonts, no npm. Editing it only needs a page refresh; the server does not have to be rebuilt.
* **Built in as well**: the same three files are compiled into the server
  (`server/src/online_server/ConsoleWebAssets.hx`, generated by `server/tools/gen_console_assets.ps1`), so
  `/console` works even when no `server/web/` directory exists. That is what makes the in-client LAN
  host's *Open Local Web Console* button work, because a game export never ships that directory. A disk
  copy still wins, so live editing is unchanged - just re-run the generator after editing the page. Each
  asset is emitted as 4000-character chunks joined with `+` (runtime concatenation): MSVC refuses a single
  string literal above ~16 KB with `C2026`, which is exactly what broke the first version of this feature.
* **Local read-only mode**: with `localConsoleReadOnly` (the embedded host sets it) or
  `--console-local-readonly`, a `GET` from a loopback peer (`127.0.0.0/8`, `::1`, `::ffff:127.0.0.1`)
  needs no credential and receives a synthetic `local-console` account, so the page skips its login form
  and shows a local-read-only banner. Every write and every non-loopback peer still goes through
  `requireAccess` and gets 401, and `/api/admin/*` is never affected.
* **Startup helpers**: `start.ps1 -AdminEmail <email>` makes that account the console administrator;
  `start.ps1 -DataDir <dir>` switches the runtime data directory (`config.toml`, `mail.log`,
  `accounts.json` and the rest move with it). Example:
  `powershell -NoProfile -File server/start.ps1 -AdminEmail me@example.com`.

## LAN play

The same server code can also run **inside the game client** (the online menu's `LAN HOST` row):
the client build puts `server/src` on its classpath inside the `ONLINE_ALLOWED` section of
`project.xml`, calls `online_server.ServerBoot.start()` in its own process and serves on
`0.0.0.0:2567/2568`, auto-creating a room and showing a room code that carries the host LAN IP.
It is account-free, writes its data to `<applicationStorageDirectory>/lanhost/`, applies panel
settings through that directory's `config.toml` (same parser as here), never exposes an admin
account (its `/console` is loopback-only and read-only, see the web console section), and supports Host -> Stop -> Host again in one process. An offline
build (`-D SEIUN_NO_ONLINE`) does not put `server/src` on the classpath at all. See
`docs/multiplayer-protocol.md` section 8.1 for the protocol-level description.

For a dedicated machine, use the standalone server as before:

```powershell
powershell -NoProfile -File server/start.ps1 -Lan          # bind 0.0.0.0
ipconfig | Select-String 'IPv4'                            # find this machine's LAN IP
# Client A connects to 127.0.0.1:2567, client B to <LAN-IP>:2567
```

* `publicAddress` echoes the HTTP `Host` header (`ServerHub.publicAddressFor`), so the bind address
  and the advertised address are independent. A matchmaking request with
  `Host: 192.168.1.50:2667` is answered with `publicAddress = "192.168.1.50:2668"`, while local
  `127.0.0.1` behaviour is unchanged and needs no configuration.
* `--public-host <ip>` overrides the advertised address for NAT / multi-interface setups.
* `--disable-ip-lock` is required when several clients share one machine.
* Remaining client-side work: the client has to be able to set the server address (it currently
  targets `127.0.0.1`). Windows Firewall must allow 2567 / 2568 on the host
  (the first run prompts, or use `New-NetFirewallRule`).
* LAN jitter is far higher than loopback, so disconnect / reconnect handling is worth testing with
  real machines.

## Development notes

1. **Add a room message**: add a `case` to the `switch` in `RoomLogic.handle`; if it changes room
   state, call `setRoomField` / `setPlayerField` (they broadcast), otherwise let it fall through to
   `default`. Grep the client first to confirm the listener name.
2. **Change the schema**: `source/online/backend/schema/*.hx` is generated for
   `E@colyseus/schema 2.0.35`, so edit it carefully. `SchemaEncoder.hx` is a hand-written PATCH
   encoder - new fields or indices must be kept in sync with it.
3. **Add an HTTP endpoint**: `Api.handle` (and `Main.handleHttp` for server-level routes).
   `GET /api/health` is the read-only example to copy.
4. **Add storage**: put the DDL in a new `Migrations.stepN` (never edit a shipped step -- bump
   `SCHEMA_VERSION`), add the statements to a `db/*Repo.hx`, and expose them through the matching
   `*Store` facade. Only `Db.lock` / `Db.lockTx` may be used, a callback must never re-enter
   `Db.lock`, and a result row must be projected into a fresh struct before it leaves the lock.
   Never concatenate a value or an identifier: use `Sqlite.text/int/real/bool/jsonText` and code
   constants.
5. **Coordinate protocol semantics changes before implementing them.**
6. **Two concurrency pitfalls in room lifecycle code**:
   * the `ws.close()` callback can re-enter `disconnect` - make it idempotent with
     `ClientConn.closed`;
   * when a reconnect replaces an old connection, the old `onclose` can wrongly mark the session as
     disconnected, so `SessionRecord.conn` must be bound to the current connection, and the new
     connection must be bound *before* the old one is displaced.
7. **IP lock counts reservations per session.** Adjust it with `--ip-lock-limit` /
   `--disable-ip-lock`; automated tests should clean up temporary sessions (for example with
   `leave(true)`) so they do not block later connections.

