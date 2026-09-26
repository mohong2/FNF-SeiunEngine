package;

/**
 * Persistence rules for achievement progress.
 *
 * Both APIs land here: the legacy Seiun side (a `Map<String, Bool>`) and the 0.7.3 style side
 * (an unlock list plus score variables). The list is the source of truth and the bool map is a
 * view over it, so a single save/flush pair keeps both readable again next launch.
 *
 * Deliberately free of flixel imports: the rules run under the achievement probe next to the
 * other client probes, with a plain object standing in for `FlxG.save.data`.
 */
class AchievementSave {
	/** Reads `data` into `unlocked` and `variables`; both are mutated in place. */
	public static function load(data:Dynamic, unlocked:Array<String>, variables:Map<String,Float>):Void {
		if (data == null) return;

		var saved:Array<String> = cast Reflect.field(data, 'achievementsUnlocked');
		if (saved != null) {
			var copy:Array<String> = saved.copy();
			unlocked.resize(0);
			for (name in copy)
				if (name != null && !unlocked.contains(name)) unlocked.push(name);
		}

		var savedVars:Map<String,Float> = cast Reflect.field(data, 'achievementsVariables');
		if (savedVars != null)
			for (key => value in savedVars) variables.set(key, value);

		// Saves written before the two APIs were unified only carry the legacy bool map.
		for (key in legacyKeys(Reflect.field(data, 'achievementsMap')))
			if (!unlocked.contains(key)) unlocked.push(key);
	}

	/** Key names of the legacy bool map; anonymous objects (very old saves) are read as fields. */
	static function legacyKeys(value:Dynamic):Array<String> {
		var out:Array<String> = [];
		if (value == null) return out;
		if (Type.getClass(value) == haxe.ds.StringMap) {
			var typed:haxe.ds.StringMap<Bool> = cast value;
			for (key in typed.keys()) out.push(key);
		} else {
			for (field in Reflect.fields(value)) out.push(field);
		}
		return out;
	}

	/** Writes the list, its map view and the score variables back into the save object. */
	public static function save(data:Dynamic, unlocked:Array<String>, map:Map<String,Bool>, variables:Map<String,Float>):Void {
		if (data == null) return;
		Reflect.setField(data, 'achievementsUnlocked', unlocked);
		Reflect.setField(data, 'achievementsMap', map);
		Reflect.setField(data, 'achievementsVariables', variables);
	}

	/** Rebuilds `map` from `unlocked`; the two are views of one set. */
	public static function rebuildMap(unlocked:Array<String>, map:Map<String,Bool>):Void {
		map.clear();
		for (name in unlocked) map.set(name, true);
	}

	/** Adds a name to both views. Returns false when it was already recorded. */
	public static function record(unlocked:Array<String>, map:Map<String,Bool>, name:String):Bool {
		if (name == null || name == '') return false;
		if (unlocked.contains(name) || map.exists(name)) return false;
		unlocked.push(name);
		map.set(name, true);
		return true;
	}
}
