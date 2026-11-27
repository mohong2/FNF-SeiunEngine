package editors;

import android.flixel.FlxButton;
import android.flixel.FlxVirtualPad;
import flixel.FlxG;

/**
 * Placement of the on-screen pad inside the chart editors.
 *
 * The stock pad is built for gameplay, not for a 280 px-wide editor margin:
 *
 *  - `LEFT_FULL` puts its 132 px buttons at x = 0..339, i.e. 59 px inside the classic chart
 *    grid, which starts at x = 280. Notes under those buttons cannot be tapped, and the
 *    bottom-left of the modern layout is where the player's thumb rests while charting.
 *  - `NEW_CHART_EDITOR` places its Q/E pair at `FlxG.width - 952`, which is x = 328 on a
 *    1280 px canvas - on top of the cross' right button (207..339, an 11 px overlap that makes
 *    a tap hit both) - and every narrower canvas pushes it further left, off screen.
 *
 * This class keeps the same buttons with the same mappings and only re-places them, at the
 * same 60 % scale the online screens already use, into the two screen corners neither chart
 * layout uses:
 *
 * ```
 *        [UP]                                    [X] [Y] [Z]
 *     [LEFT] [RIGHT]                             [D] [B] [A]
 *        [DOWN]   [UP2] [DOWN2]
 * ```
 *
 * The whole left cluster stays within x <= 256 (left of the classic grid at 280 and left of
 * the modern centred grid), and the action block is right of the classic panel (x = 1000) and
 * right of an 8K modern grid - so the Modern and Classic editor layouts share one arrangement
 * and switching layouts needs no re-layout.
 */
class EditorPadLayout
{
	/** Same fraction as the online screens: a comfortable thumb target that still fits the margins. */
	public static inline var SCALE:Float = 0.6;
	public static inline var MARGIN:Float = 6;
	public static inline var GAP:Float = 6;
	/** Columns of the action block (3 x 2 for the modern editor, 3 x 4 for the legacy one). */
	public static inline var ACTION_COLUMNS:Int = 3;

	/**
	 * Re-places every button of `pad` into the bottom corners.
	 *
	 * @param actionOrder the action buttons in reading order; the last one lands in the
	 *                    bottom-right corner (closest to the right thumb). Buttons that are not
	 *                    part of this pad (not in `members`) are ignored.
	 */
	public static function apply(pad:FlxVirtualPad, actionOrder:Array<FlxButton>):Void
	{
		if (pad == null) return;

		var cell:FlxButton = firstMember(pad);
		if (cell == null) return;

		for (btn in pad.members)
		{
			if (btn == null) continue;
			btn.scale.set(SCALE, SCALE);
			btn.updateHitbox();
		}

		var w:Float = cell.width;
		var h:Float = cell.height;
		if (w <= 0 || h <= 0) return;

		var bottom:Float = FlxG.height - MARGIN;
		var midX:Float = MARGIN + w + GAP;

		// Directions: a cross hugging the bottom-left corner. 3 cells + 2 gaps = 250 px at 0.6,
		// still inside the 280 px the classic layout leaves to the left of the chart grid.
		put(pad.buttonUp, midX, bottom - h * 2 - GAP);
		put(pad.buttonLeft, MARGIN, bottom - h);
		put(pad.buttonDown, midX, bottom - h);
		put(pad.buttonRight, MARGIN + (w + GAP) * 2, bottom - h);

		// Sustain length (Q/E): the row right above the cross, same left column.
		var sustainY:Float = bottom - h * 3 - GAP * 2;
		put(pad.buttonUp2, MARGIN, sustainY);
		put(pad.buttonDown2, midX, sustainY);

		if (actionOrder == null) return;

		var actions:Array<FlxButton> = [];
		for (btn in actionOrder)
		{
			if (btn == null) continue;
			if (pad.members.indexOf(btn) < 0) continue;
			if (actions.indexOf(btn) > -1) continue;
			actions.push(btn);
		}
		if (actions.length == 0) return;

		var cols:Int = Std.int(Math.min(ACTION_COLUMNS, actions.length));
		var rows:Int = Std.int(Math.ceil(actions.length / cols));
		var right:Float = FlxG.width - MARGIN;
		var top:Float = bottom - rows * h - (rows - 1) * GAP;

		for (i in 0...actions.length)
		{
			var col:Int = i % cols;
			var row:Int = Std.int(i / cols);
			put(actions[i], right - (cols - col) * (w + GAP) + GAP, top + row * (h + GAP));
		}
	}

	/**
	 * Y of the top edge of the left cluster (the sustain row). Screens that draw text along the
	 * bottom edge use this to move it above the buttons instead of underneath them.
	 */
	public static function leftClusterTop(pad:FlxVirtualPad):Float
	{
		var cell:FlxButton = firstMember(pad);
		if (cell == null) return FlxG.height;
		return FlxG.height - MARGIN - cell.height * 3 - GAP * 2;
	}

	static function firstMember(pad:FlxVirtualPad):FlxButton
	{
		for (btn in pad.members)
			if (btn != null) return btn;
		return null;
	}

	static function put(btn:FlxButton, x:Float, y:Float):Void
	{
		if (btn != null) btn.setPosition(x, y);
	}
}
