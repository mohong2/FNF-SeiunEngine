package backend;

import backend.BackupFormat.BackupContainer;
import backend.BackupFormat.BackupError;
import backend.BackupFormat.HeaderSink;
import backend.BackupFormat.InputSource;
import backend.BackupFormat.BackupStream;
import backend.BackupFormat.StringHeaderSink;
import backend.BackupFormat.StringSource;
import backend.BackupData.BackupJsonStats;
import backend.BackupData.BackupScoreBlob;
import backend.BackupData.BackupScoreFile;
import haxe.io.Bytes;
#if sys
import sys.FileSystem;
import sys.io.File;
import sys.io.FileInput;
import sys.io.FileOutput;
import sys.io.FileSeek;
#end
import Achievements;
import Allscore;
import BuildInfo;
import ClientPrefs;
import Highscore;
import Language;
import states.StoryMenuState;
import SUtil;
import flixel.FlxG;
import flixel.input.gamepad.FlxGamepadInputID;
import flixel.input.keyboard.FlxKey;
import flixel.util.FlxSave;
import mohong.TraceManager;

/** Everything a successful restore changed, for the status line. */
typedef BackupApplyResult =
{
	var fields:Int;
	var scores:Int;
	var scoresRemoved:Int;
	var bytes:Int;
	var safetyPath:String;
}

/** How much a written backup contains, for the status line and the logs. */
typedef BackupWriteStats =
{
	var path:String;
	/** Size of the text file on disk, in bytes. */
	var size:Int;
	/** Size of the JSON payload, in bytes. */
	var payload:Int;
	var fields:Int;
	var scores:Int;
	var scoreBytes:Int;
}

/** What a capture produced, before it is written anywhere. */
typedef BackupCapture =
{
	var payload:Int;
	var fields:Int;
	var scores:Int;
	var scoreBytes:Int;
}

/**
 * Reads the live game data into a .SEB file and puts it back.
 *
 * The file format, the validation and the legacy upgrade live in BackupFormat and
 * BackupData, which have no engine dependencies and are covered by tools/backup_tests.
 * This class is only the glue: FlxG.save, key binds, the .scores directory, and the
 * reload calls that make a restored save visible without restarting the game.
 *
 * ## Why the whole save object instead of a field list
 *
 * The old exporter walked a hard-coded list of interesting fields and converted them to
 * JSON by hand. Every field it forgot (or could not convert: Maps, Int64, nested objects)
 * was silently lost, and the restore path then skipped those fields again. The result was
 * a backup that "worked" - no error, no crash - while quietly not containing the data.
 *
 * Here the unit is the save object itself: every field of FlxG.save.data is stored as a
 * Serializer string (the same serializer FlxSave uses for the file), so Maps, Int64,
 * nested arrays and anything a mod put in the save round-trip exactly. Fields that cannot
 * be serialized are skipped *at export time* with a log line, never at restore time.
 *
 * ## Streaming instead of one giant string
 *
 * A score history is tens of megabytes. Building the file as one string meant holding the
 * score base64, the JSON, the packed container and the encoded text at the same time -
 * several times the size of the data. writeBackupToFile() streams the payload straight to
 * disk chunk by chunk, so backing up 23 MB of scores needs a few hundred KB of memory.
 * createBackupText() keeps the old whole-text behaviour for the platforms whose save
 * dialog only accepts text (Android SAF) and for the tests.
 *
 * ## Restore is all-or-nothing
 *
 * 1. Decode and validate every field and every score blob (no writes yet).
 * 2. Write a safety copy of the current data to .backups/.
 * 3. Apply the save fields, key binds and score files.
 * 4. If any write fails, put the safety copy back.
 * 5. Reload the in-memory caches (ClientPrefs, Highscore, Allscore, achievements).
 */
class BackupUtil
{
	/** Automatic pre-restore copies. Kept next to the game, like .scores. */
	public static inline var AUTO_DIR = './.backups/';
	public static inline var AUTO_PREFIX = 'SeiunEngine_AutoBackup_';
	public static inline var AUTO_KEEP = 5;

