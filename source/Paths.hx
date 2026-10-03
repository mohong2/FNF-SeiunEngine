package;

import animateatlas.AtlasFrameMaker;
 
import flixel.graphics.frames.FlxFrame.FlxFrameAngle;
import openfl.geom.Rectangle;
import flixel.math.FlxRect;
import haxe.xml.Access;
 
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.FlxG;
import openfl.utils.AssetType;
import openfl.utils.Assets as OpenFlAssets;
import lime.utils.Assets;
 
#if sys
import sys.io.File;
import sys.FileSystem;
#end
import flixel.graphics.FlxGraphic;
import openfl.display.BitmapData;
import haxe.Json;

import flash.media.Sound;

using StringTools;
import mohong.TraceManager;

class Paths
{
	inline public static var SOUND_EXT = #if web "mp3" #else "ogg" #end;
	inline public static var VIDEO_EXT = "mp4";

	#if MODS_ALLOWED
	public static var ignoreModFolders:Array<String> = [
		'characters',
		'custom_events',
		'custom_notetypes',
		'data',
		'songs',
		'music',
		'sounds',
		'shaders',
		'videos',
		'images',
		'stages',
		'weeks',
		'fonts',
		'scripts',
		'hscripts',
		'lua',
		'options',
		'achievements'
	];
	#end

	public static function excludeAsset(key:String) {
		if (!dumpExclusions.contains(key))
			dumpExclusions.push(key);
	}

	public static var dumpExclusions:Array<String> =
	[
		'assets/music/freakyMenu.$SOUND_EXT',
		'assets/shared/music/breakfast.$SOUND_EXT',
		'assets/shared/music/tea-time.$SOUND_EXT',
	];


	/** Auto-free when unreferenced. Keep false everywhere: destroyOnNoUse
	 *  would kill cached-but-unreferenced graphics (useCount 0) and FlxBar's
	 *  live cached graphics, defeating the whole cache. Mobile is bounded by
	 *  the smaller maxCachedAssets instead. */
	public static var allowGraphicAutoFree:Bool = false;

	/**
	 * 从 OpenFL 资源缓存取 BitmapData 后立刻从 OpenFL 缓存移除。
	 * FlxGraphic 自己会持有这份 BitmapData，OpenFL 再留一份引用只会让图片
	 * 在 FlxGraphic 销毁后仍无法释放，造成“同一张图内存多份”。
	 */
	static function getBitmapDataOnce(file:String):BitmapData
	{
		var bmp:BitmapData = null;
		#if sys
		// 优先直接走文件系统，避免 OpenFL 资产缓存再保留一份解码后的 BitmapData。
		var fsPath:String = file;
		if (fsPath.indexOf(':') > 0 && !fsPath.startsWith('assets/'))
			fsPath = fsPath.substring(fsPath.indexOf(':') + 1);
		if (FileSystem.exists(fsPath))
			bmp = BitmapData.fromFile(fsPath);
		#end
		if (bmp == null && OpenFlAssets.exists(file, IMAGE))
			bmp = OpenFlAssets.getBitmapData(file);
		if (bmp != null)
		{
			try
			{
				openfl.Assets.cache.removeBitmapData(file);
			}
			catch (e:Dynamic) {}
		}
		return bmp;
	}

	/// haya I love you for the base cache dump I took to the max
	/**
	 * Remove a FlxGraphic from every cache (FlxG bitmap cache + currentTrackedAssets)
	 * before destroying it, so a "zombie" graphic with a null bitmap can never be
	 * returned again by Paths.image() / cacheBitmap().
	 */
	static function isGraphicAlive(g:FlxGraphic):Bool
	{
		// A destroyed FlxGraphic keeps a stale (disposed) BitmapData in its
		// `bitmap` field, but `frameCollections` is always nulled by destroy().
		// Checking both catches every zombie reliably.
		@:privateAccess
		return g != null && g.frameCollections != null && g.bitmap != null;
	}

	static function purgeGraphicFromCaches(obj:FlxGraphic, ?fileKey:String):Void
	{
		var bitmapKeys:Array<String> = [];
		@:privateAccess
		for (k in FlxG.bitmap._cache.keys())
			if (FlxG.bitmap._cache.get(k) == obj) bitmapKeys.push(k);
		for (k in bitmapKeys)
		{
			@:privateAccess
			FlxG.bitmap._cache.remove(k);
			openfl.Assets.cache.removeBitmapData(k);
		}

		if (fileKey != null)
		{
			currentTrackedAssets.remove(fileKey);
		}
		else
		{
			var fileKeys:Array<String> = [];
			for (ck in currentTrackedAssets.keys())
				if (currentTrackedAssets.get(ck) == obj) fileKeys.push(ck);
			for (ck in fileKeys)
			{
				currentTrackedAssets.remove(ck);
			}
		}
		// Safety net: never destroy a graphic a live sprite still references.
		if (obj.useCount <= 0)
		{
			// The cached sparrow-atlas frames hold a reference to this graphic and
			// are registered in its frameCollections, so destroy() nulls their
			// frames/parent. Evict them now — otherwise getSparrowAtlas() would
			// return a zombie husk and mods that build sprites from cached atlases
			// (e.g. FruitNinja-style spawners) would render nothing and end up in
			// a Lua error loop until the whole script gets silently disabled.
			var staleAtlasKeys:Array<String> = [];
			for (cacheKey => frames in atlasFramesCache)
			{
				if (frames == null || frames.parent == obj)
					staleAtlasKeys.push(cacheKey);
			}
			for (k in staleAtlasKeys)
				atlasFramesCache.remove(k);

			// Try storing in LRU cache before destroying. If retained, keep VRAM copy loaded
			// for instant reuse on song replay. Repacked graphics are exempted from size checks.
			if (backend.GfxLru.park(obj, fileKey, backend.GfxRepack.isPacked(fileKey)))
				return;

			obj.destroy();
		}
	}

	// FlxBar's cached bar graphics keep useCount 0 but are held by live FlxBar via _frontFrame;
	// the periodic purge would destroy them mid-song and break the bar fill colors.
	static inline function isFlxBarCacheKey(key:String):Bool
	{
		return key.startsWith('empty: ') || key.startsWith('filled: ') || key.startsWith('Gradient:');
	}

	public static function clearUnusedMemory() {
		// clear non local assets in the tracked assets list
		var keysToRemove:Array<String> = [];
		for (key in currentTrackedAssets.keys()) {
			// if it is not currently contained within the used local assets
			if (!localTrackedAssets.contains(key)
				&& !dumpExclusions.contains(key)) {
				// Only drop graphics that no sprite is currently using.
				// Destroying a graphic that is still referenced makes the
				// sprite render blank until the asset is loaded again.
				var obj = currentTrackedAssets.get(key);
				if (obj == null || obj.useCount <= 0)
					keysToRemove.push(key);
			}
		}
		// Batch remove to avoid map modification during iteration
		for (key in keysToRemove) {
			var obj = currentTrackedAssets.get(key);
			if (obj != null) {
				purgeGraphicFromCaches(obj, key);
			}
		}
		// System.gc() was here; removed. It hitched every song
		// switch with a full sync collect. GC goes back to the default policy.
	}

