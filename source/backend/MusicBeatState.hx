package backend;

import Conductor.BPMChangeEvent;
import flixel.FlxG;
import flixel.addons.ui.FlxUIState;
import flixel.math.FlxRect;
import flixel.util.FlxTimer;
import flixel.addons.transition.FlxTransitionableState;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import flixel.FlxSprite;
import flixel.util.FlxColor;
import flixel.util.FlxGradient;
import flixel.FlxState;
import flixel.FlxSubState;
import flixel.FlxCamera;
import flixel.FlxBasic;
import flixel.util.FlxSave;
import flixel.system.FlxSound;
import flixel.group.FlxGroup.FlxTypedGroup;

#if HSCRIPT_ALLOWED
import script.hscript.HScript;
#end

import script.lua.FunkinLua;

import script.lua.ModchartSprite;
import script.lua.ModchartText;
import script.lua.DebugLuaText;

#if (!flash && sys)
import flixel.addons.display.FlxRuntimeShader;
#end

import flixel.input.actions.FlxActionInput;
import flixel.util.FlxDestroyUtil;
import android.AndroidControls;
import android.flixel.FlxVirtualPad;
import mohong.TraceManager;

class MusicBeatState extends FlxUIState
{
	public var curSection:Int = 0;
	public var curStep:Int = 0;
	public var curBeat:Int = 0;
	public var curDecStep:Float = 0;
	public var curDecBeat:Float = 0;
	public var controls(get, never):Controls;

	private var stepsToDo:Int = 0;

	public static var camBeat:FlxCamera;

	/** When true, the next state switch uses a snappier menu transition fade. */
	public static var quickMenuTransition:Bool = false;

	public var scriptName:String = null;

	public function new(?scriptName:String) {
		super();
		this.scriptName = scriptName;
	}


	#if HSCRIPT_ALLOWED
	public var hscriptArray:Array<HScript> = [];
	#end

	public var luaArray:Array<FunkinLua> = [];
	public var variables:Map<String, Dynamic> = new Map<String, Dynamic>();
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

	inline function get_controls():Controls
		return PlayerSettings.player1.controls;


	var androidControls:AndroidControls;
	var virtualPad:FlxVirtualPad;
	var trackedinputsUI:Array<FlxActionInput> = [];
	var trackedinputsNOTES:Array<FlxActionInput> = [];
	var padCamera:FlxCamera;

