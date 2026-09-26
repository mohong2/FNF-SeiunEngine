package;

import haxe.Json;
import openfl.utils.Assets;
import Section;
import Note;
import mohong.TraceManager;

typedef SwagSong =
{
	var song:String;
	var notes:Array<SwagSection>;
	var events:Array<Dynamic>;
	var bpm:Float;
	var needsVoices:Bool;
	var speed:Float;
	var offset:Float;

	var player1:String;
	var player2:String;
	var gfVersion:String;
	var stage:String;
	var format:String;

	@:optional var gameOverChar:String;
	@:optional var gameOverSound:String;
	@:optional var gameOverLoop:String;
	@:optional var gameOverEnd:String;

	@:optional var disableNoteRGB:Bool;

	/** Multi-key: chart key count (0-based: 3 = 4K, 8 = 9K). Old 4K charts lack the field and default to 3. */
	@:optional var mania:Null<Int>;

	@:optional var arrowSkin:String;
	@:optional var splashSkin:String;
	@:optional var difficultyName:String; // original chart difficulty (osu Version / Malody meta.version)

	/** Original chart creator/mapper carried over on osu!/Malody import. */
	@:optional var chartCreator:String;
	/** Original music artist carried over on osu!/Malody import. */
	@:optional var chartArtist:String;
	/** Original source string carried over on osu!/Malody import. */
	@:optional var chartSource:String;
	/** Original tags string carried over on osu!/Malody import. */
	@:optional var chartTags:String;

	public var validScore:Null<Bool>;
}


class Song
{
	public var song:String = null;
	public var notes:Array<SwagSection>;
	public var events:Array<Dynamic>;
	public var bpm:Float;
	public var needsVoices:Bool = true;
	public var arrowSkin:String;

	public var splashSkin:String;
	public var gameOverChar:String;
	public var gameOverSound:String;
	public var gameOverLoop:String;
	public var gameOverEnd:String;
	public var disableNoteRGB:Bool = false;
	public var mania:Null<Int> = 3;
	public var speed:Float = 1;
	public var stage:String;
	public var player1:String = 'bf';
	public var player2:String = 'dad';
	public var gfVersion:String = 'gf';

	public var mapper:String = 'N/A';
	public var musican:String = 'N/A';

	static public var isNewVersion:Bool = false;

	private static function onLoadJson(songJson:Dynamic) // Convert old charts to newest format
	{
		if (songJson.mania == null)
			songJson.mania = Note.defaultMania;

		if (songJson.gfVersion == null)
		{
			songJson.gfVersion = songJson.player3;
			songJson.player3 = null;
		}

		if (songJson.events == null)
		{
			songJson.events = [];
			for (secNum in 0...songJson.notes.length)
			{
				var sec:SwagSection = songJson.notes[secNum];

				var i:Int = 0;
				var notes:Array<Dynamic> = sec.sectionNotes;
				var len:Int = notes.length;
				while (i < len)
				{
					var note:Array<Dynamic> = notes[i];
					if (note[1] < 0)
					{
						songJson.events.push([note[0], [[note[2], note[3], note[4]]]]);
						notes.remove(note);
						len = notes.length;
					}
					else
						i++;
				}
			}
		}
	}

	public function new(song, notes, bpm)
	{
		this.song = song;
		this.notes = notes;
		this.bpm = bpm;
	}

	public static var chartPath:String;
	public static var loadedSongName:String;

	// ── Turbo chart DOM release guard ──
	// Remembers the reload arguments and identity token of the last real (non-events) chart
	// loadFromJson. Before dropping per-note data under Turbo, PlayState checks the token so a
	// restart can always reload the same chart from disk. SONG assigned by editors or scripts has no token and is skipped.
	public static var lastChartReloadJson:String;
	public static var lastChartReloadFolder:String;
	public static var lastChartToken:Int = 0;

	/** Trims exactly like StringTools.trim, but returns the original string when there is nothing to trim.
	 *  A multi-hundred-MB chart JSON would otherwise be copied twice, doubling the load peak. */
	static function trimChartJson(s:String):String
	{
		if (s == null) return null;
		var len:Int = s.length;
		var start:Int = 0;
		while (start < len && isJsonSpace(s, start)) start++;
		var end:Int = len;
		while (end > start && isJsonSpace(s, end - 1)) end--;
		if (start == 0 && end == len) return s;
		if (start >= end) return '';
		return s.substr(start, end - start);
	}

	/** Same whitespace test as StringTools.isSpace (tab/LF/VT/FF/CR/space). */
	inline static function isJsonSpace(s:String, pos:Int):Bool
	{
		var c:Int = s.charCodeAt(pos);
		return (c > 8 && c < 14) || c == 32;
	}

