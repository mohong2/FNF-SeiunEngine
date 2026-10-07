package backend;

import flixel.FlxG;
import flixel.graphics.FlxGraphic;
import mohong.TraceManager;


typedef GfxLruLedgerDelta =
{
	var parked:Int;
	var bytes:Float;
	var hits:Int;
	var saved:Float;
}


typedef GfxLruFlushResult =
{
	var count:Int;
	var bytes:Float;
}


typedef GfxLruEntry =
{
	var key:String;        
	var normKey:String;    
	var graphic:FlxGraphic;
	var bytes:Float;
	var hits:Int;
	var lastUse:Int;
	var pinned:Bool;
}


class GfxLru
{
	public static var enabled:Bool = true;

	public static var budgetBytes:Float = 1536 * 1048576;

	public static inline var HOT_HITS:Int = 2;

	public static var parkedTotal:Int = 0;
	public static var parkedBytesTotal:Float = 0;
	public static var hitTotal:Int = 0;
	public static var savedMsTotal:Float = 0;
	public static var evictTotal:Int = 0;

	static var entries:Map<String, GfxLruEntry> = [];
	static var totalBytes:Float = 0;
	static var tick:Int = 0;
	static var wasEnabled:Bool = true;

	static var wm:GfxLruLedgerDelta = {parked: 0, bytes: 0.0, hits: 0, saved: 0.0};

	public static function isEnabled():Bool
	{
		return enabled && ClientPrefs.data.gfxLruCache;
	}


	public static function park(g:FlxGraphic, ?fileKey:String, allowSmall:Bool = false):Bool
	{
		checkEnabledFlush();
		if (!isEnabled()) return false;
		if (g == null || g.key == null) return false;

		// Use the graphic's own creation key as the canonical LRU key. The
		// optional fileKey is only an alias (e.g. shared:... vs assets/...);
		// revive() re-registers both forms so cache/eviction stay in sync.
		var key:String = g.key;
		if (key == null || key.length == 0) return false;

		var bmp = g.bitmap;
		if (bmp == null) return false;

		var packed:Bool = allowSmall || backend.GfxRepack.isPacked(g.key);
		if (!packed && bmp.width < GfxPolicy.minDimension && bmp.height < GfxPolicy.minDimension)
			return false;

		var bytes:Float = bmp.width * bmp.height * 4;
		if (bytes > budgetBytes) return false;

		var norm:String = normalizeKey(key);
		var existing = entries.get(norm);
		var prevHits:Int = 0;
		var prevPin:Bool = false;
		if (existing != null && existing.graphic == g)
		{
			tick++;
			existing.lastUse = tick;
			return true;
		}

		if (bmp.readable)
		{
			if (!GfxPolicy.hasLiveTexture(bmp)) return false;
		}
		else if (!GfxPolicy.hasLiveTexture(bmp))
		{
			return false;
		}

		if (existing != null)
		{
			prevHits = existing.hits;
			prevPin = existing.pinned;
			// Evict first so any CPU-release registry owned by the old graphic
			// is dropped; otherwise tryRelease below would reject the new one.
			evictEntry(existing, 'replace'); 
		}

		if (bmp.readable)
		{
			if (!GfxPolicy.tryRelease(key, g)) return false;
		}

		tick++;
		var e:GfxLruEntry = {
			key: key,
			normKey: norm,
			graphic: g,
			bytes: bytes,
			hits: prevHits,
			lastUse: tick,
			pinned: prevPin
		};
		entries.set(norm, e);
		totalBytes += bytes;
		parkedTotal++;
		parkedBytesTotal += bytes;
		TraceManager.info('trace.gfx.lruPark',
			'GfxLru parked {}: ~{} MB', [key, mb(bytes)]);

		enforceBudget();
		return true;
	}

	public static function lookup(requestedKey:String):Null<FlxGraphic>
	{
		if (requestedKey == null || requestedKey.length == 0) return null;
		checkEnabledFlush();
		if (!isEnabled()) return null;

		var e = entries.get(normalizeKey(requestedKey));
		if (e == null) return null;
		if (!entryUsable(e))
		{
			evictEntry(e, 'dead');
			return null;
		}

		touch(e);
		hitTotal++;
		savedMsTotal += estimateSavedMs();

		revive(e, requestedKey);
		TraceManager.info('trace.gfx.lruHit',
			'GfxLru hit #{}: {} (~{} MB vram, zero decode)', [hitTotal, requestedKey, mb(e.bytes)]);
		return e.graphic;
	}

