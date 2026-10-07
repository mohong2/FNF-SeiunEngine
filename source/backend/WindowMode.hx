package backend;

import flixel.FlxG;
import lime.math.Rectangle;
import lime.system.Display;
import lime.ui.Window;
import openfl.Lib;
#if desktop
import openfl.events.Event;
import openfl.events.KeyboardEvent;
import openfl.ui.Keyboard;
#end

/**
 * Window mode handling, shared by the boot path (Main / TitleState) and the options page.
 *
 * Modes are exactly the values of `ClientPrefs.data.windowedmode`:
 *   windowed   - a normal decorated window, at the size it had before.
 *   fullscreen - real SDL fullscreen (a display mode switch).
 *   borderless - "true" borderless fullscreen: decorations off and the window resized
 *                over the display, with SDL fullscreen explicitly *off*.
 *
 * Why borderless must not ask SDL for fullscreen: that is the state Windows reads as
 * "this process took over the screen", which is what Auto HDR (and the fullscreen
 * optimization path) hooks into - the display switches into HDR mode and the game sits
 * on a black screen while it happens. A borderless window that simply covers the
 * display stays an ordinary composited window, so nothing is switched.
 *
 * This mirrors what mods do by hand (`window.borderless = true` plus resizing to
 * `window.display.bounds`, see the "Paranoia but Limu Varelt & Selevena Sings It" mod's
 * data/paranoia-limu/Window.lua), except that it is an engine mode instead of a
 * per-song script, and it also restores the player's previous window size when they
 * switch back to windowed.
 *
 * F11 flips between windowed and borderless at any time (see toggleShortcut), so the two
 * modes a player actually switches mid-song are reachable without opening the menu.
 */
class WindowMode
{
	public static inline var WINDOWED:String = 'windowed';
	public static inline var FULLSCREEN:String = 'fullscreen';
	public static inline var BORDERLESS:String = 'borderless';

	/** True while the window covers the display with its decorations removed. */
	public static var borderlessActive(default, null):Bool = false;

	/** Decorated-window geometry to go back to when leaving borderless / fullscreen. */
	static var windowedBounds:Null<{x:Int, y:Int, width:Int, height:Int}> = null;

	/**
	 * Applies a mode. Null or anything unknown falls back to windowed.
	 */
	public static function apply(mode:String):Void
	{
		var window:Window = Lib.application.window;
		if (window == null) return;

		switch (mode)
		{
			case FULLSCREEN:
				saveWindowedBounds(window);
				borderlessActive = false;
				window.borderless = false;
				FlxG.fullscreen = true;
				window.fullscreen = true;

			case BORDERLESS:
				saveWindowedBounds(window);
				enterBorderless(window);

			default:
				leaveBorderless(window);
		}
	}

	/**
	 * Borderless fullscreen: decorations off, window moved and sized over the display,
	 * and no SDL fullscreen anywhere in the process.
	 */
	public static function enterBorderless(window:Window):Void
	{
		FlxG.fullscreen = false;
		window.fullscreen = false;
		window.borderless = true;
		borderlessActive = true;

		var display:Display = window.display;
		if (display == null) return;

		var bounds:Rectangle = display.bounds;
		// A display without a usable desktop rectangle would shrink the window to nothing.
		if (bounds.width < 2 || bounds.height < 2) return;

		window.x = Std.int(bounds.x);
		window.y = Std.int(bounds.y);
		// One extra pixel: a window sized exactly to the display can leave a hairline
		// along an edge on some drivers, and the extra pixel sits off-screen anyway.
		window.width = Std.int(bounds.width) + 1;
		window.height = Std.int(bounds.height) + 1;

		// Re-assert after the resize: a driver can hand back the old display mode when a
		// fullscreen window is resized, and that is the switch we are avoiding.
		if (window.fullscreen) window.fullscreen = false;
	}

	/**
	 * Windowed: decorations back, at the size the window had before it was taken over.
	 */
	public static function leaveBorderless(window:Window):Void
	{
		FlxG.fullscreen = false;
		window.fullscreen = false;
		window.borderless = false;
		borderlessActive = false;

		var b = windowedBounds;
		if (b == null) return;

		window.x = b.x;
		window.y = b.y;
		window.width = b.width;
		window.height = b.height;
		windowedBounds = null;
	}