	// ------------------------------------------------------------------ export

	/**
	 * Captures the current game data and returns the text a .SEB file contains.
	 * Throws BackupError when the current state cannot be captured, so the caller never
	 * writes a half-empty backup over a good one.
	 */
	public static function createBackupText():String
	{
		var sink = new StringHeaderSink();
		writeTo(sink);
		return sink.toString();
	}

	#if sys
	/**
	 * Captures the current game data and streams it into `path`.
	 *
	 * The file is written as it is produced, so the memory this needs does not depend on
	 * how big the score history is. A failure deletes the partial file instead of leaving
	 * a truncated backup behind.
	 */
	public static function writeBackupToFile(path:String):BackupWriteStats
	{
		if (path == null || path.length == 0)
			throw new BackupError('there is no place to write the backup to');

		var sink:FileBackupSink = null;
		try
		{
			sink = new FileBackupSink(path);
			var capture:BackupCapture = writeTo(sink);
			sink.close();

			var size:Int = 0;
			try size = Std.int(FileSystem.stat(path).size) catch (e:Dynamic) {}

			return {
				path: path,
				size: size,
				payload: capture.payload,
				fields: capture.fields,
				scores: capture.scores,
				scoreBytes: capture.scoreBytes
			};
		}
		catch (e:Dynamic)
		{
			// nothing is left behind for the player to mistake for a backup
			if (sink != null) sink.abort();
			throw rethrow(e, 'the backup file could not be written');
		}
	}
	#end

	/** Captures the live data and pushes it through `sink`; returns what was written. */
	static function writeTo(sink:HeaderSink):BackupCapture
	{
		var started:Float = haxe.Timer.stamp();

		var data:BackupData = captureData();
		var stream = new BackupStream(sink, 0);
		var json:BackupJsonStats = data.writeJson(stream.write, scoreOpener());
		var written = stream.finish();

		var elapsed:Float = Math.round((haxe.Timer.stamp() - started) * 1000) / 1000;
		TraceManager.info('trace.backup.created',
			'Backup captured: {} save fields, {} score files, {} payload bytes, {}s', [
				mapSize(data.saveFields), json.scores, written.length, Std.string(elapsed)
			]);

		return {
			payload: written.length,
			fields: mapSize(data.saveFields),
			scores: json.scores,
			scoreBytes: json.scoreBytes
		};
	}

	static function captureData():BackupData
	{
		var data = new BackupData();
		data.engineVersion = safeVersion();
		data.buildVersion = safeBuild();
		data.platform = platformName();

		var now:Date = Date.now();
		data.createdAt = now.toString();
		data.createdAtUnix = now.getTime() / 1000;

		data.saveFields = collectSaveFields();
		data.keyboard = collectKeyBinds(ClientPrefs.keyBinds);
		data.gamepad = collectPadBinds();

		#if sys
		// Only the paths: the bytes of each score file are read while the payload is
		// written, one file at a time, and dropped as soon as they have been encoded.
		for (path in Allscore.listScoreFiles())
			data.scores.push({path: path, size: -1, hash: 0, data: null});
		#end

		return data;
	}

	#if sys
	/** Reads one score file when the payload writer asks for it. Null skips the entry. */
	static function scoreOpener():BackupScoreFile->Bytes
	{
		var dir:String = Allscore.scoreDirectory();
		return function(score:BackupScoreFile):Bytes {
			var full:String = dir + score.path;
			try
			{
				return File.getBytes(full);
			}
			catch (e:Dynamic)
			{
				// A locked or unreadable score file must not fail the whole backup;
				// losing one history entry is better than losing all of them.
				TraceManager.warn('trace.backup.scoreReadFailed',
					'Backup: score file {} could not be read and was skipped: {}', [full, e]);
				return null;
			}
		};
	}
	#end