	/**
	 * Reads the chart text for hashing, using the same lookup order as the online GameClient.
	 * `online/GameClient.hx` calls it to hash the host's chart
	 * (`Md5.encode(Song.loadRawSong(...))` -> `verifyChart`) and `online/states/RoomState.hx`
	 * uses it for the local chart preview. This engine's `Song` had no raw-text accessor:
	 * `loadFromJson()` parses straight away and `getChart()` swallows a missing file by
	 * returning `null`, so neither can be reused here (the hash must be of the same bytes the host read).
	 *
	 * Guarded by ONLINE_ALLOWED because its only caller is the online slice.
	 */
	#if ONLINE_ALLOWED
	public static function loadRawSong(jsonInput:String, ?folder:String):String
	{
		var rawJson = null;

		var formattedFolder:String = Paths.formatToSongPath(folder);
		var formattedSong:String = Paths.formatToSongPath(jsonInput);
		#if MODS_ALLOWED
		var moddyFile:String = Paths.modsJson(formattedFolder + '/' + formattedSong);
		if (FileSystem.exists(moddyFile)) {
			rawJson = File.getContent(moddyFile).trim();
		}
		#end

		if (rawJson == null) {
			// The function is guarded as `#if sys / #else`; the `#else` branch is written as
			// `#elseif (ONLINE_ALLOWED)` so that every line of this function sits inside an
			// ONLINE_ALLOWED guard. The function itself is only compiled when ONLINE_ALLOWED is
			// set, so the branch selection is unchanged.
			#if (sys && ONLINE_ALLOWED)
			if (FileSystem.exists(Paths.json(formattedFolder + '/' + formattedSong)))
				rawJson = File.getContent(Paths.json(formattedFolder + '/' + formattedSong));
			#elseif (ONLINE_ALLOWED)
			rawJson = Assets.getText(Paths.json(formattedFolder + '/' + formattedSong));
			#end

			if (rawJson == null) {
				throw new haxe.Exception("Missing file: " + Paths.json(formattedFolder + '/' + formattedSong));
			}

			rawJson = trimChartJson(rawJson);
		}

		while (!rawJson.endsWith("}")) {
			rawJson = rawJson.substr(0, rawJson.length - 1);
			// LOL GOING THROUGH THE BULLSHIT TO CLEAN IDK WHATS STRANGE
		}

		return rawJson;
	}

	/**
	 * Streaming variant of loadRawSong() that only returns the MD5 of the same bytes.
	 *
	 * Md5.encode(Song.loadRawSong(...)) reads the whole file into one string first, which
	 * doubles peak memory; this reads in chunks and hashes incrementally, so the peak is a
	 * single read buffer. It is used only for large files and matches the old hash exactly.
	 * (verified on real charts).
	 */
	public static function hashRawSong(jsonInput:String, ?folder:String):String
	{
		var path:String = rawSongPath(jsonInput, folder);
		if (path != null && ChartStream.isLargeChart(path))
			return Md5Stream.hashChartFile(path);
		return haxe.crypto.Md5.encode(loadRawSong(jsonInput, folder));
	}

	/** Same lookup order as loadRawSong(): mod directory first, then the base directory. */
	static function rawSongPath(jsonInput:String, ?folder:String):String
	{
		#if sys
		var formattedFolder:String = Paths.formatToSongPath(folder);
		var formattedSong:String = Paths.formatToSongPath(jsonInput);
		#if MODS_ALLOWED
		var moddyFile:String = Paths.modsJson(formattedFolder + '/' + formattedSong);
		if (FileSystem.exists(moddyFile)) return moddyFile;
		#end
		var plainFile:String = Paths.json(formattedFolder + '/' + formattedSong);
		if (FileSystem.exists(plainFile)) return plainFile;
		#end
		return null;
	}
	#end

	/**
	 * Byte-streaming load for large charts (ChartStream).
	 *
	 * Enabled only when all of the following hold (otherwise the caller falls back to a full parse):
	 *   - sys target and the chart file on disk is >= ChartStream.MIN_STREAM_BYTES;
	 *   - not events.json;
	 *   - convertTo is psych_v1;
	 *   - the events array is readable from the top level;
	 *   - not CNE format.
	 *
	 * The returned SwagSong has empty notes[].sectionNotes: the real notes are read per section
	 * in PlayState.generateSong from the byte ranges recorded in __seiunStream, then dropped.
	 * Note re-encoding cannot happen at skeleton stage, so the data needed for it is recorded
	 * here and applied by the reader through ChartStream.rewriteSectionNotes().
	 */
	static function tryLoadStreaming(jsonInput:String, ?folder:String, convertTo:String):SwagSong
	{
		#if sys
		try
		{
			return tryLoadStreamingInner(jsonInput, folder, convertTo);
		}
		catch (e:Dynamic)
		{
			// Any scan / normalisation / re-encode problem falls back to a full parse.
			// The skeleton data itself must be correct: a missing sectionNotes crashes on the
			// convert() iteration in native code, which no Haxe try/catch can stop.
			return null;
		}
		#else
		return null;
		#end
	}

