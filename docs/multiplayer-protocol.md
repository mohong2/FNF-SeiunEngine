# SeiunEngine 联机协议与架构 / Online Protocol & Architecture

> **本文档描述现役实现（Colyseus 兼容 / WebSocket，Haxe 4.3.7 + neko 或 hxcpp 服务端）。**
> This document describes the current implementation (Colyseus-compatible over WebSocket; server in
> Haxe 4.3.7, built for neko or hxcpp).

权威实现位置 / Sources of truth：

| 关注点 | 位置 |
|---|---|
| 客户端握手常量 | `source/online/Protocol.hx`（MAGIC / NETWORK_MAGIC / VERSION） |
| 客户端房间状态机与消息注册 | `source/online/GameClient.hx`、`source/online/NetworkClient.hx` |
| 服务端入口 / HTTP 路由 / 匹配 | `server/src/online_server/Main.hx` |
| 服务端房间状态与帧编码 | `server/src/online_server/GameRoom.hx`、`SchemaEncoder.hx` |
| 业务房消息处理 | `server/src/online_server/RoomLogic.hx` |
| 社交大厅（network 房） | `server/src/online_server/NetworkLogic.hx` |
| 共享 schema | `source/online/backend/schema/*.hx`（服务端与客户端同一份） |

---

## 1. 传输与端口 / Transport & ports

| 端口 | 用途 | 说明 |
|---|---|---|
| **2567/tcp** | HTTP：匹配（`/matchmake/*`）、房间列表、REST（`/api/*`）、Web 控制台（`/console`） | 客户端**只填这个端口** |
| **2568/tcp** | WebSocket：房间连接（Colyseus 帧格式） | 由服务端 `publicAddress` 推导，客户端不填 |

- HTTP 是自实现的 HTTP/1.1，`Connection: close`，没有 keep-alive（`HttpServer.hx`）。
- WebSocket 帧、`JOIN_ROOM`、schema PATCH 全部手写；**不依赖 Node / TypeScript / colyseus-server**。
- 匹配响应里的 `publicAddress` 决定房间 WS 的落点：`--public-host` 优先，否则回显 HTTP `Host` 头并拼上 `--ws-port`。
- 客户端把房间地址（`ws://host:port`）交给 vendored `io.colyseus.Client`，`ws://` 会被换算成 `http://` 用于 REST 与可达性探测。

## 2. 握手与版本强校验 / Handshake

1. 客户端 `GET /api/config`，必须回 `engine = "seiunengine-online"`；不一致直接拒绝连接（`GameClient.verifyServer`）。
2. 加入房间时在 join options 里带握手字段：

| 字段 | 值 | 说明 |
|---|---|---|
| `engine` | `seiunengine-online`（游戏房）/ `seiunengine-network`（社交房） | 应用层 magic |
| `protocol` | `1` | 游戏房协议版本 |
| `protocol`（网络房） | `1` | 与 `NetworkLogic.PROTOCOL_VERSION` 同步 |
| `networkId` / `networkToken` | 可选 | 有账号凭据时才带；缺失时服务端按 `name → networkId → sessionId` 回落 |
| `name` | 可选 | 局域网/无账号模式的显示名 |

3. 服务端校验 magic 与版本，不匹配就拒绝（症状很像「连不上」，排障时先看两端版本与 magic）。
4. 心跳：服务端 3 秒一次 ping，60 秒没有 pong 或 20 分钟无活动会被踢；客户端用 `ping`/`pong` 消息替代定时器。

## 3. 匹配与房间生命周期 / Matchmaking & lifecycle

| 方法 | 路径 | 说明 |
|---|---|---|
| create | `POST /matchmake/create` | 建房 |
| joinOrCreate | `POST /matchmake/joinOrCreate` | 加入或建房 |
| joinById | `POST /matchmake/joinById` | 按房号加入 |
| reconnect | `POST /matchmake/reconnect/<roomId>` | body `{reconnectionToken}`，复用原座位；被踢/主动离开/超时返回 400 |
| room list | `GET /rooms/room` | 房间列表（含元数据） |
| online count | `GET /api/onlinecount` | 在线人数 |
| config | `GET /api/config` | 只读常量快照：maxClients、ipLock、maxSessionsPerIp、reconnectWindow、pingInterval、reconnectGuard、reconnectLimit、reconnectStormWindow、networkRoomId、networkProtocol、auth |

