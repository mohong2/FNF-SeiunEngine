package editors;

#if LUA_ALLOWED
import llua.Lua;
import llua.LuaL;
import llua.State;
import llua.Convert;
#end

 
 
 
 
 
 
import flixel.system.FlxSound;
 
 
 
 
import flixel.FlxBasic;
#if sys
import sys.FileSystem;
import sys.io.File;
#end
import Type.ValueType;
import Controls;
import DialogueBoxPsych;
import script.lua.FunkinLua;

#if cpp
import Discord;
#end

using StringTools;

class EditorLua {
	public static var Function_Stop = "##PSYCHLUA_FUNCTIONSTOP";
	public static var Function_Continue = "##PSYCHLUA_FUNCTIONCONTINUE";

	#if LUA_ALLOWED
	public var lua:State = null;
	#end

	public function new(script:String) {
		#if LUA_ALLOWED
		lua = LuaL.newstate();
		LuaL.openlibs(lua);
		Lua.init_callbacks(lua);
		backend.NativeCrash.installLuaPanic(lua);

		//trace('Lua version: ' + Lua.version());
		//trace("LuaJIT version: " + Lua.versionJIT());

		var result:Dynamic = LuaL.dofile(lua, script);
		var resultStr:String = Lua.tostring(lua, result);
		if(resultStr != null && result != 0) {
			SUtil.showPopUp(resultStr, 'Error on .LUA script!');
			lime.app.Application.current.window.alert(resultStr, 'Error on .LUA script!');
			CoolUtil.traceMsg('trace.luaError', 'Error on .LUA script! {}', [resultStr]);
			lua = null;
			return;
		}
		CoolUtil.traceMsg('trace.luaLoaded', 'Lua file loaded successfully: {}', [script]);

		// Lua variables
		set('Function_Stop', Function_Stop);
		set('Function_Continue', Function_Continue);
		set('inChartEditor', true);

		set('curBpm', Conductor.bpm);
		set('bpm', PlayState.SONG != null ? PlayState.SONG.bpm : 100);
		set('scrollSpeed', PlayState.SONG != null ? PlayState.SONG.speed : 1);
		set('crochet', Conductor.crochet);
		set('stepCrochet', Conductor.stepCrochet);
		set('songLength', (FlxG.sound.music != null) ? FlxG.sound.music.length : 0);
		set('songName', PlayState.SONG != null ? PlayState.SONG.song : '');

		set('screenWidth', FlxG.width);
		set('screenHeight', FlxG.height);

		for (i in 0...4) {
			set('defaultPlayerStrumX' + i, 0);
			set('defaultPlayerStrumY' + i, 0);
			set('defaultOpponentStrumX' + i, 0);
			set('defaultOpponentStrumY' + i, 0);
		}

		set('downscroll', ClientPrefs.data.downScroll);
		set('middlescroll', ClientPrefs.data.middleScroll);

		//stuff 4 noobz like you B)
		Lua_helper.add_callback(lua, "getProperty", function(variable:String, ?allowMaps:Bool = false) {
			var killMe:Array<String> = variable.split('.');
			if(killMe.length > 1) {
				var coverMeInPiss:Dynamic = Reflect.getProperty(EditorPlayState.instance, killMe[0]);

				for (i in 1...killMe.length-1) {
					coverMeInPiss = Reflect.getProperty(coverMeInPiss, killMe[i]);
				}
				return Reflect.getProperty(coverMeInPiss, killMe[killMe.length-1]);
			}
			return Reflect.getProperty(EditorPlayState.instance, variable);
		});
		Lua_helper.add_callback(lua, "setProperty", function(variable:String, value:Dynamic, ?allowMaps:Bool = false, ?allowInstances:Bool = false) {
			var killMe:Array<String> = variable.split('.');
			if(killMe.length > 1) {
				var coverMeInPiss:Dynamic = Reflect.getProperty(EditorPlayState.instance, killMe[0]);

				for (i in 1...killMe.length-1) {
					coverMeInPiss = Reflect.getProperty(coverMeInPiss, killMe[i]);
				}
				return Reflect.setProperty(coverMeInPiss, killMe[killMe.length-1], value);
			}
			return Reflect.setProperty(EditorPlayState.instance, variable, value);
		});
		Lua_helper.add_callback(lua, "getPropertyFromGroup", function(obj:String, index:Int, variable:Dynamic, ?allowMaps:Bool = false) {
			var groupObj:Dynamic = Reflect.getProperty(EditorPlayState.instance, obj);
			if(groupObj == null) return null;
			if(Std.isOfType(groupObj, FlxTypedGroup)) {
				if(groupObj.members == null || index < 0 || index >= groupObj.members.length) return null;
				return Reflect.getProperty(Reflect.getProperty(EditorPlayState.instance, obj).members[index], variable);
			}

			var leArray:Dynamic = Reflect.getProperty(EditorPlayState.instance, obj)[index];
			if(leArray != null) {
				if(Type.typeof(variable) == ValueType.TInt) {
					return leArray[variable];
				}
				return Reflect.getProperty(leArray, variable);
			}
			return null;
		});
		Lua_helper.add_callback(lua, "setPropertyFromGroup", function(obj:String, index:Int, variable:Dynamic, value:Dynamic, ?allowMaps:Bool = false, ?allowInstances:Bool = false) {
			var groupObjS:Dynamic = Reflect.getProperty(EditorPlayState.instance, obj);
			if(groupObjS == null) return null;
			if(Std.isOfType(groupObjS, FlxTypedGroup)) {
				if(groupObjS.members == null || index < 0 || index >= groupObjS.members.length) return null;
				return Reflect.setProperty(Reflect.getProperty(EditorPlayState.instance, obj).members[index], variable, value);
			}

			var leArray:Dynamic = Reflect.getProperty(EditorPlayState.instance, obj)[index];
			if(leArray != null) {
				if(Type.typeof(variable) == ValueType.TInt) {
					return leArray[variable] = value;
				}
				return Reflect.setProperty(leArray, variable, value);
			}
		});
		// 1.0.4: removeFromGroup(group, ?index = -1, ?tag = null, ?destroy = true)
		// 第三参为 Bool 时按 0.6.3 旧签名 removeFromGroup(group, index, dontDestroy) 处理。
		Lua_helper.add_callback(lua, "removeFromGroup", function(obj:String, ?index:Any = null, ?tagOrDontDestroy:Any = null, ?destroy:Bool = true) {
			var groupOrArray:Dynamic = Reflect.getProperty(EditorPlayState.instance, obj);
			if(groupOrArray == null) return;
			// 全部走 Dynamic 访问, 不把 x.members 硬 cast 成 Array<Dynamic>。
			var idx:Int = FunkinLua.anyToInt(index, -1);

			if(Std.isOfType(tagOrDontDestroy, Bool))
			{
				var dontDestroy:Bool = cast tagOrDontDestroy;
				var members:Dynamic = Reflect.field(groupOrArray, "members");
				if(members != null)
				{
					if(idx < 0 || idx >= members.length) return;
					var sex:Dynamic = members[idx];
					if(sex == null) return;
					if(!dontDestroy && Reflect.hasField(sex, "kill")) sex.kill();
					Reflect.callMethod(groupOrArray, Reflect.field(groupOrArray, "remove"), [sex, true]);
					if(!dontDestroy && Reflect.hasField(sex, "destroy")) sex.destroy();
					return;
				}
				if(idx >= 0 && idx < groupOrArray.length)
					Reflect.callMethod(groupOrArray, Reflect.field(groupOrArray, "remove"), [groupOrArray[idx]]);
				return;
			}

			var target:Dynamic = null;
			if(tagOrDontDestroy != null)
			{
				var tag:String = Std.string(tagOrDontDestroy);
				target = Reflect.getProperty(EditorPlayState.instance, tag);
				if(target == null) return;
			}

			var members104:Dynamic = Reflect.field(groupOrArray, "members");
			if(members104 != null)
			{
				if(target == null)
				{
					if(idx < 0 || idx >= members104.length) return;
					target = members104[idx];
				}
				if(target == null) return;
				Reflect.callMethod(groupOrArray, Reflect.field(groupOrArray, "remove"), [target, true]);
				if(destroy && Reflect.hasField(target, "destroy")) target.destroy();
				return;
			}

			if(target != null)
			{
				Reflect.callMethod(groupOrArray, Reflect.field(groupOrArray, "remove"), [target]);
				if(destroy && Reflect.hasField(target, "destroy")) target.destroy();
			}
			else if(idx >= 0 && idx < groupOrArray.length)
			{
				Reflect.callMethod(groupOrArray, Reflect.field(groupOrArray, "remove"), [groupOrArray[idx]]);
			}
		});

		Lua_helper.add_callback(lua, "getColorFromHex", function(color:String) {
			if(!color.startsWith('0x')) color = '0xff' + color;
			return Std.parseInt(color);
		});

		// 1.0.4: setGraphicSize(obj, x:Float, y = 0, updateHitbox = true)
		Lua_helper.add_callback(lua, "setGraphicSize", function(obj:String, x:Float, y:Float = 0, ?updateHitbox:Bool = true) {
			var poop:FlxSprite = Reflect.getProperty(EditorPlayState.instance, obj);
			if(poop != null) {
				poop.setGraphicSize(Std.int(x), Std.int(y));
				if(updateHitbox) poop.updateHitbox();
				return;
			}
		});
		// 1.0.4: scaleObject(obj, x, y, updateHitbox = true)
		Lua_helper.add_callback(lua, "scaleObject", function(obj:String, x:Float, y:Float, ?updateHitbox:Bool = true) {
			var poop:FlxSprite = Reflect.getProperty(EditorPlayState.instance, obj);
			if(poop != null) {
				poop.scale.set(x, y);
				if(updateHitbox) poop.updateHitbox();
				return;
			}
		});
		Lua_helper.add_callback(lua, "updateHitbox", function(obj:String) {
			var poop:FlxSprite = Reflect.getProperty(EditorPlayState.instance, obj);
			if(poop != null) {
				poop.updateHitbox();
				return;
			}
		});

		Discord.DiscordClient.addLuaCallbacks(lua);

		call('onCreate', []);
		#end
	}
	
