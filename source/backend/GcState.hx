package backend;


class GcState
{
	public static var disabled(default, null):Bool = false;

	public static var targetFreePercent(default, null):Int = -1;

	public static var heapBudgetBytes:Float = 0;

	public static var budgetCollects(default, null):Int = 0;

	public static function setDisabled(v:Bool):Void
	{
		#if cpp
		cpp.vm.Gc.enable(!v);
		#end
		disabled = v;
	}

	public static function collect():Void
	{
		#if cpp
		cpp.vm.Gc.run(true);
		#end
	}


	public static function applyHeapPolicy():Void
	{
		#if cpp
		var pct:Int = 50;
		var env:String = Sys.getEnv('FNF_GC_TARGET_FREE_SPACE');
		if (env != null && env.length > 0)
		{
			var v:Null<Int> = Std.parseInt(env);
			if (v != null && v > 0 && v <= 100) pct = v;
		}
		cpp.vm.Gc.setTargetFreeSpacePercentage(pct);
		targetFreePercent = pct;
		#end
	}

	public static function currentHeapBytes():Float
	{
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_CURRENT);
		#else
		return 0;
		#end
	}

	public static function liveHeapBytes():Float
	{
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		#else
		return 0;
		#end
	}

	public static function enforceBudget():Bool
	{
		#if cpp
		if (!disabled || heapBudgetBytes <= 0) return false;
		if (currentHeapBytes() < heapBudgetBytes) return false;
		setDisabled(false);
		cpp.vm.Gc.run(true);
		setDisabled(true);
		budgetCollects++;
		return true;
		#else
		return false;
		#end
	}
}
