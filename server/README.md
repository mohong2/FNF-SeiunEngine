# SeiunEngine Online Server

A Colyseus-compatible game server written in **Haxe** and compiled to **neko**. It serves
SeiunEngine's online mode: rooms, song selection, per-player state sync, scoring and the session
lifecycle (reconnect, ping, IP lock).

It has no Node.js / TypeScript / `colyseus-server` dependency. HTTP, WebSocket, the Colyseus frame
format and schema PATCH encoding are all implemented in this repository; the only requirements are
**Haxe 4.2.5 + neko**.

Ports: HTTP **2567** (matchmaking + REST), WebSocket **2568** (room connections).

## Quick start

```powershell
# 1) Build. The script locates the repository root itself.
#    Output: server/bin/server.n and server/bin/server.exe
powershell -NoProfile -File server/build.ps1

# 2) Run. Default is foreground: live logs, Ctrl+C stops.
powershell -NoProfile -File server/start.ps1

#    Detached:   powershell -NoProfile -File server/start.ps1 -Background
#    Double-click launcher: server/start.cmd (pauses on exit, does not close instantly)

# 3) Health check / stop
powershell -NoProfile -File server/start.ps1 -Status
powershell -NoProfile -File server/start.ps1 -Stop
```

### Build output

* `server/bin/server.n` - the main artifact.
* `server/bin/server.exe` - optional launcher produced by `build.ps1` via `nekotools boot`, wrapping
  the `.n` inside a `neko.exe` shell. It can be started by double-click or with `start.ps1 -Exe`,
  but it is **not self-contained**: the machine still needs the Haxe/neko toolchain (in particular
  `neko` on `PATH`), otherwise it exits immediately. A genuinely standalone native executable
  requires the Haxe -> C++ target instead. Skip the exe with `server/build.ps1 -NoBoot`.

Artifacts, pid and logs all live under `server/`: `server/bin/server.n`, `server/bin/server.exe`,
`server/logs/p5_server.pid`, `server/logs/p5_server.out.log`, `server/logs/p5_server.err.log`.
`server/bin`, `server/logs` and `server/data` are gitignored.

### Manual equivalents

```powershell
$env:HAXELIB_PATH = (Get-Location).Path + '\.haxelib'
haxe server/server.hxml                                          # -> server/bin/server.n
& 'C:\HaxeToolkit\neko\nekotools.exe' boot server/bin/server.n   # optional -> server/bin/server.exe
server\bin\server.exe                                            # run the exe (foreground; Ctrl+C stops)
& 'C:\HaxeToolkit\neko\neko.exe' server/bin/server.n             # run the .n (foreground; Ctrl+C stops)
```

### start.ps1 parameters

| Parameter | Meaning |
|---|---|
| `-Lan` | Bind `0.0.0.0` (LAN play). |
| `-BindHost <ip>` | Bind address explicitly (takes priority over `-Lan`). |
| `-HttpPort <n>` / `-WsPort <n>` | Override the default ports. |
| `-NoBuild` | Skip compilation and run the existing `server.n` (or `server.exe` with `-Exe`). |
| `-Exe` | Run `server/bin/server.exe` instead of `neko server/bin/server.n`; flags, ports, logs and pid are identical. Prints a hint to run `build.ps1` if the exe is missing. |
| `-Background` | `Start-Process` with pid file and separate `out.log` / `err.log`; suitable for scripts and the DSH harness. |
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
| `--data-dir <dir>` | `server/data` | Local JSON store directory (accounts, leaderboard, comments, ...). |
| `--admin-email <email>` | none | The account with this e-mail automatically gets `["*"]` access (`/api/admin/*`, `/api/console/*`). |
| `--fixture-dir <dir>` | none | Only needed to run the protocol probe with deterministic state bytes. |
| `--smtp-host <host>` | none | SMTP host. Mail is only sent when this and `--smtp-mail` are both set; otherwise verification codes are appended to `<data-dir>/mail.log`. |
| `--smtp-port <n>` | `25` | SMTP port. Only implicit TLS (465) is usable; 587 STARTTLS is not available in the Haxe 4.2.5 standard library. |
| `--smtp-user <user>` | none | SMTP user (may be empty for anonymous relay). |
| `--smtp-pass <pass>` | none | SMTP password. |
| `--smtp-mail <from>` | none | Envelope sender. Required together with `--smtp-host`. |
| `--auth-ttl-minutes <n>` | `[auth]` then `43200` | Credential lifetime in minutes. `0` means never expires. When given on the command line the value is also pinned (`ttl_locked`). |
| `--ng-app-id <id>` | none | Newgrounds gateway app id. Without it `/api/account/link/newgrounds` returns 400. |
| `--discord-webhook <url>` | none | Outbound mirror for network-room chat. Without it the mirror is a no-op. |

