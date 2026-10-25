package;

import haxe.Json;
import haxe.io.Bytes;
#if sys
import sys.io.File;
import sys.FileSystem;
#end
import flixel.FlxG;
import flixel.util.FlxSave;
import mohong.TraceManager;
import SUtil;

using StringTools;

class Allscore
{
	public static var entries:Map<String, Array<ScoreEntry>> = new Map();

	private static inline var SCORE_DIR:String = "./.scores/";
	/** 旧扁平目录是否已完成迁移 (一次会话只做一次) */
	private static var legacyMigrated:Bool = false;

	/** 难度名转目录安全名 (小写、空格转-, 与歌曲名同一套规则) */
	private static function difficultyFolder(diffName:String):String
	{
		if (diffName == null || diffName.length == 0)
			return 'unknown';
		return Paths.formatToSongPath(diffName);
	}

	/** 根据难度索引取当前会话的难度名 (模组自定义难度同样生效) */
	private static function difficultyNameFor(difficulty:Int):String
	{
		if (CoolUtil.difficulties == null || CoolUtil.difficulties.length == 0)
			return CoolUtil.defaultDifficulty;
		if (difficulty < 0 || difficulty >= CoolUtil.difficulties.length)
			return CoolUtil.defaultDifficulty;
		return CoolUtil.difficulties[difficulty];
	}

	/** 歌曲/难度名对应的子目录 (如 ./.scores/songname/normal/) */
	private static function entryDir(songName:String, diffName:String):String
	{
		return SCORE_DIR + Paths.formatToSongPath(songName) + '/' + difficultyFolder(diffName) + '/';
	}

