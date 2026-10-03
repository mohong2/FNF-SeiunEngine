package script.hscript;

import backend.MusicBeatState;
import backend.ModConfig;
import backend.CompatEngine;
import haxe.io.Path;
import flixel.addons.display.FlxRuntimeShader;
import hscript.*;
import hscript.Expr.Error;
import hscript.Parser;
import hscript.iris.Iris;
import flixel.FlxG;
import flixel.util.FlxColor;
import Paths;
import Conductor;
import ClientPrefs;
import Character;
import Alphabet;
import Note;
import Achievements;
import Controls;
import states.*;
import substates.*;
import flixel.FlxSprite;
import flixel.text.FlxText;
import flixel.sound.FlxSound;
import flixel.util.FlxTimer;
import flixel.tweens.FlxTween;
import flixel.tweens.FlxEase;
import flixel.effects.FlxFlicker;
import flixel.group.FlxGroup;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.group.FlxSpriteGroup;
import flixel.util.FlxSpriteUtil;
import flixel.util.FlxStringUtil;
import flixel.graphics.frames.FlxAtlasFrames;
import openfl.filters.ShaderFilter;
import openfl.filters.ColorMatrixFilter;
import mohong.TraceManager;
import script.FunkinText;
import script.FunkinSprite;
import script.FunkinButton;
import script.FunkinBar;
import script.ScriptErrorGuard;

#if LUA_ALLOWED
import script.lua.FunkinLua;
import psychlua.LuaUtils;
import llua.Lua;
import llua.LuaL;
#end

#if VIDEOS_ALLOWED
// hxvlc-backed hxCodec compatibility layer (see source/objects/hxcodec)
import vlc.MP4Handler;
import vlc.MP4Sprite;
import hxcodec.VideoHandler;
import hxcodec.VideoSprite;
import hxcodec.flixel.FlxVideo;
import hxcodec.flixel.FlxVideoSprite;
#end

#if HSCRIPT_ALLOWED

class HScript
{
	public static var globalScripts:Array<HScript> = [];
	public static var hscriptVersion:String = "0.2.1h";

	public var interp:Interp;
	public var parser:Parser;
	public var scriptName:String = '';
	public var scriptDir:String = '';
	public var closed:Bool = false;
	#if LUA_ALLOWED
	/** 所属的 Lua 脚本实例（0.7.3+/1.0.4 HScript 的 parentLua 全局）。 */
	/** English: owning Lua script instance (the parentLua global of 0.7.3+/1.0.4 HScript). */
	public var parentLua:script.lua.FunkinLua = null;
	#end

	/** 连续报错计数：脚本在 update 循环里连续报错达到上限时会被静默忽略。 */
	public var errorLoopCount:Int = 0;

	/** 函数覆盖备份表：原名 → 原函数，供 restoreFunction() 恢复。
	 * English: Function-override backups: name → original function, used by restoreFunction(). */
	var functionBackups:Map<String, Dynamic> = new Map<String, Dynamic>();

	/**
	 * Advanced whenever ANY HScript interpreter ran code or had one of its variables written.
	 * FunkinLua consumes it to invalidate its negative callback caches: HScript code is the only
	 * route into LuaApi, which writes Lua globals behind FunkinLua's back (LuaApi and the Lua
	 * require/import loaders are deliberately untouched).
	 */
	public static var codeEpoch:Int = 0;
	/** Number of HScript bodies (call()/execute()) currently on the stack. */
	public static var execDepth:Int = 0;

	/**
	 * Negative callback cache for call(). name -> stamp at which interpGet() found nothing.
	 * Only the empty result is cached: a variable that exists but is not a function must keep
	 * taking the normal path, exactly as before.
	 * Invalidation: any code that ran (varEpoch), any write to this interp's tables (set()
	 * removes the exact name, the override/rename/restore/reload helpers bump varEpoch), and
	 * probeStamp() returns -1 while HScript code is on the stack, so a re-entrant dispatch from
	 * inside a script body can never read an entry that body may have invalidated.
	 */
	var nilVars:Map<String, Int> = null;
	var varEpoch:Int = 0;
	var foldedVars:Int = -1;
	var nilStamp:Int = 0;

	/** Any write to this interp's variable tables, or any HScript code that ran. */
	inline function bumpVarEpoch():Void
	{
		varEpoch++;
		codeEpoch++;
	}

	/** Stamp to compare against nilVars entries, or -1 when nothing may be cached/read. */
	inline function probeStamp():Int
	{
		if (execDepth > 0) return -1;
		if (foldedVars != varEpoch)
		{
			foldedVars = varEpoch;
			nilStamp++;
		}
		// Long-session guard: the stamp only has to differ from every stored value.
		if (nilStamp >= 0x20000000)
		{
			nilStamp = 0;
			if (nilVars != null) nilVars.clear();
		}
		return nilStamp;
	}

	public var variables(get, never):Map<String, Dynamic>;
	public var __importedPaths:Array<String> = [];

	inline function get_variables():Map<String, Dynamic>
		return interp.variables;

	// ==================== Static Methods ====================

	public static function initialize():Void {
		// NOTE: fully qualified — the `hscript.*` wildcard import
		// would otherwise shadow our own script.hscript.Config
		script.hscript.Config.applyBlocklist();
		loadGlobalScripts();
		TraceManager.info('trace.hscript.initialized', 'HScript initialized with {} global scripts', [globalScripts.length]);

		// ── 模组切换时切换 FPS 样式（默认使用新版 FPS） ──
		// 只有模组通过 pack.json 明确要求旧版样式时才会切换.
		// 全局脚本重载由 ModState.applyModPackConfig() 在配置应用后触发
		Paths.onModDirectoryChanged.push(function(oldMod:String, newMod:String) {
			var useOld:Bool = false;
			if (newMod != null && newMod.length > 0)
			{
				var cfg = ModConfig.load(newMod);
				useOld = cfg.useOldFPS;
			}
			Main.useOldFPS = useOld;
			if (Main.fpsVar != null) {
				Main.fpsVar.visible = ClientPrefs.data.showFPS && !useOld;
				Main.oldFpsVar.visible = ClientPrefs.data.showFPS && useOld;
			}
			setOnGlobalScript('useOldFPS', useOld);
		});
	}

	static function loadGlobalScripts():Void {
		var filesPushed:Array<String> = [];
		var foldersToCheck:Array<String> = [Paths.getPreloadPath('hscripts/')];

		#if MODS_ALLOWED
		foldersToCheck.insert(0, Paths.mods('hscripts/'));
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			foldersToCheck.insert(0, Paths.mods(Paths.currentModDirectory + '/hscripts/'));
		for (mod in Paths.getGlobalMods())
			foldersToCheck.insert(0, Paths.mods(mod + '/hscripts/'));
		#end

		for (folder in foldersToCheck) {
			if (!FileSystem.exists(folder)) continue;
			for (file in FileSystem.readDirectory(folder)) {
				// Same filenames in different mods are distinct scripts. The path,
				// not the basename, defines identity; priority is folder order.
				var scriptPath:String = folder + file;
				if (!isHscriptFile(file) || filesPushed.contains(scriptPath)) continue;
				try {
					var script = new HScript(scriptPath);
					globalScripts.push(script);
					filesPushed.push(scriptPath);
				} catch (e:Dynamic) {
					TraceManager.error('trace.hscript.globalFailed', 'Failed to load global hscript: {} - {}', [file, e]);
				}
			}
		}
	}

	/** 重载所有全局脚本（模组切换时调用） **/
	public static function reloadGlobalScripts():Void {
		for (s in globalScripts) s.stop();
		globalScripts = [];
		loadGlobalScripts();
	}

