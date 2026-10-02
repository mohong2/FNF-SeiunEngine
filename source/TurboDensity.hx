#if seiun_turbo_harness
// Standalone benchmark harness (tools/turboharness) compiles this same file
// against a flixel-free stub of source/Note.hx. Engine builds take the normal path.
import PreloadedChartNote;
#else
import Note.PreloadedChartNote;
#end
import haxe.Int64;

/**
 * Turbo-mode chart pre-processing.
 *
 * The engine has a single render path: real note sprites. "Not fast enough" therefore always
 * means "too many sprites alive at once". Low scroll speeds make this worst: a +/-700px band
 * covers 1400 / (0.45 * songSpeed) ms of chart, roughly 3.1s at speed=1 and 6.2s at speed=0.5,
 * which can hold six figures of notes on a very dense chart; materialising all of them is
 * pure waste.
 *
 * Key observation: two notes on the same lane that are less than a pixel apart on screen look
 * (and draw) as one, because note sprites are opaque and cover each other. Merging by screen
 * pixel distance rather than time distance is what stays consistent with the scroll speed:
 * lower speed -> smaller pixel gap -> more merges -> a constant materialised count that does
 * not explode with chart density.
 * This class is a side-effect free data transform: nothing is written to disk, cached or modified in place.
 */
typedef TurboGhostScratch = {
	var lastTime:Array<Float>;
	var lastRate:Array<Float>;
	var lastSlowRate:Array<Float>;
}

class TurboDensity
{
	/** Same-lane same-direction taps closer than this on screen are treated as one note (pixels). */
	public static inline final DEFAULT_MIN_GAP_PX:Float = 4.0;

	/** Most raw taps a single note may represent; guards against extreme charts distorting the density value. */
	public static inline final MAX_REPRESENTED:Int = 512;

	/**
 * Chart content fingerprint.
	 *
 * Contains only chart-owned fields: time, lane, judgement side, length. noteDensity is
 * deliberately excluded because it is an output of collapseGhostNotes (the merged count),
 * so any repeat call over the same array would change it and make the fingerprint unstable;
 * anything derived from it would drift. The class holds no cache; the fingerprint is used
 * for logging and diagnostics only.
	 */
	public static function chartFingerprint(notes:Array<PreloadedChartNote>):Int
	{
		var h:Int = 0x811C9DC5;
		if (notes == null)
			return h;
		for (pn in notes)
		{
			if (pn == null)
			{
				h = (h * 31 + 0xFFFF) & 0x7FFFFFFF;
				continue;
			}
			h = (h * 31 + Std.int(pn.strumTime * 1000)) & 0x7FFFFFFF;
			h = (h * 31 + pn.noteData + pn.mania * 7) & 0x7FFFFFFF;
			h = (h * 31 + (pn.mustPress ? 2 : 0) + (pn.isSustainNote ? 4 : 0) + (pn.isSustainEnd ? 8 : 0) + (pn.gfNote ? 16 : 0)) & 0x7FFFFFFF;
			h = (h * 31 + Std.int(pn.sustainLength * 1000)) & 0x7FFFFFFF;
			h = (h * 31 + Std.int(pn.parentST * 1000)) & 0x7FFFFFFF;
		}
		return h;
	}