	public function call(event:String, args:Array<Dynamic>):Dynamic {
		#if LUA_ALLOWED
		if(lua == null) {
			return Function_Continue;
		}

		Lua.getglobal(lua, event);

		for (arg in args) {
			Convert.toLua(lua, arg);
		}

		var result:Null<Int> = Lua.pcall(lua, args.length, 1, 0);
		if(result != null && resultIsAllowed(lua, result)) {
			/*var resultStr:String = Lua.tostring(lua, result);
			var error:String = Lua.tostring(lua, -1);
			Lua.pop(lua, 1);*/
			if(Lua.type(lua, -1) == Lua.LUA_TSTRING) {
				var error:String = Lua.tostring(lua, -1);
				Lua.pop(lua, 1);
				if(error == 'attempt to call a nil value') { //Makes it ignore warnings and not break stuff if you didn't put the functions on your lua file
					return Function_Continue;
				}
			}

			var conv:Dynamic = Convert.fromLua(lua, result);
			return conv;
		}
		#end
		return Function_Continue;
	}

	#if LUA_ALLOWED
	function resultIsAllowed(leLua:State, leResult:Null<Int>) { //Makes it ignore warnings
		switch(Lua.type(leLua, leResult)) {
			case Lua.LUA_TNIL | Lua.LUA_TBOOLEAN | Lua.LUA_TNUMBER | Lua.LUA_TSTRING | Lua.LUA_TTABLE:
				return true;
		}
		return false;
	}
	#end

	public function set(variable:String, data:Dynamic) {
		#if LUA_ALLOWED
		if(lua == null) {
			return;
		}

		// 与 FunkinLua.set 保持一致：类实例等无法安全转换的值静默置 nil。
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

		// YES! FINALLY IT WORKS
		//trace('variable: ' + variable + ', ' + result);
		return (result == 'true');
	}
	#end

	public function stop() {
		#if LUA_ALLOWED
		if(lua == null) {
			return;
		}

		Lua.close(lua);
		lua = null;
		#end
	}
}