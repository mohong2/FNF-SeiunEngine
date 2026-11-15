package script.hscript;

import script.lua.FunkinLua;
import flixel.util.FlxColor;
import mohong.TraceManager;

#if LUA_ALLOWED
import llua.Lua;
import llua.LuaL;
import llua.State;
import llua.Convert;
#end

/**
 * LuaApi - HScript 与 Lua 之间的桥接 API。
 * English: LuaApi — the bridge API between HScript and Lua.
 *
 * 与旧版（0.2.x）相比，本版修复了三个核心问题：
 * 1. 旧版把 Lua 函数用 Convert.fromLua 转成 LuaCallback 后直接塞回
 *    Lua_helper.add_callback，导致包装函数无法调用"原函数"；现在原函数
 *    以可调用的 Haxe 代理形式传给包装器，override 里 `original(...)` 可用。
 * 2. 引擎内置回调（getProperty 等）本质是 Haxe 闭包，旧版只备份了 Lua 侧
 *    C 闭包，覆盖后调用原函数会死循环；现在优先备份 Haxe 闭包本身。
 * 3. 新增 callLuaFunction / setLuaVariable / getLuaVariable /
 *    renameLuaFunction 等双向互操作 API。
 * Compared to 0.2.x, this rewrite fixes three core issues:
 * 1. The old version converted Lua functions via Convert.fromLua and re-fed
 *    them into Lua_helper.add_callback, so wrappers could never call the
 *    "original". Now the original is passed to wrappers as a callable Haxe
 *    proxy, so `original(...)` works inside overrides.
 * 2. Engine callbacks (getProperty, etc.) are Haxe closures under the hood;
 *    the old version backed up only the Lua-side C closure, which caused
 *    infinite recursion when calling the original after an override. Now the
 *    Haxe closure itself is backed up first.
 * 3. Added bidirectional APIs: callLuaFunction / setLuaVariable /
 *    getLuaVariable / renameLuaFunction.
 *
 * HScript 用法：
 * ```
 * // 新增全局 Lua 函数
 * LuaApi.addLuaFunction("myFunc", function(x, y) return x + y;);
 *
 * // 覆盖已有函数，wrapper 第一个参数是"原函数"代理
 * LuaApi.overrideLuaFunction("getProperty", function(original, variable, allowMaps) {
 *     trace('Intercepted: ' + variable);
 *     return original(variable, allowMaps);
 * });
 *
 * // 调用 Lua 里的函数 / 读写 Lua 全局变量
 * LuaApi.callLuaFunction("myLuaFunc", [1, 2]);
 * LuaApi.setLuaVariable("myVar", 42);
 * ```
 */
class LuaApi {

	// 原始函数备份：name -> Haxe 闭包（引擎回调）或可调用代理（Lua 定义函数）
	// English: original-function backups: name -> Haxe closure (engine callback)
	// or a callable proxy (Lua-defined function)
	private static var originalFunctions:Map<String, Dynamic> = new Map<String, Dynamic>();

	// 自定义 / 覆盖后注册到 Lua 的函数
	// English: functions added/overridden and registered to Lua
	private static var customFunctions:Map<String, Dynamic> = new Map<String, Dynamic>();

	// 被 overrideLuaFunction 覆盖过的名字
	// English: names that were overridden via overrideLuaFunction
	private static var overriddenFunctions:Map<String, Bool> = new Map<String, Bool>();

	// Lua 定义的原函数：name -> 每个活跃 state 上的 registry 引用（恢复时逐 state 写回）
	// English: Lua-defined originals: name -> registry refs on every active
	// state (written back per-state when restoring)
	private static var luaDefinedOriginals:Map<String, Array<LuaRef>> = new Map<String, Array<LuaRef>>();

	/**
	 * 初始化 LuaApi（无副作用，保留兼容）。
	 * English: Initialize LuaApi (no side effects; kept for compatibility).
	 */
	public static function initialize():Void {
		TraceManager.info('trace.luaApi.initialized', 'LuaApi initialized');
	}

