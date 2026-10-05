package backend;

import Conductor.BPMChangeEvent;
import flixel.FlxSubState;
import flixel.FlxBasic;
import flixel.system.FlxSound;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.util.FlxSave;
import flixel.util.FlxTimer;
import flixel.util.FlxColor;
import flixel.tweens.FlxTween;

import script.lua.FunkinLua;

import script.lua.ModchartSprite;
import script.lua.ModchartText;
import script.lua.DebugLuaText;
#if HSCRIPT_ALLOWED
import script.hscript.HScript;
#end

#if (!flash && sys)
import flixel.addons.display.FlxRuntimeShader;
#end

import flixel.input.actions.FlxActionInput;
import flixel.util.FlxDestroyUtil;
import android.flixel.FlxVirtualPad;
import mohong.TraceManager;

class MusicBeatSubstate extends FlxSubState
{
	// -- Public beat/step state --
	public var curStep:Int = 0;
	public var curBeat:Int = 0;
	public var curDecStep:Float = 0;
	public var curDecBeat:Float = 0;
	public var controls(get, never):Controls;

	// -- Internal --
	private var lastBeat:Float = 0;
	private var lastStep:Float = 0;

	/** Script name for data/states/ loading. */
	public var scriptName:String = null;

	// -- Shared variable storage --
	public var variables:Map<String, Dynamic> = new Map<String, Dynamic>();

	#if HSCRIPT_ALLOWED
	public var hscriptArray:Array<HScript> = [];
	#end

	public var luaArray:Array<FunkinLua> = [];
	public var modchartTweens:Map<String, FlxTween> = new Map<String, FlxTween>();
	public var modchartSprites:Map<String, ModchartSprite> = new Map<String, ModchartSprite>();
	public var modchartTimers:Map<String, FlxTimer> = new Map<String, FlxTimer>();
	public var modchartSounds:Map<String, FlxSound> = new Map<String, FlxSound>();
	public var modchartTexts:Map<String, ModchartText> = new Map<String, ModchartText>();
	public var modchartSaves:Map<String, FlxSave> = new Map<String, FlxSave>();
	public var luaDebugGroup:FlxTypedGroup<DebugLuaText>;
	#if (!flash && sys)
	public var runtimeShaders:Map<String, Array<String>> = new Map<String, Array<String>>();
	#end

	public function new(?scriptName:String) {
		super();
		this.scriptName = scriptName;
	}

	inline function get_controls():Controls
		return PlayerSettings.player1.controls;

	// -- Getters --
	public function getCurStep():Int return curStep;
	public function getCurBeat():Int return curBeat;

	var virtualPad:FlxVirtualPad;
	var trackedinputsUI:Array<FlxActionInput> = [];
	var padCamera:FlxCamera;

	/**
	 * 创建菜单虚拟按键。安卓/iOS 始终启用; 桌面端只有开启"触屏支持"后才显示。
	 */
	public function addVirtualPad(DPad:FlxDPadMode, Action:FlxActionMode) {
		#if !TOUCH_CONTROLS
		if (!ClientPrefs.data.touchControls)
			return;
		#end
		if (virtualPad != null) removeVirtualPad();
		virtualPad = new FlxVirtualPad(DPad, Action);
		add(virtualPad);
		controls.setVirtualPadUI(virtualPad, DPad, Action);
		trackedinputsUI = controls.trackedinputsUI;
		controls.trackedinputsUI = [];
	}

	public function removeVirtualPad() {
		if (trackedinputsUI.length > 0) controls.removeVirtualControlsInput(trackedinputsUI);
		if (virtualPad != null)
		{
			remove(virtualPad);
			virtualPad = FlxDestroyUtil.destroy(virtualPad);
		}
		if (padCamera != null)
		{
			FlxG.cameras.remove(padCamera, true);
			padCamera = null;
		}
	}

	public function addPadCamera(DefaultDrawTarget:Bool = false) {
		if (virtualPad != null) {
			if (padCamera == null)
			{
				padCamera = new FlxCamera();
				FlxG.cameras.add(padCamera, DefaultDrawTarget);
				padCamera.bgColor.alpha = 0;
			}
			virtualPad.cameras = [padCamera];
		}
	}

	// ==================== CREATE ====================

	override function create() {
		super.create();

		#if HSCRIPT_ALLOWED initHScripts(); #end

		#if LUA_ALLOWED initLuaScripts(); #end

		setOnHscript('controls', controls);
		setOnHscript('state', this);
		setOnLuas('controls', controls);
		setOnLuas('state', this);

		#if HSCRIPT_ALLOWED callOnHscript('onCreatePost', []); #end

		#if LUA_ALLOWED callOnLuas('onCreatePost', []); #end
	}

