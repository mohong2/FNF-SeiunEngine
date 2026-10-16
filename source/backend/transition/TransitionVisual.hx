package backend.transition;

import flixel.FlxCamera;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.tweens.FlxEase;

/**
 * One half of a state transition: out covers the old state, in reveals the new one.
 *
 * A visual owns the sprites it draws and advances them from a single eased clock, so the
 * pieces of the animation can never drift apart the way two independent tweens can.
 */
class TransitionVisual
{
	/** Sprites to add to the transition substate, in draw order. */
	public var sprites:Array<FlxSprite> = [];

	/** True once the animation has run to the end. */
	public var finished(default, null):Bool = false;

	/** Left edge of the visible world area, in world units (cameras zoom around their centre). */
	public var xOffset:Float = 0;
	/** Top edge of the visible world area, in world units. */
	public var yOffset:Float = 0;
	/** Size of the visible world area, in world units. */
	public var viewWidth:Float = 0;
	public var viewHeight:Float = 0;

	var duration:Float;
	var elapsed:Float = 0;

	public function new(width:Float, height:Float, duration:Float)
	{
		this.viewWidth = width;
		this.viewHeight = height;
		this.duration = (duration > 0) ? duration : 0.01;

		// A camera zooms around its own centre, so an overlay that has to cover the whole
		// screen starts at the top-left of the *visible* world area, not at (0, 0). At zoom 1
		// both offsets are 0, which is the menu case this whole thing was written for.
		this.xOffset = -(width - FlxG.width) / 2;
		this.yOffset = -(height - FlxG.height) / 2;
	}

	/**
	 * Advances the clock and returns the eased 0..1 progress of this half.
	 *
	 * cubeOut is the sweet spot for these durations: the sweep is already at ~78% of its
	 * travel 40% in (so it reads as a cut, not as a slide), yet the edge keeps moving evenly
	 * enough that the finish never looks stalled - which is what quintOut does here.
	 */
	inline function advance(elapsed:Float):Float
	{
		this.elapsed += elapsed;

		var t:Float = this.elapsed / duration;
		if (t > 1) t = 1;
		else if (t < 0) t = 0;

		if (t >= 1) finished = true;

		return FlxEase.cubeOut(t);
	}

	/** @return true once this half of the transition has finished. */
	public function update(elapsed:Float):Bool
	{
		return finished;
	}

	public function setCameras(cameras:Array<FlxCamera>):Void
	{
		for (sprite in sprites)
			sprite.cameras = cameras;
	}
}