	/**
	 * 新增一个全局 Lua 函数，所有活跃 Lua 实例均可调用。
	 * English: Add a new global Lua function callable from every active Lua instance.
	 *
	 * @param functionName Lua 全局函数名
	 * @param func Haxe 函数
	 * @param overrideExisting 同名已存在时是否强制覆盖
	 * @return Bool 是否成功
	 */
	public static function addLuaFunction(functionName:String, func:Dynamic, overrideExisting:Bool = false):Bool {
		if (functionName == null || functionName.length == 0) {
			TraceManager.warn('trace.luaApi.invalidName', 'LuaApi: Invalid function name');
			return false;
		}

		if (func == null || !Reflect.isFunction(func)) {
			TraceManager.error('trace.luaApi.invalidFunction', 'LuaApi: Invalid function provided for "{}"', [functionName]);
			return false;
		}

		#if LUA_ALLOWED
		try {
			if (luaFunctionExists(functionName)) {
				if (!overrideExisting) {
					TraceManager.warn('trace.luaApi.alreadyExists', 'LuaApi: Function "{}" already exists. Use overrideLuaFunction() or overrideExisting=true.', [functionName]);
					return false;
				}
				backupOriginal(functionName);
			}

			customFunctions.set(functionName, func);
			registerFunctionToAllLuaInstances(functionName, func);

			TraceManager.info('trace.luaApi.added', 'LuaApi: Function "{}" added successfully', [functionName]);
			return true;
		} catch (e:Dynamic) {
			TraceManager.error('trace.luaApi.addError', 'LuaApi: Error adding function "{}": {}', [functionName, e]);
			return false;
		}
		#else
		TraceManager.warn('trace.luaApi.unsupported', 'LuaApi: Lua not supported on this platform');
		return false;
		#end
	}

	/**
	 * 覆盖一个已存在的 Lua 函数。
	 * wrapperFunc 的第一个参数是"原函数"代理，可以像普通函数一样调用；
	 * 原函数是引擎内置回调时，代理直接调用引擎的 Haxe 闭包，不会死循环。
	 * English: Override an existing Lua function. The first argument of
	 * wrapperFunc is a callable proxy for the "original" function; when the
	 * original is an engine callback the proxy calls the engine's Haxe closure
	 * directly, so no infinite recursion.
	 *
	 * @param functionName 要覆盖的 Lua 函数名
	 * @param wrapperFunc 包装函数 (original, ...args) -> result
	 * @return Bool 是否成功
	 */
	public static function overrideLuaFunction(functionName:String, wrapperFunc:Dynamic):Bool {
		if (functionName == null || functionName.length == 0) {
			TraceManager.warn('trace.luaApi.invalidName', 'LuaApi: Invalid function name');
			return false;
		}

		if (wrapperFunc == null || !Reflect.isFunction(wrapperFunc)) {
			TraceManager.error('trace.luaApi.invalidWrapper', 'LuaApi: Invalid wrapper function for "{}"', [functionName]);
			return false;
		}

		#if LUA_ALLOWED
		try {
			if (!luaFunctionExists(functionName)) {
				TraceManager.warn('trace.luaApi.notExists', 'LuaApi: Function "{}" does not exist to override', [functionName]);
				return false;
			}

			backupOriginal(functionName);
			var originalProxy:Dynamic = makeCallableProxy(originalFunctions.get(functionName));

			var wrappedFunc:Dynamic = function(...args:Array<Dynamic>):Dynamic {
				var allArgs:Array<Dynamic> = [originalProxy];
				if (args != null) {
					for (arg in args) allArgs.push(arg);
				}
				return Reflect.callMethod(null, wrapperFunc, allArgs);
			};

			overriddenFunctions.set(functionName, true);
			customFunctions.set(functionName, wrappedFunc);
			registerFunctionToAllLuaInstances(functionName, wrappedFunc);

			TraceManager.info('trace.luaApi.overridden', 'LuaApi: Function "{}" overridden successfully', [functionName]);
			return true;
		} catch (e:Dynamic) {
			TraceManager.error('trace.luaApi.overrideError', 'LuaApi: Error overriding "{}": {}', [functionName, e]);
			return false;
		}
		#else
		TraceManager.warn('trace.luaApi.unsupported', 'LuaApi: Lua not supported on this platform');
		return false;
		#end
	}

