> ⚠️ **已废弃 / DEPRECATED（2026-09-12）**
>
> 本文描述的是 SeiunEngine **旧版联机实现**，该实现已在 commit `8ab3200` 中整体拆除。
> 它与现役的 SeiunEngine 联机实现（Colyseus/WebSocket，见 `docs/ONLINE_PORT_HANDOFF.md`）
> **协议不兼容**，因此本文**不能作为新实现的参考**。
> 保留仅为历史记录，将在新实现落地后重写或替换。

# SeiunEngine Multiplayer Protocol / SeiunEngine 联机协议

SeiunEngine 旧版专属协议。与本引擎现役的 Colyseus/WebSocket 实现互不兼容。
This is a legacy SeiunEngine-specific protocol, intentionally incompatible with the current Colyseus/WebSocket implementation.

## 1. Transport / 传输层

- TCP, default port `2567`.
- LAN discovery uses UDP broadcast on the same port with the probe string `SEIUNP01-DISCOVER`.
- The UI also accepts `ws://host:port` as an address alias only; the wire format is NOT WebSocket.

## 2. Frame header / 帧头 (28 bytes, big endian)

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | Magic `SEIUNP01` |
| 8 | 2 | Protocol version (currently `1`) |
| 10 | 2 | Message type |
| 12 | 2 | Channel |
| 14 | 2 | Flags |
| 16 | 4 | Payload length |
| 20 | 4 | Sequence id |
| 24 | 4 | CRC32 of payload (0 = not set) |

Channels:

- `0` control
- `1` room
- `2` game
- `3` file
- `4` async
- `5` admin
- `6` auth

Limits: control/room/game JSON payload <= 64 KiB; file chunk <= 256 KiB per frame and <= 64 MiB per file; protocol rate limit 600 messages / 5 s.

## 3. Handshake / 握手

1. Client sends `HELLO` with `protocolVersion`, `fingerprint = "SeiunEngine/0.2.1"`, `deviceId`, `nickname`, `avatar`, optional `sessionToken`.
2. Server checks magic + header version + fingerprint. Mismatch sends `ERROR` (`0x1001` bad magic, `0x1002` version mismatch, `0x1003` wrong fingerprint) and closes.
3. Server replies `WELCOME` with the same engine fingerprint, server mode, auth flags, server time and reconnect window; the client also rejects a mismatched fingerprint.
4. Three `PING`/`PONG` samples measure RTT and clock offset. Offset > 1500 ms or single jump > 300 ms is rejected.
5. Dedicated server may require `AUTH_LOGIN` / `AUTH_REGISTER` before room messages.

## 4. Identity / 身份

- Device id (random UUID, stored locally) is the primary key. Nickname and avatar are display-only.
- Embedded LAN mode: no account, device id + nickname + avatar in HELLO.
- Dedicated mode: username + password; server stores salted SHA-256 hash, binds one device to one account.

## 5. Rooms / 房间

- `ROOM_LIST` -> `ROOM_LIST_RESULT`.
- `ROOM_CREATE` with mode (`realtime`/`async`), max players, anticheat, password, judgement preset/timings, marvelous flag, 0.7.3 compatibility flag.
- `ROOM_JOIN` with room code and optional password.
- `ROOM_READY` carries `ready` and the client's locally computed `chartHash`; the server refuses realtime countdown until every player has the same chart hash as the host.
- Force start, chat, host settings and host admin commands are host-only.

## 6. Real-time gameplay / 实时对局

- After `GAME_START`, the host uploads the generated chart timeline (`chartNotes`) on `CHANNEL_FILE` so long charts are not limited by the 64 KiB game-channel cap.
- Anti-cheat ON: clients send only `GAME_INPUT`; host validates inputs against the chart timeline and broadcasts authoritative `GAME_JUDGE`.
- Anti-cheat OFF: clients judge locally and send `GAME_JUDGE`; host forwards.
- `GAME_PAUSE` / `GAME_RESUME` are forwarded to all players.
- Disconnect: `BYE` = normal leave; heartbeat timeout = "connection lost"; `CRASH_SIGNAL` = "game crashed".

## 7. Async ranking / 异步排名

- `ASYNC_START`, `ASYNC_SUBMIT` (score + replay JSON), `ASYNC_RANKING`, `ASYNC_FINALIZE`.
- When anticheat is ON, submitted replay JSON must exist and pass basic consistency checks; invalid submissions are ignored with a room notice.
- Ranking order: score desc, then accuracy desc, then submission time asc.

## 8. File sync / 文件同步

All on `CHANNEL_FILE`:

- `MOD_MANIFEST`: every player sends its local `mods/` manifest (relative path, size, SHA-256) after entering a room.
- `MOD_MANIFEST_RESULT`: server compares the host manifest against the player manifest and returns missing/different files. In the default embedded-server mode the server can read the host's local `mods/` directly and marks `serverCanServe`.
- `MOD_FILE_REQUEST`: client requests one file at a time.
- `MOD_FILE_CHUNK`: raw binary chunk. Each chunk payload starts with a small big-endian header: `0x5A`, transferId (i32), path byte length (i32), UTF-8 path, chunk index (i32), chunk count (i32), data length (i32), then data. Chunk size is 256 KiB.
- `MOD_FILE_ACK`: client confirms success/failure after SHA-256 verification; server broadcasts a room notice.
- `CHART_BUNDLE_ANNOUNCE` is reserved for converted chart bundles.

Received files are written to the matching relative path under `mods/`, verified with SHA-256, retried twice, and the room lobby shows progress. After receiving files the game prompts the player to restart so newly added mods are loaded cleanly.

## 9. Isolation guarantees / 隔离保证

- Legacy Seiun client connects to the current server: the HTTP/WebSocket endpoint does not recognize `SEIUNP01`, handshake fails.
- Current client connects to a legacy Seiun server: first bytes are HTTP text, the server sends `ERR_BAD_MAGIC` and disconnects.
- No public server addresses are built into the client.