	/**
	 * Release every graphic with useCount<=0 (including the current level's),
	 * removing it from both caches before destroying so no zombie remains.
	 * @return number of graphics released.
	 */
	public static function purgeUnusedGraphics():Int
	{
		var purged:Int = 0;

		var trackedKeys:Array<String> = [];
		for (key in currentTrackedAssets.keys())
		{
			var obj = currentTrackedAssets.get(key);
			if (obj != null && obj.useCount <= 0)
				trackedKeys.push(key);
		}
		for (key in trackedKeys)
		{
			var obj = currentTrackedAssets.get(key);
			if (obj != null && obj.useCount <= 0)
			{
				purgeGraphicFromCaches(obj, key);
				purged++;
			}
		}

		var cacheKeys:Array<String> = [];
		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
			cacheKeys.push(key);
		@:privateAccess
		for (key in cacheKeys)
		{
			var obj = FlxG.bitmap._cache.get(key);
			if (obj != null && obj.useCount <= 0 && !currentTrackedAssets.exists(key) && !isFlxBarCacheKey(key))
			{
				purgeGraphicFromCaches(obj);
				purged++;
			}
		}

		return purged;
	}

	/**
	 * User-facing "clear image cache": release every cached graphic no live
	 * sprite is using. purgeUnusedGraphics() drops unused graphics from the
	 * main caches (they get parked into the LRU pool), then flushUnused()
	 * destroys the pool contents. Live graphics (useCount>0) are never touched.
	 * @return how many graphics were destroyed and how many bytes released.
	 */
	public static function clearImageCache():backend.GfxLru.GfxLruFlushResult
	{
		purgeUnusedGraphics();
		return backend.GfxLru.flushUnused('user-clear');
	}

	// define the locally tracked assets
	public static var localTrackedAssets:Array<String> = [];
	static var localTrackedAssetSet:Map<String, Bool> = new Map<String, Bool>();

	/** Record a key as used by the current state, deduplicated to avoid unbounded string-array growth. */
	public static function trackLocalAsset(key:String):Void
	{
		if (key == null || localTrackedAssetSet.exists(key)) return;
		localTrackedAssetSet.set(key, true);
		localTrackedAssets.push(key);
	}

	/** Remove a key from the current-state tracking (keeps the dedup set in sync). */
	public static function untrackLocalAsset(key:String):Void
	{
		if (key == null) return;
		localTrackedAssets.remove(key);
		localTrackedAssetSet.remove(key);
	}

	public static function clearStoredMemory(?cleanUnused:Bool = false) {
		// clear anything not in the tracked assets list
		var cacheKeys:Array<String> = [];
		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
			cacheKeys.push(key);
		@:privateAccess
		for (key in cacheKeys)
		{
			var obj = FlxG.bitmap._cache.get(key);
			if (obj != null && obj.useCount <= 0 && !currentTrackedAssets.exists(key) && !isFlxBarCacheKey(key)) {
				purgeGraphicFromCaches(obj);
			}
		}

		// clear all sounds that are cached
		for (key in currentTrackedSounds.keys()) {
			if (!localTrackedAssets.contains(key)
			&& !dumpExclusions.contains(key) && key != null) {
				currentTrackedSounds.remove(key);
			}
		}
		// flags everything to be cleared out next unused memory clear
		localTrackedAssets = [];
		localTrackedAssetSet = new Map<String, Bool>();

		// Clear atlas cache on mod/state change.
		clearAtlasFramesCache();
		// Clear per-note animation frame cache in sync with atlas cache.
		Note.clearNoteAnimCache();
	}

	static public var currentModDirectory(get, set):String;
	static var _currentModDirectory:String = '';

	static function get_currentModDirectory():String return _currentModDirectory;
	static function set_currentModDirectory(v:String):String {
		if (_currentModDirectory == v) return v;
		var oldMod = _currentModDirectory;
		_currentModDirectory = v;
		for (cb in onModDirectoryChanged) cb(oldMod, v);
		return v;
	}

	/** 模组目录变更回调（供 HScript 等监听） **/
	public static var onModDirectoryChanged:Array<String->String->Void> = [];

	static public var currentLevel:String;
	static public function setCurrentLevel(name:String)
	{
		currentLevel = name.toLowerCase();
	}

	public static function getPath(file:String, ?type:AssetType = TEXT, ?library:Null<String> = null)
	{
		if (library != null)
			return getLibraryPath(file, library);

		// 当前关卡目录（如 week1 / week2 ...）
		if (currentLevel != null && currentLevel != 'shared')
		{
			var levelPath:String = getLibraryPathForce(file, currentLevel);
			if (OpenFlAssets.exists(levelPath, type))
				return levelPath;
		}

		// shared 是全局共享资源库（NOTE_assets / characters / controllertype 等都在这里）。
		// 即使 currentLevel 为 null（例如从主菜单直接进入设置界面），也必须回退到这里，
		// 否则这些图片会解析失败返回 null —— 这是“设置界面图片变成 null”的底层根因。
		var sharedPath:String = getLibraryPathForce(file, "shared");
		if (OpenFlAssets.exists(sharedPath, type))
			return sharedPath;

		return getPreloadPath(file);
	}

	static public function getLibraryPath(file:String, library = "preload")
	{
		return if (library == "preload" || library == "default") getPreloadPath(file); else getLibraryPathForce(file, library);
	}

	// Left module-private on purpose. `source/backend/NoteSkinData.hx` needs it, so the call site
	// uses `@:privateAccess` (it is inside `#if ONLINE_ALLOWED`) rather than widening this
	// declaration. Widening the visibility here would be an unguarded engine change to a shared
	// engine file.
	inline static function getLibraryPathForce(file:String, library:String)
	{
		var returnPath = '$library:assets/$library/$file';
		return returnPath;
	}

	inline public static function getPreloadPath(file:String = '')
	{
		return 'assets/$file';
	}

	inline static public function file(file:String, type:AssetType = TEXT, ?library:String)
	{
		return getPath(file, type, library);
	}

	inline static public function txt(key:String, ?library:String)
	{
		return getPath('data/$key.txt', TEXT, library);
	}

	inline static public function xml(key:String, ?library:String)
	{
		return getPath('data/$key.xml', TEXT, library);
	}

	inline static public function json(key:String, ?library:String)
	{
		return getPath('data/$key.json', TEXT, library);
	}

	inline static public function shaderFragment(key:String, ?library:String)
	{
		return getPath('shaders/$key.frag', TEXT, library);
	}
	inline static public function shaderVertex(key:String, ?library:String)
	{
		return getPath('shaders/$key.vert', TEXT, library);
	}
	inline static public function lua(key:String, ?library:String)
	{
		return getPath('$key.lua', TEXT, library);
	}

