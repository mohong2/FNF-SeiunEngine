package backend;

import haxe.Json;
#if sys
import sys.io.File;
import sys.FileSystem;
#end
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import mohong.TraceManager;
import SUtil;

/**
 * Backup utility for FNF-SeiunEngine game data.
 * Provides encryption, packaging, and extraction of backup files (.SEB).
 */
class BackupUtil
{
	/** Magic number for identifying .SEB backup files: "SEB1" */
	private static var MAGIC:Bytes = Bytes.ofString("SEB1");

	/** XOR key for basic obfuscation - not military-grade, but prevents casual tampering */
	private static var XOR_KEY:Array<Int> = [
		0x9A, 0x3C, 0xF7, 0x2B, 0x6D, 0xE4, 0x15, 0x88,
		0x4E, 0x71, 0xB2, 0x0F, 0xC9, 0x56, 0xAD, 0x38,
		0x6F, 0xD2, 0x1B, 0xE7, 0x84, 0x39, 0xCA, 0x5F,
		0x20, 0x94, 0x6B, 0xD7, 0x41, 0xFE, 0x03, 0xBC
	];

	/**
	 * Package all game data into an encrypted backup structure.
	 * Returns a data object ready for encryptAndPack.
	 */
	public static function collectGameData():Dynamic
	{
		var backup:Dynamic = {};

		// 1. Save version info
		backup.version = 1;
		backup.timestamp = Date.now().toString();
		backup.engine = "FNF-SeiunEngine";

		// 2. Read Highscore data (scores, ratings, stats)
		backup.highscoreData = readHighscoreFromSave();

		// 3. Read Allscore entries from binary score files (detailed history + replays)
		backup.allscoreData = readAllscoreFiles();

		// 4. Read ClientPrefs settings + keybinds
		backup.clientPrefs = captureClientPrefs();

		// 5. Capture week completion data
		try
		{
			backup.weekCompleted = flixel.FlxG.save.data.weekCompleted;
		}
		catch (e:Dynamic) {}

		return backup;
	}

	/**
	 * Encrypt and pack data into .SEB format bytes.
	 */
	public static function encryptAndPack(data:Dynamic):Bytes
	{
		var json:String = Json.stringify(data, "\t");
		var inputBytes:Bytes = Bytes.ofString(json, UTF8);
		var output:BytesOutput = new BytesOutput();
		output.bigEndian = true;

		// Write magic header
		output.writeBytes(MAGIC, 0, MAGIC.length);

		// Write version byte
		output.writeByte(1);

		// Write XOR key index (for future key rotation, currently always 0)
		output.writeByte(0);

		// Write original data length (for verification)
		output.writeInt32(inputBytes.length);

		// XOR-encrypt the data
		var encrypted:Bytes = xorEncryptDecrypt(inputBytes, 0);

		// Write encrypted data
		output.writeBytes(encrypted, 0, encrypted.length);

		return output.getBytes();
	}

	/**
	 * Decrypt and unpack .SEB format bytes.
	 * Returns the parsed data object, or null if invalid.
	 */
	public static function decryptAndUnpack(bytes:Bytes):Dynamic
	{
		try
		{
			var totalLen:Int = bytes.length;
			var input:BytesInput = new BytesInput(bytes);
			input.bigEndian = true;

			// Check magic header
			var magic:Bytes = input.read(MAGIC.length);
			if (magic.getString(0, MAGIC.length, UTF8) != MAGIC.getString(0, MAGIC.length, UTF8))
			{
				TraceManager.error('trace.backup.invalidMagic', 'BackupUtil: Invalid magic number - not a valid .SEB file');
				return null;
			}

			// Read version
			var version:Int = input.readByte();
			if (version != 1)
			{
				TraceManager.error('trace.backup.unknownVersion', 'BackupUtil: Unknown backup version: {}', [version]);
				return null;
			}

			// Read key index (reserved)
			var keyIndex:Int = input.readByte();

			// Read original data length
			var originalLength:Int = input.readInt32();

			// Read encrypted data (remaining bytes after header)
			var headerSize:Int = MAGIC.length + 1 + 1 + 4; // magic(4) + version(1) + keyIndex(1) + dataLen(4)
			var encrypted:Bytes = bytes.sub(headerSize, totalLen - headerSize);

			// Decrypt
			var decrypted:Bytes = xorEncryptDecrypt(encrypted, keyIndex);

			// Verify length
			if (decrypted.length < originalLength)
			{
				TraceManager.error('trace.backup.dataLengthMismatch', 'BackupUtil: Data length mismatch - corrupted backup?');
				return null;
			}

			// Truncate to original length (in case of padding)
			if (decrypted.length > originalLength)
				decrypted = decrypted.sub(0, originalLength);

			var json:String = decrypted.getString(0, decrypted.length, UTF8);
			return Json.parse(json);
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.decryptFailed', 'BackupUtil: Failed to decrypt backup: {}', [e]);
			return null;
		}
	}