	/**
	 * Remembers the decorated window geometry. Only records while the window is still a
	 * normal one, so going fullscreen -> borderless -> windowed returns to the size the
	 * player actually had.
	 */
	static function saveWindowedBounds(window:Window):Void
	{
		if (windowedBounds != null || borderlessActive || FlxG.fullscreen || window.fullscreen) return;
		windowedBounds = {x: window.x, y: window.y, width: window.width, height: window.height};
	}

	#if desktop
	/** Registered once, from TitleState: FlxG.stage is only guaranteed there. */
	static var shortcutsInstalled:Bool = false;

	/**
	 * Held-F11 flag. The OS repeats KEY_DOWN while a key is held, and every repeat would
	 * otherwise flip the mode again.
	 */
	static var f11Held:Bool = false;

	/**
	 * Installs the global F11 shortcut.
	 *
	 * The listener sits on the stage instead of being polled from a state update so that it
	 * also works in sub-states (pause menu, dialogs), where the state underneath is not
	 * being updated at all.
	 */
	public static function installShortcuts():Void
	{
		if (shortcutsInstalled) return;

		var stage = FlxG.stage;
		if (stage == null) return;

		shortcutsInstalled = true;
		stage.addEventListener(KeyboardEvent.KEY_DOWN, onShortcutKeyDown);
		stage.addEventListener(KeyboardEvent.KEY_UP, onShortcutKeyUp);
		stage.addEventListener(Event.DEACTIVATE, onShortcutFocusLost);
	}

	/**
	 * A KEY_UP that happens while the window is not focused never arrives, which would
	 * leave F11 held forever. Same remedy Flixel uses for its own key state.
	 */
	static function onShortcutFocusLost(_):Void
	{
		f11Held = false;
	}

	static function onShortcutKeyDown(event:KeyboardEvent):Void
	{
		if (event.keyCode != Keyboard.F11) return;

		if (f11Held) return;
		f11Held = true;

		// F11 on its own; Alt/Ctrl combinations belong to whatever else may want them.
		if (event.altKey || event.ctrlKey) return;

		#if ONLINE_ALLOWED
		// The online lobby already gives F11 to `GameClient.reconnect()` (see
		// online.states.RoomState.update). Whoever is on that screen keeps the existing
		// behaviour rather than having the window resized under them as well.
		if (Std.isOfType(FlxG.state, online.states.RoomState)) return;
		#end

		toggleShortcut();
	}

	static function onShortcutKeyUp(event:KeyboardEvent):Void
	{
		if (event.keyCode == Keyboard.F11) f11Held = false;
	}

	/**
	 * F11: flips between the two modes a player switches at runtime - windowed and
	 * borderless fullscreen. Exclusive `fullscreen` is deliberately not part of the toggle:
	 * it is the mode that switches the display mode, so it stays on the options page where
	 * the choice is explicit.
	 *
	 * The resulting mode is written to ClientPrefs and saved, so it survives a restart. If
	 * the options page is what is on screen right now, its row text is refreshed as well -
	 * otherwise it would keep showing the value from before the key press.
	 */
	public static function toggleShortcut():Void
	{
		var window:Window = Lib.application.window;
		if (window == null) return;

		// Anything that currently owns the screen goes back to a normal window.
		var ownsScreen:Bool = borderlessActive || FlxG.fullscreen || window.fullscreen;
		var mode:String = ownsScreen ? WINDOWED : BORDERLESS;

		try
		{
			if (ClientPrefs.data != null) ClientPrefs.data.windowedmode = mode;
			apply(mode);
			ClientPrefs.saveSettings();

			var state = FlxG.state;
			if (Std.isOfType(state, options.OptionsState))
				cast(state, options.OptionsState).refreshOptionsText('windowedmode');
		}
		catch (e:Dynamic)
		{
			trace('trace.windowMode.shortcutFailed: ' + Std.string(e));
		}
	}
	#end
}