	static function collectSaveFields():Map<String, String>
	{
		if (FlxG.save == null || FlxG.save.data == null)
			throw new BackupError('the game save is not loaded');

		var values:Map<String, Dynamic> = new Map();
		for (field in Reflect.fields(FlxG.save.data))
		{
			try
			{
				values.set(field, Reflect.field(FlxG.save.data, field));
			}
			catch (e:Dynamic)
			{
				TraceManager.warn('trace.backup.readFieldFailed', 'Backup: could not read save field "{}": {}', [field, e]);
			}
		}

		return BackupData.encodeSaveFields(values, function(field:String, error:String) {
			TraceManager.warn('trace.backup.skipField',
				'Backup: save field "{}" cannot be serialized and was skipped: {}', [field, error]);
		});
	}

	static function collectKeyBinds(binds:Map<String, Array<FlxKey>>):Map<String, Array<Int>>
	{
		var out:Map<String, Array<Int>> = new Map();
		if (binds == null) return out;

		for (name => keys in binds)
		{
			if (keys == null) continue;
			var codes:Array<Int> = [];
			for (key in keys) codes.push(cast key);
			out.set(name, codes);
		}
		return out;
	}

	static function collectPadBinds():Map<String, Array<Int>>
	{
		var out:Map<String, Array<Int>> = new Map();
		#if !android
		for (name => buttons in ClientPrefs.gamepadBinds)
		{
			if (buttons == null) continue;
			var codes:Array<Int> = [];
			for (button in buttons) codes.push(cast button);
			out.set(name, codes);
		}
		#end
		return out;
	}

	// ------------------------------------------------------------------ parse

	/** Decodes and fully validates a .SEB file that is already in memory. */
	public static function parseBackupText(text:String):BackupData
	{
		if (text == null || text.length == 0)
			throw new BackupError('the file is empty');

		return acceptContainer(BackupFormat.readContainer(new StringSource(text)));
	}

	#if sys
	/**
	 * Decodes and fully validates a .SEB file on disk.
	 *
	 * The file is read in chunks: a 40 MB backup never becomes a 40 MB string, so the
	 * memory this needs follows the payload, not the text.
	 */
	public static function parseBackupFile(path:String):BackupData
	{
		var length:Int = -1;
		try
		{
			length = Std.int(FileSystem.stat(path).size);
		}
		catch (e:Dynamic) {}

		var input:FileInput = null;
		var container:BackupContainer = null;
		var failure:Dynamic = null;

		try
		{
			input = File.read(path);
			container = BackupFormat.readContainer(new InputSource(input, length));
		}
		catch (e:Dynamic)
		{
			failure = e;
		}

		// Haxe has no finally, so the handle is closed here either way.
		if (input != null)
		{
			try input.close() catch (e:Dynamic) {}
		}

		if (failure != null)
		{
			if (Std.isOfType(failure, BackupError)) throw failure;
			throw new BackupError('the backup file could not be read (' + Std.string(failure) + ')');
		}

		return acceptContainer(container);
	}

	/** Size of a backup file in bytes, for the "contains" line of the confirm dialog. */
	public static function backupFileSize(path:String):Int
	{
		try
		{
			if (path != null && path.length > 0 && FileSystem.exists(path))
				return Std.int(FileSystem.stat(path).size);
		}
		catch (e:Dynamic) {}
		return 0;
	}
	#end

	static function acceptContainer(container:BackupContainer):BackupData
	{
		var data:BackupData = BackupData.fromContainer(container);

		// Validate every value now, while nothing has been written yet. A backup whose
		// first three fields are fine and whose fourth is garbage must not half-restore.
		data.decodeSaveFields();
		data.decodeScores();

		TraceManager.info('trace.backup.parsed',
			'Backup read: format {} ({}), {} save fields, {} score files', [
				container.version, container.legacy ? 'legacy' : 'current',
				data.saveFieldCount(), data.scoreCount()
			]);
		return data;
	}

	// ------------------------------------------------------------------ restore

