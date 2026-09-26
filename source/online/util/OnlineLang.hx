package online.util;

import Language;

/**
 * Text / font entry point for the online UI.
 *
 * `OnlineLang.L("menu.join", "JOIN")` looks up `Online.menu.join` and falls back to the second
 * argument; `OnlineLang.font()` returns `Paths.languageFont()`. Keys live in
 * assets/lang/<Lang>/Online.json, and Language.loadDirectory() reads every .json in the folder.
 */
class OnlineLang {
	public static inline function L(key:String, ?fallback:String):String {
		return Language.get('Online.' + key, fallback);
	}

	/**
	 * Lobby menu item display names. OnlineState.itms must stay in English (its
	 * `switch (itms[curSelected].toLowerCase())` depends on it), so names are mapped here.
	 */
	public static function menuName(item:String):String {
		return switch (item) {
			case "JOIN": L('menu.join', 'JOIN');
			case "HOST": L('menu.host', 'HOST');
			case "FIND": L('menu.find', 'FIND');
			case "OPTIONS": L('menu.options', 'OPTIONS');
			case "LEADERBOARD": L('menu.leaderboard', 'LEADERBOARD');
			case "MOD DOWNLOADER": L('menu.downloader', 'MOD DOWNLOADER');
			default: item;
		};
	}

	public static inline function font():String {
		return Paths.languageFont();
	}
}