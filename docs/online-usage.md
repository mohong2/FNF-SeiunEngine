# SeiunEngine 联机使用说明 / Online & LAN usage

> 本文档描述 SeiunEngine 现役的联机实现：Haxe 4.3.7 客户端 + Colyseus 兼容服务端（可用 neko 运行，
> 也可以编成独立的 `SeiunServer.exe`），并支持在游戏客户端里直接开服（局域网主机）。
> 协议细节见 [`docs/multiplayer-protocol.md`](multiplayer-protocol.md)；服务端权威说明见 [`server/README.md`](../server/README.md)。

---

## 1. 联机怎么玩（三条路径）

| 场景 | 服务端 | 客户端 |
|---|---|---|
| **局域网**（最常用） | 房主机器跑 `server/start.ps1 -Lan`（绑 `0.0.0.0`） | 其他人：联机 → 服务器列表 → 填房主**内网 IP**（裸 IP 会自动补 `:2567`） |
| **同机双开**（自测） | `server/start.ps1 -Lan --disable-ip-lock` | 两个客户端都填 `127.0.0.1:2567` |
| **公网 / 反代** | `server/start.ps1` + `--public-host <对外地址>` | 填对外域名（`wss://` 走 443，不要补端口） |

客户端服务器地址**只填 HTTP 端口（默认 2567）**；房间用的 WebSocket 端口（默认 2568）由服务端在匹配响应里
通过 `publicAddress` 推导，玩家填 2568 反而连不上。

## 2. 局域网 / LAN 步骤

### 2.1 客户端内置开服（LAN HOST，推荐：不用装服务端）

游戏客户端的联机菜单里新增了 **LAN HOST** 行（面板代码 `source/online/states/LanHostState.hx`，界面风格与联机选项菜单一致）：

1. 主菜单 → **联机** → **LAN HOST** → **Host on LAN**：客户端**在自己的进程里**启动一个服务端
   （HTTP 2567 / WS 2568，绑 `0.0.0.0`），自动建好房间并让房主自己进房，然后把**房间码**与**局域网地址**显示在面板上。
2. 面板上的房间码形如 `ABCD;ws://192.168.1.50:2567`（点一下复制），把整段发给朋友。
3. 朋友：主菜单 → 联机 → **JOIN**，把整段房间码粘进去即可（码里带地址，朋友不用再配服务器列表）。
4. 面板设置：**Port**（默认 2567；被占用会自动往后找，并在面板上显示实际端口）、**Max Players**（1–64）、
   **Allow Players From This PC**（同机双开自测时勾上）、**Public Room**（勾上才出现在 FIND 列表，默认只认房间码）、
   **Open Local Web Console**（本机浏览器打开这个内嵌服务端的 `/console`；内嵌服没有管理员账号，所以只有**本机**
   免登录、且只能看，局域网里其它机器打开只会看到登录墙）。
5. 结束：面板里的 **Stop Hosting**。停掉后端口会释放，**同一局游戏里可以再次开服**（Host → Stop → Host）。

说明与限制：

- **内嵌服务端是"独立本地服"**：无账号也能玩，账号与分数只写在这台电脑的 `<applicationStorageDirectory>/lanhost/` 里，
  **不会上传官方服务器**，也不参与官方排行榜。
- **开服时这个客户端就是"本地服"的客户端**：游戏房间与社交/聊天都连本地服（和 MC 一样），
  因此开服期间收不到官方好友消息与官方公告。
- 首次开服 Windows 会弹防火墙：**必须允许"专用网络"**，否则朋友连不上；面板底部也有这条提示。
- Android 同样能开服，但局域网 IP 可能探测不到（面板会提示手填 Wi-Fi IP），且**必须保持前台**，后台会被系统冻结。
- 离线构建（`-D SEIUN_NO_ONLINE`）不含内嵌服务端：`server/src` 不进 classpath，联机菜单也不会出现。

### 2.2 独立服务端（专用机器 / 长期在线）

房主：