	/**
	 * Replaces the live save, key binds and score history with the backup.
	 * Throws BackupError on failure; in that case the previous data has been put back
	 * (unless the rollback itself failed, which the message says explicitly).
	 */
	public static function applyBackup(data:BackupData):BackupApplyResult
	{
		if (data == null) throw new BackupError('there is no backup to restore');

		// 1. Decode everything first: this can throw without having touched anything.
		var values:Map<String, Dynamic> = data.decodeSaveFields();
		var scoreBlobs:Array<BackupScoreBlob> = data.decodeScores();

		// 2. Safety copy of the *current* state, streamed straight to disk. It is also the
		//    rollback source, so the current data is never kept in memory a second time.
		var safetyPath:String = writeSafetyCopy();

		var removed:Int = 0;
		var bytes:Int = 0;
		for (blob in scoreBlobs) bytes += blob.bytes.length;

		// 3. Apply. Any exception from here on is rolled back.
		try
		{
			applySaveData(values, !data.legacy);
			applyKeyBinds(data.keyboard, data.gamepad);
			#if sys
			removed = writeScoreFiles(scoreBlobs);
			#end
			flushSave();
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.applyFailed', 'Backup restore failed, rolling back: {}', [e]);
			var rolledBack:Bool = rollback(safetyPath);
			var reason:String = describeError(e);
			if (rolledBack)
				throw new BackupError(reason + ' — your previous data has been put back');
			throw new BackupError(reason + ' — AND the rollback failed; the previous data is in '
				+ (safetyPath != null ? safetyPath : AUTO_DIR));
		}

		return {
			fields: mapSize(values),
			scores: scoreBlobs.length,
			scoresRemoved: removed,
			bytes: bytes,
			safetyPath: safetyPath
		};
	}

	/**
	 * Refreshes every in-memory cache that mirrors FlxG.save.data, so the restored data
	 * is what the running game sees. Called after applyBackup() succeeded.
	 */
	public static function reloadAfterRestore():Void
	{
		// Order matters: loadPrefs() reads both the main save and controls_v3, and the
		// other caches read FlxG.save.data directly.
		ClientPrefs.loadPrefs();
		Highscore.load();
		Allscore.load();
		Achievements.reload();

		if (FlxG.save != null && FlxG.save.data != null && Reflect.hasField(FlxG.save.data, 'weekCompleted'))
			StoryMenuState.weekCompleted = Reflect.field(FlxG.save.data, 'weekCompleted');

		Language.load();
		TraceManager.info('trace.backup.reloaded', 'Backup restore: in-memory data reloaded');
	}

	static function applySaveData(values:Map<String, Dynamic>, clearFirst:Bool):Void
	{
		if (FlxG.save == null || FlxG.save.data == null)
			throw new BackupError('the game save is not loaded');

		if (clearFirst)
		{
			// v2 backups contain the whole save: drop stale fields so the result is exactly
			// the backup. Legacy backups only contain a subset, so they merge instead.
			for (field in Reflect.fields(FlxG.save.data))
				Reflect.deleteField(FlxG.save.data, field);
		}

		for (field => value in values)
			Reflect.setField(FlxG.save.data, field, value);
	}

	static function applyKeyBinds(keyboard:Map<String, Array<Int>>, gamepad:Map<String, Array<Int>>):Void
	{
		var applied:Int = 0;

		if (keyboard != null)
		{
			for (name => codes in keyboard)
			{
				if (!ClientPrefs.keyBinds.exists(name)) continue; // control from another engine version
				var keys:Array<FlxKey> = [];
				for (code in codes) keys.push(cast code);
				ClientPrefs.keyBinds.set(name, keys);
				applied++;
			}
		}

		#if !android
		if (gamepad != null)
		{
			for (name => codes in gamepad)
			{
				if (!ClientPrefs.gamepadBinds.exists(name)) continue;
				var buttons:Array<FlxGamepadInputID> = [];
				for (code in codes) buttons.push(cast code);
				ClientPrefs.gamepadBinds.set(name, buttons);
				applied++;
			}
		}
		#end

		// A backup that carries no known control name (or an all-empty one) leaves the
		// current binds alone rather than making the game unplayable.
		if (applied == 0) return;
		persistControls();
	}