	static public function video(key:String)
	{
		#if MODS_ALLOWED
		// 1. Check active mod's folder
		if (currentModDirectory != null && currentModDirectory.length > 0)
		{
			var file:String = mods(currentModDirectory + '/videos/' + key + '.' + VIDEO_EXT);
			if(FileSystem.exists(file)) {
				#if windows
				return file.split('\\').join('/');
				#else
				return file;
				#end
			}
		}
		// 2. Check global mods
		for (mod in getGlobalMods())
		{
			var file:String = mods(mod + '/videos/' + key + '.' + VIDEO_EXT);
			if(FileSystem.exists(file)) {
				#if windows
				return file.split('\\').join('/');
				#else
				return file;
				#end
			}
		}
		// 3. Check root mods/
		var file:String = mods('videos/' + key + '.' + VIDEO_EXT);
		if(FileSystem.exists(file)) {
			#if windows
			return file.split('\\').join('/');
			#else
			return file;
			#end
		}
		#end
		return 'assets/videos/$key.$VIDEO_EXT';

	}

	static public function sound(key:String, ?library:String):Sound
	{
		var sound:Sound = returnSound('sounds', key, library);
		return sound;
	}

	inline static public function soundRandom(key:String, min:Int, max:Int, ?library:String)
	{
		return sound(key + FlxG.random.int(min, max), library);
	}

	inline static public function music(key:String, ?library:String):Sound
	{
		var file:Sound = returnSound('music', key, library);
		return file;
	}

	inline static public function voices(song:String):Any
	{
		var songKey:String = '${formatToSongPath(song)}/Voices';
		var voices = returnSound('songs', songKey);
		return voices;
	}

		inline static public function opponentvoices(song:String):Any
	{
		var songKey:String = '${formatToSongPath(song)}/Voices-Opponent';
		var voices = returnSound('songs', songKey);
		return voices;
	}
		inline static public function playervoices(song:String):Any
	{
		var songKey:String = '${formatToSongPath(song)}/Voices-Player';
		var voices = returnSound('songs', songKey);
		return voices;
	}

	// `Paths.inst(song, songSuffix)` takes an optional difficulty suffix. This engine's `inst()`
	// had no such parameter because its own `PlayState` resolves the variant track by another
	// means, but the online slice (`online/states/RoomState.hx`, "host the currently selected
	// song") computes the same suffix, so the parameter is added here.
	//
	// The extra suffix is applied by a helper that only exists under the guard, so the single
	// `inst()` signature stays exactly as it was for the other 12 call sites and a macro-off
	// build sees the same function unchanged.
	// The suffix is only applied when it is non-null and non-empty.
	#if ONLINE_ALLOWED
	/** Appends the difficulty suffix that `Paths.inst(song, songSuffix)` accepts. */
	static function applyInstSuffix(songKey:String, ?songSuffix:String):String {
		if (songSuffix != null && songSuffix.length > 0)
			return songKey + songSuffix;
		return songKey;
	}
	#end

	static public function inst(song:String, ?songSuffix:String = null):Any
	{
		var songKey:String = '${formatToSongPath(song)}/Inst';
		#if ONLINE_ALLOWED
		songKey = applyInstSuffix(songKey, songSuffix);
		#end
		// RAM-imported instrumental takes priority (session only)
		if (ramInst.exists(songKey))
			return ramInst.get(songKey);

		#if MODS_ALLOWED
		// SeiunEngine: imported charts may store Inst.mp3 / Inst.wav / Inst.m4a
		// next to the usual Inst.ogg, so check those too before falling back.
		var exts:Array<String> = ['ogg', 'mp3', 'wav', 'm4a'];
		for (ext in exts)
		{
			var file:String = modFolders('songs/' + songKey + '.' + ext);
			if (!FileSystem.exists(file)) continue;

			var snd:Sound = null;
			if (ext == 'mp3')
			{
				// lime has no native MP3 decoder on Windows/Android — decode to
				// WAV via dr_mp3 and play from memory instead (cached per session).
				#if cpp
				try
				{
					var wav:haxe.io.Bytes = editors.content.DrMp3Tools.decodeFileToWav(file);
					if (wav != null)
					{
						var buffer:lime.media.AudioBuffer = lime.media.AudioBuffer.fromBytes(lime.utils.Bytes.ofData(wav.getData()));
						if (buffer != null) snd = Sound.fromAudioBuffer(buffer);
					}
				}
				catch (e:Dynamic) snd = null;
				#end
			}
			else
			{
				try { snd = Sound.fromFile(file); } catch (e:Dynamic) { snd = null; }
			}

			if (snd != null)
			{
				if (!currentTrackedSounds.exists(file))
					currentTrackedSounds.set(file, snd);
				trackLocalAsset(songKey);
				return currentTrackedSounds.get(file);
			}
		}
		#end
		return returnSound('songs', songKey);
	}
	/*
	inline static public function image(key:String, ?library:String):FlxGraphic
	{
		// streamlined the assets process more
		var returnAsset:FlxGraphic = returnGraphic(key, library);
		return returnAsset;
	}*/
	inline public static function getSharedPath(file:String = '')
	{
		return 'assets/shared/$file';
	}

	inline public static function mergeAllTextsNamed(path:String, defaultDirectory:String = null, allowDuplicates:Bool = false)
	{
		if(defaultDirectory == null) defaultDirectory =	getSharedPath();
		defaultDirectory = defaultDirectory.trim();
		if(!defaultDirectory.endsWith('/')) defaultDirectory += '/';
		if(!defaultDirectory.startsWith('assets/')) defaultDirectory = 'assets/$defaultDirectory';

		var mergedList:Array<String> = [];
		var paths:Array<String> = directoriesWithFile(defaultDirectory, path);

		// directoriesWithFile already returns paths in correct priority:
		// active mod → global mods → mods/ root → default (lowest)
		// No need to reorder; the natural order is authoritative.

		for (file in paths)
		{
			var list:Array<String> = CoolUtil.coolTextFile(file);
			for (value in list)
				if((allowDuplicates || !mergedList.contains(value)) && value.length > 0)
					mergedList.push(value);
		}
		return mergedList;
	}
	inline public static function directoriesWithFile(path:String, fileToFind:String, mods:Bool = true)
	{
		var foldersToCheck:Array<String> = [];

		#if MODS_ALLOWED
		if(mods)
		{
			// 1. Active mod's folder (highest priority)
			if(currentModDirectory != null && currentModDirectory.length > 0)
			{
				var folder:String = Paths.mods(currentModDirectory + '/' + fileToFind);
				if(FileSystem.exists(folder) && !foldersToCheck.contains(folder)) foldersToCheck.push(folder);
			}

			// 2. Global mods
			for(mod in getGlobalMods())
			{
				var folder:String = Paths.mods(mod + '/' + fileToFind);
				if(FileSystem.exists(folder) && !foldersToCheck.contains(folder)) foldersToCheck.push(folder);
			}

			// 3. Root "mods/" folder
			var folder:String = Paths.mods(fileToFind);
			if(FileSystem.exists(folder) && !foldersToCheck.contains(folder)) foldersToCheck.push(folder);
		}
		#end

		// 4. Default path (lowest priority)
		#if sys
		if(FileSystem.exists(path + fileToFind))
		#end
			foldersToCheck.push(path + fileToFind);

		return foldersToCheck;
	}


