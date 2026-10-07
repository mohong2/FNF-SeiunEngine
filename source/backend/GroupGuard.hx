package backend;

import flixel.FlxState;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.group.FlxSpriteGroup.FlxTypedSpriteGroup;
import mohong.TraceManager;

/**
 * 组容器成员完整性守卫。
 *
 * ## 为什么需要它
 *
 * FlxTypedGroup.update() 遍历 members 时, 每个元素都要做一次
 * Dynamic -> FlxBasic 转换, hxcpp 的转换会读对象的 vtable(偏移 0)并调用
 * _hx_isInstanceOf()。只要某个成员指向的内存已经被回收/复用(地址本身还在,
 * 但头 8 字节是 0), 这一读就是空指针解引用 —— 主线程直接 ACCESS_VIOLATION,
 * 而且崩溃点永远落在 FlxTypedGroup.update 里, 与真正的凶手无关。
 *
 * ## 它做什么
 *
 * 每次 state 进入 update 之前扫一遍成员数组(以及嵌套容器), 只读一级指针,
 * 不解引用任何 Haxe 字段: 发现 vtable 不是合法代码地址的成员, 就把该槽位置空
 * (和 flixel 自己的 remove(obj, false) 完全一样的做法)并记一条警告。
 * 最坏情况从"整局游戏原生崩溃"变成"少一个坏对象 + 一条可追查的日志"。
 *
 * ## 兼容性
 *
 * 对 0.6.3 / 0.7.3 / 1.0.4 三种模式行为完全一致: 它只在内存已经被破坏时动手;
 * 正常运行时只做指针合法性判断, 没有任何副作用。
 */
class GroupGuard
{
	/** 总开关。 */
	public static var enabled:Bool = true;

	/**
	 * 递归全量检查的间隔帧数。状态切换后的第一帧一定会做一次全量: 成员表刚建好,
	 * 而且出问题的都是进入 state 的最初几帧。深挖(notes 之类上千成员的组)比较贵,
	 * 所以之后按这个间隔来查。
	 */
	public static var fullEvery:Int = 600;

	/** 已经摘除的坏成员总数。 */
	public static var repaired(default, null):Int = 0;

	/** 每帧轻量检查(只查 state 的直接成员 + sprite 容器成员)。 */
	public static var shallowEveryFrame:Bool = true;

	static inline var REPORT_LIMIT:Int = 40;

	static var _frames:Int = 0;
	static var _lastState:FlxState = null;
	static var _reports:Int = 0;

	/** 每个 state 进入 update 前调用(MusicBeatState.update 里)。 */
	public static function tick(state:FlxState):Void
	{
		if (!enabled || state == null) return;

		var fresh:Bool = (state != _lastState);
		if (fresh)
		{
			_lastState = state;
			_frames = 0;
		}
		_frames++;

		var deep:Bool = fresh || (fullEvery > 0 && (_frames % fullEvery) == 0);
		if (!deep && !shallowEveryFrame) return;

		try
		{
			walk(state, deep, typeName(state));
		}
		catch (e:Dynamic)
		{
			// 守卫自己出错绝不能连带游戏: 关掉它, 记一条, 让正常崩溃报告接手。
			enabled = false;
			TraceManager.warn('trace.groupGuard.failed', 'GroupGuard disabled after error: {}', [Std.string(e)]);
		}
	}