	/**
	 * 在 Main 启动时加载模组根目录下的引导脚本（boot.hx / Main.hx）。
	 * 这些脚本在 TitleState 之前执行，用于模组早期初始化。
	 */
	public static function loadModBootScript():Void
	{
		#if MODS_ALLOWED
		var bootNames:Array<String> = ['Main.hx', 'boot.hx', 'boot.hscript', 'boot.hxs'];
		var searched:Array<String> = [];

		// 当前激活的 mod 目录
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
		{
			var modRoot:String = Paths.mods(Paths.currentModDirectory + '/');
			searched.push(modRoot);
			for (bootName in bootNames)
			{
				var bootPath:String = modRoot + bootName;
				if (FileSystem.exists(bootPath))
				{
					try {
						var script = new HScript(bootPath);
						globalScripts.push(script);
						TraceManager.info('trace.hscript.bootLoaded', 'Loaded boot script: {}', [bootPath]);
					} catch (e:Dynamic) {
						TraceManager.error('trace.hscript.bootFailed', 'Failed to load boot script: {} - {}', [bootPath, e]);
					}
					break;
				}
			}
		}

		// Do NOT load Main.hx/boot from every global mod: that leaked other mods'
		// boot scripts even on vanilla/other mods. Boot script belongs to the
		// currently selected mod only; global mods inject via hscripts/ instead.

		// 内置 preload 路径
		var preloadRoot:String = Paths.getPreloadPath('');
		if (!searched.contains(preloadRoot))
		{
			for (bootName in bootNames)
			{
				var bootPath:String = preloadRoot + bootName;
				if (FileSystem.exists(bootPath))
				{
					try {
						var script = new HScript(bootPath);
						globalScripts.push(script);
						TraceManager.info('trace.hscript.bootLoaded', 'Loaded boot script: {}', [bootPath]);
					} catch (e:Dynamic) {
						TraceManager.error('trace.hscript.bootFailed', 'Failed to load boot script: {} - {}', [bootPath, e]);
					}
					break;
				}
			}
		}
		#end
	}

	public static function callOnGlobalScript(event:String, args:Array<Dynamic> = null):Dynamic {
		if (args == null) args = [];
		var returnVal:Dynamic = FunkinLua.Function_Continue;

		for (script in globalScripts) {
			if (script.closed) continue;
			var ret = script.call(event, args);
			if (ret == FunkinLua.Function_StopHScript) return ret;
			if (ret != FunkinLua.Function_Continue) returnVal = ret;
		}
		return returnVal;
	}

	public static function setOnGlobalScript(variable:String, arg:Dynamic):Void {
		for (script in globalScripts) {
			if (!script.closed) script.set(variable, arg);
		}
	}

	public static function cleanup():Void {
		for (script in globalScripts) script.stop();
		globalScripts = [];
	}

	public static function isHscriptFile(file:String):Bool {
		return file.endsWith('.hx') || file.endsWith('.hscript')
			|| file.endsWith('.hsc') || file.endsWith('.hxs');
	}

	/**
	 * 从多个文件夹收集所有 HScript 文件并加载，返回新实例数组。
	 * filesPushed 用于跨批次去重。
	 */
	public static function collectFromFolders(folders:Array<String>, filesPushed:Array<String>):Array<HScript>
	{
		var result:Array<HScript> = [];
		for (folder in folders)
		{
			if (!FileSystem.exists(folder)) continue;
			for (file in FileSystem.readDirectory(folder))
			{
				if (!isHscriptFile(file) || filesPushed.contains(file)) continue;
				try {
					result.push(new HScript(folder + file));
					filesPushed.push(file);
				} catch (e:Dynamic) {
					TraceManager.error('trace.hscript.collectFailed', 'Failed: {} - {}', [file, e]);
				}
			}
		}
		return result;
	}

	/**
	 * 加载指定路径列表中的单个 HScript 文件，返回新实例数组。
	 */
	public static function collectStandalone(paths:Array<String>, filesPushed:Array<String>):Array<HScript>
	{
		var result:Array<HScript> = [];
		for (path in paths)
		{
			if (!FileSystem.exists(path) || filesPushed.contains(path)) continue;
			try {
				result.push(new HScript(path));
				filesPushed.push(path);
			} catch (e:Dynamic) {
				TraceManager.error('trace.hscript.collectFailed', 'Failed: {} - {}', [path, e]);
			}
		}
		return result;
	}

	// ==================== Instance ====================

	public function new(?scriptPath:String = null) {
		interp = new PlayStateInterp();
		// ── 静态/公开变量 + 错误与导入回调 (hscript-seiun) ──
		interp.allowStaticVariables = true;
		interp.allowPublicVariables = true;
		interp.errorHandler = function(e) {
			TraceManager.error('trace.hscript.interpError', 'HScript error in {}: {}', [scriptName, e]);
		};
		interp.importFailedCallback = importFailedCallback;
		parser = new Parser();
		parser.allowTypes = true;
		parser.allowJSON = true;
		parser.allowMetadata = true;
		applyDefaultPreprocessors(parser);

		if (scriptPath != null) {
			scriptDir = Path.directory(scriptPath);
			scriptName = Path.withoutDirectory(scriptPath);
			__importedPaths.push(scriptPath);
		} else {
			scriptName = '<inline>';
		}

		try {
			setupVariables();
		} catch (e:Dynamic) {
			handleError('Failed to setup variables: $e');
			return;
		}

		if (scriptPath != null) {
			try {
				loadScriptFromPath(scriptPath);
			} catch (e:Dynamic) {
				handleError('Failed to load script "$scriptPath": $e');
				closed = true;
				return;
			}
		}

		if (!closed) {
			try {
				call('onCreate', []);
			} catch (e:Dynamic) {
				handleError('Failed to call onCreate: $e');
				closed = true;
			}
		}

		bumpVarEpoch(); // loading the script + onCreate may have defined any global
	}

