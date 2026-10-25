package backend;

import flixel.FlxCamera;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.util.FlxColor;
import flixel.util.FlxSpriteUtil;
import openfl.filters.BlurFilter;
import ClientPrefs;

/**
 * Shared helpers for modern glass/acrylic UI screens.
 *
 * - createScreenCamera(): creates a dedicated, static screen-space camera.
 *   Using this for substate UI prevents PlayState/Freeplay camera scroll, zoom
 *   and follow movement from shifting the interface or the mouse hitboxes.
 * - applyBlur()/clearBlur(): applies/removes a real OpenFL Gaussian-ish blur on
 *   the underlying game/menu camera. Respects ClientPrefs.data.shaders.
 */
class UIScreen
{
	public static function createScreenCamera():FlxCamera
	{
		var cam = new FlxCamera();
		cam.bgColor.alpha = 0;
		FlxG.cameras.add(cam, false);
		return cam;
	}

	/**
	 * Creates a screen-space camera whose viewport crops everything assigned to it.
	 *
	 * This is the reliable way to clip a scrolling text block: `FlxSprite.clipRect`
	 * offsets the visible content by `clipRect.y` on the tile renderer, so using it
	 * as a scroll window drags the text out of the panel instead of scrolling it.
	 * A camera viewport keeps its world position fixed and moves the content under it.
	 *
	 * The camera's `x`/`y` are its top-left corner. `scroll` is aligned with that
	 * corner so children can keep using normal screen coordinates.
	 */
	public static function createViewportCamera(x:Float, y:Float, width:Int, height:Int):FlxCamera
	{
		var cam = new FlxCamera(Std.int(x), Std.int(y), width, height);
		cam.bgColor.alpha = 0;
		cam.scroll.set(cam.x, cam.y);
		FlxG.cameras.add(cam, false);
		return cam;
	}

	public static function applyBlur(cam:FlxCamera, radius:Float = 9):Void
	{
		if (cam == null || !ClientPrefs.data.shaders) return;
		var filters:Array<openfl.filters.BitmapFilter> = [new BlurFilter(radius, radius, 2)];
		cam.setFilters(filters);
	}

	public static function clearBlur(cam:FlxCamera):Void
	{
		if (cam == null) return;
		cam.filters = null;
	}

	/**
	 * Rounded translucent glass card with a subtle 1px white border.
	 */
	public static function makeGlassCard(x:Float, y:Float, width:Int, height:Int,
		radius:Int = 18, ?fill:FlxColor):FlxSprite
	{
		if (fill == null)
			fill = FlxColor.fromRGBFloat(0.06, 0.09, 0.18, 0.62);

		var card = new FlxSprite(x, y).makeGraphic(width, height, FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(card, 0, 0, width, height, radius, radius, fill,
			{thickness: 1, color: FlxColor.fromRGBFloat(1, 1, 1, 0.08)});
		return card;
	}
}
