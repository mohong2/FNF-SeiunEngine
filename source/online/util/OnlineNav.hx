package online.util;

import android.flixel.FlxButton;
import android.flixel.FlxVirtualPad;
import flixel.FlxCamera;
import flixel.FlxG;
import flixel.FlxObject;
import flixel.math.FlxPoint;

/**
 * Pointer rules shared by every online screen.
 *
 * The online UI used to move its selection whenever the pointer moved (`FlxG.mouse.justMoved ->
 * curSelected`), which is exactly what a touchscreen player cannot use: a swipe aimed at a
 * scroll or a pad button dragged the highlight across the list. The rules now are:
 *
 *   - moving the pointer only LIGHTS the row under it (hover), it never changes the selection;
 *   - clicking selects the row under the pointer and runs it;
 *   - UP/DOWN and the wheel move the selection (see NavRepeat for the hold-to-repeat part);
 *   - pointer input that lands on the on-screen pad is ignored, so tapping `A` cannot also
 *     activate the menu row sitting behind it.
 */
class OnlineNav
{
	/**
	 * True when the pointer is on a visible on-screen pad button.
	 *
	 * This is a screen-space test on purpose: the pad is drawn by its own camera whose scroll is
	 * always 0, while the screen behind it may be scrolled (the options/LAN panels follow the
	 * selection), so a world-space `FlxG.mouse.overlaps()` against the pad buttons would miss
	 * whenever that camera is not at the origin.
	 */
	public static function padBlocks(pad:FlxVirtualPad):Bool
	{
		if (pad == null || !pad.visible)
			return false;

		var sx = FlxG.mouse.screenX;
		var sy = FlxG.mouse.screenY;
		var gx = pad.x;
		var gy = pad.y;

		for (btn in pad.members)
		{
			if (btn == null || !btn.visible)
				continue;
			if (sx >= gx + btn.x && sx < gx + btn.x + btn.width
				&& sy >= gy + btn.y && sy < gy + btn.y + btn.height)
				return true;
		}
		return false;
	}

	/** Source size of one virtual-pad button (the `virtualpad/*.png` art is a 2-frame sheet). */
	public static inline var BUTTON_SIZE:Float = 128;

	/**
	 * Online pads are drawn at this fraction of the engine's size.
	 *
	 * A full button is 128 px of a 1280 px screen -- a tenth of the canvas -- and on these screens
	 * it lands on top of a card, a checkbox or a hint. At 60 % the same artwork is 77 px, which is
	 * still a comfortable thumb target on a phone (the 1280x720 canvas is upscaled to the device)
	 * and leaves the UI underneath readable.
	 */
	public static inline var BUTTON_SCALE:Float = 0.6;

	/** Rendered size of one button. `shrink()` refreshes it for the pad just laid out. */
	public static var SIZE:Float = BUTTON_SIZE * BUTTON_SCALE;

	static inline var MARGIN:Float = 14;
	static inline var GAP:Float = 10;

	/** Left edge that content has to clear while a pad is mounted. */
	public static var LEFT_BAND(get, never):Float;

	static inline function get_LEFT_BAND():Float
		return MARGIN + SIZE + 16;

	/**
	 * x for content that would otherwise be drawn under the on-screen direction column.
	 *
	 * Every online screen mounts its own layout, but they all keep the direction buttons in the
	 * bottom-left corner, so this is the one shared rule: shift past them, or stay put when there
	 * is no pad (a desktop build with "touch controls" off).
	 */
	public static function avoidLeftPad(pad:FlxVirtualPad, x:Float):Float
		return pad == null ? x : Math.max(x, LEFT_BAND);

	/**
	 * Shrinks every button of a mounted pad.
	 *
	 * The artwork and the tap target stay on the same rectangle: `updateHitbox()` sizes the box
	 * from the scale and compensates the artwork's origin with `offset`, while the hit test
	 * (`FlxObject.overlapsPoint`) reads x/width. That is also the box `padBlocks()`
	 * compares against, so "a tap on the pad never reaches the row behind it" keeps holding.
	 */
	public static function shrink(pad:FlxVirtualPad, scale:Float = BUTTON_SCALE):Void
	{
		if (pad == null)
			return;

		SIZE = BUTTON_SIZE * scale;
		for (btn in pad.members)
		{
			if (btn == null)
				continue;
			btn.scale.set(scale, scale);
			btn.updateHitbox();
		}
	}

	static function move(btn:FlxButton, x:Float, y:Float):Void
	{
		if (btn != null)
			btn.setPosition(x, y);
	}