## Directory layout

```
server/
+-- README.md            this file
+-- server.hxml          canonical compilation entry (-cp server/src + source + source/_online_libs)
+-- build.ps1            one-shot build (-TypeCheck for types only; -NoBoot to skip the exe)
+-- start.ps1            run (foreground by default; -Exe runs the booted exe) / health check / stop
+-- start.cmd            double-click launcher
+-- bin/                 build output (gitignored)
+-- logs/                pid + logs (gitignored)
+-- data/                runtime data (gitignored)
+-- web/                 web console front end (index.html, style.css, app.js)
+-- src/online_server/   server sources
```

The compilation closure is this directory plus `source/online/backend/schema/**` (the Colyseus
schema classes shared with the client) and `source/_online_libs/**` (`io.colyseus.*`,
`org.msgpack.*`). The client build does not compile the server: `-main online_server.Main` appears
only in `server/server.hxml` and in the probe's `server.hxml`.

## Runtime data (`--data-dir`, default `server/data`)

All persistence is local JSON/plain files; no database is required.

| Path | Purpose |
|---|---|
| `config.toml` | Console-managed runtime configuration (see below). |
| `accounts.json` | Accounts: id, name, e-mail, token, points, average accuracy, role, profile colours, country, club, notifications. |
| `leaderboard.json` | Scores, replays, song comments and reports. |
| `public.json` | Front-page messages, the next weekly-reset timestamp and day-player samples. |
| `admin.json` | Moderator warnings and the moderator action log. |
| `clubs.json` | Clubs: members, pending join requests, leaders, points and base64 banner images. |
| `mods.json` | Mod repository entries and their download items. |
| `images/` | One file per avatar / background, kept out of the fully rewritten account JSON. |
| `mail.log` | Outbox for verification codes and outbound mail, appended to on every send attempt. |
| `backups/` | Config snapshots (`config-<epoch-ms>.toml`) written before each save. |

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
| Auth | `/api/auth/register`, `/api/auth/login`, `/api/auth/refresh`, `/api/auth/cookie`, `/api/auth/logout` |
| Account | `/api/account/me`, `/rename`, `/email/set`, `/delete`, `/friends`, `/notifications`, `/info`, `/profile/set`, `/resetsecret`, `/club`, `/avatar`, `/background`, `/removeimages`, `/link/newgrounds`, `/unlink/newgrounds` |
| Clubs | `/api/club/details`, `/pending`, `/create`, `/join`, `/accept`, `/reject`, `/kick`, `/promote`, `/demote`, `/leave`, `/edit`, `/banner` |
| Users | `/api/user/info`, `/friends/request`, `/friends/remove`, `/details`, `/scores` |
| Mods | `/api/mod/dl/submit`, `/dl/edit`, `/dl/delete`, `/fav`, `/submit`, `/edit`, `/delete` |
| Search | `/api/search/mods`, `/songs`, `/users` |
| Public data | `/api/sezdetal`, `/api/online`, `/api/nextweekreset`, `/api/front`, `/api/sez`, `/api/song/comment`, `/api/song/comments` |
| Scores / tops | `/api/score/submit`, `/report`, `/replay`, `/delete`, `/set/modurl`, `/api/top/song`, `/api/top/players`, `/api/top/clubs` |
| Stats | `/api/stats/day_players`, `/api/stats/country_players` |
| Admin | `/api/admin/*` (songs, users, clubs, players, reports, logs, cooldown, weekly reset); requires `["*"]` |
| Console | `/api/console/*` (see the web console section) |

