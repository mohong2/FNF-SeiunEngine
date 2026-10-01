package script.lua;

import backend.ModConfig;
import backend.MusicBeatState;
import backend.CompatEngine;
import Achievements;
import backend.Difficulty;
import haxe.Constraints.Function;
import script.hscript.HScript;
import script.ScriptErrorGuard;
import substates.PauseSubState;
import states.FreeplayState;
import states.StoryMenuState;
import substates.GameOverSubstate;
import states.MainMenuState;
import states.ModState;
import substates.ModSubState;
import openfl.display.BitmapData;
import backend.MusicBeatSubstate;
import animateatlas.AtlasFrameMaker;
import flixel.addons.effects.FlxTrail;
import flixel.input.keyboard.FlxKey;
import flixel.system.FlxSound;
import flixel.FlxBasic;
import flixel.FlxObject;
import openfl.Lib;
import openfl.display.BlendMode;
import openfl.filters.BitmapFilter;
import openfl.utils.Assets;
import flixel.util.FlxSave;
import flixel.util.FlxTimer;
import flixel.tweens.FlxTween;
import flixel.tweens.FlxTween.FlxTweenType;
import flixel.tweens.FlxEase.EaseFunction;
import flixel.addons.transition.FlxTransitionableState;
import flixel.system.FlxAssets.FlxShader;
import WiggleEffect.WiggleEffectType;
import haxe.io.Path;

#if flxanimate
import flxanimate.FlxAnimate;
#end
 
#if (!flash && sys)
import flixel.addons.display.FlxRuntimeShader;
#end

#if sys
import sys.FileSystem;
import sys.io.File;
#end

import Type.ValueType;
import Controls;
import DialogueBoxPsych;

#if HSCRIPT_ALLOWED
import hscript.Parser;
import hscript.Interp;
import hscript.Expr;
#end

#if cpp
import Discord;
#end

using StringTools;
import mohong.TraceManager;

@:allow(HScript)
class FunkinLua {
	var classPathMap:Map<String, String> = [
		"backend.ClientPrefs" => "ClientPrefs",
		"GameOverSubstate" => "substates.GameOverSubstate",
		"GameplayChangersSubstate" => "substates.GameplayChangersSubstate",
		"PauseSubState" => "substates.PauseSubState",
		"ResetScoreSubState" => "substates.ResetScoreSubState",
		"ScoreHistorySubstate" => "substates.ScoreHistorySubstate",
		"PlayState" => "states.PlayState"
	];
	var replaceMap:Map<String, String> = [
	];

	var extraMap:Map<String, Array<{target: String, val: Dynamic}>> = [
	"timeBar.visible" => [{target: "timeBarBG.visible", val: null}]
	];

	public static var luaversion:String = "0.64.1";
	public var callbacks:Map<String, Dynamic> = new Map<String, Dynamic>();
	public static var Function_Stop:Dynamic = "##PSYCHLUA_FUNCTIONSTOP";
	public static var Function_Continue:Dynamic = "##PSYCHLUA_FUNCTIONCONTINUE";
	public static var Function_StopLua:Dynamic = "##PSYCHLUA_FUNCTIONSTOPLUA";
	public static var Function_StopHScript:Dynamic = "##PSYCHLUA_FUNCTIONSTOPHSCRIPT";
    public static var Function_StopAll:Dynamic = "##PSYCHLUA_FUNCTIONSTOPALL";
	static final instanceStr:Dynamic = "##PSYCHLUA_STRINGTOOBJ";
	//public var errorHandler:String->Void;
	#if LUA_ALLOWED
	public var lua:State = null;
	public var modFolder:String = null;
	#end
	public var camTarget:FlxCamera;
	public var scriptName:String = '';
	public var closed:Bool = false;

	/** 连续报错计数：脚本的每帧/每步回调（见 ScriptErrorGuard）连续报错达到上限时会被静默忽略。 */
	public var errorLoopCount:Int = 0;

	#if HSCRIPT_ALLOWED
	public static var hscript:HScript = null;
	#end

	/**
	 * require 支持：本实例注册的解析回调名 / chunk 表名。
	 * English: require support — unique resolver callback name & chunk table name
	 * for this instance (cleaned up on stop() to avoid leaking the global callback map).
	 */
	var __requireResolveName:String = null;
	var __requireChunksName:String = null;
	static var __requireUid:Int = 0;
	static var __requireChunkRef:Int = 0;

	/** import 支持：本实例注册的解析回调名（stop 时清理）。 English: import support — unique resolver callback name (cleaned up on stop()). */
	var __importResolveName:String = null;
	static var __importUid:Int = 0;

	/**
	 * 从多个文件夹收集所有 .lua 文件并加载，filesPushed 用于跨批次去重。
	 */
	public static function collectFromFolders(folders:Array<String>, filesPushed:Array<String>):Array<FunkinLua>
	{
		var result:Array<FunkinLua> = [];
		#if LUA_ALLOWED
		for (folder in folders)
		{
			if (!FileSystem.exists(folder)) continue;
			for (file in FileSystem.readDirectory(folder))
			{
				if (!file.endsWith('.lua') || filesPushed.contains(file)) continue;
				try {
					result.push(new FunkinLua(folder + file));
					filesPushed.push(file);
				} catch (e:Dynamic) {
					TraceManager.error('trace.funkinLua.collectFailed', 'Failed: {} - {}', [file, e]);
				}
			}
		}
		#end
		return result;
	}

	/**
	 * 加载指定路径列表中的单个 .lua 文件。
	 */
	public static function collectStandalone(paths:Array<String>, filesPushed:Array<String>):Array<FunkinLua>
	{
		var result:Array<FunkinLua> = [];
		#if LUA_ALLOWED
		for (path in paths)
		{
			if (!FileSystem.exists(path) || filesPushed.contains(path)) continue;
			try {
				result.push(new FunkinLua(path));
				filesPushed.push(path);
			} catch (e:Dynamic) {
				TraceManager.error('trace.funkinLua.collectFailed', 'Failed: {} - {}', [path, e]);
			}
		}
		#end
		return result;
	}