生命周期约束（`ServerHub` / `GameRoom`）：

- 默认 `maxClients = 6`；每个 IP 默认 4 个会话（`--disable-ip-lock` 关闭，`--ip-lock-limit` 调整）。
- 断线保留窗口 20 秒，可用 `reconnectionToken` 回到同一座位；主机离开时自动转移 host。
- 重连风暴保护默认开启（`--disable-reconnect-guard`、`--reconnect-limit` 可调）。
- 社交房（network room）固定 roomId `0`，常驻不回收，保留最近 100 条聊天。

## 4. 房间状态同步 / Schema

- `source/online/backend/schema/*.hx` 是为 `@colyseus/schema 2.0.35` 生成的：`Room`、`Player`、`Person`、`ColorArray`。
- 服务端用手写的 `SchemaEncoder.hx` 产出 PATCH，客户端用 vendored `io.colyseus.serializer` 解析。
- **改 schema 必须同时改 `SchemaEncoder.hx` 的字段与索引**，否则两端静默错位。新增字段只能追加。
- `Room.health` 是共享血条权威值；`Player` 承载分数、判定计数、`bfSide`、皮肤、准备状态等。
- `Room.pauseMode`（最后追加的字段，索引 25）是房间的**暂停策略**，由房主用 `nextPauseMode` 循环切换：
  `0` = 仅房主可暂停（其他人被强制暂停）、`1` = 任一玩家暂停则全体暂停（默认）、`2` = 保留原来逻辑（暂停只影响自己）。

### 5.1 暂停语义（房间设置「暂停策略」）

- 客户端 ESC 时按 `pauseMode` 决定：模式 0 只有房主能暂停（客人按 ESC 只会收到本地提示），模式 1/2 谁都能按。
- 模式 0/1 下暂停会发 `pauseGame`；**服务端是唯一仲裁**：校验策略与「当前是否只有一个人持有暂停」，然后
  **回显给所有人（含发送者）**。回显里带着发起者的 sid：收到自己 sid = 自己持有暂停；收到别人 sid =
  自己只是被强制暂停（该客户端因此无权恢复；两人同帧按 ESC 时由服务端先到者持有，落败方从回显得知）。
- `resumeGame` 只有**暂停的持有者**能生效（模式 0 下房主也可以）；被拒绝的连接会收到一条 `log`。
  持有者掉线/被踢/离开时服务端自动广播 `resumeGame`，不会把其他人永久卡在暂停里。
- `room.pauseOwner` 是服务端业务字段（非 schema）：暂停是事件而非状态，迟到进房的玩家不会继承旧的暂停。
- 模式 2 下所有暂停消息都不上线（双向都忽略），两端行为与旧版本完全一致。

## 5. 游戏房消息 / Game-room messages

权威 handler：`server/src/online_server/RoomLogic.hx`（`handle` 的显式 case + 未列出的走泛化广播）。

| 类别 | 消息 |
|---|---|
| 心跳/状态 | `pong`、`status`、`noteHold`、`botplay` |
| 选歌/开局 | `verifyChart`、`setSong`、`setStage`、`startGame`、`playerReady`、`nextWinCondition` |
| 暂停 | `pauseGame`、`resumeGame`、`nextPauseMode`（房间设置「暂停策略」，见下） |
| 对局上报 | `addScore`、`addHitJudge`、`addMiss`、`updateMaxCombo`、`updateSongFP`、`updateFP`、`updateHealth`、`playerEnded`、`requestEndSong` |
| 社交/杂项 | `chat`、`command`、`custom`、`customTo`、`notifyInstall`、`roll`、`help`、`kick` |
| 皮肤/设置 | `setSkin`、`updateNoteSkinData`、`togglePrivate`、`toggleNetworkOnly`、`anarchyMode`、`togglePlayersCanChoose`、`toggleGF`、`toggleSkins`、`swapSides`、`teamMode`、`royalMode`、`royalModeDadSide` |

社交房消息（`NetworkLogic.hx`）：`chat`、`loggedMessagesAfter`、`inviteplayertoroom`、`pong`。

## 6. HTTP 面 / HTTP surface