	static public function image(key:String, ?library:String = null, ?allowGPU:Bool = true):FlxGraphic
	{
		var bitmap:BitmapData = null;
		var file:String = null;

		#if MODS_ALLOWED
		file = modsImages(key);
		if (currentTrackedAssets.exists(file))
		{
			var cached:FlxGraphic = currentTrackedAssets.get(file);
			if (isGraphicAlive(cached))
			{
				trackLocalAsset(file);
				return cached;
			}
			currentTrackedAssets.remove(file); // zombie — force a fresh load
		}
		// Return cached graphic from LRU cache if available to skip disk read, decoding, and GPU upload
		var lruG:FlxGraphic = backend.GfxLru.lookup(file);
		if (lruG != null)
			return lruG;
		if (FileSystem.exists(file))
			bitmap = BitmapData.fromFile(file);
		else
		#end
		{
			file = getPath('images/$key.png', IMAGE, library);
			// 兜底：getPath 在 currentLevel 为 null 时可能只回退到 preload，
			// 这里显式再查一次 shared（NOTE_assets / characters / controllertype 等共享资源）。
			if (!OpenFlAssets.exists(file, IMAGE))
			{
				var sharedTry:String = getLibraryPathForce('images/$key.png', 'shared');
				if (OpenFlAssets.exists(sharedTry, IMAGE))
					file = sharedTry;
			}
			// shared 资源可能以两种 key 进缓存（'shared:assets/shared/...' 或 'assets/shared/...'），
			// 统一命中，避免同一张图被缓存两份。
			var altKey:String = null;
			if (file.startsWith('shared:assets/shared/'))
				altKey = 'assets/shared/' + file.substr('shared:assets/shared/'.length);
			else if (file.startsWith('assets/shared/'))
				altKey = 'shared:assets/shared/' + file.substr('assets/shared/'.length);

			if (currentTrackedAssets.exists(file))
			{
				var cached:FlxGraphic = currentTrackedAssets.get(file);
				if (isGraphicAlive(cached))
				{
					trackLocalAsset(file);
					return cached;
				}
				currentTrackedAssets.remove(file); // zombie — force a fresh load
			}
			else
			{
				if (altKey != null && currentTrackedAssets.exists(altKey))
				{
					var altCached:FlxGraphic = currentTrackedAssets.get(altKey);
					if (isGraphicAlive(altCached))
					{
						trackLocalAsset(altKey);
						return altCached;
					}
					currentTrackedAssets.remove(altKey);
				}
			}

			// Check LRU resident cache before any decoding attempts
			var lruMain:FlxGraphic = backend.GfxLru.lookup(file);
			if (lruMain == null && altKey != null)
			{
				var lruAlt:FlxGraphic = backend.GfxLru.lookup(altKey);
				if (lruAlt != null)
					return lruAlt;
			}
			if (lruMain != null)
				return lruMain;

			if (bitmap == null && OpenFlAssets.exists(file, IMAGE))
				bitmap = getBitmapDataOnce(file);
			#if sys
			// 直接文件系统兜底：完全不依赖 manifest 注册（覆盖 dev 运行、打包后 manifest 缺项、
			// 或 currentLevel 为 null 时库前缀解析异常等情况）。游戏目录下资源文件是真实存在的。
			if (bitmap == null)
			{
				var fsCandidates:Array<String> = [];
				if (library != null && library != 'preload' && library != 'default')
					fsCandidates.push('assets/$library/images/$key.png');
				fsCandidates.push(getPreloadPath('images/$key.png'));
				fsCandidates.push('assets/shared/images/$key.png');

				for (candidate in fsCandidates)
				{
					// Restore graphic directly if found in LRU candidate cache
					var cLru:FlxGraphic = backend.GfxLru.lookup(candidate);
					if (cLru != null)
					{
						file = candidate;
						return cLru;
					}
					if (FileSystem.exists(candidate))
					{
						file = candidate;
						bitmap = BitmapData.fromFile(candidate);
						break;
					}
				}
			}
			#end
		}

		if (bitmap != null)
		{
			var retVal = cacheBitmap(file, bitmap, allowGPU);
			if(retVal != null) return retVal;
		}

		// 最终兜底：返回占位图而不是 null。
		// 设置界面的 Note 预览 / 角色 / 手柄键盘图等拿到 null graphic 后会空白甚至崩溃。
		TraceManager.error('trace.paths.nullReturn', 'image not found: {} — using placeholder', [file]);
		return getMissingPlaceholder();
	}

	/** 缺失图片占位图（16x16 品红），保证 sprite 永远不会拿到 null graphic。 */
	static var _missingPlaceholder:FlxGraphic = null;
	static function getMissingPlaceholder():FlxGraphic
	{
		if (_missingPlaceholder == null || !isGraphicAlive(_missingPlaceholder))
		{
			var bmp:BitmapData = new BitmapData(16, 16, true, 0xFFFF00FF);
			_missingPlaceholder = FlxGraphic.fromBitmapData(bmp, false, '__missing_image_placeholder__');
			_missingPlaceholder.persist = true;
		}
		return _missingPlaceholder;
	}
	static public function languageImage(key:String, ?library:String = null, ?allowGPU:Bool = true):FlxGraphic
	{
		var currentLang:String = ClientPrefs.data.language;
		
		if (currentLang != null && currentLang.length > 0)
		{
			var langKey:String = '';
			
			if (key.indexOf('/') != -1)
			{
				var lastSlash:Int = key.lastIndexOf('/');
				langKey = key.substring(0, lastSlash) + '/' + currentLang + '/' + key.substring(lastSlash + 1);
			}
			else
			{
				langKey = currentLang + '/' + key;
			}
			#if MODS_ALLOWED
			var modPath:String = modsImages(langKey);
			if (FileSystem.exists(modPath))
			{
				return image(langKey, library, allowGPU);
			}
			#end
			
			var mainPath:String = getPath('images/$langKey.png', IMAGE, library);
			if (OpenFlAssets.exists(mainPath, IMAGE))
			{
				return image(langKey, library, allowGPU);
			}
		}
		
		return image(key, library, allowGPU);
	}

	static public function cacheBitmap(file: String, ?bitmap: BitmapData = null, ?allowGPU: Bool = true): FlxGraphic {
			if (currentTrackedAssets.exists(file)) {
				var cached:FlxGraphic = currentTrackedAssets.get(file);
				if (isGraphicAlive(cached))
				{
					trackLocalAsset(file);
					return cached;
				}
				currentTrackedAssets.remove(file); // zombie — force a fresh load
			}

			if (bitmap == null) {
				#if MODS_ALLOWED
				if (FileSystem.exists(file)) bitmap = BitmapData.fromFile(file);
				else
				#end {
					if (OpenFlAssets.exists(file, IMAGE)) bitmap = getBitmapDataOnce(file);
				}
			if (bitmap == null) return null;
			}

			trackLocalAsset(file);

