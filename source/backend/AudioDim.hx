package backend;

#if desktop
import openfl.Lib;
import openfl.events.Event;
#end

/**
 * Background audio attenuation ("Background Dim").
 *
 * The attenuation is a multiplier applied on top of the master volume by
 * `FlxSound.updateTransform()`. It deliberately does NOT write to `FlxG.sound.volume`:
 *
 *  - `FlxG.sound.volume` is the player's setting. The volume keys, the sound-tray readout and
 *    flixel's save file all use it. Writing the attenuated value there meant that if the sound
 *    tray happened to finish hiding while the game was unfocused (it keeps updating while
 *    `runInBackground` is on), flixel persisted the dimmed volume as the player's volume, so
 *    the next launch started quiet in the foreground.
 *  - The old code used the absolute value 0.2, so a player whose volume was already at or
 *    below 0.2 was made LOUDER when the window lost focus. A multiplier can only attenuate.
 *
 * The multiplier is reset unconditionally when the window regains focus, so turning the
 * option off, disabling "Run in Background" or a missed focus event can never leave the game
 * stuck at the attenuated level.
 */
class AudioDim
{
	/** Multiplier applied while the window is unfocused (0.25 = -12 dB). */
	public static inline var FACTOR:Float = 0.25;

	/** Current multiplier; 1 while the game is in the foreground. */
	public static var factor(default, null):Float = 1.0;

	static var installed:Bool = false;
	static var focused:Bool = true;

	/** Registers the focus listeners once. Safe to call from every entry point. */
	public static function install():Void
	{
		if (installed) return;
		installed = true;

		#if desktop
		// Lib.current.stage works before FlxGame exists, which lets Main install these
		// listeners before flixel's own ACTIVATE handler: the multiplier is then already
		// reset when flixel resumes the paused sounds.
		var stage = Lib.current.stage;
		if (stage != null)
		{
			stage.addEventListener(Event.DEACTIVATE, onFocusLost);
			stage.addEventListener(Event.ACTIVATE, onFocusGained);
		}
		#end

		refresh();
	}

	/** Re-evaluates the multiplier from the current focus/preference state. */
	public static function refresh():Void
	{
		var enabled:Bool = false;
		try { enabled = ClientPrefs.data != null && ClientPrefs.data.backgroundDim; } catch (e:Dynamic) {}
		setFactor((enabled && !focused) ? FACTOR : 1.0);
	}

	static function onFocusLost(_):Void
	{
		focused = false;
		refresh();
	}

	static function onFocusGained(_):Void
	{
		focused = true;
		refresh();
	}

	static function setFactor(value:Float):Void
	{
		if (value < 0) value = 0;
		if (value > 1) value = 1;
		factor = value;
	}
}
