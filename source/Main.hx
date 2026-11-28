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

		#if sys
		// Lab probe: slow step/draw-record logging (SEIUN_LAB_FRAME_LOG=1).
		try { if (Sys.getEnv('SEIUN_LAB_FRAME_LOG') == '1') backend.LabFrameLog.install(); } catch (e:Dynamic) {}
		#end

		// ── Renderer choice (0.2.2 has no in-game row; save / flags still work) ──
		// A launch that asked for Vulkan and died before the backend proved itself left
		// logs/vulkan-attempt.txt behind. recover() reads that as "that machine cannot
		// run Vulkan" and puts this launch back on OpenGL - and rewrites the saved
		// preference, which is the half of the fallback that survives a hard crash.
		// It runs here because the boot state's create() (inside the FlxGame above) has
		// already loaded ClientPrefs, so the saved choice is readable.
		backend.RendererChoice.recover();

		// One line in logs/renderer.txt: which backend this launch picked and why. Without it
		// a session that stays on OpenGL leaves no trace at all.
		backend.RendererChoice.writeDecisionRecord();

		#if seiun_vulkan
		// A leftover attempt marker means the last launch died before the backend proved
		// itself. Say so once: the saved choice has already been put back to OpenGL, and a
		// silent revert looks like the setting "forgot" what was picked.
		if (backend.RendererChoice.recoveredFromCrash) showVulkanFallback(backend.RendererChoice.failureReason, true);

		// 实验性 Vulkan 后端：等第一帧再探测。setupGame 跑的时候窗口可能还没 show，
		// lvk_self_window 找不到可见窗口就会判定失败 —— 那是误报。
		// 要不要真的切，由 saved preference / --vulkan / SEIUN_VULKAN 共同决定
		// （backend.RendererChoice），失败时自动回到 OpenGL。
		if (backend.RendererChoice.shouldStart())
		{
			if (FlxG.stage != null)
			{
				installVulkanAfterFirstFrame();
			}
			else
			{
				backend.RendererChoice.fellBack('no stage to attach to', false);
			}
		}
		#else
		// 这一份构建里没有 Vulkan 代码。玩家如果带了 --vulkan，必须**说出来**：
		// 安静地忽略会让人以为"开了 Vulkan 但画面没变"，反而更难查。
		// 这个提示放在引擎里：没有 seiun_vulkan 的时候，渲染器的类根本不在源码路径上。
		backend.VulkanNotice.report(function(text) backend.Dialog.show('Vulkan', text, 'Warning'));
		#end


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

	#if seiun_vulkan
	/**
	 * 实验性 Vulkan 后端接线。要不要真的切由 backend.RendererChoice 决定：存档里的
	 * 渲染器选择、--vulkan / --no-vulkan、SEIUN_VULKAN。0.2.2 不在游戏内提供切换
	 * 接口，但这几条入口照旧。切不过去就留在 OpenGL，并且把存档里的选择改回
	 * OpenGL，下次不再踩同一个坑。
	 *
	 * 这里只做四件游戏侧才知道的事：
	 *   1. 回退提示怎么显示（VkRuntime 不认识游戏的 Dialog / 语言表）；
	 *   2. 每帧末尾提交上屏的时机（必须晚于 flixel 的 draw 和 OpenFL 的 stage render）；
	 *   3. 窗口尺寸变化和状态切换时通知运行时；
	 *   4. 把"这次真的跑起来了"记进标记文件（崩溃回退的另一半，见 RendererChoice）。
	 */
	static function installVulkanAfterFirstFrame():Void
	{
		var onFirstFrame:openfl.events.Event->Void = null;

		onFirstFrame = function(_)
		{
			FlxG.stage.removeEventListener(openfl.events.Event.ENTER_FRAME, onFirstFrame);
			installVulkan();
		};

		FlxG.stage.addEventListener(openfl.events.Event.ENTER_FRAME, onFirstFrame);
	}

	static function installVulkan():Void
	{
		// The preference can change between the frame that scheduled this call and the
		// call itself (a recovery, a mod, a command line override): re-check, do not trust.
		if (!backend.RendererChoice.shouldStart()) return;

		var runtime = seiun.vulkan.VkRuntime;

		// The runtime decides "was Vulkan asked for?" from the command line and the
		// environment; a saved choice is neither, so it is handed over here. Without this
		// a saved choice silently did nothing (and then looked like a failed start, which
		// reset it).
		runtime.preferred = function() return backend.RendererChoice.wanted();

		#if android
		// Android cannot have both: the EGL surface SDL created for OpenGL keeps a buffer
		// producer on the ANativeWindow, and the driver answers
		// VK_ERROR_NATIVE_WINDOW_IN_USE_KHR when Vulkan asks for that window (measured on a
		// Mali-G610). The window is therefore handed over first; if the backend then fails,
		// the session cannot draw through OpenGL any more and showVulkanFallback() ends the
		// process so the next launch starts on OpenGL.
		runtime.releaseOpenGL();
		#end

		// Before the first native call: from here on this process can die without running
		// another line of Haxe, and this marker is the only witness of the attempt.
		backend.RendererChoice.beginAttempt();

		// A start that fails reports through onFallback *and* returns false here. One record
		// and one dialog are enough; this keeps the second path from repeating the first.
		var runtimeReported:Bool = false;

		runtime.onFallback = function(reason:String)
		{
			runtimeReported = true;

			// The runtime hands over a message it already decorated with its own "stays on
			// OpenGL" preamble; the raw reason is what belongs under *this* engine's heading,
			// otherwise the dialog says the same thing twice in two languages.
			var detail:String = runtime.lastFailure;
			if (detail == null || detail.length == 0) detail = reason;

			// An attempt that never committed has not proven anything, so the saved
			// preference is corrected and the next launch goes straight to OpenGL. Once it
			// has committed, a failure is treated as a one-off (a suspend/resume, a driver
			// reset) and the player's choice is kept for the next launch.
			var beforeCommit:Bool = backend.RendererChoice.attemptPending;

			backend.RendererChoice.fellBack(detail, beforeCommit);

			showVulkanFallback(detail, beforeCommit);
		};

		if (!runtime.start(false))
		{
			// The runtime already cleaned up and asked for its dialog: nothing left to do.
			if (runtimeReported) return;

			var reason:String = runtime.lastFailure == null
				? 'Vulkan could not start on this device'
				: runtime.lastFailure;

			// A start that never reached a frame cannot be a one-off: this machine or this
			// driver has no usable Vulkan, so stop asking for it in the save file as well.
			backend.RendererChoice.fellBack(reason, true);

			showVulkanFallback(reason, true);

			return;
		}

		// Let the settings menu (and anything else) see that this session really is on
		// Vulkan instead of only assuming OpenGL.
		backend.RendererChoice.markActive();

		// Take the stage over before this frame is drawn. It used to happen in endFrame(),
		// which left exactly one frame rendering through the old OpenGLRenderer - and on
		// Android that frame is fatal: the EGL surface is already gone, so openfl compiles
		// its quad shader against no context and throws.
		seiun.vulkan.VkOverlay.install();

		// Vulkan keeps its own texture table, so the CPU release decision can no
		// longer look for a Context3D texture: this context is about to be deleted,
		// and getTexture() on it would create textures nothing renders with.
		backend.gfx.GfxMemory.externalActive = function() return runtime.enabled;
		backend.gfx.GfxMemory.externalHolds = seiun.vulkan.VkTextures.holdsGraphic;
		backend.gfx.GfxMemory.externalUpload = seiun.vulkan.VkTextures.uploadGraphic;

		// flixel 的鼠标指针是塞在舞台里的一个 Bitmap（cursorContainer），走的是
		// OpenFL 的渲染器，Vulkan 这条路不会画它 —— 表现就是"游戏里没有鼠标"。
		// 让它改用系统光标，指针就回来了。
		try
		{
			FlxG.mouse.useSystemCursor = true;
		}
		catch (e:Dynamic) {}

		// 每帧收尾：flixel 的 draw() 在 update 阶段就跑完了，这里挂在 render 阶段，
		// 一定晚于所有 drawQuads，也晚于 OpenFL 自己的 stage render。
		// window.onRender 的监听顺序就是执行顺序：lime 自己在窗口创建时挂的 render() 在前，
		// 所以这一句一定在 OpenFL 画完整个舞台之后才跑，也就是"这一帧的 draw 全部结束了"。
		var window = lime.app.Application.current.window;

		var stats:Bool = false;

		for (arg in Sys.args ())
		{
			if (arg == "--vulkan-stats") stats = true;
		}

		if (window != null)
		{
			var frames:Int = 0;
			var lastStat:Float = haxe.Timer.stamp ();

			window.onRender.add(function(_)
			{
				// The backend stopped (a lost Android surface, a device reset, a driver
				// fault). Leaving the frame alone puts lime's own OpenGL flip back in charge,
				// so the session keeps drawing: on Android the EGL surface was never
				// released, and VkStageRenderer hands the stage back the same way.
				if (!runtime.enabled) return;

				seiun.vulkan.VkTextures.tick ();
				runtime.endFrame ();

				// The first few hundred frames are the attempt's probation: once they are
				// on screen the marker is retired and the next launch may try Vulkan again.
				backend.RendererChoice.tick ();

				frames++;

				// lime flips the OpenGL buffers right after this dispatch. That paints the
				// (empty) GL frame over ours, so the window alternates between the two
				// renderers every frame. Cancelling the event skips the flip.
				window.onRender.cancel ();

				// Frame stats are printed only with --vulkan-stats.
				if (stats && (frames == 60 || frames % 60 == 0))
				{
					var now = haxe.Timer.stamp ();
					var ms = (now - lastStat) * 1000.0 / 60.0;
					lastStat = now;

					Sys.println ('[vulkan] frame ' + frames + ' avg=' + Std.int (ms * 100) / 100 + 'ms ('
						+ Std.int (1000.0 / (ms <= 0 ? 1 : ms)) + ' fps): ' + seiun.vulkan.VkQuads.debugLine ()
						+ ' | ' + seiun.vulkan.VkTextures.stats ());
				}
			});
		}

		FlxG.stage.addEventListener(openfl.events.Event.RESIZE, function(_)
		{
			runtime.resize(FlxG.stage.stageWidth, FlxG.stage.stageHeight);
		});

		// 状态切换时全清纹理缓存：换关卡的纹理本来就用不上了，
		// 留着只会让显存曲线随进出关卡一路往上涨。
		// 状态切换时**不要**清纹理缓存：引擎的 GfxMemory 已经释放了大部分图片的
		// CPU 像素，清掉之后传不回来，下一关满屏精灵就是空的。缓存的寿命跟着
		// FlxGraphic 走（destroy 时 bitmap 置空，sweep 会回收）。
		FlxG.signals.preStateCreate.add(function(_) seiun.vulkan.VkQuads.restartTrace ());
	}

	/**
	 * The dialog a player sees when Vulkan did not work out.
	 *
	 * Three different stories, and telling them apart matters: a backend that never started
	 * leaves this session on OpenGL and the save file already says so; one that stopped after
	 * the swapchain existed cannot hand the window back on Windows; and on Android the window
	 * had to be taken away from OpenGL before the attempt, so there is nothing left to fall
	 * back into and the process has to restart.
	 */
	static function showVulkanFallback(reason:String, beforeCommit:Bool):Void
	{
		var head:String;

		#if android
		// The EGL surface is gone, so OpenGL cannot draw this session again: the only honest
		// continuation is a fresh launch, which starts on OpenGL because the saved choice has
		// already been reset by RendererChoice.fellBack().
		if (seiun.vulkan.VkRuntime.glReleased)
		{
			var restartHead:String = beforeCommit
				? Language.get('renderer.fallback.needsRestart',
					'Vulkan could not take over this game. Offering it the window meant releasing OpenGL first, so the game has to be restarted - the saved renderer is already back on OpenGL and the next launch is a plain OpenGL session.')
				: Language.get('renderer.fallback.needsRestartStopped',
					'Vulkan stopped while the game was running. OpenGL was released when the window was handed over, so the game has to be restarted - the next launch is a plain OpenGL session unless Vulkan is requested again.');

			try
			{
				backend.Dialog.showCustom('Vulkan', restartHead + '\n\n' + reason,
					[{name: Language.get('Dialog.ok', 'OK'), callback: function() Sys.exit(0)}], false);
			}
			catch (e:Dynamic) {}

			return;
		}
		#end

		if (beforeCommit)
		{
			head = Language.get('renderer.fallback.notStarted',
				'Vulkan could not take over this game, so it keeps running on OpenGL. The saved renderer is back on OpenGL.');
		}
		else
		{
			#if windows
			// The swapchain already handed the window to the compositor: GL cannot draw
			// into it any more, so the honest advice is a restart.
			head = Language.get('renderer.fallback.stopped',
				'Vulkan stopped while the game was running. OpenGL cannot take this window back, so the picture stays frozen - restart the game to keep playing on OpenGL.');
			#else
			// Android keeps the EGL surface alive, so OpenGL really does take the picture
			// back and the player can keep going.
			head = Language.get('renderer.fallback.stoppedAndroid',
				'Vulkan stopped while the game was running. OpenGL is drawing again, so you can keep playing; restart the game to try Vulkan once more.');
			#end
		}

		try
		{
			backend.Dialog.show('Vulkan', head + '\n\n' + reason, 'Warning');
		}
		catch (e:Dynamic) {}
	}
	#end

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
	 *      module probe, loaded modules) and the origin,
	 *   4. write crash/SeiunEngine_<date>.txt (UTF-8 + BOM, same prefix as always),
	 *   5. hand over to the recovery screen when the engine still exists, otherwise
	 *      show a native UTF-16 dialog with the report path and exit.
	 *
	 * The dump is facts only: engine state, native diagnostics, origin. It carries
	 * no what/why/fix paragraph on purpose - no fixed table covers every failure,
	 * and a wrong guess is worse than none.
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
				stackLines += formatStackItem(stackItem) + "\n";
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
	 * One report line per stack frame, function name first.
	 *
	 * hxcpp wraps every frame as FilePos(Method(class, method), file, line), and the old reporter
	 * printed only "file (line N)" - the one part that identifies a null pointer (the C++ function
	 * name) was thrown away. The line number is printed only when the build records it
	 * (HXCPP_STACK_LINE); release builds skip that store and leave the field meaningless.
	 */
	static function formatStackItem(item:haxe.CallStack.StackItem, depth:Int = 0):String
	{
		if (item == null || depth > 8) return '';
		switch (item)
		{
			case haxe.CallStack.StackItem.Method(classname, method):
				return (classname == null || classname.length == 0 ? '' : classname + '.') + method + '()';
			case haxe.CallStack.StackItem.FilePos(inner, file, line, column):
				var head:String = formatStackItem(inner, depth + 1);
				var where:String = '(' + file;
				#if HXCPP_STACK_LINE
				if (line > 0) where += ':' + line;
				#end
				where += ')';
				return (head.length == 0 ? '' : head + '  ') + where;
			default:
				return Std.string(item);
		}
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
