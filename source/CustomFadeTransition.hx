package;

import backend.MusicBeatSubstate;
import backend.transition.TransitionDirector;
import backend.transition.TransitionVisual;
import flixel.FlxCamera;
import flixel.FlxG;

/**
 * Host substate for a state transition.
 *
 * The look of the transition lives in `backend.transition` and is chosen by
 * `TransitionDirector` from the player's Options -> Visuals and UI preference. This class
 * only keeps the old name and the old static API alive, so every existing call site - engine,
 * mods, Lua and HScript - keeps working untouched.
 */
class CustomFadeTransition extends MusicBeatSubstate
{
	/**
	 * Camera the overlay is drawn on, or null for the default cameras.
	 *
	 * Set by an incoming state before `super.create()` (PlayState points it at camOther,
	 * ResultsState at its HUD camera, ...). Kept as a plain static - not a property - so it
	 * stays visible to reflection-based script access.
	 */
	public static var nextCamera:FlxCamera;

	/** Fired when the outgoing half is done and the queued state switch may run. */
	public static var finishCallback:Void->Void;

	var isTransIn:Bool = false;
	var visual:TransitionVisual = null;
	/** Remaining full-black pause between the two halves (out only). */
	var holdTime:Float = 0;
	var holding:Bool = false;
	var completed:Bool = false;
	var callbackFired:Bool = false;

	public function new(duration:Float, isTransIn:Bool)
	{
		super();

		this.isTransIn = isTransIn;

		// The overlay is drawn on this camera, so its zoom decides how much world space has
		// to be covered. Consuming it here matches the old behaviour exactly.
		var cam:FlxCamera = nextCamera;
		nextCamera = null;

		var reference:FlxCamera = (cam != null) ? cam : FlxG.camera;
		var zoom:Float = reference.zoom;
		if (zoom <= 0.001) zoom = 1;

		visual = TransitionDirector.createVisual(isTransIn, reference.width / zoom, reference.height / zoom, duration);
		for (sprite in visual.sprites)
			add(sprite);
		if (cam != null)
			visual.setCameras([cam]);

		// Position everything for frame 0 so nothing flashes at a default position first.
		visual.update(0);
	}

	override function update(elapsed:Float)
	{
		if (visual != null && !completed)
		{
			if (holding)
			{
				holdTime -= elapsed;
				if (holdTime <= 0) finishOutTransition();
			}
			else if (visual.update(elapsed))
			{
				if (isTransIn)
				{
					// The new state is fully visible: just take the overlay away.
					completed = true;
					close();
				}
				else
				{
					// Hold the black for a beat so the switch lands as an impact.
					holding = true;
					holdTime = TransitionDirector.HOLD_DURATION;
				}
			}
		}

		super.update(elapsed);
	}

	function finishOutTransition():Void
	{
		completed = true;
		fireFinishCallback();
	}

	function fireFinishCallback():Void
	{
		if (callbackFired) return;
		callbackFired = true;

		// Cleared before the call: the callback switches state, and a stale callback left
		// behind would make the next out-transition fire twice.
		var callback:Void->Void = finishCallback;
		finishCallback = null;
		if (callback != null) callback();
	}

	override function destroy()
	{
		// A transition torn down mid-flight (parent state died, window closed, mod reloaded)
		// must still complete the switch it was asked to perform, otherwise the queued
		// FlxG.switchState never happens and the game is left on a black screen.
		if (!isTransIn && !completed) fireFinishCallback();

		// The sprites are members of this substate, so FlxGroup.destroy() releases them.
		visual = null;

		super.destroy();
	}
}