	/**
	 * 从 HScript 调用 Lua 全局函数（第一个存在该函数的活跃 Lua 实例）。
	 * English: Call a Lua global function from HScript (uses the first active
	 * Lua instance that has the function).
	 *
	 * @param functionName Lua 函数名
	 * @param args 参数数组
	 * @return Dynamic 函数返回值（表会转成 Haxe 对象/数组，函数转成可调用句柄）
	 */
	public static function callLuaFunction(functionName:String, args:Array<Dynamic> = null):Dynamic {
		#if LUA_ALLOWED
		var state:State = getFirstActiveState();
		if (state == null) return null;
		return callLuaFunctionOnState(state, functionName, args);
		#else
		return null;
		#end
	}

	/**
	 * 在所有活跃 Lua 实例上设置全局变量。
	 * English: Set a global variable on every active Lua instance.
	 *
	 * @return Bool 是否有至少一个实例被写入
	 */
	public static function setLuaVariable(variableName:String, value:Dynamic):Bool {
		if (variableName == null || variableName.length == 0) return false;
		#if LUA_ALLOWED
		var instances:Array<FunkinLua> = getActiveLuaInstances();
		if (instances.length == 0) return false;
		for (li in instances) {
			var s:State = li.lua;
			if (s == null) continue;
			Convert.toLua(s, value);
			Lua.setglobal(s, variableName);
		}
		return true;
		#else
		return false;
		#end
	}

	/**
	 * 读取 Lua 全局变量（第一个活跃实例）。
	 * English: Read a Lua global variable (first active instance).
	 */
	public static function getLuaVariable(variableName:String):Dynamic {
		#if LUA_ALLOWED
		var state:State = getFirstActiveState();
		if (state == null) return null;
		Lua.getglobal(state, variableName);
		// fromLua 现在对每种类型都保持栈平衡（函数是先 pushvalue 再 luaL_ref），
		// 所以取出 + 弹栈各一次即可，不必再为函数单开一条分支。
		// English: fromLua is stack-neutral for every type now, so convert once and pop once.
		var result:Dynamic = Convert.fromLua(state, -1);
		Lua.pop(state, 1);
		return result;
		#else
		return null;
		#end
	}

	/**
	 * 给 Lua 全局函数重命名（相当于把 oldName 指向的函数复制到 newName）。
	 * English: Rename a Lua global function (copies the function pointed to by
	 * oldName to newName).
	 *
	 * @param oldName 原函数名
	 * @param newName 新函数名
	 * @param removeOld true 时移除旧名字（注意：引擎自己会调用的回调不建议移除）
	 * @return Bool 是否找到并重命名
	 */
	public static function renameLuaFunction(oldName:String, newName:String, ?removeOld:Bool = false):Bool {
		if (oldName == null || newName == null || oldName.length == 0 || newName.length == 0) return false;
		if (oldName == newName) return true;
		#if LUA_ALLOWED
		var instances:Array<FunkinLua> = getActiveLuaInstances();
		if (instances.length == 0) return false;
		var found:Bool = false;
		for (li in instances) {
			var s:State = li.lua;
			if (s == null) continue;
			Lua.getglobal(s, oldName);
			if (Lua.type(s, -1) == Lua.LUA_TFUNCTION) {
				found = true;
				Lua.setglobal(s, newName);
				if (removeOld) {
					Lua.pushnil(s);
					Lua.setglobal(s, oldName);
				}
			} else {
				Lua.pop(s, 1);
			}
		}
		return found;
		#else
		return false;
		#end
	}

