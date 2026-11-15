# 安卓原生崩溃报告指南 / Android native crash reports

SeiunEngine 底层(C++)崩溃处理在安卓上的完整说明:抓到什么、在哪看、怎么拿到**出错的 C++ 文件和行号**。

## 一、崩溃时引擎会自动记录什么

安卓上发生 SIGSEGV / SIGABRT / SIGBUS / SIGFPE / SIGILL 或 LuaJIT PANIC 时,原生崩溃钩子(不依赖 Haxe 层存活)会写下一份完整报告:

- **信号信息**:信号类型、si_code(如 `SEGV_MAPERR` = 访问了未映射地址)、出错的内存地址 si_addr
- **寄存器快照**(arm64 / armv7):PC、SP、LR、x0~x30 全量,PC 会直接标注它落在哪个 so 的哪个偏移
- **调用栈回溯**:从内核信号上下文展开,每帧格式与系统 tombstone 一致:
  ```
  #03 pc 00b0f2e4 libApplicationMain-64.so [source/backend/Foo.cpp:123]
  ```
- **C++ 文件:行号**(配置了 linemap 时,见下文第三节)
- **设备信息**:机型、厂商、Android 版本、ABI、build fingerprint
- **构建指纹**(报告的 `Build:` 行):ABI、so 文件名、大小、mtime 与内容哈希,以及本次加载的 linemap 身份;这是判断「报告属于哪次构建」的唯一依据
- **引擎上下文**:游戏版本、崩溃时的 state/歌曲、GL 错误状态、**最近 30 条引擎日志**
- **/proc/self/maps 快照**:同名 `_maps.txt` 文件,离线符号化必需
- 以上全部内容**同步镜像到 logcat**(tag `SeiunEngine-Crash`)

崩溃文件位于 `/storage/emulated/0/Android/data/com.mohong.Seiunengine/files/crash/native_crash_日期时间.txt`。下次启动游戏会自动弹出崩溃恢复界面并提示文件路径;崩溃文件不会被删除,方便上报 issue。

钩子由 C++ 构造期(`__attribute__((constructor))`)安装,**早于 hxcpp 的 `__boot_all()`**:即使崩溃发生在任何 Haxe 代码之前(类静态初始化),报告同样会落盘并镜像到 logcat,崩溃目录也会提前指向上面那个可写目录(进程 cwd 在安卓是 `/`,不可写)。

> 栈溢出型 SIGSEGV 也能抓到:信号处理器运行在独立的 altstack 上。

## 二、怎么拿到崩溃文件

**方法 A(推荐):adb**
```bash
adb logcat -d -s SeiunEngine-Crash > crash_log.txt      # 直接从 logcat 拿全部报告
adb pull /storage/emulated/0/Android/data/com.mohong.Seiunengine/files/crash/ ./crash/
```

**方法 B(玩家上报)**:游戏自带的崩溃恢复界面 → 复制日志;或文件管理器进入上面的 crash 目录。

## 三、拿到 C++ 文件:行号(crash linemap)

安卓的 so 在 release 打包时被 strip,运行时无法直接解析函数名和行号。引擎为此支持**预生成行号映射表**(linemap):把编译产物中未 strip 的 `.so` 的 DWARF 行表提取成紧凑二进制文件,崩溃时由原生层直接二分查找,在报告里输出精确的 `[source/xxx.cpp:行号]`。

linemap **不再属于构建流水线**了:一次 `lime build` 不会生成它,`Project.xml` 也不再把它当常驻资产嵌进 APK。要走这条路,手工做一次,然后把表推到设备上。

1. **正常构建一次**。`Project.xml` 对 android release 打开着 `HXCPP_DEBUG_LINK_AND_STRIP`,所以 hxcpp 在 strip 部署件之前会另存一份未剥离副本;构建结束时的 `<postbuild>`(`tools/SymbolsAfterBuild.hx`)把这份副本移到 `export/symbols/android-release/`,和 `build.json` / `build-info.txt` 放在一起。APK 内的 so 仍是 strip 版,不受影响:

   ```bash
   haxelib run lime build android -arm64
   ```