	/**
 * Turbo pre-processing at chart load: folds taps that cannot be told apart on screen into one
 * representative note.
 * Pure function: it never mutates the caller's objects and does not depend on the call count,
 * so repeated calls give identical results. (The old form wrote `prev.noteDensity += 1` on a
 * shared object, so the second call differed and every derived index drifted.)
	 *
 * Merge rule (same lane + same mustPress side + same multSpeed, adjacent in time):
 *   screen gap = dt * 0.45 * songSpeed * multSpeed * maniaScale < minGapPx
 * The gap uses the slower of the two notes' visible rates, so it is conservative for speed
 * tweens: notes are merged only when they can never separate beyond minGapPx at any time.
	 *
 * The representative keeps the earliest note of the group (the first to reach the strum line,
 * which visually fills that pixel band) and accumulates the merged count into its noteDensity,
 * matching the existing judgement weighting (PlayState counts combo / judgements by noteDensity).
	 *
 * @param songSpeed  actual scroll speed of this play (PlayState.songSpeed)
 * @param mania      key count of this play (drives maniaScale)
 * @param rangeMs    extra hard time floor (ghost-note merging), default 1.0ms
 * @param minGapPx   screen pixel gap threshold
	 */
	public static function collapseGhostNotes(notes:Array<PreloadedChartNote>, laneCount:Int,
		rangeMs:Float = 1.0, songSpeed:Float = 1.0, mania:Int = -1, minGapPx:Float = DEFAULT_MIN_GAP_PX):Array<PreloadedChartNote>
	{
		if (notes == null || notes.length == 0)
			return notes != null ? notes : [];
		if (laneCount <= 0)
			laneCount = 4;
		if (!Math.isFinite(songSpeed) || songSpeed <= 0)
			songSpeed = 1.0;
		if (!Math.isFinite(minGapPx) || minGapPx < 0)
			minGapPx = 0;
		if (!Math.isFinite(rangeMs) || rangeMs < 0)
			rangeMs = 0;

		var maniaScale:Float = 1.0;
		#if !seiun_turbo_harness
		maniaScale = Note.getManiaScale(mania);
		#end
		if (!Math.isFinite(maniaScale) || maniaScale <= 0)
			maniaScale = 1.0;

		// Pixel/ms -> ms threshold factor (same formula as the note position):
		// screen gap between two notes = dt * 0.45 * songSpeed * multSpeed * maniaScale
		var pxPerMs:Float = 0.45 * songSpeed * maniaScale;

		var slots:Int = laneCount * 2;
		var scratch:TurboGhostScratch = {
			lastTime: [for (i in 0...slots) -1e30],
			lastRate: [for (i in 0...slots) 0.0],
			lastSlowRate: [for (i in 0...slots) 0.0]
		};

		// Index of the representative that can still absorb folds, per lane/side.
		// Tracked per lane rather than just looking at the tail of out: sustains and tails are
		// inserted between representatives, and a representative is the only object allowed to carry noteDensity.
		var anchor:Array<Int> = [for (i in 0...slots) -1];

		var out:Array<PreloadedChartNote> = [];

		for (pn in notes)
		{
			if (pn == null)
				continue;

			// Sustains, tails and sustain heads never merge: tail trimming and the prev/next chain must stay intact.
			if (pn.isSustainNote || pn.sustainLength > 0)
			{
				out.push(pn);
				continue;
			}

			var lane:Int = Std.int(Math.abs(pn.noteData));
			if (lane >= laneCount)
				lane = lane % laneCount;
			var idx:Int = (pn.mustPress ? 1 : 0) * laneCount + lane;

			var rate:Float = pxPerMs * (pn.multSpeed > 0 ? pn.multSpeed : 1.0);

			var mergeable:Bool = false;
			if (anchor[idx] >= 0 && scratch.lastRate[idx] == rate && scratch.lastSlowRate[idx] > 0)
			{
				var dt:Float = pn.strumTime - scratch.lastTime[idx];
				if (dt <= rangeMs)
				{
					// Notes overlapping in time: merge unconditionally (matches the old behaviour).
					mergeable = true;
				}
				else if (minGapPx > 0 && dt * scratch.lastSlowRate[idx] < minGapPx)
				{
					// The slower note sets the minimum visible gap: if even it stays under minGapPx,
					// the two notes can never become distinguishable.
					mergeable = true;
				}
			}

			var prev:Null<PreloadedChartNote> = (anchor[idx] >= 0) ? out[anchor[idx]] : null;

			if (mergeable && prev != null && prev.noteDensity < MAX_REPRESENTED)
			{
				prev.noteDensity += 1;
				continue;
			}

			// A new representative: clone it so the caller's objects stay untouched.
			// noteDensity is normalised to 1: the merged count is a result of this pass, not a chart property.
			var rep:PreloadedChartNote = cloneNote(pn);
			rep.noteDensity = 1;
			out.push(rep);
			anchor[idx] = out.length - 1;

			// Whether it split or hit the group cap, this representative is the next anchor for the lane.
			scratch.lastTime[idx] = rep.strumTime;
			scratch.lastRate[idx] = rate;
			scratch.lastSlowRate[idx] = rate;
		}

		return out;
	}

	/**
	 * Shallow copy of one PreloadedChartNote.
	 * Turbo-only: the caller's objects stay untouched so the result stays idempotent and fingerprintable.
	 */
	public static function cloneNote(src:PreloadedChartNote):PreloadedChartNote
	{
		return {
			strumTime: src.strumTime,
			sustainLength: src.sustainLength,
			parentST: src.parentST,
			parentSL: src.parentSL,
			stepCrochet: src.stepCrochet,
			hitHealth: src.hitHealth,
			missHealth: src.missHealth,
			multSpeed: src.multSpeed,
			multAlpha: src.multAlpha,
			noteDensity: src.noteDensity,
			offsetX: src.offsetX,
			offsetY: src.offsetY,
			noteSplashHue: src.noteSplashHue,
			noteSplashSat: src.noteSplashSat,
			noteSplashBrt: src.noteSplashBrt,
			noteType: src.noteType,
			animSuffix: src.animSuffix,
			noteskin: src.noteskin,
			texture: src.texture,
			noteSplashTexture: src.noteSplashTexture,
			noteData: src.noteData,
			mania: src.mania,
			mustPress: src.mustPress,
			oppNote: src.oppNote,
			gfNote: src.gfNote,
			noAnimation: src.noAnimation,
			noMissAnimation: src.noMissAnimation,
			isSustainNote: src.isSustainNote,
			isSustainEnd: src.isSustainEnd,
			hitCausesMiss: src.hitCausesMiss,
			ignoreNote: src.ignoreNote,
			blockHit: src.blockHit,
			lowPriority: src.lowPriority,
			wasHit: src.wasHit,
			noteSplashDisabled: src.noteSplashDisabled,
			hitsoundDisabled: src.hitsoundDisabled
		};
	}