	/**
	 * 把被覆盖的函数恢复到覆盖前的状态。
	 * English: Restore an overridden function to its pre-override state.
	 *
	 * @param functionName 函数名
	 * @return Bool 是否恢复成功
	 */
	public static function restoreLuaFunction(functionName:String):Bool {
		#if LUA_ALLOWED
		try {
			if (!originalFunctions.exists(functionName)) {
				TraceManager.warn('trace.luaApi.noBackup', 'LuaApi: No backup exists for "{}"', [functionName]);
				return false;
			}

			var original:Dynamic = originalFunctions.get(functionName);

			if (luaDefinedOriginals.exists(functionName)) {
				// Lua 定义的原函数：逐 state 写回 registry 里的原始全局
				// English: Lua-defined originals: write the registry-backed
				// original global back on each state
			var refs:Array<LuaRef> = luaDefinedOriginals.get(functionName);
				Lua_helper.callbacks.remove(functionName);
				for (li in getActiveLuaInstances()) {
					var s:State = li.lua;
					if (s != null) Lua.remove_callback_function(s, functionName);
				}
				for (entry in refs) {
					if (entry == null || entry.state == null) continue;
					Lua.rawgeti(entry.state, Lua.LUA_REGISTRYINDEX, entry.ref);
					if (Lua.type(entry.state, -1) == Lua.LUA_TFUNCTION)
						Lua.setglobal(entry.state, functionName);
					else
						Lua.pop(entry.state, 1);
					LuaL.unref(entry.state, Lua.LUA_REGISTRYINDEX, entry.ref);
				}
				luaDefinedOriginals.remove(functionName);
			} else if (Reflect.isFunction(original)) {
				// Haxe 闭包（引擎内置回调 / 之前 add 的自定义函数）：原样恢复
				// English: Haxe closure (engine callback / previously added
				// custom function): restore as-is
				registerFunctionToAllLuaInstances(functionName, original);
			} else {
				// 原本不存在该函数 → 全部置 nil
				// English: the function did not exist before → set all to nil
				setFunctionToNil(functionName);
			}

			customFunctions.remove(functionName);
			overriddenFunctions.remove(functionName);
			originalFunctions.remove(functionName);

			TraceManager.info('trace.luaApi.restored', 'LuaApi: Function "{}" restored to original', [functionName]);
			return true;
		} catch (e:Dynamic) {
			TraceManager.error('trace.luaApi.restoreError', 'LuaApi: Error restoring "{}": {}', [functionName, e]);
			return false;
		}
		#else
		TraceManager.warn('trace.luaApi.unsupported', 'LuaApi: Lua not supported on this platform');
		return false;
		#end
	}

	/**
	 * 移除一个自定义函数。若它是覆盖函数则恢复原函数，否则置 nil。
	 * English: Remove a custom function. If it was an override, restore the
	 * original; otherwise set it to nil.
	 *
	 * @param functionName 自定义函数名
	 * @return Bool 是否成功
	 */
	public static function removeLuaFunction(functionName:String):Bool {
		#if LUA_ALLOWED
		try {
			if (!customFunctions.exists(functionName)) {
				TraceManager.warn('trace.luaApi.notCustom', 'LuaApi: "{}" is not a custom function', [functionName]);
				return false;
			}

			// 覆盖过 / 有原函数备份的：恢复原状而不是简单置 nil
			// English: if it was overridden or has an original backup, restore
			// instead of just setting it to nil
			if (overriddenFunctions.exists(functionName) || originalFunctions.exists(functionName)) {
				return restoreLuaFunction(functionName);
			}

			setFunctionToNil(functionName);
			Lua_helper.callbacks.remove(functionName);
			customFunctions.remove(functionName);

			TraceManager.info('trace.luaApi.removed', 'LuaApi: Function "{}" removed', [functionName]);
			return true;
		} catch (e:Dynamic) {
			TraceManager.error('trace.luaApi.removeError', 'LuaApi: Error removing "{}": {}', [functionName, e]);
			return false;
		}
		#else
		TraceManager.warn('trace.luaApi.unsupported', 'LuaApi: Lua not supported on this platform');
		return false;
		#end
	}

	/**
	 * 检查某个名字当前是否存在可调用的 Lua 全局函数
	 * （包括引擎内置回调与 Lua 脚本里定义的函数）。
	 * English: Check whether a callable Lua global function exists under this
	 * name (includes engine callbacks and Lua-defined functions).
	 */
	public static function luaFunctionExists(functionName:String):Bool {
		#if LUA_ALLOWED
		if (Lua_helper.callbacks.exists(functionName)) {
			var f:Dynamic = Lua_helper.callbacks.get(functionName);
			if (f != null && Reflect.isFunction(f)) return true;
		}
		return getLuaFunctionDirect(functionName) != null;
		#else
		return false;
		#end
	}