2. **生成表**。工具自己挑同一次构建里最新、确实带 DWARF 的那份 .so(`--abi` 可只做一种 ABI):

   ```bat
   python tools\crash.py linemap --android release --abi arm64-v8a
   ```

   产物是 `assets\linemap\arm64-v8a.bin`(实测约 0.8~0.9MB,只含地址→`文件:行` 的紧凑表)。

3. **推到设备**(不改 APK):

   ```bash
   adb push assets/linemap/arm64-v8a.bin /storage/emulated/0/Android/data/com.mohong.Seiunengine/files/linemap/
   ```

   引擎启动时优先从存储目录 `linemap/<abi>.bin` 加载;那里没有时才去找 APK 内嵌的资产(当前 `Project.xml` 不嵌,所以发布包默认没有行号表)。

4. 复现崩溃,报告中即包含 `[source/backend/xxx.cpp:行号]`。

> 表必须与设备上运行的 so 是**同一次编译**的产物:地址一变,旧表给出的行号就是错的(比没有更糟)。`crash.py linemap` 因此会拒绝比部署件更老的 DWARF 副本,覆盖率低于门槛也会拒绝写表。
> 没有表时报告仍然完整,只是行号列缺失(偏移可离线符号化,见第四节)。

### 报告的 `Build:` 行怎么用

安卓侧报告头形如:

```
Build: abi=arm64-v8a | so=libApplicationMain.so | size=46123456B@1790405812s#fae5fdb6 | linemap=arm64-v8a:12345678B#77b61b1d
```

- `size` + `#hash` 由运行中的 so 自身算出,**稳定**;`@mtime` 是设备上的安装时间,会变,不用管。
- `linemap=...` 是本进程实际加载的那张表(字节数与整表哈希),证明报告里的 `[file:line]` 出自哪张表;没有加载表时这一段为空。
- 与发布包配套的 `build.json` / `build-info.txt`(在 `SeiunEngine-symbols-<版本>.zip` 的 `android-<abi>/` 里)列出的就是同样的片段:对上 `so ... size=...B#hash` 即可确认符号包是否匹配该 APK。
- 本地可用 `python tools\crash.py resolve <文件>` / `whole <文件>` 复算同一哈希。

### 注意

- linemap 必须与设备上运行的 so 是**同一次编译**的产物;改代码重新构建后要重新生成。
- 引擎按运行时 ABI(arm64-v8a / armeabi-v7a)自动选择对应文件,32 位包在 64 位设备上也不会拿错。

## 四、没有 linemap 时:离线符号化

报告里的 `pc 偏移 lib名.so` 与 Android tombstone 格式一致,可直接用 NDK 工具还原:

```bash
# 方式 1:ndk-stack(直接喂 logcat 或崩溃文件)
adb logcat -d -s SeiunEngine-Crash | ndk-stack -sym export/symbols/android-release

# 方式 2:llvm-symbolizer(精确到帧)
llvm-symbolizer --obj=export/symbols/android-release/libApplicationMain-arm64-v8a.so 0x00b0f2e4

# 方式 3:一条命令读完整份报告(需要 pyelftools)
python tools\crash.py symbolize crash/native_crash_XXXX.txt
```

`export/symbols/android-release/` 里就是那次构建挪出来的未 strip `.so`(名字带着 ABI);`_maps.txt` 快照里有各模块基址,跨 so 的帧同样可解。发布包 `SeiunEngine-symbols-<版本>.zip` 的 `android-<abi>/` 目录内容与它一致。

## 五、相关代码位置

| 内容 | 位置 |
|---|---|
| 原生钩子实现 | `source/backend/native_crash.inc` |
| Haxe 封装/linemap 加载 | `source/backend/NativeCrash.hx` |
| 上下文/日志注入(每 5 秒) | `source/backend/SystemDiag.hx` (`feedNativeCrash`) |
| 日志尾部导出 | `source/mohong/TraceManager.hx` (`getRecentCrashText`) |
| linemap 生成工具(安卓) | `python tools\crash.py linemap --android release` |
| 符号归集(每次构建后自动跑) | `tools/SymbolsAfterBuild.hx`(`Project.xml` 的 `<postbuild>`) |
| 发版符号打包(一个压缩包) | `python tools\crash.py package` |
| 构建指纹哈希(与 C++/Haxe 同算法) | `python tools\crash.py` 内 `hash_head_tail` |
| 崩溃恢复界面 | `source/states/CrashCatcherState.hx` |