	public static function has(requestedKey:String):Bool
	{
		if (requestedKey == null || requestedKey.length == 0) return false;
		if (!isEnabled()) return false;
		var e = entries.get(normalizeKey(requestedKey));
		return e != null && entryUsable(e);
	}

	public static function pin(requestedKey:String):Void
	{
		var e = entries.get(normalizeKey(requestedKey != null ? requestedKey : ''));
		if (e != null) e.pinned = true;
	}

	public static function unpin(requestedKey:String):Void
	{
		var e = entries.get(normalizeKey(requestedKey != null ? requestedKey : ''));
		if (e != null) e.pinned = false;
	}

	public static function isParked(requestedKey:String):Bool
	{
		return requestedKey != null && entries.exists(normalizeKey(requestedKey));
	}

	public static function takeLedgerDelta():GfxLruLedgerDelta
	{
		var d:GfxLruLedgerDelta = {
			parked: parkedTotal - wm.parked,
			bytes: parkedBytesTotal - wm.bytes,
			hits: hitTotal - wm.hits,
			saved: savedMsTotal - wm.saved
		};
		wm.parked = parkedTotal;
		wm.bytes = parkedBytesTotal;
		wm.hits = hitTotal;
		wm.saved = savedMsTotal;
		return d;
	}

	public static function liveEntries():Int return Lambda.count(entries);
	public static function liveBytes():Float return totalBytes;
	public static function liveHotCount():Int
	{
		var n:Int = 0;
		for (e in entries) if (e.hits >= HOT_HITS) n++;
		return n;
	}
	public static function livePinnedCount():Int
	{
		var n:Int = 0;
		for (e in entries) if (e.pinned) n++;
		return n;
	}
	public static function budgetMb():Float return budgetBytes / 1048576;

	/**
	 * Rough decode cost an LRU hit avoids. The async decode average this used to report is gone
	 * with the background pre-decode path, so the fixed estimate is what is left.
	 */
	public static function estimateSavedMs():Float
	{
		return 300;
	}

	public static function onContextRestored():Void
	{
		if (Lambda.count(entries) == 0) return;
		var dead:Array<GfxLruEntry> = [];
		for (e in entries)
			if (!entryUsable(e)) dead.push(e);
		for (e in dead)
			evictEntry(e, 'context');
		if (dead.length > 0)
			TraceManager.warn('trace.gfx.lruContext',
				'GfxLru context-restored: evicted {} unusable parked graphics', [dead.length]);
	}

	public static function flushAll(reason:String):Void
	{
		var all:Array<GfxLruEntry> = [];
		for (e in entries) all.push(e);
		for (e in all) evictEntry(e, reason);
	}

	/**
	 * Evict only entries no live sprite references (useCount<=0, never pinned).
	 * flushAll() would also destroy revived graphics that sprites are actively
	 * using, so user-facing "clear cache" actions must go through this instead.
	 * @return how many graphics were destroyed and how many bytes released.
	 */
	public static function flushUnused(reason:String):GfxLruFlushResult
	{
		var result:GfxLruFlushResult = {count: 0, bytes: 0.0};
		var doomed:Array<GfxLruEntry> = [];
		for (e in entries)
			if (!e.pinned && (e.graphic == null || e.graphic.useCount <= 0))
				doomed.push(e);
		for (e in doomed)
		{
			var bytes:Float = e.bytes;
			evictEntry(e, reason);
			result.count++;
			result.bytes += bytes;
		}
		return result;
	}

	static function checkEnabledFlush():Void
	{
		var now = isEnabled();
		if (wasEnabled && !now && Lambda.count(entries) > 0)
			flushAll('setting-off');
		wasEnabled = now;
	}
	static function entryUsable(e:GfxLruEntry):Bool
	{
		var g = e.graphic;
		if (g == null || g.bitmap == null) return false;
		@:privateAccess
		if (g.frameCollections == null) return false; // 已被外部 destroy
		return g.bitmap.readable || GfxPolicy.hasLiveTexture(g.bitmap);
	}