	/**
	 * Converts a tap sequence (with sustains/tails already excluded) into "how many notes each representative stands for".
	 * Diagnostics / tests only.
	 */
	public static function representedTotal(notes:ChartNotes):Int64
	{
		// Running total, not an index: each row contributes up to MAX_REPRESENTED notes to the sum, so
		// a folded list of a few million rows can pass 2^31 while every individual row is still an
		// Int. The Int64 return keeps a diagnostic from wrapping silently.
		var t:Int64 = 0;
		for (i in 0...notes.length) t = t + Std.int(Math.max(1, Math.round(notes.noteDensityAt(i))));
		return t;
	}
}

/**
 * Incremental version of collapseGhostNotes: folds while the notes are produced instead of
 * materialising the whole DTO array first. The per-note test matches collapseGhostNotes (and
 * delegates to the same helper), apart from one deliberate tightening: a note that is earlier
 * than its representative on the same lane is never merged. Streamed input arrives in file
 * order, and real charts contain a few out-of-order notes across sections; merging backwards
 * would drop a real note from the combo / judgement / health totals. Skipping the merge only
 * costs a few KB and keeps the judgement count correct, since collapses are counted by
 * noteDensity either way.
 * Usage: feed() while producing, read out at the end. Sustains and sustain heads are pushed
 * straight through, as in the full-array version.
 */
class GhostCollapser
{
	// Packed columns, not an Array: a dense chart folds to millions of representatives and the
	// array form of that is what grows hxcpp's block pool to several GB for the whole song.
	public var out:ChartNotes = ChartNotes.builder(4096);
	/**
	 * Total notes fed in (diagnostic). A running total over the whole chart, never an index, so it is
	 * Int64: a segmented chart can feed more notes than an Int32 can hold. This is also the value
	 * PlayState saves as ChartCache's fedNotes.
	 */
	public var fedCount:Int64 = 0;

	var laneCount:Int;
	var rangeMs:Float;
	var minGapPx:Float;
	var pxPerMs:Float;
	var slots:Int;
	var lastTime:Array<Float>;
	var lastRate:Array<Float>;
	var lastSlowRate:Array<Float>;
	var anchor:Array<Int>;
	/** Pending noteDensity of each slot's current representative. Kept in a plain Float array while
	 *  folding and only written into the column when the representative is finalised: on a dense
	 *  chart the merge path runs ~311M times, and a column read+write per merge made the load ~50s
	 *  slower than the old "increment a field through a pointer" version. */
	var lastDensity:Array<Float>;
	/** Slot/rate stashed by wantsRepresentative() for the commitRepresentative() that must follow. */
	var pendingIdx:Int = 0;
	var pendingRate:Float = 0;

	public function new(laneCount:Int, rangeMs:Float = 1.0, songSpeed:Float = 1.0, mania:Int = -1,
		minGapPx:Float = TurboDensity.DEFAULT_MIN_GAP_PX)
	{
		if (laneCount <= 0) laneCount = 4;
		if (!Math.isFinite(songSpeed) || songSpeed <= 0) songSpeed = 1.0;
		if (!Math.isFinite(minGapPx) || minGapPx < 0) minGapPx = 0;
		if (!Math.isFinite(rangeMs) || rangeMs < 0) rangeMs = 0;

		var maniaScale:Float = 1.0;
		#if !seiun_turbo_harness
		maniaScale = Note.getManiaScale(mania);
		#end
		if (!Math.isFinite(maniaScale) || maniaScale <= 0) maniaScale = 1.0;

		this.laneCount = laneCount;
		this.rangeMs = rangeMs;
		this.minGapPx = minGapPx;
		pxPerMs = 0.45 * songSpeed * maniaScale;
		slots = laneCount * 2;
		lastTime = [for (i in 0...slots) -1e30];
		lastRate = [for (i in 0...slots) 0.0];
		lastSlowRate = [for (i in 0...slots) 0.0];
		anchor = [for (i in 0...slots) -1];
		lastDensity = [for (i in 0...slots) 0.0];
	}

	/** Writes a slot's pending count back to the column it belongs to. */
	inline function flushDensity(slot:Int):Void
	{
		var at:Int = anchor[slot];
		if (at >= 0 && lastDensity[slot] > 0) out.setNoteDensity(at, lastDensity[slot]);
	}