	/** Up above down, down hugging the bottom-left corner. */
	public static function dirColumn(pad:FlxVirtualPad):Void
	{
		if (pad == null)
			return;
		move(pad.buttonUp, MARGIN, FlxG.height - SIZE * 2 - GAP - MARGIN);
		move(pad.buttonDown, MARGIN, FlxG.height - SIZE - MARGIN);
	}

	/** Left then right, hugging the bottom-left corner. */
	public static function dirRow(pad:FlxVirtualPad):Void
	{
		if (pad == null)
			return;
		move(pad.buttonLeft, MARGIN, FlxG.height - SIZE - MARGIN);
		move(pad.buttonRight, MARGIN + SIZE + GAP, FlxG.height - SIZE - MARGIN);
	}

	/** The four direction buttons as one compact cross in the bottom-left corner. */
	public static function dirCross(pad:FlxVirtualPad):Void
	{
		if (pad == null)
			return;

		var column:Float = MARGIN + SIZE + GAP;
		var bottom:Float = FlxG.height - SIZE - MARGIN;
		move(pad.buttonUp, column, bottom - SIZE - GAP);
		move(pad.buttonLeft, MARGIN, bottom);
		move(pad.buttonRight, MARGIN + (SIZE + GAP) * 2, bottom);
		move(pad.buttonDown, column, bottom);
	}

	/**
	 * A, then B to its left, then C: right-aligned along the bottom edge. Buttons the pad did not
	 * create are skipped, so `A_B` leaves out C and `B` alone leaves out A.
	 */
	public static function actions(pad:FlxVirtualPad):Void
	{
		if (pad == null)
			return;

		var x:Float = FlxG.width - MARGIN - SIZE;
		for (btn in [pad.buttonA, pad.buttonB, pad.buttonC])
		{
			if (btn == null || pad.members.indexOf(btn) < 0)
				continue;
			move(btn, x, FlxG.height - SIZE - MARGIN);
			x -= SIZE + GAP;
		}
	}

	/** Direction column in the bottom-left corner, actions in the bottom-right. */
	public static function layoutColumn(pad:FlxVirtualPad):Void
	{
		shrink(pad);
		dirColumn(pad);
		actions(pad);
	}

	/** Left/right pair in the bottom-left corner, actions in the bottom-right. */
	public static function layoutRow(pad:FlxVirtualPad):Void
	{
		shrink(pad);
		dirRow(pad);
		actions(pad);
	}

	/** Four-way cross in the bottom-left corner, actions in the bottom-right. */
	public static function layoutCross(pad:FlxVirtualPad):Void
	{
		shrink(pad);
		dirCross(pad);
		actions(pad);
	}

	/** Action buttons only, right-aligned along the bottom edge. */
	public static function layoutActions(pad:FlxVirtualPad):Void
	{
		shrink(pad);
		actions(pad);
	}

	/**
	 * World-space hit test using the camera the object is actually drawn with.
	 *
	 * `FlxG.mouse.overlaps(obj, camera)` cannot be used instead: in flixel 4.11 its screen-space
	 * branch compares `pointerScreen - scroll` against the object's screen position, which only
	 * cancels out while the camera sits at the origin, and the online rows (options, LAN, server
	 * list) all live under a camera that follows the selection.
	 */
	public static function pointerOver(obj:FlxObject, cam:FlxCamera):Bool
	{
		if (obj == null || cam == null)
			return false;

		var point = FlxG.mouse.getWorldPosition(cam);
		var hit = false;

		// A row widget is a FlxSpriteGroup (options / LAN / server rows): it is hit when one of its
		// members is, exactly the shape FlxPointer.overlaps uses. The group's own bounds are never
		// sized, so testing the group directly would never hit. Anything else is tested directly.
		if (Std.isOfType(obj, FlxSpriteGroup))
		{
			var row:FlxSpriteGroup = cast obj;
			for (member in row.members)
			{
				if (member == null || !member.exists)
					continue;
				if (member.overlapsPoint(point, false))
				{
					hit = true;
					break;
				}
			}
		}
		else
		{
			hit = obj.overlapsPoint(point, false);
		}

		point.put();
		return hit;
	}

	/** Axis box in the given camera's world space (for rows that are plain text). */
	public static function pointerOverRect(x:Float, y:Float, w:Float, h:Float, cam:FlxCamera):Bool
	{
		if (cam == null)
			return false;

		var point = FlxG.mouse.getWorldPosition(cam);
		var hit = point.x >= x && point.x < x + w && point.y >= y && point.y < y + h;
		point.put();
		return hit;
	}
}