- **匹配**：`/matchmake/create|joinOrCreate|joinById|reconnect`。
- **房间/配置**：`/rooms/room`、`/api/onlinecount`、`/api/config`。
- **账号**：`/api/auth/*`（register/login/refresh/cookie/logout）、`/api/account/*`。
- **社交**：`/api/club/*`、`/api/user/*`、`/api/search/*`。
- **分数/榜单**：`/api/score/*`、`/api/top/song|players|clubs`、`/api/song/comment(s)`。
- **模组**：`/api/mod/*`。
- **公共数据/统计**：`/api/sez*`、`/api/front`（`{online, rooms, sez, announcement}`，`announcement` 为控制台存盘的当前公告，空串表示未设置）、`/api/nextweekreset`、`/api/stats/*`。
- **公告**：控制台 `POST /api/console/announce` 存盘到 `<data-dir>/config.toml` 的 `[server] announcement`，并向网络房间的已 ack 连接推送 `notification` 帧；两件事互相独立，重启不会重推，但新登录的玩家可从 `/api/front.announcement` 看到当前公告。
- **文本上限按码点计数**：公告与 `/api/sez` 的上限都按 UTF-8 **码点**而非字节，中文/emoji 不会再被按 1/3 长度误拒或被中途切断。
- **UTF-8 保证（写入 + 读取两层）**：所有用户文本（账号/简介/俱乐部/模组/评论/警告/通知/公告）写入时归一化、读取时再修复；非法序列（overlong、UTF-8 编码的代理对、>U+10FFFF、孤立续字节、NUL）一律拒绝，CESU-8 代理对折叠回真实码点。两个 JSON 出口（`Api.json`、`ConsoleApi.json`）统一经过同一修复，任何 `/api/*` 响应都不会返回非法 UTF-8。
- **cpp（hxcpp）非 BMP 字符**：hxcpp 的 `haxe.Json.stringify` 会把 emoji 变成 U+FFFD，因此 cpp 服务端的 JSON 出口会替换为 JSON 代理对转义，客户端仍收到真实 emoji。
- **控制台日志**：`GET /api/console/logs?source=actions` 返回**最新** N 行（最新在前），与文档一致。
- **管理**：`/api/admin/*`（需要 `["*"]` 权限）。
- **控制台**：`/console` 与 `/api/console/*`（同进程同端口，见 `server/README.md`）。
- **健康检查**：`GET /api/health`（只读：status / uptime / rooms / version / dbSchemaVersion / dbPath）。

## 7. 联机玩法约束（重要，改动前先读）/ Online gameplay constraints

1. **联机禁用全部运行期 Note / 脚本优化**：`perfMode`、`bulkSkip`、`fastSort`、`scriptArgReuse` 等会绕过唯一两个命中上报点
   （`goodNoteHit()` / `noteMiss()`），因此联机进歌时**只改本局内存值**全部关闭，退出歌曲按进歌快照恢复；用户设置文件不被改写。
   加载期优化（流式解析、分桶排序、巨谱缓存）保留。
2. **联机只承诺单文件谱面**：`ChartParts` 分段谱面与 `ChartCache` 巨谱缓存不参与联机一致性校验；
   两者与联机叠加的场景不作承诺。请用单文件谱面联机。
3. **反作弊边界**：服务端不做对局模拟，判定在客户端本地完成后上报（`addScore` / `addMiss` / `addHitJudge`）。
   局域网门槛更低，改包风险更高，不要把它当作可信竞技环境。
4. **两端必须同版本**：`Protocol.MAGIC`、`VERSION`、`NETWORK_MAGIC`、`NETWORK_VERSION` 与 `/api/config` 的 `engine` 任一不一致都会被拒绝。
5. **联机时不要启用 Turbo / botplay 强制**：Turbo 会被联机静默关闭（它强制 botplay 并走数据层结算，与共享血条和逐 sid 计分冲突）。

## 8. 局域网 / LAN

服务端（已就绪，不需要改造）：

```powershell
powershell -NoProfile -File server/start.ps1 -Lan          # 绑定 0.0.0.0
# 同一台机器上开多个客户端时追加 --disable-ip-lock
```

- 客户端服务器地址只填**主机在局域网里的 IP + HTTP 端口**，例如 `192.168.1.50:2567`；
  客户端会把裸主机/裸 IP 自动补成 `ws://<host>:2567`（只补一次）。