	inline function flushAllDensity():Void
	{
		for (i in 0...slots) flushDensity(i);
	}

	public function feed(pn:PreloadedChartNote):Void
	{
		if (pn == null) return;
		fedCount = fedCount + 1;

		// Sustains, tails and sustain heads never merge: tail trimming and the prev/next chain must stay intact.
		if (pn.isSustainNote || pn.sustainLength > 0)
		{
			out.append(pn);
			return;
		}

		var lane:Int = Std.int(Math.abs(pn.noteData));
		if (lane >= laneCount) lane = lane % laneCount;
		var idx:Int = (pn.mustPress ? 1 : 0) * laneCount + lane;
		var rate:Float = pxPerMs * (pn.multSpeed > 0 ? pn.multSpeed : 1.0);

		var mergeable:Bool = false;
		if (anchor[idx] >= 0 && lastRate[idx] == rate && lastSlowRate[idx] > 0)
		{
			var dt:Float = pn.strumTime - lastTime[idx];
			if (dt >= 0)
			{
				if (dt <= rangeMs)
					mergeable = true;
				else if (minGapPx > 0 && dt * lastSlowRate[idx] < minGapPx)
					mergeable = true;
			}
		}

		// The fold increments the density of a representative appended earlier, so it has to go
		// through the column: a DTO read back from the store cannot be written through.
		if (mergeable && lastDensity[idx] > 0 && lastDensity[idx] < TurboDensity.MAX_REPRESENTED)
		{
			lastDensity[idx] += 1;
			return;
		}

		var rep:PreloadedChartNote = TurboDensity.cloneNote(pn);
		rep.noteDensity = 1;
		flushDensity(idx);
		out.append(rep);
		anchor[idx] = out.length - 1;
		lastDensity[idx] = 1;
		lastTime[idx] = rep.strumTime;
		lastRate[idx] = rate;
		lastSlowRate[idx] = rate;
	}

	// ── allocation-free raw path ──────────────────────────────────────────
	// feed() needs a PreloadedChartNote to decide whether a note merges, so a chart on which almost
	// every note merges still builds one DTO per note. The raw path makes the same decision from the
	// note's own fields, so the caller only materialises a DTO for the notes that survive. The merge
	// rules are feed()'s; feed() is kept for callers that already have a DTO.

	/**
	 * Raw front half of feed(): merges a tap into the previous representative when feed() would and
	 * reports whether the caller must materialise a new one.
	 *
	 * False: the tap was merged (the previous representative's noteDensity was incremented) and
	 * nothing must be allocated. True: build a PreloadedChartNote and pass it to
	 * commitRepresentative(). Holds and sustain segments never merge -- use pushHold() for those.
	 */
	public function wantsRepresentative(strumTime:Float, lane:Int, mustPress:Bool, multSpeed:Float = 1):Bool
	{
		fedCount = fedCount + 1;
		lane = Std.int(Math.abs(lane));
		if (lane >= laneCount) lane = lane % laneCount;
		var idx:Int = (mustPress ? 1 : 0) * laneCount + lane;
		var rate:Float = pxPerMs * (multSpeed > 0 ? multSpeed : 1.0);

		var mergeable:Bool = false;
		if (anchor[idx] >= 0 && lastRate[idx] == rate && lastSlowRate[idx] > 0)
		{
			var dt:Float = strumTime - lastTime[idx];
			if (dt >= 0)
			{
				if (dt <= rangeMs)
					mergeable = true;
				else if (minGapPx > 0 && dt * lastSlowRate[idx] < minGapPx)
					mergeable = true;
			}
		}

		if (mergeable && lastDensity[idx] > 0 && lastDensity[idx] < TurboDensity.MAX_REPRESENTED)
		{
			lastDensity[idx] += 1;
			return false;
		}

		pendingIdx = idx;
		pendingRate = rate;
		return true;
	}

	/** Second half of the raw path: registers the representative built after wantsRepresentative() returned true. */
	public function commitRepresentative(rep:PreloadedChartNote):Void
	{
		if (rep == null) return;
		rep.noteDensity = 1;
		flushDensity(pendingIdx);
		out.append(rep);
		anchor[pendingIdx] = out.length - 1;
		lastDensity[pendingIdx] = 1;
		lastTime[pendingIdx] = rep.strumTime;
		lastRate[pendingIdx] = pendingRate;
		lastSlowRate[pendingIdx] = pendingRate;
	}

	/** Holds, sustain heads and sustain segments: never merged, always materialised by the caller. */
	public function pushHold(pn:PreloadedChartNote):Void
	{
		if (pn == null) return;
		fedCount = fedCount + 1;
		out.append(pn);
	}

	/** Finalises: the last representative of every slot still has its count in the slot array. */
	public function finish():ChartNotes
	{
		flushAllDensity();
		return out;
	}
}