	/**
	 * Get the default variable bindings for hscript.
	 * Uses a Map so subclasses / external code can extend it.
	 */
	public static function getDefaultVariables():Map<String, Dynamic> {
		var vars:Map<String, Dynamic> = [
			// Haxe std
			"Math" => Math, "Std" => Std, "StringTools" => StringTools,
			"Sys" => Sys, "Type" => Type, "Reflect" => Reflect,
			"Date" => Date, "DateTools" => DateTools, "Lambda" => Lambda,
			// haxe.Json's parse/stringify are inline statics, so they do NOT exist
			// at runtime and can't be called from scripts via reflection (they would
			// silently fail with "Null Function Pointer"). Bind a reflectable wrapper
			// so `Json.parse(...)` / `Json.stringify(...)` work inside hscripts.
			"Json" => {
				parse: function(text:String):Dynamic return haxe.format.JsonParser.parse(text),
				stringify: function(value:Dynamic, ?replacer:Dynamic = null, ?space:String = null):String
					return haxe.format.JsonPrinter.print(value, replacer, space)
			},
			"String" => String, "Array" => Array,

			// Flixel
			"FlxG" => flixel.FlxG, "FlxMath" => flixel.math.FlxMath,
			"FlxSprite" => flixel.FlxSprite, "FlxCamera" => flixel.FlxCamera,
			"FlxTimer" => FlxTimer, "FlxTween" => FlxTween, "FlxEase" => FlxEase,
			"FlxText" => FlxText, "FlxSound" => FlxSound,
			"FlxGroup" => FlxGroup, "FlxTypedGroup" => FlxTypedGroup,
			"FlxSpriteGroup" => FlxSpriteGroup, "FlxStringUtil" => FlxStringUtil,
			"FlxSpriteUtil" => FlxSpriteUtil, "FlxAtlasFrames" => FlxAtlasFrames,
			"FlxColor" => CustomFlxColor,

			// Engine
			"Paths" => Paths, "Conductor" => Conductor, "ClientPrefs" => ClientPrefs,
			"Dialog" => backend.Dialog,
			"SeiunOverlay" => backend.SeiunOverlay,
			"Character" => Character, "Alphabet" => Alphabet,
			"Note" => Note,
			"Achievements" => Achievements,
			"PsychCamera" => backend.PsychCamera,
			"Countdown" => backend.Countdown,
			"CustomSubstate" => script.lua.CustomSubstate,
			#if flxanimate
			"FlxAnimate" => flxanimate.FlxAnimate,
			#end
			"FunkinText" => FunkinText,
			"FunkinSprite" => FunkinSprite,
			"FunkinButton" => FunkinButton,
			"FunkinBar" => FunkinBar,

			// States
			"MusicBeatState" => MusicBeatState, "MusicBeatSubstate" => MusicBeatSubstate,
			"ModState" => ModState, "ModSubState" => ModSubState,
			"PlayState" => PlayState, "FreeplayState" => FreeplayState,
			"StoryMenuState" => StoryMenuState, "TitleState" => TitleState,
			"CreditsState" => CreditsState, "MainMenuState" => MainMenuState,
			"HScript" => HScript,

			// Shaders
			"ShaderFilter" => ShaderFilter, "ColorMatrixFilter" => ColorMatrixFilter,
			#if (!flash && sys) "FlxRuntimeShader" => FlxRuntimeShader, #end
			#if VIDEOS_ALLOWED
			"VideoSpriteManager" => backend.VideoSpriteManager,
			#end

			// Video playback classes (for LUA addHaxeLibrary / runHaxeCode compatibility)
			"Event" => openfl.events.Event,

			// Script controls
			"Function_Stop" => FunkinLua.Function_Stop,
			"Function_Continue" => FunkinLua.Function_Continue,
			"Function_StopLua" => FunkinLua.Function_StopLua,
			"Function_StopHScript" => FunkinLua.Function_StopHScript,
			"Function_StopAll" => FunkinLua.Function_StopAll,

			// Shorthand
			"add" => function(obj:Dynamic) FlxG.state.add(obj),
			"insert" => function(pos:Int, obj:Dynamic) FlxG.state.insert(pos, obj),
			"remove" => function(obj:Dynamic, splice:Bool = false) FlxG.state.remove(obj, splice),

			// Version info
			"hscriptVersion" => hscriptVersion,
			"version" => CompatEngine.current(),
			"screenWidth" => FlxG.width, "screenHeight" => FlxG.height,
		];

		#if windows
		vars.set("buildTarget", "windows");
		#elseif linux
		vars.set("buildTarget", "linux");
		#elseif mac
		vars.set("buildTarget", "mac");
		#elseif html5
		vars.set("buildTarget", "browser");
		#elseif android
		vars.set("buildTarget", "android");
		#else
		vars.set("buildTarget", "unknown");
		#end

		// Additional commonly‑needed engine-compat type bindings
		vars.set("FlxObject", flixel.FlxObject);
		vars.set("FlxBasic", flixel.FlxBasic);
		vars.set("FlxAxes", flixel.util.FlxAxes);
		vars.set("FlxPoint", flixel.math.FlxPoint);
		vars.set("FlxButton", flixel.ui.FlxButton);
		vars.set("FlxBar", flixel.ui.FlxBar);
		vars.set("FlxRect", flixel.math.FlxRect);
		vars.set("FlxRandom", flixel.math.FlxRandom);
		vars.set("FlxTextBorderStyle", flixel.text.FlxText.FlxTextBorderStyle);
		vars.set("Application", lime.app.Application);
		vars.set("Assets", openfl.utils.Assets);
		vars.set("CoolUtil", CoolUtil);
		vars.set("WeekData", WeekData);
		vars.set("Language", Language);
		vars.set("LoadingState", LoadingState);
		vars.set("Highscore", Highscore);
		vars.set("ClientPrefs", ClientPrefs);
		vars.set("ModConfig", ModConfig);

		// 1.0.4: getModSetting (HScript 侧) —— 读取模组 data/settings.json 里的设置值。
		// modName 省略时使用当前激活的模组目录。
		#if MODS_ALLOWED
		vars.set("getModSetting", function(saveTag:String, ?modName:String = null):Dynamic {
			if (modName == null || modName.length == 0) modName = Paths.currentModDirectory;
			if (modName == null || modName.length == 0) return null;
			return FunkinLua.getModSetting(saveTag, modName);
		});
		#end

		// 多k API (hscript)
		vars.set("getMania", function():Int return (PlayState.instance != null) ? PlayState.instance.getManiaK() : -1);
		vars.set("setMania", function(k:Int, ?skipTween:Bool = false, ?animStyle:String = null):Bool {
			if (PlayState.instance == null || k < 1) return false;
			PlayState.instance.changeMania(k - 1, skipTween, animStyle);
			return true;
		});
		vars.set("changeMania", function(k:Int, ?skipTween:Bool = false, ?animStyle:String = null):Bool {
			if (PlayState.instance == null || k < 1) return false;
			PlayState.instance.changeMania(k - 1, skipTween, animStyle);
			return true;
		});
		vars.set("setNoteTexture", function(noteIndex:Int, texture:String):Bool {
			return (PlayState.instance != null) ? PlayState.instance.setNoteTextureByIndex(noteIndex, texture) : false;
		});
		vars.set("setNoteCharAnim", function(noteIndex:Int, anim:String):Bool {
			return (PlayState.instance != null) ? PlayState.instance.setNoteCharAnimByIndex(noteIndex, anim) : false;
		});
		vars.set("setNoteColor", function(noteIndex:Int, hue:Float, sat:Float, brt:Float):Bool {
			return (PlayState.instance != null) ? PlayState.instance.setNoteColorByIndex(noteIndex, hue, sat, brt) : false;
		});

		// Convenience: change the OS window icon from any script
		#if (desktop && MODS_ALLOWED)
		vars.set("setModWindowIcon", function(?modFolder:String) ModConfig.setWindowIcon(modFolder));
		#end

		// FlxAxes constants for screenCenter()
		vars.set("X", flixel.util.FlxAxes.X);
		vars.set("Y", flixel.util.FlxAxes.Y);
		vars.set("XY", flixel.util.FlxAxes.XY);

		// FlxText alignment constants (commonly used in setFormat calls)
		vars.set("LEFT", flixel.text.FlxText.FlxTextAlign.LEFT);
		vars.set("CENTER", flixel.text.FlxText.FlxTextAlign.CENTER);
		vars.set("RIGHT", flixel.text.FlxText.FlxTextAlign.RIGHT);

		// FlxText border style constants
		vars.set("OUTLINE", flixel.text.FlxText.FlxTextBorderStyle.OUTLINE);
		vars.set("OUTLINE_FAST", flixel.text.FlxText.FlxTextBorderStyle.OUTLINE_FAST);
		vars.set("SHADOW", flixel.text.FlxText.FlxTextBorderStyle.SHADOW);
		vars.set("NONE", flixel.text.FlxText.FlxTextBorderStyle.NONE);

		// ── Haxe std library 完整基类 ──
		// 数据结构
		vars.set("IntMap", haxe.ds.IntMap);
		vars.set("StringMap", haxe.ds.StringMap);
		vars.set("ObjectMap", haxe.ds.ObjectMap);
		vars.set("EnumValueMap", haxe.ds.EnumValueMap);
		vars.set("HaxeList", haxe.ds.List);       // List 是保留字，用别名
		vars.set("GenericStack", haxe.ds.GenericStack);
		// haxe.ds.Option/Either are abstract types, can't use as values
		vars.set("SortedList", haxe.ds.List);   // 别名

		// I/O
		vars.set("Bytes", haxe.io.Bytes);
		vars.set("Input", haxe.io.Input);
		vars.set("Output", haxe.io.Output);
		vars.set("HaxePath", haxe.io.Path);
		vars.set("Eof", haxe.io.Eof);

		// 密码学
		vars.set("Base64", haxe.crypto.Base64);
		vars.set("Md5", haxe.crypto.Md5);
		vars.set("Sha1", haxe.crypto.Sha1);
		vars.set("Sha256", haxe.crypto.Sha256);
		vars.set("Adler32", haxe.crypto.Adler32);
		vars.set("CrC32", haxe.crypto.Crc32);

		#if sys
		// 文件系统
		vars.set("File", sys.io.File);
		vars.set("FileSystem", sys.FileSystem);
		vars.set("FileInput", sys.io.FileInput);
		vars.set("FileOutput", sys.io.FileOutput);
		vars.set("Process", sys.io.Process);
		#end

		// ── Lime / OpenFL ──
		vars.set("Matrix", openfl.geom.Matrix);
		vars.set("Point", openfl.geom.Point);
		vars.set("Rectangle", openfl.geom.Rectangle);
		vars.set("ColorTransform", openfl.geom.ColorTransform);
		vars.set("Transform", openfl.geom.Transform);
		vars.set("DisplayObject", openfl.display.DisplayObject);
		vars.set("DisplayObjectContainer", openfl.display.DisplayObjectContainer);
		vars.set("Sprite", openfl.display.Sprite);
		vars.set("Stage", openfl.display.Stage);
		vars.set("Bitmap", openfl.display.Bitmap);
		vars.set("BitmapData", openfl.display.BitmapData);
		vars.set("Graphics", openfl.display.Graphics);
		vars.set("MovieClip", openfl.display.MovieClip);
		vars.set("Shader", openfl.display.Shader);
		vars.set("ShaderParameter", openfl.display.ShaderParameter);
		vars.set("MouseEvent", openfl.events.MouseEvent);
		vars.set("KeyboardEvent", openfl.events.KeyboardEvent);
		vars.set("TouchEvent", openfl.events.TouchEvent);
		vars.set("FocusEvent", openfl.events.FocusEvent);
		vars.set("IOErrorEvent", openfl.events.IOErrorEvent);
		vars.set("SecurityErrorEvent", openfl.events.SecurityErrorEvent);
		vars.set("ProgressEvent", openfl.events.ProgressEvent);
		vars.set("HTTPStatusEvent", openfl.events.HTTPStatusEvent);
		vars.set("DataEvent", openfl.events.DataEvent);
		vars.set("SampleDataEvent", openfl.events.SampleDataEvent);
		vars.set("ShaderInput", openfl.display.ShaderInput);
		vars.set("FPS", openfl.display.FPS);
		vars.set("OldFPS", openfl.display.OldFPS);
		vars.set("fpsVar", Main.fpsVar);
		vars.set("oldFpsVar", Main.oldFpsVar);
		vars.set("useOldFPS", false);

		// 切换 FPS 样式：true = 旧版简约样式（OldFPS），false = 新版样式
		vars.set("setOldFPS", function(useOld:Bool) {
			Main.useOldFPS = useOld;
			if (Main.fpsVar != null) {
				Main.fpsVar.visible = ClientPrefs.data.showFPS && !useOld;
				Main.oldFpsVar.visible = ClientPrefs.data.showFPS && useOld;
			}
			HScript.setOnGlobalScript("useOldFPS", useOld);
		});

		// 强制覆盖 OldFPS 显示文字（null = 恢复正常显示）
		vars.set("setFpsOverride", function(?text:String = null, ?color:Int = null) {
			if (Main.oldFpsVar != null) {
				Main.oldFpsVar.forceText = text;
				Main.oldFpsVar.forceColor = color;
			}
		});

		// 快捷：让 OldFPS 闪烁显示诡异文字 n 秒
		vars.set("fpsGlitch", function(text:String, color:Int, duration:Float) {
			if (Main.oldFpsVar == null) return;
			Main.oldFpsVar.forceText = text;
			Main.oldFpsVar.forceColor = color;
			haxe.Timer.delay(function() {
				if (Main.oldFpsVar != null) {
					Main.oldFpsVar.forceText = null;
					Main.oldFpsVar.forceColor = null;
				}
			}, Std.int(duration * 1000));
		});

		// ── 加载模组中任意路径的文本文件 ──
		// path 是相对于 mod 根目录或 assets 根目录的路径，例如 "text/crash_report.txt"
		// 搜索顺序：mods/<currentMod>/<path> → mods/<path> → assets/<path>
		vars.set("loadModTextFile", function(path:String):String {
			#if sys
			var paths:Array<String> = [];
			#if MODS_ALLOWED
			if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
				paths.push(Paths.mods(Paths.currentModDirectory + '/' + path));
			for (mod in Paths.getGlobalMods())
				paths.push(Paths.mods(mod + '/' + path));
			#end
			paths.push(Paths.getPreloadPath(path));
			for (p in paths) {
				if (FileSystem.exists(p))
					return File.getContent(p);
			}
			#end
			return '';
		});

		// ── 解析 text 配置文件（#注释行、key=value格式） ──
		// 可选 prefix 过滤只返回指定前缀的行
		vars.set("parseTextConfig", function(content:String, ?prefix:String = null):Dynamic {
			var result = {};
			if (content == null || content.length == 0) return result;
			var lines = content.split("\n");
			for (line in lines) {
				line = StringTools.trim(line);
				if (line.length == 0 || line.startsWith("#")) continue;
				var eqIdx = line.indexOf("=");
				if (eqIdx < 0) continue;
				var key = StringTools.trim(line.substr(0, eqIdx));
				var val = StringTools.trim(line.substr(eqIdx + 1));
				if (prefix != null) {
					if (!key.startsWith(prefix)) continue;
					key = key.substr(prefix.length);
				}
				Reflect.setField(result, key, val);
			}
			return result;
		});

		// 获取当前正在显示的 FPS 样式名（"new" / "old"）
		vars.set("getFpsStyle", function():String {
			return Main.useOldFPS ? "old" : "new";
		});

		// ── OldPauseSubState 相关变量 ──
		vars.set("OldPauseSubState", substates.OldPauseSubState);
		vars.set("useOldPause", ClientPrefs.data.oldPauseMenu);

		// 切换暂停界面样式：true = 旧版，false = 新版
		// hscript 优先级高于设置（hscripts override settings）
		vars.set("setOldPause", function(useOld:Bool) {
			Main.useOldPause = useOld;
			HScript.setOnGlobalScript("useOldPause", useOld);
		});

		// 重置 hscript 覆盖，回到设置值
		vars.set("resetOldPause", function() {
			Main.useOldPause = null;
			HScript.setOnGlobalScript("useOldPause", ClientPrefs.data.oldPauseMenu);
		});

		vars.set("language", ClientPrefs.data.language);
		vars.set("customSubstate", CustomSubstate.instance);
		vars.set("customSubstateName", CustomSubstate.name);

		return vars;
	}

