package;

import Note.PreloadedChartNote;

/**
 * Counting bucket sort for very large note arrays (streaming chart load only).
 *
 * Array.sort needs ~2.8s for 11.8M notes on hxcpp and gains nothing from nearly
 * sorted input. Here notes are bucketed by strumTime, which is O(n) and leaves the
 * buckets ordered because the bucket index is a monotonic function of the key;
 * each roughly 256-entry bucket is then sorted on its own.
 *
 * Equivalence with Array.sort is checked by tools/online_probe/ChartSortProbe
 * (11.8M notes, identical strumTime sequence). Like Array.sort, the relative order
 * of equal strumTimes is not guaranteed.
 *
 * The full-parse path (charts under 64MB) keeps using Array.sort.
 */
class ChartSort
{
	/** Rough number of notes per bucket. */
	static inline final BUCKET_TARGET:Int = 256;
	/** Safety cap so a wild time range cannot blow up the counts array. */
	static inline final MAX_BUCKETS:Int = 1 << 21;

	/** Ascending by strumTime. Callers must have removed null slots already. */
	public static function sortPreloadedNotes(notes:Array<PreloadedChartNote>):Void
	{
		var n:Int = notes.length;
		if (n < 2) return;

		var minV:Float = notes[0].strumTime;
		var maxV:Float = minV;
		for (i in 1...n)
		{
			var v:Float = notes[i].strumTime;
			if (v < minV) minV = v;
			else if (v > maxV) maxV = v;
		}
		var span:Float = maxV - minV;
		// NaN / all-equal / infinite range: fall back so the result is always valid.
		if (!(span > 0) || !Math.isFinite(span))
		{
			sortFallback(notes);
			return;
		}

		var buckets:Int = Std.int(n / BUCKET_TARGET);
		if (buckets < 1) buckets = 1;
		if (buckets > MAX_BUCKETS) buckets = MAX_BUCKETS;
		var scale:Float = buckets / span;

		// 1) count (stable: items are scattered in their original order)
		var counts:Array<Int> = [for (i in 0...buckets + 1) 0];
		for (i in 0...n)
		{
			var bi:Int = Std.int((notes[i].strumTime - minV) * scale);
			if (bi >= buckets) bi = buckets - 1;
			else if (bi < 0) bi = 0;
			counts[bi + 1]++;
		}
		for (i in 1...counts.length) counts[i] += counts[i - 1];

		// 2) scatter into bucket ranges
		var tmp:Array<PreloadedChartNote> = notes.copy();
		var pos:Array<Int> = counts.copy();
		for (i in 0...n)
		{
			var pn:PreloadedChartNote = notes[i];
			var bi:Int = Std.int((pn.strumTime - minV) * scale);
			if (bi >= buckets) bi = buckets - 1;
			else if (bi < 0) bi = 0;
			tmp[pos[bi]] = pn;
			pos[bi]++;
		}
		pos = null;

		// 3) sort each bucket (scratch is reused instead of allocated per bucket)
		var scratch:Array<PreloadedChartNote> = [];
		for (bi in 0...buckets)
		{
			var s:Int = counts[bi];
			var e:Int = counts[bi + 1];
			var m:Int = e - s;
			if (m < 2) continue;
			scratch.resize(0);
			for (i in s...e) scratch.push(tmp[i]);
			scratch.sort(cmpStrumTime);
			for (i in 0...m) tmp[s + i] = scratch[i];
		}

		for (i in 0...n) notes[i] = tmp[i];
	}

	static function cmpStrumTime(a:PreloadedChartNote, b:PreloadedChartNote):Int
		return (a.strumTime < b.strumTime) ? -1 : ((a.strumTime > b.strumTime) ? 1 : 0);

	/** Fallback for a degenerate time range. */
	static function sortFallback(notes:Array<PreloadedChartNote>):Void
	{
		notes.sort(function(a, b) {
			if (a == null || b == null) return 0;
			return (a.strumTime < b.strumTime) ? -1 : ((a.strumTime > b.strumTime) ? 1 : 0);
		});
	}
}
