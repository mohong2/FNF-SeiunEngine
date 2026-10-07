# 服务端扩展点 / Server extension points

SeiunEngine 的服务端（`server/src/online_server/`）**没有脚本加载器**：它不加载 `server/scripts/*.hx` 之类的
外部脚本，扩展都是直接改源码。可用的扩展点：

| 扩展点 | 位置 | 说明 |
|---|---|---|
| HTTP 路由 | `Api.hx`（`Api.handle`）、`Main.hx`（`routeHttp`、`handleMatchmake`） | 新增 `/api/*` 端点；权限模式在 `config.toml` 的 `[permissions]` |
| 房间消息 | `RoomLogic.hx`（`handle` 的 case 表） | 新增消息要同时改客户端监听（`source/online/GameClient.hx` / `RoomState.hx`）；改房间状态要走 `setRoomField` / `setPlayerField` 才会广播 |
| 社交大厅 | `NetworkLogic.hx` | 网络房（roomId `0`）的聊天 / 邀请逻辑 |
| 管理面 | `/console` 与 `/api/console/*`（`ConsoleApi.hx`、`server/web/`） | 只读面板 + 可写 `[server]` / `[smtp]` / `[permissions]`，带冷却 |
| 存储 | `db/*Repo.hx` 与 `db/Migrations.hx` | 新增表用新的 `Migrations.stepN` 并提升 `SCHEMA_VERSION`，不要改已发布的 step |

## 如果要做脚本系统

- 服务端脚本属于**服主可信代码**；客户端脚本绝不能上传到服务端执行。
- 默认屏蔽 `sys.io.File`、`sys.io.Process`、`sys.net.Socket`、`sys.net.UdpSocket`、`haxe.Http` 等危险 import。
- 沙箱边界、可用对象与钩子签名需要在 `server/README.md` 里写明，并给出示例。