	static function persistControls():Void
	{
		var save:FlxSave = new FlxSave();
		save.bind('controls_v3', 'ninjamuffin99');
		save.data.keyboard = ClientPrefs.keyBinds;
		#if !android
		save.data.gamepad = ClientPrefs.gamepadBinds;
		#end
		var written:Bool = save.flush();
		save.destroy();

		if (!written)
			throw new BackupError('the key bindings could not be written (the storage may be full)');
	}

	#if sys
	static function writeScoreFiles(blobs:Array<BackupScoreBlob>):Int
	{
		var dir:String = Allscore.scoreDirectory();
		SUtil.mkDirs(dir);

		var wanted:Map<String, Bool> = new Map();
		for (blob in blobs) wanted.set(blob.path, true);

		// Write the backup's files first. Deleting first would open a window where neither
		// the old nor the new history exists, and a failure inside that window is exactly
		// what the rollback is supposed to cover.
		for (blob in blobs)
		{
			var target:String = dir + blob.path;
			var slash:Int = target.lastIndexOf('/');
			if (slash > 0) SUtil.mkDirs(target.substr(0, slash));
			File.saveBytes(target, blob.bytes);
		}

		// Then remove entries the backup does not know about, so the restored history is
		// the backup's history and not "the backup plus whatever was already here".
		var removed:Int = 0;
		for (path in Allscore.listScoreFiles())
		{
			if (wanted.exists(path)) continue;
			try
			{
				FileSystem.deleteFile(dir + path);
				removed++;
			}
			catch (e:Dynamic)
			{
				// Leaving one extra history entry behind is not worth failing a restore.
				TraceManager.warn('trace.backup.scoreDeleteFailed',
					'Backup: old score file {} could not be removed: {}', [dir + path, e]);
			}
		}
		return removed;
	}
	#end

	static function flushSave():Void
	{
		if (FlxG.save == null) throw new BackupError('the game save is not loaded');
		if (!FlxG.save.flush())
		{
			var detail:String = FlxG.save.lastError != null ? FlxG.save.lastError : 'unknown error';
			throw new BackupError('the save file could not be written: ' + detail);
		}
	}

	static function rollback(safetyPath:String):Bool
	{
		#if sys
		if (safetyPath == null || safetyPath.length == 0)
		{
			TraceManager.error('trace.backup.rollbackFailed', 'Backup rollback failed: no safety copy');
			return false;
		}

		try
		{
			var snapshot:BackupData = parseBackupFile(safetyPath);
			applySaveData(snapshot.decodeSaveFields(), true);
			writeScoreFiles(snapshot.decodeScores());
			applyKeyBinds(snapshot.keyboard, snapshot.gamepad);
			flushSave();
			return true;
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.rollbackFailed', 'Backup rollback failed: {}', [e]);
			return false;
		}
		#else
		return false;
		#end
	}

	// ------------------------------------------------------------------ safety copies

	/** Writes the current data to .backups/ before a restore; returns the path. */
	static function writeSafetyCopy():String
	{
		#if sys
		try
		{
			SUtil.mkDirs(AUTO_DIR);
			var path:String = AUTO_DIR + AUTO_PREFIX + timeStamp() + '.SEB';
			writeBackupToFile(path);
			pruneSafetyCopies();
			TraceManager.info('trace.backup.safetyCopy', 'Backup: safety copy written to {}', [path]);
			return path;
		}
		catch (e:Dynamic)
		{
			throw new BackupError('a safety copy of your current data could not be written ('
				+ describeError(e) + '); nothing was changed');
		}
		#else
		return null;
		#end
	}

