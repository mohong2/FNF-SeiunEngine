package backend.transition;

/**
 * Visual style used when the engine moves from one state to another.
 *
 * The value lives as a plain string in `ClientPrefs.data.transitionStyle` so the option is
 * driven entirely by `assets/preload/data/options/visuals.json` (see OptionLoader). The raw
 * values double as the identifiers shown in the options menu; they get translated through the
 * `option.transitionStyle.<value>` language keys whenever a translation exists.
 */
enum abstract TransitionStyle(String) from String to String
{
	/** No animation at all - the state is swapped on the spot. */
	var Off = 'Off';
	/** Plain full-screen black fade. */
	var Fade = 'Fade';
	/** Downward sweeping black shutter with a hard leading edge (default). */
	var Wipe = 'Wipe';

	/**
	 * Converts a stored or scripted value into a style.
	 *
	 * Unknown values - and the `null` a save written before this option existed can produce -
	 * fall back to `Wipe`, which is the engine's default behaviour.
	 */
	public static function parse(value:String):TransitionStyle
	{
		if (value == null) return Wipe;

		return switch (value.toLowerCase().trim())
		{
			case 'off' | 'none' | 'instant' | 'skip': Off;
			case 'fade' | 'crossfade': Fade;
			default: Wipe;
		}
	}
}