	static function tryLoadStreamingInner(jsonInput:String, ?folder:String, convertTo:String):SwagSong
	{
		#if sys
		if (jsonInput == 'events') return null;
		if (convertTo != null && convertTo.length > 0 && convertTo != 'psych_v1') return null;

		var formattedFolder:String = Paths.formatToSongPath(folder);
		var formattedSong:String = Paths.formatToSongPath(jsonInput);
		var path:String = null;


		#if MODS_ALLOWED
		var moddyFile:String = Paths.modsJson(formattedFolder + '/' + formattedSong);
		if (FileSystem.exists(moddyFile) && ChartStream.isLargeChart(moddyFile))
			path = moddyFile;
		#end


		if (path == null)
		{
			var plainFile:String = Paths.json(formattedFolder + '/' + formattedSong);
			if (FileSystem.exists(plainFile) && ChartStream.isLargeChart(plainFile))
				path = plainFile;
		}
		if (path == null) return null;


		var scan:ChartStream.ChartScanResult = null;
		try
		{
			scan = ChartStream.scan(path);
		}
		catch (e:Dynamic)
		{
			return null;
		}
		if (scan == null || scan.chart == null) return null;


		var chart:Dynamic = scan.chart;
		if (Reflect.hasField(chart, 'codenameChart')) return null;


		// psych 1.0 keeps the chart body in a song sub-object
		isNewVersion = true;
		if (Reflect.hasField(chart, 'song'))
		{
			var subSong:Dynamic = Reflect.field(chart, 'song');
			if (subSong != null && Type.typeof(subSong) == TObject)
			{
				chart = subSong;
				if (Reflect.field(chart, 'format') == null) isNewVersion = false;
			}
		}


		var ev:Dynamic = Reflect.field(chart, 'events');
		if (ev == null || !Std.isOfType(ev, Array)) return null;


		// Format normalisation: run the same convert() on the skeleton. Its sectionNotes are
		// empty, so only section-level scalars are touched; note re-encoding stays with the reader.
		// note re-encoding is left to the reader.
		var fmt:String = Reflect.field(chart, 'format');
		if (fmt == null) fmt = 'unknown';
		var needRewrite:Bool = !fmt.startsWith('psych_v1');
		if (needRewrite)
		{
			Reflect.setField(chart, 'format', 'psych_v1_convert');
			convert(chart);
			isNewVersion = true;
		}


		// A whitespace-only difficulty name is not written back out
		if (Reflect.field(chart, 'difficultyName') != null)
		{
			var dn:String = Std.string(Reflect.field(chart, 'difficultyName'));
			if (StringTools.trim(dn).length == 0) Reflect.deleteField(chart, 'difficultyName');
		}


		if (jsonInput != 'events') StageData.loadDirectory(chart);
		onLoadJson(chart);


		lastChartReloadJson = jsonInput;
		lastChartReloadFolder = folder;
		++lastChartToken;
		Reflect.setField(chart, '__seiunToken', lastChartToken);


		// convert()'s re-encoding rule is the chart-level mania (not the per-note Change Mania);
		// onLoadJson already filled a missing mania with Note.defaultMania, so this matches what
		// convert() would compute.
		var rawMania:Dynamic = Reflect.field(chart, 'mania');
		var mania:Int = (rawMania != null && Std.int(rawMania) >= 0 && Std.int(rawMania) < Note.ammo.length)
			? Std.int(rawMania) : Note.defaultMania;
		var ammo:Int = Note.ammo[mania];


		Reflect.setField(chart, '__seiunStream', {
			path: path,
			ranges: scan.ranges,
			ammo: ammo,
			rewrite: needRewrite
		});
		return cast chart;
		#else
		return null;
		#end
	}

