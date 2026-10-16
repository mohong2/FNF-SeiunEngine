package backend.transition;

import ClientPrefs;

/**
 * Single decision point for state-switch transitions.
 *
 * `MusicBeatState` asks the director for a style and a duration; the director is the only
 * place that knows the player's preference, so adding another style never touches the
 * state-switching code again.
 */
class TransitionDirector
{
	/**
	 * How long the outgoing state takes to be covered.
	 *
	 * Fast on purpose: the sweep has to feel like a cut, not like a loading screen. The
	 * cubeOut curve used by the visuals covers ~78% of the travel in the first 40% of it.
	 */
	public static inline var OUT_DURATION:Float = 0.25;
	/** How long the incoming state takes to be revealed. */
	public static inline var IN_DURATION:Float = 0.35;
	/**
	 * Full-black pause between the two halves. Two frames of held black are what make the
	 * switch land as an impact instead of a continuous slide.
	 */
	public static inline var HOLD_DURATION:Float = 0.03;

	/** The style the player picked in Options -> Visuals and UI. */
	public static function currentStyle():TransitionStyle
	{
		return TransitionStyle.parse(ClientPrefs.data != null ? ClientPrefs.data.transitionStyle : null);
	}

	/** True when the animation is turned off and states should swap on the spot. */
	public static function isInstant():Bool
	{
		return currentStyle() == Off;
	}

	/** Builds the visual for one half of a transition. */
	public static function createVisual(isTransIn:Bool, width:Float, height:Float, duration:Float):TransitionVisual
	{
		return switch (currentStyle())
		{
			case Fade | Off: new FadeVisual(width, height, duration, isTransIn);
			default: new WipeVisual(width, height, duration, isTransIn);
		}
	}
}
