package backend.seiun.ui;

import backend.MusicBeatState;
import flixel.FlxG;
import flixel.tweens.FlxTween;
import flixel.tweens.FlxEase;

/**
 * Base class for Seiun Engine menu states.
 *
 * The menu theme keeps playing while the player moves from one menu to
 * another: every menu state asks for the music through `ensureMenuMusic()`
 * instead of restarting the track on each state switch.
 */
class SeiunMenuState extends MusicBeatState
{
	/** True while the currently playing music is the menu theme. */
	public static var menuMusicActive:Bool = false;

	/**
	 * Start the menu music unless the same track is already playing.
	 * This keeps the song playing seamlessly across menu state switches.
	 */
	public static function ensureMenuMusic(volume:Float = 1):Void
	{
		if (menuMusicActive && FlxG.sound.music != null && FlxG.sound.music.playing)
		{
			FlxG.sound.music.volume = volume;
			return;
		}
		playMenuMusic(volume);
	}

	/** Restart the menu music from scratch (used after switching mods). */
	public static function playMenuMusic(volume:Float = 1):Void
	{
		FlxG.sound.playMusic(Paths.music('freakyMenu'), 0);
		FlxTween.tween(FlxG.sound.music, {volume: volume}, 0.5, {ease: FlxEase.sineOut});
		menuMusicActive = true;
	}

	/** Tell the base class the menu music is no longer playing (e.g. gameplay). */
	public static function markMenuMusicStopped():Void
	{
		menuMusicActive = false;
	}
}
