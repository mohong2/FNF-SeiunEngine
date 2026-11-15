package backend.ui;

import backend.ui.PsychUIBox.UIStyleData;
import flixel.FlxCamera;
import flixel.FlxG;
import flixel.FlxObject;
import flixel.FlxSprite;
import flixel.math.FlxMath;
import flixel.math.FlxPoint;
import flixel.util.FlxColor;
import openfl.display.BitmapData;
import openfl.geom.Rectangle;

/**
 * Shared helpers for the Psych UI widgets (rounded boxes, hit tests, easing).
 *
 * IMPORTANT - no bitmap is ever shared between two sprites.
 *
 * The engine calls FlxG.bitmap.clearCache() on every state switch (Main.hx), and a sprite
 * frees its graphic when it is destroyed. A cache of BitmapData (the previous version of this
 * class had one) therefore handed out already-destroyed pixels the second time a size was
 * reused: every panel, tab, input field and button painted with them turned into a solid black
 * rectangle, and entering an editor a second time painted the whole UI black. Every helper here
 * bakes a fresh graphic that belongs to exactly one sprite.
 */
class PsychUIHelper
{
	/** Default corner radius used across all UI components. */
	public static var cornerRadius:Int = 8;

	/** Animation speed of the widgets' smoothing (1/second). Higher = snappier. */
	public static var smoothSpeed:Float = 18;

	/** Below this difference a smoothed value snaps to its target (avoids endless tiny lerps). */
	static inline var SNAP_EPSILON:Float = 0.0015;

	/**
	 * True when 'obj' may take part in interaction: it has to exist, be visible, be active and
	 * have a real hit area. Skipping this check was the reason a hidden panel still swallowed
	 * clicks and a collapsed input still received focus.
	 */
	public static function interactive(obj:FlxObject):Bool
	{
		return obj != null && obj.exists && obj.visible && obj.active && obj.width > 0 && obj.height > 0;
	}

	/** Frame-rate independent smoothing towards 'target' (identical at 60 and at 240 fps). */
	public static function approach(current:Float, target:Float, elapsed:Float, ?speed:Float = -1):Float
	{
		if (speed < 0) speed = smoothSpeed;
		if (speed <= 0) return target;
		var delta:Float = target - current;
		if (Math.abs(delta) <= SNAP_EPSILON) return target;
		return current + delta * (1 - Math.exp(-speed * elapsed));
	}

	/** Ease-out cubic (0..1). */
	public static inline function easeOutCubic(t:Float):Float
	{
		var v:Float = FlxMath.bound(t, 0, 1);
		var inv:Float = 1 - v;
		return 1 - inv * inv * inv;
	}

	/** Ease-out back: overshoots slightly, then settles (used for pops). */
	public static inline function easeOutBack(t:Float):Float
	{
		var v:Float = FlxMath.bound(t, 0, 1) - 1;
		return 1 + (v * v * ((1.7 + 1) * v + 1.7));
	}

	/** Colour blend; returns 'b' at t = 1. */
	public static function lerpColor(a:FlxColor, b:FlxColor, t:Float):FlxColor
	{
		var v:Float = FlxMath.bound(t, 0, 1);
		if (v <= 0) return a;
		if (v >= 1) return b;
		return FlxColor.fromRGBFloat(
			(a.redFloat) + (b.redFloat - a.redFloat) * v,
			(a.greenFloat) + (b.greenFloat - a.greenFloat) * v,
			(a.blueFloat) + (b.blueFloat - a.blueFloat) * v
		);
	}

	/** Writes a style triple onto a background sprite + label, blended from 'from' to 'to' by 't'. */
	public static function blendStyle(bg:FlxSprite, text:FlxText, from:UIStyleData, to:UIStyleData, t:Float):Void
	{
		if (bg == null || !bg.exists || from == null || to == null) return;
		var v:Float = FlxMath.bound(t, 0, 1);
		bg.color = lerpColor(from.bgColor, to.bgColor, v);
		bg.alpha = from.bgAlpha + (to.bgAlpha - from.bgAlpha) * v;
		if (text != null && text.exists)
			text.color = lerpColor(from.textColor, to.textColor, v);
	}

	/** Interpolates two style triples (used by the buttons' hover / press blend). */
	public static function blendStyleData(a:UIStyleData, b:UIStyleData, t:Float):UIStyleData
	{
		if (a == null) return b;
		if (b == null) return a;
		var v:Float = FlxMath.bound(t, 0, 1);
		return {
			bgColor: lerpColor(a.bgColor, b.bgColor, v),
			textColor: lerpColor(a.textColor, b.textColor, v),
			bgAlpha: a.bgAlpha + (b.bgAlpha - a.bgAlpha) * v
		};
	}