	/**
	 * 获取一个 Lua 函数的可调用句柄。
	 * 引擎回调返回 Haxe 闭包；Lua 定义函数返回可调用的代理（hscript 里可以直接调用）。
	 * English: Get a callable handle for a Lua function. Engine callbacks
	 * return the Haxe closure; Lua-defined functions return a callable proxy
	 * (directly invokable from hscript).
	 *
	 * @param functionName 函数名
	 * @return Dynamic 可调用值或 null
	 */
	public static function getLuaFunction(functionName:String):Dynamic {
		#if LUA_ALLOWED
		var raw:Dynamic = getLuaFunctionDirect(functionName);
		if (raw == null) return null;
		return makeCallableProxy(raw);
		#else
		return null;
		#end
	}

	/**
	 * 列出所有由 LuaApi 添加的自定义函数名。
	 * English: List all custom function names added via LuaApi.
	 */
	public static function getCustomFunctions():Array<String> {
		var result:Array<String> = [];
		for (key in customFunctions.keys()) result.push(key);
		return result;
	}

	/**
	 * 列出所有被 overrideLuaFunction 覆盖的函数名。
	 * English: List all function names overridden via overrideLuaFunction.
	 */
	public static function getOverriddenFunctions():Array<String> {
		var result:Array<String> = [];
		for (key in overriddenFunctions.keys()) result.push(key);
		return result;
	}

	/**
	 * 获取某个函数覆盖前的"原函数"（可调用代理）。
	 * English: Get the "original" function (callable proxy) of an overridden function.
	 */
	public static function getOriginalFunction(functionName:String):Dynamic {
		if (!originalFunctions.exists(functionName)) return null;
		var raw:Dynamic = originalFunctions.get(functionName);
		if (raw == null) return null;
		return makeCallableProxy(raw);
	}

	/**
	 * 批量覆盖多个函数。
	 * English: Batch-override multiple functions.
	 *
	 * @return Int 成功数量
	 */
	public static function batchOverrideLuaFunctions(overrides:Map<String, Dynamic>):Int {
		var successCount:Int = 0;
		for (functionName in overrides.keys()) {
			if (overrideLuaFunction(functionName, overrides.get(functionName))) successCount++;
		}
		return successCount;
	}

	/**
	 * 批量新增多个函数。
	 * English: Batch-add multiple functions.
	 *
	 * @return Int 成功数量
	 */
	public static function batchAddLuaFunctions(functions:Map<String, Dynamic>, overrideExisting:Bool = false):Int {
		var successCount:Int = 0;
		for (functionName in functions.keys()) {
			if (addLuaFunction(functionName, functions.get(functionName), overrideExisting)) successCount++;
		}
		return successCount;
	}

	/**
	 * 恢复所有被覆盖的函数。
	 * English: Restore all overridden functions.
	 *
	 * @return Int 恢复数量
	 */
	public static function restoreAllLuaFunctions():Int {
		var restoredCount:Int = 0;
		var overriddenCopy:Array<String> = [];
		for (key in overriddenFunctions.keys()) overriddenCopy.push(key);
		for (functionName in overriddenCopy) {
			if (restoreLuaFunction(functionName)) restoredCount++;
		}
		return restoredCount;
	}

	/**
	 * 清空所有自定义/覆盖函数并恢复原状。
	 * English: Clear all custom/overridden functions and restore originals.
	 */
	public static function clearAll():Void {
		restoreAllLuaFunctions();

		for (functionName in customFunctions.keys()) {
			setFunctionToNil(functionName);
			Lua_helper.callbacks.remove(functionName);
		}

		customFunctions.clear();
		originalFunctions.clear();
		overriddenFunctions.clear();
		luaDefinedOriginals.clear();
		TraceManager.info('trace.luaApi.cleared', 'LuaApi: All custom functions cleared');
	}

	// ==================== Private Helper Methods ====================

	#if LUA_ALLOWED
	/** 所有活跃（未关闭）的 Lua 实例列表。 English: All active (non-closed) Lua instances. */
	static function getActiveLuaInstances():Array<FunkinLua> {
		var result:Array<FunkinLua> = [];
		if (PlayState.instance == null || PlayState.instance.luaArray == null) return result;
		for (luaInstance in PlayState.instance.luaArray) {
			if (!luaInstance.closed && luaInstance.lua != null)
				result.push(luaInstance);
		}
		return result;
	}

