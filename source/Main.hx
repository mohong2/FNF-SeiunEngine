package;


import flixel.graphics.FlxGraphic;
 
import flixel.FlxGame;
import flixel.FlxG;
import flixel.FlxState;
import openfl.Assets;
import openfl.Lib;
import openfl.display.FPS;
import openfl.display.OldFPS;
import openfl.display.Sprite;
import openfl.events.Event;
import openfl.display.StageScaleMode;

//crash handler stuff
#if CRASH_HANDLER
import lime.app.Application;
import openfl.events.UncaughtErrorEvent;
import haxe.CallStack;
import haxe.io.Path;
#if cpp
import Discord.DiscordClient;
#end
#end
import mohong.Windows;
import mohong.TraceManager;
import mohong.TraceConsole;
import backend.Dialog;
import backend.SystemDiag;
import backend.GlErrorWatchdog;
import backend.NativeCrash;
import states.CrashCatcherState;
#if VIDEOS_ALLOWED
import backend.VideoPreloader;
#end

using StringTools;

#if linux
@:cppInclude('./external/gamemode_client.h')
@:cppFileCode('
	#define GAMEMODE_AUTO
')
#end

class Main extends Sprite
{
	public static var initialWindowX:Int;
	public static var initialWindowY:Int;
	var gameWidth:Int = 1280; // Width of the game in pixels (might be less / more in actual pixels depending on your zoom).
	var gameHeight:Int = 720; 
	// Height of the game in pixels (might be less / more in actual pixels depending on your zoom).
	#if mobile
	// Mobile must verify/extract the bundled assets before anything else runs, so the boot
	// starts in CopyState, which extends BootState and adds the extraction pass on top of
	// the shared boot splash (one loading screen on every platform). Desktop and web start
	// in BootState itself: splash + real graphics/sound precache, then the title.
	// Fully qualified: CopyState only exists on mobile, and Main.hx sits in the root package.
	var initialState:Class<FlxState> = states.CopyState;
	#else
	var initialState:Class<FlxState> = states.BootState; // The FlxState the game starts with.
	#end
	#if !android
	var zoom:Float = 1; // If -1, zoom is automatically calculated to fit the window dimensions.
	#else
	var zoom:Float = 1;
	#end
	var framerate:Int = 60; // Fallback only — real framerates come from ClientPrefs (see setupGame).
	var skipSplash:Bool = true; // Whether to skip the flixel splash screen that appears in release mode.
	var startFullscreen:Bool = false; // Whether to start the game in fullscreen on desktop targets
	public static var fpsVar:FPS;
	public static var oldFpsVar:OldFPS;
	public static var useOldFPS:Bool = false;
	public static var useOldPause:Null<Bool> = null;
	/**
	 * @deprecated Kept only so old scripts still compile. Background dim no longer writes
	 * `FlxG.sound.volume`; see backend.AudioDim.
	 */
	public static var originalVolume:Float = -1;
	#if ONLINE_ALLOWED
	// Constants the online client slice needs; this engine's Main.hx declares them here.
	// The value is this engine's own handshake version and the magic strings live in
	// online/Protocol.hx.
	//
	// This block intentionally keeps its line count stable so the macro-off product stays a
	// plain byte comparison; guarded by ONLINE_ALLOWED so that build is untouched.
	public static final CLIENT_PROTOCOL:Float = 1;
	// The social / network-room handshake version, sent by online/NetworkClient.hx.
	// Same as above: this engine's own counter; the matching magic lives in
	// online/Protocol.hx.
	//
	public static final NETWORK_PROTOCOL:Float = 1;
	public static var repoHost:String = '';
	#end
	// Windows 关闭动画状态（仅 Windows 目标使用）
	static var allowWindowClose:Bool = false;
	static var closeAnimStarted:Bool = false;
	// You can pretty much ignore everything from here on - your code should go in your states.

	public static function main():Void
	{
		// Install native crash hooks first, so even early startup faults leave a log with memory pointers.
		NativeCrash.install();
		// HTML5 has no ndll and no crash directory: the degraded path is window.onerror /
		// unhandledrejection -> console + localStorage + an overlay over the canvas.
		backend.Html5Fatal.install();
		// 脚本诊断日志（logs/script_log.txt）：记录每个被加载的脚本、被扫描的脚本目录、
		// 每次脚本报错，以及 onCreate / onCreatePost 分发给了谁。排查"模组脚本没生效"必备。
		backend.ScriptLog.begin();

		// Funnel 3 of the crash architecture: a Haxe exception that escapes main()
		// itself. Everything below this point - the engine sprite, the online
		// overlays, the window setup - is inside ONE try, so a failure there can no
		// longer fall through to hxcpp's C++ handler (which has no Haxe context left).
		// Report + dialog + exit; this function never throws.
		// Compile-time test lever (see backend/CrashTestHooks.hx): only exists in
		// builds made with -D seiun_test_hooks, so the shipping build has no path
		// to a deliberate fault here.
		backend.CrashTestHooks.sehProbe();

		try
		{
			backend.CrashTestHooks.mainThrow();
			boot();
		}
		catch (e:Dynamic)
		{
			reportCrash(e, null, 'startup');
		}
	}

	/**
	 * The boot sequence main() used to contain.
	 *
	 * Split out so every failure inside it lands in one place. Note the separate
	 * handler around "new Main()": if the engine sprite cannot even be constructed
	 * there is no FlxG to recover into, and the message must say "engine init"
	 * rather than pretending the game was running.
	 */
	static function boot():Void
	{
		#if mac
		// macOS: .app 由 Finder 双击启动时，进程工作目录是根目录 "/"，
		// 会导致 assets/、mods/、lang/ 等所有相对路径读取失败。
		// 这里把工作目录切换到 bundle 的资源目录，让全部相对路径正常解析。
		var resourcesDir:String = haxe.io.Path.directory(Sys.programPath()) + "/../Resources/";
		if (sys.FileSystem.exists(resourcesDir))
			Sys.setCwd(resourcesDir);
		#end

		try
		{
			Lib.current.addChild(new Main());
		}
		catch (e:Dynamic)
		{
			// No engine object means no stage, no FlxG, no recovery screen: report
			// with a startup-specific explanation and stop here.
			reportCrash(e, null, 'engine_init');
			return;
		}
		#if ONLINE_ALLOWED
		// The LoadingScreen overlay must exist before anything calls LoadingScreen.toggle(),
		// otherwise instance stays null and the toggle writes through a null pointer --
		// the native ACCESS_VIOLATION seen when opening the Online "Find" screen
		// (LoadingScreen.toggle +0x29, write fault, RAX=0).
		// Adding it after Main keeps the overlay on top of the game sprite, which is what
		// moving the game sprite to index 0 would achieve: the overlay is a sibling on
		// Lib.current, so draw order is what puts it above.
		Lib.current.addChild(new online.gui.LoadingScreen());
		// The network sidebar shell. It also lives on Lib.current, so it
		// outlives state changes and draws over the game; the Alert overlay stays above it.
		Lib.current.addChild(new online.gui.sidebar.SideUI());
		// The Alert overlay must also be created. Without it Alert.instance stays null and
		// every Alert.alert() writes through null (Alert.alert calls instance.addChild).
		// Crash map-located to ?alert@Alert_obj@@ +0x143, called from an OnlineOptionsState
		// closure (online/gui/Alert.hx:159).
		Lib.current.addChild(new online.gui.Alert());
		#end
		#if desktop
		applyWindowMode();
		Windows.enableDarkMode();
		#end
	}
		#if desktop
		/**
		 * Normalises the boot window. The *saved* mode cannot be applied from here: main()
		 * runs before the save file is read, so ClientPrefs still holds its defaults (which is
		 * why the saved mode used to be forgotten on every launch). TitleState applies the real
		 * mode as soon as the preferences are in memory.
		 */
		private static function applyWindowMode():Void
		{
			backend.WindowMode.apply(ClientPrefs.data.windowedmode);
		}
		#end

	public function new()
	{
		#if android
		SUtil.doPermissionsShit();
		// Floating keyboard button: show automatically if overlay permission is
		// already granted. The user-facing permission explanation dialog is
		// handled later from TitleState (after Language.load) by
		// SUtil.maybeRequestOverlayPermission() so it is localized and modern.
		backend.SeiunOverlay.maybeAutoShow();
		#end
		#if sys
		// One entry point for the process cwd, the native crash directory and the crash
		// linemap: they must never resolve the storage root independently. ClientPrefs is
		// not loaded yet here, so this uses the version-aware default type; CopyState (and
		// TitleState on desktop) re-applies the directory once the player's saved
		// storageType is actually in memory.
		SUtil.applyStorageDirectory();
		#end
		
		super();
		

		#if HSCRIPT_ALLOWED
        HScript.initialize();
        #end

        // 初始化 TraceManager（尽早拦截所有 trace() 调用）
        TraceManager.init();
        TraceManager.info('trace.systemInit', 'TraceManager initialized successfully.');

        // Windows 桌面启动 TraceConsole 交互式面板（是否实际输出由 syncWithPrefs/开关决定）
        #if (desktop && !android)
        TraceConsole.start();
        #end

        // 桌面端：注册窗口文件拖放（拖 zip / 链接自动安装）
        backend.ModInstaller.init();

		if (stage != null)
		{
			init();
		}
		else
		{
			addEventListener(Event.ADDED_TO_STAGE, init);
		}
	}

	private function init(?E:Event):Void
	{
		if (hasEventListener(Event.ADDED_TO_STAGE))
		{
			removeEventListener(Event.ADDED_TO_STAGE, init);
		}

		setupGame();
	}

	private function setupGame():Void
	{
		// Install the background-dim focus handling before FlxGame registers its own
		// ACTIVATE handler, so the attenuation is already reset when flixel resumes sounds.
		setupBackgroundDim();

		var stageWidth:Int = Lib.current.stage.stageWidth;
		var stageHeight:Int = Lib.current.stage.stageHeight;

		if (zoom == -1)
		{
			var ratioX:Float = stageWidth / gameWidth;
			var ratioY:Float = stageHeight / gameHeight;
			zoom = Math.min(ratioX, ratioY);
			gameWidth = Math.ceil(stageWidth / zoom);
			gameHeight = Math.ceil(stageHeight / zoom);
		}
		ClientPrefs.loadDefaultKeys();

		// Native crash reports carry the engine identity + (on Android) the
		// precomputed address->cpp-line table for exact file:line output.
		#if sys
		var appVersion:String = null;
		try { appVersion = Lib.application.meta.get('version'); } catch (e:Dynamic) {}
		if (appVersion == null || appVersion.length == 0) appVersion = '?';
		NativeCrash.setAppInfo('SeiunEngine ' + appVersion);
		// Tie every crash report to the exact exe/PDB pair, so offsets can never be
		// resolved against a stale symbol file again.
		NativeCrash.setBuildInfo();
		#end
		#if (android || windows)
		// Windows looks the embedded linemap up by the running exe name, which is
		// the same string the native annotation compares module names against.
		var linemapLib:String = 'libApplicationMain';
		#if windows
		linemapLib = haxe.io.Path.withoutDirectory(Sys.programPath());
		#end
		SUtil.applyStorageDirectory(false, linemapLib);
		#end

		// Wire ClientPrefs framerate/drawFramerate into FlxGame (was 60/60).
		var updateFramerate:Int = ClientPrefs.data.framerate;
		var drawFramerate:Int = ClientPrefs.data.drawFramerate;

		#if (mobile || switch)
		// Cap at the panel refresh rate; drawing faster just burns battery.
		var refreshRate:Int = 0;
		try { refreshRate = FlxG.stage.application.window.displayMode.refreshRate; } catch (e:Dynamic) {}
		if (refreshRate < 60) refreshRate = 60;
		if (updateFramerate > refreshRate) updateFramerate = refreshRate;
		if (drawFramerate > refreshRate) drawFramerate = refreshRate;
		#end

		// Bad save values shouldn't nuke the engine.
		if (updateFramerate < 30) updateFramerate = framerate;
		if (drawFramerate < 30) drawFramerate = framerate;

		// The test-build notice is queued by BootState.handOver() after the boot screen has
		// finished loading, so release and test builds share the same entry state.

		addChild(new FlxGame(gameWidth, gameHeight, initialState, zoom, updateFramerate, drawFramerate, skipSplash, startFullscreen));


		// Image residency backend: release CPU pixels only after the renderer has
		// uploaded them, and re-decode transparently on demand. Installed before
		// the first state so the very first assets are covered.
		backend.gfx.GfxMemory.install();

		// Bottom-right build watermark (openfl stage child): above every state and substate,
		// no flixel camera, no input. Hidden while a song is playing.
		backend.Watermark.install();

#if ONLINE_ALLOWED
			// Registers the two online plugins. Waiter is a
		// FlxBasic that drains the message queues every frame -- every online onMessage handler
		// ends in Waiter.put/putPersist (startSong, noteHit, state callbacks, sendPending ...),
		// so without the plugin none of those callbacks ever run. DownloadAlerts must exist
		// before any DownloadAlert is constructed: its constructor does
		// DownloadAlerts.instance.addChild(this) (online/gui/DownloadAlert.hx:127).
		FlxG.plugins.add(new online.backend.Waiter());
		addChild(new online.gui.DownloadAlert.DownloadAlerts());
#end

		#if android
		// SDL3 的 Android 返回键 keycode 与 FlxG.android 内置的旧 keycode 不同，
		// 在这里做一次全局翻译，保证返回键暂停/退出菜单等逻辑继续生效。
		backend.AndroidBackFix.init();
		#end

		// Warm up LibVLC in the background so the first video cutscene doesn't
		// freeze the main thread while hxvlc scans/resets its plugin cache.
		#if VIDEOS_ALLOWED
		VideoPreloader.warmup();
		#end

		// REC badge used while a video render is running (desktop only).
		#if desktop
		backend.RenderIndicator.install();
		#end

		// 每次状态切换时，旧 state 已 destroy、FlxG.bitmap.clearCache() 已执行，
		// 这里统一清掉上一状态残留的 Paths 图片缓存，避免反复进出关卡内存只增不减。
		FlxG.signals.preStateCreate.add(function(_) {
			Paths.clearStoredMemory();
			Paths.clearUnusedMemory();
			// Drop queued keys belonging to the state that just went away.
			backend.gfx.GfxMemory.onStateSwitch();
		});

		// Poll GL errors on render frames: renderer faults end up in crash reports.
		GlErrorWatchdog.install();

		// Heartbeat: last known state survives even a process killed below the Haxe layer.
		SystemDiag.setupHeartbeat();

		// Sync separateUpdateDraw (the property setter keeps FlxGame in sync).
		// While the mode is on, an idle render tick - one that ran no logic step - re-presents the
		// draw commands already recorded on the camera canvases instead of rebuilding them.
		// The flag is mirrored from the mode that is actually in effect, not from the preference.
		// See FlxG.separateDrawSkipIdleFrames and FlxGame.invalidateDrawCache().
		if (FlxG.game != null)
		{
			FlxG.game.separateUpdateDraw = ClientPrefs.data.separateUpdateDraw;
			FlxG.separateDrawSkipIdleFrames = FlxG.game.separateUpdateDraw;
		}

		// Ensure draw wrapper is null (threaded rendering removed)
		if (FlxG.game != null)
			FlxG.game.drawWrapper = null;

		#if CRASH_HANDLER
		// Wire the timer crash callback so separate-update-mode errors are
		// handled gracefully with the original stack trace preserved.
		if (FlxG.game != null)
		{
			FlxG.game.onTimerCrashCallback = function(msg:String, stack:String)
			{
				var path:String;
				var dateNow:String = Date.now().toString();
				dateNow = dateNow.replace(" ", "_");
				dateNow = dateNow.replace(":", "'");
				path = "./crash/" + "SeiunEngine_" + dateNow + ".txt";

				// Capture the GL error state at the crash moment (main thread).
				GlErrorWatchdog.pollNow(true);

				// Full dump: error + stack + system/renderer info + recent logs.
				var fullMsg:String = SystemDiag.buildCrashDump(msg, stack, states.CrashCatcherState.crashCount + 1);
				fullMsg += "\nPlease report this error to the GitHub page: https://github.com/mohong2/FNF-SeiunEngine\n\n> SeiunEngine by mo_hong · Crash Handler written by: sqirra-rng ";

				#if sys
				if (!sys.FileSystem.exists("./crash/"))
					sys.FileSystem.createDirectory("./crash/");
				sys.io.File.saveContent(path, fullMsg + "\n");

				Sys.println(fullMsg);
				Sys.println("Crash dump saved in " + haxe.io.Path.normalize(path));
				#end

				// Store crash info for the in-game crash catcher
				states.CrashCatcherState.lastCrashMessage = msg;
				states.CrashCatcherState.lastCrashStack = stack;
				states.CrashCatcherState.lastCrashPath = path;
				states.CrashCatcherState.crashCount++;


				// Show a native dialog first
				var dialogTitle:String = Language.get("CrashCatcher.dialog.title", "Game Crashed!");
				var githubUrl:String = Language.get("CrashCatcher.reportURL", "https://github.com/mohong2/FNF-SeiunEngine/issues");
				var dialogMsg:String = Language.get("CrashCatcher.dialog.message",
					"The game has encountered an error and needs to recover.\n\nError: {error}\n\nCrash dump saved to: {path}\n\nPlease report this on GitHub:\n{url}\n\nClick OK to enter recovery screen.");
				dialogMsg = dialogMsg.replace("{error}", msg);
				dialogMsg = dialogMsg.replace("{path}", path);
				dialogMsg = dialogMsg.replace("{url}", githubUrl);
				backend.Dialog.show(dialogTitle, dialogMsg, 'Error');

				// Queue the state switch (FlxG.switchState sets _requestedState;
				// FlxGame.timerCrashRecovery will complete it via switchState())
				try
				{
					if (FlxG.game != null && !Std.isOfType(FlxG.state, states.CrashCatcherState))
					{
						FlxG.switchState(new states.CrashCatcherState());
					}
				}
				catch (ex:Dynamic)
				{
					// Fallback: show another dialog and exit
					var fallbackTitle:String = Language.get("CrashCatcher.dialog.fallbackTitle", "Fatal Error");
					var fallbackMsg:String = Language.get("CrashCatcher.dialog.fallbackMessage", "Could not enter recovery mode.\nThe game will now close.");
					backend.Dialog.show(fallbackTitle, fallbackMsg, 'Error');
					#if cpp
					DiscordClient.shutdown();
					#end
					#if sys
					Sys.exit(1);
					#end
				}
			};
		}
		#end

		// ── Window icon from active mod's pack.json ──
		// Uses ModConfig.setWindowIcon() which supports multi‑resolution icons
		// (16×16 … 64×64) and handles scaling.  Can also be called later at
		// runtime when the user switches mods (see ModState.applyModPackConfig).
		#if (desktop && MODS_ALLOWED)
		setModWindowIcon();
		#end

		// [TEST] Sync drag-to-wheel setting from ClientPrefs to FlxMouse at startup
		initDragToWheel();

		fpsVar = new FPS(10, 3, 0xFFFFFF);
		oldFpsVar = new OldFPS(10, 3, 0xFFFFFF);
		addChild(fpsVar);
		addChild(oldFpsVar);

		Lib.current.stage.align = "tl";
		Lib.current.stage.scaleMode = StageScaleMode.NO_SCALE;

		// Device-pixel aware scaling (see backend/RenderScale.hx). Must come after
		// the stage scale mode above: setting that fires a RESIZE which applies the
		// stock RatioScaleMode one last time.
		backend.RenderScale.install();
		TraceManager.info('trace.render.scaleMode', 'Render scale: {}', [backend.RenderScale.describe()]);

		if(fpsVar != null) {
			fpsVar.visible = ClientPrefs.data.showFPS && !useOldFPS;
			oldFpsVar.visible = ClientPrefs.data.showFPS && useOldFPS;
		}


		// 每帧通过 hscript 触发 onFrameUpdate 事件，供脚本自定义更新
		#if HSCRIPT_ALLOWED
		addEventListener(Event.ENTER_FRAME, function(_) {
			HScript.callOnGlobalScript("onFrameUpdate", []);
		});
		#else

		#end
		#if html5
		FlxG.autoPause = false;
		FlxG.mouse.visible = false;
		#else
		FlxG.mouse.visible = true;
		#end
		
		#if CRASH_HANDLER
		Lib.current.loaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onCrash);
		#end

		// ── Window close interceptor (X button) ──
		setupWindowCloseHandler();
	}

	/**
	 * Intercept the window close button (X) to warn about unsaved editor changes.
	 * 拦截窗口关闭按钮（X），在有未保存的编辑器更改时发出警告。
	 *
	 * Uses Lime's onClose event + cancel() mechanism.
	 * NativeWindow dispatches onClose, then checks onClose.canceled — if true,
	 * the native WM_CLOSE is blocked.
	 *
	 * Windows 目标额外播放可配置的关闭动画（样式与速度见设置中的
	 * 「关闭动画」/「关闭动画速度」），动画结束后才真正关闭窗口；
	 * 其他桌面平台保持原行为（直接关闭）。
	 */
	static function setupWindowCloseHandler():Void
	{
		#if desktop
		var window = Lib.application.window;
		if (window == null) return;

		window.onClose.add(function()
		{
			// 动画完成后的最终关闭：不再拦截，放行原生关闭
			if (allowWindowClose) return;

			if (backend.UnsavedChangesTracker.hasUnsavedChanges)
			{
				if (!backend.UnsavedChangesTracker.onWindowQuit())
				{
					// User cancelled — cancel the close event
					window.onClose.cancel();
					return;
				}
			}


			#if windows
			// 未启用关闭动画：直接放行原生关闭
			var closeStyle:String = ClientPrefs.data.closeAnimStyle;
			if (closeStyle != null && closeStyle == 'off')
				return;

			// 关闭动画播放中：拦截重复的关闭请求（防 Alt+F4 连按）
			if (closeAnimStarted)
			{
				window.onClose.cancel();
				return;
			}

			// 拦截本次原生关闭，先播动画，动画结束后再真正关闭
			window.onClose.cancel();
			startCloseAnimation(window);
			#end
		});
		#end
	}

	#if windows
	/**
	 * 从脚本返回值里取字段。Lua 表在非 JS 目标上会转成匿名对象，
	 * HScript 返回的对象也是匿名结构，用 Reflect 直接取即可。
	 */
	static function scriptField(obj:Dynamic, name:String):Dynamic
	{
		if (obj == null) return null;
		if (Reflect.hasField(obj, name))
			return Reflect.field(obj, name);
		return null;
	}

	/** 把脚本返回值里的字段安全地转成 Float，失败用 fallback。 */
	static function scriptNumField(obj:Dynamic, name:String, fallback:Float):Float
	{
		var v:Dynamic = scriptField(obj, name);
		if (v == null) return fallback;
		var f:Float = Std.parseFloat(Std.string(v));
		return Math.isNaN(f) ? fallback : f;
	}

	/** 调用当前状态附带的 Lua 脚本（模组写在 data/states/<State>.lua 等位置）。 */
	static function callCloseAnimLua(func:String, args:Array<Dynamic>):Dynamic
	{
		#if LUA_ALLOWED
		var state = FlxG.state;
		if (state != null && Std.isOfType(state, backend.MusicBeatState))
			return cast(state, backend.MusicBeatState).callOnLuas(func, args);
		#end
		return null;
	}

	/**
	 * 模组扩展入口 1：onCloseAnimStart(style, speed)
	 * 返回 null 表示不改动；返回字符串可换成自定义样式名（未知样式按“缩放”兜底，
	 * 配合 onCloseAnimUpdate 逐帧覆盖即可实现完全自定义动画）；
	 * 返回 {style=..., duration=...} 可同时改样式和总时长；返回 "off" 直接关闭。
	 */
	static function callCloseAnimStart(style:String, speed:Float):Dynamic
	{
		var ret:Dynamic = null;
		#if HSCRIPT_ALLOWED
		var hxRet:Dynamic = HScript.callOnGlobalScript('onCloseAnimStart', [style, speed]);
		if (hxRet != null && hxRet != 0) ret = hxRet;
		#end
		#if LUA_ALLOWED
		var luaRet:Dynamic = callCloseAnimLua('onCloseAnimStart', [style, speed]);
		if (luaRet != null && luaRet != 0) ret = luaRet;
		#end
		return ret;
	}

	/**
	 * 模组扩展入口 2：onCloseAnimUpdate(progress, style, speed)
	 * 每帧调用，progress 0→1。返回 {x=..., y=..., width=..., height=...}
	 * 可覆盖窗口变换（返回 null 则使用内置计算）。
	 */
	static function callCloseAnimUpdate(progress:Float, style:String, speed:Float):Dynamic
	{
		var ret:Dynamic = null;
		#if HSCRIPT_ALLOWED
		var hxRet:Dynamic = HScript.callOnGlobalScript('onCloseAnimUpdate', [progress, style, speed]);
		if (hxRet != null && hxRet != 0) ret = hxRet;
		#end
		#if LUA_ALLOWED
		var luaRet:Dynamic = callCloseAnimLua('onCloseAnimUpdate', [progress, style, speed]);
		if (luaRet != null && luaRet != 0) ret = luaRet;
		#end
		return ret;
	}

	/** 模组扩展入口 3：onCloseAnimEnd(style)，动画结束、真正关闭前调用。 */
	static function callCloseAnimEnd(style:String):Void
	{
		#if HSCRIPT_ALLOWED
		HScript.callOnGlobalScript('onCloseAnimEnd', [style]);
		#end
		#if LUA_ALLOWED
		callCloseAnimLua('onCloseAnimEnd', [style]);
		#end
	}

	/**
	 * 关闭动画：按设置中的样式（off/squeeze/zoom/drop/slide）与速度倍率播放，
	 * 完成后才真正调用 window.close()。
	 * 模组可通过 HScript 全局脚本 / 当前状态 Lua 脚本实现自定义关闭动画。
	 *
	 * 使用主线程 ENTER_FRAME 驱动，不依赖 FlxG 的更新循环，
	 * 因此在暂停菜单等状态下按 Alt+F4 也能正常播放。
	 */
	static function startCloseAnimation(window:lime.ui.Window):Void
	{
		closeAnimStarted = true;

		var style:String = ClientPrefs.data.closeAnimStyle;
		var speed:Float = ClientPrefs.data.closeAnimSpeed;
		if (style == null || style.length == 0) style = 'squeeze';
		if (speed <= 0) speed = 1.0;

		// ── 模组扩展：onCloseAnimStart 可改样式 / 时长，或返回 'off' 直接关闭 ──
		var customDuration:Float = -1;
		var startRet:Dynamic = callCloseAnimStart(style, speed);
		if (startRet != null && startRet != 0)
		{
			if (Std.isOfType(startRet, String))
				style = Std.string(startRet);
			else
			{
				var s:Dynamic = scriptField(startRet, 'style');
				if (s != null) style = Std.string(s);
				var d:Dynamic = scriptField(startRet, 'duration');
				if (d != null)
				{
					var dv:Float = Std.parseFloat(Std.string(d));
					if (!Math.isNaN(dv) && dv > 0) customDuration = dv;
				}
			}
		}

		// 未启用关闭动画：直接关闭
		if (style == 'off')
		{
			callCloseAnimEnd(style);
			allowWindowClose = true;
			window.close();
			return;
		}

		// 全屏时窗口尺寸无法正常缩放，先退回窗口模式再播动画
		if (window.fullscreen)
			window.fullscreen = false;

		// 以退出全屏后的实际尺寸为准（退出全屏会触发一次 resize）
		var startWidth:Int = window.width;
		var startHeight:Int = window.height;
		var centerX:Float = window.x + startWidth * 0.5;
		var centerY:Float = window.y + startHeight * 0.5;

		var minSize:Int = 1; // 避免缩到 0 导致渲染/系统异常

		// 基础时长（秒），除以速度倍率得到实际时长
		var durationH:Float = 0.30 / speed; // squeeze 高度段
		var durationW:Float = 0.35 / speed; // squeeze 宽度段
		var duration:Float = switch (style)
		{
			case 'zoom': 0.40 / speed;
			case 'drop': 0.50 / speed;
			case 'slide': 0.50 / speed;
			default: 0.40 / speed; // squeeze 外的未知样式（模组自定义）按缩放兜底
		}
		if (customDuration > 0) duration = customDuration / speed;

		var phase:Int = 0; // 0 = 高度，1 = 宽度
		var t0:Float = haxe.Timer.stamp();
		var stage = Lib.current.stage;
		if (stage == null) // 极端情况：没有舞台就直接关
		{
			allowWindowClose = true;
			window.close();
			return;
		}

		var onFrame:openfl.events.Event->Void = null;
		onFrame = function(_)
		{
			var elapsed:Float = haxe.Timer.stamp() - t0;
			var curDuration:Float = (style == 'squeeze') ? (phase == 0 ? durationH : durationW) : duration;
			var progress:Float = Math.min(1, elapsed / curDuration);
			// 快速起步、末尾放缓，让「压扁」显得干脆
			var eased:Float = progress * (2 - progress);

			var newWidth:Int = startWidth;
			var newHeight:Int = startHeight;
			var newX:Float = centerX - startWidth * 0.5;
			var newY:Float = centerY - startHeight * 0.5;

			var builtin:String = switch (style)
			{
				case 'squeeze': 'squeeze';
				case 'drop': 'drop';
				case 'slide': 'slide';
				default: 'zoom'; // 模组自定义样式兜底为缩放
			}
			switch (builtin)
			{
				case 'zoom':
					newWidth = Math.round(startWidth * (1 - eased));
					newHeight = Math.round(startHeight * (1 - eased));
					newX = centerX - newWidth * 0.5;
					newY = centerY - newHeight * 0.5;

				case 'drop':
					newWidth = Math.round(startWidth * (1 - eased));
					newHeight = Math.round(startHeight * (1 - eased));
					newX = centerX - newWidth * 0.5;
					// 下落：先慢后快的重力感
					var fall:Float = progress * progress;
					newY = centerY - newHeight * 0.5 + startHeight * fall * 1.2;

				case 'slide':
					newWidth = Math.round(startWidth * (1 - eased));
					newHeight = Math.round(startHeight * (1 - eased));
					newY = centerY - newHeight * 0.5;
					// 向左滑出屏幕
					newX = centerX - newWidth * 0.5 - startWidth * eased * 0.7;

				default: // squeeze：先压扁高度，再压扁宽度
					if (phase == 0)
					{
						newHeight = Math.round(startHeight * (1 - eased));
						newY = centerY - newHeight * 0.5;
					}
					else
					{
						newWidth = Math.round(startWidth * (1 - eased));
						newHeight = minSize;
						newX = centerX - newWidth * 0.5;
						newY = centerY - newHeight * 0.5;
					}
			}

			// ── 模组扩展：onCloseAnimUpdate 逐帧覆盖窗口变换 ──
			var overrideRet:Dynamic = callCloseAnimUpdate(progress, style, speed);
			if (overrideRet != null && overrideRet != 0)
			{
				newWidth = Std.int(scriptNumField(overrideRet, 'width', newWidth));
				newHeight = Std.int(scriptNumField(overrideRet, 'height', newHeight));
				newX = scriptNumField(overrideRet, 'x', newX);
				newY = scriptNumField(overrideRet, 'y', newY);
			}

			if (newWidth < minSize) newWidth = minSize;
			if (newHeight < minSize) newHeight = minSize;

			window.width = newWidth;
			window.height = newHeight;
			window.x = Math.round(newX);
			window.y = Math.round(newY);

			if (progress >= 1)
			{
				if (style == 'squeeze' && phase == 0)
				{
					// 高度压扁完成，进入宽度段
					phase = 1;
					t0 = haxe.Timer.stamp();
					window.height = minSize;
				}
				else
				{
					stage.removeEventListener(Event.ENTER_FRAME, onFrame);
					callCloseAnimEnd(style);
					allowWindowClose = true;
					window.close();
				}
			}
		};

		stage.addEventListener(Event.ENTER_FRAME, onFrame);
	}
	#end

	/** [TEST] Initialize FlxMouse drag-to-wheel from saved setting. */
	static function initDragToWheel():Void
	{
		#if !FLX_UNIT_TEST
		if (FlxG.mouse != null)
		{
			FlxG.mouse.dragToWheelEnabled = ClientPrefs.data.touchSwipeEnabled;
		}
		#end
	}

	/**
	 * Installs the desktop background-dim focus handling and re-evaluates it.
	 *
	 * Kept as the single entry point used by the boot path and the options menu; the state
	 * itself lives in backend.AudioDim. That module attenuates FlxSound output with a
	 * multiplier instead of writing FlxG.sound.volume, so the player's volume (and what
	 * flixel's sound tray persists) is never overwritten by a focus change.
	 */
	public static function setupBackgroundDim():Void
	{
		backend.AudioDim.install();
		backend.AudioDim.refresh();
	}

	// Code was entirely made by sqirra-rng for their fnf engine named "Izzy Engine", big props to them!!!
	// very cool person for real they don't get enough credit for their work
	#if CRASH_HANDLER
	/**
	 * Runtime uncaught error (UncaughtErrorEvent). Thin wrapper: the reporting
	 * itself lives in reportCrash() so a startup failure produces the exact same
	 * dump, directory and file naming as a mid-game crash.
	 */
	function onCrash(e:UncaughtErrorEvent):Void
	{
		// We own the aftermath (recovery screen or a native box + exit), so stop the
		// default "print the stack and kill the process" handling first.
		try { e.preventDefault(); } catch (x:Dynamic) {}
		var error:Dynamic = null;
		try { error = e.error; } catch (x:Dynamic) {}
		reportCrash(error, null, 'uncaught');
	}
	#end

	/**
	 * The one Haxe-side crash reporter, used by:
	 *   - onCrash()          (runtime uncaught error, origin "uncaught")
	 *   - main()/boot()      (startup failure,    origin "startup"/"engine_init")
	 *
	 * What it does, in the order that matters when the process is already sick:
	 *   1. snapshot the GL error state (the renderer may not answer later),
	 *   2. build the SystemDiag dump (engine/OS/window/renderer/logs),
	 *   3. append the C++ diagnostics block (OS, GPU/driver, GetLastError, lime
	 *      module probe, loaded modules), the shared diagnosis text and the origin,
	 *   4. write crash/SeiunEngine_<date>.txt (UTF-8 + BOM, same prefix as always),
	 *   5. hand over to the recovery screen when the engine still exists, otherwise
	 *      show a native UTF-16 dialog with the report path and exit.
	 *
	 * Every step is individually guarded: a failure while reporting must not lose
	 * the report that was already produced, and this function must never throw.
	 */
	public static function reportCrash(error:Dynamic, ?stackLines:String, ?origin:String = 'uncaught'):Void
	{
		var message:String = '';
		try { message = Std.string(error); } catch (x:Dynamic) { message = '(unprintable exception)'; }
		if (message == null || message.length == 0) message = '(empty exception)';
		if (stackLines == null || stackLines.length == 0) stackLines = collectCrashStack();

		var path:String = crashReportPath();

		#if js
		// No crash/ directory in a browser: console + localStorage + overlay.
		backend.Html5Fatal.report(origin, message, stackLines);
		#end

		// Capture the GL error state at the crash moment (main thread).
		try { GlErrorWatchdog.pollNow(true); } catch (x:Dynamic) {}

		var fullMsg:String = '';
		try
		{
			fullMsg = SystemDiag.buildCrashDump(message, stackLines, CrashCatcherState.crashCount + 1);
		}
		catch (x:Dynamic)
		{
			fullMsg = '=== SeiunEngine Crash Report ===\n'
				+ 'Error: ' + message + '\n'
				+ '(the full system dump could not be built: ' + Std.string(x) + ')\n'
				+ 'Stack:\n' + stackLines + '\n';
		}

		// Same sections as the C++ reporter: OS / GPU+driver / last Win32 error /
		// lime module probe / loaded modules. Without this a "Could not load module
		// lime@lime_init" report says nothing about *why* it could not.
		try { fullMsg += NativeCrash.collectDiag(); } catch (x:Dynamic) {}

		// The diagnosis table is shared with the C++ funnel (native_crash.inc).
		var advice:String = '';
		try { advice = NativeCrash.explainFatal(origin, message); } catch (x:Dynamic) {}
		if (advice.length > 0) fullMsg += '\n--- Diagnosis ---\n' + advice;

		fullMsg += '\n--- Report ---\nOrigin: ' + origin + '\nFile: ' + path + '\n';
		fullMsg += '\nPlease report this error to the GitHub page: https://github.com/mohong2/FNF-SeiunEngine\n\n> SeiunEngine by mo_hong · Crash Handler written by: sqirra-rng ';

		writeCrashReport(path, fullMsg);

		// Store crash info for the in-game crash catcher.
		CrashCatcherState.lastCrashMessage = message;
		CrashCatcherState.lastCrashStack = stackLines;
		CrashCatcherState.lastCrashPath = path;
		CrashCatcherState.crashCount++;

		var dialogTitle:String = Language.get("CrashCatcher.dialog.title", "Game Crashed!");
		var githubUrl:String = Language.get("CrashCatcher.reportURL", "https://github.com/mohong2/FNF-SeiunEngine/issues");
		var dialogMsg:String = Language.get("CrashCatcher.dialog.message",
			"The game has encountered an error and needs to recover.\n\nError: {error}\n\nCrash dump saved to: {path}\n\nPlease report this on GitHub:\n{url}\n\nClick OK to enter recovery screen.");
		dialogMsg = dialogMsg.replace("{error}", message);
		dialogMsg = dialogMsg.replace("{path}", path);
		dialogMsg = dialogMsg.replace("{url}", githubUrl);
		if (advice.length > 0) dialogMsg += "\n\n" + advice;

		// Before Language.load() there are no lang files in memory, so the keys
		// above fall back to English. A crash that early is exactly the one a
		// Chinese-speaking player is most likely to hit (missing DLL, wrong
		// bitness), so use fixed bilingual text until the tables exist.
		if (Language.generation == 0)
		{
			dialogTitle = "SeiunEngine 崩溃 / Crashed";
			dialogMsg = "游戏发生致命错误，需要退出。\nThe game has hit a fatal error and must exit.\n\n"
				+ "错误 / Error: " + message + "\n\n"
				+ "崩溃报告已保存到 / Report saved to:\n" + path + "\n\n"
				+ "请把这份报告发给开发者 / Please send this report to the developers:\n" + githubUrl;
			if (advice.length > 0) dialogMsg += "\n\n" + advice;
		}

		// Recovery screen: only possible when the engine really exists. A startup
		// failure has no FlxG yet, and pretending otherwise used to throw inside the
		// handler (the "crash while reporting a crash" loop).
		var switched:Bool = false;
		try
		{
			if (FlxG.game != null && FlxG.state != null && !Std.isOfType(FlxG.state, CrashCatcherState))
			{
				backend.Dialog.show(dialogTitle, dialogMsg, 'Error');
				FlxG.switchState(new CrashCatcherState());
				switched = true;
			}
		}
		catch (x:Dynamic) {}

		if (switched) return;

		// No engine to recover into: a native UTF-16 box (Chinese works, unlike the
		// old MessageBoxA path) is the last surface left, and then the process ends.
		try
		{
			// dialogTitle is localised when the language tables exist and bilingual
			// when they do not, which is exactly what this last surface needs.
			NativeCrash.showDialog(dialogTitle, dialogMsg);
		}
		catch (x:Dynamic) {}
		#if cpp
		try { Discord.DiscordClient.shutdown(); } catch (x:Dynamic) {}
		#end
		#if sys
		Sys.exit(1);
		#end
	}

	/** crash/SeiunEngine_<date>.txt - the naming the engine has always used. */
	static function crashReportPath():String
	{
		var dateNow:String = Date.now().toString();
		dateNow = dateNow.replace(" ", "_");
		dateNow = dateNow.replace(":", "'");
		return "./crash/" + "SeiunEngine_" + dateNow + ".txt";
	}

	/** Haxe stack for the report; falls back to the live call stack on cpp. */
	static function collectCrashStack():String
	{
		var stackLines:String = "";
		try
		{
			for (stackItem in haxe.CallStack.exceptionStack(true))
			{
				switch (stackItem)
				{
					case haxe.CallStack.StackItem.FilePos(s, file, line, column):
						stackLines += file + " (line " + line + ")\n";
					default:
						#if sys
						Sys.println(stackItem);
						#end
						// keep non-FilePos entries too, otherwise the report stack may end up empty
						stackLines += Std.string(stackItem) + "\n";
				}
			}
		}
		catch (x:Dynamic) {}

		// Fall back to the current call stack when exceptionStack is unavailable on cpp.
		if (stackLines == null || stackLines.length == 0)
		{
			try { stackLines = haxe.CallStack.toString(haxe.CallStack.callStack()); } catch (x:Dynamic) {}
		}
		return stackLines == null ? '' : stackLines;
	}

	/**
	 * Writes the dump with a UTF-8 BOM: every reader (Notepad included) then
	 * decodes the Chinese text correctly instead of guessing the ANSI code page.
	 * Never throws - a failed write must not stop the dialog from appearing.
	 */
	static function writeCrashReport(path:String, content:String):Bool
	{
		#if sys
		try
		{
			if (!FileSystem.exists("./crash/"))
				FileSystem.createDirectory("./crash/");
			sys.io.File.saveContent(path, '\uFEFF' + content + "\n");
			Sys.println(content);
			Sys.println("Crash dump saved in " + haxe.io.Path.normalize(path));
			return true;
		}
		catch (x:Dynamic)
		{
			try { Sys.println("Could not write the crash dump to " + path + ": " + Std.string(x)); } catch (y:Dynamic) {}
		}
		#end
		return false;
	}

	#if (desktop && MODS_ALLOWED)
	/** Set window icon from the active mod's pack.json using ModConfig. */
	static function setModWindowIcon():Void
	{
		try
		{
			var activeModPath:String = 'activeMod.txt';
			if (!sys.FileSystem.exists(activeModPath)) return;
			var modFolder:String = sys.io.File.getContent(activeModPath).trim();
			if (modFolder.length == 0) return;

			backend.ModConfig.setWindowIcon(modFolder);
		}
		catch (e:Dynamic)
		{
			// Silently fail – icon is cosmetic, not critical
		}
	}
	#end
}