	// ==================== OPEN SUBSTATE ====================

	override function openSubState(subState:FlxSubState):Void {
		#if MODS_ALLOWED
		subState = substates.ModSubState.resolveSubState(subState);
		#end
		super.openSubState(subState);
	}

	// ==================== UPDATE ====================

	override function update(elapsed:Float) {
		// 桌面端：驱动拖放安装/下载任务（子状态打开时也能处理）
		ModInstaller.update(elapsed);

		#if (HSCRIPT_ALLOWED || LUA_ALLOWED)
		// Ctrl+Alt+1 → force-reload all HScripts and Lua scripts
		if (FlxG.keys.pressed.CONTROL && FlxG.keys.pressed.ALT && FlxG.keys.justPressed.ONE) {
			reloadScripts();
		}
		#end

		#if LUA_ALLOWED
		var luaRet = callOnLuas('onUpdate', [elapsed]);
		if (luaRet == FunkinLua.Function_StopLua) return;
		#end

		#if HSCRIPT_ALLOWED
		var hxRet = callOnHscript('onUpdate', [elapsed]);
		if (hxRet == FunkinLua.Function_StopHScript) return;
		#end

		var oldStep:Int = curStep;
		updateCurStep();
		updateBeat();
		if (oldStep != curStep && curStep > 0) stepHit();

		super.update(elapsed);

		#if LUA_ALLOWED callOnLuas('onUpdatePost', [elapsed]); #end
		#if HSCRIPT_ALLOWED callOnHscript('onUpdatePost', [elapsed]); #end
	}

	// ==================== SCRIPT RELOAD ====================

	#if (HSCRIPT_ALLOWED || LUA_ALLOWED)
	/** Force-reload all HScript and Lua scripts for this substate. */
	public function reloadScripts():Void {
		TraceManager.info('trace.musicBeatSubstate.reloadScripts', 'Reloading scripts...');
		#if HSCRIPT_ALLOWED
		for (s in hscriptArray) { try { s.stop(); } catch(e:Dynamic) {} }
		hscriptArray = [];
		#end
		#if LUA_ALLOWED
		for (s in luaArray) { try { s.stop(); } catch(e:Dynamic) {} }
		luaArray = [];
		#end
		#if HSCRIPT_ALLOWED
		initHScripts();
		#end
		#if LUA_ALLOWED
		initLuaScripts();
		#end
		setOnHscript('controls', controls);
		setOnHscript('state', this);
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		#if HSCRIPT_ALLOWED
		callOnHscript('onCreatePost', []);
		#end
		#if LUA_ALLOWED
		callOnLuas('onCreatePost', []);
		#end
		TraceManager.info('trace.musicBeatSubstate.reloadDone', 'Scripts reloaded.');
	}
	#end

	// ==================== BEAT / STEP ====================

	public function updateBeat():Void {
		curBeat = Math.floor(curStep / 4);
		curDecBeat = curDecStep/4;
	}

	public function updateCurStep():Void {
		var lastChange = Conductor.getBPMFromSeconds(Conductor.songPosition);
		var shit = ((Conductor.songPosition - ClientPrefs.data.noteOffset) - lastChange.songTime) / lastChange.stepCrochet;
		curDecStep = lastChange.stepTime + shit;
		curStep = lastChange.stepTime + Math.floor(shit);
	}

	public function stepHit():Void {
		var stepArgs:Array<Dynamic> = Scripts.fill1(Scripts.get(1), curStep);
		#if LUA_ALLOWED callOnLuas('onStepHit', stepArgs); #end
		#if HSCRIPT_ALLOWED callOnHscript('onStepHit', stepArgs); #end
		if (curStep % 4 == 0) beatHit();
	}

	public function beatHit():Void {
		var beatArgs:Array<Dynamic> = Scripts.fill1(Scripts.get(1), curBeat);
		#if LUA_ALLOWED callOnLuas('onBeatHit', beatArgs); #end
		#if HSCRIPT_ALLOWED callOnHscript('onBeatHit', beatArgs); #end
	}

	// ==================== PATH HELPERS ====================

	/**
	 * Collects all base paths ordered by priority: currentMod > mods/ > assets/.
	 * 只收集“当前激活 mod”的 substate 脚本，不再遍历其它（未激活的）全局 mod，
	 * 避免整包 mod 的 hscripts/substates/ 泄漏进原生 substate。
	 */
	static function collectSubPaths(subPath:String):Array<String> {
		var paths:Array<String> = [];
		paths.push(Paths.getPreloadPath(subPath));
		#if MODS_ALLOWED
		paths.insert(0, Paths.mods(subPath));
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			paths.insert(0, Paths.mods(Paths.currentModDirectory + '/' + subPath));
		#end
		return paths;
	}