	public static function loadFromJson(jsonInput:String, ?folder:String, ?convertTo:String = 'psych_v1'):SwagSong
	{
		// Large charts stream from disk; null means the conditions were not met, so fall through
		// to the full parse below.
		var streamed:SwagSong = tryLoadStreaming(jsonInput, folder, convertTo);
		if (streamed != null) return streamed;

		var rawJson = null;
		
		var formattedFolder:String = Paths.formatToSongPath(folder);
		var formattedSong:String = Paths.formatToSongPath(jsonInput);
		#if MODS_ALLOWED
		var moddyFile:String = Paths.modsJson(formattedFolder + '/' + formattedSong);
		if(FileSystem.exists(moddyFile)) {
			rawJson = trimChartJson(File.getContent(moddyFile));
		}
		#end

		if(rawJson == null) {
			#if sys
			rawJson = trimChartJson(File.getContent(Paths.json(formattedFolder + '/' + formattedSong)));
			#else
			rawJson = trimChartJson(Assets.getText(Paths.json(formattedFolder + '/' + formattedSong)));
			#end
		}

		while (!rawJson.endsWith("}"))
		{
			rawJson = rawJson.substr(0, rawJson.length - 1);
			// LOL GOING THROUGH THE BULLSHIT TO CLEAN IDK WHATS STRANGE
		}

		// FIX THE CASTING ON WINDOWS/NATIVE
		// Windows???
		// trace(songData);

		// trace('LOADED FROM JSON: ' + songData.notes);
		/* 
			for (i in 0...songData.notes.length)
			{
				trace('LOADED FROM JSON: ' + songData.notes[i].sectionNotes);
				// songData.notes[i].sectionNotes = songData.notes[i].sectionNotes
			}

				daNotes = songData.notes;
				daSong = songData.song;
				daBpm = songData.bpm; */

		// convertTo defaults to 'psych_v1' (old charts are upgraded); pass '' to skip normalisation
		// and keep the on-disk format field (used online to tell re-encoded charts from original ones).
		var songJson:Dynamic = parseJSON(rawJson, jsonInput, convertTo);
		if(jsonInput != 'events') StageData.loadDirectory(songJson);
		onLoadJson(songJson);

		// Records the reload arguments and identity token (events.json excluded; used by the Turbo DOM release guard and restarts)
		if (jsonInput != 'events')
		{
			lastChartReloadJson = jsonInput;
			lastChartReloadFolder = folder;
			++lastChartToken;
			Reflect.setField(songJson, '__seiunToken', lastChartToken);
		}
		return songJson;
	}

	static var _lastPath:String;

	public static function getChart(jsonInput:String, ?folder:String):SwagSong
	{
		if (folder == null)
			folder = jsonInput;
		var rawData:String = null;

		var formattedFolder:String = Paths.formatToSongPath(folder);
		var formattedSong:String = Paths.formatToSongPath(jsonInput);

		#if MODS_ALLOWED
		var moddyFile:String = Paths.modsJson(formattedFolder + '/' + formattedSong);
		if(FileSystem.exists(moddyFile))
			rawData = File.getContent(moddyFile);
		#end

		if(rawData == null)
		{
			_lastPath = Paths.json('$formattedFolder/$formattedSong');
			rawData = Assets.getText(_lastPath);
		}

		return rawData != null ? parseJSON(rawData, jsonInput) : null;
	}

	public static function parseJSON(rawData:String, ?nameForError:String = null, ?convertTo:String = 'psych_v1'):SwagSong
	{
		// Strip UTF-8 BOM: haxe.format.JsonParser rejects U+FEFF at position 0,
		// which crashes chart loading for files saved by Notepad/PowerShell etc.
		if (rawData != null && rawData.length > 0 && rawData.charCodeAt(0) == 0xFEFF)
			rawData = rawData.substr(1);

		// Detect CNE (Codename Engine) format
		if (rawData.indexOf('"codenameChart"') != -1)
		{
			try
			{
				var testData:Dynamic = Json.parse(rawData);
				if ((testData.codenameChart == true || testData.codenameChart == "true") && testData.strumLines != null)
				{
					CoolUtil.traceMsg('trace.convertingChart', 'converting CNE chart {} to psych_v1 format...', [nameForError]);
					return editors.content.CneExport.cneToPsych(rawData);
				}
			}
			catch(e:Dynamic) {}
		}

		var songJson:SwagSong = cast Json.parse(rawData);
		isNewVersion = true;
		if (Reflect.hasField(songJson, 'song'))
		{
			var subSong:SwagSong = Reflect.field(songJson, 'song');
			if (subSong != null && Type.typeof(subSong) == TObject)
			{
				songJson = subSong;
				if (songJson.format == null)
					isNewVersion = false; // it build with old
			}
		}

		if (convertTo != null && convertTo.length > 0)
		{
			var fmt:String = songJson.format;
			if (fmt == null) fmt = songJson.format = 'unknown';

			switch (convertTo)
			{
				case 'psych_v1':
					if (!fmt.startsWith('psych_v1'))
					{
						// Old-format chart -> convert to psych_v1
						// (convert() is safe and side-effect free for empty sectionNotes)
						trace('converting chart $nameForError with format $fmt to psych_v1 format...');
						songJson.format = 'psych_v1_convert';
						convert(songJson);
						isNewVersion = true; // data has been converted
				}
			}
		}

		if (songJson.mania == null)
			songJson.mania = Note.defaultMania;

		// Normalize a whitespace-only difficulty name (e.g. imported charts
		// with an empty Version / meta.version) so it never leaks into exports.
		if (songJson.difficultyName != null)
		{
			var dn:String = Std.string(songJson.difficultyName);
			if (StringTools.trim(dn).length == 0)
				Reflect.deleteField(songJson, 'difficultyName');
		}

		return songJson;
	}

