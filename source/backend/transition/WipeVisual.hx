package backend.transition;

import flixel.FlxSprite;
import flixel.util.FlxColor;
import flixel.util.FlxGradient;

/**
 * The Seiun shutter.
 *
 * A hard-edged black curtain sweeps down the screen, a short soft lip softens the leading
 * edge and a thin highlight rides on it. Both halves move the boundary downwards, so leaving
 * one screen and entering the next read as a single continuous passthrough instead of two
 * unrelated wipes. The lip is what gives the eye a direction to follow; the curtain alone
 * reads as a plain fade.
 */
class WipeVisual extends TransitionVisual
{
	/** Height of the soft lip, as a fraction of the visible area. */
	static inline var EDGE_RATIO:Float = 0.12;
	/** Floor for the lip so it stays readable on small windows. */
	static inline var MIN_EDGE:Float = 48;
	/** Alpha of the leading highlight when the sweep starts. */
	static inline var HIGHLIGHT_ALPHA:Float = 0.25;
	/** Progress at which the highlight has faded out completely. */
	static inline var HIGHLIGHT_FADE:Float = 0.6;
	/** Tiny gradient texture that gets stretched across the lip. */
	static inline var LIP_TEXTURE_W:Int = 8;
	static inline var LIP_TEXTURE_H:Int = 64;

	var isTransIn:Bool;
	/** Height of the soft lip in world units. */
	var edge:Float;
	/** Height of the solid curtain: enough to swallow the whole visible area at either end. */
	var curtainHeight:Float;

	var curtain:FlxSprite;
	var lip:FlxSprite;
	var highlight:FlxSprite;

	public function new(width:Float, height:Float, duration:Float, isTransIn:Bool)
	{
		super(width, height, duration);
		this.isTransIn = isTransIn;

		edge = height * EDGE_RATIO;
		if (edge < MIN_EDGE) edge = MIN_EDGE;
		curtainHeight = height + edge * 2;

		// Solid curtain. A 1x1 graphic stretched with scale() keeps this cheap no matter how
		// far the camera is zoomed out - baking a full-size bitmap per transition does not.
		curtain = new FlxSprite();
		curtain.makeGraphic(1, 1, FlxColor.BLACK);
		curtain.scrollFactor.set();
		curtain.origin.set(0, 0);
		curtain.scale.set(width, curtainHeight);
		curtain.x = xOffset;
		sprites.push(curtain);

		// The lip is opaque on the side the curtain covers and fully transparent at the
		// leading edge, so the boundary is a short ramp instead of a full-screen haze.
		var lipColors:Array<FlxColor> = isTransIn ? [FlxColor.TRANSPARENT, FlxColor.BLACK] : [FlxColor.BLACK, FlxColor.TRANSPARENT];
		lip = FlxGradient.createGradientFlxSprite(LIP_TEXTURE_W, LIP_TEXTURE_H, lipColors);
		lip.scrollFactor.set();
		lip.origin.set(0, 0);
		lip.scale.set(width / LIP_TEXTURE_W, edge / LIP_TEXTURE_H);
		lip.x = xOffset;
		sprites.push(lip);

		// Thin sheen on the leading edge: short, subtle, and gone before the sweep ends.
		highlight = new FlxSprite();
		highlight.makeGraphic(1, 2, FlxColor.WHITE);
		highlight.scrollFactor.set();
		highlight.origin.set(0, 0);
		highlight.scale.set(width, 1);
		highlight.x = xOffset;
		highlight.alpha = HIGHLIGHT_ALPHA;
		sprites.push(highlight);
	}

	override public function update(elapsed:Float):Bool
	{
		var progress:Float = advance(elapsed);

		// The boundary runs from just above the visible area to just below it. Both halves
		// use the same travel, so the hand-off between them is seamless.
		var boundary:Float = yOffset - edge + progress * (viewHeight + edge);

		lip.y = boundary;
		highlight.y = boundary + edge * 0.5;

		if (isTransIn)
		{
			curtain.y = boundary + edge;
		}
		else
		{
			curtain.y = boundary - curtainHeight;
		}

		var sheen:Float = 1 - progress / HIGHLIGHT_FADE;
		highlight.alpha = (sheen > 0) ? HIGHLIGHT_ALPHA * sheen : 0;

		return finished;
	}
}