	// ==================== HSCRIPT ====================

	#if HSCRIPT_ALLOWED
	public function initHScripts():Void {
		var stateName:String = Type.getClassName(Type.getClass(this));
		stateName = stateName.substr(stateName.lastIndexOf('.') + 1);
		var loadName = scriptName != null ? scriptName : stateName;
		var filesPushed:Array<String> = [];
		var all:Array<HScript> = [];

		// 1. Standalone: data/states/<Name>.hx
		var standalones:Array<String> = [];
		for (basePath in collectSubPaths('data/states/$loadName'))
			for (ext in ['hx', 'hscript', 'hsc', 'hxs'])
				standalones.push('$basePath.$ext');
		all = all.concat(HScript.collectStandalone(standalones, filesPushed));

		// 2. Directory: data/states/<Name>/
		all = all.concat(HScript.collectFromFolders(collectSubPaths('data/states/$loadName/'), filesPushed));

		// 3. Legacy: hscripts/substates/<stateName>/
		all = all.concat(HScript.collectFromFolders(collectSubPaths('hscripts/substates/$stateName/'), filesPushed));

		hscriptArray = hscriptArray.concat(all);
		TraceManager.info('trace.musicBeatSubstate.scriptsLoaded', 'Loaded {} hscripts for {}', [all.length, loadName]);
	}

	public function callOnHscript(event:String, args:Array<Dynamic> = null, ignoreStops:Bool = false, exclusions:Array<String> = null):Dynamic {
		if (args == null) args = [];
		if (exclusions == null) exclusions = [];
		var returnVal:Dynamic = FunkinLua.Function_Continue;

		var globalResult = HScript.callOnGlobalScript(event, args);
		if (globalResult == FunkinLua.Function_StopHScript && !ignoreStops) return globalResult;

		for (script in hscriptArray) {
			if (exclusions.contains(script.scriptName) || script.closed) continue;
			var ret = script.call(event, args);
			if (ret == FunkinLua.Function_StopHScript && !ignoreStops) { returnVal = ret; break; }
			if (ret != FunkinLua.Function_Continue) returnVal = ret;
		}
		return returnVal;
	}

	public function setOnHscript(variable:String, arg:Dynamic):Void {
		HScript.setOnGlobalScript(variable, arg);
		for (script in hscriptArray) if (!script.closed) script.set(variable, arg);
	}
	#else
	public function callOnHscript(event:String, args:Array<Dynamic> = null, ignoreStops:Bool = false, exclusions:Array<String> = null):Dynamic {
		return 0;
	}
	public function setOnHscript(variable:String, arg:Dynamic):Void {}
	#end

	// ==================== LUA ====================

	#if LUA_ALLOWED
	public function initLuaScripts():Void {
		var stateName:String = Type.getClassName(Type.getClass(this));
		stateName = stateName.substr(stateName.lastIndexOf('.') + 1);
		var loadName = scriptName != null ? scriptName : stateName;
		var filesPushed:Array<String> = [];
		var all:Array<FunkinLua> = [];

		// 1. Standalone: data/states/<Name>.lua
		var standalones:Array<String> = [];
		for (basePath in collectSubPaths('data/states/$loadName'))
			standalones.push('$basePath.lua');
		all = all.concat(FunkinLua.collectStandalone(standalones, filesPushed));

		// 2. Directory: data/states/<Name>/
		all = all.concat(FunkinLua.collectFromFolders(collectSubPaths('data/states/$loadName/'), filesPushed));

		// 3. Legacy: lua/substates/<stateName>/
		all = all.concat(FunkinLua.collectFromFolders(collectSubPaths('lua/substates/$stateName/'), filesPushed));

		luaArray = luaArray.concat(all);
		TraceManager.info('trace.musicBeatSubstate.luaLoaded', 'Loaded {} lua scripts for {}', [all.length, loadName]);
	}

	public function callOnLuas(funcToCall:String, args:Array<Dynamic> = null, ignoreStops:Bool = false, exclusions:Array<String> = null, excludeValues:Array<Dynamic> = null):Dynamic {
		if (args == null) args = [];
		if (exclusions == null) exclusions = [];
		if (excludeValues == null) excludeValues = [];
		var returnVal:Dynamic = FunkinLua.Function_Continue;

		for (script in luaArray) {
			if (script.closed) continue;
			if (exclusions.contains(script.scriptName)) continue;
			if (excludeValues.contains(script)) continue;

			var ret = script.call(funcToCall, args);
			if (ret == FunkinLua.Function_StopLua && !ignoreStops) { returnVal = ret; break; }
			if (ret != FunkinLua.Function_Continue) returnVal = ret;
		}
		return returnVal;
	}