	/**
	 * Restore game data from a decrypted backup object.
	 * Returns true on success.
	 */
	public static function restoreFromBackup(backup:Dynamic):Bool
	{
		try
		{
			if (backup == null || backup.version == null)
			{
				TraceManager.error('trace.backup.invalidData', 'BackupUtil: Invalid backup data');
				return false;
			}

			// 1. Restore Highscore maps
			if (backup.highscoreData != null)
			{
				restoreHighscore(backup.highscoreData);
			}

			// 2. Restore Allscore entries
			if (backup.allscoreData != null)
			{
				restoreAllscore(backup.allscoreData);
			}

			// 3. Restore ClientPrefs
			if (backup.clientPrefs != null)
			{
				restoreClientPrefs(backup.clientPrefs);
			}

			// 4. Restore week completion data
			if (backup.weekCompleted != null)
			{
				try
				{
					flixel.FlxG.save.data.weekCompleted = backup.weekCompleted;
				}
				catch (e:Dynamic) {}
			}

			// 5. Persist controls_v2 save (keybinds)
			try
			{
				var controlsSave:flixel.util.FlxSave = new flixel.util.FlxSave();
				controlsSave.bind('controls_v2', 'ninjamuffin99');
				controlsSave.data.customControls = ClientPrefs.keyBinds;
				controlsSave.flush();
				controlsSave.destroy();
			}
			catch (e:Dynamic) {}

			// Flush main save
			try { flixel.FlxG.save.flush(); } catch (e:Dynamic) {}

			TraceManager.info('trace.backup.restoreSuccess', 'BackupUtil: Backup restored successfully');
			return true;
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.restoreFailed', 'BackupUtil: Failed to restore backup: {}', [e]);
			return false;
		}
	}

	// ==================== Private Helpers ====================

	private static function xorEncryptDecrypt(data:Bytes, keyIndex:Int):Bytes
	{
		var key = XOR_KEY;
		var result:Bytes = Bytes.alloc(data.length);
		for (i in 0...data.length)
		{
			var keyByte:Int = key[(i + keyIndex) % key.length];
			result.set(i, data.get(i) ^ keyByte);
		}
		return result;
	}



	private static function readHighscoreFromSave():Dynamic
	{
		// Highscore data is stored in FlxG.save.data fields
		// We capture it by reading the in-memory maps
		var data:Dynamic = {};
		try
		{
		// Int64 maps cannot be JSON.stringify'd as numbers; store exact decimal strings.
			function exportIntMap(source:Map<String, haxe.Int64>):Map<String, String>
			{
			var out:Map<String, String> = new Map();
			for (key => value in source)
			out.set(key, haxe.Int64.toStr(value));
			return out;
		}
			data.songScores = exportIntMap(Highscore.songScores);
			data.songRating = Highscore.songRating;
			data.weekScores = exportIntMap(Highscore.weekScores);
			data.songSicks = exportIntMap(Highscore.songSicks);
			data.songGoods = exportIntMap(Highscore.songGoods);
			data.songBads = exportIntMap(Highscore.songBads);
			data.songShits = exportIntMap(Highscore.songShits);
			data.songMisses = exportIntMap(Highscore.songMisses);
			data.songMaxCombo = exportIntMap(Highscore.songMaxCombo);
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.readHighscoreFailed', 'BackupUtil: Could not read Highscore data: {}', [e]);
		}
		return data;
	}