	/** 递归收集目录下所有 .json 文件路径 */
	private static function collectJsonFiles(dir:String, into:Array<String>):Void
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
					collectJsonFiles(path + '/', into);
				else if (item.endsWith('.json'))
					into.push(path);
			}
			catch (e:Dynamic) {}
		}
		#end
	}

	/**
	 * 把旧扁平目录 (./.scores/*.json) 的成绩/回放迁移到
	 * ./.scores/<歌曲>/<难度>/ 子目录, 迁移成功才删除旧文件。
	 */
	private static function migrateLegacyFiles():Void
	{
		if (legacyMigrated) return;
		legacyMigrated = true;

		#if sys
		if (!FileSystem.exists(SCORE_DIR)) return;
		var items:Array<String> = FileSystem.readDirectory(SCORE_DIR);
		for (item in items)
		{
			if (!item.endsWith('.json')) continue;
			var src:String = SCORE_DIR + item;
			try
			{
				var entry:ScoreEntry = readEntryFromJson(src);
				if (entry == null || entry.songName == null) continue;

				var dir:String = entryDir(entry.songName, difficultyNameFor(entry.difficulty));
				SUtil.mkDirs(dir);
				var dest:String = dir + item;
				if (FileSystem.exists(dest)) continue; // 目标已存在则跳过, 不覆盖

				writeEntryToJson(entry, dest);
				FileSystem.deleteFile(src); // 新文件写成功后才删旧文件
			}
			catch (e:Dynamic)
			{
				CoolUtil.traceMsg('trace.errScoreMigrate', 'Failed to migrate score file {}: {}', [src, e]);
			}
		}
		#end
	}

	public static function load():Void
	{
		entries = new Map();

		#if sys
		if (!FileSystem.exists(SCORE_DIR))
		{
			FileSystem.createDirectory(SCORE_DIR);
		}
		else
		{
			migrateLegacyFiles();
			var files:Array<String> = [];
			collectJsonFiles(SCORE_DIR, files);
			for (file in files)
			{
				var filePath:String = file;
				try
				{
					var entry = readEntryFromJson(filePath);
					if (entry != null)
					{
						var key = Highscore.formatSong(entry.songName, entry.difficulty);
						if (!entries.exists(key)) entries.set(key, []);
						entries.get(key).push(entry);
					}
				}
				catch (e:Dynamic)
				{
					CoolUtil.traceMsg('trace.errScoreRead', 'Error reading score file {}: {}', [filePath, e]);
				}
			}
		}
		#end

		for (key => list in entries)
		{
			list.sort((a, b) -> Reflect.compare(b.date, a.date));
		}
	}

	public static function addEntry(songName:String, difficulty:Int,
		rating:Float = -1, ratingFC:String = "", ratingName:String = "", score:haxe.Int64 = 0,
		marvelouses:haxe.Int64 = -1, sicks:haxe.Int64 = -1, goods:haxe.Int64 = -1, bads:haxe.Int64 = -1, shits:haxe.Int64 = -1,
		misses:haxe.Int64 = -1, maxCombo:haxe.Int64 = -1,
		replayData:Array<Dynamic> = null,
		details:Array<Dynamic> = null,
		?date:String,
		?songSpeed:Float = 1, ?playbackRate:Float = 1, ?songSpeedType:String = "multiplicative"):Void
	{
		#if sys
		details = normalizeDetails(details);
		var key:String = Highscore.formatSong(songName, difficulty);

		var safeName = Paths.formatToSongPath(songName);
		var timestamp = Date.now().getTime();
		var random = Std.random(10000);

		// 统一文件名：歌曲_难度_时间戳_随机数.json
		var fileName = '${safeName}_${difficulty}_${timestamp}_${random}.json';
		// 按 歌曲/难度名 子目录存放 (模组自定义难度用名字归档, 避免数字索引错位)
		var diffName:String = difficultyNameFor(difficulty);
		var dir:String = entryDir(songName, diffName);
		SUtil.mkDirs(dir);
		var filePath = dir + fileName;

		var entry:ScoreEntry = {
			songName: songName,
			difficulty: difficulty,
			difficultyName: diffName,
			folder: Paths.currentModDirectory != null ? Paths.currentModDirectory : '',
			date: date != null ? date : Date.now().toString(),
			ratingPercent: rating,
			ratingFC: ratingFC,
			ratingName: ratingName,
			score: score,
			marvelouses: marvelouses,
			sicks: sicks,
			goods: goods,
			bads: bads,
			shits: shits,
			misses: misses,
			maxCombo: maxCombo,
			replayData: replayData,
			details: details,
			songSpeed: songSpeed,
			playbackRate: playbackRate,
			songSpeedType: songSpeedType,
			filePath: filePath
		};

		// 单个 JSON 文件保存所有数据（分数 + 详情 + replay）
		writeEntryToJson(entry, filePath);

		if (!entries.exists(key)) entries.set(key, []);
		var list:Array<ScoreEntry> = entries.get(key);
		list.unshift(entry);

		CoolUtil.traceMsg('trace.addedEntry', 'Added entry for {} [{}] -> {}', [songName, difficulty, filePath]);
		#end
	}

	public static function getHistory(songName:String, difficulty:Int):Array<ScoreEntry>
	{
		// 只读取该歌曲/难度子目录, 不再全量扫描所有成绩文件
		var list:Array<ScoreEntry> = [];
		#if sys
		migrateLegacyFiles();
		if (!FileSystem.exists(SCORE_DIR))
			FileSystem.createDirectory(SCORE_DIR);

		var diffName:String = difficultyNameFor(difficulty);
		var dir:String = entryDir(songName, diffName);
		if (FileSystem.exists(dir) && FileSystem.isDirectory(dir))
		{
			var files:Array<String> = FileSystem.readDirectory(dir);
			for (file in files)
			{
				if (!file.endsWith('.json')) continue;
				try
				{
					var entry:ScoreEntry = readEntryFromJson(dir + file);
					if (entry != null) list.push(entry);
				}
				catch (e:Dynamic)
				{
					CoolUtil.traceMsg('trace.errScoreRead', 'Error reading score file {}{}: {}', [dir, file, e]);
				}
			}
		}
		// 兼容上一版本的数字难度目录 (./.scores/<song>/2/): 名字目录为空时回退读取
		if (list.length == 0)
		{
			var legacyDir:String = SCORE_DIR + Paths.formatToSongPath(songName) + '/' + difficulty + '/';
			if (FileSystem.exists(legacyDir) && FileSystem.isDirectory(legacyDir))
			{
				var files:Array<String> = FileSystem.readDirectory(legacyDir);
				for (file in files)
				{
					if (!file.endsWith('.json')) continue;
					try
					{
						var entry:ScoreEntry = readEntryFromJson(legacyDir + file);
						if (entry != null) list.push(entry);
					}
					catch (e:Dynamic)
					{
						CoolUtil.traceMsg('trace.errScoreRead', 'Error reading score file {}{}: {}', [legacyDir, file, e]);
					}
				}
				list.sort((a, b) -> Reflect.compare(b.date, a.date));
			}
		}
		list.sort((a, b) -> Reflect.compare(b.date, a.date));
		#end
		return list;
	}

	public static function deleteEntry(songName:String, difficulty:Int, index:Int):Void
	{
		#if sys
		var key:String = Highscore.formatSong(songName, difficulty);
		if (!entries.exists(key)) return;

		var list = entries.get(key);
		if (index < 0 || index >= list.length) return;

		var entry = list[index];

		// 删除唯一的 JSON 文件
		if (entry.filePath != null && entry.filePath != "" && FileSystem.exists(entry.filePath))
		{
			try
			{
				FileSystem.deleteFile(entry.filePath);
				CoolUtil.traceMsg('trace.deletedScore', 'Deleted score file: {}', [entry.filePath]);
			}
			catch (e:Dynamic)
			{
				CoolUtil.traceMsg('trace.failDeleteScore', 'Failed to delete file: {}', [e]);
			}
		}

		list.splice(index, 1);
		if (list.length == 0) entries.remove(key);
		#end
	}

	// ---- 简单 XOR 加密(非密码学安全,防随手查看) ----
	// 使用 Bytes 读写避免 null byte 截断问题
	private static inline var XOR_KEY:Int = 0x7A;

	private static function xorBytes(input:Bytes):Bytes
	{
		var out = Bytes.alloc(input.length);
		for (i in 0...input.length)
		{
			out.set(i, input.get(i) ^ ((XOR_KEY + i) & 0xFF));
		}
		return out;
	}

	private static function writeEntryToJson(entry:ScoreEntry, filePath:String):Void
	{
		#if sys
		if (!FileSystem.exists(SCORE_DIR))
			FileSystem.createDirectory(SCORE_DIR);

		var jsonObj:Dynamic = {
			songName: entry.songName,
			difficulty: entry.difficulty,
			difficultyName: entry.difficultyName,
			folder: entry.folder,
			date: entry.date,
			score: Int64Util.toSaveString(entry.score),
			ratingPercent: entry.ratingPercent,
			ratingName: entry.ratingName,
			ratingFC: entry.ratingFC,
			marvelouses: entry.marvelouses != null ? Int64Util.toSaveString(entry.marvelouses) : null,
			sicks: Int64Util.toSaveString(entry.sicks),
			goods: Int64Util.toSaveString(entry.goods),
			bads: Int64Util.toSaveString(entry.bads),
			shits: Int64Util.toSaveString(entry.shits),
			misses: Int64Util.toSaveString(entry.misses),
			maxCombo: Int64Util.toSaveString(entry.maxCombo),
			songSpeed: entry.songSpeed,
			playbackRate: entry.playbackRate,
			songSpeedType: entry.songSpeedType,
			// Int64 must not reach haxe.Json: cpp.Int64 is a native class, JsonPrinter reflects
			// it as an object with no fields and throws "Null Object Reference". details still
			// carries the Int64 gameplay counters (score/hits/misses/maxCombo), so copy them as
			// numbers - the exact shape older score files already have (see Int64Util.jsonSafe).
			details: Int64Util.jsonSafeArray(entry.details),
			replayData: entry.replayData
		};

		var json:String;
		try
		{
			json = Json.stringify(jsonObj, "\t");
		}
		catch (e:Dynamic)
		{
			// A value haxe.Json cannot reflect (cpp.Int64 and other native classes) used to
			// abort the whole end-of-song path before the file was written. Details are already
			// sanitised above, so this is the slow path for a future field: retry with a fully
			// sanitised copy instead of losing the run. If it still fails, the exception now
			// surfaces through the guarded update()/CRASH_HANDLER instead of hxcpp's MessageBox.
			TraceManager.error('trace.errScoreWrite', 'Score JSON failed, retrying sanitised: {}', [e]);
			json = Json.stringify(Int64Util.jsonSafe(jsonObj), "\t");
		}
		var srcBytes:Bytes = Bytes.ofString(json, UTF8);
		var encBytes:Bytes = xorBytes(srcBytes);
		File.saveBytes(filePath, encBytes);
		#end
	}

	/**
	 * 归一化成绩详情数组。
	 * osu! 尾判被注释掉后曾产生过 30 项的 details（少了索引 27 的占位），
	 * 导致 ratingOffset/guitarHeroSustains/marvelousWindow 整体前移一位，
	 * 回放还原时会把 marvelousWindow 误读成 “Sustains as One Note” 开启。
	 * 这里统一在索引 27 补 null 占位，恢复 27-30 的原始布局。
	 */
	private static function normalizeDetails(details:Array<Dynamic>):Array<Dynamic>
	{
		if (details != null && details.length == 30)
			details.insert(27, null);
		return details;
	}

	private static function readEntryFromJson(filePath:String):ScoreEntry
	{
		#if sys
		var encBytes:Bytes = File.getBytes(filePath);
		var content:String = null;

		// 先按 XOR 加密格式解; 失败再按明文 JSON 兜底 (兼容其他工具/旧版本导出的成绩文件)
		try
		{
			var decBytes:Bytes = xorBytes(encBytes);
			content = decBytes.getString(0, decBytes.length, UTF8);
		}
		catch (e:Dynamic) { content = null; }

		var data:Dynamic = null;
		if (content != null)
		{
			if (content.length > 0 && content.charCodeAt(0) == 0xFEFF) content = content.substr(1);
			try { data = Json.parse(content); } catch (e:Dynamic) { data = null; }
		}
		if (data == null)
		{
			// 明文兜底 (去 BOM)
			try
			{
				content = encBytes.getString(0, encBytes.length, UTF8);
				if (content != null && content.length > 0 && content.charCodeAt(0) == 0xFEFF) content = content.substr(1);
				data = Json.parse(content);
			}
			catch (e:Dynamic) { data = null; }
		}
		if (data == null) return null;

		// 字段容错: 类型/缺失一律兜底, 单个坏文件不阻塞整个成绩列表
		var difficulty:Int = 1; // Normal
		if (data.difficulty != null)
		{
			var d:Float = Std.parseFloat(Std.string(data.difficulty));
			if (!Math.isNaN(d)) difficulty = Std.int(d);
		}
		var ratingPercent:Float = 0;
		if (data.ratingPercent != null)
		{
			ratingPercent = Std.parseFloat(Std.string(data.ratingPercent));
			if (Math.isNaN(ratingPercent)) ratingPercent = 0;
		}
		var songSpeed:Float = 1;
		if (data.songSpeed != null)
		{
			songSpeed = Std.parseFloat(Std.string(data.songSpeed));
			if (Math.isNaN(songSpeed) || songSpeed <= 0) songSpeed = 1;
		}
		var playbackRate:Float = 1;
		if (data.playbackRate != null)
		{
			playbackRate = Std.parseFloat(Std.string(data.playbackRate));
			if (Math.isNaN(playbackRate) || playbackRate <= 0) playbackRate = 1;
		}

		var details:Array<Dynamic> = null;
		if (Std.isOfType(data.details, Array))
			details = cast data.details;
		details = normalizeDetails(details);

		var entry:ScoreEntry = {
			songName: data.songName != null ? Std.string(data.songName) : null,
			difficulty: difficulty,
			difficultyName: data.difficultyName != null ? Std.string(data.difficultyName) : null,
			folder: data.folder != null ? Std.string(data.folder) : null,
			date: data.date != null ? Std.string(data.date) : '',
			ratingPercent: ratingPercent,
			ratingFC: data.ratingFC != null ? Std.string(data.ratingFC) : '',
			ratingName: data.ratingName != null ? Std.string(data.ratingName) : '',
			score: Int64Util.fromJson(data.score),
			marvelouses: data.marvelouses != null ? Int64Util.fromJson(data.marvelouses) : null,
			sicks: Int64Util.fromJson(data.sicks),
			goods: Int64Util.fromJson(data.goods),
			bads: Int64Util.fromJson(data.bads),
			shits: Int64Util.fromJson(data.shits),
			misses: Int64Util.fromJson(data.misses),
			maxCombo: Int64Util.fromJson(data.maxCombo),
			replayData: data.replayData,
			details: details,
			songSpeed: songSpeed,
			playbackRate: playbackRate,
			songSpeedType: data.songSpeedType != null ? Std.string(data.songSpeedType) : 'multiplicative',
			filePath: filePath
		};
		// 没有歌名无法路由/展示, 直接跳过该文件 (不阻塞列表)
		if (entry.songName == null || entry.songName.length == 0) return null;

		return entry;
		#else
		return null;
		#end
	}

	/**
	 * 检查 ScoreEntry 是否包含 replay 数据。
	 * 最大限度的宽松: 只要 replayData 非空 (数组有元素, 或对象包装) 就算有回放,
	 * 完全不校验帧结构 —— 拿到数据就允许进回放, 帧内容统一由 Replay.normalizeFrames 兜底。
	 */
	public static function hasReplayData(entry:ScoreEntry):Bool
	{
		if (entry.replayData == null) return false;
		if (Std.isOfType(entry.replayData, Array))
			return ((cast entry.replayData:Array<Dynamic>).length > 0);
		return (Type.typeof(entry.replayData) == TObject);
	}
}

/** 统一 ScoreEntry typedef，移除废弃字段，新增 filePath */
typedef ScoreEntry = {
	var songName:String;
	var difficulty:Int;
	@:optional var difficultyName:String;
	@:optional var folder:String;
	var date:String;
	var score:haxe.Int64;
	var ratingPercent:Float;
	var ratingName:String;
	var ratingFC:String;
	@:optional var marvelouses:haxe.Int64;
	var sicks:haxe.Int64;
	var goods:haxe.Int64;
	var bads:haxe.Int64;
	var shits:haxe.Int64;
	var misses:haxe.Int64;
	var maxCombo:haxe.Int64;
	@:optional var replayData:Array<Dynamic>;
	@:optional var details:Array<Dynamic>;
	var songSpeed:Float;
	var playbackRate:Float;
	var songSpeedType:String;
	@:optional var filePath:String;
}