	public function setOnLuas(variable:String, arg:Dynamic, exclusions:Array<String> = null):Void {
		if (exclusions == null) exclusions = [];
		for (script in luaArray) {
			if (script.closed) continue;
			if (exclusions.contains(script.scriptName)) continue;
			script.set(variable, arg);
		}
	}
	#end

	/** Get a Lua-created object (modchart sprite/text, or shared variable) */
	public function getLuaObject(tag:String, text:Bool = true):FlxSprite {
		if (modchartSprites.exists(tag)) return modchartSprites.get(tag);
		if (text && modchartTexts.exists(tag)) return modchartTexts.get(tag);
		if (variables.exists(tag)) return variables.get(tag);
		return null;
	}

	/** Add a debug trace line visible on screen (used by luaTrace) */
	public function addTextToDebug(text:String, color:FlxColor) {
		if (luaDebugGroup == null) return;
		luaDebugGroup.forEachAlive(function(spr:DebugLuaText) {
			spr.y += 20;
		});
		if (luaDebugGroup.members.length > 34) {
			var blah = luaDebugGroup.members[34];
			blah.destroy();
			luaDebugGroup.remove(blah);
		}
		luaDebugGroup.insert(0, new DebugLuaText(text, luaDebugGroup, color));
	}

	#if LUA_ALLOWED
	#if (!flash && sys)
	public function createRuntimeShader(name:String):FlxRuntimeShader {
		if (!ClientPrefs.data.shaders) return new FlxRuntimeShader();
		#if (!flash && MODS_ALLOWED && sys)
		if (!runtimeShaders.exists(name) && !initLuaShader(name)) {
			FlxG.log.warn('Shader $name is missing!');
			return new FlxRuntimeShader();
		}
		var arr:Array<String> = runtimeShaders.get(name);
		return new FlxRuntimeShader(arr[0], arr[1]);
		#else
		FlxG.log.warn("Platform unsupported for Runtime Shaders!");
		return null;
		#end
	}

	public function initLuaShader(name:String, ?glslVersion:Int = 120):Bool {
		if (!ClientPrefs.data.shaders) return false;
		if (runtimeShaders.exists(name)) {
			FlxG.log.warn('Shader $name was already initialized!');
			return true;
		}
		var foldersToCheck:Array<String> = [Paths.mods('shaders/')];
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			foldersToCheck.insert(0, Paths.mods(Paths.currentModDirectory + '/shaders/'));
		for (mod in Paths.getGlobalMods())
			foldersToCheck.insert(0, Paths.mods(mod + '/shaders/'));
		for (folder in foldersToCheck) {
			if (FileSystem.exists(folder)) {
				var frag:String = folder + name + '.frag';
				var vert:String = folder + name + '.vert';
				var found:Bool = false;
				if (FileSystem.exists(frag)) { frag = File.getContent(frag); found = true; } else frag = null;
				if (FileSystem.exists(vert)) { vert = File.getContent(vert); found = true; } else vert = null;
				if (found) { runtimeShaders.set(name, [frag, vert]); return true; }
			}
		}
		FlxG.log.warn('Missing shader $name .frag AND .vert files!');
		return false;
	}
	#end
	#else
	public function callOnLuas(funcToCall:String, args:Array<Dynamic> = null, ignoreStops:Bool = false, exclusions:Array<String> = null, excludeValues:Array<Dynamic> = null):Dynamic {
		return 0; // Function_Continue
	}
	public function setOnLuas(variable:String, arg:Dynamic, exclusions:Array<String> = null):Void {}
	#end

	// ==================== DESTROY ====================

	override function destroy():Void {
		if (trackedinputsUI.length > 0) controls.removeVirtualControlsInput(trackedinputsUI);
		#if HSCRIPT_ALLOWED
		if (hscriptArray != null) {
			for (script in hscriptArray) script.stop();
			hscriptArray = [];
		}
		#end

		#if LUA_ALLOWED
		if (luaArray != null) {
			for (lua in luaArray) {
				lua.stop();
				lua.closed = true;
			}
			luaArray = [];
		}
		#end

		super.destroy();
		if (virtualPad != null) virtualPad = FlxDestroyUtil.destroy(virtualPad);
		if (padCamera != null) { FlxG.cameras.remove(padCamera, true); padCamera = null; }
	}
}