`/matchmake/reconnect/<roomId>` reuses the old session from the token and returns the same seat
reservation (body `{reconnectionToken}`). Sessions that were kicked, left voluntarily or timed out
get 400. `/api/config` is a read-only snapshot of the effective constants: `maxClients`,
`ipLock`, `maxSessionsPerIp`, `reconnectWindow`, `pingInterval`, `reconnectGuard`,
`reconnectLimit`, `reconnectStormWindow`, `networkRoomId`, `networkProtocol` and `auth`.

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
only targets game rooms, so protocol-probe rooms are left alone.

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
* **Startup helpers**: `start.ps1 -AdminEmail <email>` makes that account the console administrator;
  `start.ps1 -DataDir <dir>` switches the runtime data directory (`config.toml`, `mail.log`,
  `accounts.json` and the rest move with it). Example:
  `powershell -NoProfile -File server/start.ps1 -AdminEmail me@example.com`.

## LAN play

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
4. **Coordinate protocol semantics changes before implementing them.**
5. **Two concurrency pitfalls in room lifecycle code**:
   * the `ws.close()` callback can re-enter `disconnect` - make it idempotent with
     `ClientConn.closed`;
   * when a reconnect replaces an old connection, the old `onclose` can wrongly mark the session as
     disconnected, so `SessionRecord.conn` must be bound to the current connection, and the new
     connection must be bound *before* the old one is displaced.
6. **IP lock counts reservations per session.** Adjust it with `--ip-lock-limit` /
   `--disable-ip-lock`; automated tests should clean up temporary sessions (for example with
   `leave(true)`) so they do not block later connections.

## Probes

The online probe toolchain lives outside this repository, in the engine-sibling directory
`../FNF-SeiunEngine-online-tools/online_probe/` (not tracked by git). It must be invoked from the
engine root, because the `.hxml` files resolve relative paths from the current directory.
`../FNF-SeiunEngine-online-tools/online_probe/server.hxml` is the equivalent compilation entry for
probes and CI.

Rebuild a probe with `haxe ../FNF-SeiunEngine-online-tools/online_probe/<name>.hxml` (from the
engine root); its output lands in `export/online_probe/<name>.n`. The server artifact is
`server/bin/server.n`.

| Probe | Expected | Notes |
|---|---|---|
| `probe.n` | 17/17 | Protocol level. |
| `biz_probe.n` | 73/73 | Business level; the IP lock must stay enabled. |
| `net_probe.n` | 23/23 | Network room. |
| `http_probe.n` | 464/464 | Needs the server started with `--admin-email admin@probe.local` for the console assertions, and the same `--data-dir` as the probe. |
| `persist_probe.n` | 130/130 | Client side; no server required. Compiles `source/online/**` and exercises the local JSON files. |
| `layout_probe.n` | 100/100 | Client side; no server required. Pins the coordinate clamping of the field-row submit buttons. |

## Verifying inside a DSH session

Verification is usually run through the DSH `pwsh` tool, which cleans up child processes when a call
ends. A server started by `server/start.ps1` therefore does not survive that call (a `-Status` in
the same call can still read `onlinecount=0`; the next call gets `Failed to connect`). To keep a
server alive across calls, start it as a managed background job:

```powershell
cmd /c "C:\HaxeToolkit\neko\neko.exe server\bin\server.n > server\logs\p5_server.out.log 2>&1"
# run as a background job; probes can connect across calls
# server/start.ps1 -Background has the same child-cleanup limitation
```

Running `server/start.ps1` in your own terminal is unaffected: the process stays alive until
`-Stop`.