	#if sys
	static function pruneSafetyCopies():Void
	{
		try
		{
			if (!FileSystem.exists(AUTO_DIR)) return;

			var names:Array<String> = [];
			for (name in FileSystem.readDirectory(AUTO_DIR))
				if (name.indexOf(AUTO_PREFIX) == 0 && name.endsWith('.SEB')) names.push(name);

			if (names.length <= AUTO_KEEP) return;

			names.sort(function(a, b) return a > b ? -1 : (a < b ? 1 : 0));
			for (i in AUTO_KEEP...names.length)
			{
				try FileSystem.deleteFile(AUTO_DIR + names[i])
				catch (e:Dynamic) {}
			}
		}
		catch (e:Dynamic) {}
	}
	#end

	/** Human-readable location of the automatic pre-restore copies (for the UI). */
	public static function autoBackupDirectory():String
		return AUTO_DIR;

	public static function countSafetyCopies():Int
	{
		#if sys
		try
		{
			if (!FileSystem.exists(AUTO_DIR)) return 0;
			var count:Int = 0;
			for (name in FileSystem.readDirectory(AUTO_DIR))
				if (name.indexOf(AUTO_PREFIX) == 0 && name.endsWith('.SEB')) count++;
			return count;
		}
		catch (e:Dynamic) {}
		#end
		return 0;
	}

	// ------------------------------------------------------------------ small helpers

	static function timeStamp():String
	{
		var now:Date = Date.now();
		return now.getFullYear() + pad2(now.getMonth() + 1) + pad2(now.getDate())
			+ '_' + pad2(now.getHours()) + pad2(now.getMinutes()) + pad2(now.getSeconds());
	}

	static function pad2(value:Int):String
		return value < 10 ? '0' + value : Std.string(value);

	static function safeVersion():String
	{
		try return BuildInfo.appVersion() catch (e:Dynamic) return 'unknown';
	}

	static function safeBuild():String
	{
		try return BuildInfo.buildId() catch (e:Dynamic) return 'unknown';
	}

	static function platformName():String
	{
		#if sys
		try return Sys.systemName() catch (e:Dynamic) {}
		#end
		return 'unknown';
	}

	/** Keeps a BackupError's message, turns anything else into a sentence. */
	static function rethrow(e:Dynamic, what:String):Dynamic
	{
		if (Std.isOfType(e, BackupError)) return e;
		return new BackupError(what + ' (' + Std.string(e) + ')');
	}

	static function describeError(e:Dynamic):String
	{
		if (e == null) return 'unknown error';
		if (Std.isOfType(e, BackupError)) return (cast e:BackupError).message;
		return Std.string(e);
	}

	/** Map has no count() on this Haxe version; every caller here only needs the size. */
	static function mapSize<K, V>(map:Map<K, V>):Int
	{
		if (map == null) return 0;
		var count:Int = 0;
		for (_ in map.keys()) count++;
		return count;
	}
}

#if sys
/**
 * Writes the container text straight to a file.
 *
 * The header is reserved by writing HEADER_CHARS spaces first; patchHeader() seeks back
 * and overwrites them once the payload length and checksum are known, then returns to the
 * end. abort() closes the handle and removes the partial file, so a failed export never
 * leaves something that looks like a backup.
 */
class FileBackupSink implements HeaderSink
{
	var path:String;
	var output:FileOutput;

	public function new(path:String)
	{
		this.path = path;
		this.output = File.write(path, false);
	}

	public function beginHeader(length:Int):Void
	{
		var spaces:StringBuf = new StringBuf();
		for (i in 0...length) spaces.addChar(0x20);
		output.writeString(spaces.toString());
	}

	public function write(text:String):Void
	{
		output.writeString(text);
	}

	public function patchHeader(text:String):Void
	{
		output.flush();
		output.seek(0, FileSeek.SeekBegin);
		output.writeString(text);
		output.flush();
		output.seek(0, FileSeek.SeekEnd);
	}

	public function close():Void
	{
		if (output == null) return;
		output.flush();
		output.close();
		output = null;
	}

	public function abort():Void
	{
		try
		{
			if (output != null)
			{
				output.close();
				output = null;
			}
		}
		catch (e:Dynamic) {}

		try
		{
			if (FileSystem.exists(path)) FileSystem.deleteFile(path);
		}
		catch (e:Dynamic) {}
	}
}
#end
