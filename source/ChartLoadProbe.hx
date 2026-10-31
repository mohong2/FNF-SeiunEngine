package;

import haxe.Int64;

/**
 * Dev-only chart-load probe, used to measure and verify the real in-engine load path without
 * clicking through the menus.
 *
 * Activation (environment only; normal gameplay never reaches this):
 *   SEIUN_CHART_PROBE="<songFolder>:<chartKey>[:<useCache 0|1>[:<modFolder>]]"
 *   SEIUN_CHART_PROBE_OUT=<optional result file path>
 *
 * BootState.handOver() boots straight into PlayState for that chart; PlayState.generateSong()
 * calls onNotesGenerated() once the note list exists, which writes one result line and exits 0.
 * Result keys: songLoad (Song.loadFromJson wall time), stateCreateToNotes, generateSong_* phases,
 * sections/parts/notesFed/representatives/folded/cacheHit/prefetch/cacheEnabled.
 */
class ChartLoadProbe
{
	public static var enabled:Bool = false;

	/** SEIUN_CHART_PROBE_STAY=1 keeps the process alive after the result, so a test
	 *  can inspect the first gameplay frames (memory, GPU upload, screenshots). */
	static var stayAlive:Bool = false;

	static var tSwitch:Float = 0;
	static var tCreate:Float = 0;
	static var tSongLoad:Float = 0;
	static var songLoadSeconds:Float = 0;
	static var outPath:String = 'chart_probe_result.txt';
	static var spec:String = '';

	public static function tryAutoStart():Bool
	{
		var raw:String = null;
		try raw = Sys.getEnv('SEIUN_CHART_PROBE') catch (e:Dynamic) {}
		if (raw == null || raw.length == 0) return false;

		enabled = true;
		spec = raw;
		try
		{
			var bits:Array<String> = raw.split(':');
			var folder:String = bits[0];
			var chartKey:String = (bits.length > 1 && bits[1].length > 0) ? bits[1] : bits[0];
			var useCache:Bool = (bits.length > 2) ? (bits[2] != '0') : true;
			var modFolder:String = (bits.length > 3) ? bits[3] : '';
			var out:String = null;
			try out = Sys.getEnv('SEIUN_CHART_PROBE_OUT') catch (e:Dynamic) {}
			if (out != null && out.length > 0) outPath = out;
			try stayAlive = Sys.getEnv('SEIUN_CHART_PROBE_STAY') == '1' catch (e:Dynamic) {}

			if (modFolder.length > 0) Paths.currentModDirectory = modFolder;
			ClientPrefs.data.chartCache = useCache;

			tSwitch = haxe.Timer.stamp();
			tSongLoad = haxe.Timer.stamp();
			PlayState.SONG = Song.loadFromJson(chartKey, folder);
			songLoadSeconds = haxe.Timer.stamp() - tSongLoad;
			if (PlayState.SONG == null) throw 'Song.loadFromJson returned null';
			PlayState.storyDifficulty = 0;
			PlayState.isStoryMode = false;
			tCreate = haxe.Timer.stamp();
			FlxG.switchState(new PlayState());
		}
		catch (e:Dynamic)
		{
			write(['FAILED', 'spec=' + spec, 'error=' + Std.string(e), 'songLoad=' + round3(songLoadSeconds)]);
			Sys.exit(2);
		}
		return true;
	}

	public static function onNotesGenerated(t0:Float, tLoop:Float, tWait:Float, tBody:Float,
		sectionIndex:Int, partCount:Int, fed:Int64, reps:Int, turbo:Bool, cacheHit:Bool,
		prefetch:Bool, cacheEnabled:Bool, nativeUsed:Bool, nativeFoldMs:Float):Void
	{
		if (!enabled) return;
		var now:Float = haxe.Timer.stamp();
		write([
			'OK',
			'spec=' + spec,
			'chartCachePref=' + ClientPrefs.data.chartCache,
			'songLoad=' + round3(songLoadSeconds),
			'stateCreateToNotes=' + round3(now - tCreate),
			'generateSong_total=' + round3(now - t0),
			'generateSong_scanSetup=' + round3(tLoop - t0),
			'generateSong_parseBuild=' + round3(now - tLoop),
			'generateSong_sectionWait=' + round3(tWait),
			'generateSong_perNoteBody=' + round3(tBody),
			'wallFromProbeStart=' + round3(now - tSwitch),
			'sections=' + sectionIndex,
			'parts=' + partCount,
			'notesFed=' + Int64.toStr(fed),
			'representatives=' + reps,
			'folded=' + (Int64.compare(fed, Int64.ofInt(reps)) != 0),
			'turbo=' + turbo,
			'cacheHit=' + cacheHit,
			'prefetch=' + prefetch,
			'cacheEnabled=' + cacheEnabled,
			'nativeUsed=' + nativeUsed,
			'nativeFold=' + round3(nativeFoldMs / 1000),
		]);
		if (!stayAlive) Sys.exit(0);
	}

	static function round3(v:Float):String
		return Std.string(Math.round(v * 1000) / 1000);

	static function write(lines:Array<String>):Void
	{
		var text:String = lines.join('\n') + '\n';
		try sys.io.File.saveContent(outPath, text) catch (e:Dynamic) {}
		try Sys.println(text) catch (e:Dynamic) {}
	}
}
