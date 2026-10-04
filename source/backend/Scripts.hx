package backend;

/**
我不道啊
 */
class Scripts
{
	public static var reuseEnabled:Bool = true;

	public static var execDepth:Int = 0;

	public static final EMPTY:Array<Dynamic> = [];

	static var slots:Map<Int, Array<Dynamic>> = new Map();

	static var lastShape:Int = -1;
	static var lastArr:Array<Dynamic> = null;
	public static var allocated:Int = 0;
	public static var reused:Int = 0;

	inline public static function get(shape:Int):Array<Dynamic>
	{
		if (!reuseEnabled)
		{
			allocated++;
			return new Array<Dynamic>();
		}

		if (shape <= 0)
		{
			reused++;
			return EMPTY;
		}

		if (execDepth > 0)
		{
			allocated++;
			return new Array<Dynamic>();
		}

		var arr:Array<Dynamic> = (shape == lastShape) ? lastArr : slots.get(shape);
		if (arr == null)
		{
			arr = new Array<Dynamic>();
			if (arr.length != shape) arr.resize(shape);
			slots.set(shape, arr);
			lastShape = shape;
			lastArr = arr;
			allocated++;
			return arr;
		}
		lastShape = shape;
		lastArr = arr;
		if (arr.length != shape) arr.resize(shape);
		reused++;
		return arr;
	}

	//这么写又是何意味
	inline public static function fill1(a:Array<Dynamic>, v0:Dynamic):Array<Dynamic> { a[0] = v0; return a; }
	inline public static function fill2(a:Array<Dynamic>, v0:Dynamic, v1:Dynamic):Array<Dynamic> { a[0] = v0; a[1] = v1; return a; }
	inline public static function fill3(a:Array<Dynamic>, v0:Dynamic, v1:Dynamic, v2:Dynamic):Array<Dynamic> { a[0] = v0; a[1] = v1; a[2] = v2; return a; }
	inline public static function fill4(a:Array<Dynamic>, v0:Dynamic, v1:Dynamic, v2:Dynamic, v3:Dynamic):Array<Dynamic> { a[0] = v0; a[1] = v1; a[2] = v2; a[3] = v3; return a; }
	inline public static function fill5(a:Array<Dynamic>, v0:Dynamic, v1:Dynamic, v2:Dynamic, v3:Dynamic, v4:Dynamic):Array<Dynamic> { a[0] = v0; a[1] = v1; a[2] = v2; a[3] = v3; a[4] = v4; return a; }

	inline public static function enterExec():Void
	{
		execDepth++;
	}

	inline public static function exitExec():Void
	{
		if (execDepth > 0) execDepth--;
	}

	public static function clear():Void
	{
		slots = new Map();
		lastShape = -1;
		lastArr = null;
	}
}