	/**
	 * Default preprocessor values available inside scripts.
	 * Presence in the map means "defined" (matching Haxe `#if` semantics),
	 * so `#if android`, `#if !ios`, `#if desktop && !web` etc. all work.
	 * Platform keys follow Haxe/OpenFL target names; engine keys are provided
	 * for mods that want to branch on the engine itself.
	 */
	public static function getDefaultPreprocessors():Map<String, Dynamic> {
		var defs:Map<String, Dynamic> = [
			"engine" => "SeiunEngine",
			"engineName" => "Seiun Engine",
			"hscript" => hscriptVersion,
		];

		#if android
		defs.set("android", true);
		#elseif ios
		defs.set("ios", true);
		#elseif mac
		defs.set("mac", true);
		#elseif linux
		defs.set("linux", true);
		#elseif windows
		defs.set("windows", true);
		#end

		#if web
		defs.set("web", true);
		defs.set("html5", true);
		#end

		#if desktop
		defs.set("desktop", true);
		#end

		#if mobile
		defs.set("mobile", true);
		#end

		#if switch
		defs.set("switch", true);
		#end

		#if sys
		defs.set("sys", true);
		#end

		return defs;
	}

	static function applyDefaultPreprocessors(parser:Parser):Void {
		for (k => v in getDefaultPreprocessors())
			parser.preprocessorValues.set(k, v);
	}