	private static function readAllscoreFiles():Array<Dynamic>
	{
		var entries:Array<Dynamic> = [];
		try
		{
			#if sys
			// Read unified encrypted score files
			var scoreDir:String = "./.scores/";
			if (FileSystem.exists(scoreDir))
			{
				// 递归收集 (兼容 歌曲/难度/ 子目录布局)
				var files:Array<String> = [];
				collectScoreFiles(scoreDir, files);
				for (filePath in files)
				{
					try
					{
						var bytes:Bytes = File.getBytes(filePath);
						entries.push({
							type: "score",
							fileName: filePath.substring(scoreDir.length), // 相对路径: 歌曲/难度/文件.json
							data: base64Encode(bytes)  // 加密的二进制, base64 存储
						});
					}
					catch (e:Dynamic)
					{
						TraceManager.error('trace.backup.readScoreFileFailed', 'BackupUtil: Failed to read score file {}: {}', [filePath, e]);
					}
				}
			}
			#end
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.readAllscoreDirsFailed', 'BackupUtil: Could not read Allscore directories: {}', [e]);
		}
		return entries;
	}

	/** 递归收集 .scores 下所有 .json 文件路径 */
	private static function collectScoreFiles(dir:String, into:Array<String>):Void
	{
		#if sys
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return;
		var items:Array<String> = FileSystem.readDirectory(dir);
		for (item in items)
		{
			if (item == '.' || item == '..') continue;
			var path:String = dir + item;
			try
			{
				if (FileSystem.isDirectory(path))
					collectScoreFiles(path + '/', into);
				else if (item.endsWith('.json'))
					into.push(path);
			}
			catch (e:Dynamic) {}
		}
		#end
	}

	private static function captureClientPrefs():Dynamic
	{
		var data:Dynamic = {};
		try
		{
			// Field names to skip (complex types that don't serialize well)
			var skipFields:Array<String> = [
				"arrowRGB", "arrowRGBPixel", "arrowHSV",
				"modSettings", "gameplaySettings",
				"comboOffset", "keyBinds"
			];

			// Capture all public fields from ClientPrefs.data
			var prefs = ClientPrefs.data;
			for (field in Reflect.fields(prefs))
			{
				if (skipFields.indexOf(field) >= 0) continue;
				var val = Reflect.field(prefs, field);
				if (val != null)
				{
					Reflect.setField(data, field, val);
				}
			}

			// Capture gameplaySettings manually (Map<String, Dynamic>)
			var gpSettings = ClientPrefs.data.gameplaySettings;
			if (gpSettings != null)
			{
				var gp:Dynamic = {};
				for (key in gpSettings.keys())
				{
					gpSettings.get(key); // ensure accessible
					Reflect.setField(gp, key, gpSettings.get(key));
				}
				data.gameplaySettings = gp;
			}

			// Capture keybinds
			data.keyBinds = captureKeyBinds();
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.captureClientPrefsFailed', 'BackupUtil: Could not capture ClientPrefs: {}', [e]);
		}
		return data;
	}

	private static function captureKeyBinds():Dynamic
	{
		var binds:Dynamic = {};
		try
		{
			for (key in ClientPrefs.keyBinds.keys())
			{
				var arr = ClientPrefs.keyBinds.get(key);
				if (arr != null)
				{
					Reflect.setField(binds, key, arr);
				}
			}
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.captureKeybindsFailed', 'BackupUtil: Could not capture keybinds: {}', [e]);
		}
		return binds;
	}

	private static function restoreFlxSave(saveContent:Dynamic):Void
	{
		// Data is restored via Highscore and ClientPrefs individually.
		// FlxG.save is updated automatically by those restore functions.
	}