	static inline function touch(e:GfxLruEntry):Void
	{
		tick++;
		e.lastUse = tick;
		e.hits++;
	}

	
	static function revive(entry:GfxLruEntry, requestedKey:String):Void
	{
		registerAlias(requestedKey, entry.graphic);
		// Keep the canonical key registered too. Without this, a hit through an
		// alias (shared:... vs assets/...) could leave the entry untracked and
		// the budget evictor could destroy a graphic a live sprite still uses.
		if (entry.key != null && entry.key != requestedKey)
			registerAlias(entry.key, entry.graphic);
	}

	static function registerAlias(key:String, g:FlxGraphic):Void
	{
		if (key == null || key.length == 0 || g == null) return;

		var existing:FlxGraphic = Paths.currentTrackedAssets.get(key);
		var flxExisting:FlxGraphic = null;
		@:privateAccess
		{
			flxExisting = FlxG.bitmap._cache.get(key);
		}
		if ((existing != null && existing != g) || (flxExisting != null && flxExisting != g))
			return; // never replace different live graphics in either cache

		Paths.currentTrackedAssets.set(key, g);
		@:privateAccess
		{
			FlxG.bitmap._cache.set(key, g);
		}
		Paths.trackLocalAsset(key);
	}

	static function enforceBudget():Void
	{
		var guard:Int = 0;
		while (totalBytes > budgetBytes && guard++ < 1024)
		{
			var v = pickVictim(false); 
			if (v == null) v = pickVictim(true); 
			if (v == null) break;
			evictEntry(v, 'budget');
		}
	}

	static function pickVictim(includeHot:Bool):GfxLruEntry
	{
		var best:GfxLruEntry = null;
		for (e in entries)
		{
			if (e.pinned) continue;
			if (!includeHot && e.hits >= HOT_HITS) continue;
			if (e.graphic != null && e.graphic.useCount > 0) continue;
			if (Paths.currentTrackedAssets.exists(e.key)) continue;
			if (best == null || e.lastUse < best.lastUse) best = e;
		}
		return best;
	}

	static function evictEntry(e:GfxLruEntry, reason:String):Void
	{
		if (e == null) return;
		entries.remove(e.normKey);
		totalBytes -= e.bytes;
		if (totalBytes < 0) totalBytes = 0;
		evictTotal++;
		if (e.key != null) backend.GfxRepack.forgetPair(e.key);
		if (e.graphic != null)
		{
			if (e.key != null) GfxPolicy.forgetReleased(e.key);
			if (e.graphic.key != null) GfxPolicy.forgetReleased(e.graphic.key);
			removeFromCaches(e.graphic);
			e.graphic.destroy();
		}
	}

	static function removeFromCaches(g:FlxGraphic):Void
	{
		if (g == null) return;
		var keys:Array<String> = [];
		for (key => value in Paths.currentTrackedAssets)
			if (value == g) keys.push(key);
		for (key in keys)
		{
			Paths.currentTrackedAssets.remove(key);
			try openfl.Assets.cache.removeBitmapData(key) catch (e:Dynamic) {}
		}
		keys.resize(0);
		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
			if (FlxG.bitmap._cache.get(key) == g) keys.push(key);
		@:privateAccess
		for (key in keys)
		{
			FlxG.bitmap._cache.remove(key);
			try openfl.Assets.cache.removeBitmapData(key) catch (e:Dynamic) {}
		}
	}

	static function normalizeKey(key:String):String
	{
		var ci = key.indexOf(':');
		if (ci <= 0) return key;
		var prefix = key.substr(0, ci);
		var rest = key.substr(ci + 1);
		if (rest.startsWith('assets/')
			&& prefix.indexOf('/') < 0
			&& prefix.indexOf('\\') < 0
			&& prefix.indexOf(':') < 0)
			return rest;
		return key;
	}

	static inline function mb(v:Float):String
	{
		return Std.string(Math.round(v / 1048576 * 10) / 10);
	}
}