	function setupVariables():Void {
		// ── Default bindings ──
		try {
			var defaults = getDefaultVariables();
			for (k => v in defaults)
				set(k, v);
		} catch (e:Dynamic) {
			handleError('setupVariables → getDefaultVariables: $e');
			return;
		}

		// Self reference
		set('this', this);

		// 0.7.3+/1.0.4 兼容全局（HScript 侧）
		// English: 0.7.3+/1.0.4-compatible globals (HScript side)
		#if LUA_ALLOWED
		set('parentLua', parentLua);
		#else
		set('parentLua', null);
		#end
		set('controls', Controls.instance);

		set('setVar', function(name:String, value:Dynamic) {
			if (PlayState.instance != null && PlayState.instance.variables != null) PlayState.instance.variables.set(name, value);
			return value;
		});
		set('getVar', function(name:String) {
			if (PlayState.instance != null && PlayState.instance.variables != null && PlayState.instance.variables.exists(name))
				return PlayState.instance.variables.get(name);
			return null;
		});
		set('removeVar', function(name:String) {
			if (PlayState.instance != null && PlayState.instance.variables != null && PlayState.instance.variables.exists(name))
			{
				PlayState.instance.variables.remove(name);
				return true;
			}
			return false;
		});

		// 自定义回调注册（0.7.3+/1.0.4 的 createCallback / createGlobalCallback）
		// English: custom callback registration (0.7.3+/1.0.4 createCallback / createGlobalCallback)
		#if LUA_ALLOWED
		set('createGlobalCallback', function(name:String, func:Dynamic) {
			if (PlayState.instance != null && PlayState.instance.luaArray != null)
			{
				for (script in PlayState.instance.luaArray)
					if (script != null && script.lua != null && !script.closed)
						Lua_helper.add_callback(script.lua, name, func);
			}
		});
		set('createCallback', function(name:String, func:Dynamic, ?funk:script.lua.FunkinLua = null) {
			if (funk == null) funk = parentLua;
			if (funk != null) funk.addLocalCallback(name, func);
		});
		#end

		// Pre-register the hxCodec-compatible video classes so LUA addHaxeLibrary/runHaxeCode works.
		// Use direct compiled references (not Type.resolveClass) to guarantee the class is available.
		#if VIDEOS_ALLOWED
		try {
			set('MP4Handler', vlc.MP4Handler);
			set('MP4Sprite', vlc.MP4Sprite);
			set('VideoHandler', hxcodec.VideoHandler);
			set('VideoSprite', hxcodec.VideoSprite);
			set('FlxVideo', hxcodec.flixel.FlxVideo);
			set('FlxVideoSprite', hxcodec.flixel.FlxVideoSprite);
		} catch (e:Dynamic) {
			handleError('setupVariables → Video classes: $e');
			return;
		}
		#end

		// importScript
		set('importScript', function(path:String):Dynamic {
			if (closed) return null;
			try {
				var fullPath = path;
				if (!Path.isAbsolute(path))
					fullPath = Path.join([scriptDir, path]);

				var foundPath:String = null;
				for (ext in ['hx', 'hscript', 'hsc', 'hxs']) {
					var testPath = '$fullPath.$ext';
					if (FileSystem.exists(testPath)) { foundPath = testPath; break; }
					var assetsPath = 'assets/$path.$ext';
					if (FileSystem.exists(assetsPath)) { foundPath = assetsPath; break; }
				}

				if (foundPath == null) {
					TraceManager.warn('trace.hscript.notFound', 'HScript: Could not find script: {}', [path]);
					return null;
				}
				if (__importedPaths.contains(foundPath)) {
					TraceManager.debug('trace.hscript.alreadyImported', 'HScript: Already imported: {}', [foundPath]);
					return null;
				}

				var content = File.getContent(foundPath);
				__importedPaths.push(foundPath);
				var oldDir = scriptDir;
				scriptDir = Path.directory(foundPath);
				var result = execute(content);
				scriptDir = oldDir;
				return result;
			} catch (e:Dynamic) {
				handleError('Error importing "$path": $e');
				return null;
			}
		});

		// State reference (allows hscript to access current MusicBeatState/MusicBeatSubstate)
		// NOTE: FlxG.state resolves to FlxG.game._state; during early init (before
		// FlxGame is constructed, e.g. HScript.initialize() runs before addChild(new FlxGame))
		// FlxG.game is null, which is a native SIGSEGV that Haxe try/catch cannot trap.
		// Guard the whole chain explicitly.
		try {
			var __stateRef:Dynamic = null;
			@:privateAccess
			if (FlxG.game != null) __stateRef = FlxG.game._state;
			set('state', (__stateRef != null) ? __stateRef : this);
		} catch (e:Dynamic) { handleError('setupVariables → state: $e'); return; }
		set('getState', @:privateAccess function():Dynamic {
			if (FlxG.game == null) return null;
			return FlxG.game._state;
		});

		// Lua bridge (independent per-state, uses FunkinLua)
		#if LUA_ALLOWED
		try {
		set('runLuaCode', function(code:String):Dynamic {
			try {
				var l = LuaL.newstate();
				LuaL.openlibs(l);
				Lua.init_callbacks(l);
				backend.NativeCrash.installLuaPanic(l);
				LuaL.dostring(l, code);
				var result = Lua.tostring(l, -1);
				Lua.close(l);
				return result;
			} catch (e:Dynamic) { return null; }
		});
		set('FunkinLua', FunkinLua);
		set('LuaUtils', LuaUtils);
		set('LuaApi', LuaApi);
		} catch (e:Dynamic) { handleError('setupVariables → Lua: $e'); return; }
		#end

		// ── 函数管理：覆盖 / 重命名 / 恢复已设定函数（引擎预设回调也适用）
		// ── Function management: override / rename / restore already-set functions
		//    (engine-preset callbacks included)
		set('overrideFunction', function(name:String, fn:Dynamic, ?syncToLua:Bool = false):Bool
			return overrideFunction(name, fn, syncToLua));
		set('renameFunction', function(name:String, newName:String, ?removeOld:Bool = false):Bool
			return renameFunction(name, newName, removeOld));
		set('restoreFunction', function(name:String):Bool
			return restoreFunction(name));
		set('getFunction', function(name:String):Dynamic
			return get(name));
		set('functionNames', function():Array<String> {
			var result:Array<String> = [];
			if (interp != null && interp.variables != null)
				for (k in interp.variables.keys()) result.push(k);
			return result;
		});

		#if LUA_ALLOWED
		// ── Lua 桥接（hscript → lua）── Lua bridge (hscript → lua)
		set('callLuaFunction', function(name:String, ?args:Array<Dynamic> = null):Dynamic
			return LuaApi.callLuaFunction(name, args));
		set('setLuaVariable', function(name:String, value:Dynamic):Bool
			return LuaApi.setLuaVariable(name, value));
		set('getLuaVariable', function(name:String):Dynamic
			return LuaApi.getLuaVariable(name));
		set('renameLuaFunction', function(oldName:String, newName:String, ?removeOld:Bool = false):Bool
			return LuaApi.renameLuaFunction(oldName, newName, removeOld));
		set('addLuaFunction', function(name:String, fn:Dynamic, ?overrideExisting:Bool = false):Bool
			return LuaApi.addLuaFunction(name, fn, overrideExisting));
		set('overrideLuaFunction', function(name:String, wrapper:Dynamic):Bool
			return LuaApi.overrideLuaFunction(name, wrapper));
		set('restoreLuaFunction', function(name:String):Bool
			return LuaApi.restoreLuaFunction(name));
		set('removeLuaFunction', function(name:String):Bool
			return LuaApi.removeLuaFunction(name));
		set('luaFunctionExists', function(name:String):Bool
			return LuaApi.luaFunctionExists(name));
		#end

		// Input
		// 1.0.4: name 可省略, 且统一小写后查表。
		set('keyJustPressed', function(?name:String = null) {
			if (PlayState.instance == null) return false;
			if (name == null) name = '';
			if (!backend.CompatEngine.is063()) name = name.toLowerCase().trim();
			if (name.length == 0) return false;
			// 回放时: 录制中出现过的键以模拟状态为准 (还原 mod 自定义机制键, 如空格闪避)
			if (PlayState.replayMode && PlayState.instance.replayExam != null && PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyJustPressed(name);
			return switch(name) {
				case 'left': PlayState.instance.getControl('NOTE_LEFT_P');
				case 'down': PlayState.instance.getControl('NOTE_DOWN_P');
				case 'up': PlayState.instance.getControl('NOTE_UP_P');
				case 'right': PlayState.instance.getControl('NOTE_RIGHT_P');
				case 'accept': PlayState.instance.getControl('ACCEPT');
				case 'back': PlayState.instance.getControl('BACK');
				case 'pause': PlayState.instance.getControl('PAUSE');
				case 'reset': PlayState.instance.getControl('RESET');
				case 'space': FlxG.keys.justPressed.SPACE;
				default: false;
			}
		});
		set('keyPressed', function(?name:String = null) {
			if (PlayState.instance == null) return false;
			if (name == null) name = '';
			if (!backend.CompatEngine.is063()) name = name.toLowerCase().trim();
			if (name.length == 0) return false;
			if (PlayState.replayMode && PlayState.instance.replayExam != null && PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyPressed(name);
			return switch(name) {
				case 'left': PlayState.instance.getControl('NOTE_LEFT');
				case 'down': PlayState.instance.getControl('NOTE_DOWN');
				case 'up': PlayState.instance.getControl('NOTE_UP');
				case 'right': PlayState.instance.getControl('NOTE_RIGHT');
				case 'space': FlxG.keys.pressed.SPACE;
				default: false;
			}
		});
		set('keyReleased', function(?name:String = null) {
			if (PlayState.instance == null) return false;
			if (name == null) name = '';
			if (!backend.CompatEngine.is063()) name = name.toLowerCase().trim();
			if (name.length == 0) return false;
			if (PlayState.replayMode && PlayState.instance.replayExam != null && PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyJustReleased(name);
			return switch(name) {
				case 'left': PlayState.instance.getControl('NOTE_LEFT_R');
				case 'down': PlayState.instance.getControl('NOTE_DOWN_R');
				case 'up': PlayState.instance.getControl('NOTE_UP_R');
				case 'right': PlayState.instance.getControl('NOTE_RIGHT_R');
				case 'space': FlxG.keys.justReleased.SPACE;
				default: false;
			}
		});

		set('keyboardJustPressed', function(name:String) {
			if (PlayState.replayMode && PlayState.instance != null && PlayState.instance.replayExam != null
				&& PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyJustPressed(name);
			return Reflect.getProperty(FlxG.keys.justPressed, name);
		});
		set('keyboardPressed', function(name:String) {
			if (PlayState.replayMode && PlayState.instance != null && PlayState.instance.replayExam != null
				&& PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyPressed(name);
			return Reflect.getProperty(FlxG.keys.pressed, name);
		});
		set('keyboardReleased', function(name:String) {
			if (PlayState.replayMode && PlayState.instance != null && PlayState.instance.replayExam != null
				&& PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyJustReleased(name);
			return Reflect.getProperty(FlxG.keys.justReleased, name);
		});
		set('anyGamepadJustPressed', function(name:String) return FlxG.gamepads.anyJustPressed(name));
		set('anyGamepadPressed', function(name:String) return FlxG.gamepads.anyPressed(name));
		set('anyGamepadReleased', function(name:String) return FlxG.gamepads.anyJustReleased(name));

		set('gamepadAnalogX', function(id:Int, ?leftStick:Bool = true) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null) return 0.0;
			return controller.getXAxis(leftStick ? LEFT_ANALOG_STICK : RIGHT_ANALOG_STICK);
		});
		set('gamepadAnalogY', function(id:Int, ?leftStick:Bool = true) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null) return 0.0;
			return controller.getYAxis(leftStick ? LEFT_ANALOG_STICK : RIGHT_ANALOG_STICK);
		});
		set('gamepadJustPressed', function(id:Int, name:String) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null) return false;
			return Reflect.getProperty(controller.justPressed, name) == true;
		});
		set('gamepadPressed', function(id:Int, name:String) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null) return false;
			return Reflect.getProperty(controller.pressed, name) == true;
		});
		set('gamepadReleased', function(id:Int, name:String) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null) return false;
			return Reflect.getProperty(controller.justReleased, name) == true;
		});

		// Bind PlayState instance if available
		try {
			bindPlayState();
		} catch (e:Dynamic) {
			handleError('setupVariables → bindPlayState: $e');
			return;
		}
	}

	/**
	 * Bind PlayState-specific variables. Safe to call when PlayState is not ready.
	 */
	public function bindPlayState():Void {
		if (PlayState.instance == null) return;
		if (PlayState.SONG == null) return;
		if (FlxG.sound.music == null) return;
		if (ClientPrefs.data == null) return;

		set('game', PlayState.instance);
		set('curBpm', Conductor.bpm);
		set('bpm', PlayState.SONG.bpm);
		set('scrollSpeed', PlayState.SONG.speed);
		set('crochet', Conductor.crochet);
		set('stepCrochet', Conductor.stepCrochet);
		set('songLength', FlxG.sound.music.length);
		set('songName', PlayState.SONG.song);
		set('songPath', Paths.formatToSongPath(PlayState.SONG.song));
		set('startedCountdown', false);
		set('curStage', PlayState.SONG.stage);
		set('compatibility_mode', CompatEngine.compatMode());
		set('compatEngine', CompatEngine.current());
		set('isStoryMode', PlayState.isStoryMode);
		set('difficulty', PlayState.storyDifficulty);

		var diffName = CoolUtil.difficulties[PlayState.storyDifficulty];
		set('difficultyName', diffName);
		set('difficultyPath', Paths.formatToSongPath(diffName));
		set('weekRaw', PlayState.storyWeek);
		set('week', WeekData.weeksList[PlayState.storyWeek]);
		set('seenCutscene', PlayState.seenCutscene);

		// 不静态绑定 boyfriend/dad/gf/camXxx，
		// 它们在 PlayState.create() 中创建较晚，初始为 null。
		// PlayStateInterp.resolve() 会在运行时动态从 PlayState.instance 获取。

		set('healthGainMult', PlayState.instance.healthGain);
		set('healthLossMult', PlayState.instance.healthLoss);
		set('playbackRate', PlayState.instance.playbackRate);
		set('instakillOnMiss', PlayState.instance.instakillOnMiss);
		set('botPlay', PlayState.instance.cpuControlled);
		set('practice', PlayState.instance.practiceMode);
		set('luattf', ClientPrefs.data.luattf);
		set('addBehindGF', PlayState.instance.addBehindGF);
		set('addBehindDad', PlayState.instance.addBehindDad);
		set('addBehindBF', PlayState.instance.addBehindBF);

		set('setVar', function(name:String, value:Dynamic) {
			if (PlayState.instance == null || PlayState.instance.variables == null)
				return null;
			PlayState.instance.variables.set(name, value);
			return value;
		});
		set('getVar', function(name:String):Dynamic {
			if (PlayState.instance == null || PlayState.instance.variables == null)
				return null;
			return PlayState.instance.variables.exists(name) ? PlayState.instance.variables.get(name) : null;
		});
		set('removeVar', function(name:String):Bool {
			if (PlayState.instance == null || PlayState.instance.variables == null)
				return false;
			if (PlayState.instance.variables.exists(name)) {
				PlayState.instance.variables.remove(name);
				return true;
			}
			return false;
		});

		set('luaDebugMode', false);
		set('luaDeprecatedWarnings', true);
		set('inChartEditor', false);
	}

	// ==================== Script Execution ====================

	function loadScriptFromPath(scriptPath:String):Void {
		var content = File.getContent(scriptPath);
		execute(content);
		TraceManager.info('trace.hscript.loaded', 'HScript loaded: {}', [scriptPath]);
	}

	public function execute(codeToRun:String):Dynamic {
		if (closed) return FunkinLua.Function_StopHScript;
		@:privateAccess parser.line = 1;
		parser.allowTypes = true;
		var expr = parser.parseString(codeToRun);
		execDepth++;
		var result:Dynamic;
		try {
			result = interp.execute(expr);
			execDepth--;
			bumpVarEpoch(); // the code may have written any global
		} catch (e:Dynamic) {
			execDepth--;
			bumpVarEpoch();
			throw e;
		}
		// execute() 不是每帧回调：这里不重置连续错误计数（计数只归每帧/每步回调，见 ScriptErrorGuard）。
		return result;
	}

	public function call(func:String, args:Array<Dynamic>):Dynamic {
		if (closed) return FunkinLua.Function_StopHScript;
		if (args == null) args = [];
		// Negative callback cache (see nilVars): skip the lookup when this name was already
		// observed to be absent and nothing could have defined it since.
		var stamp:Int = probeStamp();
		if (stamp >= 0 && nilVars != null)
		{
			var seen:Null<Int> = nilVars.get(func);
			if (seen != null && seen == stamp) return FunkinLua.Function_Continue;
		}
		try {
			var f:Dynamic = interpGet(func);
			if (f != null && Reflect.isFunction(f)) {
				// 只有每帧/每步回调的成功才重置连续错误计数（见 ScriptErrorGuard）。
				if (ScriptErrorGuard.isLoopCallback(func)) errorLoopCount = 0;
				execDepth++;
				try {
					var ret:Dynamic = Reflect.callMethod(null, f, args);
					execDepth--;
					bumpVarEpoch(); // the body may have written any global
					return ret;
				} catch (e:Dynamic) {
					execDepth--;
					bumpVarEpoch(); // a body that threw may still have written globals
					throw e;
				}
			}
			if (f == null && stamp >= 0)
			{
				if (nilVars == null) nilVars = new Map();
				nilVars.set(func, stamp);
			}
			return FunkinLua.Function_Continue;
		} catch (e:Dynamic) {
			handleError('Error calling "$func": $e', func);
			return FunkinLua.Function_StopHScript;
		}
	}

	public function set(variable:String, data:Dynamic):Void {
		if (closed) return;
		try { interp.variables.set(variable, data); if (nilVars != null) nilVars.remove(variable); }
		catch (e:Dynamic) { handleError('Failed to set "$variable": $e'); }
	}

	public function get(variable:String):Dynamic {
		if (closed) return null;
		try { return interpGet(variable); }
		catch (e:Dynamic) { handleError('Failed to get "$variable": $e'); return null; }
	}

	public function exists(variable:String):Bool {
		if (closed) return false;
		try { return interpGet(variable) != null; }
		catch (e:Dynamic) { return false; }
	}

	/**
	 * Look a variable up across all three variable tables
	 * (variables / publicVariables / staticVariables), hscript-seiun style.
	 */
	function interpGet(variable:String):Dynamic {
		if (interp == null) return null;
		if (interp.variables.exists(variable)) return interp.variables.get(variable);
		if (interp.publicVariables != null && interp.publicVariables.exists(variable)) return interp.publicVariables.get(variable);
		if (interp.staticVariables != null && interp.staticVariables.exists(variable)) return interp.staticVariables.get(variable);
		return null;
	}

	/**
	 * Script-module import callback: when a script does `import ai.Enemy` and
	 * the module isn't a compiled Haxe class, try to load it from the
	 * hscripts folder (ai/Enemy.hx / .hscript / .hsc / .hxs).
	 */
	function importFailedCallback(cl:Array<String>):Bool {
		var relative = cl.join("/");
		var candidates:Array<String> = [];
		#if MODS_ALLOWED
		candidates.push(Paths.mods('hscripts/$relative'));
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			candidates.push(Paths.mods(Paths.currentModDirectory + '/hscripts/$relative'));
		for (mod in Paths.getGlobalMods())
			candidates.push(Paths.mods(mod + '/hscripts/$relative'));
		#end
		candidates.push(Paths.getPreloadPath('hscripts/$relative'));

		for (base in candidates) {
			for (hxExt in ["hx", "hscript", "hsc", "hxs"]) {
				var p = '$base.$hxExt';
				if (__importedPaths.contains(p)) return true;
				if (FileSystem.exists(p)) {
					var code = File.getContent(p);
					var expr = null;
					try {
						if (code != null && code.trim() != "") {
							@:privateAccess parser.line = 1;
							expr = parser.parseString(code, cl.join(".") + "." + hxExt);
						}
					} catch (e:Dynamic) {
						handleError('Failed to import $p: $e');
					}
					if (expr != null) {
						interp.exprReturn(expr);
						__importedPaths.push(p);
						bumpVarEpoch(); // imported code may have defined globals
					}
					return true;
				}
			}
		}
		return false;
	}

	// ==================== Function Management ====================

	/**
	 * 覆盖一个已设定函数（引擎预设回调如 keyJustPressed / getProperty 也适用）。
	 * 原函数会被备份，之后可用 restoreFunction() 恢复。
	 * English: Override an already-set function (engine-preset callbacks such as
	 * keyJustPressed / getProperty included). The original is backed up and can
	 * be restored later with restoreFunction().
	 *
	 * @param name 函数名（变量名）
	 * @param fn 新函数
	 * @param syncToLua true 时同时覆盖到所有活跃 Lua 实例（需要 LUA_ALLOWED）
	 * @return Bool 是否成功
	 */
	public function overrideFunction(name:String, fn:Dynamic, ?syncToLua:Bool = false):Bool {
		if (closed || name == null || name.length == 0) return false;
		if (fn == null || !Reflect.isFunction(fn)) return false;
		try {
			if (!functionBackups.exists(name)) {
				var old:Dynamic = interp.variables.get(name);
				if (old != null) functionBackups.set(name, old);
			}
			interp.variables.set(name, fn);
			bumpVarEpoch(); // a function may have appeared under any name
			#if LUA_ALLOWED
			if (syncToLua && LuaApi.addLuaFunction(name, fn, true)) {
				TraceManager.info('trace.hscript.overrideSynced', 'HScript: "{}" override synced to Lua', [name]);
			}
			#end
			return true;
		} catch (e:Dynamic) {
			handleError('overrideFunction("$name"): $e');
			return false;
		}
	}

	/**
	 * 重命名一个已设定函数：把 name 指向的函数绑定到新名字上。
	 * English: Rename an already-set function — bind the function pointed to by
	 * `name` to a new name.
	 *
	 * @param name 原函数名
	 * @param newName 新函数名
	 * @param removeOld true 时移除旧名字（旧名字指向同一函数的别名会丢失）
	 * @return Bool 是否成功
	 */
	public function renameFunction(name:String, newName:String, ?removeOld:Bool = false):Bool {
		if (closed || name == null || newName == null || name.length == 0 || newName.length == 0) return false;
		if (name == newName) return true;
		try {
			if (!interp.variables.exists(name)) return false;
			if (!functionBackups.exists(name))
				functionBackups.set(name, interp.variables.get(name));
			interp.variables.set(newName, interp.variables.get(name));
			if (removeOld) interp.variables.remove(name);
			bumpVarEpoch();
			return true;
		} catch (e:Dynamic) {
			handleError('renameFunction("$name" → "$newName"): $e');
			return false;
		}
	}

	/**
	 * 恢复被 overrideFunction / renameFunction 覆盖的函数。
	 * English: Restore a function that was overridden via
	 * overrideFunction / renameFunction.
	 *
	 * @param name 函数名
	 * @return Bool 是否有备份并恢复成功
	 */
	public function restoreFunction(name:String):Bool {
		if (closed || !functionBackups.exists(name)) return false;
		try {
			interp.variables.set(name, functionBackups.get(name));
			bumpVarEpoch();
			functionBackups.remove(name);
			return true;
		} catch (e:Dynamic) {
			handleError('restoreFunction("$name"): $e');
			return false;
		}
	}

	/**
	 * Reload the script from disk, preserving non‑function variables.
	 * (keeps non-function variables – useful during development.)
	 */
	public function reload():Void {
		if (closed || scriptName == '<inline>') return;
		var saved:Map<String, Dynamic> = [];
		for (k => v in interp.variables)
			if (!Reflect.isFunction(v))
				saved[k] = v;

		var oldPath = scriptDir + '/' + scriptName;
		__importedPaths = [];
		setupVariables();
		loadScriptFromPath(oldPath);

		for (k => v in saved)
			interp.variables.set(k, v);

		call('onCreate', []);
		bumpVarEpoch();
		TraceManager.info('trace.hscript.reloaded', 'Script reloaded: {}', [scriptName]);
	}

	public function stop():Void {
		if (closed) return;
		closed = true;
		interp = null;
		parser = null;
	}

	// ==================== Error Handling ====================

	function handleError(message:String, callback:String = null):Void {
		if (closed) return;

		// Error-loop protection: 只有每帧/每步回调参与计数（见 ScriptErrorGuard）。
		// 达到上限后只是安静下来（不再打印 / 不再弹窗），脚本**继续运行** —— 1.0.4 并没有
		// "因报错停掉整个脚本"这种行为，关掉会让它在别的回调里本该正常工作的功能一起失效。
		var silenced:Bool = false;
		if (ClientPrefs.data != null && ClientPrefs.data.ignoreErrorLoopScripts && ScriptErrorGuard.isLoopCallback(callback)) {
			errorLoopCount++;
			if (errorLoopCount >= ClientPrefs.data.scriptErrorLimit) silenced = true;
		}

		if (!silenced) {
			// Always log via TraceManager so we can see the error in the console
			// even when ClientPrefs / Language are not yet initialized.
			TraceManager.error('trace.hscript.error', 'HScript error in {}: {}', [scriptDir + '/' + scriptName, message]);
		}

		if (ClientPrefs.data == null) return;

		if (ClientPrefs.data.ignoreErrorLoopScripts) {
			if (silenced && (errorLoopCount == ClientPrefs.data.scriptErrorLimit || errorLoopCount % 600 == 0))
				TraceManager.warn('trace.script.errorLoopSilenced', 'Repeated errors silenced ({} times, script still running): {} :: {}', [errorLoopCount, scriptName, callback]);
			return;
		}

		// Legacy behavior: show a dialog and stop the script on the first error.
		if (!ClientPrefs.data.hscriptErrorHandling) return;
		closed = true;
		var dialogMessage:String = Language.get('script_hscript_error_in', 'HScript Error in') + ' ' + scriptDir + '/' + scriptName + '\n' + message;
        backend.Dialog.show(Language.get('script_hscript_error', 'HScript Error'), dialogMessage, 'Error');
		interp = null;
		parser = null;
	}
}