	private static function restoreHighscore(data:Dynamic):Void
	{
		try
		{
			// Restore each map: backup stores them as anonymous objects (from JSON),
			// we convert back to proper Map by iterating Reflect.fields.
			function restoreIntMap(fieldName:String, target:Map<String, haxe.Int64>)
			{
				if (!Reflect.hasField(data, fieldName)) return;
				var src:Dynamic = Reflect.field(data, fieldName);
				if (src == null) return;
				target.clear();
				// The live FlxSave payload must stay string-encoded: haxe.Serializer does not
				// round-trip Int64 (see Highscore.saveIntMap). Writing the Int64 map back here
				// made the next launch's save contain boxed cpp.Int64 values again.
				var stored:Map<String, String> = new Map();
				for (key in Reflect.fields(src))
				{
					var value:haxe.Int64 = Int64Util.fromDynamic(Reflect.field(src, key));
					target.set(key, value);
					stored.set(key, Int64Util.toSaveString(value));
				}
				Reflect.setField(flixel.FlxG.save.data, fieldName, stored);
			}
			function restoreFloatMap(fieldName:String, target:Map<String, Float>)
			{
				if (!Reflect.hasField(data, fieldName)) return;
				var src:Dynamic = Reflect.field(data, fieldName);
				if (src == null) return;
				target.clear();
				for (key in Reflect.fields(src))
					target.set(key, Reflect.field(src, key) * 1.0);
				Reflect.setField(flixel.FlxG.save.data, fieldName, target);
			}

			restoreIntMap("songScores", Highscore.songScores);
			restoreFloatMap("songRating", Highscore.songRating);
			restoreIntMap("weekScores", Highscore.weekScores);
			restoreIntMap("songSicks", Highscore.songSicks);
			restoreIntMap("songGoods", Highscore.songGoods);
			restoreIntMap("songBads", Highscore.songBads);
			restoreIntMap("songShits", Highscore.songShits);
			restoreIntMap("songMisses", Highscore.songMisses);
			restoreIntMap("songMaxCombo", Highscore.songMaxCombo);

			flixel.FlxG.save.flush();
			TraceManager.info('trace.backup.highscoreRestoreSuccess', 'BackupUtil: Highscore data restored successfully');
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.highscoreRestoreFailed', 'BackupUtil: Failed to restore Highscore: {}', [e]);
		}
	}

	private static function restoreAllscore(entries:Array<Dynamic>):Void
	{
		try
		{
			#if sys
			var scoreDir:String = "./.scores/";
			if (!FileSystem.exists(scoreDir))
				FileSystem.createDirectory(scoreDir);

			for (entry in entries)
			{
				try
				{
					var fileName:String = entry.fileName;
					if (fileName == null || entry.data == null) continue;

					var bytes:Bytes = base64Decode(entry.data);
					if (bytes != null)
					{
						// 兼容新格式相对路径 (歌曲/难度/文件.json) 与旧格式扁平文件名
						var slash:Int = fileName.lastIndexOf('/');
						var dirPart:String = slash > -1 ? fileName.substr(0, slash + 1) : '';
						SUtil.mkDirs(scoreDir + dirPart);
						File.saveBytes(scoreDir + fileName, bytes);
					}
				}
				catch (e:Dynamic)
				{
					TraceManager.error('trace.backup.restoreEntryFailed', 'BackupUtil: Failed to restore entry: {}', [e]);
				}
			}
			#end

			// Reload Allscore data
			Allscore.load();
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.allscoreRestoreFailed', 'BackupUtil: Failed to restore Allscore: {}', [e]);
		}
	}

