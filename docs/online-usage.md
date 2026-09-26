> ⚠️ **已废弃 / DEPRECATED（2026-09-12）**
>
> 本文描述的「内置局域网托管 / 端口 2567 / 管理面板 2568 / `seiun_online_profile.json`」
> 均属**旧版联机实现**，已在 commit `8ab3200` 中整体拆除；文中「`ONLINE_ALLOWED` 只在
> desktop 构建默认定义」与 `Project.xml` 实际（该 define 处于注释状态）亦不符。
> 保留仅为历史记录，将在新实现落地后重写。

# SeiunEngine 联机使用说明

## 内置局域网托管（默认，Minecraft 式）

1. 主菜单进入「联机」。
2. 点击「快速开启局域网」。游戏进程内会直接启动内置服务器。
3. 其他玩家进入「联机」，点击「快速拉取服务端」扫描局域网，按 J 选择服务器；或直接输入房主 IP 后点「连接服务器」。
4. 房主进入「建房配置」创建房间，选择实时/异步、人数、反作弊、判定与 0.7.3 兼容模式。
5. 加入方输入房间码加入；若房主设置了密码需要密码。
6. 房主选歌后，实时模式全员准备并由房主开始；异步模式各人点击「开始游玩」。
7. 房主退出/关闭游戏即关闭房间。

## 无头专用服务器（可选）

```bat
cd server
start_server.bat
```

- 默认端口 `2567`，管理面板 `http://127.0.0.1:2568`（默认口令 `seiun`，可在 `server/server.config.json` 修改）。
- 启动时会打印本机局域网 IP。
- 控制台命令：`list`、`kick <id>`、`ban <id/ip>`、`mute <id>`、`announce <文本>`、`setpassword <密码>`、`anticheat on/off`、`maxplayers <n>`、`stop`。
- 专用服务器需要注册/登录账号；密码只以盐化哈希保存在 `server_data/accounts.json`，一个账号绑定一个设备码。
- 邮箱验证/SMTP：未配置时自动关闭，注册后直接可用。

## 模组同步（局域网快速互传）

- 进入房间后所有玩家自动提交 `mods/` 文件清单（相对路径 + SHA-256）。
- 服务器以房主清单为基准，列出缺失或哈希不同的文件。
- 内置托管模式下服务器可直接读取房主本机 `mods/`，按 256 KiB 分块通过 TCP 传输；接收方整文件 SHA-256 校验，失败自动重试 2 次。
- 房间大厅实时显示同步文件名与百分比；完成后会提示重启游戏以启用新模组。
- 传输不会阻塞选歌/聊天/开局流程。

## 联机身份

- 首次使用会在存档目录生成 `seiun_online_profile.json`，包含随机设备码、昵称、头像。
- 设备码是唯一身份主键，昵称可重名；不采集硬件序列号/MAC。
- 崩溃补报标记：`online_crash_report.json`。

## 离线构建

- `ONLINE_ALLOWED` 只在 desktop 构建默认定义。
- 不传该 define 时：无联机入口；GitHub 更新检查仍会默认启用（可在 设置 → 视觉 中关闭）。
- Android / iOS 构建默认也启用更新检查，使用异步网络请求，不阻塞启动流程。
- Android 如需实验性联机：`lime build android -D ONLINE_ALLOWED`。

## 服务端脚本

- 专用服务器和内置托管都会加载 `server/scripts/*.hx` 与 `mods/server/*.hx`。
- 钩子：`onInit`、`onRoomCreate`、`onPlayerJoin`、`onPlayerLeave`、`onInput`、`onJudge`、`onChat`、`onModSync`、`onGameStart`、`onGameEnd`。
- 脚本是服主可信代码；默认屏蔽 `sys.io.File`、`sys.io.Process`、`sys.net.Socket`、`haxe.Http` 等危险 import。
- 示例：`server/scripts/example.hx`。
