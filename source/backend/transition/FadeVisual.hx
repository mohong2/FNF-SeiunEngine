package backend.transition;

import flixel.FlxSprite;
import flixel.util.FlxColor;

/**
 * Plain full-screen black fade - the calm alternative to the shutter.
 */
class FadeVisual extends TransitionVisual
{
	var fade:FlxSprite;
	var isTransIn:Bool;

	public function new(width:Float, height:Float, duration:Float, isTransIn:Bool)
	{
		super(width, height, duration);
		this.isTransIn = isTransIn;

		fade = new FlxSprite();
		fade.makeGraphic(1, 1, FlxColor.BLACK);
		fade.scrollFactor.set();
		fade.origin.set(0, 0);
		fade.scale.set(width, height);
		fade.x = xOffset;
		fade.y = yOffset;
		fade.alpha = isTransIn ? 1 : 0;
		sprites.push(fade);
	}

	override public function update(elapsed:Float):Bool
	{
		var progress:Float = advance(elapsed);

		fade.alpha = isTransIn ? 1 - progress : progress;

		return finished;
	}
}