```powershell
# 1) 编译服务端（首次或改过服务端代码后）
powershell -NoProfile -File server/build.ps1

# 2) 以局域网模式启动：绑 0.0.0.0，并打印本机内网 IPv4 与放行命令
powershell -NoProfile -File server/start.ps1 -Lan

# 3) 从打印出来的 IPv4 里挑一个给玩家（多网卡时挑同一个 Wi-Fi/交换机网段的那个）
# 4) 按提示执行 New-NetFirewallRule 放行 2567 与 2568（首次连接时 Windows 弹窗点允许也行）
```

玩家（同一局域网）：

1. 主菜单 → **联机** → **服务器列表**。
2. 新增/编辑一个服务器条目，**Server Address** 填 `192.168.x.y:2567`（协议可省略；裸 IP 会自动补成 `ws://192.168.x.y:2567`）。
   - 用 `ServerListState` 里的「本机 / LAN」入口可以一键填入本机内网地址；同机自测时它同样适用。
   - 列表行的探测结果会区分 **可达 / 超时 / 协议不符**：出现「协议不符」说明那个地址不是 SeiunEngine 服务端，或两端版本不一致。
3. 连接后进房间：房主选歌（**只支持单文件谱面**，见 §5）、全员准备、房主开始。

常见坑：

- **不要用 `127.0.0.1` 去连别人的机器**：服务端按请求的 `Host` 头推导房间地址，`127.0.0.1` 会让对面连到自己的回环。
- 只放行了 2567 会出现「能匹配、进不了房间」：2568 也要放行。
- 同机双开必须给服务端加 `--disable-ip-lock`（默认每个 IP 最多 4 个会话）；用客户端内置开服时勾 **Allow Players From This PC**。
- 内置开服后朋友连不上：先看防火墙是否允许了"专用网络"，再确认房间码是**整段**（含 `;ws://<你的内网IP>:端口`）。
- 两端版本/协议必须一致（`Protocol.MAGIC`、`VERSION` 与 `/api/config` 的 `engine`），否则表现和「连不上」一样。
- Android：manifest 已开启明文流量（`android:usesCleartextTraffic`），否则系统会直接拒绝局域网 `ws://`。
- 局域网 RTT 远高于回环，掉线重连要先在真机上试（断 Wi-Fi 约 5 秒再恢复）。

## 3. 服务端 / Dedicated server

```powershell
powershell -NoProfile -File server/build.ps1              # -> server/bin/server.n（neko）
powershell -NoProfile -File server/build.ps1 -Target cpp   # -> server/bin/SeiunServer.exe（hxcpp，零运行时依赖）
powershell -NoProfile -File server/build.ps1 -Target both  # 两个目标都编
powershell -NoProfile -File server/start.ps1              # 前台启动，Ctrl+C 停止
powershell -NoProfile -File server/start.ps1 -Background  # 后台启动
powershell -NoProfile -File server/start.ps1 -Status      # 健康检查 / 在线人数
powershell -NoProfile -File server/start.ps1 -Stop        # 停止
```

- 端口：HTTP **2567**（匹配 + REST + `/console`），WebSocket **2568**（房间）。
- 关键参数：`-Lan`、`--public-host`、`--disable-ip-lock`、`--ip-lock-limit`、`--disable-reconnect-guard`、`--reconnect-limit`、`--data-dir`、`--admin-email`、`--smtp-*`、`--auth-ttl-minutes`。
- 健康检查：`GET /api/health`（只读：状态、运行时长、房间数、版本、数据库 schema 版本、数据库路径）。
- Web 控制台：同进程同端口打开 `http://<主机>:2567/console`（主机可以在手机浏览器上管理房间）。
- 数据目录（默认 `server/data`，`--data-dir` 可改）：**`seiun.sqlite3`**（SQLite：事务 + WAL）、`config.toml`、`images/`、`server-YYYYMMDD.jsonl` 结构化日志、`mail.log`、`backups/`。
  旧版 JSON（`accounts.json` 等）会在首次启动时**自动导入**数据库，并把原文件改名为 `*.imported-<时间戳>`；
  导入失败会直接报错退出，不会静默丢数据。也可以显式触发：`--import-legacy-json`。