class CustomFlxColor {
	public static var TRANSPARENT(default, null):Int = FlxColor.TRANSPARENT;
	public static var BLACK(default, null):Int = FlxColor.BLACK;
	public static var WHITE(default, null):Int = FlxColor.WHITE;
	public static var GRAY(default, null):Int = FlxColor.GRAY;
	public static var GREEN(default, null):Int = FlxColor.GREEN;
	public static var LIME(default, null):Int = FlxColor.LIME;
	public static var YELLOW(default, null):Int = FlxColor.YELLOW;
	public static var ORANGE(default, null):Int = FlxColor.ORANGE;
	public static var RED(default, null):Int = FlxColor.RED;
	public static var PURPLE(default, null):Int = FlxColor.PURPLE;
	public static var BLUE(default, null):Int = FlxColor.BLUE;
	public static var BROWN(default, null):Int = FlxColor.BROWN;
	public static var PINK(default, null):Int = FlxColor.PINK;
	public static var MAGENTA(default, null):Int = FlxColor.MAGENTA;
	public static var CYAN(default, null):Int = FlxColor.CYAN;

	public static function fromInt(Value:Int):Int
		return cast FlxColor.fromInt(Value);

	public static function fromRGB(Red:Int, Green:Int, Blue:Int, Alpha:Int = 255):Int
		return cast FlxColor.fromRGB(Red, Green, Blue, Alpha);