	private static function restoreClientPrefs(data:Dynamic):Void
	{
		try
		{
			var prefs = ClientPrefs.data;

			// Fields we skip (complex types stored separately)
			var skipFields:Array<String> = [
				"arrowRGB", "arrowRGBPixel", "arrowHSV",
				"modSettings", "gameplaySettings",
				"comboOffset", "keyBinds"
			];

			// Restore simple fields: iterate over ALL known fields in ClientPrefs.data,
			// look each one up in the backup data.
			for (field in Reflect.fields(prefs))
			{
				if (skipFields.indexOf(field) >= 0) continue;
				if (!Reflect.hasField(data, field)) continue;
				var val = Reflect.field(data, field);
				if (val == null) continue;
				try
				{
					Reflect.setField(prefs, field, val);
				}
				catch (e:Dynamic)
				{
					TraceManager.error('trace.backup.setFieldFailed', 'BackupUtil: Failed to set field {}: {}', [field, e]);
				}
			}

			// Restore gameplaySettings (Map<String, Dynamic>)
			if (Reflect.hasField(data, "gameplaySettings"))
			{
				var gpData:Dynamic = Reflect.field(data, "gameplaySettings");
				if (gpData != null)
				{
					var gpMap = prefs.gameplaySettings;
					for (field in Reflect.fields(gpData))
					{
						try { gpMap.set(field, Reflect.field(gpData, field)); }
						catch (e:Dynamic) {}
					}
				}
			}

			// Restore keybinds (Map<String, Array<FlxKey>>)
			if (Reflect.hasField(data, "keyBinds"))
			{
				var bindsData:Dynamic = Reflect.field(data, "keyBinds");
				if (bindsData != null)
				{
					for (field in Reflect.fields(bindsData))
					{
						if (ClientPrefs.keyBinds.exists(field))
						{
							try { ClientPrefs.keyBinds.set(field, Reflect.field(bindsData, field)); }
							catch (e:Dynamic) {}
						}
					}
				}
			}

			// Persist to disk
			ClientPrefs.saveSettings();
			TraceManager.info('trace.backup.clientPrefsRestoreSuccess', 'BackupUtil: ClientPrefs restored successfully');
		}
	 catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.clientPrefsRestoreFailed', 'BackupUtil: Failed to restore ClientPrefs: {}', [e]);
		}
	}



	// ==================== Simple Base64 Implementation ====================

	private static var BASE64_CHARS:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	private static function base64Encode(bytes:Bytes):String
	{
		var output = new StringBuf();
		var i:Int = 0;
		var len:Int = bytes.length;

		while (i < len)
		{
			var b1:Int = bytes.get(i++);
			var b2:Int = (i < len) ? bytes.get(i++) : -1;
			var b3:Int = (i < len) ? bytes.get(i++) : -1;

			output.add(BASE64_CHARS.charAt((b1 >> 2) & 0x3F));
			output.add(BASE64_CHARS.charAt(((b1 << 4) & 0x30) | ((b2 >> 4) & 0x0F)));

			if (b2 == -1)
			{
				output.add("==");
			}
			else
			{
				output.add(BASE64_CHARS.charAt(((b2 << 2) & 0x3C) | ((b3 >> 6) & 0x03)));
				if (b3 == -1)
					output.add("=");
				else
					output.add(BASE64_CHARS.charAt(b3 & 0x3F));
			}
		}

		return output.toString();
	}

	private static function base64Decode(str:String):Bytes
	{
		try
		{
			// Remove whitespace
			str = StringTools.replace(str, "\n", "");
			str = StringTools.replace(str, "\r", "");
			str = StringTools.replace(str, " ", "");

			var output = new BytesOutput();
			var i:Int = 0;
			var len:Int = str.length;

			while (i < len && str.charAt(i) != '=')
			{
				var c1:Int = BASE64_CHARS.indexOf(str.charAt(i++));
				var c2:Int = (i < len && str.charAt(i) != '=') ? BASE64_CHARS.indexOf(str.charAt(i++)) : 0;
				var c3:Int = (i < len && str.charAt(i) != '=') ? BASE64_CHARS.indexOf(str.charAt(i++)) : 0;
				var c4:Int = (i < len && str.charAt(i) != '=') ? BASE64_CHARS.indexOf(str.charAt(i++)) : 0;

				if (c1 < 0 || c2 < 0) break;

				output.writeByte((c1 << 2) | ((c2 >> 4) & 0x03));
				if (c3 >= 0)
					output.writeByte(((c2 << 4) & 0xF0) | ((c3 >> 2) & 0x0F));
				if (c4 >= 0)
					output.writeByte(((c3 << 6) & 0xC0) | c4);
			}

			return output.getBytes();
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.backup.base64DecodeFailed', 'BackupUtil: Base64 decode failed: {}', [e]);
			return null;
		}
	}
}