			// NOTE: The old "cache on GPU" path uploaded bitmaps to a Stage3D
			// RectangleTexture and then disposed the CPU bitmap, wrapping the
			// texture with BitmapData.fromTexture(). That broke image rendering
			// with the standard OpenFL/Flixel renderer (blank images until the
			// graphic got re-loaded a few times). We always use the plain
			// CPU-side FlxGraphic cache now — it is reliable and safe.
			var newGraphic: FlxGraphic = FlxGraphic.fromBitmapData(bitmap, false, file);
			newGraphic.persist = !allowGraphicAutoFree;
			newGraphic.destroyOnNoUse = allowGraphicAutoFree;
			currentTrackedAssets.set(file, newGraphic);
			return newGraphic;
		}
	static public function getTextFromFile(key:String, ?ignoreMods:Bool = false):String
	{
		#if sys
		#if MODS_ALLOWED
		if (!ignoreMods)
		{
			var foundPath:String = modFolders(key); // Now searches active mod → global mods → root mods/
			if (FileSystem.exists(foundPath))
				return File.getContent(foundPath);
		}
		#end

		if (FileSystem.exists(getPreloadPath(key)))
			return File.getContent(getPreloadPath(key));

		// 与 getPath 一致：currentLevel 为 null（主菜单/设置）时也要能读 shared 资源
		if (currentLevel != null && currentLevel != 'shared')
		{
			var levelPath:String = getLibraryPathForce(key, currentLevel);
			if (FileSystem.exists(levelPath))
				return File.getContent(levelPath);
		}

		var sharedPath:String = 'assets/shared/$key';
		if (FileSystem.exists(sharedPath))
			return File.getContent(sharedPath);
		#end
		return Assets.getText(getPath(key, TEXT));
	}
	// FlxAtlasFrames cache: avoid re-parsing the same XML / re-creating frames for
	// every note (critical for charts with tens of thousands of notes).
	public static var atlasFramesCache:Map<String, FlxAtlasFrames> = [];

	// Clear atlas cache on mod/state change to avoid stale frames across mods.
	public static function clearAtlasFramesCache():Void {
		atlasFramesCache = [];
	}

	static public function getSparrowAtlas(key:String, ?library:String = null, ?allowGPU:Bool = true):FlxAtlasFrames
	{
		var cacheKey:String = key + '::' + (library != null ? library : '');
		var cached:FlxAtlasFrames = atlasFramesCache.get(cacheKey);
		if (cached != null)
		{
			// The parent graphic may have been destroyed by the periodic unused-
			// graphics purge after this was cached; a destroyed collection has null
			// frames and null parent. Rebuild instead of returning a zombie.
			if (isGraphicAlive(cached.parent))
				return cached;
			atlasFramesCache.remove(cacheKey);
		}

		var imageLoaded:FlxGraphic = image(key, library, allowGPU);
		if (imageLoaded == null) return null;

		try
		{
			var xmlContent:String = getSparrowXml(key, library);
			// Use packed XML generated from repacked bitmap if repacked cache hits
			xmlContent = backend.GfxRepack.applyPackedXml(xmlContent, imageLoaded);
			if (xmlContent == null)
			{
				TraceManager.error('trace.paths.atlasError', 'Failed to find sparrow XML for {}', [key]);
				return null;
			}
			var frames:FlxAtlasFrames = FlxAtlasFrames.fromSparrow(imageLoaded, xmlContent);
			#if android
			// Frames need only the GPU texture; drop the CPU sheet immediately.
			backend.GfxPolicy.releaseNow(imageLoaded.key, imageLoaded);
			#end
			atlasFramesCache.set(cacheKey, frames);
			return frames;
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.paths.sparrowBuildFail', 'Failed to build sparrow atlas for {}: {}', [key, e]);
			return null;
		}
	}

	/**
	 * 1.0.4 兼容: 解析 JSON 图集内容 (aseprite / texture-packer)，
	 * 兜底顺序与 getSparrowXml 保持一致: mods → manifest → 直接文件系统。
	 */
	static function getAtlasJson(key:String, ?library:String):String
	{
		#if MODS_ALLOWED
		var modJson:String = modsJson(key);
		if (FileSystem.exists(modJson))
			return File.getContent(modJson);
		#end

		var path:String = getPath('images/$key.json', TEXT, library);
		if (OpenFlAssets.exists(path, TEXT))
			return OpenFlAssets.getText(path);

		#if sys
		var fsCandidates:Array<String> = [];
		if (library != null && library != 'preload' && library != 'default')
			fsCandidates.push('assets/$library/images/$key.json');
		fsCandidates.push(getPreloadPath('images/$key.json'));
		fsCandidates.push('assets/shared/images/$key.json');
		for (candidate in fsCandidates)
		{
			if (FileSystem.exists(candidate))
				return File.getContent(candidate);
		}
		#end
		return null;
	}

	/**
	 * Psych Engine 1.0.4 `Paths.getAtlas` 兼容入口：自动判定图集格式 ——
	 * sparrow XML → texture-packer / aseprite JSON → packer TXT。
	 * 供 1.0.4 的 `loadFrames(..., 'auto')` / `makeAnimatedLuaSprite` 使用。
	 */
	static public function getAtlas(key:String, ?library:String = null, ?allowGPU:Bool = true):FlxAtlasFrames
	{
		if (key == null || key.length == 0) return null;

		// 1.0.4 的 .lang 词组可以把资源路径整体替换 (如 images/alphabet)。
		key = Language.getFileTranslation(key);

		if (getSparrowXml(key, library) != null)
			return getSparrowAtlas(key, library, allowGPU);

		var json:String = getAtlasJson(key, library);
		if (json != null)
		{
			var imageLoaded:FlxGraphic = returnGraphic(key);
			if (imageLoaded == null) imageLoaded = image(key, library, allowGPU);
			if (imageLoaded == null) return null;
			try
			{
				var frames:FlxAtlasFrames = FlxAtlasFrames.fromTexturePackerJson(imageLoaded, json);
				#if android
				backend.GfxPolicy.releaseNow(imageLoaded.key, imageLoaded);
				#end
				return frames;
			}
			catch (e:Dynamic)
			{
				TraceManager.error('trace.paths.jsonBuildFail', 'Failed to build JSON atlas for {}: {}', [key, e]);
				return null;
			}
		}
		return getPackerAtlas(key, library);
	}

	/**
	 * Psych Engine 1.0.4 `Paths.getAsepriteAtlas` 兼容入口：只走 JSON 图集。
	 */
	static public function getAsepriteAtlas(key:String, ?library:String = null, ?allowGPU:Bool = true):FlxAtlasFrames
	{
		if (key == null || key.length == 0) return null;
		key = Language.getFileTranslation(key);

		var json:String = getAtlasJson(key, library);
		var imageLoaded:FlxGraphic = returnGraphic(key);
		if (imageLoaded == null) imageLoaded = image(key, library, allowGPU);
		if (imageLoaded == null) return null;
		if (json == null)
		{
			TraceManager.error('trace.paths.jsonNotFound', 'No JSON atlas found for {}', [key]);
			return null;
		}
		try
		{
			var frames:FlxAtlasFrames = FlxAtlasFrames.fromTexturePackerJson(imageLoaded, json);
			#if android
			backend.GfxPolicy.releaseNow(imageLoaded.key, imageLoaded);
			#end
			return frames;
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.paths.asepriteBuildFail', 'Failed to build aseprite atlas for {}: {}', [key, e]);
			return null;
		}
	}

	/** 解析 Sparrow XML 内容：mods → manifest → 直接文件系统（与 image() 的兜底顺序一致）。 */
	static function getSparrowXml(key:String, ?library:String):String
	{
		#if MODS_ALLOWED
		var modXml:String = modsXml(key);
		if (FileSystem.exists(modXml))
			return File.getContent(modXml);
		#end

		var path:String = getPath('images/$key.xml', TEXT, library);
		if (OpenFlAssets.exists(path, TEXT))
			return OpenFlAssets.getText(path);

		#if sys
		var fsCandidates:Array<String> = [];
		if (library != null && library != 'preload' && library != 'default')
			fsCandidates.push('assets/$library/images/$key.xml');
		fsCandidates.push(getPreloadPath('images/$key.xml'));
		fsCandidates.push('assets/shared/images/$key.xml');
		for (candidate in fsCandidates)
		{
			if (FileSystem.exists(candidate))
				return File.getContent(candidate);
		}
		#end
		return null;
	}


	inline static public function languageFont()
	{
		var language_ttf:String = Language.get("ttf", "vcr");
		return 'assets/fonts/$language_ttf.ttf';
	}

	static public function font(key:String)
	{
		#if MODS_ALLOWED
		// 1. Check active mod
		if (currentModDirectory != null && currentModDirectory.length > 0)
		{
			var file:String = mods(currentModDirectory + '/fonts/' + key);
			if(FileSystem.exists(file)) return file;
		}
		// 2. Check global mods
		for (mod in getGlobalMods())
		{
			var file:String = mods(mod + '/fonts/' + key);
			if(FileSystem.exists(file)) return file;
		}
		// 3. Check root mods/
		var file:String = mods('fonts/' + key);
		if(FileSystem.exists(file)) return file;
		#end
		return 'assets/fonts/$key';
	}

	inline static public function optionsfont()
	{
		var options_ttf:String = Language.get("option.ttf", "vcr");
		return 'assets/fonts/$options_ttf.ttf';
	}
	inline static public function locale(key:String, ?library:String)
	{
		return getPath('lang/$key', TEXT, library);
	}
	inline static public function localeMod(key:String)
	{
		#if MODS_ALLOWED
		return modFolders('lang/$key');
		#else
		return null;
		#end
	}

	static public function fileExists(key:String, type:AssetType, ?ignoreMods:Bool = false, ?library:String)
	{
		#if MODS_ALLOWED
		// 1. Check active mod's folder
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
		{
			if(FileSystem.exists(mods(currentModDirectory + '/' + key))) return true;
		}
		// 2. Check global mods
		for (mod in getGlobalMods())
		{
			if(FileSystem.exists(mods(mod + '/' + key))) return true;
		}
		// 3. Check root mods/
		if(FileSystem.exists(mods(key))) return true;
		#end

		if(OpenFlAssets.exists(getPath(key, type))) {
			return true;
		}
		return false;
	}

	inline static public function getPackerAtlas(key:String, ?library:String)
	{
		#if MODS_ALLOWED
		var imageLoaded:FlxGraphic = returnGraphic(key);
		if (imageLoaded == null) imageLoaded = image(key, library);
		var txtExists:Bool = false;
		if(FileSystem.exists(modsTxt(key))) {
			txtExists = true;
		}

		var frames:FlxAtlasFrames = FlxAtlasFrames.fromSpriteSheetPacker(imageLoaded, (txtExists ? File.getContent(modsTxt(key)) : file('images/$key.txt', library)));
		#if android
		backend.GfxPolicy.releaseNow(imageLoaded.key, imageLoaded);
		#end
		return frames;
		#elseif sys
		var imageLoaded:FlxGraphic = image(key, library);
		var frames:FlxAtlasFrames = FlxAtlasFrames.fromSpriteSheetPacker(imageLoaded, file('images/$key.txt', library));
		#if android
		backend.GfxPolicy.releaseNow(imageLoaded.key, imageLoaded);
		#end
		return frames;
		#else
		var txtContent:String = null;
		var txtPath:String = file('images/$key.txt', library);
		if (txtPath != null) txtContent = Assets.getText(txtPath);
		if (txtContent == null) txtContent = '';
		var lines:Array<String> = txtContent.split('\n');
		var clean:Array<String> = [];
		for (l in lines)
			if (l != null && l.indexOf('=') >= 0) clean.push(l);
		var packerText:String = clean.join('\n');
		if (packerText.length < 1) packerText = 'placeholder = 0 0 1 1';
		return FlxAtlasFrames.fromSpriteSheetPacker(image(key, library), packerText);
		#end
	}

	/**
	 * 多图集拼接（1.0.4 loadMultipleFrames 用）。
	 * English: merge multiple sparrow atlases into a single FlxAtlasFrames
	 * (used by the 1.0.4 loadMultipleFrames Lua function).
	 */
	inline static public function getMultiAtlas(keys:Array<String>, ?parentFolder:String = null, ?allowGPU:Bool = true):FlxAtlasFrames
	{
		if (keys == null || keys.length == 0) return null;
		var parentFrames:FlxAtlasFrames = getSparrowAtlas(keys[0].trim(), parentFolder, allowGPU);
		if (parentFrames == null) return null;

		if (keys.length > 1)
		{
			var original:FlxAtlasFrames = parentFrames;
			parentFrames = new FlxAtlasFrames(parentFrames.parent);
			for (frame in original.frames)
				parentFrames.pushFrame(frame);
			for (i in 1...keys.length)
			{
				var extraFrames:FlxAtlasFrames = getSparrowAtlas(keys[i].trim(), parentFolder, allowGPU);
				if (extraFrames != null)
					for (frame in extraFrames.frames)
						parentFrames.pushFrame(frame);
			}
		}
		return parentFrames;
	}

	/**
	 * 加载 Adobe Animate 图集（0.7.3+/1.0.4 FlxAnimate 用）。
	 * English: load an Adobe Animate atlas onto a FlxAnimate sprite
	 * (used by the 0.7.3+/1.0.4 FlxAnimate Lua functions).
	 */
	#if flxanimate
	public static function loadAnimateAtlas(spr:flxanimate.PsychFlxAnimate, folderOrImg:Dynamic, spriteJson:Dynamic = null, animationJson:Dynamic = null)
	{
		var changedAnimJson:Bool = false;
		var changedAtlasJson:Bool = false;
		var changedImage:Bool = false;

		if (spriteJson != null)
		{
			changedAtlasJson = true;
			spriteJson = File.getContent(spriteJson);
		}

		if (animationJson != null)
		{
			changedAnimJson = true;
			animationJson = File.getContent(animationJson);
		}

		// is folder or image path
		if (Std.isOfType(folderOrImg, String))
		{
			var originalPath:String = folderOrImg;
			for (i in 0...10)
			{
				var st:String = '$i';
				if (i == 0) st = '';

				if (!changedAtlasJson)
				{
					if (fileExists('images/$originalPath/spritemap$st.json', TEXT))
						spriteJson = getTextFromFile('images/$originalPath/spritemap$st.json');
					else
						spriteJson = null;

					if (spriteJson != null)
					{
						changedImage = true;
						changedAtlasJson = true;
						folderOrImg = image('$originalPath/spritemap$st');
						break;
					}
				}
				else if (fileExists('images/$originalPath/spritemap$st.png', IMAGE))
				{
					changedImage = true;
					folderOrImg = image('$originalPath/spritemap$st');
					break;
				}
			}

			if (!changedImage)
			{
				changedImage = true;
				folderOrImg = image(originalPath);
			}

			if (!changedAnimJson)
			{
				changedAnimJson = true;
				if (fileExists('images/$originalPath/Animation.json', TEXT))
					animationJson = getTextFromFile('images/$originalPath/Animation.json');
				else
					animationJson = null;
			}
		}

		spr.loadAtlasEx(folderOrImg, spriteJson, animationJson);
	}
	#end

	inline static public function formatToSongPath(path:String) {
		var invalidChars = ~/[~&\\;:<>#]/;
		var hideChars = ~/[.,'"%?]/;

		var path = invalidChars.split(path.replace(' ', '-')).join("-");
		return hideChars.split(path).join("").toLowerCase();
	}

	// completely rewritten asset loading? fuck!
	public static var currentTrackedAssets:Map<String, FlxGraphic> = [];
	public static function returnGraphic(key:String, ?library:String) {
		#if MODS_ALLOWED
		var modKey:String = modsImages(key);
		if(FileSystem.exists(modKey)) {
			if(!currentTrackedAssets.exists(modKey)) {
				// Reuse from LRU resident cache if hit
				var lruMod:FlxGraphic = backend.GfxLru.lookup(modKey);
				if (lruMod != null)
					return lruMod;
				// Reuse pre-decoded bitmap from async loader if available
				var newBitmap:BitmapData = backend.AsyncGfxLoader.takeDecoded(modKey);
				if (newBitmap == null) newBitmap = BitmapData.fromFile(modKey);
				var newGraphic:FlxGraphic = FlxGraphic.fromBitmapData(newBitmap, false, modKey);
				newGraphic.persist = true;
				currentTrackedAssets.set(modKey, newGraphic);
				#if android
				backend.GfxPolicy.releaseNow(modKey, newGraphic);
				#end
			}
			trackLocalAsset(modKey);
			return currentTrackedAssets.get(modKey);
		}
		#end

		var path = getPath('images/$key.png', IMAGE, library);
		//trace(path);
		if (OpenFlAssets.exists(path, IMAGE)) {
			if(!currentTrackedAssets.exists(path)) {
				// Reuse from LRU resident cache if hit
				var lruPath:FlxGraphic = backend.GfxLru.lookup(path);
				if (lruPath != null)
					return lruPath;
				// Reuse pre-decoded bitmap from async loader if available
				var preBmp:BitmapData = backend.AsyncGfxLoader.takeDecoded(path);
				var newGraphic:FlxGraphic = preBmp != null
					? FlxGraphic.fromBitmapData(preBmp, false, path)
					: FlxG.bitmap.add(path, false, path);
				newGraphic.persist = true;
				currentTrackedAssets.set(path, newGraphic);
				#if android
				backend.GfxPolicy.releaseNow(path, newGraphic);
				#end
			}
			trackLocalAsset(path);
			return currentTrackedAssets.get(path);
		}
		TraceManager.warn('trace.paths.nullReturn', 'oh no its returning null NOOOO');
		return null;
	}

	public static var currentTrackedSounds:Map<String, Sound> = [];

	/**
	 * Session-only instrumentals loaded straight into RAM (no file written).
	 * Key: "<formatted song path>/Inst" — checked first by inst().
	 */
	public static var ramInst:Map<String, Sound> = [];
	/** Raw audio bytes of the RAM-imported instrumental (for re-export). */
	public static var ramInstBytes:Map<String, haxe.io.Bytes> = [];

	public static function setRamInst(song:String, sound:Sound):Void
	{
		ramInst.set('${formatToSongPath(song)}/Inst', sound);
	}

	public static function setRamInstBytes(song:String, bytes:haxe.io.Bytes):Void
	{
		ramInstBytes.set('${formatToSongPath(song)}/Inst', bytes);
	}

	public static function clearRamInst(song:String):Void
	{
		ramInst.remove('${formatToSongPath(song)}/Inst');
		ramInstBytes.remove('${formatToSongPath(song)}/Inst');
	}

	public static function returnSound(path:String, key:String, ?library:String) {
		#if MODS_ALLOWED
		var file:String = modsSounds(path, key);
		if(FileSystem.exists(file)) {
			if(!currentTrackedSounds.exists(file)) {
				currentTrackedSounds.set(file, Sound.fromFile(file));
			}
			trackLocalAsset(key);
			return currentTrackedSounds.get(file);
		}
		#end
		// I hate this so god damn much
		var gottenPath:String = getPath('$path/$key.$SOUND_EXT', SOUND, library);
		gottenPath = gottenPath.substring(gottenPath.indexOf(':') + 1, gottenPath.length);
		// trace(gottenPath);
		if(!currentTrackedSounds.exists(gottenPath))
		#if MODS_ALLOWED
			currentTrackedSounds.set(gottenPath, Sound.fromFile(gottenPath));
		#else
		{
			var folder:String = '';
			if(path == 'songs') folder = 'songs:';

			currentTrackedSounds.set(gottenPath, OpenFlAssets.getSound(folder + getPath('$path/$key.$SOUND_EXT', SOUND, library)));
		}
		#end
		trackLocalAsset(gottenPath);
		return currentTrackedSounds.get(gottenPath);
	}

	#if MODS_ALLOWED
	inline static public function mods(key:String = '') {
		return Sys.getCwd() + 'mods/' + key;
	}

	inline static public function modsFont(key:String) {
		return modFolders('fonts/' + key);
	}

	inline static public function modsJson(key:String) {
		return modFolders('data/' + key + '.json');
	}

	inline static public function modsVideo(key:String) {
		return modFolders('videos/' + key + '.' + VIDEO_EXT);
	}

	inline static public function modsSounds(path:String, key:String) {
		return modFolders(path + '/' + key + '.' + SOUND_EXT);
	}

	inline static public function modsImages(key:String) {
		return modFolders('images/' + key + '.png');
	}

	inline static public function modsXml(key:String) {
		return modFolders('images/' + key + '.xml');
	}

	inline static public function modsTxt(key:String) {
		return modFolders('images/' + key + '.txt');
	}


	/* Goes unused for now

	inline static public function modsShaderFragment(key:String, ?library:String)
	{
		return modFolders('shaders/'+key+'.frag');
	}
	inline static public function modsShaderVertex(key:String, ?library:String)
	{
		return modFolders('shaders/'+key+'.vert');
	}
	inline static public function modsAchievements(key:String) {
		return modFolders('achievements/' + key + '.json');
	}*/

	static public function modFolders(key:String) {
		// 1. Check active mod's folder (highest priority)
		if(currentModDirectory != null && currentModDirectory.length > 0) {
			var fileToCheck:String = mods(currentModDirectory + '/' + key);
			if(FileSystem.exists(fileToCheck)) {
				return fileToCheck;
			}
		}

		// 2. Check global mods (runsGlobally) — they should always be available
		for (mod in getGlobalMods()) {
			var fileToCheck:String = mods(mod + '/' + key);
			if(FileSystem.exists(fileToCheck)) {
				return fileToCheck;
			}
		}

		// 3. Fall back to root mods/ (lowest priority)
		return Sys.getCwd() + 'mods/' + key;
	}

	public static var globalMods:Array<String> = [];

	/** Add a single mod to the global mods list (used for dependency loading). */
	public static function addGlobalMod(mod:String):Void
	{
		if (mod == null || mod.length == 0) return;
		if (globalMods == null) globalMods = [];
		if (!globalMods.contains(mod)) globalMods.push(mod);
	}

	static public function getGlobalMods()
		return globalMods;

	static public function clearGlobalMods() {
		globalMods = [];
	}

	static public function pushGlobalMods() // prob a better way to do this but idc
	{
		globalMods = [];
		var path:String = 'modsList.txt';
		if(FileSystem.exists(path))
		{
			var list:Array<String> = CoolUtil.coolTextFile(path);
			for (i in list)
			{
				var dat = i.split("|");
				if (dat.length >= 2 && dat[0] != null && dat[0].length > 0 && dat[1] == "1")
				{
					var folder = dat[0];
					var path = Paths.mods(folder + '/pack.json');
					if(FileSystem.exists(path)) {
						try{
							var rawJson:String = File.getContent(path);
							if(rawJson != null && rawJson.length > 0) {
								// pack.json 在 1.0.4 里用 tjson 解析（容忍尾随逗号/注释）。
								var stuff:Dynamic = backend.JsonUtil.parseTolerant(rawJson);
								var global:Bool = Reflect.hasField(stuff, "runsGlobally") && Reflect.field(stuff, "runsGlobally") == true;
								if(global && !globalMods.contains(dat[0])) globalMods.push(dat[0]);
							}
						} catch(e:Dynamic){
							TraceManager.error('trace.error', 'Exception: {}', [e]);
						}
					}
				}
			}
		}
		return globalMods;
	}

	static public function getModDirectories():Array<String> {
		var list:Array<String> = [];
		var modsFolder:String = mods();
		if(FileSystem.exists(modsFolder)) {
			for (folder in FileSystem.readDirectory(modsFolder)) {
				var path = haxe.io.Path.join([modsFolder, folder]);
				if (sys.FileSystem.isDirectory(path) && !ignoreModFolders.contains(folder) && !list.contains(folder)) {
					list.push(folder);
				}
			}
		}
		return list;
	}
	#end

	#if ONLINE_ALLOWED
	/** Last file `iconBitmap()` failed on, used to avoid repeating the same debug message. */
	static var lastImageErrorFile:String = null;

	/**
	 * Decodes a freeplay icon eagerly and returns the `BitmapData` (or `null`).
	 * The consumer (`online/substates/SoFunkinSubstate.hx`) keeps its `futureQueue` and still
	 * decodes one icon per frame, so the per-frame cost profile is preserved; only the moment
	 * at which decoding begins moves from a background thread to this call.
	 *
	 * **Haxe 4.2.5 has no `haxe.thread.Future`** (introduced in 4.3; the 4.2.5 std has no
	 * `Future` anywhere -- verified by searching `C:\HaxeToolkit\haxe\std`), and the `Future` that
	 * *is* reachable here is OpenFL's (`openfl.utils.Future`), a callback-based future with
	 * neither `isComplete` nor `value`, so a deferred value cannot be reproduced.
	 * The engine therefore cannot expose a Future-based API on this target.
	 *
	 * The returned value therefore comes from the three lookup branches below, each of which
	 * returns the decoded bitmap directly when the requested file exists.
	 *
	 * Pairs with `bitmapToGraphic()` below. (Named `iconBitmap` rather than `asyncBitmap`
	 * because it is synchronous: the caller gets the bitmap immediately.)
	 *
	 * Guarded by ONLINE_ALLOWED: the online slice is its only consumer.
	 */
	static public function iconBitmap(key:String, ?library:String = null, ?modDir:String):Null<BitmapData> {
		var file:String = null;

		#if MODS_ALLOWED
		file = (modDir != null && modDir.length > 0) ? mods(modDir + '/images/' + key + '.png') : modsImages(key);
		// return cached
		if (currentTrackedAssets.exists(file))
		{
			localTrackedAssets.push(file);
			return currentTrackedAssets.get(file).bitmap;
		}
		// found in the mods files
		else if (FileSystem.exists(file))
			return BitmapData.fromFile(file);
		// load from assets
		else
		#end
		{
			file = getPath('images/$key.png', IMAGE, library);
			if (currentTrackedAssets.exists(file))
			{
				localTrackedAssets.push(file);
				return currentTrackedAssets.get(file).bitmap;
			}
			else if (OpenFlAssets.exists(file, IMAGE))
				return OpenFlAssets.getBitmapData(file);
		}

		if (lastImageErrorFile != file && ClientPrefs.isDebug()) {
			Sys.println('Paths.iconBitmap(): oh no its returning null NOOOO ($file)');
			lastImageErrorFile = file;
		}
		return null;
	}

	/**
	 * Registers an already-decoded `BitmapData` in the engine's graphic cache so that
	 * `Paths.image()` and `FlxSprite.loadGraphic()` can reuse it. It is the pairing helper for
	 * `iconBitmap()` above and is called from `online/substates/SoFunkinSubstate.hx:201`, which
	 * installs the freshly decoded icon into the cache.
	 *
	 * Guarded by ONLINE_ALLOWED (only consumer is the online slice). The commented-out GPU-texture
	 * fast path below is intentionally left disabled.
	 */
	static public function bitmapToGraphic(file:String, bitmap:BitmapData) {
		localTrackedAssets.push(file);
		// if (allowGPU /*&& ClientPrefs.data.cacheOnGPU*/)
		// {
		// 	var texture:RectangleTexture = FlxG.stage.context3D.createRectangleTexture(bitmap.width, bitmap.height, BGRA, true);
		// 	texture.uploadFromBitmapData(bitmap);
		// 	bitmap.image.data = null;
		// 	bitmap.dispose();
		// 	bitmap.disposeImage();
		// 	bitmap = BitmapData.fromTexture(texture);
		// }
		var newGraphic:FlxGraphic = FlxGraphic.fromBitmapData(bitmap, false, file);
		newGraphic.persist = true;
		newGraphic.destroyOnNoUse = false;
		currentTrackedAssets.set(file, newGraphic);
		return newGraphic;
	}
	#end
}
