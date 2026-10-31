package backend;

/**
 * Compile-time test levers for the crash reporting stack.
 *
 * Every function here compiles out unless the build enables the
 * `seiun_test_hooks` define, so a normal build contains none of it:
 *
 *     haxelib run lime build windows -D seiun_test_hooks
 *
 * Use this to verify the top-level funnels end to end without editing and
 * reverting the real sources:
 *
 *   SEIUN_TEST_MAIN_THROW=1    uncaught Haxe exception inside Main.main()
 *                              -> Main.reportCrash() (Haxe funnel, report + dialog)
 *   SEIUN_TEST_STATIC_THROW=1  exception thrown while hxcpp runs the static
 *                              initializers (before Main.main exists)
 *                              -> hxcpp WinMain catch (C++ funnel)
 *   SEIUN_TEST_SEH=1           real ACCESS_VIOLATION (null pointer write)
 *                              -> SEH handler, native_crash_*.txt
 *
 * The matching lever for the lime ndll itself is the environment variable
 * SEIUN_TEST_FATAL (see lime/utils/FatalReport.h), which needs no rebuild.
 */
class CrashTestHooks
{
	#if seiun_test_hooks
	/**
	 * Static initializer: runs inside hxcpp's __boot_all, before main().
	 * The compiler cannot skip a static with a call initializer, so this is a
	 * reliable way to test the failure that happens before any Haxe frame exists.
	 */
	static var __staticInitProbe:Dynamic = runStaticThrow();

	static function runStaticThrow():Dynamic
	{
		if (env('SEIUN_TEST_STATIC_THROW') == '1')
			throw '测试静态初始化错误 (static initializer)';
		return null;
	}

	static function env(name:String):String
	{
		#if sys
		var v:String = null;
		try
		{
			v = Sys.getEnv(name);
		}
		catch (e:Dynamic) {}
		return (v == null) ? '' : v;
		#else
		return '';
		#end
	}

	/**
	 * Called at the top of Main.main(), inside its try/catch.
	 */
	public static function mainThrow():Void
	{
		if (env('SEIUN_TEST_MAIN_THROW') == '1')
			throw '测试中文错误 (Main.main)';
	}

	/**
	 * Called before the boot try/catch: a genuine access violation, the same
	 * class of fault as a null field write in the engine.
	 */
	public static function sehProbe():Void
	{
		if (env('SEIUN_TEST_SEH') == '1')
		{
			#if cpp
			untyped __cpp__('*(volatile int *)0 = 1;');
			#end
		}
	}
	#else
	public static function mainThrow():Void {}

	public static function sehProbe():Void {}
	#end
}