	/**
	 * 创建菜单虚拟按键。安卓/iOS 始终启用; 桌面端只有开启"触屏支持"后才显示。
	 */
	public function addVirtualPad(DPad:FlxDPadMode, Action:FlxActionMode)
	{
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

	public function removeVirtualPad()
	{
		if (trackedinputsUI != []) controls.removeVirtualControlsInput(trackedinputsUI);
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

	public function addPadCamera(DefaultDrawTarget:Bool = false)
	{
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

	/**
	 * 创建安卓移动端控件 (虚拟按键/Hitbox)。
	 * 安卓/iOS 始终启用; 桌面端只有开启"触屏支持"设置后才创建。
	 */
	public function addAndroidControls(DefaultDrawTarget:Bool = false, ?withPauseButton:Bool = false)
	{
		#if !TOUCH_CONTROLS
		if (!ClientPrefs.data.touchControls)
			return;
		#end
		if (androidControls != null) removeAndroidControls();
		androidControls = new AndroidControls();
		switch (AndroidControls.mode)
		{
			case 'Pad-Right' | 'Pad-Left' | 'Pad-Custom':
				controls.setVirtualPadNOTES(androidControls.virtualPad, RIGHT_FULL, NONE);
			case 'Hitbox': controls.setHitBox(androidControls.hitbox);
			case 'Keyboard': // do nothing
		}

		if (withPauseButton && androidControls != null)
		{
			androidControls.addPauseButton();
			if (androidControls.pauseButton != null)
				controls.addButtonNOTES(@:privateAccess controls._pause, androidControls.pauseButton, flixel.input.FlxInput.FlxInputState.JUST_PRESSED);
		}

		trackedinputsNOTES = controls.trackedinputsNOTES;
		controls.trackedinputsNOTES = [];
		var camControls:FlxCamera = new FlxCamera();
		FlxG.cameras.add(camControls, DefaultDrawTarget);
		camControls.bgColor.alpha = 0;
		androidControls.cameras = [camControls];
		androidControls.visible = false;
		add(androidControls);
	}

	public function removeAndroidControls()
	{
		if (trackedinputsNOTES != []) controls.removeVirtualControlsInput(trackedinputsNOTES);
		if (androidControls != null) remove(androidControls);
	}

	// ==================== CREATE ====================

	override function create() {
		camBeat = FlxG.camera;
		Language.load();
		var skip:Bool = FlxTransitionableState.skipNextTransOut;
		super.create();
		var fadeTime:Float = quickMenuTransition ? 0.35 : 0.7;
		if(!skip) openSubState(new CustomFadeTransition(fadeTime, true));
		quickMenuTransition = false;
		FlxTransitionableState.skipNextTransOut = false;

		#if HSCRIPT_ALLOWED
		initHScripts();
		#end

		var stateName:String = Type.getClassName(Type.getClass(this));
		stateName = stateName.substr(stateName.lastIndexOf('.') + 1);
		setOnHscript('controls', controls);
		setOnHscript('state', this);
		setOnHscript('currentStateName', stateName);

		#if HSCRIPT_ALLOWED
		callOnHscript('onCreatePost', []);
		#end
	}

	// ==================== OPEN SUBSTATE ====================

	override function openSubState(subState:FlxSubState):Void {
		#if MODS_ALLOWED
		subState = substates.ModSubState.resolveSubState(subState);
		#end
		super.openSubState(subState);
	}

	// ==================== SCRIPT RELOAD ====================

	#if (HSCRIPT_ALLOWED || LUA_ALLOWED)
	/** Force-reload all HScript and Lua scripts for this state. */
	public function reloadScripts():Void {
		TraceManager.info('trace.musicBeatState.reloadScripts', 'Reloading scripts...');
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
		setOnLuas('state', this);
		#if HSCRIPT_ALLOWED
		callOnHscript('onCreatePost', []);
		#end
		#if LUA_ALLOWED
		callOnLuas('onCreatePost', []);
		#end
		TraceManager.info('trace.musicBeatState.reloadDone', 'Scripts reloaded.');
	}
	#end

	// ==================== UPDATE ====================

	override function update(elapsed:Float)
	{
		// 桌面端：驱动拖放安装/下载任务（任意状态下都可拖 zip/链接进窗口）
		ModInstaller.update(elapsed);

		#if (HSCRIPT_ALLOWED || LUA_ALLOWED)
		// Ctrl+Alt+1 → force-reload all HScripts and Lua scripts
		if (FlxG.keys.pressed.CONTROL && FlxG.keys.pressed.ALT && FlxG.keys.justPressed.ONE) {
			reloadScripts();
		}
		#end

		var oldStep:Int = curStep;
		updateCurStep();
		updateBeat();

		if (oldStep != curStep) {
			if (curStep > 0) stepHit();
			if (PlayState.SONG != null) {
				if (oldStep < curStep) updateSection();
				else rollbackSection();
			}
		}

		if (FlxG.save.data != null) FlxG.save.data.fullscreen = FlxG.fullscreen;

		// 组容器成员守卫: 已死掉的成员会让 FlxTypedGroup.update 里的 Dynamic->FlxBasic
		// 转换读到空 vtable, 主线程直接 ACCESS_VIOLATION。这里在最外层 update 之前
		// 把它摘掉 —— 详见 backend.GroupGuard。
		GroupGuard.tick(this);

		super.update(elapsed);
	}

	// ==================== BEAT / STEP / SECTION ====================

	public function updateSection():Void {
		if(stepsToDo < 1) stepsToDo = Math.round(getBeatsOnSection() * 4);
		while(curStep >= stepsToDo) {
			curSection++;
			var beats:Float = getBeatsOnSection();
			stepsToDo += Math.round(beats * 4);
			sectionHit();
		}
	}

	public function rollbackSection():Void {
		if(curStep < 0) return;
		if (PlayState.SONG == null || PlayState.SONG.notes == null)
		{
			curSection = 0;
			stepsToDo = 0;
			return;
		}
		var lastSection:Int = curSection;
		curSection = 0;
		stepsToDo = 0;
		for (i in 0...PlayState.SONG.notes.length) {
			if (PlayState.SONG.notes[i] != null) {
				stepsToDo += Math.round(getBeatsOnSection() * 4);
				if(stepsToDo > curStep) break;
				curSection++;
			}
		}
		if(curSection > lastSection) sectionHit();
	}

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

	// ==================== STATE SWITCHING ====================

	public static function switchState(nextState:FlxState) {
		#if MODS_ALLOWED
		nextState = states.ModState.resolveState(nextState);
		#end

		var curState:Dynamic = FlxG.state;
		var leState:MusicBeatState = curState;
		if(!FlxTransitionableState.skipNextTransIn) {
			var transitionTime:Float = quickMenuTransition ? 0.25 : 0.6;
			leState.openSubState(new CustomFadeTransition(transitionTime, false));
			if(nextState == FlxG.state)
				CustomFadeTransition.finishCallback = function() { FlxG.resetState(); }
			else
				CustomFadeTransition.finishCallback = function() { FlxG.switchState(nextState); }
			return;
		}
		FlxTransitionableState.skipNextTransIn = false;
		FlxG.switchState(nextState);
	}

	public static function resetState() { MusicBeatState.switchState(FlxG.state); }

	public static function getState():MusicBeatState {
		var curState:Dynamic = FlxG.state;
		return cast curState;
	}

	public function stepHit():Void {
		#if HSCRIPT_ALLOWED callOnHscript('onStepHit', [curStep]); #end
		if (curStep % 4 == 0) beatHit();
	}

	public function beatHit():Void {
		#if HSCRIPT_ALLOWED callOnHscript('onBeatHit', [curBeat]); #end
	}

	public function sectionHit():Void {
		#if HSCRIPT_ALLOWED callOnHscript('onSectionHit', [curSection]); #end
	}

	public function getBeatsOnSection():Float {
		var val:Null<Float> = 4;
		if(PlayState.SONG != null && PlayState.SONG.notes != null
			&& curSection >= 0 && curSection < PlayState.SONG.notes.length
			&& PlayState.SONG.notes[curSection] != null)
			val = PlayState.SONG.notes[curSection].sectionBeats;
		return val == null ? 4 : val;
	}

	// ==================== PATH HELPERS ====================

	/**
	 * Collects all base paths ordered by priority: currentMod > mods/ > assets/.
	 *
	 * 只收集“当前激活 mod”的 state 脚本，不再遍历 runsGlobally 的其它全局 mod。
	 * 否则未选中的整包 mod 会把它的 hscripts/<state>/、data/states/<Name> 脚本
	 * 泄漏进原生 state（滤镜/位移/黑屏等渗透到其它 state）。全局 mod 的全局
	 * 注入仍走 HScript.loadGlobalScripts()（根 hscripts/*.hx），与该函数正交。
	 */
	static function collectPaths(subPath:String):Array<String> {
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
		for (basePath in collectPaths('data/states/$loadName'))
			for (ext in ['hx', 'hscript', 'hsc', 'hxs'])
				standalones.push('$basePath.$ext');
		all = all.concat(HScript.collectStandalone(standalones, filesPushed));

		// 2. Directory: data/states/<Name>/
		all = all.concat(HScript.collectFromFolders(collectPaths('data/states/$loadName/'), filesPushed));

		// 3. Legacy: hscripts/<stateName>/
		all = all.concat(HScript.collectFromFolders(collectPaths('hscripts/$stateName/'), filesPushed));

		hscriptArray = hscriptArray.concat(all);
		TraceManager.info('trace.musicBeatState.scriptsLoaded', 'Loaded {} hscripts for {}', [all.length, loadName]);
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
		for (basePath in collectPaths('data/states/$loadName'))
			standalones.push('$basePath.lua');
		all = all.concat(FunkinLua.collectStandalone(standalones, filesPushed));

		// 2. Directory: data/states/<Name>/
		all = all.concat(FunkinLua.collectFromFolders(collectPaths('data/states/$loadName/'), filesPushed));

		// 3. Legacy: lua/<stateName>/
		all = all.concat(FunkinLua.collectFromFolders(collectPaths('lua/$stateName/'), filesPushed));

		luaArray = luaArray.concat(all);
		TraceManager.info('trace.musicBeatState.luaLoaded', 'Loaded {} lua scripts for {}', [all.length, loadName]);
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

			// 只记录一次性的创建回调，便于确认某个脚本到底有没有收到 onCreate/onCreatePost。
			if (funcToCall == 'onCreate' || funcToCall == 'onCreatePost')
				backend.ScriptLog.write('callback', funcToCall + ' -> ' + script.scriptName);

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
				if (FileSystem.exists(frag)) {
					frag = File.getContent(frag);
					found = true;
				} else frag = null;

				if (FileSystem.exists(vert)) {
					vert = File.getContent(vert);
					found = true;
				} else vert = null;

				if (found) {
					runtimeShaders.set(name, [frag, vert]);
					return true;
				}
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
		if (trackedinputsNOTES != []) controls.removeVirtualControlsInput(trackedinputsNOTES);
		if (trackedinputsUI != []) controls.removeVirtualControlsInput(trackedinputsUI);
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
		if (virtualPad != null) { virtualPad = FlxDestroyUtil.destroy(virtualPad); virtualPad = null; }
		if (androidControls != null) { androidControls = FlxDestroyUtil.destroy(androidControls); androidControls = null; }
		if (padCamera != null) { FlxG.cameras.remove(padCamera, true); padCamera = null; }

	}
}