	public static function fromRGBFloat(Red:Float, Green:Float, Blue:Float, Alpha:Float = 1):Int
		return cast FlxColor.fromRGBFloat(Red, Green, Blue, Alpha);

	public static inline function fromCMYK(Cyan:Float, Magenta:Float, Yellow:Float, Black:Float, Alpha:Float = 1):Int
		return cast FlxColor.fromCMYK(Cyan, Magenta, Yellow, Black, Alpha);

	public static function fromHSB(Hue:Float, Sat:Float, Brt:Float, Alpha:Float = 1):Int
		return cast FlxColor.fromHSB(Hue, Sat, Brt, Alpha);

	public static function fromHSL(Hue:Float, Sat:Float, Light:Float, Alpha:Float = 1):Int
		return cast FlxColor.fromHSL(Hue, Sat, Light, Alpha);

	public static function fromString(str:String):Int
		return cast FlxColor.fromString(str);
}

/**
 * 自定义 Interp，当变量在 locals/variables/imports 中都找不到时，
 * 尝试从 PlayState.instance 动态解析。解决了 HScript 加载时
 * boyfriend/dad/gf 等尚未创建导致绑定为 null 的问题。
 */
class PlayStateInterp extends hscript.Interp
{
	private var _instanceFields:Array<String> = [];