	/** Writes a style triple instantly. */
	public static function applyStyle(bg:FlxSprite, text:FlxText, style:UIStyleData):Void
	{
		if (style == null) return;
		if (bg != null && bg.exists)
		{
			bg.color = style.bgColor;
			bg.alpha = style.bgAlpha;
		}
		if (text != null && text.exists) text.color = style.textColor;
	}

	// ===========================================================================
	// Graphics
	// ===========================================================================

	/**
	 * Creates a white rounded-rectangle sprite.
	 * The sprite is fully white with transparent corners, so '.color' / '.alpha' tinting works.
	 */
	public static function createRoundedRectSprite(width:Int, height:Int, ?radius:Int = -1):FlxSprite
	{
		var sprite:FlxSprite = new FlxSprite();
		bakeRounded(sprite, width, height, radius);
		return sprite;
	}

	/** Alias kept for the widgets that were written against the old helper API. */
	public static function makeRoundedRect(sprite:FlxSprite, width:Int, height:Int, ?radius:Int = -1):Void
	{
		bakeRounded(sprite, width, height, radius);
	}

	/**
	 * Replaces 'sprite' graphic with a white rounded rectangle of exactly width x height.
	 *
	 * The graphic is unique to this sprite (makeGraphic(..., true)); it is never taken from a
	 * cache, so destroying the sprite can never invalidate another widget.
	 */
	public static function bakeRounded(sprite:FlxSprite, width:Int, height:Int, ?radius:Int = -1):Void
	{
		if (sprite == null) return;

		var w:Int = (width < 1) ? 1 : width;
		var h:Int = (height < 1) ? 1 : height;
		if (radius == null) radius = -1;

		var r:Int = radius;
		if (r < 0) r = cornerRadius;
		r = Std.int(Math.max(0, Math.min(r, Std.int(Math.min(w, h) / 2))));
		if (w < 3 || h < 3) r = 0;

		sprite.makeGraphic(w, h, FlxColor.WHITE, true);
		if (r > 0) punchCorners(sprite.pixels, w, h, r);

		sprite.offset.set(0, 0);
		sprite.updateHitbox();
		sprite.offset.set(0, 0);
	}

	/** Solid rectangle sprite of exactly width x height (own graphic). */
	public static function createSolidSprite(width:Int, height:Int, color:FlxColor):FlxSprite
	{
		var sprite:FlxSprite = new FlxSprite();
		sprite.makeGraphic(Std.int(Math.max(1, width)), Std.int(Math.max(1, height)), color, true);
		sprite.offset.set(0, 0);
		return sprite;
	}

	/** Helper: make the four corners transparent via circle-mask pixel ops. */
	static function punchCorners(bmd:BitmapData, width:Int, height:Int, r:Int):Void
	{
		if (bmd == null || r < 1) return;

		var rsq:Float = r * r;
		bmd.fillRect(new Rectangle(0, 0, r, r), FlxColor.TRANSPARENT);
		bmd.fillRect(new Rectangle(width - r, 0, r, r), FlxColor.TRANSPARENT);
		bmd.fillRect(new Rectangle(0, height - r, r, r), FlxColor.TRANSPARENT);
		bmd.fillRect(new Rectangle(width - r, height - r, r, r), FlxColor.TRANSPARENT);

		for (px in 0...r)
		{
			for (py in 0...r)
			{
				var dx:Float = (px + 0.5) - r;
				var dy:Float = (py + 0.5) - r;
				if (dx * dx + dy * dy <= rsq)
				{
					bmd.setPixel32(px, py, 0xFFFFFFFF);
					bmd.setPixel32(width - 1 - px, py, 0xFFFFFFFF);
					bmd.setPixel32(px, height - 1 - py, 0xFFFFFFFF);
					bmd.setPixel32(width - 1 - px, height - 1 - py, 0xFFFFFFFF);
				}
			}
		}
	}

	// ===========================================================================
	// Hit testing
	// ===========================================================================

	/**
	 * Rect hit test relative to 'obj' own origin: the widget passes its local hit area
	 * (0, 0, width, height) and this compares it with the mouse in the same space the other
	 * widgets use (obj.getScreenPosition / mouse.getPositionInCameraView).
	 */
	public static function overlapsRect(obj:FlxObject, x:Float, y:Float, width:Float, height:Float, ?camera:FlxCamera):Bool
	{
		if (obj == null || !obj.exists || !obj.visible || width <= 0 || height <= 0) return false;

		var cam:FlxCamera = (camera != null) ? camera : FlxG.camera;
		if (cam == null) return false;

		var pos:FlxPoint = obj.getScreenPosition(null, cam);
		var mouse:FlxPoint = FlxG.mouse.getPositionInCameraView(cam);

		return mouse.x >= pos.x + x && mouse.x <= pos.x + x + width
			&& mouse.y >= pos.y + y && mouse.y <= pos.y + y + height;
	}
}