- 房间 WS 地址由服务端按请求的 `Host` 头推导，所以填 `2568` 反而连不上匹配接口。
- **不要用 127.0.0.1 去连别人的机器**：`publicAddress` 会回显 `127.0.0.1`，对方连的是自己的回环。
- Windows 防火墙要放行 2567 与 2568；`server/start.ps1 -Lan` 会打印本机内网 IPv4 与可直接粘贴的 `New-NetFirewallRule` 命令。
- NAT / 多网卡 / 反代场景用 `--public-host <ip>` 覆盖对外广播地址。
- Android：`templates/android/template/app/src/main/AndroidManifest.xml` 已开启 `android:usesCleartextTraffic`，
  否则 targetSdk ≥ 28 会直接拒绝明文 `ws://` / `http://`（连 `ws://localhost` 一起拒）。
- 网络抖动：局域网 RTT 远大于回环，断线重连（20 秒保留窗口 + `reconnectionToken`）在真实局域网上会比回环明显慢。

### 8.1 客户端内置开服（内嵌服务端）/ Embedded host

- 客户端联机菜单的 **LAN HOST** 会把**同一个服务端**（`server/src/online_server`）编进客户端二进制，
  `online_server.ServerBoot.start()` 在**客户端进程内**启动 HTTP(2567)+WS(2568)，`runLoop()` 跑在后台线程，
  `stop()` 关闭两个监听套接字并释放端口；**同一 dataDir 支持 Host → Stop → Host 重启**（换 dataDir 需要重启进程，
  因为 `db/Db.hx` 的 SQLite 句柄是进程级的）。
- 客户端开服时把 `GameClient.lanLocalOverride` 指向 `ws://127.0.0.1:<httpPort>`：**游戏房间与社交/网络房间都走本地服**
  （用户口径：局域网服务器就是服务器），且不写 `ClientPrefs` / `ServerList`，玩家的官方服务器选择不被污染。
- **无账号**：`/matchmake/joinById/<code>` 只需要握手 + 房间存在 + IP 锁，guest 不需要 token。
  房主屏幕上复制出来的房间码用 `GameClient.lanShareAddress` 换成局域网 IP（`ROOMID;ws://192.168.x.y:2567`）。
- 面板设置通过 `<dataDir>/config.toml` 生效（`[server] max_clients`、`ip_lock`、`ip_lock_limit` 等，
  与独立服务端同一套解析），数据目录默认 `<applicationStorageDirectory>/lanhost/`。
- 构建：`project.xml` 在 `ONLINE_ALLOWED` 段内加 `-cp server/src`；`-D SEIUN_NO_ONLINE` 时该行不生成，
  离线构建产物与之前逐字节一致。
- 内嵌模式不暴露管理员账号（`adminEmail:null`）。控制台因此以**本机只读**方式工作：`localConsoleReadOnly`
  打开时，来自环回地址（127.0.0.0/8、::1、::ffff:127.0.0.1）的 `GET /api/console/*` 免登录，返回一个合成
  只读账号（`local-console`），页面据此跳过登录墙并显示只读横幅；**写操作**与**非环回来源**（局域网里其它机器）
  仍走原来的四步校验。独立服务端默认关闭，可用 `--console-local-readonly` 打开。
- 控制台前端（`server/web/*`）已随服务端一起编译进二进制（`server/online_server/ConsoleWebAssets.hx`），
  `/console` 不再依赖部署目录里是否有 `server/web/`；两边都在时以磁盘文件为准。

## 9. 安全与运维要点 / Security & ops

- 客户端**无条件信任**服务端返回的 `publicAddress`：恶意服务端可以把房间 WS 指向第三方主机。只连可信服务器。
- 账号与会话凭据在服务端**只以哈希形式落盘**（token 哈希 + 前缀查找，常量时间比较，带过期与撤销）；验证码同样哈希。
- 服务端持久化已从「整份 JSON 明文覆盖写」迁移到 **SQLite**（`<data-dir>/seiun.sqlite3`；WAL、事务、参数化引号转义、`user_version` 版本化迁移）；旧 JSON 会在首次启动时自动导入并改名为 `*.imported-<ts>`，不会删除用户数据。
- 运行数据目录默认 `server/data`（`--data-dir` 可改）：数据库、`config.toml`、`images/`、`mail.log`、`backups/`。
- 控制台 `/console` 与 `/api/admin/*` 是管理面，暴露到公网前必须先把口令/权限与反代访问控制配好。
