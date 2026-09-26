package backend;

// Reads the note-skin list for the online option payload.
// `online/GameClient.hx` uses it in `getOptions()`:
//     var data:NoteSkinStructure = NoteSkinData.getCurrent(-1);
//     options.set('noteSkin', data.skin); / 'noteSkinMod' / 'noteSkinURL'
// It lives directly in the `backend` package because that is where the rest of the
// note-skin plumbing is rooted.
//
// The whole file is inside `#if ONLINE_ALLOWED`: its only reason to exist is the online slice, and
// this engine's own note-skin handling does not go through it. Keeping it guarded preserves the
// ability to produce an online-less build.
//
// Prerequisites verified present on this engine:
//   `Paths.getLibraryPathForce`, `Paths.mods`, `CoolUtil.coolTextFile`,
//   `Mods.parseList`/`Mods.getGlobalMods` (source/backend/Mods.hx), `online.mods.OnlineMods.getModURL`.
//
// Two implementation notes:
//   * `reloadNoteSkins()` does not keep the stray unused `skinsFinished` local (dead code).
//   * the default-skin entry is not read from `ClientPrefs.defaultData.noteSkin`. This engine's
//     `defaultData` is populated from the save file, not from the declared field defaults, so
//     reading it here could be null on a fresh profile. The literal `'Default'` is used instead --
//     exactly this engine's own `data.noteSkin` initial value (`source/ClientPrefs.hx:38`).
//     Behaviour for a player who has never changed the setting is identical.
#if ONLINE_ALLOWED

import openfl.utils.Assets;

#if sys
import sys.io.File;
import sys.FileSystem;
#end

class NoteSkinData {
	public static var noteSkins:Array<NoteSkinStructure> = [];
	public static var noteSkinArray:Array<String> = [];

	public static function reloadNoteSkins()
	{
		noteSkins = [];
		noteSkinArray = [];

			// `Paths.getLibraryPathForce` is module-private in this engine. `@:privateAccess` is used
			// here instead of widening that declaration, because a shared engine change must stay
			// inside `#if ONLINE_ALLOWED` and a visibility modifier cannot be macro-conditional.
			// This line is inside the guard, so a macro-off build never sees it and the engine
			// declaration keeps its original visibility.
		var directories:Array<Array<String>> = [[@:privateAccess Paths.getLibraryPathForce('', 'shared'), '']];
		#if MODS_ALLOWED
		directories.push([Paths.mods(), '']);

		for (mod in Mods.parseList().enabled)
		{
			if(Mods.getGlobalMods().contains(mod))
				directories.push([Paths.mods(mod + '/'), mod]);
		}
		#end

		for (i in 0...directories.length) {
			var directory:String = directories[i][0] + 'images/noteSkins/list.txt';

			for (skin in CoolUtil.coolTextFile(directory)) {
				if(!noteSkinArray.contains(skin)) {
					noteSkins.push({
						skin: skin,
						folder: directories[i][1],
						url: online.mods.OnlineMods.getModURL(directories[i][1])
					});

					noteSkinArray.push(skin);
				}
			}
		}

		noteSkins.insert(0, {skin: 'Default', folder: ''}); //Default skin always comes first
		noteSkinArray.insert(0, 'Default');
	}

	public static function getCurrent(?player:Int = 0):NoteSkinStructure
	{
		var toReturn:NoteSkinStructure = null;

		if(player == -1)
			toReturn = NoteSkinData.noteSkins[NoteSkinData.noteSkinArray.indexOf(ClientPrefs.noteSkin)];
		else
			toReturn = NoteSkinData.noteSkins[NoteSkinData.noteSkinArray.indexOf(ClientPrefs.getNoteSkin(player))];

		if(toReturn == null)
			toReturn = NoteSkinData.noteSkins[0];

		return toReturn;
	}
}

typedef NoteSkinStructure = {
	var skin:String;
	var folder:String;
	@:optional var url:String;
}
#end