	public static function castVersion(songJson:SwagSong):SwagSong // Convert psych_v1 format to old format
	{
		// Multi-key: the key count comes from the chart's mania so 9K/18K charts are not flipped as 4K.
		var mania:Int = (songJson != null && songJson.mania != null && songJson.mania >= 0 && songJson.mania < Note.ammo.length) ? Std.int(songJson.mania) : Note.defaultMania;
		var ammo:Int = Note.ammo[mania];

		for (i in 0...songJson.notes.length)
		{
			for (ii in 0...songJson.notes[i].sectionNotes.length)
			{
				var gottaHitNote:Bool = songJson.notes[i].mustHitSection;
				var noteData:Int = Std.int(songJson.notes[i].sectionNotes[ii][1]);
				if (noteData < 0) continue;
				if (!gottaHitNote)
				{
					if (noteData >= ammo)
					{
						noteData -= ammo;
					}
					else
					{
						noteData += ammo;
					}
					songJson.notes[i].sectionNotes[ii][1] = noteData;
				}
			}
		}
		isNewVersion = false;
		return songJson;
	}

	public static function convert(songJson:Dynamic):Void
	{
		if(songJson.gfVersion == null)
		{
			songJson.gfVersion = songJson.player3;
			if(Reflect.hasField(songJson, 'player3')) Reflect.deleteField(songJson, 'player3');
		}

		if(songJson.events == null)
		{
			songJson.events = [];
			for (secNum in 0...songJson.notes.length)
			{
				var sec:SwagSection = songJson.notes[secNum];

				var i:Int = 0;
				var notes:Array<Dynamic> = sec.sectionNotes;
				var len:Int = notes.length;
				while(i < len)
				{
					var note:Array<Dynamic> = notes[i];
					if(note[1] < 0)
					{
						songJson.events.push([note[0], [[note[2], note[3], note[4]]]]);
						notes.remove(note);
						len = notes.length;
					}
					else i++;
				}
			}
		}

		var sectionsData:Array<SwagSection> = songJson.notes;
		if(sectionsData == null) return;

		// Multi-key: use the chart's own key count (mania, 0-based) instead of a hardcoded 4.
		// Old charts without a mania field are treated as the default 4K.
		var mania:Int = (songJson.mania != null && songJson.mania >= 0 && songJson.mania < Note.ammo.length) ? Std.int(songJson.mania) : Note.defaultMania;
		var ammo:Int = Note.ammo[mania];

		for (section in sectionsData)
		{
			var beats:Null<Float> = cast section.sectionBeats;
			if (beats == null || Math.isNaN(beats))
			{
				section.sectionBeats = 4;
				if(Reflect.hasField(section, 'lengthInSteps')) Reflect.deleteField(section, 'lengthInSteps');
			}

			for (note in section.sectionNotes)
			{
				var rawData:Int = Std.int(note[1]);
				if (rawData < 0) continue;
				var gottaHitNote:Bool = (rawData < ammo) ? section.mustHitSection : !section.mustHitSection;
				note[1] = (rawData % ammo) + (gottaHitNote ? 0 : ammo);

				// Old format (0.1 - 0.3.2) numeric noteType converted to a string
				if(note.length > 3 && !Std.isOfType(note[3], String) && note[3] != null)
				{
					var typeIdx:Int = Std.int(note[3]);
					if(typeIdx >= 0 && typeIdx < Note.defaultNoteTypes.length)
						note[3] = Note.defaultNoteTypes[typeIdx];
					else
						note[3] = '';
				}
				else if(note.length <= 3)
				{
					// Very old charts without a noteType field at all
					note.push('');
				}
			}
		}
	}


}