	public function new()
	{
		super();
		// 缓存 PlayState 的所有公开字段名，加速后续 resolve
		try {
			if (PlayState.instance != null)
				_instanceFields = Type.getInstanceFields(Type.getClass(PlayState.instance));
			else
				_instanceFields = Type.getInstanceFields(PlayState);
		} catch (e:Dynamic) {
			_instanceFields = [];
			mohong.TraceManager.error('trace.hscript.interpInit', 'PlayStateInterp init: {}', [e]);
		}
	}

	override function resolve(id:String):Dynamic
	{
		// 1) 局部变量
		if (locals.exists(id))
		{
			var l = locals.get(id);
			return l.r;
		}

		// 2) 显式设置的变量 (包括预设绑定)
		if (variables.exists(id))
		{
			var v = variables.get(id);
			return v;
		}

		// 3) import 的类
		if (imports.exists(id))
		{
			var v = imports.get(id);
			return v;
		}

		// 3.5) 脚本类 / 静态 / 公开变量 (hscript-seiun)
		if (customClasses.exists(id)) return customClasses.get(id);
		if (staticVariables.exists(id)) return staticVariables.get(id);
		if (publicVariables.exists(id)) return publicVariables.get(id);

		// 4) 动态从 PlayState.instance 解析
		if (PlayState.instance != null && _instanceFields.contains(id))
		{
			var v = Reflect.getProperty(PlayState.instance, id);
			if (v != null) return v;
		}

		error(EUnknownVariable(id));
		return null;
	}
}
#end