	static function getFirstActiveState():State {
		if (PlayState.instance == null || PlayState.instance.luaArray == null) return null;
		for (luaInstance in PlayState.instance.luaArray) {
			if (!luaInstance.closed && luaInstance.lua != null)
				return luaInstance.lua;
		}
		return null;
	}

	/** 在指定 state 上调用 Lua 全局函数并返回结果。 English: Call a Lua global on the given state and return the result. */
	static function callLuaFunctionOnState(state:State, functionName:String, args:Array<Dynamic> = null):Dynamic {
		if (state == null) return null;
		if (args == null) args = [];
		Lua.getglobal(state, functionName);
		if (Lua.type(state, -1) != Lua.LUA_TFUNCTION) {
			Lua.pop(state, 1);
			return null;
		}
		for (a in args) Convert.toLua(state, a);
		var status:Int = Lua.pcall(state, args.length, 1, 0);
		if (status != Lua.LUA_OK) {
			var err:String = Lua.tostring(state, -1);
			Lua.pop(state, 1);
			TraceManager.error('trace.luaApi.callError', 'LuaApi: Error calling "{}": {}', [functionName, err]);
			return null;
		}
		// fromLua 对函数不再偷偷弹栈了，所以这里统一：取出 → 弹一次。
		// English: fromLua no longer pops for functions; convert once, pop once.
		var result:Dynamic = Convert.fromLua(state, -1);
		Lua.pop(state, 1);
		return result;
	}

	/** 调用 LuaRef 指向的 Lua 函数并返回结果。 English: Call the Lua function referenced by a LuaRef and return the result. */
	static function callLuaRef(lr:LuaRef, args:Array<Dynamic> = null):Dynamic {
		if (lr == null || lr.state == null) return null;
		var state:State = lr.state;
		if (state == null) return null;
		if (args == null) args = [];
		Lua.rawgeti(state, Lua.LUA_REGISTRYINDEX, lr.ref);
		if (Lua.type(state, -1) != Lua.LUA_TFUNCTION) {
			Lua.pop(state, 1);
			return null;
		}
		for (a in args) Convert.toLua(state, a);
		var status:Int = Lua.pcall(state, args.length, 1, 0);
		if (status != Lua.LUA_OK) {
			var err:String = Lua.tostring(state, -1);
			Lua.pop(state, 1);
			TraceManager.error('trace.luaApi.originalError', 'LuaApi: error in original function: {}', [err]);
			return null;
		}
		// fromLua 对函数不再偷偷弹栈了，所以这里统一：取出 → 弹一次。
		// English: fromLua no longer pops for functions; convert once, pop once.
		var result:Dynamic = Convert.fromLua(state, -1);
		Lua.pop(state, 1);
		return result;
	}

	/** 把原始函数包装成 Haxe 可直接调用的代理。 English: Wrap an original into a Haxe-callable proxy. */
	static function makeCallableProxy(original:Dynamic):Dynamic {
		if (original == null)
			return function(...args:Array<Dynamic>):Dynamic return null;
		if (Std.isOfType(original, LuaRef)) {
			var lr:LuaRef = cast original;
			return function(...args:Array<Dynamic>):Dynamic {
				return callLuaRef(lr, args);
			};
		}
		return function(...args:Array<Dynamic>):Dynamic {
			return Reflect.callMethod(null, original, args);
		};
	}