	public function new(script:String) {
		#if LUA_ALLOWED
		lua = LuaL.newstate();
		LuaL.openlibs(lua);
		Lua.init_callbacks(lua);

		//trace('Lua version: ' + Lua.version());
		//trace("LuaJIT version: " + Lua.versionJIT());

		//LuaL.dostring(lua, CLENSE);

		// In compatibility mode, suppress unsupported type traces (old behavior)
		Convert.enableUnsupportedTraces = CompatEngine.compatMode();

		initHaxeModule();
		scriptName = script;
	
		CoolUtil.traceMsg('trace.luaLoaded', 'Lua file loaded successfully: {}', [script]);

		var myFolder:Array<String> = this.scriptName.split('/');
		#if MODS_ALLOWED
		if(myFolder[0] + '/' == Paths.mods() && (Paths.currentModDirectory == myFolder[1] || Paths.getGlobalMods().contains(myFolder[1]))) //is inside mods folder
			this.modFolder = myFolder[1];
		#end

		// Lua shit
        set('Function_StopHScript', Function_StopHScript);
        set('Function_StopAll', Function_StopAll);
        set('Function_StopLua', Function_StopLua);
        set('Function_Stop', Function_Stop);
        set('Function_Continue', Function_Continue);

		set('luaDebugMode', false);
		set('luaDeprecatedWarnings', true);
		set('inChartEditor', false);

		set('luaVersion', luaversion);
		set('hscriptVersion', HScript.hscriptVersion);

		set('language', ClientPrefs.data.language);

		// Lua require() 支持：把脚本目录 / 模组 lua 目录接入模块搜索链
		setupRequireSupport();
		// Lua import() 支持：加载并立即执行目标 Lua 文件（include 语义）
		setupImportSupport();

		// PlayState-specific variables (only set when PlayState is active)
		if (PlayState.instance != null && PlayState.SONG != null)
		{
			// Song/Week shit
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

			var difficultyName:String = CoolUtil.difficulties[PlayState.storyDifficulty];
			set('difficultyName', difficultyName);
			set('difficultyPath', Paths.formatToSongPath(difficultyName));
			set('weekRaw', PlayState.storyWeek);
			set('week', WeekData.weeksList[PlayState.storyWeek]);
			set('seenCutscene', PlayState.seenCutscene);

			// PlayState gameplay variables
			set('score', 0);
			set('misses', 0);
			set('hits', 0);
			set('rating', 0);
			set('ratingName', '');
			set('ratingFC', '');
			set('inGameOver', false);
			set('mustHitSection', false);
			set('altAnim', false);
			set('gfSection', false);

			set('healthGainMult', PlayState.instance.healthGain);
			set('healthLossMult', PlayState.instance.healthLoss);
			set('playbackRate', PlayState.instance.playbackRate);
			set('instakillOnMiss', PlayState.instance.instakillOnMiss);
			set('botPlay', PlayState.instance.cpuControlled);
			set('practice', PlayState.instance.practiceMode);

			// Default character positions woooo
			set('defaultBoyfriendX', PlayState.instance.BF_X);
			set('defaultBoyfriendY', PlayState.instance.BF_Y);
			set('defaultOpponentX', PlayState.instance.DAD_X);
			set('defaultOpponentY', PlayState.instance.DAD_Y);
			set('defaultGirlfriendX', PlayState.instance.GF_X);
			set('defaultGirlfriendY', PlayState.instance.GF_Y);

			// Character shit
			set('boyfriendName', PlayState.SONG.player1);
			set('dadName', PlayState.SONG.player2);
			set('gfName', PlayState.SONG.gfVersion);

			set('hasVocals', PlayState.SONG.needsVoices);
			set('curSection', 0);
			set('combo', 0);

			// 0.7.3+/1.0.4 新增的全局变量（兼容旧模组）
			// Globals added in 0.7.3+/1.0.4 (kept for mod compatibility)
			set('deaths', PlayState.deathCounter);
			set('totalPlayed', PlayState.instance.totalPlayed);
			set('totalNotesHit', PlayState.instance.totalNotesHit);
			set('controls', PlayState.instance.controls);
			set('loadedSongName', Song.loadedSongName);
			set('loadedSongPath', Paths.formatToSongPath(Song.loadedSongName));
			set('chartPath', Song.chartPath);
			set('difficultyNameTranslation', Difficulty.getString(true));
		}

		// Camera poo
		set('cameraX', 0);
		set('cameraY', 0);

		// Screen stuff
		set('screenWidth', FlxG.width);
		set('screenHeight', FlxG.height);

		// PlayState cringe ass nae nae bullcrap (common)
		set('curBeat', 0);
		set('curStep', 0);
		set('curDecBeat', 0);
		set('curDecStep', 0);

		set('version', CompatEngine.current());

		// Some settings, no jokes
		set('downscroll', ClientPrefs.data.downScroll);
		set('middlescroll', ClientPrefs.data.middleScroll);
		set('framerate', ClientPrefs.data.framerate);
		set('ghostTapping', ClientPrefs.data.ghostTapping);
		set('hideHud', ClientPrefs.data.hideHud);
		set('timeBarType', ClientPrefs.data.timeBarType);
		set('scoreZoom', ClientPrefs.data.scoreZoom);
		set('cameraZoomOnBeat', ClientPrefs.data.camZooms);
		set('flashingLights', ClientPrefs.data.flashing);
		set('noteOffset', ClientPrefs.data.noteOffset);
		set('healthBarAlpha', ClientPrefs.data.healthBarAlpha);
		set('noResetButton', ClientPrefs.data.noReset);
		set('lowQuality', ClientPrefs.data.lowQuality);
		set('shadersEnabled', ClientPrefs.data.shaders);
		set('scriptName', scriptName);
		set('currentModDirectory', Paths.currentModDirectory);
		set('modFolder', modFolder);

		set('guitarHeroSustains', ClientPrefs.data.guitarHeroSustains);
		set('noteSkin', ClientPrefs.data.noteSkin);
		set('splashSkin', ClientPrefs.data.splashSkin);
		set('splashAlpha', ClientPrefs.data.splashAlpha);
		set('noteSkinPostfix', Note.getNoteSkinPostfix());
		set('splashSkinPostfix', NoteSplash.getSplashSkinPostfix());

		set('luattf', ClientPrefs.data.luattf);
		for (i in 0...4) {
			set('defaultPlayerStrumX' + i, 0);
			set('defaultPlayerStrumY' + i, 0);
			set('defaultOpponentStrumX' + i, 0);
			set('defaultOpponentStrumY' + i, 0);
		}

		#if windows
		set('buildTarget', 'windows');
		#elseif linux
		set('buildTarget', 'linux');
		#elseif mac
		set('buildTarget', 'mac');
		#elseif html5
		set('buildTarget', 'browser');
		#elseif android
		set('buildTarget', 'android');
		#else
		set('buildTarget', 'unknown');
		#end

		// ── 自定义 substate（CustomSubstate，脚本通过 onCustomSubstate* 事件控制内容）
		// ── Custom substate: content is driven by the onCustomSubstate* script events
		Lua_helper.add_callback(lua, "openCustomSubstate", function(name:String, pauseGame:Bool = false) {
			if (PlayState.instance == null) {
				luaTrace("openCustomSubstate: only available during gameplay!", false, false, FlxColor.RED);
				return false;
			}
			if(pauseGame)
			{
				PlayState.instance.persistentUpdate = false;
				PlayState.instance.persistentDraw = true;
				PlayState.instance.paused = true;
				if(FlxG.sound.music != null) {
					FlxG.sound.music.pause();
					if (PlayState.instance.vocals != null) PlayState.instance.vocals.pause();
				}
			}
			PlayState.instance.openSubState(new CustomSubstate(name));
			return true;
		});

		Lua_helper.add_callback(lua, "closeCustomSubstate", function() {
			if(CustomSubstate.instance != null)
			{
				var target:Dynamic = (PlayState.instance != null) ? PlayState.instance : FlxG.state;
				if (target != null) target.closeSubState();
				CustomSubstate.instance = null;
				return true;
			}
			return false;
		});

		// 把已创建的 Lua 对象（makeLuaSprite 等）插入 CustomSubstate
		// Insert an already-created Lua object (e.g. makeLuaSprite) into the CustomSubstate
		Lua_helper.add_callback(lua, "insertToCustomSubstate", function(tag:String, ?pos:Int = -1) {
			if(CustomSubstate.instance == null || PlayState.instance == null)
				return false;
			var tagObject:Dynamic = PlayState.instance.getLuaObject(tag, true);
			if(tagObject != null && Std.isOfType(tagObject, FlxObject))
			{
				if(pos < 0) CustomSubstate.instance.add(cast tagObject);
				else CustomSubstate.instance.insert(pos, cast tagObject);
				return true;
			}
			return false;
		});

		// ── 自定义完整 state（ModState，从 data/states/<name> 加载 Lua/hscript）
		// ── Custom full state (ModState): loads Lua/hscript from data/states/<name>
		Lua_helper.add_callback(lua, "switchToModState", function(stateName:String, ?data:Dynamic = null) {
			if (stateName == null || stateName.length == 0) return false;
			MusicBeatState.switchState(new ModState(stateName, data));
			return true;
		});

		// ── 自定义 substate（ModSubState，从 data/states/<name> 加载 Lua/hscript）
		// ── Custom substate (ModSubState): loads Lua/hscript from data/states/<name>
		Lua_helper.add_callback(lua, "openModSubState", function(stateName:String, ?data:Dynamic = null) {
			if (stateName == null || stateName.length == 0) return false;
			if (FlxG.state == null) return false;
			FlxG.state.openSubState(new ModSubState(stateName, data));
			return true;
		});

		Lua_helper.add_callback(lua, "closeModSubState", function() {
			if (FlxG.state == null || FlxG.state.subState == null) return false;
			if (Std.isOfType(FlxG.state.subState, ModSubState)) {
				FlxG.state.closeSubState();
				return true;
			}
			return false;
		});

		// ── state 信息 / 导航工具 ── State info & navigation helpers
		Lua_helper.add_callback(lua, "getStateName", function():String {
			if (FlxG.state == null) return '';
			var cls:String = Type.getClassName(Type.getClass(FlxG.state));
			return (cls == null) ? '' : cls.substr(cls.lastIndexOf('.') + 1);
		});

		Lua_helper.add_callback(lua, "getSubStateName", function():String {
			if (FlxG.state == null || FlxG.state.subState == null) return '';
			var cls:String = Type.getClassName(Type.getClass(FlxG.state.subState));
			return (cls == null) ? '' : cls.substr(cls.lastIndexOf('.') + 1);
		});

		Lua_helper.add_callback(lua, "switchToState", function(stateName:String) {
			if (stateName == null || stateName.length == 0) return false;
			var cls:Class<Dynamic> = Type.resolveClass('states.' + stateName);
			if (cls == null) cls = Type.resolveClass(stateName);
			if (cls == null) return false;
			try {
				var st:Dynamic = Type.createInstance(cls, []);
				if (st == null) return false;
				MusicBeatState.switchState(cast st);
				return true;
			} catch (e:Dynamic) {
				luaTrace("switchToState: failed to create '" + stateName + "': " + e, false, false, FlxColor.RED);
				return false;
			}
		});

		// shader shit
		Lua_helper.add_callback(lua, "initLuaShader", function(name:String, glslVersion:Int = 120) {
			if(!ClientPrefs.data.shaders) return false;

			#if (!flash && MODS_ALLOWED && sys)
			return initLuaShader(name, glslVersion);
			#else
			luaTrace("initLuaShader: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
			return false;
		});
		
		Lua_helper.add_callback(lua, "setSpriteShader", function(obj:String, shader:String) {
			if(!ClientPrefs.data.shaders) return false;

			#if (!flash && MODS_ALLOWED && sys)
			if((PlayState.instance != null && !PlayState.instance.runtimeShaders.exists(shader)) && !initLuaShader(shader))
			{
				luaTrace('setSpriteShader: Shader $shader is missing!', false, false, FlxColor.RED);
				return false;
			}

			var killMe:Array<String> = obj.split('.');
			var leObj:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				leObj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(leObj != null) {
				var arr:Array<String> = (PlayState.instance != null) ? PlayState.instance.runtimeShaders.get(shader) : null;
				ensureSpriteFrame(leObj);
				leObj.shader = new FlxRuntimeShader(arr[0], arr[1]);
				return true;
			}
			#else
			luaTrace("setSpriteShader: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
			return false;
		});
		// Wiggle effect (source/WiggleEffect.hx): the engine has shipped the shader since 0.6.3 but
		// had no way in from Lua, so a stage script asking for a wiggling background died on
		// "attempt to call global 'addWiggleEffect' (a nil value)" -- and every line after that one
		// in the same onCreate (the sprites and the background shader) never ran.
		// Signature and behaviour are the PE fork H-Slice's: speed, frequency, amplitude, then the
		// effect type by name ('FLAG' default), the effect registered in PlayState.wiggleMap so its
		// uTime advances once per frame.
		Lua_helper.add_callback(lua, "addWiggleEffect", function(tag:String, ?spd:Float = 2.25, ?freq:Float = 5, ?amp:Float = 0.1, ?type:String = 'FLAG') {
			var shit:FlxSprite = resolveSpriteByTag(tag);
			if(shit == null) {
				luaTrace('addWiggleEffect: no sprite named "$tag"', false, false, FlxColor.RED);
				return false;
			}
			var neoWiggle:WiggleEffect = new WiggleEffect();
			neoWiggle.effectType = wiggleTypeFromName(type);
			neoWiggle.waveSpeed = spd;
			neoWiggle.waveFrequency = freq;
			neoWiggle.waveAmplitude = amp;
			shit.shader = neoWiggle.shader;
			if(PlayState.instance != null) PlayState.instance.wiggleMap.set(tag, neoWiggle);
			return true;
		});
		Lua_helper.add_callback(lua, "removeWiggleEffect", function(tag:String) {
			if(PlayState.instance == null) return false;
			var shit:FlxSprite = resolveSpriteByTag(tag);
			if(shit != null) shit.shader = null;
			return PlayState.instance.wiggleMap.remove(tag);
		});
		Lua_helper.add_callback(lua, "removeSpriteShader", function(obj:String) {
			var killMe:Array<String> = obj.split('.');
			var leObj:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				leObj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(leObj != null) {
				leObj.shader = null;
				return true;
			}
			return false;
		});


		Lua_helper.add_callback(lua, "getShaderBool", function(obj:String, prop:String) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if (shader == null)
			{
				Lua.pushnil(lua);
				return null;
			}
			return shader.getBool(prop);
			#else
			luaTrace("getShaderBool: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
			#end
		});
		Lua_helper.add_callback(lua, "getShaderBoolArray", function(obj:String, prop:String) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if (shader == null)
			{
				Lua.pushnil(lua);
				return null;
			}
			return shader.getBoolArray(prop);
			#else
			luaTrace("getShaderBoolArray: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
			#end
		});
		Lua_helper.add_callback(lua, "getShaderInt", function(obj:String, prop:String) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if (shader == null)
			{
				Lua.pushnil(lua);
				return null;
			}
			return shader.getInt(prop);
			#else
			luaTrace("getShaderInt: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
			#end
		});
		Lua_helper.add_callback(lua, "getShaderIntArray", function(obj:String, prop:String) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if (shader == null)
			{
				Lua.pushnil(lua);
				return null;
			}
			return shader.getIntArray(prop);
			#else
			luaTrace("getShaderIntArray: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
			#end
		});
		Lua_helper.add_callback(lua, "getShaderFloat", function(obj:String, prop:String) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if (shader == null)
			{
				Lua.pushnil(lua);
				return null;
			}
			return shader.getFloat(prop);
			#else
			luaTrace("getShaderFloat: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
			#end
		});
		Lua_helper.add_callback(lua, "getShaderFloatArray", function(obj:String, prop:String) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if (shader == null)
			{
				Lua.pushnil(lua);
				return null;
			}
			return shader.getFloatArray(prop);
			#else
			luaTrace("getShaderFloatArray: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
			#end
		});


		Lua_helper.add_callback(lua, "setShaderBool", function(obj:String, prop:String, value:Bool) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if(shader == null) return;

			shader.setBool(prop, value);
			#else
			luaTrace("setShaderBool: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
		});
		Lua_helper.add_callback(lua, "setShaderBoolArray", function(obj:String, prop:String, values:Dynamic) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if(shader == null) return;

			shader.setBoolArray(prop, values);
			#else
			luaTrace("setShaderBoolArray: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
		});
		Lua_helper.add_callback(lua, "setShaderInt", function(obj:String, prop:String, value:Int) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if(shader == null) return;

			shader.setInt(prop, value);
			#else
			luaTrace("setShaderInt: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
		});
		Lua_helper.add_callback(lua, "setShaderIntArray", function(obj:String, prop:String, values:Dynamic) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if(shader == null) return;

			shader.setIntArray(prop, values);
			#else
			luaTrace("setShaderIntArray: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
		});
		Lua_helper.add_callback(lua, "setShaderFloat", function(obj:String, prop:String, value:Float) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if(shader == null) return;

			shader.setFloat(prop, value);
			#else
			luaTrace("setShaderFloat: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
		});
		Lua_helper.add_callback(lua, "setShaderFloatArray", function(obj:String, prop:String, values:Dynamic) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if(shader == null) return;

			shader.setFloatArray(prop, values);
			#else
			luaTrace("setShaderFloatArray: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
		});

		Lua_helper.add_callback(lua, "setShaderSampler2D", function(obj:String, prop:String, bitmapdataPath:String) {
			#if (!flash && MODS_ALLOWED && sys)
			var shader:FlxRuntimeShader = getShader(obj);
			if(shader == null) return;

			// trace('bitmapdatapath: $bitmapdataPath');
			var value = Paths.image(bitmapdataPath);
			if(value != null && value.bitmap != null)
			{
				// trace('Found bitmapdata. Width: ${value.bitmap.width} Height: ${value.bitmap.height}');
				shader.setSampler2D(prop, value.bitmap);
			}
			#else
			luaTrace("setShaderSampler2D: Platform unsupported for Runtime Shaders!", false, false, FlxColor.RED);
			#end
		});


		//
		Lua_helper.add_callback(lua, "getRunningScripts", function(){
			var luaArr = getStateLuaArray();
			if (luaArr == null) return [];
			var runningScripts:Array<String> = [];
			for (idx in 0...luaArr.length)
				runningScripts.push(luaArr[idx].scriptName);
			return runningScripts;
		});

		// ============ 多k API ============
		Lua_helper.add_callback(lua, "getMania", function():Int {
			if (PlayState.instance == null) return -1;
			return PlayState.mania + 1;
		});

		Lua_helper.add_callback(lua, "setNoteTexture", function(noteIndex:Int, texture:String):Bool {
			if (PlayState.instance == null || texture == null) return false;
			var notes:FlxTypedGroup<Note> = PlayState.instance.notes;
			if (noteIndex < 0 || noteIndex >= notes.length) return false;
			var note:Note = notes.members[noteIndex];
			if (note == null || !note.exists || note.noteData < 0) return false;
			// 自定义纹理不应用多k 调色 (默认/空纹理恢复轨道色)
			note.applyLaneColorShader = (texture.length < 1 || texture == 'NOTE_assets');
			note.texture = texture;
			note.reloadNote('', texture);
			if (note.applyLaneColorShader) note.applyLaneColor();
			return true;
		});

		Lua_helper.add_callback(lua, "setNoteCharAnim", function(noteIndex:Int, anim:String):Bool {
			if (PlayState.instance == null) return false;
			var notes:FlxTypedGroup<Note> = PlayState.instance.notes;
			if (noteIndex < 0 || noteIndex >= notes.length) return false;
			var note:Note = notes.members[noteIndex];
			if (note == null || !note.exists) return false;
			note.customCharAnim = (anim == null || anim.length < 1) ? null : anim;
			return true;
		});

		Lua_helper.add_callback(lua, "setNoteColor", function(noteIndex:Int, hue:Float, sat:Float, brt:Float):Bool {
			if (PlayState.instance == null) return false;
			var notes:FlxTypedGroup<Note> = PlayState.instance.notes;
			if (noteIndex < 0 || noteIndex >= notes.length) return false;
			var note:Note = notes.members[noteIndex];
			if (note == null || !note.exists || note.colorSwap == null) return false;
			note.noteColorOverride = [hue / 360, sat / 100, brt / 100];
			note.applyLaneColor();
			return true;
		});

		Lua_helper.add_callback(lua, "setMania", function(k:Int, skipTween:Dynamic = false, ?animStyle:Dynamic = null):Bool {
			if (PlayState.instance == null || k < 1) return false;
			var skip:Bool = (skipTween == true);
			var style:String = (animStyle != null) ? Std.string(animStyle) : null;
			PlayState.instance.changeMania(k - 1, skip, style);
			return true;
		});

		// 兼容命名: changeMania 与 setMania 相同
		Lua_helper.add_callback(lua, "changeMania", function(k:Int, skipTween:Dynamic = false, ?animStyle:Dynamic = null):Bool {
			if (PlayState.instance == null || k < 1) return false;
			var skip:Bool = (skipTween == true);
			var style:String = (animStyle != null) ? Std.string(animStyle) : null;
			PlayState.instance.changeMania(k - 1, skip, style);
			return true;
		});
		// ============ 多k API 结束 ============

		Lua_helper.add_callback(lua, "callOnScripts", function(?funcName:String, ?args:Array<Dynamic>, ignoreStops=false, ignoreSelf=true, ?exclusions:Array<String>){
			if(funcName==null){
				#if (linc_luajit >= "0.0.6")
				LuaL.error(lua, "bad argument #1 to 'callOnScripts' (string expected, got nil)");
				#end
				return;
			}
			if(args==null)args = [];

			if(exclusions==null)exclusions=[];

			Lua.getglobal(lua, 'scriptName');
			var daScriptName = Lua.tostring(lua, -1);
			Lua.pop(lua, 1);
			if(ignoreSelf && !exclusions.contains(daScriptName))exclusions.push(daScriptName);
			callOnStateScripts(funcName, args, ignoreStops, exclusions);
		});

		Lua_helper.add_callback(lua, "callScript", function(?luaFile:String, ?funcName:String, ?args:Array<Dynamic>){
			if (PlayState.instance == null) return;
			if(luaFile==null){
				#if (linc_luajit >= "0.0.6")
				LuaL.error(lua, "bad argument #1 to 'callScript' (string expected, got nil)");
				#end
				return;
			}
			if(funcName==null){
				#if (linc_luajit >= "0.0.6")
				LuaL.error(lua, "bad argument #2 to 'callScript' (string expected, got nil)");
				#end
				return;
			}
			if(args==null){
				args = [];
			}
			var cervix = luaFile + ".lua";
			if(luaFile.endsWith(".lua"))cervix=luaFile;
			var doPush = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(cervix)))
			{
				cervix = Paths.modFolders(cervix);
				doPush = true;
			}
			else if(FileSystem.exists(cervix))
			{
				doPush = true;
			}
			else {
				cervix = Paths.getPreloadPath(cervix);
				if(FileSystem.exists(cervix)) {
					doPush = true;
				}
			}
			#else
			cervix = Paths.getPreloadPath(cervix);
			if(Assets.exists(cervix)) {
				doPush = true;
			}
			#end
			if(doPush)
			{
				for (luaInstance in PlayState.instance.luaArray)
				{
					if(luaInstance.scriptName == cervix)
					{
						luaInstance.call(funcName, args);

						return;
					}

				}
			}
			Lua.pushnil(lua);

		});

		Lua_helper.add_callback(lua, "getGlobalFromScript", function(?luaFile:String, ?global:String){ // returns the global from a script
			if(luaFile==null){
				#if (linc_luajit >= "0.0.6")
				LuaL.error(lua, "bad argument #1 to 'getGlobalFromScript' (string expected, got nil)");
				#end
				return;
			}
			if(global==null){
				#if (linc_luajit >= "0.0.6")
				LuaL.error(lua, "bad argument #2 to 'getGlobalFromScript' (string expected, got nil)");
				#end
				return;
			}
			var cervix = luaFile + ".lua";
			if(luaFile.endsWith(".lua"))cervix=luaFile;
			var doPush = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(cervix)))
			{
				cervix = Paths.modFolders(cervix);
				doPush = true;
			}
			else if(FileSystem.exists(cervix))
			{
				doPush = true;
			}
			else {
				cervix = Paths.getPreloadPath(cervix);
				if(FileSystem.exists(cervix)) {
					doPush = true;
				}
			}
			#else
			cervix = Paths.getPreloadPath(cervix);
			if(Assets.exists(cervix)) {
				doPush = true;
			}
			#end
			if(doPush)
			{
				for (luaInstance in PlayState.instance.luaArray)
				{
					if(luaInstance.scriptName == cervix)
					{
						Lua.getglobal(luaInstance.lua, global);
						if(Lua.isnumber(luaInstance.lua,-1)){
							Lua.pushnumber(lua, Lua.tonumber(luaInstance.lua, -1));
						}else if(Lua.isstring(luaInstance.lua,-1)){
							Lua.pushstring(lua, Lua.tostring(luaInstance.lua, -1));
						}else if(Lua.isboolean(luaInstance.lua,-1)){
							Lua.pushboolean(lua, Lua.toboolean(luaInstance.lua, -1));
						}else{
							Lua.pushnil(lua);
						}
						// TODO: table

						Lua.pop(luaInstance.lua,1); // remove the global

						return;
					}

				}
			}
			Lua.pushnil(lua);
		});
		Lua_helper.add_callback(lua, "setGlobalFromScript", function(luaFile:String, global:String, val:Dynamic){ // returns the global from a script
			var cervix = luaFile + ".lua";
			if(luaFile.endsWith(".lua"))cervix=luaFile;
			var doPush = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(cervix)))
			{
				cervix = Paths.modFolders(cervix);
				doPush = true;
			}
			else if(FileSystem.exists(cervix))
			{
				doPush = true;
			}
			else {
				cervix = Paths.getPreloadPath(cervix);
				if(FileSystem.exists(cervix)) {
					doPush = true;
				}
			}
			#else
			cervix = Paths.getPreloadPath(cervix);
			if(Assets.exists(cervix)) {
				doPush = true;
			}
			#end
			if(doPush)
			{
				for (luaInstance in PlayState.instance.luaArray)
				{
					if(luaInstance.scriptName == cervix)
					{
						luaInstance.set(global, val);
					}

				}
			}
			Lua.pushnil(lua);
		});
		/*Lua_helper.add_callback(lua, "getGlobals", function(luaFile:String){ // returns a copy of the specified file's globals
			var cervix = luaFile + ".lua";
			if(luaFile.endsWith(".lua"))cervix=luaFile;
			var doPush = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(cervix)))
			{
				cervix = Paths.modFolders(cervix);
				doPush = true;
			}
			else if(FileSystem.exists(cervix))
			{
				doPush = true;
			}
			else {
				cervix = Paths.getPreloadPath(cervix);
				if(FileSystem.exists(cervix)) {
					doPush = true;
				}
			}
			#else
			cervix = Paths.getPreloadPath(cervix);
			if(Assets.exists(cervix)) {
				doPush = true;
			}
			#end
			if(doPush)
			{
				for (luaInstance in PlayState.instance.luaArray)
				{
					if(luaInstance.scriptName == cervix)
					{
						Lua.newtable(lua);
						var tableIdx = Lua.gettop(lua);

						Lua.pushvalue(luaInstance.lua, Lua.LUA_GLOBALSINDEX);
						Lua.pushnil(luaInstance.lua);
						while(Lua.next(luaInstance.lua, -2) != 0) {
							// key = -2
							// value = -1

							var pop:Int = 0;

							// Manual conversion
							// first we convert the key
							if(Lua.isnumber(luaInstance.lua,-2)){
								Lua.pushnumber(lua, Lua.tonumber(luaInstance.lua, -2));
								pop++;
							}else if(Lua.isstring(luaInstance.lua,-2)){
								Lua.pushstring(lua, Lua.tostring(luaInstance.lua, -2));
								pop++;
							}else if(Lua.isboolean(luaInstance.lua,-2)){
								Lua.pushboolean(lua, Lua.toboolean(luaInstance.lua, -2));
								pop++;
							}
							// TODO: table


							// then the value
							if(Lua.isnumber(luaInstance.lua,-1)){
								Lua.pushnumber(lua, Lua.tonumber(luaInstance.lua, -1));
								pop++;
							}else if(Lua.isstring(luaInstance.lua,-1)){
								Lua.pushstring(lua, Lua.tostring(luaInstance.lua, -1));
								pop++;
							}else if(Lua.isboolean(luaInstance.lua,-1)){
								Lua.pushboolean(lua, Lua.toboolean(luaInstance.lua, -1));
								pop++;
							}
							// TODO: table

							if(pop==2)Lua.rawset(lua, tableIdx); // then set it
							Lua.pop(luaInstance.lua, 1); // for the loop
						}
						Lua.pop(luaInstance.lua,1); // end the loop entirely
						Lua.pushvalue(lua, tableIdx); // push the table onto the stack so it gets returned

						return;
					}

				}
			}
			Lua.pushnil(lua);
		});*/
		Lua_helper.add_callback(lua, "isRunning", function(luaFile:String){
			var cervix = luaFile + ".lua";
			if(luaFile.endsWith(".lua"))cervix=luaFile;
			var doPush = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(cervix)))
			{
				cervix = Paths.modFolders(cervix);
				doPush = true;
			}
			else if(FileSystem.exists(cervix))
			{
				doPush = true;
			}
			else {
				cervix = Paths.getPreloadPath(cervix);
				if(FileSystem.exists(cervix)) {
					doPush = true;
				}
			}
			#else
			cervix = Paths.getPreloadPath(cervix);
			if(Assets.exists(cervix)) {
				doPush = true;
			}
			#end

			if(doPush)
			{
				for (luaInstance in PlayState.instance.luaArray)
				{
					if(luaInstance.scriptName == cervix)
						return true;

				}
			}
			return false;
		});


		Lua_helper.add_callback(lua, "addLuaScript", function(luaFile:String, ?ignoreAlreadyRunning:Bool = false) { //would be dope asf.
			var cervix = luaFile + ".lua";
			if(luaFile.endsWith(".lua"))cervix=luaFile;
			var doPush = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(cervix)))
			{
				cervix = Paths.modFolders(cervix);
				doPush = true;
			}
			else if(FileSystem.exists(cervix))
			{
				doPush = true;
			}
			else {
				cervix = Paths.getPreloadPath(cervix);
				if(FileSystem.exists(cervix)) {
					doPush = true;
				}
			}
			#else
			cervix = Paths.getPreloadPath(cervix);
			if(Assets.exists(cervix)) {
				doPush = true;
			}
			#end

			if(doPush)
			{
				var luaArr = getStateLuaArray();
				if(luaArr != null)
				{
					if(!ignoreAlreadyRunning)
					{
						for (luaInstance in luaArr)
						{
							if(luaInstance.scriptName == cervix)
							{
								luaTrace('addLuaScript: The script "' + cervix + '" is already running!');
								return;
							}
						}
					}
					addLuaToState(new FunkinLua(cervix));
				}
				return;
			}
			luaTrace("addLuaScript: Script doesn't exist!", false, false, FlxColor.RED);
		});
		Lua_helper.add_callback(lua, "removeLuaScript", function(luaFile:String, ?ignoreAlreadyRunning:Bool = false) { //would be dope asf.
			var cervix = luaFile + ".lua";
			if(luaFile.endsWith(".lua"))cervix=luaFile;
			var doPush = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(cervix)))
			{
				cervix = Paths.modFolders(cervix);
				doPush = true;
			}
			else if(FileSystem.exists(cervix))
			{
				doPush = true;
			}
			else {
				cervix = Paths.getPreloadPath(cervix);
				if(FileSystem.exists(cervix)) {
					doPush = true;
				}
			}
			#else
			cervix = Paths.getPreloadPath(cervix);
			if(Assets.exists(cervix)) {
				doPush = true;
			}
			#end

			if(doPush)
			{
				var luaArr = getStateLuaArray();
				if(luaArr != null)
				{
					if(!ignoreAlreadyRunning)
					{
						for (luaInstance in luaArr)
						{
							if(luaInstance.scriptName == cervix)
							{
								luaArr.remove(luaInstance);
								return;
							}
						}
					}
				}
				return;
			}
			luaTrace("removeLuaScript: Script doesn't exist!", false, false, FlxColor.RED);
		});

		// 0.7.3+/1.0.4: addHScript / removeHScript
		Lua_helper.add_callback(lua, "addHScript", function(scriptFile:String, ?ignoreAlreadyRunning:Bool = false) {
			#if HSCRIPT_ALLOWED
			var scriptPath:String = scriptFile + ".hx";
			if(scriptFile.endsWith(".hx")) scriptPath = scriptFile;
			var doPush:Bool = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(scriptPath)))
			{
				scriptPath = Paths.modFolders(scriptPath);
				doPush = true;
			}
			else if(FileSystem.exists(scriptPath))
			{
				doPush = true;
			}
			else {
				scriptPath = Paths.getPreloadPath(scriptPath);
				if(FileSystem.exists(scriptPath)) doPush = true;
			}
			#else
			scriptPath = Paths.getPreloadPath(scriptPath);
			if(Assets.exists(scriptPath)) doPush = true;
			#end

			if(doPush && PlayState.instance != null)
			{
				if(!ignoreAlreadyRunning)
				{
					for (script in PlayState.instance.hscriptArray)
					{
						if(script != null && script.scriptName == scriptPath)
						{
							luaTrace('addHScript: The script "' + scriptPath + '" is already running!');
							return;
						}
					}
				}
				PlayState.instance.initHScript(scriptPath);
				return;
			}
			luaTrace("addHScript: Script doesn't exist!", false, false, FlxColor.RED);
			#else
			luaTrace("addHScript: HScript is not supported on this platform!", false, false, FlxColor.RED);
			#end
		});
		Lua_helper.add_callback(lua, "removeHScript", function(scriptFile:String) {
			#if HSCRIPT_ALLOWED
			var scriptPath:String = scriptFile + ".hx";
			if(scriptFile.endsWith(".hx")) scriptPath = scriptFile;
			var doPush:Bool = false;
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(scriptPath)))
			{
				scriptPath = Paths.modFolders(scriptPath);
				doPush = true;
			}
			else if(FileSystem.exists(scriptPath))
			{
				doPush = true;
			}
			else {
				scriptPath = Paths.getPreloadPath(scriptPath);
				if(FileSystem.exists(scriptPath)) doPush = true;
			}
			#else
			scriptPath = Paths.getPreloadPath(scriptPath);
			if(Assets.exists(scriptPath)) doPush = true;
			#end

			if(doPush && PlayState.instance != null)
			{
				var foundAny:Bool = false;
				for (script in PlayState.instance.hscriptArray)
				{
					if(script != null && script.scriptName == scriptPath)
					{
						script.stop();
						foundAny = true;
					}
				}
				if(foundAny) return true;
			}

			luaTrace('removeHScript: Script ' + scriptFile + ' isn\'t running!', false, false, FlxColor.RED);
			return false;
			#else
			luaTrace("removeHScript: HScript is not supported on this platform!", false, false, FlxColor.RED);
			return false;
			#end
		});

		Lua_helper.add_callback(lua, "runHaxeCode", function(codeToRun:String) {
			var retVal:Dynamic = null;

			#if HSCRIPT_ALLOWED
			initHaxeModule();
			try {
				retVal = hscript.execute(codeToRun);
			}
			catch (e:Dynamic) {
				luaTrace(scriptName + ":" + lastCalledFunction + " - " + e, false, false, FlxColor.RED);
			}
			#else
			luaTrace("runHaxeCode: HScript isn't supported on this platform!", false, false, FlxColor.RED);
			#end

			// 返回值支持 Map/表（此前只有 Bool/Int/Float/String/Array）。
			// English: return values now also support Map/table (previously only Bool/Int/Float/String/Array).
			if(retVal != null && !isOfTypes(retVal, [Bool, Int, Float, String, Array]) && !isMap(retVal)) retVal = null;
			if(retVal == null) Lua.pushnil(lua);
			return retVal;
		});

		// 0.7.3+/1.0.4: runHaxeFunction — call a function defined by a previous runHaxeCode
		Lua_helper.add_callback(lua, "runHaxeFunction", function(funcToRun:String, ?funcArgs:Array<Dynamic> = null) {
			var retVal:Dynamic = null;

			#if HSCRIPT_ALLOWED
			initHaxeModule();
			try {
				retVal = hscript.call(funcToRun, funcArgs);
			}
			catch (e:Dynamic) {
				luaTrace(scriptName + ":" + lastCalledFunction + " - " + e, false, false, FlxColor.RED);
			}

			if(retVal != null && !isOfTypes(retVal, [Bool, Int, Float, String, Array]) && !isMap(retVal)) retVal = null;
			if(retVal == null) Lua.pushnil(lua);
			return retVal;
			#else
			luaTrace("runHaxeFunction: HScript isn't supported on this platform!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
			#end
		});

		// 写入共享 hscript 环境变量。English: write a variable into the shared hscript environment.
		Lua_helper.add_callback(lua, "setHaxeVar", function(varName:String, value:Dynamic) {
			#if HSCRIPT_ALLOWED
			initHaxeModule();
			try {
				hscript.set(varName, value);
			}
			catch (e:Dynamic) {
				luaTrace(scriptName + ":" + lastCalledFunction + " - " + e, false, false, FlxColor.RED);
			}
			#end
		});

		// 读取共享 hscript 环境变量。English: read a variable from the shared hscript environment.
		Lua_helper.add_callback(lua, "getHaxeVar", function(varName:String):Dynamic {
			#if HSCRIPT_ALLOWED
			initHaxeModule();
			try {
				return hscript.get(varName);
			}
			catch (e:Dynamic) {
				luaTrace(scriptName + ":" + lastCalledFunction + " - " + e, false, false, FlxColor.RED);
			}
			#end
			return null;
		});

		Lua_helper.add_callback(lua, "addHaxeLibrary", function(libName:String, ?libPackage:String = '') {
			#if HSCRIPT_ALLOWED
			initHaxeModule();
			try {
				var str:String = '';
				if(libPackage.length > 0)
					str = libPackage + '.';

				var resolvedClass:Dynamic = Type.resolveClass(str + libName);
				if(resolvedClass != null) {
					hscript.variables.set(libName, resolvedClass);
				}
			}
			catch (e:Dynamic) {
				luaTrace(scriptName + ":" + lastCalledFunction + " - " + e, false, false, FlxColor.RED);
			}
			#end
		});

		Lua_helper.add_callback(lua, "loadSong", function(?name:String = null, ?difficultyNum:Int = -1) {
			if(name == null || name.length < 1)
				name = PlayState.SONG.song;
			if (difficultyNum == -1)
				difficultyNum = PlayState.storyDifficulty;

			var poop = Highscore.formatSong(name, difficultyNum);
			PlayState.SONG = Song.loadFromJson(poop, name);
			PlayState.storyDifficulty = difficultyNum;
			PlayState.instance.persistentUpdate = false;
			LoadingState.loadAndSwitchState(new PlayState());

			FlxG.sound.music.pause();
			FlxG.sound.music.volume = 0;
			if(PlayState.instance.vocals != null)
			{
				PlayState.instance.vocals.pause();
				PlayState.instance.vocals.volume = 0;
			}
		});
		Lua_helper.add_callback(lua, "loadLanguage", function(?lang:String){
			Language.load(lang);
		});
		
		Lua_helper.add_callback(lua, "getLanguage", function(key:String, ?defaultText:String){
			if (defaultText != null)
			return Language.get(key, defaultText);
			else
			return Language.get(key);
		});
			

		Lua_helper.add_callback(lua, "loadGraphic", function(variable:String, image:String, ?gridX:Int = 0, ?gridY:Int = 0) {
			var killMe:Array<String> = variable.split('.');
			var spr:FlxSprite = getObjectDirectly(killMe[0]);
			var animated = gridX != 0 || gridY != 0;

			if(killMe.length > 1) {
				spr = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(spr != null && image != null && image.length > 0)
			{
				spr.loadGraphic(Paths.image(image), animated, gridX, gridY);
			}
		});
		Lua_helper.add_callback(lua, "loadFrames", function(variable:String, image:String, spriteType:String = "sparrow") {
			var killMe:Array<String> = variable.split('.');
			var spr:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				spr = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(spr != null && image != null && image.length > 0)
			{
				loadFrames(spr, image, spriteType);
			}
		});

		// 1.0.4: loadMultipleFrames — 多图集拼接
		// 1.0.4-only: loadMultipleFrames — merge multiple sparrow atlases into one
		Lua_helper.add_callback(lua, "loadMultipleFrames", function(variable:String, images:Array<String>) {
			var killMe:Array<String> = variable.split('.');
			var spr:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				spr = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(spr != null && images != null && images.length > 0)
			{
				spr.frames = Paths.getMultiAtlas(images);
			}
		});

		// 0.7.3+/1.0.4: FlxAnimate 精灵（需要 flxanimate 库）
		// FlxAnimate sprites (0.7.3+) — requires the flxanimate library
		#if (LUA_ALLOWED && flxanimate)
		Lua_helper.add_callback(lua, "makeFlxAnimateSprite", function(tag:String, ?x:Float = 0, ?y:Float = 0, ?loadFolder:String = null) {
			tag = tag.replace('.', '');
			var stateVars = getStateVars();
			if(stateVars == null) return;

			var lastSprite:Dynamic = stateVars.get(tag);
			if(lastSprite != null)
			{
				lastSprite.kill();
				if(getInstance() != null) getInstance().remove(lastSprite);
				lastSprite.destroy();
			}

			var mySprite:ModchartAnimateSprite = new ModchartAnimateSprite(x, y);
			if(loadFolder != null) Paths.loadAnimateAtlas(mySprite, loadFolder);
			stateVars.set(tag, mySprite);
			mySprite.active = true;
		});

		Lua_helper.add_callback(lua, "loadAnimateAtlas", function(tag:String, folderOrImg:String, ?spriteJson:String = null, ?animationJson:String = null) {
			var stateVars = getStateVars();
			if(stateVars == null) return;
			var spr:flxanimate.PsychFlxAnimate = cast stateVars.get(tag);
			if(spr != null) Paths.loadAnimateAtlas(spr, folderOrImg, spriteJson, animationJson);
		});

		Lua_helper.add_callback(lua, "addAnimationBySymbol", function(tag:String, name:String, symbol:String, ?framerate:Float = 24, ?loop:Bool = false, ?matX:Float = 0, ?matY:Float = 0) {
			var stateVars = getStateVars();
			if(stateVars == null) return false;
			var obj:FlxAnimate = cast stateVars.get(tag);
			if(obj == null) return false;

			obj.anim.addBySymbol(name, symbol, framerate, loop, matX, matY);
			if(obj.anim.curSymbol == null)
			{
				var obj2:ModchartAnimateSprite = cast (obj, ModchartAnimateSprite);
				if(obj2 != null) obj2.playAnim(name, true);
				else obj.anim.play(name, true);
			}
			return true;
		});

		Lua_helper.add_callback(lua, "addAnimationBySymbolIndices", function(tag:String, name:String, symbol:String, ?indices:Any = null, ?framerate:Float = 24, ?loop:Bool = false, ?matX:Float = 0, ?matY:Float = 0) {
			var stateVars = getStateVars();
			if(stateVars == null) return false;
			var obj:FlxAnimate = cast stateVars.get(tag);
			if(obj == null) return false;

			if(indices == null)
				indices = [0];
			else if(Std.isOfType(indices, String))
			{
				var strIndices:Array<String> = cast (indices, String).trim().split(',');
				var myIndices:Array<Int> = [];
				for (i in 0...strIndices.length) myIndices.push(Std.parseInt(strIndices[i]));
				indices = myIndices;
			}

			obj.anim.addBySymbolIndices(name, symbol, indices, framerate, loop, matX, matY);
			if(obj.anim.curSymbol == null)
			{
				var obj2:ModchartAnimateSprite = cast (obj, ModchartAnimateSprite);
				if(obj2 != null) obj2.playAnim(name, true);
				else obj.anim.play(name, true);
			}
			return true;
		});
		#end


		Lua_helper.add_callback(lua, "getProperty", function(variable:String, ?allowMaps:Bool = false) {
			if (CompatEngine.compatMode()) {
				if (replaceMap.exists(variable)) {
					variable = replaceMap.get(variable);
				}
			}
			var split:Array<String> = variable.split('.');

			var result:Dynamic = null;
			if(split.length > 1)
				result = getVarInArray(getPropertyLoop(split, true, true, allowMaps), split[split.length-1], allowMaps);
			else
				result = getVarInArray(getTargetInstance(), variable, allowMaps);

			// 1.0.4 兼容：Bar/FlxBar 的 scale 在某些路径下读成 null，Lua 里 `<0` 会直接崩。
			// 这里对 healthBar.scale.x/y 给一个安全默认值 1，和 104 行为一致。
			if(result == null && (variable == 'healthBar.scale.x' || variable == 'healthBar.scale.y'))
				result = 1;

			// 0.6.3/0.7.3 旧加载顺序下，全局脚本可能在角色/谱面创建前访问
			// dad/boyfriend/notes/strums 等对象。此时返回安全默认值而不是 nil，
			// 避免脚本顶层 string.format / 算术直接报错，保证脚本能正常加载。
			// 1.0.4 模式保持原有 nil 语义，避免影响已正常的 104 脚本。
			if(result == null && !CompatEngine.is104() && split.length > 0)
			{
				var lastProp:String = split[split.length - 1];
				if(lastProp == 'name' || lastProp == 'curCharacter' || lastProp == 'text' || lastProp.indexOf('Name') != -1)
					result = '';
				else
					result = 0;
			}
			return result;
		});
		Lua_helper.add_callback(lua, "setProperty", function(variable:String, value:Dynamic, allowMaps:Bool = false) {
			if (CompatEngine.compatMode()) {
				if (extraMap.exists(variable)) {
					for (item in extraMap.get(variable)) {
						var extraVal = (item.val != null) ? item.val : value;
						var splitExtra = item.target.split('.');
						if (splitExtra.length > 1) {
							setVarInArray(getPropertyLoop(splitExtra, true, true, allowMaps), splitExtra[splitExtra.length-1], extraVal, allowMaps);
						} else {
							setVarInArray(getTargetInstance(), item.target, extraVal, allowMaps);
						}
					}
				}

				if (replaceMap.exists(variable)) {
					variable = replaceMap.get(variable);
				}
			}

			var split:Array<String> = variable.split('.');
			if (split.length > 1) {
				setVarInArray(getPropertyLoop(split, true, true, allowMaps), split[split.length-1], value, allowMaps);
				return true;
			}
			setVarInArray(getTargetInstance(), variable, value, allowMaps);
			return true;
		});
		/*}else{
		Lua_helper.add_callback(lua, "getProperty", function(variable:String, ?allowMaps:Bool = false) {
			var split:Array<String> = variable.split('.');
			if(split.length > 1)
				return new_setVarInArray(getPropertyLoop(split, true, true, allowMaps), split[split.length-1], allowMaps);
			return new_setVarInArray(getTargetInstance(), variable, allowMaps);
		});
		Lua_helper.add_callback(lua, "setProperty", function(variable:String, value:Dynamic, allowMaps:Bool = false) {
			var split:Array<String> = variable.split('.');
			if(split.length > 1) {
				new_setVarInArray(getPropertyLoop(split, true, true, allowMaps), split[split.length-1], value, allowMaps);
				return true;
			}
			new_setVarInArray(getTargetInstance(), variable, value, allowMaps);
			return true;
			});
		}*/
		Lua_helper.add_callback(lua, "getPropertyFromGroup", function(obj:String, index:Int, variable:Dynamic):Dynamic {
			var shitMyPants:Array<String> = obj.split('.');
			var realObject:Dynamic = Reflect.getProperty(getInstance(), obj);
			if(shitMyPants.length>1)
				realObject = getPropertyLoopThingWhatever(shitMyPants, true, false);

			// 1.0.4 保持原行为，不改变 nil 语义
			if (CompatEngine.is104())
			{
				if(Std.isOfType(realObject, FlxTypedGroup))
				{
					var result104:Dynamic = getGroupStuff(realObject.members[index], variable);
					if(result104 == null) Lua.pushnil(lua);
					return result104;
				}

				var leArray104:Dynamic = realObject[index];
				if(leArray104 != null) {
					var result104:Dynamic = null;
					if(Type.typeof(variable) == ValueType.TInt)
						result104 = leArray104[variable];
					else
						result104 = getGroupStuff(leArray104, variable);

					if(result104 == null) Lua.pushnil(lua);
					return result104;
				}
				luaTrace("getPropertyFromGroup: Object #" + index + " from group: " + obj + " doesn't exist!", false, false, FlxColor.RED);
				Lua.pushnil(lua);
				return null;
			}

			// 0.6.3/0.7.3 旧加载顺序下组可能还没创建，返回安全默认值避免脚本顶层崩溃。
			if(realObject == null) return 0;

			if(Std.isOfType(realObject, FlxTypedGroup))
			{
				if(realObject.members == null || index < 0 || index >= realObject.members.length)
					return 0;
				var result:Dynamic = getGroupStuff(realObject.members[index], variable);
				if(result == null) return 0;
				return result;
			}

			var leArray:Dynamic = realObject[index];
			if(leArray != null) {
				var result:Dynamic = null;
				if(Type.typeof(variable) == ValueType.TInt)
					result = leArray[variable];
				else
					result = getGroupStuff(leArray, variable);

				if(result == null) return 0;
				return result;
			}
			luaTrace("getPropertyFromGroup: Object #" + index + " from group: " + obj + " doesn't exist!", false, false, FlxColor.RED);
			return 0;
		});
		Lua_helper.add_callback(lua, "setPropertyFromGroup", function(obj:String, index:Int, variable:Dynamic, value:Dynamic) {
			var shitMyPants:Array<String> = obj.split('.');
			var realObject:Dynamic = Reflect.getProperty(getInstance(), obj);
			if(shitMyPants.length>1)
				realObject = getPropertyLoopThingWhatever(shitMyPants, true, false);

			if(Std.isOfType(realObject, FlxTypedGroup)) {
				setGroupStuff(realObject.members[index], variable, value);
				return;
			}

			var leArray:Dynamic = realObject[index];
			if(leArray != null) {
				if(Type.typeof(variable) == ValueType.TInt) {
					leArray[variable] = value;
					return;
				}
				setGroupStuff(leArray, variable, value);
			}
		});
		Lua_helper.add_callback(lua, "removeFromGroup", function(obj:String, index:Int, dontDestroy:Bool = false) {
			if(Std.isOfType(Reflect.getProperty(getInstance(), obj), FlxTypedGroup)) {
				var sex = Reflect.getProperty(getInstance(), obj).members[index];
				if(!dontDestroy)
					sex.kill();
				Reflect.getProperty(getInstance(), obj).remove(sex, true);
				if(!dontDestroy)
					sex.destroy();
				return;
			}
			Reflect.getProperty(getInstance(), obj).remove(Reflect.getProperty(getInstance(), obj)[index]);
		});

		// 1.0.4: addToGroup（把已创建的 Lua 对象塞进任意 Group/Array）
		// 1.0.4-only: addToGroup — insert a created Lua object into any group/array
		Lua_helper.add_callback(lua, "addToGroup", function(group:String, tag:String, ?index:Int = -1) {
			var obj:Dynamic = getObjectDirectly(tag);
			if(obj == null || obj.destroy == null)
			{
				luaTrace('addToGroup: Object ' + tag + ' is not valid!', false, false, FlxColor.RED);
				return;
			}

			var groupOrArray:Dynamic = Reflect.getProperty(getInstance(), group);
			if(groupOrArray == null)
			{
				luaTrace('addToGroup: Group/Array ' + group + ' is not valid!', false, false, FlxColor.RED);
				return;
			}

			if(index < 0)
			{
				switch(Type.typeof(groupOrArray))
				{
					case TClass(Array): //Is Array
						groupOrArray.push(obj);
					default: //Is Group
						groupOrArray.add(obj);
				}
			}
			else groupOrArray.insert(index, obj);
		});

		Lua_helper.add_callback(lua, "callMethod", function(funcToRun:String, ?args:Array<Dynamic> = null) {
			return callMethodFromObject(PlayState.instance, funcToRun, parseInstances(args));
			
		});
		Lua_helper.add_callback(lua, "callMethodFromClass", function(className:String, funcToRun:String, ?args:Array<Dynamic> = null) {
			var resolvedClass:Dynamic = Type.resolveClass(className);
			if(resolvedClass == null && StringTools.startsWith(className, 'backend.'))
				resolvedClass = Type.resolveClass(className.substr(8));
			else if(resolvedClass == null && StringTools.startsWith(className, 'objects.'))
				resolvedClass = Type.resolveClass(className.substr(8));
			return callMethodFromObject(resolvedClass, funcToRun, parseInstances(args));
		});
		Lua_helper.add_callback(lua, "createInstance", function(variableToSave:String, className:String, ?args:Array<Dynamic> = null) {
			variableToSave = variableToSave.trim().replace('.', '');
			if(!PlayState.instance.variables.exists(variableToSave))
			{
				if(args == null) args = [];
				var resolvedName:String = className;
				if(className == 'objects.Character' || className == 'Character')
				{
					resolvedName = 'Character';
				}
				var myType:Dynamic = Type.resolveClass(resolvedName);
				if(myType == null)
				{
					luaTrace('createInstance: Class "' + className + '" not found!', false, false, FlxColor.RED);
					return false;
				}
				var obj:Dynamic = Type.createInstance(myType, args);
				if(obj != null)
					PlayState.instance.variables.set(variableToSave, obj);
				else
					luaTrace('createInstance: Failed to create "' + variableToSave + '", arguments are possibly wrong.', false, false, FlxColor.RED);
				return (obj != null);
			}
			luaTrace('createInstance: Variable "' + variableToSave + '" is already being used and cannot be replaced!', false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "addInstance", function(objectName:String, ?inFront:Bool = false) {
			if(PlayState.instance.variables.exists(objectName))
			{
				var obj:Dynamic = PlayState.instance.variables.get(objectName);
				if (inFront)
					getTargetInstance().add(obj);
				else
				{
					if(!PlayState.instance.isDead)
						PlayState.instance.insert(PlayState.instance.members.indexOf(getLowestCharacterGroup()), obj);
					else
						GameOverSubstate.instance.insert(GameOverSubstate.instance.members.indexOf(GameOverSubstate.instance.boyfriend), obj);
				}
			}
			else luaTrace('addInstance: Can\'t add what doesn\'t exist~ ($objectName)', false, false, FlxColor.RED);
		});

		Lua_helper.add_callback(lua, "instanceArg", function(instanceName:String, ?className:String = null) {
			var retStr:String ='$instanceStr::$instanceName';
			if(className != null) retStr += '::$className';
			return retStr;
		});



		Lua_helper.add_callback(lua, "getPropertyFromClass", function(classVar:String, variable:String, ?allowMaps:Bool = false) {
			if (classPathMap.exists(classVar)) {
				classVar = classPathMap[classVar];
			}
			var myClass:Dynamic = Type.resolveClass(classVar);
			if(myClass == null)
			{
				luaTrace('getPropertyFromClass: Class $classVar not found', false, false, FlxColor.RED);
				return null;
			}

			var split:Array<String> = variable.split('.');
			if(split.length > 1) {
				var obj:Dynamic = getVarInArray(myClass, split[0], allowMaps);
				for (i in 1...split.length-1)
					obj = getVarInArray(obj, split[i], allowMaps);

				return getVarInArray(obj, split[split.length-1], allowMaps);
			}
			return getVarInArray(myClass, variable, allowMaps);
		});
		Lua_helper.add_callback(lua, "setPropertyFromClass", function(classVar:String, variable:String, value:Dynamic, ?allowMaps:Bool = false) {
			if (classPathMap.exists(classVar)) {
				classVar = classPathMap[classVar];
			}
			var myClass:Dynamic = Type.resolveClass(classVar);
			if(myClass == null)
			{
				luaTrace('setPropertyFromClass: Class $classVar not found', false, false, FlxColor.RED);
				return null;
			}

			var split:Array<String> = variable.split('.');
			if(split.length > 1) {
				var obj:Dynamic = getVarInArray(myClass, split[0], allowMaps);
				for (i in 1...split.length-1)
					obj = getVarInArray(obj, split[i], allowMaps);

				setVarInArray(obj, split[split.length-1], value, allowMaps);
				return value;
			}
			setVarInArray(myClass, variable, value, allowMaps);
			return value;
		});

		//shitass stuff for epic coders like me B)  *image of obama giving himself a medal*
		Lua_helper.add_callback(lua, "getObjectOrder", function(obj:String) {
			var killMe:Array<String> = obj.split('.');
			var leObj:FlxBasic = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				leObj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(leObj != null)
			{
				return getInstance().members.indexOf(leObj);
			}
			luaTrace("getObjectOrder: Object " + obj + " doesn't exist!", false, false, FlxColor.RED);
			return -1;
		});
		Lua_helper.add_callback(lua, "setObjectOrder", function(obj:String, position:Int) {
			var killMe:Array<String> = obj.split('.');
			var leObj:FlxBasic = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				leObj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(leObj != null) {
				getInstance().remove(leObj, true);
				getInstance().insert(position, leObj);
				return;
			}
			luaTrace("setObjectOrder: Object " + obj + " doesn't exist!", false, false, FlxColor.RED);
		});

		// gay ass tweens
		Lua_helper.add_callback(lua, "doTweenX", function(tag:String, vars:String, value:Dynamic, duration:Float, ease:String) {
			var penisExam:Dynamic = tweenShit(tag, vars);
			if(penisExam != null) {
				var tweens = getStateModchartTweens();
				if(tweens != null) tweens.set(tag, FlxTween.tween(penisExam, {x: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						callOnStateLuas('onTweenCompleted', [tag]);
						if(tweens != null) tweens.remove(tag);
					}
				}));
			} else {
				luaTrace('doTweenX: Couldnt find object: ' + vars, false, false, FlxColor.RED);
			}
		});
		Lua_helper.add_callback(lua, "doTweenY", function(tag:String, vars:String, value:Dynamic, duration:Float, ease:String) {
			var penisExam:Dynamic = tweenShit(tag, vars);
			if(penisExam != null) {
				var tweens = getStateModchartTweens();
				if(tweens != null) tweens.set(tag, FlxTween.tween(penisExam, {y: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						callOnStateScripts('onTweenCompleted', [tag]);
						if(tweens != null) tweens.remove(tag);
					}
				}));
			} else {
				luaTrace('doTweenY: Couldnt find object: ' + vars, false, false, FlxColor.RED);
			}
		});
		Lua_helper.add_callback(lua, "doTweenAngle", function(tag:String, vars:String, value:Dynamic, duration:Float, ease:String) {
			var penisExam:Dynamic = tweenShit(tag, vars);
			if(penisExam != null) {
				var tweens = getStateModchartTweens();
				if(tweens != null) tweens.set(tag, FlxTween.tween(penisExam, {angle: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						callOnStateLuas('onTweenCompleted', [tag]);
						if(tweens != null) tweens.remove(tag);
					}
				}));
			} else {
				luaTrace('doTweenAngle: Couldnt find object: ' + vars, false, false, FlxColor.RED);
			}
		});
		Lua_helper.add_callback(lua, "doTweenAlpha", function(tag:String, vars:String, value:Dynamic, duration:Float, ease:String) {
			var penisExam:Dynamic = tweenShit(tag, vars);
			if(penisExam != null) {
				var tweens = getStateModchartTweens();
				if(tweens != null) tweens.set(tag, FlxTween.tween(penisExam, {alpha: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						callOnStateScripts('onTweenCompleted', [tag]);
						if(tweens != null) tweens.remove(tag);
					}
				}));
			} else {
				luaTrace('doTweenAlpha: Couldnt find object: ' + vars, false, false, FlxColor.RED);
			}
		});
		Lua_helper.add_callback(lua, "doTweenZoom", function(tag:String, vars:String, value:Dynamic, duration:Float, ease:String) {
			var penisExam:Dynamic = tweenShit(tag, vars);
			if(penisExam != null) {
				var tweens = getStateModchartTweens();
				if(tweens != null) tweens.set(tag, FlxTween.tween(penisExam, {zoom: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						callOnStateLuas('onTweenCompleted', [tag]);
						if(tweens != null) tweens.remove(tag);
					}
				}));
			} else {
				luaTrace('doTweenZoom: Couldnt find object: ' + vars, false, false, FlxColor.RED);
			}
		});
		Lua_helper.add_callback(lua, "doTweenColor", function(tag:String, vars:String, targetColor:String, duration:Float, ease:String) {
			var penisExam:Dynamic = tweenShit(tag, vars);
			if(penisExam != null) {
				var color:Int = Std.parseInt(targetColor);
				if(!targetColor.startsWith('0x')) color = Std.parseInt('0xff' + targetColor);

				var curColor:FlxColor = penisExam.color;
				curColor.alphaFloat = penisExam.alpha;
				var tweens = getStateModchartTweens();
				if(tweens != null) tweens.set(tag, FlxTween.color(penisExam, duration, curColor, color, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						if(tweens != null) tweens.remove(tag);
						callOnStateScripts('onTweenCompleted', [tag]);
					}
				}));
			} else {
				luaTrace('doTweenColor: Couldnt find object: ' + vars, false, false, FlxColor.RED);
			}
		});

		// 0.7.3+/1.0.4: startTween（带 options 表的高级 tween）
		// startTween (0.7.3+) — advanced tween with an options table
		Lua_helper.add_callback(lua, "startTween", function(tag:String, vars:String, values:Dynamic = null, duration:Float, ?options:Dynamic = null) {
			var penisExam:Dynamic = tweenShit(tag, vars);
			if(penisExam != null)
			{
				if(values != null)
				{
					var type:FlxTweenType = FlxTweenType.ONESHOT;
					var ease:EaseFunction = FlxEase.linear;
					var startDelay:Float = 0;
					var loopDelay:Float = 0;
					var onUpdate:String = null;
					var onStart:String = null;
					var onComplete:String = null;

					if(options != null)
					{
						type = getTweenTypeByString(Reflect.field(options, 'type'));
						ease = getFlxEaseByString(Reflect.field(options, 'ease'));
						if(Reflect.field(options, 'startDelay') != null) startDelay = Reflect.field(options, 'startDelay');
						if(Reflect.field(options, 'loopDelay') != null) loopDelay = Reflect.field(options, 'loopDelay');
						if(Reflect.field(options, 'onUpdate') != null) onUpdate = Reflect.field(options, 'onUpdate');
						if(Reflect.field(options, 'onStart') != null) onStart = Reflect.field(options, 'onStart');
						if(Reflect.field(options, 'onComplete') != null) onComplete = Reflect.field(options, 'onComplete');
					}

					var stateVars = getStateVars();
					var originalTag:String = 'tween_' + formatVariable(tag);
					var myTween:FlxTween = FlxTween.tween(penisExam, values, duration, {
						type: type,
						ease: ease,
						startDelay: startDelay,
						loopDelay: loopDelay,
						onUpdate: function(twn:FlxTween) {
							if(onUpdate != null) callOnStateLuas(onUpdate, [originalTag, vars]);
						},
						onStart: function(twn:FlxTween) {
							if(onStart != null) callOnStateLuas(onStart, [originalTag, vars]);
						},
						onComplete: function(twn:FlxTween) {
							if(twn.type == FlxTweenType.ONESHOT || twn.type == FlxTweenType.BACKWARD)
							{
								if(stateVars != null) stateVars.remove(tag);
							}
							if(onComplete != null) callOnStateLuas(onComplete, [originalTag, vars]);
						}
					});
					if(stateVars != null) stateVars.set(tag, myTween);
					return tag;
				}
				else luaTrace('startTween: No values on 2nd argument!', false, false, FlxColor.RED);
			}
			else luaTrace('startTween: Couldnt find object: ' + vars, false, false, FlxColor.RED);
			return null;
		});

		//Tween shit, but for strums
		Lua_helper.add_callback(lua, "noteTweenX", function(tag:String, note:Int, value:Dynamic, duration:Float, ease:String) {
			cancelTween(tag);
			if(note < 0) note = 0;
			var testicle:StrumNote = PlayState.instance.strumLineNotes.members[note % PlayState.instance.strumLineNotes.length];

			if(testicle != null) {
				PlayState.instance.modchartTweens.set(tag, FlxTween.tween(testicle, {x: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						PlayState.instance.callOnLuas('onTweenCompleted', [tag]);
						PlayState.instance.modchartTweens.remove(tag);
					}
				}));
			}
		});
		Lua_helper.add_callback(lua, "noteTweenY", function(tag:String, note:Int, value:Dynamic, duration:Float, ease:String) {
			cancelTween(tag);
			if(note < 0) note = 0;
			var testicle:StrumNote = PlayState.instance.strumLineNotes.members[note % PlayState.instance.strumLineNotes.length];

			if(testicle != null) {
				PlayState.instance.modchartTweens.set(tag, FlxTween.tween(testicle, {y: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						PlayState.instance.callOnLuas('onTweenCompleted', [tag]);
						PlayState.instance.modchartTweens.remove(tag);
					}
				}));
			}
		});
		Lua_helper.add_callback(lua, "noteTweenAngle", function(tag:String, note:Int, value:Dynamic, duration:Float, ease:String) {
			cancelTween(tag);
			if(note < 0) note = 0;
			var testicle:StrumNote = PlayState.instance.strumLineNotes.members[note % PlayState.instance.strumLineNotes.length];

			if(testicle != null) {
				PlayState.instance.modchartTweens.set(tag, FlxTween.tween(testicle, {angle: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						PlayState.instance.callOnLuas('onTweenCompleted', [tag]);
						PlayState.instance.modchartTweens.remove(tag);
					}
				}));
			}
		});
		Lua_helper.add_callback(lua, "noteTweenDirection", function(tag:String, note:Int, value:Dynamic, duration:Float, ease:String) {
			cancelTween(tag);
			if(note < 0) note = 0;
			var testicle:StrumNote = PlayState.instance.strumLineNotes.members[note % PlayState.instance.strumLineNotes.length];

			if(testicle != null) {
				PlayState.instance.modchartTweens.set(tag, FlxTween.tween(testicle, {direction: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						PlayState.instance.callOnLuas('onTweenCompleted', [tag]);
						PlayState.instance.modchartTweens.remove(tag);
					}
				}));
			}
		});
		Lua_helper.add_callback(lua, "mouseClicked", function(button:String) {
			var boobs = FlxG.mouse.justPressed;
			switch(button){
				case 'middle':
					boobs = FlxG.mouse.justPressedMiddle;
				case 'right':
					boobs = FlxG.mouse.justPressedRight;
			}


			return boobs;
		});
		Lua_helper.add_callback(lua, "mousePressed", function(button:String) {
			var boobs = FlxG.mouse.pressed;
			switch(button){
				case 'middle':
					boobs = FlxG.mouse.pressedMiddle;
				case 'right':
					boobs = FlxG.mouse.pressedRight;
			}
			return boobs;
		});
		Lua_helper.add_callback(lua, "mouseReleased", function(button:String) {
			var boobs = FlxG.mouse.justReleased;
			switch(button){
				case 'middle':
					boobs = FlxG.mouse.justReleasedMiddle;
				case 'right':
					boobs = FlxG.mouse.justReleasedRight;
			}
			return boobs;
		});
		Lua_helper.add_callback(lua, "noteTweenAngle", function(tag:String, note:Int, value:Dynamic, duration:Float, ease:String) {
			cancelTween(tag);
			if(note < 0) note = 0;
			var testicle:StrumNote = PlayState.instance.strumLineNotes.members[note % PlayState.instance.strumLineNotes.length];

			if(testicle != null) {
				PlayState.instance.modchartTweens.set(tag, FlxTween.tween(testicle, {angle: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						PlayState.instance.callOnLuas('onTweenCompleted', [tag]);
						PlayState.instance.modchartTweens.remove(tag);
					}
				}));
			}
		});
		Lua_helper.add_callback(lua, "noteTweenAlpha", function(tag:String, note:Int, value:Dynamic, duration:Float, ease:String) {
			cancelTween(tag);
			if(note < 0) note = 0;
			var testicle:StrumNote = PlayState.instance.strumLineNotes.members[note % PlayState.instance.strumLineNotes.length];

			if(testicle != null) {
				PlayState.instance.modchartTweens.set(tag, FlxTween.tween(testicle, {alpha: value}, duration, {ease: getFlxEaseByString(ease),
					onComplete: function(twn:FlxTween) {
						PlayState.instance.callOnLuas('onTweenCompleted', [tag]);
						PlayState.instance.modchartTweens.remove(tag);
					}
				}));
			}
		});

		Lua_helper.add_callback(lua, "cancelTween", function(tag:String) {
			cancelTween(tag);
		});

		Lua_helper.add_callback(lua, "runTimer", function(tag:String, time:Float = 1, loops:Int = 1) {
			cancelTimer(tag);
			var timers = getStateModchartTimers();
			if(timers != null) {
				timers.set(tag, new FlxTimer().start(time, function(tmr:FlxTimer) {
					if(tmr.finished) {
						timers.remove(tag);
					}
					callOnStateLuas('onTimerCompleted', [tag, tmr.loops, tmr.loopsLeft]);
				}, loops));
			}
		});
		Lua_helper.add_callback(lua, "cancelTimer", function(tag:String) {
			cancelTimer(tag);
		});

		/*Lua_helper.add_callback(lua, "getPropertyAdvanced", function(varsStr:String) {
			var variables:Array<String> = varsStr.replace(' ', '').split(',');
			var leClass:Class<Dynamic> = Type.resolveClass(variables[0]);
			if(variables.length > 2) {
				var curProp:Dynamic = Reflect.getProperty(leClass, variables[1]);
				if(variables.length > 3) {
					for (i in 2...variables.length-1) {
						curProp = Reflect.getProperty(curProp, variables[i]);
					}
				}
				return Reflect.getProperty(curProp, variables[variables.length-1]);
			} else if(variables.length == 2) {
				return Reflect.getProperty(leClass, variables[variables.length-1]);
			}
			return null;
		});
		Lua_helper.add_callback(lua, "setPropertyAdvanced", function(varsStr:String, value:Dynamic) {
			var variables:Array<String> = varsStr.replace(' ', '').split(',');
			var leClass:Class<Dynamic> = Type.resolveClass(variables[0]);
			if(variables.length > 2) {
				var curProp:Dynamic = Reflect.getProperty(leClass, variables[1]);
				if(variables.length > 3) {
					for (i in 2...variables.length-1) {
						curProp = Reflect.getProperty(curProp, variables[i]);
					}
				}
				return Reflect.setProperty(curProp, variables[variables.length-1], value);
			} else if(variables.length == 2) {
				return Reflect.setProperty(leClass, variables[variables.length-1], value);
			}
		});*/

		//stupid bietch ass functions
		Lua_helper.add_callback(lua, "addScore", function(value:Int = 0) {
			if (PlayState.instance == null) return;
			PlayState.instance.songScore += value;
			PlayState.instance.RecalculateRating();
		});
		Lua_helper.add_callback(lua, "addMisses", function(value:Int = 0) {
			if (PlayState.instance == null) return;
			PlayState.instance.songMisses += value;
			PlayState.instance.RecalculateRating();
		});
		Lua_helper.add_callback(lua, "addHits", function(value:Int = 0) {
			if (PlayState.instance == null) return;
			PlayState.instance.songHits += value;
			PlayState.instance.RecalculateRating();
		});
		Lua_helper.add_callback(lua, "setScore", function(value:Int = 0) {
			if (PlayState.instance == null) return;
			PlayState.instance.songScore = value;
			PlayState.instance.RecalculateRating();
		});
		Lua_helper.add_callback(lua, "setMisses", function(value:Int = 0) {
			if (PlayState.instance == null) return;
			PlayState.instance.songMisses = value;
			PlayState.instance.RecalculateRating();
		});
		Lua_helper.add_callback(lua, "setHits", function(value:Int = 0) {
			if (PlayState.instance == null) return;
			PlayState.instance.songHits = value;
			PlayState.instance.RecalculateRating();
		});
		Lua_helper.add_callback(lua, "getScore", function() {
			return (PlayState.instance != null) ? PlayState.instance.songScore : 0;
		});
		Lua_helper.add_callback(lua, "getMisses", function() {
			return (PlayState.instance != null) ? PlayState.instance.songMisses : 0;
		});
		Lua_helper.add_callback(lua, "getHits", function() {
			return (PlayState.instance != null) ? PlayState.instance.songHits : 0;
		});

		Lua_helper.add_callback(lua, "setHealth", function(value:Float = 0) {
			if (PlayState.instance == null) return;
			PlayState.instance.health = value;
		});
		Lua_helper.add_callback(lua, "addHealth", function(value:Float = 0) {
			if (PlayState.instance == null) return;
			PlayState.instance.health += value;
		});
		Lua_helper.add_callback(lua, "getHealth", function() {
			return (PlayState.instance != null) ? PlayState.instance.health : 0;
		});

		Lua_helper.add_callback(lua, "getColorFromHex", function(color:String) {
			if(!color.startsWith('0x')) color = '0xff' + color;
			return Std.parseInt(color);
		});
		Lua_helper.add_callback(lua, "FlxColor", function(color:String) return FlxColor.fromString(color));
		Lua_helper.add_callback(lua, "getColorFromName", function(color:String) return FlxColor.fromString(color));
		Lua_helper.add_callback(lua, "getColorFromString", function(color:String) return FlxColor.fromString(color));

		Lua_helper.add_callback(lua, "keyboardJustPressed", function(name:String)
		{
			// 回放时: 录制中出现过的键以模拟状态为准 (还原 mod 自定义机制键)
			if (PlayState.replayMode && PlayState.instance != null && PlayState.instance.replayExam != null
				&& PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyJustPressed(name);

			var keyDown:Bool = Reflect.getProperty(FlxG.keys.justPressed, name) == true;
			if (keyDown) return true;
			if (PlayState.instance == null) return false;

			// 0.7.3/1.0.4 兼容：很多模组只检查 keyboardJustPressed('ENTER')，
			// 这里在键盘没按时回退到 Controls 的 ACCEPT/BACK/UI_*，让手柄也能操作菜单。
			switch(name.toUpperCase())
			{
				case 'ENTER' | 'SPACE' | 'Z':
					return PlayState.instance.getControl('ACCEPT');
				case 'ESCAPE' | 'BACKSPACE':
					return PlayState.instance.getControl('BACK');
				case 'W' | 'UP':
					return PlayState.instance.getControl('UI_UP_P');
				case 'S' | 'DOWN':
					return PlayState.instance.getControl('UI_DOWN_P');
				case 'A' | 'LEFT':
					return PlayState.instance.getControl('UI_LEFT_P');
				case 'D' | 'RIGHT':
					return PlayState.instance.getControl('UI_RIGHT_P');
			}
			return false;
		});
		Lua_helper.add_callback(lua, "keyboardPressed", function(name:String)
		{
			if (PlayState.replayMode && PlayState.instance != null && PlayState.instance.replayExam != null
				&& PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyPressed(name);

			var keyDown:Bool = Reflect.getProperty(FlxG.keys.pressed, name) == true;
			if (keyDown) return true;
			if (PlayState.instance == null) return false;

			switch(name.toUpperCase())
			{
				case 'W' | 'UP':
					return PlayState.instance.getControl('UI_UP');
				case 'S' | 'DOWN':
					return PlayState.instance.getControl('UI_DOWN');
				case 'A' | 'LEFT':
					return PlayState.instance.getControl('UI_LEFT');
				case 'D' | 'RIGHT':
					return PlayState.instance.getControl('UI_RIGHT');
			}
			return false;
		});
		Lua_helper.add_callback(lua, "keyboardReleased", function(name:String)
		{
			if (PlayState.replayMode && PlayState.instance != null && PlayState.instance.replayExam != null
				&& PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyJustReleased(name);

			var keyUp:Bool = Reflect.getProperty(FlxG.keys.justReleased, name) == true;
			if (keyUp) return true;
			if (PlayState.instance == null) return false;

			switch(name.toUpperCase())
			{
				case 'W' | 'UP':
					return PlayState.instance.getControl('UI_UP_R');
				case 'S' | 'DOWN':
					return PlayState.instance.getControl('UI_DOWN_R');
				case 'A' | 'LEFT':
					return PlayState.instance.getControl('UI_LEFT_R');
				case 'D' | 'RIGHT':
					return PlayState.instance.getControl('UI_RIGHT_R');
			}
			return false;
		});

		Lua_helper.add_callback(lua, "anyGamepadJustPressed", function(name:String)
		{
			return FlxG.gamepads.anyJustPressed(name);
		});
		Lua_helper.add_callback(lua, "anyGamepadPressed", function(name:String)
		{
			return FlxG.gamepads.anyPressed(name);
		});
		Lua_helper.add_callback(lua, "anyGamepadReleased", function(name:String)
		{
			return FlxG.gamepads.anyJustReleased(name);
		});

		Lua_helper.add_callback(lua, "gamepadAnalogX", function(id:Int, ?leftStick:Bool = true)
		{
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
			{
				return 0.0;
			}
			return controller.getXAxis(leftStick ? LEFT_ANALOG_STICK : RIGHT_ANALOG_STICK);
		});
		Lua_helper.add_callback(lua, "gamepadAnalogY", function(id:Int, ?leftStick:Bool = true)
		{
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
			{
				return 0.0;
			}
			return controller.getYAxis(leftStick ? LEFT_ANALOG_STICK : RIGHT_ANALOG_STICK);
		});
		Lua_helper.add_callback(lua, "gamepadJustPressed", function(id:Int, name:String)
		{
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
			{
				return false;
			}
			return Reflect.getProperty(controller.justPressed, name) == true;
		});
		Lua_helper.add_callback(lua, "gamepadPressed", function(id:Int, name:String)
		{
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
			{
				return false;
			}
			return Reflect.getProperty(controller.pressed, name) == true;
		});
		Lua_helper.add_callback(lua, "gamepadReleased", function(id:Int, name:String)
		{
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
			{
				return false;
			}
			return Reflect.getProperty(controller.justReleased, name) == true;
		});

		Lua_helper.add_callback(lua, "keyJustPressed", function(name:String) {
			if (PlayState.instance == null) return false;
			// 回放时: 录制中出现过的键以模拟状态为准 (还原 mod 自定义机制键, 如空格闪避)
			if (PlayState.replayMode && PlayState.instance.replayExam != null && PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyJustPressed(name);
			var key:Bool = false;
			switch(name) {
				case 'left': key = PlayState.instance.getControl('NOTE_LEFT_P');
				case 'down': key = PlayState.instance.getControl('NOTE_DOWN_P');
				case 'up': key = PlayState.instance.getControl('NOTE_UP_P');
				case 'right': key = PlayState.instance.getControl('NOTE_RIGHT_P');
				case 'accept': key = PlayState.instance.getControl('ACCEPT');
				case 'back': key = PlayState.instance.getControl('BACK');
				case 'pause': key = PlayState.instance.getControl('PAUSE');
				case 'reset': key = PlayState.instance.getControl('RESET');
				case 'space': key = FlxG.keys.justPressed.SPACE;//an extra key for convinience
				default: key = PlayState.instance.controls.justPressed(name);
			}
			return key;
		});
		Lua_helper.add_callback(lua, "keyPressed", function(name:String) {
			if (PlayState.instance == null) return false;
			if (PlayState.replayMode && PlayState.instance.replayExam != null && PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyPressed(name);
			var key:Bool = false;
			switch(name) {
				case 'left': key = PlayState.instance.getControl('NOTE_LEFT');
				case 'down': key = PlayState.instance.getControl('NOTE_DOWN');
				case 'up': key = PlayState.instance.getControl('NOTE_UP');
				case 'right': key = PlayState.instance.getControl('NOTE_RIGHT');
				case 'space': key = FlxG.keys.pressed.SPACE;//an extra key for convinience
				default: key = PlayState.instance.controls.pressed(name);
			}
			return key;
		});
		Lua_helper.add_callback(lua, "keyReleased", function(name:String) {
			if (PlayState.instance == null) return false;
			if (PlayState.replayMode && PlayState.instance.replayExam != null && PlayState.instance.replayExam.keyExists(name))
				return PlayState.instance.replayExam.keyJustReleased(name);
			var key:Bool = false;
			switch(name) {
				case 'left': key = PlayState.instance.getControl('NOTE_LEFT_R');
				case 'down': key = PlayState.instance.getControl('NOTE_DOWN_R');
				case 'up': key = PlayState.instance.getControl('NOTE_UP_R');
				case 'right': key = PlayState.instance.getControl('NOTE_RIGHT_R');
				case 'space': key = FlxG.keys.justReleased.SPACE;//an extra key for convinience
				default: key = PlayState.instance.controls.justReleased(name);
			}
			return key;
		});
		#if MODS_ALLOWED
		addLocalCallback("getModSetting", function(saveTag:String, ?modName:String = null) {
			if(modName == null)
			{
				if(this.modFolder == null)
				{
					luaTrace('getModSetting: Argument #2 is null and script is not inside a packed Mod folder!', false, false, FlxColor.RED);
					return null;
				}
				modName = this.modFolder;
			}
			return getModSetting(saveTag, modName);
		});
		#end
		addLocalCallback("setOnScripts", function(varName:String, arg:Dynamic, ?ignoreSelf:Bool = false, ?exclusions:Array<String> = null) {
			if(exclusions == null) exclusions = [];
			if(ignoreSelf && !exclusions.contains(scriptName)) exclusions.push(scriptName);
			var state = FlxG.state;
			if (PlayState.instance != null) PlayState.instance.setOnScripts(varName, arg, exclusions);
			else if (Std.isOfType(state, MusicBeatState)) {
				var mState:MusicBeatState = cast state;
				mState.setOnHscript(varName, arg);
				mState.setOnLuas(varName, arg, exclusions);
			} else if (Std.isOfType(state, MusicBeatSubstate)) {
				var mSub:MusicBeatSubstate = cast state;
				mSub.setOnHscript(varName, arg);
				mSub.setOnLuas(varName, arg, exclusions);
			}
		});
		addLocalCallback("setOnHScript", function(varName:String, arg:Dynamic, ?ignoreSelf:Bool = false, ?exclusions:Array<String> = null) {
			if(exclusions == null) exclusions = [];
			if(ignoreSelf && !exclusions.contains(scriptName)) exclusions.push(scriptName);
			var state = FlxG.state;
			if (PlayState.instance != null) PlayState.instance.setOnHScript(varName, arg, exclusions);
			else if (Std.isOfType(state, MusicBeatState)) cast(state, MusicBeatState).setOnHscript(varName, arg);
			else if (Std.isOfType(state, MusicBeatSubstate)) cast(state, MusicBeatSubstate).setOnHscript(varName, arg);
		});
		addLocalCallback("setOnLuas", function(varName:String, arg:Dynamic, ?ignoreSelf:Bool = false, ?exclusions:Array<String> = null) {
			if(exclusions == null) exclusions = [];
			if(ignoreSelf && !exclusions.contains(scriptName)) exclusions.push(scriptName);
			var state = FlxG.state;
			if (PlayState.instance != null) PlayState.instance.setOnLuas(varName, arg, exclusions);
			else if (Std.isOfType(state, MusicBeatState)) cast(state, MusicBeatState).setOnLuas(varName, arg, exclusions);
			else if (Std.isOfType(state, MusicBeatSubstate)) cast(state, MusicBeatSubstate).setOnLuas(varName, arg, exclusions);
		});

		addLocalCallback("callOnScripts", function(funcName:String, ?args:Array<Dynamic> = null, ?ignoreStops=false, ?ignoreSelf:Bool = true, ?excludeScripts:Array<String> = null, ?excludeValues:Array<Dynamic> = null) {
			if(excludeScripts == null) excludeScripts = [];
			if(ignoreSelf && !excludeScripts.contains(scriptName)) excludeScripts.push(scriptName);
			callOnStateScripts(funcName, args, ignoreStops, excludeScripts, excludeValues);
			return true;
		});
		addLocalCallback("callOnLuas", function(funcName:String, ?args:Array<Dynamic> = null, ?ignoreStops=false, ?ignoreSelf:Bool = true, ?excludeScripts:Array<String> = null, ?excludeValues:Array<Dynamic> = null) {
			if(excludeScripts == null) excludeScripts = [];
			if(ignoreSelf && !excludeScripts.contains(scriptName)) excludeScripts.push(scriptName);
			callOnStateLuas(funcName, args, ignoreStops, excludeScripts, excludeValues);
			return true;
		});
		addLocalCallback("callOnHScript", function(funcName:String, ?args:Array<Dynamic> = null, ?ignoreStops=false, ?ignoreSelf:Bool = true, ?excludeScripts:Array<String> = null, ?excludeValues:Array<Dynamic> = null) {
			if(excludeScripts == null) excludeScripts = [];
			if(ignoreSelf && !excludeScripts.contains(scriptName)) excludeScripts.push(scriptName);
			// callOnHScript should only call hscript, not lua
			var state = FlxG.state;
			if (PlayState.instance != null) PlayState.instance.callOnHScript(funcName, args, ignoreStops, excludeScripts, excludeValues);
			else if (Std.isOfType(state, MusicBeatState)) cast(state, MusicBeatState).callOnHscript(funcName, args, ignoreStops, excludeScripts);
			else if (Std.isOfType(state, MusicBeatSubstate)) cast(state, MusicBeatSubstate).callOnHscript(funcName, args, ignoreStops, excludeScripts);
			return true;
		});

		// 0.7.3+/1.0.4: setVar / getVar / removeVar（操作 MusicBeatState.variables）
		// setVar/getVar/removeVar (0.7.3+) — operate on MusicBeatState.variables
		Lua_helper.add_callback(lua, "setVar", function(varName:String, value:Dynamic) {
			var vars = getStateVars();
			if (vars != null) vars.set(varName, value);
			return value;
		});
		Lua_helper.add_callback(lua, "getVar", function(varName:String) {
			var vars = getStateVars();
			return (vars != null) ? vars.get(varName) : null;
		});
		Lua_helper.add_callback(lua, "removeVar", function(varName:String) {
			var vars = getStateVars();
			if (vars != null && vars.exists(varName)) {
				vars.remove(varName);
				return true;
			}
			return false;
		});


		Lua_helper.add_callback(lua, "addCharacterToList", function(name:String, type:String) {
			var charType:Int = 0;
			switch(type.toLowerCase()) {
				case 'dad': charType = 1;
				case 'gf' | 'girlfriend': charType = 2;
			}
			PlayState.instance.addCharacterToList(name, charType);
		});
		Lua_helper.add_callback(lua, "precacheImage", function(name:String) {
			Paths.returnGraphic(name);
		});
		Lua_helper.add_callback(lua, "precacheSound", function(name:String) {
			CoolUtil.precacheSound(name);
		});
		Lua_helper.add_callback(lua, "precacheMusic", function(name:String) {
			CoolUtil.precacheMusic(name);
		});
		Lua_helper.add_callback(lua, "triggerEvent", function(name:String, arg1:Dynamic, arg2:Dynamic) {
			var value1:String = arg1;
			var value2:String = arg2;
			PlayState.instance.triggerEventNote(name, value1, value2);
			//trace('Triggered event: ' + name + ', ' + value1 + ', ' + value2);
			return true;
		});

		Lua_helper.add_callback(lua, "startCountdown", function() {
			PlayState.instance.startCountdown();
			return true;
		});
		Lua_helper.add_callback(lua, "endSong", function() {
			PlayState.instance.KillNotes();
			PlayState.instance.endSong();
			return true;
		});
		Lua_helper.add_callback(lua, "restartSong", function(?skipTransition:Bool = false) {
			PlayState.instance.persistentUpdate = false;
			PauseSubState.restartSong(skipTransition);
			return true;
		});
		Lua_helper.add_callback(lua, "exitSong", function(?skipTransition:Bool = false) {
			if(skipTransition)
			{
				FlxTransitionableState.skipNextTransIn = true;
				FlxTransitionableState.skipNextTransOut = true;
			}

			PlayState.cancelMusicFadeTween();
			CustomFadeTransition.nextCamera = PlayState.instance.camOther;
			if(FlxTransitionableState.skipNextTransIn)
				CustomFadeTransition.nextCamera = null;

			if(PlayState.isStoryMode)
				MusicBeatState.switchState(new StoryMenuState());
			else
				MusicBeatState.switchState(new FreeplayState());

			FlxG.sound.playMusic(Paths.music('freakyMenu'));
			PlayState.changedDifficulty = false;
			PlayState.chartingMode = false;
			PlayState.instance.transitioning = true;
			WeekData.loadTheFirstEnabledMod();
			return true;
		});
		Lua_helper.add_callback(lua, "getSongPosition", function() {
			return Conductor.songPosition;
		});

		Lua_helper.add_callback(lua, "getCharacterX", function(type:String) {
			switch(type.toLowerCase()) {
				case 'dad' | 'opponent':
					return PlayState.instance.dadGroup.x;
				case 'gf' | 'girlfriend':
					return PlayState.instance.gfGroup.x;
				default:
					return PlayState.instance.boyfriendGroup.x;
			}
		});
		Lua_helper.add_callback(lua, "setCharacterX", function(type:String, value:Float) {
			switch(type.toLowerCase()) {
				case 'dad' | 'opponent':
					PlayState.instance.dadGroup.x = value;
				case 'gf' | 'girlfriend':
					PlayState.instance.gfGroup.x = value;
				default:
					PlayState.instance.boyfriendGroup.x = value;
			}
		});
		Lua_helper.add_callback(lua, "getCharacterY", function(type:String) {
			switch(type.toLowerCase()) {
				case 'dad' | 'opponent':
					return PlayState.instance.dadGroup.y;
				case 'gf' | 'girlfriend':
					return PlayState.instance.gfGroup.y;
				default:
					return PlayState.instance.boyfriendGroup.y;
			}
		});
		Lua_helper.add_callback(lua, "setCharacterY", function(type:String, value:Float) {
			switch(type.toLowerCase()) {
				case 'dad' | 'opponent':
					PlayState.instance.dadGroup.y = value;
				case 'gf' | 'girlfriend':
					PlayState.instance.gfGroup.y = value;
				default:
					PlayState.instance.boyfriendGroup.y = value;
			}
		});
		Lua_helper.add_callback(lua, "cameraSetTarget", function(target:String) {
			var isDad:Bool = false;
			if(target == 'dad') {
				isDad = true;
			}
			PlayState.instance.moveCamera(isDad);
			return isDad;
		});

		// 1.0.4 相机滚动/跟随点函数（0.6.3/0.7.3 没有，属于 1.0.4 新增）
		// 1.0.4-only camera scroll/follow-point functions
		Lua_helper.add_callback(lua, "setCameraScroll", function(x:Float, y:Float) FlxG.camera.scroll.set(x - FlxG.width / 2, y - FlxG.height / 2));
		Lua_helper.add_callback(lua, "setCameraFollowPoint", function(x:Float, y:Float) {
			if (PlayState.instance != null && PlayState.instance.camFollow != null)
				PlayState.instance.camFollow.set(x, y);
		});
		Lua_helper.add_callback(lua, "addCameraScroll", function(?x:Float = 0, ?y:Float = 0) FlxG.camera.scroll.add(x, y));
		Lua_helper.add_callback(lua, "addCameraFollowPoint", function(?x:Float = 0, ?y:Float = 0) {
			if (PlayState.instance != null && PlayState.instance.camFollow != null)
			{
				PlayState.instance.camFollow.x += x;
				PlayState.instance.camFollow.y += y;
			}
		});
		Lua_helper.add_callback(lua, "getCameraScrollX", function() return FlxG.camera.scroll.x + FlxG.width / 2);
		Lua_helper.add_callback(lua, "getCameraScrollY", function() return FlxG.camera.scroll.y + FlxG.height / 2);
		Lua_helper.add_callback(lua, "getCameraFollowX", function() {
			return (PlayState.instance != null && PlayState.instance.camFollow != null) ? PlayState.instance.camFollow.x : 0;
		});
		Lua_helper.add_callback(lua, "getCameraFollowY", function() {
			return (PlayState.instance != null && PlayState.instance.camFollow != null) ? PlayState.instance.camFollow.y : 0;
		});

		Lua_helper.add_callback(lua, "cameraShake", function(camera:String, intensity:Float, duration:Float) {
			cameraFromString(camera).shake(intensity, duration);
		});

		Lua_helper.add_callback(lua, "cameraFlash", function(camera:String, color:String, duration:Float,forced:Bool) {
			var colorNum:Int = Std.parseInt(color);
			if(!color.startsWith('0x')) colorNum = Std.parseInt('0xff' + color);
			cameraFromString(camera).flash(colorNum, duration,null,forced);
		});
		// The 5th argument is Psych 1.0.4's (?fadeOut, H-Slice has the same): it is handed straight to
		// FlxCamera.fade() as its FadeIn flag, so true means "the colour is already covering the
		// screen and fades away over duration" while the default false means "fade out to it".
		// 0.6.3/0.7.3 only ever had 4 arguments and were hardcoded to false, which inverted every
		// 5-argument script: ampho.lua's cameraFade('hud','000000', 20, true, true) is meant to be a
		// 20s reveal from the black frame its onCreate sets up, and instead darkened the screen to
		// black over 20s. Default false keeps 4-argument scripts byte-for-byte unchanged.
		// (Upstream names it fadeOut even though it is passed as FadeIn -- kept for compatibility.)
		Lua_helper.add_callback(lua, "cameraFade", function(camera:String, color:String, duration:Float,forced:Bool, ?fadeOut:Bool = false) {
			var colorNum:Int = Std.parseInt(color);
			if(!color.startsWith('0x')) colorNum = Std.parseInt('0xff' + color);
			cameraFromString(camera).fade(colorNum, duration,fadeOut,null,forced);
		});
		Lua_helper.add_callback(lua, "setRatingPercent", function(value:Float) {
			PlayState.instance.ratingPercent = value;
		});
		Lua_helper.add_callback(lua, "setRatingName", function(value:String) {
			PlayState.instance.ratingName = value;
		});
		Lua_helper.add_callback(lua, "setRatingFC", function(value:String) {
			PlayState.instance.ratingFC = value;
		});
		Lua_helper.add_callback(lua, "updateScoreText", function() {
			if (PlayState.instance != null)
				PlayState.instance.updateScore();
		});
		Lua_helper.add_callback(lua, "getMouseX", function(camera:String) {
			var cam:FlxCamera = cameraFromString(camera);
			return FlxG.mouse.getScreenPosition(cam).x;
		});
		Lua_helper.add_callback(lua, "getMouseY", function(camera:String) {
			var cam:FlxCamera = cameraFromString(camera);
			return FlxG.mouse.getScreenPosition(cam).y;
		});

		Lua_helper.add_callback(lua, "getMidpointX", function(variable:String) {
			var killMe:Array<String> = variable.split('.');
			var obj:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				obj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}
			if(obj != null) return obj.getMidpoint().x;

			return 0;
		});
		Lua_helper.add_callback(lua, "getMidpointY", function(variable:String) {
			var killMe:Array<String> = variable.split('.');
			var obj:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				obj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}
			if(obj != null) return obj.getMidpoint().y;

			return 0;
		});
		Lua_helper.add_callback(lua, "getGraphicMidpointX", function(variable:String) {
			var killMe:Array<String> = variable.split('.');
			var obj:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				obj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}
			if(obj != null) return obj.getGraphicMidpoint().x;

			return 0;
		});
		Lua_helper.add_callback(lua, "getGraphicMidpointY", function(variable:String) {
			var killMe:Array<String> = variable.split('.');
			var obj:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				obj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}
			if(obj != null) return obj.getGraphicMidpoint().y;

			return 0;
		});
		Lua_helper.add_callback(lua, "getScreenPositionX", function(variable:String) {
			var killMe:Array<String> = variable.split('.');
			var obj:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				obj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}
			if(obj != null) return obj.getScreenPosition().x;

			return 0;
		});
		Lua_helper.add_callback(lua, "getScreenPositionY", function(variable:String) {
			var killMe:Array<String> = variable.split('.');
			var obj:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				obj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}
			if(obj != null) return obj.getScreenPosition().y;

			return 0;
		});
		Lua_helper.add_callback(lua, "characterDance", function(character:String) {
			switch(character.toLowerCase()) {
				case 'dad': PlayState.instance.dad.dance();
				case 'gf' | 'girlfriend': if(PlayState.instance.gf != null) PlayState.instance.gf.dance();
				default: PlayState.instance.boyfriend.dance();
			}
		});

		Lua_helper.add_callback(lua, "makeLuaSprite", function(tag:String, ?image:String = null, ?x:Float = 0, ?y:Float = 0) {
			tag = tag.replace('.', '');
			resetSpriteTag(tag);
			var leSprite:ModchartSprite = new ModchartSprite(x, y);
			if(image != null && image.length > 0)
			{
				// 单个贴图缺失不应中断整个脚本，保留空白 sprite 继续执行。
				try { leSprite.loadGraphic(Paths.image(image)); } catch(e:Dynamic) {}
			}
			var sprites = getStateModchartSprites();
			if(sprites != null) sprites.set(tag, leSprite);
			leSprite.active = true;
		});
		Lua_helper.add_callback(lua, "makeAnimatedLuaSprite", function(tag:String, ?image:String = null, ?x:Float = 0, ?y:Float = 0, ?spriteType:String = "sparrow") {
			tag = tag.replace('.', '');
			resetSpriteTag(tag);
			var leSprite:ModchartSprite = new ModchartSprite(x, y);

			// 单个图集/贴图缺失不应中断整个脚本，保留空白 sprite 继续执行。
			try { loadFrames(leSprite, image, spriteType); } catch(e:Dynamic) {}
			var sprites = getStateModchartSprites();
			if(sprites != null) sprites.set(tag, leSprite);
		});

		Lua_helper.add_callback(lua, "makeGraphic", function(obj:String, width:Int = 256, height:Int = 256, color:String = 'FFFFFF') {
			var colorNum:Int = Std.parseInt(color);
			if(!color.startsWith('0x')) colorNum = Std.parseInt('0xff' + color);

			var spr:FlxSprite = PlayState.instance.getLuaObject(obj,false);
			if(spr!=null) {
				PlayState.instance.getLuaObject(obj,false).makeGraphic(width, height, colorNum);
				return;
			}

			var object:FlxSprite = Reflect.getProperty(getInstance(), obj);
			if(object != null) {
				object.makeGraphic(width, height, colorNum);
			}
		});
		Lua_helper.add_callback(lua, "addAnimationByPrefix", function(obj:String, name:String, prefix:String, framerate:Int = 24, loop:Bool = true) {
			if(PlayState.instance.getLuaObject(obj,false)!=null) {
				var cock:FlxSprite = PlayState.instance.getLuaObject(obj,false);
				cock.animation.addByPrefix(name, prefix, framerate, loop);
				if(cock.animation.curAnim == null) {
					cock.animation.play(name, true);
				}
				return;
			}

			var cock:FlxSprite = Reflect.getProperty(getInstance(), obj);
			if(cock != null) {
				cock.animation.addByPrefix(name, prefix, framerate, loop);
				if(cock.animation.curAnim == null) {
					cock.animation.play(name, true);
				}
			}
		});

		Lua_helper.add_callback(lua, "addAnimation", function(obj:String, name:String, frames:Array<Int>, framerate:Int = 24, loop:Bool = true) {
			if(PlayState.instance.getLuaObject(obj,false)!=null) {
				var cock:FlxSprite = PlayState.instance.getLuaObject(obj,false);
				cock.animation.add(name, frames, framerate, loop);
				if(cock.animation.curAnim == null) {
					cock.animation.play(name, true);
				}
				return;
			}

			var cock:FlxSprite = Reflect.getProperty(getInstance(), obj);
			if(cock != null) {
				cock.animation.add(name, frames, framerate, loop);
				if(cock.animation.curAnim == null) {
					cock.animation.play(name, true);
				}
			}
		});

		Lua_helper.add_callback(lua, "addAnimationByIndices", function(obj:String, name:String, prefix:String, indices:Any, framerate:Int = 24, loop:Bool = false) {
			if(Std.isOfType(indices, Array)) {
				var arr:Array<Int> = cast indices;
				indices = arr.join(',');
			}
			return addAnimByIndices(obj, name, prefix, indices, framerate, loop);
		});
		Lua_helper.add_callback(lua, "addAnimationByIndicesLoop", function(obj:String, name:String, prefix:String, indices:String, framerate:Int = 24) {
			luaTrace("addAnimationByIndicesLoop is deprecated! Use addAnimationByIndices instead", false, true);
			return addAnimByIndices(obj, name, prefix, indices, framerate, true);
		});
		

		Lua_helper.add_callback(lua, "playAnim", function(obj:String, name:String, forced:Bool = false, ?reverse:Bool = false, ?startFrame:Int = 0)
		{
			var luaObj:FlxSprite = PlayState.instance.getLuaObject(obj, false);
			if(luaObj != null)
			{
				if(Std.isOfType(luaObj, Character))
				{
					var char:Character = cast luaObj;
					if(char.hasAnimation(name)) char.playAnim(name, forced, reverse, startFrame);
				}
				else if(Std.isOfType(luaObj, ModchartAnimateSprite))
				{
					var animSpr:ModchartAnimateSprite = cast luaObj;
					animSpr.playAnim(name, forced, reverse, startFrame);
				}
				else if(luaObj.animation.getByName(name) != null)
				{
					luaObj.animation.play(name, forced, reverse, startFrame);
					if(Std.isOfType(luaObj, ModchartSprite))
					{
						var modSpr:ModchartSprite = cast luaObj;
						var daOffset = modSpr.animOffsets.get(name);
						if (modSpr.animOffsets.exists(name))
						{
							modSpr.offset.set(daOffset[0], daOffset[1]);
						}
					}
				}
				return true;
			}

			var spr:FlxSprite = Reflect.getProperty(getInstance(), obj);
			if(spr != null)
			{
				if(Std.isOfType(spr, Character))
				{
					var char:Character = cast spr;
					if(char.hasAnimation(name)) char.playAnim(name, forced, reverse, startFrame);
				}
				else if(Std.isOfType(spr, ModchartAnimateSprite))
				{
					var animSpr:ModchartAnimateSprite = cast spr;
					animSpr.playAnim(name, forced, reverse, startFrame);
				}
				else if(spr.animation.getByName(name) != null)
				{
					spr.animation.play(name, forced, reverse, startFrame);
				}
				return true;
			}
			return false;
		});
		Lua_helper.add_callback(lua, "addOffset", function(obj:String, anim:String, x:Float, y:Float) {
			if(PlayState.instance.modchartSprites.exists(obj)) {
				PlayState.instance.modchartSprites.get(obj).animOffsets.set(anim, [x, y]);
				return true;
			}

			var char:Character = Reflect.getProperty(getInstance(), obj);
			if(char != null) {
				char.addOffset(anim, x, y);
				return true;
			}
			return false;
		});

		Lua_helper.add_callback(lua, "setScrollFactor", function(obj:String, scrollX:Float, scrollY:Float) {
			if(PlayState.instance.getLuaObject(obj,false)!=null) {
				PlayState.instance.getLuaObject(obj,false).scrollFactor.set(scrollX, scrollY);
				return;
			}

			var object:FlxObject = Reflect.getProperty(getInstance(), obj);
			if(object != null) {
				object.scrollFactor.set(scrollX, scrollY);
			}
		});
		Lua_helper.add_callback(lua, "addLuaSprite", function(tag:String, front:Bool = false) {
			var sprites = getStateModchartSprites();
			if(sprites == null || !sprites.exists(tag)) return;
			var shit:ModchartSprite = sprites.get(tag);
			// Same reason as setSpriteShader: an added sprite with no frame at all is never drawn
			// (and flixel's own safety net, checkEmptyFrame()'s flixel logo, is not in this build).
			ensureSpriteFrame(shit);
			if(!shit.wasAdded) {
				if(front) {
					getTargetInstance().add(shit);
				} else {
					// PlayState-specific: insert among character groups
					if(PlayState.instance != null && !PlayState.instance.isDead) {
						var position:Int = PlayState.instance.members.indexOf(PlayState.instance.gfGroup);
						if(PlayState.instance.members.indexOf(PlayState.instance.boyfriendGroup) < position) {
							position = PlayState.instance.members.indexOf(PlayState.instance.boyfriendGroup);
						} else if(PlayState.instance.members.indexOf(PlayState.instance.dadGroup) < position) {
							position = PlayState.instance.members.indexOf(PlayState.instance.dadGroup);
						}
						PlayState.instance.insert(position, shit);
					} else if(PlayState.instance != null && PlayState.instance.isDead) {
						GameOverSubstate.instance.insert(GameOverSubstate.instance.members.indexOf(GameOverSubstate.instance.boyfriend), shit);
					} else {
						getTargetInstance().add(shit);
					}
				}
				shit.wasAdded = true;
			}
		});
		Lua_helper.add_callback(lua, "setGraphicSize", function(obj:String, x:Int, y:Int = 0, updateHitbox:Bool = true) {
			if(PlayState.instance.getLuaObject(obj)!=null) {
				var shit:FlxSprite = PlayState.instance.getLuaObject(obj);
				shit.setGraphicSize(x, y);
				if(updateHitbox) shit.updateHitbox();
				return;
			}

			var killMe:Array<String> = obj.split('.');
			var poop:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				poop = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(poop != null) {
				poop.setGraphicSize(x, y);
				if(updateHitbox) poop.updateHitbox();
				return;
			}
			luaTrace('setGraphicSize: Couldnt find object: ' + obj, false, false, FlxColor.RED);
		});
		Lua_helper.add_callback(lua, "scaleObject", function(obj:String, x:Float, y:Float, updateHitbox:Bool = true) {
			if(PlayState.instance.getLuaObject(obj)!=null) {
				var shit:FlxSprite = PlayState.instance.getLuaObject(obj);
				shit.scale.set(x, y);
				if(updateHitbox) shit.updateHitbox();
				return;
			}

			var killMe:Array<String> = obj.split('.');
			var poop:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				poop = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(poop != null) {
				poop.scale.set(x, y);
				if(updateHitbox) poop.updateHitbox();
				return;
			}
			luaTrace('scaleObject: Couldnt find object: ' + obj, false, false, FlxColor.RED);
		});
		Lua_helper.add_callback(lua, "updateHitbox", function(obj:String) {
			if(PlayState.instance.getLuaObject(obj)!=null) {
				var shit:FlxSprite = PlayState.instance.getLuaObject(obj);
				shit.updateHitbox();
				return;
			}

			var poop:FlxSprite = Reflect.getProperty(getInstance(), obj);
			if(poop != null) {
				poop.updateHitbox();
				return;
			}
			luaTrace('updateHitbox: Couldnt find object: ' + obj, false, false, FlxColor.RED);
		});
		Lua_helper.add_callback(lua, "updateHitboxFromGroup", function(group:String, index:Int) {
			if(Std.isOfType(Reflect.getProperty(getInstance(), group), FlxTypedGroup)) {
				Reflect.getProperty(getInstance(), group).members[index].updateHitbox();
				return;
			}
			Reflect.getProperty(getInstance(), group)[index].updateHitbox();
		});

		Lua_helper.add_callback(lua, "removeLuaSprite", function(tag:String, destroy:Bool = true) {
			if(!PlayState.instance.modchartSprites.exists(tag)) {
				return;
			}

			var pee:ModchartSprite = PlayState.instance.modchartSprites.get(tag);
			if(destroy) {
				pee.kill();
			}

			if(pee.wasAdded) {
				getInstance().remove(pee, true);
				pee.wasAdded = false;
			}

			if(destroy) {
				pee.destroy();
				PlayState.instance.modchartSprites.remove(tag);
				PlayState.instance.wiggleMap.remove(tag);
			}
		});

		Lua_helper.add_callback(lua, "luaSpriteExists", function(tag:String) {
			var sprites = getStateModchartSprites();
			return sprites != null && sprites.exists(tag);
		});
		Lua_helper.add_callback(lua, "luaTextExists", function(tag:String) {
			var texts = getStateModchartTexts();
			return texts != null && texts.exists(tag);
		});
		Lua_helper.add_callback(lua, "luaSoundExists", function(tag:String) {
			var sounds = getStateModchartSounds();
			return sounds != null && sounds.exists(tag);
		});

		Lua_helper.add_callback(lua, "setHealthBarColors", function(leftHex:String, rightHex:String) {
			var left:FlxColor = Std.parseInt(leftHex);
			if(!leftHex.startsWith('0x')) left = Std.parseInt('0xff' + leftHex);
			var right:FlxColor = Std.parseInt(rightHex);
			if(!rightHex.startsWith('0x')) right = Std.parseInt('0xff' + rightHex);

			if (CompatEngine.compatMode()) {
				PlayState.instance.healthBar.setColors(left, right);
			} else {
				PlayState.instance.healthBar.createFilledBar(left, right);
				PlayState.instance.healthBar.updateBar();
			}
		});

		Lua_helper.add_callback(lua, "setTimeBarColors", function(leftHex:String, rightHex:String) {
			var left:FlxColor = Std.parseInt(leftHex);
			if(!leftHex.startsWith('0x')) left = Std.parseInt('0xff' + leftHex);
			var right:FlxColor = Std.parseInt(rightHex);
			if(!rightHex.startsWith('0x')) right = Std.parseInt('0xff' + rightHex);

			if (CompatEngine.compatMode()) {
				PlayState.instance.timeBar.setColors(left, right);
			} else {
				PlayState.instance.timeBar.createFilledBar(right, left);
				PlayState.instance.timeBar.updateBar();
			}
		});

		Lua_helper.add_callback(lua, "setObjectCamera", function(obj:String, camera:String = '') {
			/*if(PlayState.instance.modchartSprites.exists(obj)) {
				PlayState.instance.modchartSprites.get(obj).cameras = [cameraFromString(camera)];
				return true;
			}
			else if(PlayState.instance.modchartTexts.exists(obj)) {
				PlayState.instance.modchartTexts.get(obj).cameras = [cameraFromString(camera)];
				return true;
			}*/
			var real = PlayState.instance.getLuaObject(obj);
			if(real!=null){
				real.cameras = [cameraFromString(camera)];
				return true;
			}

			var killMe:Array<String> = obj.split('.');
			var object:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				object = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(object != null) {
				object.cameras = [cameraFromString(camera)];
				return true;
			}
			luaTrace("setObjectCamera: Object " + obj + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "setBlendMode", function(obj:String, blend:String = '') {
			var real = PlayState.instance.getLuaObject(obj);
			if(real!=null) {
				real.blend = blendModeFromString(blend);
				return true;
			}

			var killMe:Array<String> = obj.split('.');
			var spr:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				spr = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(spr != null) {
				spr.blend = blendModeFromString(blend);
				return true;
			}
			luaTrace("setBlendMode: Object " + obj + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "screenCenter", function(obj:String, pos:String = 'xy') {
			var spr:FlxSprite = PlayState.instance.getLuaObject(obj);

			if(spr==null){
				var killMe:Array<String> = obj.split('.');
				spr = getObjectDirectly(killMe[0]);
				if(killMe.length > 1) {
					spr = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
				}
			}

			if(spr != null)
			{
				switch(pos.trim().toLowerCase())
				{
					case 'x':
						spr.screenCenter(X);
						return;
					case 'y':
						spr.screenCenter(Y);
						return;
					default:
						spr.screenCenter(XY);
						return;
				}
			}
			luaTrace("screenCenter: Object " + obj + " doesn't exist!", false, false, FlxColor.RED);
		});
		Lua_helper.add_callback(lua, "objectsOverlap", function(obj1:String, obj2:String) {
			var namesArray:Array<String> = [obj1, obj2];
			var objectsArray:Array<FlxSprite> = [];
			for (i in 0...namesArray.length)
			{
				var real = PlayState.instance.getLuaObject(namesArray[i]);
				if(real!=null) {
					objectsArray.push(real);
				} else {
					objectsArray.push(Reflect.getProperty(getInstance(), namesArray[i]));
				}
			}

			if(!objectsArray.contains(null) && FlxG.overlap(objectsArray[0], objectsArray[1]))
			{
				return true;
			}
			return false;
		});
		Lua_helper.add_callback(lua, "getPixelColor", function(obj:String, x:Int, y:Int) {
			var killMe:Array<String> = obj.split('.');
			var spr:FlxSprite = getObjectDirectly(killMe[0]);
			if(killMe.length > 1) {
				spr = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
			}

			if(spr != null)
			{
				if(spr.framePixels != null) spr.framePixels.getPixel32(x, y);
				return spr.pixels.getPixel32(x, y);
			}
			return 0;
		});
		Lua_helper.add_callback(lua, "getRandomInt", function(min:Int, max:Int = FlxMath.MAX_VALUE_INT, exclude:String = '') {
			var excludeArray:Array<String> = exclude.split(',');
			var toExclude:Array<Int> = [];
			for (i in 0...excludeArray.length)
			{
				if (exclude == '' && CompatEngine.compatMode()) break;
				toExclude.push(Std.parseInt(excludeArray[i].trim()));
			}
			return FlxG.random.int(min, max, toExclude);
		});
		Lua_helper.add_callback(lua, "getRandomFloat", function(min:Float, max:Float = 1, exclude:String = '') {
			var excludeArray:Array<String> = exclude.split(',');
			var toExclude:Array<Float> = [];
			for (i in 0...excludeArray.length)
			{
				if (exclude == '' && CompatEngine.compatMode()) break;
				toExclude.push(Std.parseFloat(excludeArray[i].trim()));
			}
			return FlxG.random.float(min, max, toExclude);
		});
		Lua_helper.add_callback(lua, "getRandomBool", function(chance:Float = 50) {
			return FlxG.random.bool(chance);
		});
		Lua_helper.add_callback(lua, "startDialogue", function(dialogueFile:String, music:String = null) {
			var path:String;
			#if MODS_ALLOWED
			path = Paths.modsJson(Paths.formatToSongPath(PlayState.SONG.song) + '/' + dialogueFile);
			if(!FileSystem.exists(path))
			#end
				path = Paths.json(Paths.formatToSongPath(PlayState.SONG.song) + '/' + dialogueFile);

			luaTrace('startDialogue: Trying to load dialogue: ' + path);

			#if MODS_ALLOWED
			if(FileSystem.exists(path))
			#else
			if(Assets.exists(path))
			#end
			{
				var shit:DialogueFile = DialogueBoxPsych.parseDialogue(path);
				if(shit.dialogue.length > 0) {
					PlayState.instance.startDialogue(shit, music);
					luaTrace('startDialogue: Successfully loaded dialogue', false, false, FlxColor.GREEN);
					return true;
				} else {
					luaTrace('startDialogue: Your dialogue file is badly formatted!', false, false, FlxColor.RED);
				}
			} else {
				luaTrace('startDialogue: Dialogue file not found', false, false, FlxColor.RED);
				if(PlayState.instance.endingSong) {
					PlayState.instance.endSong();
				} else {
					PlayState.instance.startCountdown();
				}
			}
			return false;
		});
		Lua_helper.add_callback(lua, "startVideo", function(videoFile:String) {
			#if VIDEOS_ALLOWED
			if(FileSystem.exists(Paths.video(videoFile))) {
				PlayState.instance.startVideo(videoFile);
				return true;
			} else {
				luaTrace('startVideo: Video file not found: ' + videoFile, false, false, FlxColor.RED);
			}
			return false;

			#else
			if(PlayState.instance.endingSong) {
				PlayState.instance.endSong();
			} else {
				PlayState.instance.startCountdown();
			}
			return true;
			#end
		});

		Lua_helper.add_callback(lua, "playMusic", function(sound:String, volume:Float = 1, loop:Bool = false) {
			FlxG.sound.playMusic(Paths.music(sound), volume, loop);
		});
		Lua_helper.add_callback(lua, "playSound", function(sound:String, volume:Float = 1, ?tag:String = null) {
			if(tag != null && tag.length > 0) {
				tag = tag.replace('.', '');
				if(PlayState.instance.modchartSounds.exists(tag)) {
					PlayState.instance.modchartSounds.get(tag).stop();
				}
				PlayState.instance.modchartSounds.set(tag, FlxG.sound.play(Paths.sound(sound), volume, false, function() {
					PlayState.instance.modchartSounds.remove(tag);
					PlayState.instance.callOnScripts('onSoundFinished', [tag]);
				}));
				return;
			}
			FlxG.sound.play(Paths.sound(sound), volume);
		});
		Lua_helper.add_callback(lua, "stopSound", function(tag:String) {
			if(tag != null && tag.length > 1 && PlayState.instance.modchartSounds.exists(tag)) {
				PlayState.instance.modchartSounds.get(tag).stop();
				PlayState.instance.modchartSounds.remove(tag);
			}
		});
		Lua_helper.add_callback(lua, "pauseSound", function(tag:String) {
			if(tag != null && tag.length > 1 && PlayState.instance.modchartSounds.exists(tag)) {
				PlayState.instance.modchartSounds.get(tag).pause();
			}
		});
		Lua_helper.add_callback(lua, "resumeSound", function(tag:String) {
			if(tag != null && tag.length > 1 && PlayState.instance.modchartSounds.exists(tag)) {
				PlayState.instance.modchartSounds.get(tag).play();
			}
		});
		Lua_helper.add_callback(lua, "soundFadeIn", function(tag:String, duration:Float, fromValue:Float = 0, toValue:Float = 1) {
			if(tag == null || tag.length < 1) {
				FlxG.sound.music.fadeIn(duration, fromValue, toValue);
			} else if(PlayState.instance.modchartSounds.exists(tag)) {
				PlayState.instance.modchartSounds.get(tag).fadeIn(duration, fromValue, toValue);
			}

		});
		Lua_helper.add_callback(lua, "soundFadeOut", function(tag:String, duration:Float, toValue:Float = 0) {
			if(tag == null || tag.length < 1) {
				FlxG.sound.music.fadeOut(duration, toValue);
			} else if(PlayState.instance.modchartSounds.exists(tag)) {
				PlayState.instance.modchartSounds.get(tag).fadeOut(duration, toValue);
			}
		});
		Lua_helper.add_callback(lua, "soundFadeCancel", function(tag:String) {
			if(tag == null || tag.length < 1) {
				if(FlxG.sound.music.fadeTween != null) {
					FlxG.sound.music.fadeTween.cancel();
				}
			} else if(PlayState.instance.modchartSounds.exists(tag)) {
				var theSound:FlxSound = PlayState.instance.modchartSounds.get(tag);
				if(theSound.fadeTween != null) {
					theSound.fadeTween.cancel();
					PlayState.instance.modchartSounds.remove(tag);
				}
			}
		});
		Lua_helper.add_callback(lua, "getSoundVolume", function(tag:String) {
			if(tag == null || tag.length < 1) {
				if(FlxG.sound.music != null) {
					return FlxG.sound.music.volume;
				}
			} else if(PlayState.instance.modchartSounds.exists(tag)) {
				return PlayState.instance.modchartSounds.get(tag).volume;
			}
			return 0;
		});
		Lua_helper.add_callback(lua, "setSoundVolume", function(tag:String, value:Float) {
			if(tag == null || tag.length < 1) {
				if(FlxG.sound.music != null) {
					FlxG.sound.music.volume = value;
				}
			} else if(PlayState.instance.modchartSounds.exists(tag)) {
				PlayState.instance.modchartSounds.get(tag).volume = value;
			}
		});
		Lua_helper.add_callback(lua, "getSoundTime", function(tag:String) {
			if(tag != null && tag.length > 0 && PlayState.instance.modchartSounds.exists(tag)) {
				return PlayState.instance.modchartSounds.get(tag).time;
			}
			return 0;
		});
		Lua_helper.add_callback(lua, "setSoundTime", function(tag:String, value:Float) {
			if(tag != null && tag.length > 0 && PlayState.instance.modchartSounds.exists(tag)) {
				var theSound:FlxSound = PlayState.instance.modchartSounds.get(tag);
				if(theSound != null) {
					var wasResumed:Bool = theSound.playing;
					theSound.pause();
					theSound.time = value;
					if(wasResumed) theSound.play();
				}
			}
		});

		Lua_helper.add_callback(lua, "getSoundPitch", function(tag:String) {
			if(tag != null && tag.length > 0 && PlayState.instance.modchartSounds.exists(tag)) {
				#if FLX_PITCH
				return PlayState.instance.modchartSounds.get(tag).pitch;
				#else
				return 1.0;
				#end
			}
			return 1;
		});
		Lua_helper.add_callback(lua, "setSoundPitch", function(tag:String, value:Float, ?doPause:Bool = false) {
			if(tag != null && tag.length > 0 && PlayState.instance.modchartSounds.exists(tag)) {
				var theSound:FlxSound = PlayState.instance.modchartSounds.get(tag);
				#if FLX_PITCH
				theSound.pitch = value;
				#end
				return true;
			}
			return false;
		});

		Lua_helper.add_callback(lua, "debugPrint", function(text:Dynamic = '', ?color:String = 'WHITE') {
			PlayState.instance.addTextToDebug('$text', FlxColor.fromString(color));
		});
		
		Lua_helper.add_callback(lua, "close", function() {
			closed = true;
			return closed;
		});

		Lua_helper.add_callback(lua, "changePresence", function(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float) {
			#if desktop
			DiscordClient.changePresence(details, state, smallImageKey, hasStartTimestamp, endTimestamp);
			#end
		});
		Lua_helper.add_callback(lua, "changeDiscordPresence", function(details:String, state:Null<String>, ?smallImageKey:String, ?hasStartTimestamp:Bool, ?endTimestamp:Float) {
			#if desktop
			DiscordClient.changePresence(details, state, smallImageKey, hasStartTimestamp, endTimestamp);
			#end
		});
		Lua_helper.add_callback(lua, "changeDiscordClientID", function(?newID:String = null) {
			if (newID == null) newID = DiscordClient._defaultID;
			DiscordClient.clientID = newID;
		});
		Achievements.addLuaCallbacks(lua);


		// LUA TEXTS
		Lua_helper.add_callback(lua, "makeLuaText", function(tag:String, text:String, width:Int, x:Float, y:Float) {
			tag = tag.replace('.', '');
			resetTextTag(tag);
			var leText:ModchartText = new ModchartText(x, y, text, width);
			var texts = getStateModchartTexts();
			if(texts != null) texts.set(tag, leText);
		});

		Lua_helper.add_callback(lua, "setTextString", function(tag:String, text:String) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				obj.text = text;
				return true;
			}
			luaTrace("setTextString: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "setTextSize", function(tag:String, size:Int) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				obj.size = size;
				return true;
			}
			luaTrace("setTextSize: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "setTextWidth", function(tag:String, width:Float) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				obj.fieldWidth = width;
				return true;
			}
			luaTrace("setTextWidth: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		// 0.7.3+/1.0.4: setTextHeight
		Lua_helper.add_callback(lua, "setTextHeight", function(tag:String, height:Float) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				// 此 flixel 分支没有 fieldHeight；尽量设置底层 TextField 高度。
				// English: this flixel fork has no fieldHeight — best-effort on the TextField height.
				if (obj.textField != null)
				{
					obj.textField.autoSize = openfl.text.TextFieldAutoSize.NONE;
					obj.textField.height = height;
				}
				return true;
			}
			luaTrace("setTextHeight: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "setTextBorder", function(tag:String, size:Float, color:String, ?style:String = 'outline') {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				var colorNum:Int = Std.parseInt(color);
				if(!color.startsWith('0x')) colorNum = Std.parseInt('0xff' + color);

				obj.borderSize = size;
				obj.borderColor = colorNum;
				obj.borderStyle = switch(style.trim().toLowerCase()) {
					case 'outline': OUTLINE;
					case 'fast': OUTLINE_FAST;
					case 'shadow': SHADOW;
					default: OUTLINE;
				}
				return true;
			}
			luaTrace("setTextBorder: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "setTextColor", function(tag:String, color:String) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				var colorNum:Int = Std.parseInt(color);
				if(!color.startsWith('0x')) colorNum = Std.parseInt('0xff' + color);

				obj.color = colorNum;
				return true;
			}
			luaTrace("setTextColor: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "setTextFont", function(tag:String, newFont:String) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				obj.font = Paths.font(newFont);
				return true;
			}
			luaTrace("setTextFont: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "setTextItalic", function(tag:String, italic:Bool) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				obj.italic = italic;
				return true;
			}
			luaTrace("setTextItalic: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});
		Lua_helper.add_callback(lua, "setTextAlignment", function(tag:String, alignment:String = 'left') {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				obj.alignment = LEFT;
				switch(alignment.trim().toLowerCase())
				{
					case 'right':
						obj.alignment = RIGHT;
					case 'center':
						obj.alignment = CENTER;
				}
				return true;
			}
			luaTrace("setTextAlignment: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});

		Lua_helper.add_callback(lua, "setTextAutoSize", function(tag:String, value:Bool) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				obj.autoSize = value;
				return true;
			}
			luaTrace("setTextAutoSize: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return false;
		});

		Lua_helper.add_callback(lua, "getTextString", function(tag:String) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null && obj.text != null)
			{
				return obj.text;
			}
			luaTrace("getTextString: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
		});
		Lua_helper.add_callback(lua, "getTextSize", function(tag:String) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				return obj.size;
			}
			luaTrace("getTextSize: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return -1;
		});
		Lua_helper.add_callback(lua, "getTextFont", function(tag:String) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				return obj.font;
			}
			luaTrace("getTextFont: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			Lua.pushnil(lua);
			return null;
		});
		Lua_helper.add_callback(lua, "getTextWidth", function(tag:String) {
			var obj:FlxText = getTextObject(tag);
			if(obj != null)
			{
				return obj.fieldWidth;
			}
			luaTrace("getTextWidth: Object " + tag + " doesn't exist!", false, false, FlxColor.RED);
			return 0;
		});

		Lua_helper.add_callback(lua, "addLuaText", function(tag:String) {
			var texts = getStateModchartTexts();
			if(texts != null && texts.exists(tag)) {
				var shit:ModchartText = texts.get(tag);
				if(!shit.wasAdded) {
					getTargetInstance().add(shit);
					shit.wasAdded = true;
				}
			}
		});
		Lua_helper.add_callback(lua, "removeLuaText", function(tag:String, destroy:Bool = true) {
			var texts = getStateModchartTexts();
			if(texts == null || !texts.exists(tag)) {
				return;
			}

			var pee:ModchartText = texts.get(tag);
			if(destroy) {
				pee.kill();
			}

			if(pee.wasAdded) {
				getTargetInstance().remove(pee, true);
				pee.wasAdded = false;
			}

			if(destroy) {
				pee.destroy();
				texts.remove(tag);
			}
		});

		Lua_helper.add_callback(lua, "initSaveData", function(name:String, ?folder:String = 'psychenginemods') {
			var saves = getStateModchartSaves();
			if(saves != null && !saves.exists(name))
			{
				var save:FlxSave = new FlxSave();
				save.bind(name, folder);
				saves.set(name, save);
				return;
			}
			luaTrace('initSaveData: Save file already initialized: ' + name);
		});
		Lua_helper.add_callback(lua, "flushSaveData", function(name:String) {
			var saves = getStateModchartSaves();
			if(saves != null && saves.exists(name))
			{
				saves.get(name).flush();
				return;
			}
			luaTrace('flushSaveData: Save file not initialized: ' + name, false, false, FlxColor.RED);
		});
		Lua_helper.add_callback(lua, "getDataFromSave", function(name:String, field:String, ?defaultValue:Dynamic = null) {
			var saves = getStateModchartSaves();
			if(saves != null && saves.exists(name))
			{
				var retVal:Dynamic = Reflect.field(saves.get(name).data, field);
				return retVal;
			}
			luaTrace('getDataFromSave: Save file not initialized: ' + name, false, false, FlxColor.RED);
			return defaultValue;
		});
		Lua_helper.add_callback(lua, "setDataFromSave", function(name:String, field:String, value:Dynamic) {
			var saves = getStateModchartSaves();
			if(saves != null && saves.exists(name))
			{
				Reflect.setField(saves.get(name).data, field, value);
				return;
			}
			luaTrace('setDataFromSave: Save file not initialized: ' + name, false, false, FlxColor.RED);
		});

		// 0.7.3+/1.0.4: eraseSaveData
		Lua_helper.add_callback(lua, "eraseSaveData", function(name:String) {
			var saves = getStateModchartSaves();
			if(saves != null && saves.exists(name))
			{
				var save:FlxSave = saves.get(name);
				if (save != null) save.erase();
				return;
			}
			luaTrace('eraseSaveData: Save file not initialized: ' + name, false, false, FlxColor.RED);
		});

		Lua_helper.add_callback(lua, "checkFileExists", function(filename:String, ?absolute:Bool = false) {
			#if MODS_ALLOWED
			if(absolute)
			{
				return FileSystem.exists(filename);
			}

			var path:String = Paths.modFolders(filename);
			if(FileSystem.exists(path))
			{
				return true;
			}
			return FileSystem.exists(Paths.getPath('assets/$filename', TEXT));
			#else
			if(absolute)
			{
				return Assets.exists(filename);
			}
			return Assets.exists(Paths.getPath('assets/$filename', TEXT));
			#end
		});
		Lua_helper.add_callback(lua, "saveFile", function(path:String, content:String, ?absolute:Bool = false)
		{
			try {
				if(!absolute)
					File.saveContent(Paths.mods(path), content);
				else
					File.saveContent(path, content);

				return true;
			} catch (e:Dynamic) {
				luaTrace("saveFile: Error trying to save " + path + ": " + e, false, false, FlxColor.RED);
			}
			return false;
		});
		Lua_helper.add_callback(lua, "deleteFile", function(path:String, ?ignoreModFolders:Bool = false)
		{
			try {
				#if MODS_ALLOWED
				if(!ignoreModFolders)
				{
					var lePath:String = Paths.modFolders(path);
					if(FileSystem.exists(lePath))
					{
						FileSystem.deleteFile(lePath);
						return true;
					}
				}
				#end

				var lePath:String = Paths.getPath(path, TEXT);
				if(Assets.exists(lePath))
				{
					FileSystem.deleteFile(lePath);
					return true;
				}
			} catch (e:Dynamic) {
				luaTrace("deleteFile: Error trying to delete " + path + ": " + e, false, false, FlxColor.RED);
			}
			return false;
		});
		Lua_helper.add_callback(lua, "getTextFromFile", function(path:String, ?ignoreModFolders:Bool = false) {
			return Paths.getTextFromFile(path, ignoreModFolders);
		});

		// DEPRECATED, DONT MESS WITH THESE SHITS, ITS JUST THERE FOR BACKWARD COMPATIBILITY
		Lua_helper.add_callback(lua, "objectPlayAnimation", function(obj:String, name:String, forced:Bool = false, ?startFrame:Int = 0) {
			luaTrace("objectPlayAnimation is deprecated! Use playAnim instead", false, true);
			if(PlayState.instance.getLuaObject(obj,false) != null) {
				PlayState.instance.getLuaObject(obj,false).animation.play(name, forced, false, startFrame);
				return true;
			}

			var spr:FlxSprite = Reflect.getProperty(getInstance(), obj);
			if(spr != null) {
				spr.animation.play(name, forced, false, startFrame);
				return true;
			}
			return false;
		});
		Lua_helper.add_callback(lua, "characterPlayAnim", function(character:String, anim:String, ?forced:Bool = false) {
			luaTrace("characterPlayAnim is deprecated! Use playAnim instead", false, true);
			switch(character.toLowerCase()) {
				case 'dad':
					if(PlayState.instance.dad.animOffsets.exists(anim))
						PlayState.instance.dad.playAnim(anim, forced);
				case 'gf' | 'girlfriend':
					if(PlayState.instance.gf != null && PlayState.instance.gf.animOffsets.exists(anim))
						PlayState.instance.gf.playAnim(anim, forced);
				default:
					if(PlayState.instance.boyfriend.animOffsets.exists(anim))
						PlayState.instance.boyfriend.playAnim(anim, forced);
			}
		});
		Lua_helper.add_callback(lua, "luaSpriteMakeGraphic", function(tag:String, width:Int, height:Int, color:String) {
			luaTrace("luaSpriteMakeGraphic is deprecated! Use makeGraphic instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				var colorNum:Int = Std.parseInt(color);
				if(!color.startsWith('0x')) colorNum = Std.parseInt('0xff' + color);

				PlayState.instance.modchartSprites.get(tag).makeGraphic(width, height, colorNum);
			}
		});
		Lua_helper.add_callback(lua, "luaSpriteAddAnimationByPrefix", function(tag:String, name:String, prefix:String, framerate:Int = 24, loop:Bool = true) {
			luaTrace("luaSpriteAddAnimationByPrefix is deprecated! Use addAnimationByPrefix instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				var cock:ModchartSprite = PlayState.instance.modchartSprites.get(tag);
				cock.animation.addByPrefix(name, prefix, framerate, loop);
				if(cock.animation.curAnim == null) {
					cock.animation.play(name, true);
				}
			}
		});
		Lua_helper.add_callback(lua, "luaSpriteAddAnimationByIndices", function(tag:String, name:String, prefix:String, indices:String, framerate:Int = 24) {
			luaTrace("luaSpriteAddAnimationByIndices is deprecated! Use addAnimationByIndices instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				var strIndices:Array<String> = indices.trim().split(',');
				var die:Array<Int> = [];
				for (i in 0...strIndices.length) {
					die.push(Std.parseInt(strIndices[i]));
				}
				var pussy:ModchartSprite = PlayState.instance.modchartSprites.get(tag);
				pussy.animation.addByIndices(name, prefix, die, '', framerate, false);
				if(pussy.animation.curAnim == null) {
					pussy.animation.play(name, true);
				}
			}
		});
		Lua_helper.add_callback(lua, "luaSpritePlayAnimation", function(tag:String, name:String, forced:Bool = false) {
			luaTrace("luaSpritePlayAnimation is deprecated! Use playAnim instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				PlayState.instance.modchartSprites.get(tag).animation.play(name, forced);
			}
		});
		Lua_helper.add_callback(lua, "setLuaSpriteCamera", function(tag:String, camera:String = '') {
			luaTrace("setLuaSpriteCamera is deprecated! Use setObjectCamera instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				PlayState.instance.modchartSprites.get(tag).cameras = [cameraFromString(camera)];
				return true;
			}
			luaTrace("Lua sprite with tag: " + tag + " doesn't exist!");
			return false;
		});
		Lua_helper.add_callback(lua, "setLuaSpriteScrollFactor", function(tag:String, scrollX:Float, scrollY:Float) {
			luaTrace("setLuaSpriteScrollFactor is deprecated! Use setScrollFactor instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				PlayState.instance.modchartSprites.get(tag).scrollFactor.set(scrollX, scrollY);
				return true;
			}
			return false;
		});
		Lua_helper.add_callback(lua, "scaleLuaSprite", function(tag:String, x:Float, y:Float) {
			luaTrace("scaleLuaSprite is deprecated! Use scaleObject instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				var shit:ModchartSprite = PlayState.instance.modchartSprites.get(tag);
				shit.scale.set(x, y);
				shit.updateHitbox();
				return true;
			}
			return false;
		});
		Lua_helper.add_callback(lua, "getPropertyLuaSprite", function(tag:String, variable:String) {
			luaTrace("getPropertyLuaSprite is deprecated! Use getProperty instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				var killMe:Array<String> = variable.split('.');
				if(killMe.length > 1) {
					var coverMeInPiss:Dynamic = Reflect.getProperty(PlayState.instance.modchartSprites.get(tag), killMe[0]);
					for (i in 1...killMe.length-1) {
						coverMeInPiss = Reflect.getProperty(coverMeInPiss, killMe[i]);
					}
					return Reflect.getProperty(coverMeInPiss, killMe[killMe.length-1]);
				}
				return Reflect.getProperty(PlayState.instance.modchartSprites.get(tag), variable);
			}
			return null;
		});
		Lua_helper.add_callback(lua, "setPropertyLuaSprite", function(tag:String, variable:String, value:Dynamic) {
			luaTrace("setPropertyLuaSprite is deprecated! Use setProperty instead", false, true);
			if(PlayState.instance.modchartSprites.exists(tag)) {
				var killMe:Array<String> = variable.split('.');
				if(killMe.length > 1) {
					var coverMeInPiss:Dynamic = Reflect.getProperty(PlayState.instance.modchartSprites.get(tag), killMe[0]);
					for (i in 1...killMe.length-1) {
						coverMeInPiss = Reflect.getProperty(coverMeInPiss, killMe[i]);
					}
					Reflect.setProperty(coverMeInPiss, killMe[killMe.length-1], value);
					return true;
				}
				Reflect.setProperty(PlayState.instance.modchartSprites.get(tag), variable, value);
				return true;
			}
			luaTrace("setPropertyLuaSprite: Lua sprite with tag: " + tag + " doesn't exist!");
			return false;
		});
		Lua_helper.add_callback(lua, "musicFadeIn", function(duration:Float, fromValue:Float = 0, toValue:Float = 1) {
			FlxG.sound.music.fadeIn(duration, fromValue, toValue);
			luaTrace('musicFadeIn is deprecated! Use soundFadeIn instead.', false, true);

		});
		Lua_helper.add_callback(lua, "musicFadeOut", function(duration:Float, toValue:Float = 0) {
			FlxG.sound.music.fadeOut(duration, toValue);
			luaTrace('musicFadeOut is deprecated! Use soundFadeOut instead.', false, true);
		});

		// Other stuff
		Lua_helper.add_callback(lua, "stringStartsWith", function(str:String, start:String) {
			return str.startsWith(start);
		});
		Lua_helper.add_callback(lua, "stringEndsWith", function(str:String, end:String) {
			return str.endsWith(end);
		});
		Lua_helper.add_callback(lua, "stringSplit", function(str:String, split:String) {
			return str.split(split);
		});
		Lua_helper.add_callback(lua, "stringTrim", function(str:String) {
			return str.trim();
		});
		
		Lua_helper.add_callback(lua, "directoryFileList", function(folder:String) {
			var list:Array<String> = [];
			#if sys
			if(FileSystem.exists(folder)) {
				for (folder in FileSystem.readDirectory(folder)) {
					if (!list.contains(folder)) {
						list.push(folder);
					}
				}
			}
			#end
			return list;
		});

		// ── Runtime window icon ──
		Lua_helper.add_callback(lua, "setModWindowIcon", function(?modFolder:String) {
			#if (desktop && MODS_ALLOWED)
			backend.ModConfig.setWindowIcon(modFolder);
			#end
		});

		// ── Online Lua API ──
		// `online.backend.OnlineScriptFunctions.implement(this);` registers 18 online Lua callbacks
		// plus the `online` / `localPlay` / `leftSide` globals. FunkinLua has no `*Functions`
		// classes, so the call site below is placed after the last callback registration and
		// before the script's dofile: top-level script code may read those globals or call the
		// online API directly, so a later call site would mean they were never wired up.
		// Keeping it here also means the globals exist for the whole script body.
		// The call itself is compiled only when ONLINE_ALLOWED is defined.
		#if ONLINE_ALLOWED
		online.backend.OnlineScriptFunctions.implement(this);
		#end

		try{
			var result:Dynamic = LuaL.dofile(lua, script);
			var resultStr:String = Lua.tostring(lua, result);
			if(resultStr != null && result != 0) {
				TraceManager.error('trace.lua.scriptError', 'Error on lua script! {}', [resultStr]);
				backend.Dialog.show(Language.get('script_lua_error', 'Error on lua script!'), resultStr, 'Error');
				//luaTrace('Error loading lua script: "$script"\n' + resultStr, true, false, FlxColor.RED);
				lua = null;
				return;
			}
		} catch(e:Dynamic) {
			TraceManager.error('trace.lua.loadException', '{}', [e]);
			return;
		}

		// 0.7.3 兼容：onCreate 执行期间必须已经位于 PlayState.luaArray，
		// 这样 HScript 的 createGlobalCallback 才能把 parseJson 等回调注册到当前 Lua 脚本。
		// 这里临时加入，onCreate 结束后移除，由外部调用方负责正式入列，避免重复添加。
		var __tempLuaPush:Bool = false;
		if (PlayState.instance != null && !PlayState.instance.luaArray.contains(this))
		{
			PlayState.instance.luaArray.push(this);
			__tempLuaPush = true;
		}
		call('onCreate', []);
		if (__tempLuaPush && PlayState.instance != null && PlayState.instance.luaArray.contains(this))
			PlayState.instance.luaArray.remove(this);
		#end
	}

	#if LUA_ALLOWED
	/**
	 * 初始化 Lua require() 支持。
	 * English: Initialize Lua require() support.
	 *
	 * 原理：在 package.loaders / package.searchers 最前面插入一个自定义 searcher。
	 * How it works: installs a custom searcher at the front of
	 * package.loaders / package.searchers.
	 * 搜索根目录按优先级为：当前脚本所在目录 → 当前模组的 lua/ 与 scripts/ →
	 * 全局模组的 lua/ 与 scripts/ → mods/lua/ 与 mods/scripts/ → assets 内置 lua/ 与 scripts/。
	 * Search roots, in priority order: the requiring script's folder → the active
	 * mod's lua/ & scripts/ → global mods' lua/ & scripts/ → mods/lua/ & mods/scripts/
	 * → built-in assets lua/ & scripts/.
	 * 模块名按 Lua 惯例把 "." 转成 "/" 再查找 `?.lua` 与 `?/init.lua`。
	 * Module names follow Lua conventions: "." becomes "/", then `?.lua` and
	 * `?/init.lua` are tried.
	 * 模块 chunk 由 Haxe 侧用 FileSystem 读取并 loadbuffer 编译，缓存由标准
	 * package.loaded 负责（require 同一个模块只执行一次）。
	 * Chunks are read via FileSystem and compiled with loadbuffer on the Haxe side;
	 * standard package.loaded caching means a module executes only once.
	 */
	function setupRequireSupport():Void {
		if (lua == null) return;
		try {
			__requireUid++;
			var uid:Int = __requireUid;
			var resolveName:String = '__psychLuaRequireResolve_' + uid;
			var chunksName:String = '__psychLuaRequireChunks_' + uid;
			__requireResolveName = resolveName;
			__requireChunksName = chunksName;

			// 1) 收集模块搜索根目录（require 与 import 共用，只保留存在的目录）
			//    English: collect module search roots (shared by require & import; keep existing dirs only)
			var existing:Array<String> = collectLuaSearchRoots();
			if (existing.length == 0) return;

			// 2) 创建存放编译后模块 chunk 的 Lua 表
			//    English: create the Lua table that stores compiled module chunks
			Lua.createtable(lua, 0, 0);
			Lua.setglobal(lua, chunksName);

			// 3) 注册解析回调。名字按实例唯一，避免 Lua_helper 全局静态 map 串台。
			//    English: register the resolver callback with a unique per-instance
			//    name so instances never collide in Lua_helper's global static map.
			Lua_helper.add_callback(lua, resolveName, function(modName:String):Dynamic
			{
				return resolveRequireModule(modName, existing, chunksName);
			});

			// 4) 安装 searcher：Lua 侧包装调用 Haxe 解析回调，再取出 chunk 返回给 require。
			//    兼容 LuaJIT 5.1（package.loaders）与 Lua 5.2+（package.searchers）。
			//    English: install the searcher — a Lua wrapper calls the Haxe resolver
			//    and hands the chunk back to require. Supports LuaJIT 5.1
			//    (package.loaders) and Lua 5.2+ (package.searchers).
			var searcherCode:String =
				'if package == nil then package = {} end;' +
				'package.searchers = package.searchers or package.loaders;' +
				'package.loaders = package.loaders or package.searchers;' +
				'local l = package.loaders;' +
				'if l ~= nil then ' +
					'__psychLuaRequire' + uid + ' = function(modname) ' +
						'local ref = ' + resolveName + '(modname); ' +
						'if ref == nil then return nil end; ' +
						'local loader = ' + chunksName + '[ref]; ' +
						'if loader == nil then return nil end; ' +
						'return loader; ' +
					'end; ' +
					'table.insert(l, 1, __psychLuaRequire' + uid + '); ' +
				'end;';
			var status:Int = LuaL.dostring(lua, searcherCode);
			if (status != 0)
			{
				var err:String = Lua.tostring(lua, -1);
				Lua.pop(lua, 1);
				TraceManager.warn('trace.lua.requireSetupFailed', 'Failed to install require searcher: {}', [err]);
				return;
			}

			// 5) 把搜索根追加进 package.path，作为标准 loader / loadfile 的兜底
			//    English: append search roots to package.path as a fallback for
			//    the standard loaders / loadfile.
			var pathParts:Array<String> = [];
			for (r in existing)
			{
				var norm:String = StringTools.replace(r, '\\', '/');
				pathParts.push(norm + '/?.lua');
				pathParts.push(norm + '/?/init.lua');
			}
			Lua.getglobal(lua, 'package');
			if (Lua.type(lua, -1) == Lua.LUA_TTABLE)
			{
				Lua.getfield(lua, -1, 'path');
				var oldPath:String = (Lua.type(lua, -1) == Lua.LUA_TSTRING) ? Lua.tostring(lua, -1) : '';
				Lua.pop(lua, 1);
				var newPath:String = pathParts.join(';');
				if (oldPath != null && oldPath.length > 0) newPath += ';' + oldPath;
				Lua.pushstring(lua, newPath);
				Lua.setfield(lua, -2, 'path');
			}
			Lua.pop(lua, 1);

			TraceManager.info('trace.lua.requireReady', 'require support ready for {} ({} roots)', [scriptName, existing.length]);
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.lua.requireSetupError', 'Failed to setup require: {}', [e]);
		}
	}

	/**
	 * 解析 require 的模块名：在搜索根里找 `?.lua` / `?/init.lua`，
	 * 找到后编译成 Lua chunk 存入 chunks 表，返回该 chunk 在表中的引用 key。
	 * 找不到返回 null（require 会继续尝试后面的 searcher）。
	 * English: Resolve a require module name — look for `?.lua` / `?/init.lua`
	 * under the search roots, compile it into a Lua chunk stored in the chunks
	 * table, and return the chunk's key. Returns null when not found (require
	 * then falls through to the next searcher).
	 */
	function resolveRequireModule(modName:String, roots:Array<String>, chunksName:String):Dynamic {
		probeRequireResolves++; // F8 probe: a require() missed package.loaded and searched the filesystem
		if (modName == null || modName.length == 0) return null;
		// 路径穿越保护：Lua 标准 require 也不允许 ".."，这里直接拦截
		// English: path-traversal guard — standard require also rejects ".."
		if (modName.indexOf('..') != -1)
		{
			luaTrace("require: module name '" + modName + "' contains '..' and was blocked", false, false, FlxColor.RED);
			return null;
		}
		var relPath:String = StringTools.replace(modName, '.', '/');
		for (root in roots)
		{
			for (candidate in [root + '/' + relPath + '.lua', root + '/' + relPath + '/init.lua'])
			{
				#if sys
				if (!FileSystem.exists(candidate)) continue;
				var content:String = File.getContent(candidate);
				#else
				if (!Assets.exists(candidate)) continue;
				var content:String = Assets.getText(candidate);
				#end
				var status:Int = LuaL.loadbuffer(lua, content, haxe.io.Bytes.ofString(content).length, candidate);
				if (status != 0)
				{
					var err:String = Lua.tostring(lua, -1);
					Lua.pop(lua, 1);
					luaTrace("require: failed to compile '" + modName + "': " + err, false, false, FlxColor.RED);
					return null;
				}
				__requireChunkRef++;
				var ref:Int = __requireChunkRef;
				// [chunk] → [chunk, table, key, chunkcopy] → settable → [chunk, table] → pop → []
				// English: stack flow — getglobal pushes the table, then key + chunk copy,
				// settable stores it, then we pop the table & chunk back off.
				Lua.getglobal(lua, chunksName);
				Lua.pushnumber(lua, ref);
				Lua.pushvalue(lua, -3);
				Lua.settable(lua, -3);
				Lua.pop(lua, 2);
				return ref;
			}
		}
		return null;
	}

	/**
	 * 收集 Lua 文件搜索根目录（require 与 import 共用）。
	 * 按优先级：当前脚本所在目录 → 当前模组的 lua/ 与 scripts/ →
	 * 全局模组的 lua/ 与 scripts/ → mods/lua/ 与 mods/scripts/ →
	 * assets 内置 lua/ 与 scripts/。只保留真实存在的目录。
	 * English: Collect Lua file search roots (shared by require & import).
	 * Priority: requiring script's folder → active mod's lua/ & scripts/ →
	 * global mods' lua/ & scripts/ → mods/lua/ & mods/scripts/ →
	 * built-in assets lua/ & scripts/. Only existing directories are kept.
	 */
	function collectLuaSearchRoots():Array<String> {
		var roots:Array<String> = [];
		var scriptFolder:String = Path.directory(scriptName);
		if (scriptFolder != null && scriptFolder.length > 0)
			roots.push(scriptFolder);

		#if MODS_ALLOWED
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
		{
			roots.push(Paths.mods(Paths.currentModDirectory + '/lua/'));
			roots.push(Paths.mods(Paths.currentModDirectory + '/scripts/'));
		}
		for (mod in Paths.getGlobalMods())
		{
			roots.push(Paths.mods(mod + '/lua/'));
			roots.push(Paths.mods(mod + '/scripts/'));
		}
		roots.push(Paths.mods('lua/'));
		roots.push(Paths.mods('scripts/'));
		#end
		roots.push(Paths.getPreloadPath('lua/'));
		roots.push(Paths.getPreloadPath('scripts/'));

		var existing:Array<String> = [];
		for (r in roots)
		{
			if (r != null && r.length > 0 && !existing.contains(r) && FileSystem.exists(r))
				existing.push(r);
		}
		return existing;
	}

	/**
	 * 初始化 Lua import() 支持。
	 * English: Initialize Lua import() support.
	 *
	 * import 语义 = include：加载目标文件并立即执行（每次调用都会重新执行，
	 * 不会像 require 那样走 package.loaded 缓存），并返回文件的返回值
	 * （Lua 多返回值也会原样保留）。路径解析规则：
	 * - 绝对路径或带分隔符的路径（"lib/utils.lua"、"../shared/util.lua"）
	 *   按文件路径解析，允许相对脚本目录的 "../"；
	 * - 纯模块名（"lib.utils"）按 require 的规则补 ".lua" / "/init.lua"。
	 * 搜索根与 require 相同（脚本目录 → 模组 lua/scripts → assets）。
	 * English: import semantics = include — load the target file and run it
	 * immediately (re-executed on every call, no package.loaded caching),
	 * returning the file's return values (multiple returns are preserved).
	 * Path rules:
	 * - Absolute paths or paths with separators ("lib/utils.lua",
	 *   "../shared/util.lua") are resolved as file paths; "../" relative to the
	 *   script folder is allowed;
	 * - Bare module names ("lib.utils") resolve like require, trying
	 *   ".lua" then "/init.lua".
	 * Search roots match require (script folder → mod lua/scripts → assets).
	 */
	function setupImportSupport():Void {
		if (lua == null) return;
		try {
			__importUid++;
			var uid:Int = __importUid;
			var resolveName:String = '__psychLuaImportResolve_' + uid;
			__importResolveName = resolveName;
			var roots:Array<String> = collectLuaSearchRoots();
			if (roots.length == 0) return;

			// 解析回调按实例唯一命名，避免 Lua_helper 全局静态 map 串台
			// English: unique per-instance resolver name avoids Lua_helper map collisions
			Lua_helper.add_callback(lua, resolveName, function(path:String):Dynamic
			{
				return resolveImportFile(path, roots);
			});

			// import 是纯 Lua 包装：解析出完整路径后交给标准 dofile 加载执行。
			// dofile 会返回 chunk 的全部返回值，错误也会正常向上抛出。
			// English: import is a pure-Lua wrapper — resolve the full path, then
			// let standard dofile load & run it. dofile returns all chunk return
			// values and propagates errors normally.
			var importCode:String =
				'import = function(path) ' +
					'local full = ' + resolveName + '(path); ' +
					'if full == nil then ' +
						"error('import: file not found: ' .. tostring(path)); " +
					'end; ' +
					'return dofile(full); ' +
				'end;';
			var status:Int = LuaL.dostring(lua, importCode);
			if (status != 0)
			{
				var err:String = Lua.tostring(lua, -1);
				Lua.pop(lua, 1);
				TraceManager.warn('trace.lua.importSetupFailed', 'Failed to install import: {}', [err]);
				return;
			}
			TraceManager.info('trace.lua.importReady', 'import support ready for {}', [scriptName]);
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.lua.importSetupError', 'Failed to setup import: {}', [e]);
		}
	}

	/**
	 * 解析 import 的目标文件，返回完整路径；找不到返回 null。
	 * English: Resolve an import target file to its full path; null when not found.
	 */
	function resolveImportFile(path:String, roots:Array<String>):String {
		probeImportResolves++; // F8 probe: import() always re-resolves and re-executes (include semantics)
		if (path == null || path.length == 0) return null;
		#if sys
		// 以 .lua 结尾 / 绝对路径 / 带分隔符的路径 → 按文件路径解析；
		// 否则（如 "lib.utils"）按模块名补 ".lua" 与 "/init.lua"。
		// English: paths ending in .lua, absolute paths, or paths with separators
		// are resolved as files; otherwise ("lib.utils") treat as a module name
		// and try ".lua" / "/init.lua".
		var isPath:Bool = path.endsWith('.lua') || Path.isAbsolute(path) || path.indexOf('/') != -1 || path.indexOf('\\') != -1;
		if (isPath)
		{
			var candidates:Array<String> = [path];
			if (!path.endsWith('.lua'))
				candidates.push(path + '.lua');
			for (c in candidates)
			{
				if (FileSystem.exists(c)) return c;
				for (root in roots)
				{
					var full:String = root + '/' + c;
					if (FileSystem.exists(full)) return full;
				}
			}
		}
		else
		{
			var relPath:String = StringTools.replace(path, '.', '/');
			for (root in roots)
			{
				for (candidate in [root + '/' + relPath + '.lua', root + '/' + relPath + '/init.lua'])
				{
					if (FileSystem.exists(candidate)) return candidate;
				}
			}
		}
		#end
		return null;
	}
	#end

	public static function isOfTypes(value:Any, types:Array<Dynamic>)
	{
		for (type in types)
		{
			if(Std.isOfType(value, type)) return true;
		}
		return false;
	}

	#if HSCRIPT_ALLOWED
	public function initHaxeModule()
	{
		if(hscript == null)
		{
			TraceManager.info('trace.lua.haxeInterpInit', 'initializing haxe interp for: {}', [scriptName]);
			hscript = new HScript(); //TO DO: Fix issue with 2 scripts not being able to use the same variable names
			hscript.parentLua = this; // 0.7.3+/1.0.4: parentLua 全局
		}
	}
	#end
	public function addLocalCallback(name:String, myFunction:Dynamic) {
    callbacks.set(name, myFunction);
    #if LUA_ALLOWED
    if (nilCallbacks != null) nilCallbacks.remove(name); // see nilCallbacks
    Lua_helper.add_callback(lua, name, myFunction); 
    #end
}
	public static function new_setVarInArray(instance:Dynamic, variable:String, value:Dynamic, allowMaps:Bool = false):Any
	{
		var stateVars = getStateVars();
		var splitProps:Array<String> = variable.split('[');
		if(splitProps.length > 1)
		{
			var target:Dynamic = null;
			if(stateVars != null && stateVars.exists(splitProps[0]))
			{
				var retVal:Dynamic = stateVars.get(splitProps[0]);
				if(retVal != null)
					target = retVal;
			}
			else target = Reflect.getProperty(instance, splitProps[0]);

			for (i in 1...splitProps.length)
			{
				var j:Dynamic = splitProps[i].substr(0, splitProps[i].length - 1);
				if(i >= splitProps.length-1) //Last array
					target[j] = value;
				else //Anything else
					target = target[j];
			}
			return target;
		}

		if(allowMaps && isMap(instance))
		{
			//trace(instance);
			instance.set(variable, value);
			return value;
		}

		if(stateVars != null && stateVars.exists(variable))
		{
			stateVars.set(variable, value);
			return value;
		}
		Reflect.setProperty(instance, variable, value);
		return value;
		}
	public static function isMap(variable:Dynamic)
	{
		/*switch(Type.typeof(variable)){
			case ValueType.TClass(haxe.ds.StringMap) | ValueType.TClass(haxe.ds.ObjectMap) | ValueType.TClass(haxe.ds.IntMap) | ValueType.TClass(haxe.ds.EnumValueMap):
				return true;
			default:
				return false;
		}*/

		//trace(variable);
		if(variable.exists != null && variable.keyValueIterator != null) return true;
		return false;
	}

	public static function getPropertyLoop(split:Array<String>, ?checkForTextsToo:Bool = true, ?getProperty:Bool=true, ?allowMaps:Bool = false):Dynamic
	{
		var obj:Dynamic = getObjectDirectly(split[0], checkForTextsToo);
		var end = split.length;
		if(getProperty) end = split.length-1;

		for (i in 1...end) obj = getVarInArray(obj, split[i], allowMaps);
		return obj;
	}

public static function getModSetting(saveTag:String, ?modName:String = null):Dynamic {
	#if MODS_ALLOWED
    var settings:Map<String, Dynamic> = FlxG.save.data.modSettings.get(modName);
    var path:String = Paths.mods('$modName/data/settings.json');
    
    if(FileSystem.exists(path)) {
        if(settings == null || !settings.exists(saveTag)) {
            if(settings == null) settings = new Map<String, Dynamic>();
            try {
                var rawJson:String = File.getContent(path);
                var parsedJson:Array<Dynamic> = haxe.Json.parse(rawJson); 
                
                for(item in parsedJson) {
                    if(item.save == saveTag) {
                        if(item.type == 'keybind' || item.type == 'key') {
                            settings.set(item.save, {
                            });
                        } else {
                            settings.set(item.save, item.value);
                        }
                        break; 
                    }
                }
                FlxG.save.data.modSettings.set(settings, modName);
                FlxG.save.flush(); 
            } catch(e:Dynamic) {
                TraceManager.error('trace.lua.modSettingsLoadFailed', 'Failed to load mod settings: {}', [e.message]);
            }
        }
        return settings.get(saveTag);
    } else {
        TraceManager.warn('trace.lua.modSettingsNotFound', 'Mod settings not found: {}', [path]);

        return null;
    }
	#else
	return null;
	#end
}
	/** Get the variables map from whichever MusicBeatState is currently active */
	static function getStateVars():Map<String, Dynamic> {
		if (PlayState.instance != null)
			return PlayState.instance.variables;
		var state = FlxG.state;
		if (Std.isOfType(state, MusicBeatState))
			return cast(state, MusicBeatState).variables;
		if (Std.isOfType(state, MusicBeatSubstate))
			return cast(state, MusicBeatSubstate).variables;
		return null;
	}

public static function setVarInArray(instance:Dynamic, variable:String, value:Dynamic, allowMaps:Bool = false):Any
	{
		var stateVars = getStateVars();
		var splitProps:Array<String> = variable.split('[');
		if(splitProps.length > 1)
		{
			var target:Dynamic = null;
			if(stateVars != null && stateVars.exists(splitProps[0]))
			{
				var retVal:Dynamic = stateVars.get(splitProps[0]);
				if(retVal != null)
					target = retVal;
			}
			else target = Reflect.getProperty(instance, splitProps[0]);

			for (i in 1...splitProps.length)
			{
				var j:Dynamic = splitProps[i].substr(0, splitProps[i].length - 1);
				if (target == null) return null; // 对象不存在时安全跳过，避免空指针中断脚本
				if(i >= splitProps.length-1) //Last array
					target[j] = value;
				else //Anything else
					target = target[j];
			}
			return target;
		}

		if(allowMaps && isMap(instance))
		{
			//trace(instance);
			instance.set(variable, value);
			return value;
		}

		if(stateVars != null && stateVars.exists(variable))
		{
			stateVars.set(variable, value);
			return value;
		}

		// Symmetric with getProperty's compatibility fallback: a script may prime counters this
		// engine simply does not have (Amphotercity-Reformed's InitState.lua sets opCombo / npsMod /
		// opNpsAdd / ... for the fork it was written for). Reflect.setProperty throws
		// "Invalid field:x" for an unknown field of a class instance, the throw escapes the Lua
		// callback and aborts it, so everything after the first such line is lost. Under the old
		// compatibility modes the value is kept as a script variable instead -- where getProperty()
		// and getVar() read it back, which is what a HUD script does anyway -- and reported once.
		// Only when the target is the state itself: a dotted path, a group element or another class
		// still gets the original error, because there a missing field is a mistake worth stopping on.
		// 1.0.4 mode keeps the strict behaviour, exactly like the getProperty branch above.
		if(!CompatEngine.is104() && stateVars != null && instance == getTargetInstance())
		{
			trace('FunkinLua: setProperty: "' + variable + '" is not a field, kept as a script variable');
			stateVars.set(variable, value);
			return value;
		}
		Reflect.setProperty(instance, variable, value);
		return value;
	}

	public static function getVarInArray(instance:Dynamic, variable:String, allowMaps:Bool = false):Any
	{
		var stateVars = getStateVars();
		var splitProps:Array<String> = variable.split('[');
		if(splitProps.length > 1)
		{
			var target:Dynamic = null;
			if(stateVars != null && stateVars.exists(splitProps[0]))
			{
				var retVal:Dynamic = stateVars.get(splitProps[0]);
				if(retVal != null)
					target = retVal;
			}
			else
				target = Reflect.getProperty(instance, splitProps[0]);

			for (i in 1...splitProps.length)
			{
				var j:Dynamic = splitProps[i].substr(0, splitProps[i].length - 1);
				if (target == null) return null; // 对象不存在时安全返回，避免空指针中断脚本
				target = target[j];
			}
			return target;
		}
		if(stateVars != null && stateVars.exists(variable))
		{
			var retVal:Dynamic = stateVars.get(variable);
			if(retVal != null)
				return retVal;
		}

		return Reflect.getProperty(instance, variable);
	}
	static function parseInstances(args:Array<Dynamic>)
	{
		for (i in 0...args.length)
		{
			var myArg:String = cast args[i];
			if(myArg != null && myArg.length > instanceStr.length)
			{
				var index:Int = myArg.indexOf('::');
				if(index > -1)
				{
					myArg = myArg.substring(index+2);
					//trace('Op1: $myArg');
					var lastIndex:Int = myArg.lastIndexOf('::');

					var split:Array<String> = myArg.split('.');
					args[i] = (lastIndex > -1) ? Type.resolveClass(myArg.substring(0, lastIndex)) : PlayState.instance;
					for (j in 0...split.length)
					{
						//trace('Op2: ${Type.getClass(args[i])}, ${split[j]}');
						args[i] = getVarInArray(args[i], split[j].trim());
						//trace('Op3: ${args[i] != null ? Type.getClass(args[i]) : null}');
					}
				}
			}
		}
		return args;
	}

	static function callMethodFromObject(classObj:Dynamic, funcStr:String, args:Array<Dynamic> = null)
	{
		if(args == null) args = [];

		var split:Array<String> = funcStr.split('.');
		var funcToRun:Function = null;
		var obj:Dynamic = classObj;
		//trace('start: ' + obj);
		if(obj == null)
		{
			return null;
		}

		for (i in 0...split.length)
		{
			obj = getVarInArray(obj, split[i].trim());
			//trace(obj, split[i]);
		}

		funcToRun = cast obj;
		//trace('end: $obj');
		return funcToRun != null ? Reflect.callMethod(obj, funcToRun, args) : null;
	}

	static function getTextObject(name:String):FlxText
	{
		var state = getInstance();
		// Check modchart texts from current state
		if (Std.isOfType(state, MusicBeatState)) {
			var mState:MusicBeatState = cast state;
			if (mState.modchartTexts.exists(name))
				return mState.modchartTexts.get(name);
		} else if (Std.isOfType(state, MusicBeatSubstate)) {
			var mSub:MusicBeatSubstate = cast state;
			if (mSub.modchartTexts.exists(name))
				return mSub.modchartTexts.get(name);
		}
		if (PlayState.instance != null && Reflect.getProperty(PlayState.instance, name) != null)
			return Reflect.getProperty(PlayState.instance, name);
		return Reflect.getProperty(FlxG.state, name);
	}
	public static function getTargetInstance()
	{
		if (PlayState.instance == null)
			return FlxG.state;
		return PlayState.instance.isDead ? GameOverSubstate.instance : PlayState.instance;
	}

	// ==================== STATE-AGNOSTIC MODCHART HELPERS ====================

	/** Get the current MusicBeatState (or PlayState) modchart maps, or null */
	static function getStateModchartSprites():Map<String, ModchartSprite> {
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.modchartSprites;
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).modchartSprites;
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).modchartSprites;
		return null;
	}
	static function getStateModchartTexts():Map<String, ModchartText> {
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.modchartTexts;
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).modchartTexts;
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).modchartTexts;
		return null;
	}
	static function getStateModchartTweens():Map<String, FlxTween> {
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.modchartTweens;
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).modchartTweens;
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).modchartTweens;
		return null;
	}
	static function getStateModchartTimers():Map<String, FlxTimer> {
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.modchartTimers;
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).modchartTimers;
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).modchartTimers;
		return null;
	}
	static function getStateModchartSounds():Map<String, FlxSound> {
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.modchartSounds;
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).modchartSounds;
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).modchartSounds;
		return null;
	}
	static function getStateModchartSaves():Map<String, FlxSave> {
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.modchartSaves;
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).modchartSaves;
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).modchartSaves;
		return null;
	}
	#if (!flash && sys)
	static function getStateRuntimeShaders():Map<String, Array<String>> {
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.runtimeShaders;
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).runtimeShaders;
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).runtimeShaders;
		return null;
	}
	#end
	static function getStateLuaArray():Array<FunkinLua> {
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.luaArray;
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).luaArray;
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).luaArray;
		return null;
	}

	/** Call onLuas / callOnScripts on whichever MusicBeatState/Substate is active */
	static function callOnStateLuas(event:String, args:Array<Dynamic> = null, ignoreStops:Bool = false, exclusions:Array<String> = null, excludeValues:Array<Dynamic> = null):Dynamic {
		if (args == null) args = [];
		if (exclusions == null) exclusions = [];
		if (excludeValues == null) excludeValues = [];
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.callOnLuas(event, args, ignoreStops, exclusions, excludeValues);
		if (Std.isOfType(state, MusicBeatState)) return cast(state, MusicBeatState).callOnLuas(event, args, ignoreStops, exclusions, excludeValues);
		if (Std.isOfType(state, MusicBeatSubstate)) return cast(state, MusicBeatSubstate).callOnLuas(event, args, ignoreStops, exclusions, excludeValues);
		return FunkinLua.Function_Continue;
	}
	static function callOnStateScripts(event:String, args:Array<Dynamic> = null, ignoreStops:Bool = false, exclusions:Array<String> = null, excludeValues:Array<Dynamic> = null):Dynamic {
		if (args == null) args = [];
		if (exclusions == null) exclusions = [];
		if (excludeValues == null) excludeValues = [];
		var state = FlxG.state;
		if (PlayState.instance != null) return PlayState.instance.callOnScripts(event, args, ignoreStops, exclusions, excludeValues);
		if (Std.isOfType(state, MusicBeatState)) {
			var mState:MusicBeatState = cast state;
			mState.callOnHscript(event, args, ignoreStops, exclusions);
			return mState.callOnLuas(event, args, ignoreStops, exclusions, excludeValues);
		}
		if (Std.isOfType(state, MusicBeatSubstate)) {
			var mSub:MusicBeatSubstate = cast state;
			mSub.callOnHscript(event, args, ignoreStops, exclusions);
			return mSub.callOnLuas(event, args, ignoreStops, exclusions, excludeValues);
		}
		return FunkinLua.Function_Continue;
	}

	/** Add a lua script to whichever state is active */
	static function addLuaToState(lua:FunkinLua):Void {
		var arr = getStateLuaArray();
		if (arr != null) arr.push(lua);
	}
	/** Remove a lua script from whichever state is active */
	static function removeLuaFromState(lua:FunkinLua):Void {
		var arr = getStateLuaArray();
		if (arr != null) arr.remove(lua);
	}

	public static function getLowestCharacterGroup():FlxSpriteGroup
	{
		if (PlayState.instance == null) return null;
		var group:FlxSpriteGroup = PlayState.instance.gfGroup;
		var pos:Int = PlayState.instance.members.indexOf(group);

		var newPos:Int = PlayState.instance.members.indexOf(PlayState.instance.boyfriendGroup);
		if(newPos < pos)
		{
			group = PlayState.instance.boyfriendGroup;
			pos = newPos;
		}
		
		newPos = PlayState.instance.members.indexOf(PlayState.instance.dadGroup);
		if(newPos < pos)
		{
			group = PlayState.instance.dadGroup;
			pos = newPos;
		}
		return group;
	}


	#if (!flash && sys)
	public function getShader(obj:String):FlxRuntimeShader
	{
		var killMe:Array<String> = obj.split('.');
		var leObj:FlxSprite = getObjectDirectly(killMe[0]);
		if(killMe.length > 1) {
			leObj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
		}

		if(leObj != null) {
			var shader:Dynamic = leObj.shader;
			var shader:FlxRuntimeShader = shader;
			return shader;
		}
		return null;
	}
	#end
	
	function initLuaShader(name:String, ?glslVersion:Int = 120)
	{
		if(!ClientPrefs.data.shaders) return false;

		#if (!flash && sys)
		if (PlayState.instance != null && PlayState.instance.runtimeShaders.exists(name))
		{
			luaTrace('Shader $name was already initialized!');
			return true;
		}

		var foldersToCheck:Array<String> = [Paths.mods('shaders/')];
		if(Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			foldersToCheck.insert(0, Paths.mods(Paths.currentModDirectory + '/shaders/'));

		for(mod in Paths.getGlobalMods())
			foldersToCheck.insert(0, Paths.mods(mod + '/shaders/'));
		
		for (folder in foldersToCheck)
		{
			if(FileSystem.exists(folder))
			{
				var frag:String = folder + name + '.frag';
				var vert:String = folder + name + '.vert';
				var found:Bool = false;
				if(FileSystem.exists(frag))
				{
					frag = File.getContent(frag);
					found = true;
				}
				else frag = null;

				if(FileSystem.exists(vert))
				{
					vert = File.getContent(vert);
					found = true;
				}
				else vert = null;

				if(found)
				{
					if (PlayState.instance != null)
						PlayState.instance.runtimeShaders.set(name, [frag, vert]);
					return true;
				}
			}
		}
		luaTrace('Missing shader $name .frag AND .vert files!', false, false, FlxColor.RED);
		#else
		luaTrace('This platform doesn\'t support Runtime Shaders!', false, false, FlxColor.RED);
		#end
		return false;
	}

	function getGroupStuff(leArray:Dynamic, variable:String) {
		var killMe:Array<String> = variable.split('.');
		if(killMe.length > 1) {
			var coverMeInPiss:Dynamic = Reflect.getProperty(leArray, killMe[0]);
			for (i in 1...killMe.length-1) {
				coverMeInPiss = Reflect.getProperty(coverMeInPiss, killMe[i]);
			}
			switch(Type.typeof(coverMeInPiss)){
				case ValueType.TClass(haxe.ds.StringMap) | ValueType.TClass(haxe.ds.ObjectMap) | ValueType.TClass(haxe.ds.IntMap) | ValueType.TClass(haxe.ds.EnumValueMap):
					return coverMeInPiss.get(killMe[killMe.length-1]);
				default:
					return Reflect.getProperty(coverMeInPiss, killMe[killMe.length-1]);
			};
		}
		switch(Type.typeof(leArray)){
			case ValueType.TClass(haxe.ds.StringMap) | ValueType.TClass(haxe.ds.ObjectMap) | ValueType.TClass(haxe.ds.IntMap) | ValueType.TClass(haxe.ds.EnumValueMap):
				return leArray.get(variable);
			default:
				return Reflect.getProperty(leArray, variable);
		};
	}

	function loadFrames(spr:FlxSprite, image:String, spriteType:String)
	{
		switch(spriteType.toLowerCase().trim())
		{
			case "texture" | "textureatlas" | "tex":
				spr.frames = AtlasFrameMaker.construct(image);

			case "texture_noaa" | "textureatlas_noaa" | "tex_noaa":
				spr.frames = AtlasFrameMaker.construct(image, null, true);

			case "packer" | "packeratlas" | "pac":
				spr.frames = Paths.getPackerAtlas(image);

			default:
				spr.frames = Paths.getSparrowAtlas(image);
		}
	}

	function setGroupStuff(leArray:Dynamic, variable:String, value:Dynamic) {
		var killMe:Array<String> = variable.split('.');
		if(killMe.length > 1) {
			var coverMeInPiss:Dynamic = Reflect.getProperty(leArray, killMe[0]);
			for (i in 1...killMe.length-1) {
				coverMeInPiss = Reflect.getProperty(coverMeInPiss, killMe[i]);
			}
			Reflect.setProperty(coverMeInPiss, killMe[killMe.length-1], value);
			return;
		}
		Reflect.setProperty(leArray, variable, value);
	}

	function resetTextTag(tag:String) {
		var texts = getStateModchartTexts();
		if(texts == null || !texts.exists(tag)) {
			return;
		}

		var pee:ModchartText = texts.get(tag);
		pee.kill();
		if(pee.wasAdded) {
			getTargetInstance().remove(pee, true);
		}
		pee.destroy();
		texts.remove(tag);
	}

	function resetSpriteTag(tag:String) {
		var sprites = getStateModchartSprites();
		if(sprites == null || !sprites.exists(tag)) {
			return;
		}

		var pee:ModchartSprite = sprites.get(tag);
		pee.kill();
		if(pee.wasAdded) {
			getTargetInstance().remove(pee, true);
		}
		pee.destroy();
		sprites.remove(tag);
	}

	function cancelTween(tag:String) {
		var tweens = getStateModchartTweens();
		if(tweens != null && tweens.exists(tag)) {
			tweens.get(tag).cancel();
			tweens.get(tag).destroy();
			tweens.remove(tag);
		}
	}

	function tweenShit(tag:String, vars:String) {
		cancelTween(tag);
		var variables:Array<String> = vars.split('.');
		var sexyProp:Dynamic = getObjectDirectly(variables[0]);
		if(variables.length > 1) {
			sexyProp = getVarInArray(getPropertyLoopThingWhatever(variables), variables[variables.length-1]);
		}
		return sexyProp;
	}

	function cancelTimer(tag:String) {
		var timers = getStateModchartTimers();
		if(timers != null && timers.exists(tag)) {
			var theTimer:FlxTimer = timers.get(tag);
			theTimer.cancel();
			theTimer.destroy();
			timers.remove(tag);
		}
	}

	//Better optimized than using some getProperty shit or idk
	function getFlxEaseByString(?ease:String = '') {
		switch(ease.toLowerCase().trim()) {
			case 'backin': return FlxEase.backIn;
			case 'backinout': return FlxEase.backInOut;
			case 'backout': return FlxEase.backOut;
			case 'bouncein': return FlxEase.bounceIn;
			case 'bounceinout': return FlxEase.bounceInOut;
			case 'bounceout': return FlxEase.bounceOut;
			case 'circin': return FlxEase.circIn;
			case 'circinout': return FlxEase.circInOut;
			case 'circout': return FlxEase.circOut;
			case 'cubein': return FlxEase.cubeIn;
			case 'cubeinout': return FlxEase.cubeInOut;
			case 'cubeout': return FlxEase.cubeOut;
			case 'elasticin': return FlxEase.elasticIn;
			case 'elasticinout': return FlxEase.elasticInOut;
			case 'elasticout': return FlxEase.elasticOut;
			case 'expoin': return FlxEase.expoIn;
			case 'expoinout': return FlxEase.expoInOut;
			case 'expoout': return FlxEase.expoOut;
			case 'quadin': return FlxEase.quadIn;
			case 'quadinout': return FlxEase.quadInOut;
			case 'quadout': return FlxEase.quadOut;
			case 'quartin': return FlxEase.quartIn;
			case 'quartinout': return FlxEase.quartInOut;
			case 'quartout': return FlxEase.quartOut;
			case 'quintin': return FlxEase.quintIn;
			case 'quintinout': return FlxEase.quintInOut;
			case 'quintout': return FlxEase.quintOut;
			case 'sinein': return FlxEase.sineIn;
			case 'sineinout': return FlxEase.sineInOut;
			case 'sineout': return FlxEase.sineOut;
			case 'smoothstepin': return FlxEase.smoothStepIn;
			case 'smoothstepinout': return FlxEase.smoothStepInOut;
			case 'smoothstepout': return FlxEase.smoothStepInOut;
			case 'smootherstepin': return FlxEase.smootherStepIn;
			case 'smootherstepinout': return FlxEase.smootherStepInOut;
			case 'smootherstepout': return FlxEase.smootherStepOut;
		}
		return FlxEase.linear;
	}

	// 0.7.3+/1.0.4 startTween 用：把 options.type 字符串转成 FlxTweenType
	// Used by startTween (0.7.3+): converts the options.type string to FlxTweenType
	function getTweenTypeByString(?type:String = ''):FlxTweenType {
		switch(type.toLowerCase().trim())
		{
			case 'backward': return FlxTweenType.BACKWARD;
			case 'looping' | 'loop': return FlxTweenType.LOOPING;
			case 'persist': return FlxTweenType.PERSIST;
			case 'pingpong': return FlxTweenType.PINGPONG;
		}
		return FlxTweenType.ONESHOT;
	}

	// startTween 的 tween_ 标签规范化（与 0.7.3/1.0.4 一致）
	// startTween tag normalisation (matches 0.7.3/1.0.4)
	function formatVariable(tag:String):String {
		return tag.trim().replace(' ', '_').replace('.', '');
	}

	function blendModeFromString(blend:String):BlendMode {
		switch(blend.toLowerCase().trim()) {
			case 'add': return ADD;
			case 'alpha': return ALPHA;
			case 'darken': return DARKEN;
			case 'difference': return DIFFERENCE;
			case 'erase': return ERASE;
			case 'hardlight': return HARDLIGHT;
			case 'invert': return INVERT;
			case 'layer': return LAYER;
			case 'lighten': return LIGHTEN;
			case 'multiply': return MULTIPLY;
			case 'overlay': return OVERLAY;
			case 'screen': return SCREEN;
			case 'shader': return SHADER;
			case 'subtract': return SUBTRACT;
		}
		return NORMAL;
	}

	function cameraFromString(cam:String):FlxCamera {
		if (PlayState.instance != null) {
			switch(cam.toLowerCase()) {
				case 'camhud' | 'hud': return PlayState.instance.camHUD;
				case 'camother' | 'other': return PlayState.instance.camOther;
			}
			return PlayState.instance.camGame;
		}
		// Fallback for non-PlayState contexts
		return FlxG.camera;
	}

	public function luaTrace(text:String, ignoreCheck:Bool = false, deprecated:Bool = false, color:FlxColor = FlxColor.WHITE) {
		/*#if LUA_ALLOWED
		if(ignoreCheck || getBool('luaDebugMode')) {
			if(deprecated && !getBool('luaDeprecatedWarnings')) {
				return;
			}
			// Try current state first (MusicBeatState or MusicBeatSubstate)
			var curState = FlxG.state;
			if (PlayState.instance != null)
				PlayState.instance.addTextToDebug(text, color);
			else if (Std.isOfType(curState, MusicBeatState))
				cast(curState, MusicBeatState).addTextToDebug(text, color);
			else if (Std.isOfType(curState, MusicBeatSubstate))
				cast(curState, MusicBeatSubstate).addTextToDebug(text, color);
			TraceManager.info('trace.lua.luaTrace', '{}', [text]);
		}
		#end*/
	}

	function getErrorMessage(status:Int):String {
		#if LUA_ALLOWED
		var v:String = Lua.tostring(lua, -1);
		Lua.pop(lua, 1);

		if (v != null) v = v.trim();
		if (v == null || v == "") {
			switch(status) {
				case Lua.LUA_ERRRUN: return Language.get('trace.lua.errRuntime', 'Runtime Error');
				case Lua.LUA_ERRMEM: return Language.get('trace.lua.errMemory', 'Memory Allocation Error');
				case Lua.LUA_ERRERR: return Language.get('trace.lua.errCritical', 'Critical Error');
			}
			return Language.get('trace.lua.errUnknown', 'Unknown Error');
		}

		return v;
		#end
		return null;
	}

	/**
	 * Format a string by replacing `{}` placeholders with args (same as TraceManager format)
	 */
	static function formatLuaString(pattern:String, args:Array<Dynamic>):String {
		if (args == null || args.length == 0) return pattern;
		for (i in 0...args.length) {
			var pos = pattern.indexOf('{}');
			if (pos < 0) break;
			pattern = pattern.substr(0, pos) + Std.string(args[i]) + pattern.substr(pos + 2);
		}
		return pattern;
	}

	/**
	 * F8 probe counters: how many times the require / import resolvers actually had to search
	 * the file system. A mod that calls import() (or a never-resolving require) inside a
	 * per-frame callback shows up here at once, which separates "the callback body is slow"
	 * from "the callback re-reads and re-compiles files every frame".
	 */
	public static var probeRequireResolves:Int = 0;
	public static var probeImportResolves:Int = 0;

	/**
	 * Negative callback cache for call(). A global name is remembered as "nil at stamp S" and
	 * the getglobal/type/pop probe is skipped while the stamp is still S. The stamp survives
	 * only as long as nothing could have defined that global:
	 *   - globalsEpoch advances after every pcall (this Lua state ran script code),
	 *   - HScript.codeEpoch advances whenever any HScript runs or has a variable written
	 *     (HScript code is the only route into LuaApi, which writes Lua globals directly and is
	 *     deliberately untouched this round),
	 *   - probeStamp() refuses to hand out a stamp while this state (or any HScript) is
	 *     executing, so a re-entrant dispatch from inside a chunk can never read a stale entry,
	 *   - set() / addLocalCallback() drop the entry for the exact name they write.
	 * Only nil is cached on purpose: a non-nil, non-function global must keep running the
	 * "attempt to call a X value" error path on every call, or the visible script error
	 * text/loop protection would change.
	 */
	var nilCallbacks:Map<String, Int> = null;
	/** Bumped whenever script code ran in this state (its globals may have changed). */
	var globalsEpoch:Int = 0;
	/** Depth of Lua.pcall frames of this state (see probeStamp()); a counter, not a flag,
	 * because a Haxe callback invoked from a chunk can re-enter call() on the same state. */
	var luaExecDepth:Int = 0;
	var foldedGlobals:Int = -1;
	var foldedHScript:Int = -1;
	var nilStamp:Int = 0;

	/**
	 * Stamp to compare against nilCallbacks entries, or -1 when nothing may be cached/read.
	 * A changed stamp means every cached "this callback is nil" observation may be stale.
	 */
	inline function probeStamp():Int
	{
		#if HSCRIPT_ALLOWED
		var bridgeEpoch:Int = script.hscript.HScript.codeEpoch;
		var bridgeBusy:Bool = script.hscript.HScript.execDepth > 0;
		#else
		var bridgeEpoch:Int = 0;
		var bridgeBusy:Bool = false;
		#end
		if (luaExecDepth > 0 || bridgeBusy) return -1;
		if (foldedGlobals != globalsEpoch || foldedHScript != bridgeEpoch)
		{
			foldedGlobals = globalsEpoch;
			foldedHScript = bridgeEpoch;
			nilStamp++;
		}
		// Long-session guard: the stamp only has to differ from every stored value. Resetting it
		// together with the map keeps that true without any overflow reasoning.
		if (nilStamp >= 0x20000000)
		{
			nilStamp = 0;
			if (nilCallbacks != null) nilCallbacks.clear();
		}
		return nilStamp;
	}

	var lastCalledFunction:String = '';

	/**
	 * 记录一次脚本报错：连续报错达到 scriptErrorLimit 时静默忽略（closed）这个脚本，
	 * 防止在 update 循环里因同一个错误每帧刷屏、白白占用性能。
	 * 只有每帧/每步回调参与计数（见 ScriptErrorGuard）：一次性回调（onEvent、onKeyPress…）
	 * 报错照常打印，但不会把整个脚本关掉 —— 否则它在别的回调里本该正常工作的功能会一起失效。
	 * @param callback 触发报错的回调名，缺省取最近一次 call() 的函数名
	 * @return true = 已达到上限已被忽略
	 */
	function registerError(callback:String = null):Bool {
		if (!ClientPrefs.data.ignoreErrorLoopScripts) return false;
		if (callback == null) callback = lastCalledFunction;
		if (!ScriptErrorGuard.isLoopCallback(callback)) return false;
		errorLoopCount++;
		if (errorLoopCount >= ClientPrefs.data.scriptErrorLimit) {
			closed = true;
			TraceManager.warn('trace.script.ignoredAfterErrors', 'Script ignored after {} repeated errors: {}', [errorLoopCount, scriptName]);
			return true;
		}
		return false;
	}
	/** 每帧/每步回调成功执行后重置连续报错计数（只有"持续报错"才算循环）。 */
	inline function resetErrors():Void {
		errorLoopCount = 0;
	}

	public function call(func:String, args:Array<Dynamic>):Dynamic {
		#if LUA_ALLOWED
		if(closed) return Function_Continue;

		lastCalledFunction = func;
		try {
			if(lua == null) return Function_Continue;

			// Negative callback cache (see nilCallbacks): skip the whole probe when this exact
			// global was already observed to be nil and nothing could have defined it since.
			var stamp:Int = probeStamp();
			if (stamp >= 0 && nilCallbacks != null)
			{
				var seen:Null<Int> = nilCallbacks.get(func);
				if (seen != null && seen == stamp) return Function_Continue;
			}

			Lua.getglobal(lua, func);
			var type:Int = Lua.type(lua, -1);

			if (type != Lua.LUA_TFUNCTION) {
				if (type > Lua.LUA_TNIL) {
					if (CompatEngine.compatMode()) {
						// Old-style error message (PsychEngine 0.6.3 format)
						luaTrace("ERROR (" + func + "): attempt to call a " + typeToString(type) + " value", false, false, FlxColor.RED);
					} else {
						var typeName:String = typeToString(type);
						var pattern = Language.get('trace.lua.callNotFunction', 'ERROR ({}): attempt to call a {} value');
						var errMsg = formatLuaString(pattern, [func, typeName]);
						luaTrace(errMsg, false, false, FlxColor.RED);
						TraceManager.error('trace.lua.callNotFunction', 'ERROR ({}): attempt to call a {} value', [func, typeName]);
					}
					if (registerError(func)) { Lua.pop(lua, 1); return Function_Continue; }
				}

				// Only "absent" is cached; a non-nil, non-function value must keep hitting the
				// error path above on every call.
				if (type <= Lua.LUA_TNIL && stamp >= 0)
				{
					if (nilCallbacks == null) nilCallbacks = new Map();
					nilCallbacks.set(func, stamp);
				}

				Lua.pop(lua, 1);
				return Function_Continue;
			}

			for (arg in args) Convert.toLua(lua, arg);
			// While the chunk runs, engine callbacks it triggers can re-enter this same state,
			// so probeStamp() reports -1 for that window.
			luaExecDepth++;
			var status:Int;
			try {
				status = Lua.pcall(lua, args.length, 1, 0);
				luaExecDepth--;
			} catch (e:Dynamic) {
				luaExecDepth--;
				throw e;
			}
			globalsEpoch++; // script code ran: it may have defined any global

			// Checks if it's not successful, then show a error.
			if (status != Lua.LUA_OK) {
				var error:String = getErrorMessage(status);
				if (!CompatEngine.compatMode()) {
					// Old-style error message (PsychEngine 0.6.3 format)
					luaTrace("ERROR (" + func + "): " + error, false, false, FlxColor.RED);
				} else {
					var pattern = Language.get('trace.lua.callRuntimeError', 'ERROR ({}): {}');
					var errMsg = formatLuaString(pattern, [func, error]);
					luaTrace(errMsg, false, false, FlxColor.RED);
					TraceManager.error('trace.lua.callRuntimeError', 'ERROR ({}): {}', [func, error]);
				}
				if (registerError(func)) return Function_Continue;
				return Function_Continue;
			}

			// If successful, pass and then return the result.
			var result:Dynamic = cast Convert.fromLua(lua, -1);
			if (result == null) result = Function_Continue;

			Lua.pop(lua, 1);
			if (ScriptErrorGuard.isLoopCallback(func)) resetErrors();
			return result;
		}
		catch (e:Dynamic) {
			globalsEpoch++; // an error path may still have written globals
			if (!CompatEngine.compatMode()) {
				trace(e);
			} else {
				TraceManager.error('trace.lua.callError', '{}', [e]);
			}
			registerError(lastCalledFunction);
		}
		#end
		return Function_Continue;
	}

	static function addAnimByIndices(obj:String, name:String, prefix:String, indices:String, framerate:Int = 24, loop:Bool = false)
	{
		var strIndices:Array<String> = indices.trim().split(',');
		var die:Array<Int> = [];
		for (i in 0...strIndices.length) {
			die.push(Std.parseInt(strIndices[i]));
		}

		if(PlayState.instance.getLuaObject(obj, false)!=null) {
			var pussy:FlxSprite = PlayState.instance.getLuaObject(obj, false);
			pussy.animation.addByIndices(name, prefix, die, '', framerate, loop);
			if(pussy.animation.curAnim == null) {
				pussy.animation.play(name, true);
			}
			return true;
		}

		var pussy:FlxSprite = Reflect.getProperty(getInstance(), obj);
		if(pussy != null) {
			pussy.animation.addByIndices(name, prefix, die, '', framerate, loop);
			if(pussy.animation.curAnim == null) {
				pussy.animation.play(name, true);
			}
			return true;
		}
		return false;
	}

	public static function getPropertyLoopThingWhatever(killMe:Array<String>, ?checkForTextsToo:Bool = true, ?getProperty:Bool=true):Dynamic
	{
		var coverMeInPiss:Dynamic = getObjectDirectly(killMe[0], checkForTextsToo);
		var end = killMe.length;
		if(getProperty)end=killMe.length-1;

		for (i in 1...end) {
			coverMeInPiss = getVarInArray(coverMeInPiss, killMe[i]);
		}
		return coverMeInPiss;
	}

	public static function getObjectDirectly(objectName:String, ?checkForTextsToo:Bool = true):Dynamic
	{
		var coverMeInPiss:Dynamic = null;
		if (PlayState.instance != null)
			coverMeInPiss = PlayState.instance.getLuaObject(objectName, checkForTextsToo);
		if(coverMeInPiss==null)
			coverMeInPiss = getVarInArray(getInstance(), objectName);

		return coverMeInPiss;
	}

	/**
	 * Gives a frame to a sprite a script built without an image: called when it is added to the state
	 * (addLuaSprite) and when a shader is put on it (setSpriteShader), the two moments such a sprite
	 * has to work.
	 *
	 * `makeLuaSprite(tag, '')` (what the "shader background" stages write) leaves the sprite with no
	 * frame at all, and `FlxSprite.draw()` returns on `_frame.type == EMPTY` before it ever runs a
	 * shader -- so such a sprite is invisible and the whole phase it was meant to fill is black, no
	 * matter how correct the shader is. The shader also cannot work without a texture: the
	 * Shadertoy-converted ones (`neruneru`, `void`, ...) read `openfl_TextureSize` for their
	 * coordinates and take the output alpha from `texture(bitmap, uv).a`.
	 *
	 * A 1x1 opaque white frame is the minimum that satisfies both and stays out of the way: the
	 * shader's own maths normalises by the texture size, so a square 1x1 gives the plain [-1,1]
	 * domain, the alpha comes out 1 (opaque), and the on-screen size is still whatever the script's
	 * setGraphicSize/scaleObject asks for. Mods that get this right make the frame themselves
	 * (`makeGraphic(tag, screenWidth, screenHeight)`) and are untouched: this only runs when the
	 * sprite has no graphic.
	 */
	public static function ensureSpriteFrame(sprite:FlxSprite):Void
	{
		if(sprite == null || sprite.graphic != null) return;
		sprite.makeGraphic(1, 1, FlxColor.WHITE);
	}

	/** Sprite named by a Lua tag or object path, resolved exactly like setSpriteShader(). */
	public static function resolveSpriteByTag(obj:String):FlxSprite
	{
		if(obj == null || obj.length == 0) return null;
		var killMe:Array<String> = obj.split('.');
		var leObj:Dynamic = getObjectDirectly(killMe[0]);
		if(killMe.length > 1)
			leObj = getVarInArray(getPropertyLoopThingWhatever(killMe), killMe[killMe.length-1]);
		return (leObj != null && Std.isOfType(leObj, FlxSprite)) ? cast leObj : null;
	}

	/**
	 * Effect name -> WiggleEffectType, following H-Slice's addWiggleEffect mapping: the PE fork
	 * names the heat waves HORIZONTAL/VERTICAL and has no GLITCH, so everything that is not one of
	 * the four named looks is the flag look (which is also H-Slice's default).
	 */
	public static function wiggleTypeFromName(type:String):WiggleEffectType
	{
		if(type != null) switch(type.toUpperCase()) {
			case 'WAVY' | 'WAVE': return WiggleEffectType.WAVY;
			case 'DREAMY': return WiggleEffectType.DREAMY;
			case 'HORIZONTAL' | 'HEAT_WAVE_HORIZONTAL': return WiggleEffectType.HEAT_WAVE_HORIZONTAL;
			case 'VERTICAL' | 'HEAT_WAVE_VERTICAL': return WiggleEffectType.HEAT_WAVE_VERTICAL;
		}
		return WiggleEffectType.FLAG;
	}

	function typeToString(type:Int):String {
		#if LUA_ALLOWED
		switch(type) {
			case Lua.LUA_TBOOLEAN: return "boolean";
			case Lua.LUA_TNUMBER: return "number";
			case Lua.LUA_TSTRING: return "string";
			case Lua.LUA_TTABLE: return "table";
			case Lua.LUA_TFUNCTION: return "function";
		}
		if (type <= Lua.LUA_TNIL) return "nil";
		#end
		return "unknown";
	}

	public function set(variable:String, data:Dynamic) {
		#if LUA_ALLOWED
		if(lua == null) {
			return;
		}

		// Writing a global can turn a cached "absent" into a real callback.
		if (nilCallbacks != null) nilCallbacks.remove(variable);

		var oldEnableUnsupportedTraces:Bool = Convert.enableUnsupportedTraces;
		Convert.enableUnsupportedTraces = false;
		Convert.toLua(lua, data);
		Convert.enableUnsupportedTraces = oldEnableUnsupportedTraces;
		Lua.setglobal(lua, variable);
		#end
	}

	#if LUA_ALLOWED
	public function getBool(variable:String) {
		var result:String = null;
		Lua.getglobal(lua, variable);
		result = Convert.fromLua(lua, -1);
		Lua.pop(lua, 1);

		if(result == null) {
			return false;
		}
		return (result == 'true');
	}
	#end

	public function stop() {
		#if LUA_ALLOWED
		if(lua == null) {
			return;
		}

		// 清理 require 专用回调，避免 Lua_helper 全局静态 map 越积越多
		// English: clean up the require-only callback so the global static map doesn't grow
		if (__requireResolveName != null)
		{
			try { Lua_helper.remove_callback(lua, __requireResolveName); }
			catch (e:Dynamic) {}
			__requireResolveName = null;
			__requireChunksName = null;
		}

		// 清理 import 专用回调（同上）。English: clean up the import-only callback (same reason).
		if (__importResolveName != null)
		{
			try { Lua_helper.remove_callback(lua, __importResolveName); }
			catch (e:Dynamic) {}
			__importResolveName = null;
		}

		Lua.close(lua);
		lua = null;
		#end
	}

	public static function getInstance()
	{
		if (PlayState.instance == null)
			return FlxG.state;
		return PlayState.instance.isDead ? GameOverSubstate.instance : PlayState.instance;
	}
}