## 4. 账号、凭据与会话 / Accounts & credentials

- 注册/登录走邮箱验证码换 token（`/api/auth/*`）；token 支持过期、刷新与撤销。
- 服务端**只保存 token 的 HMAC-SHA256 哈希**（带可查找前缀，常量时间比较），数据库里没有明文 token；
  邮件验证码同样只以哈希形式参与校验。
- 随机数来自「OS 熵源优先（`/dev/urandom`），不可用时退化为 HMAC-SHA256 DRBG」；这是**非硬件 CSPRNG** 的
  工程折中，安全边界见 `server/README.md`。
- 局域网房间本身**不强制账号**：没有凭据时会用昵称作为身份；社交页/好友/榜单仍需要登录。

## 5. 联机玩法约束（重要）

1. **只承诺单文件谱面**：分段谱面（`<song>-0..N.json` / `.parts.json`）与巨谱缓存在联机下不参与一致性校验；
   联机房间选中这类谱面会被明确拒绝并提示，请改用单文件 `<song>.json`。
2. **联机禁用全部运行期 Note / 脚本优化**（`perfMode`、`bulkSkip`、`fastSort`、`scriptArgReuse`、`limitNotes` 上限等，
   以及强制 botplay 的 Turbo）：它们会绕过命中上报点，导致远端看到你站着不动但连击在涨。只改本局内存，退出后恢复你的设置。
3. **反作弊边界**：服务端不做对局模拟，判定在客户端本地完成后上报。局域网门槛低，不要把它当可信竞技环境。
4. **录制**：联机时不要依赖录制功能（录制会把 `fixedTimestep` 与帧率钉死，是时间轴发散的来源）；这一点尚未自动拦截。

## 6. 离线构建 / Offline build

`art/build_x64_offline.bat` 传 `-D SEIUN_NO_ONLINE`，它会**关闭** `ONLINE_ALLOWED` 与更新检查：
联机代码不参与编译、主菜单不出现联机入口、运行期不发起网络请求。
若你是手工构建，等价做法是给 lime 传同一个 define：

```sh
lime build windows -release -D SEIUN_NO_ONLINE
```

## 7. 排障清单 / Troubleshooting

| 现象 | 先查 |
|---|---|
| 连不上、一直转圈 | 地址是否只填了主机 IP（客户端会补 2567）；服务端是否 `-Lan`；防火墙 2567/2568 |
| 能匹配、进不了房间 | 2568 是否放行；`publicAddress` 是否被 `--public-host` 指错 |
| 「协议不符」 | 该地址不是 SeiunEngine 服务端，或两端 `Protocol`/版本不一致 |
| 第二个客户端被踢 | 服务端加 `--disable-ip-lock` |
| 远端看到我不动 | 联机时是否仍开着运行期优化（应被自动关闭）；是否用了 Turbo/录制 |
| 选歌后开不了局 | 是否用了分段谱面/巨谱（联机只支持单文件谱面） |
| 服务端起不来 | 端口占用（`-Status`/`-Stop`）；`server/logs/` 与 `server/logs/server-*.jsonl` 结构化日志 |
| 公告/全局留言看不到 | 公告由控制台 `POST /api/console/announce` 发布（存盘 + 立即推送）；联机菜单会显示 `/api/front.announcement`，未设置时为空串。全局留言是另一条链路：`/api/sez` 每账号每 24h 一条、且同一玩家连发会被拒 |
| 中文公告/留言被拒或断字 | 上限按 **UTF-8 码点**计数（不是字节）；文本写入前归一化、读取时再修复非法序列，不会写出坏 UTF-8 |
| 控制台网页打不开 | 三个前端文件已编译进服务端，从任何目录启动都能打开；想改页面就在 `server/web/` 放一份（磁盘版本优先，改完刷新即可） |

## 8. 服务端扩展点 / Server extension points

服务端没有脚本加载器，扩展方式是直接改源码：HTTP `/api/*`（`Api.handle`）、房间消息（`RoomLogic.handle`
的 case 表）与管理面 `/console`。逐项说明见 [`docs/server-script-api.md`](server-script-api.md)。
