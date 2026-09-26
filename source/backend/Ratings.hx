package backend;

import ClientPrefs;
import CoolUtil;
import Paths;

/**
 * Judgement-window helpers.
 * - getRating: maps a ms difference to marvelouse/sick/good/bad/shit
 * - timingPresets.txt: preset judgement windows (Leather / Psych-Kade / FNF)
 * - syncWindows: copies judgementTimings into the ClientPrefs window fields so rating,
 *   replay and the results screen all use one set of windows.
 */
class Ratings
{
	private static var scores:Array<Dynamic> = [['marvelous', 400], ['sick', 350], ['good', 200], ['bad', 50], ['shit', -150]];

	/** Returns the judgement name for a ms difference ('marvelous' / 'sick' / 'good' / 'bad' / 'shit'). */
	public static function getRating(time:Float):String
	{
		var judges:Array<Int> = ClientPrefs.data.judgementTimings;
		if (judges == null || judges.length < 4)
			judges = [25, 50, 70, 100];

		// Dense-chart optimization: the original allocated a nested array literal and compared
		// entries on every hit (GC pressure + Dynamic boxing). The logic is a plain window
		// comparison, so it is inlined here with identical results:
		//   marvelous (when enabled) -> sick -> good -> bad, first match wins, otherwise shit.
		if (ClientPrefs.data.marvelousRatings && time <= judges[0])
			return "marvelous";
		if (time <= judges[1])
			return "sick";
		if (time <= judges[2])
			return "good";
		if (time <= judges[3])
			return "bad";
		return "shit";
	}

	/** Equivalent inline form of the original implementation, kept for reference. */
	static function getRatingLegacy(time:Float):String
	{
		var judges:Array<Int> = ClientPrefs.data.judgementTimings;
		if (judges == null || judges.length < 4)
			judges = [25, 50, 70, 100];

		var timings:Array<Array<Dynamic>> = [
			[judges[0], "marvelous"],
			[judges[1], "sick"],
			[judges[2], "good"],
			[judges[3], "bad"]
		];

		var rating:String = 'bruh';

		for (x in timings)
		{
			if (x[1] == "marvelous" && ClientPrefs.data.marvelousRatings || x[1] != "marvelous")
			{
				if (time <= x[0] && rating == 'bruh')
				{
					rating = x[1];
				}
			}
		}

		if (rating == 'bruh')
			rating = "shit";

		return rating;
	}

	public static var timingPresets:Map<String, Array<Int>> = [];
	public static var presets:Array<String> = [];

	public static function returnPreset(name:String = "leather engine"):Array<Int>
	{
		if (timingPresets.exists(name))
			return timingPresets.get(name);

		return [25, 50, 70, 100];
	}

	/**
	 * Looks up the preset name for a set of judgement windows; returns "Custom" when nothing matches.
	 * Used by replay and the score history to label the judgement type.
	 */
	public static function presetNameForTimings(timings:Array<Int>):String
	{
		if (timings == null || timings.length < 4) return 'Custom';
		if (presets.length == 0) loadPresets();

		for (name in presets)
		{
			var t:Array<Int> = timingPresets.get(name);
			if (t != null && t.length >= 4
				&& t[0] == timings[0] && t[1] == timings[1] && t[2] == timings[2] && t[3] == timings[3])
				return name;
		}
		return 'Custom';
	}

	public static function loadPresets()
	{
		presets = [];
		timingPresets = [];

		var timingPresetsArray = CoolUtil.coolTextFile(Paths.txt("timingPresets"));

		for (array in timingPresetsArray)
		{
			var values = array.split(",");
			if (values.length < 5) continue;

			timingPresets.set(values[0], [
				Std.parseInt(values[1]),
				Std.parseInt(values[2]),
				Std.parseInt(values[3]),
				Std.parseInt(values[4])
			]);
			presets.push(values[0]);
		}

		// Fallback: keep at least the Leather Engine preset when the txt file is missing or damaged
		if (presets.length == 0)
		{
			timingPresets.set("Leather Engine", [25, 50, 70, 100]);
			presets.push("Leather Engine");
		}
	}

	/**
	 * Copies judgementTimings [marvelous, sick, good, bad] into
	 * ClientPrefs' marvelousWindow / sickWindow / goodWindow / badWindow.
	 * The rating, replay and results screens all read those window fields.
	 */
	public static function syncWindows():Void
	{
		var t:Array<Int> = ClientPrefs.data.judgementTimings;
		if (t == null || t.length < 4)
			t = [25, 50, 70, 100];

		ClientPrefs.data.marvelousWindow = t[0];
		ClientPrefs.data.sickWindow = t[1];
		ClientPrefs.data.goodWindow = t[2];
		ClientPrefs.data.badWindow = t[3];
	}

	public static function getScore(rating:String)
	{
		var score:Int = 0;

		for (x in scores)
		{
			if (rating == x[0])
			{
				score = x[1];
			}
		}

		return score;
	}
}
