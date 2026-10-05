package online.util;

/**
 * Hold-to-repeat for the online menus: one step on the key press, then an accelerating repeat
 * while the direction is held. Shared so the keyboard and the on-screen pad behave identically.
 *
 * The caller feeds the HELD actions (`controls.UI_UP` / `controls.UI_DOWN`), not the `_P`
 * variants: the first step is produced by the direction change, so passing just-pressed here
 * would double the first move.
 */
class NavRepeat
{
	/** Seconds a direction must be held before it starts repeating. */
	public static inline var REPEAT_DELAY:Float = 0.38;
	/** Interval of the first repeat, in seconds. */
	public static inline var REPEAT_FIRST:Float = 0.12;
	/** Fastest interval the repeat accelerates to. */
	public static inline var REPEAT_MIN:Float = 0.035;
	/** Every repeat multiplies the interval by this, down to REPEAT_MIN. */
	public static inline var REPEAT_SHRINK:Float = 0.72;

	var dir:Int = 0;
	var held:Float = 0;
	var acc:Float = 0;
	var interval:Float = REPEAT_FIRST;

	public function new() {}

	/** Forget the current direction (call when the list is rebuilt or the screen regains focus). */
	public function reset():Void
	{
		dir = 0;
		held = 0;
		acc = 0;
		interval = REPEAT_FIRST;
	}

	/**
	 * @return how many rows to move this frame; negative is up, 0 is no move.
	 */
	public function poll(up:Bool, down:Bool, elapsed:Float):Int
	{
		var press:Int = 0;
		if (up && down)
			press = dir == 0 ? -1 : dir; // both held: keep whatever started it
		else if (up)
			press = -1;
		else if (down)
			press = 1;

		if (press == 0)
		{
			reset();
			return 0;
		}

		if (press != dir)
		{
			// Fresh press (or a direction flip): always move exactly one row, immediately.
			dir = press;
			held = 0;
			acc = 0;
			interval = REPEAT_FIRST;
			return press;
		}

		held += elapsed;
		if (held < REPEAT_DELAY)
			return 0;

		acc += elapsed;
		var steps = 0;
		while (acc >= interval)
		{
			acc -= interval;
			steps++;
			interval = Math.max(REPEAT_MIN, interval * REPEAT_SHRINK);
		}
		return steps * dir;
	}
}