	/**
	 * 成员指针是否还指向一个构造完成的 hxcpp 对象。
	 * 只看 vtable 槽, 不解引用对象内容 —— 对已经死掉的指针也安全。
	 */
	#if cpp
	@:functionCode('
		hx::Object *o = inObj.mPtr;
		if (o == 0) return true;
		unsigned long long vt = (unsigned long long)*((void **)(void *)o);
		return vt > 0x10000ULL && vt < 0x00007FFFFFFFFFFFULL && (vt & 7ULL) == 0;
	')
	public static function rawAlive(inObj:Dynamic):Bool return true;
	#else
	public static function rawAlive(inObj:Dynamic):Bool return inObj != null;
	#end

	/** 成员指针的数值(只做日志, 不解引用)。 */
	#if cpp
	@:functionCode('
		return (double)(unsigned long long)(void *)inObj.mPtr;
	')
	public static function rawAddr(inObj:Dynamic):Float return 0;
	#else
	public static function rawAddr(inObj:Dynamic):Float return 0;
	#end

	// ==================== 内部 ====================

	static function walk(container:Dynamic, deep:Bool, path:String):Void
	{
		var arr:Array<Dynamic> = membersOf(container);
		if (arr == null) return;

		var i:Int = 0;
		while (i < arr.length)
		{
			var m:Dynamic = arr[i];
			if (m == null)
			{
				i++;
				continue;
			}

			if (!rawAlive(m))
			{
				var line:String = describe(container, path, arr, i, m);
				repaired++;
				// 置空槽位(不是 splice): 与 flixel 的 remove(obj, false) 一致,
				// 不移动其它元素、不动 group 自己的 length 缓存。
				arr[i] = null;
				report(line);
				i++;
				continue;
			}

			if (deep)
			{
				if (Std.isOfType(m, FlxTypedGroup) || Std.isOfType(m, FlxTypedSpriteGroup))
					walk(m, true, path + ' + ' + i);
			}
			i++;
		}
	}

	/**
	 * 取容器的成员数组。FlxTypedGroup 是普通字段; FlxTypedSpriteGroup 的
	 * members 是 getter(指向内部 group 的同一个数组), 两种都要能拿到。
	 */
	static function membersOf(container:Dynamic):Array<Dynamic>
	{
		var m:Dynamic = null;
		try { m = Reflect.getProperty(container, 'members'); } catch (e:Dynamic) { m = null; }
		if (m == null)
		{
			try { m = Reflect.field(container, 'members'); } catch (e:Dynamic) { m = null; }
		}
		if (m == null || !Std.isOfType(m, Array)) return null;
		return cast m;
	}

	static function describe(container:Dynamic, path:String, arr:Array<Dynamic>, bad:Int, ptr:Dynamic):String
	{
		var names:Array<String> = [];
		var upto:Int = arr.length < 14 ? arr.length : 14;
		for (j in 0...upto)
		{
			var s:String;
			if (j == bad) s = 'DEAD';
			else if (arr[j] == null) s = 'null';
			else s = typeName(arr[j]);
			names.push(j + ':' + s);
		}
		return path + '.members[' + bad + '/' + arr.length + ']'
			+ ' container=' + typeName(container)
			+ ' deadPtr=' + hexAddr(rawAddr(ptr))
			+ ' siblings=[' + names.join(', ') + ']';
	}

	static function report(line:String):Void
	{
		if (_reports < REPORT_LIMIT)
		{
			_reports++;
			TraceManager.warn('trace.groupGuard.deadMember',
				'GroupGuard dropped a dead group member (the engine was about to crash on it): {}', [line]);
			ScriptLog.write('guard', 'DEAD member dropped  ' + line);
			if (_reports == REPORT_LIMIT)
				TraceManager.warn('trace.groupGuard.reportLimit',
					'GroupGuard reached its report limit ({}), further drops are logged to script_log only', [Std.string(REPORT_LIMIT)]);
		}
		else
			ScriptLog.write('guard', 'DEAD member dropped  ' + line);
	}

	static function typeName(o:Dynamic):String
	{
		if (o == null) return 'null';
		try
		{
			var c = Type.getClass(o);
			if (c == null) return '?';
			var n = Type.getClassName(c);
			return n == null ? '?' : n;
		}
		catch (e:Dynamic) return '?';
	}

	static function hexAddr(v:Float):String
	{
		var digits = '0123456789ABCDEF';
		var s = '';
		var n = v;
		for (k in 0...12)
		{
			var d:Int = Std.int(n % 16);
			if (d < 0) d = 0;
			if (d > 15) d = 15;
			s = digits.charAt(d) + s;
			n = Math.floor(n / 16);
		}
		return '0x' + s;
	}
}