/**
 * 自定义子状态：内容由脚本的 onCustomSubstate* 事件驱动。
 * English: Custom substate — its content is driven by the onCustomSubstate*
 * script events (open via openCustomSubstate, close via closeCustomSubstate).
 */
class CustomSubstate extends MusicBeatSubstate
{
	public static var name:String = 'unnamed';
	public static var instance:CustomSubstate;

	override function create()
	{
		instance = this;
		if (PlayState.instance != null) {
			// Lua 侧不能直接转换 CustomSubstate 实例，给一个安全的字符串名；
			// HScript 侧仍按 0.7.3 暴露真实实例。
			PlayState.instance.setOnLuas('customSubstate', name);
			PlayState.instance.setOnHscript('customSubstate', this);
		}

		PlayState.instance.callOnScripts('onCustomSubstateCreate', [name]);
		super.create();
		PlayState.instance.callOnScripts('onCustomSubstateCreatePost', [name]);
	}
	
	public function new(name:String)
	{
		CustomSubstate.name = name;
		if (PlayState.instance != null) {
			PlayState.instance.setOnLuas('customSubstateName', name);
			PlayState.instance.setOnHscript('customSubstateName', name);
		}
		super();
		cameras = [FlxG.cameras.list[FlxG.cameras.list.length - 1]];
	}
	
	override function update(elapsed:Float)
	{
		PlayState.instance.callOnScripts('onCustomSubstateUpdate', [name, elapsed]);
		super.update(elapsed);
		PlayState.instance.callOnScripts('onCustomSubstateUpdatePost', [name, elapsed]);
	}

	override function destroy()
	{
		if (PlayState.instance != null) {
			PlayState.instance.callOnScripts('onCustomSubstateDestroy', [name]);
			PlayState.instance.setOnLuas('customSubstate', null);
			PlayState.instance.setOnLuas('customSubstateName', 'unnamed');
			PlayState.instance.setOnHscript('customSubstate', null);
			PlayState.instance.setOnHscript('customSubstateName', 'unnamed');
		}
		instance = null;
		name = 'unnamed';
		super.destroy();
	}
}