	/** 备份覆盖前的原函数（引擎回调备份 Haxe 闭包，Lua 函数备份 registry 引用）。
	 * English: Back up the pre-override original (Haxe closure for engine
	 * callbacks; registry refs for Lua-defined functions). */
	static function backupOriginal(functionName:String):Void {
		if (originalFunctions.exists(functionName)) return;

		// 1) Haxe 侧回调优先（引擎内置回调 / 之前 add 的自定义函数），可无损恢复
		//    English: Haxe-side callbacks first (engine callbacks / previously
		//    added custom functions) so they can be restored losslessly
		if (Lua_helper.callbacks.exists(functionName)) {
			var f:Dynamic = Lua_helper.callbacks.get(functionName);
			if (f != null && Reflect.isFunction(f)) {
				originalFunctions.set(functionName, f);
				return;
			}
		}

		// 2) Lua 侧函数：每个活跃 state 各存一份 registry 引用
		//    English: Lua-defined functions: keep one registry ref per active state
		var refs:Array<LuaRef> = [];
		var firstProxy:Dynamic = null;
		for (li in getActiveLuaInstances()) {
			var s:State = li.lua;
			if (s == null) continue;
			Lua.getglobal(s, functionName);
			if (Lua.type(s, -1) == Lua.LUA_TFUNCTION) {
				var ref:Int = LuaL.ref(s, Lua.LUA_REGISTRYINDEX); // luaL_ref 自动弹栈
				var lr:LuaRef = new LuaRef(s, ref);
				refs.push(lr);
				if (firstProxy == null) firstProxy = lr;
			} else {
				Lua.pop(s, 1);
			}
		}
		if (refs.length > 0) {
			luaDefinedOriginals.set(functionName, refs);
			originalFunctions.set(functionName, firstProxy);
		} else {
			originalFunctions.set(functionName, null);
		}
	}

	/**
	 * 从 Lua state 获取函数引用：
	 * 优先返回 Haxe 侧注册的闭包（引擎回调），否则返回 Lua 全局函数句柄。
	 * English: Get a function reference from a Lua state — prefers the Haxe
	 * closure registered on the Haxe side (engine callbacks), otherwise returns
	 * a handle to the Lua global function.
	 */
	private static function getLuaFunctionDirect(functionName:String):Dynamic {
		if (Lua_helper.callbacks.exists(functionName)) {
			var f:Dynamic = Lua_helper.callbacks.get(functionName);
			if (f != null && Reflect.isFunction(f)) return f;
		}
		if (PlayState.instance == null || PlayState.instance.luaArray == null) return null;
		for (luaInstance in PlayState.instance.luaArray) {
			if (luaInstance.closed || luaInstance.lua == null) continue;
			var lua:State = luaInstance.lua;
			Lua.getglobal(lua, functionName);
			var funcType:Int = Lua.type(lua, -1);
			if (funcType == Lua.LUA_TFUNCTION) {
				var ref:Int = LuaL.ref(lua, Lua.LUA_REGISTRYINDEX); // luaL_ref 自动弹栈
				return new LuaRef(lua, ref);
			}
			Lua.pop(lua, 1);
		}
		return null;
	}

	/** 把 Haxe 函数注册到所有活跃 Lua 实例。 English: Register a Haxe function on all active Lua instances. */
	private static function registerFunctionToAllLuaInstances(functionName:String, func:Dynamic):Void {
		if (PlayState.instance == null || PlayState.instance.luaArray == null) return;
		for (luaInstance in PlayState.instance.luaArray) {
			if (luaInstance.closed || luaInstance.lua == null) continue;
			try {
				Lua_helper.add_callback(luaInstance.lua, functionName, func);
			} catch (e:Dynamic) {
				TraceManager.error('trace.luaApi.registerError', 'LuaApi: Error registering "{}": {}', [functionName, e]);
			}
		}
	}

	/** 把所有活跃 Lua 实例的全局函数置 nil。 English: Set a global function to nil on all active Lua instances. */
	private static function setFunctionToNil(functionName:String):Void {
		if (PlayState.instance == null || PlayState.instance.luaArray == null) return;
		for (luaInstance in PlayState.instance.luaArray) {
			if (luaInstance.closed || luaInstance.lua == null) continue;
			try {
				Lua.pushnil(luaInstance.lua);
				Lua.setglobal(luaInstance.lua, functionName);
			} catch (e:Dynamic) {
				TraceManager.error('trace.luaApi.removeError', 'LuaApi: Error removing "{}": {}', [functionName, e]);
			}
		}
	}

	#end
}

#if LUA_ALLOWED
/** Lua 函数在某个 state registry 里的引用（LuaApi 内部使用）。
 * English: A reference to a Lua function in a state's registry (internal to LuaApi). */
private class LuaRef {
	public var state:State;
	public var ref:Int;

	public function new(state:State, ref:Int) {
		this.state = state;
		this.ref = ref;
	}
}
#end
