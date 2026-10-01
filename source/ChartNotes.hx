package;

import Note.PreloadedChartNote;

/**
 * Column storage for one numeric field: hoisted to a single scalar when every note shares the
 * same value, otherwise a packed Float64 column. Charts are extremely repetitive (stepCrochet,
 * hit/miss health, offsets and every string column are usually one value for the whole file),
 * so hoisting is what turns 358 B/note into a few tens of bytes.
 *
 * The column stays scalar until a value actually differs, so a chart that never diverges never
 * allocates its column at all. Backfill on the first divergence keeps this single-pass.
 *
 * Columns grow by doubling, so the same store serves both "pack an existing array" and
 * "append while parsing" -- the second one is what keeps hxcpp's block pool from ever reaching
 * the chart's full size (see ChartNotesData.builder).
 */
@:allow(ChartNotesData)
private class NumCol
{
	var scalar:Float = 0;
	var data:haxe.io.Bytes = null;
	var n:Int = 16;

	public inline function new() {}

	public function reset(capacity:Int):Void
	{
		n = capacity < 16 ? 16 : capacity;
		data = null;
		scalar = 0;
	}

	function grow(need:Int):Void
	{
		var cap:Int = n;
		while (cap <= need) cap <<= 1;
		var next:haxe.io.Bytes = haxe.io.Bytes.alloc(cap << 3);
		if (data != null) next.blit(0, data, 0, n << 3);
		data = next;
		n = cap;
	}

	public function add(i:Int, v:Float):Void
	{
		if (data == null)
		{
			if (i == 0) { scalar = v; return; }
			// NaN != NaN, and NaN is how a null Null<Float> is encoded, so it needs an explicit
			// "both NaN" case or every all-null splash column would allocate 8 B/note for nothing.
			if (v == scalar || (v != v && scalar != scalar)) return;
			if (i >= n) grow(i);
			// grow() only runs when the row is past the current capacity, so the common case (a
			// column that diverges early, e.g. strumTime at row 1) still has data == null here.
			if (data == null) data = haxe.io.Bytes.alloc(n << 3);
			var k:Int = 0;
			while (k < i) { data.setDouble(k << 3, scalar); k++; }
			data.setDouble(i << 3, v);
			return;
		}
		if (i >= n) grow(i);
		data.setDouble(i << 3, v);
	}

	public inline function get(i:Int):Float
		return data == null ? scalar : data.getDouble(i << 3);

	/**
	 * Writes one existing row in place. Materialises the column when it was hoisted, filling the
	 * rows that were already read from the scalar, so every earlier row keeps its value.
	 */
	public function set(i:Int, v:Float):Void
	{
		if (data == null)
		{
			if (v == scalar || (v != v && scalar != scalar)) return;
			if (i >= n) grow(i);
			if (data == null) data = haxe.io.Bytes.alloc(n << 3);
			var k:Int = 0;
			while (k < n) { data.setDouble(k << 3, scalar); k++; }
			data.setDouble(i << 3, v);
			return;
		}
		if (i >= n) grow(i);
		data.setDouble(i << 3, v);
	}

	/** Reorders the column so row k becomes old row idx[k]. A hoisted column needs no work. */
	public function permute(idx:Array<Int>, len:Int):Void
	{
		if (data == null) return;
		var next:haxe.io.Bytes = haxe.io.Bytes.alloc(n << 3);
		for (k in 0...len) next.setDouble(k << 3, data.getDouble(idx[k] << 3));
		data = next;
	}
}

/** Same lazy-hoisting idea for a String column. Index 0xFFFF encodes null. */
@:allow(ChartNotesData)
private class StrCol
{
	static inline var NULL_INDEX:Int = 0xFFFF;

	var scalar:String = null;
	var pool:Array<String> = null;
	var index:haxe.io.Bytes = null;
	var n:Int = 16;

	public inline function new() {}

	public function reset(capacity:Int):Void
	{
		n = capacity < 16 ? 16 : capacity;
		scalar = null;
		pool = null;
		index = null;
	}

	function grow(need:Int):Void
	{
		var cap:Int = n;
		while (cap <= need) cap <<= 1;
		var next:haxe.io.Bytes = haxe.io.Bytes.alloc(cap << 1);
		if (index != null) next.blit(0, index, 0, n << 1);
		index = next;
		n = cap;
	}

	public function add(i:Int, v:String):Void
	{
		if (index == null)
		{
			if (i == 0) { scalar = v; return; }
			if (v == scalar) return;
			// First divergence: the scalar becomes pool entry 0 and every earlier note points at it.
			pool = [scalar];
			if (i >= n) grow(i);
			// See NumCol.add: grow() is a no-op while the row is inside the current capacity.
			if (index == null) index = haxe.io.Bytes.alloc(n << 1);
			var zero:Int = scalar == null ? NULL_INDEX : 0;
			var k:Int = 0;
			while (k < i) { index.setUInt16(k << 1, zero); k++; }
			index.setUInt16(i << 1, intern(v));
			return;
		}
		if (i >= n) grow(i);
		index.setUInt16(i << 1, intern(v));
	}

	function intern(v:String):Int
	{
		var at:Int = pool.indexOf(v);
		if (at >= 0) return at;
		pool.push(v);
		return pool.length - 1;
	}

	public function get(i:Int):String
	{
		if (index == null) return scalar;
		var at:Int = index.getUInt16(i << 1);
		return at == NULL_INDEX ? null : pool[at];
	}

	public function permute(idx:Array<Int>, len:Int):Void
	{
		if (index == null) return;
		var next:haxe.io.Bytes = haxe.io.Bytes.alloc(n << 1);
		for (k in 0...len) next.setUInt16(k << 1, index.getUInt16(idx[k] << 1));
		index = next;
	}
}

/** Fixed-width byte column for small ints (noteData, mania). */
@:allow(ChartNotesData)
private class ByteCol
{
	var data:haxe.io.Bytes = null;
	var bias:Int = 0;
	var n:Int = 16;

	public inline function new(bias:Int) this.bias = bias;

	public function reset(capacity:Int):Void
	{
		n = capacity < 16 ? 16 : capacity;
		data = haxe.io.Bytes.alloc(n);
	}

	function grow(need:Int):Void
	{
		var cap:Int = n;
		while (cap <= need) cap <<= 1;
		var next:haxe.io.Bytes = haxe.io.Bytes.alloc(cap);
		next.blit(0, data, 0, n);
		data = next;
		n = cap;
	}

	public inline function set(i:Int, v:Int):Void
	{
		if (i >= n) grow(i);
		data.set(i, v + bias);
	}

	/** Returns the biased raw byte; callers of mania subtract 1. */
	public inline function raw(i:Int):Int return data.get(i);

	public function permute(idx:Array<Int>, len:Int):Void
	{
		var next:haxe.io.Bytes = haxe.io.Bytes.alloc(n);
		for (k in 0...len) next.set(k, data.get(idx[k]));
		data = next;
	}
}

/** 16 bit flags per note, one bit per Bool field. */
@:allow(ChartNotesData)
private class FlagsCol
{
	var data:haxe.io.Bytes = null;
	var n:Int = 16;

	public inline function new() {}

	public function reset(capacity:Int):Void
	{
		n = capacity < 16 ? 16 : capacity;
		data = haxe.io.Bytes.alloc(n << 1);
	}

	function grow(need:Int):Void
	{
		var cap:Int = n;
		while (cap <= need) cap <<= 1;
		var next:haxe.io.Bytes = haxe.io.Bytes.alloc(cap << 1);
		next.blit(0, data, 0, n << 1);
		data = next;
		n = cap;
	}

	/** Sets or clears one bit. The mask must be applied to the byte that owns the bit: writing
	 *  1<<bit into the low byte truncates anything above bit 7 to zero. */
	public inline function put(i:Int, bit:Int, v:Bool):Void
	{
		if (i >= n) grow(i);
		var at:Int = i << 1;
		var pos:Int = bit < 8 ? at : at + 1;
		var mask:Int = 1 << (bit & 7);
		var b:Int = data.get(pos);
		data.set(pos, v ? (b | mask) : (b & ~mask));
	}

	public inline function set(i:Int, bit:Int, v:Bool):Void
	{
		if (v) put(i, bit, true);
	}

	/**
	 * Writes all 16 bits in one go. append() used to call set() 14 times per note, i.e. 14
	 * read-modify-write pairs on the same two bytes (~176M of them on a dense chart); this is one
	 * pair for the whole flag word and is the single biggest remaining cost in the load loop.
	 */
	public inline function pack(i:Int, v:Int):Void
	{
		if (i >= n) grow(i);
		var at:Int = i << 1;
		data.set(at, v & 0xFF);
		data.set(at + 1, (v >> 8) & 0xFF);
	}

	public inline function get(i:Int, bit:Int):Bool
	{
		var at:Int = i << 1;
		var b:Int = bit < 8 ? data.get(at) : data.get(at + 1);
		return (b & (1 << (bit & 7))) != 0;
	}

	public function permute(idx:Array<Int>, len:Int):Void
	{
		var next:haxe.io.Bytes = haxe.io.Bytes.alloc(n << 1);
		for (k in 0...len)
		{
			var at:Int = idx[k] << 1;
			next.set(k << 1, data.get(at));
			next.set((k << 1) + 1, data.get(at + 1));
		}
		data = next;
	}
}

/**
 * Compact, column-oriented storage for a chart's PreloadedChartNote list.
 *
 * Stored data is ~40 B/note instead of 358 B/note on real charts, and hxcpp's block pool grows to
 * the largest live set it ever sees and then keeps it reserved, so this is the difference between
 * a ~4.5 GB mid-load spike (kept for the whole song) and a ~0.6 GB one.
 *
 * Two ways in:
 *   - pack(array):            one-shot conversion of an existing DTO array;
 *   - builder(n) + append():  streaming build, so the DTO array never exists at all.
 * A streaming build produces rows in file order, so sortByStrumTime() finishes the job.
 *
 * The public face is ChartNotes, an abstract with @:arrayAccess, so existing `unspawnNotes[i]`
 * reads keep working. Reads return a fresh DTO, which matches Array semantics exactly: a returned
 * object is never aliased by a later read. Only wasHit is real stored state and it goes through
 * setWasHit, because a write to a returned DTO cannot be written back.
 */
class ChartNotesData
{
	static var DEFAULTS:PreloadedChartNote = {
		strumTime: 0, sustainLength: 0, parentST: 0, parentSL: 0, stepCrochet: 0,
		hitHealth: 0.023, missHealth: 0.0475, multSpeed: 1, multAlpha: 1, noteDensity: 1,
		offsetX: 0, offsetY: 0,
		noteSplashHue: null, noteSplashSat: null, noteSplashBrt: null,
		noteType: '', animSuffix: '', noteskin: '', texture: '', noteSplashTexture: null,
		noteData: 0, mania: -1,
		mustPress: false, oppNote: false, gfNote: false, noAnimation: false, noMissAnimation: false,
		isSustainNote: false, isSustainEnd: false, hitCausesMiss: false, ignoreNote: false,
		blockHit: false, lowPriority: false, wasHit: false, noteSplashDisabled: false, hitsoundDisabled: false
	};

	public var length(default, null):Int = 0;

	var fStrumTime:NumCol = new NumCol();
	var fSustainLength:NumCol = new NumCol();
	var fParentST:NumCol = new NumCol();
	var fParentSL:NumCol = new NumCol();
	var fStepCrochet:NumCol = new NumCol();
	var fHitHealth:NumCol = new NumCol();
	var fMissHealth:NumCol = new NumCol();
	var fMultSpeed:NumCol = new NumCol();
	var fMultAlpha:NumCol = new NumCol();
	var fNoteDensity:NumCol = new NumCol();
	var fOffsetX:NumCol = new NumCol();
	var fOffsetY:NumCol = new NumCol();
	var fSplashHue:NumCol = new NumCol();
	var fSplashSat:NumCol = new NumCol();
	var fSplashBrt:NumCol = new NumCol();

	var sNoteType:StrCol = new StrCol();
	var sAnimSuffix:StrCol = new StrCol();
	var sNoteskin:StrCol = new StrCol();
	var sTexture:StrCol = new StrCol();
	var sSplashTexture:StrCol = new StrCol();

	var iNoteData:ByteCol = new ByteCol(0);
	var iMania:ByteCol = new ByteCol(1);
	var flags:FlagsCol = new FlagsCol();

	public function new() {}

	// Dynamic: the four column classes only share reset/permute, and this saves a cast per column.
	inline function columns():Array<Dynamic>
	{
		return [fStrumTime, fSustainLength, fParentST, fParentSL, fStepCrochet, fHitHealth, fMissHealth,
			fMultSpeed, fMultAlpha, fNoteDensity, fOffsetX, fOffsetY, fSplashHue, fSplashSat, fSplashBrt,
			sNoteType, sAnimSuffix, sNoteskin, sTexture, sSplashTexture, iNoteData, iMania, flags];
	}

	/**
	 * Streaming build. `estimated` is only a starting capacity (the caller usually does not know
	 * the final representative count); every column doubles as it fills.
	 */
	public static function builder(estimated:Int):ChartNotesData
	{
		var d = new ChartNotesData();
		var cap:Int = estimated < 16 ? 16 : estimated;
		for (c in d.columns()) c.reset(cap);
		return d;
	}

	/** Appends one note. Rows must arrive in order, starting at 0. */
	public function append(p:PreloadedChartNote):Void
	{
		if (p == null) p = DEFAULTS;
		var i:Int = length;
		length = i + 1;
		fStrumTime.add(i, p.strumTime);
		fSustainLength.add(i, p.sustainLength);
		fParentST.add(i, p.parentST);
		fParentSL.add(i, p.parentSL);
		fStepCrochet.add(i, p.stepCrochet);
		fHitHealth.add(i, p.hitHealth);
		fMissHealth.add(i, p.missHealth);
		fMultSpeed.add(i, p.multSpeed);
		fMultAlpha.add(i, p.multAlpha);
		fNoteDensity.add(i, p.noteDensity);
		fOffsetX.add(i, p.offsetX);
		fOffsetY.add(i, p.offsetY);
		// null survives as NaN: these are hue/sat/brt and never legitimately NaN.
		fSplashHue.add(i, p.noteSplashHue == null ? Math.NaN : p.noteSplashHue);
		fSplashSat.add(i, p.noteSplashSat == null ? Math.NaN : p.noteSplashSat);
		fSplashBrt.add(i, p.noteSplashBrt == null ? Math.NaN : p.noteSplashBrt);
		sNoteType.add(i, p.noteType);
		sAnimSuffix.add(i, p.animSuffix);
		sNoteskin.add(i, p.noteskin);
		sTexture.add(i, p.texture);
		sSplashTexture.add(i, p.noteSplashTexture);
		iNoteData.set(i, p.noteData);
		iMania.set(i, p.mania);
		// One flag word, one write. The bit order must match get(i, bit).
		var m:Int = 0;
		if (p.mustPress) m |= 1;
		if (p.oppNote) m |= 1 << 1;
		if (p.gfNote) m |= 1 << 2;
		if (p.noAnimation) m |= 1 << 3;
		if (p.noMissAnimation) m |= 1 << 4;
		if (p.isSustainNote) m |= 1 << 5;
		if (p.isSustainEnd) m |= 1 << 6;
		if (p.hitCausesMiss) m |= 1 << 7;
		if (p.ignoreNote) m |= 1 << 8;
		if (p.blockHit) m |= 1 << 9;
		if (p.lowPriority) m |= 1 << 10;
		if (p.wasHit) m |= 1 << 11;
		if (p.noteSplashDisabled) m |= 1 << 12;
		if (p.hitsoundDisabled) m |= 1 << 13;
		flags.pack(i, m);
	}

	/** One-shot conversion of an existing DTO array. Scratch DTOs from get() are never stored. */
	public static function pack(src:Array<PreloadedChartNote>):ChartNotesData
	{
		var n:Int = src == null ? 0 : src.length;
		var d = builder(n);
		for (i in 0...n) d.append(src[i]);
		return d;
	}

	/**
	 * Sorts every column by strumTime, in place.
	 *
	 * This is what lets the streaming build skip re-sorting a DTO array: the keys come from one
	 * column and the resulting permutation is applied to all of them. Ties keep their original
	 * relative order, matching a stable sort over the array.
	 */
	public function sortByStrumTime():Void
	{
		if (length < 2) return;
		var order:Array<Int> = [];
		order.resize(length);
		for (i in 0...length) order[i] = i;
		var key:NumCol = fStrumTime;
		order.sort(function(a:Int, b:Int):Int {
			var x:Float = key.get(a);
			var y:Float = key.get(b);
			if (x < y) return -1;
			if (x > y) return 1;
			return a - b;
		});
		for (c in columns()) c.permute(order, length);
	}

	public function get(i:Int):PreloadedChartNote
	{
		if (i < 0 || i >= length) return null;
		var hue:Float = fSplashHue.get(i);
		var sat:Float = fSplashSat.get(i);
		var brt:Float = fSplashBrt.get(i);
		return {
			strumTime: fStrumTime.get(i),
			sustainLength: fSustainLength.get(i),
			parentST: fParentST.get(i),
			parentSL: fParentSL.get(i),
			stepCrochet: fStepCrochet.get(i),
			hitHealth: fHitHealth.get(i),
			missHealth: fMissHealth.get(i),
			multSpeed: fMultSpeed.get(i),
			multAlpha: fMultAlpha.get(i),
			noteDensity: fNoteDensity.get(i),
			offsetX: fOffsetX.get(i),
			offsetY: fOffsetY.get(i),
			noteSplashHue: Math.isNaN(hue) ? null : hue,
			noteSplashSat: Math.isNaN(sat) ? null : sat,
			noteSplashBrt: Math.isNaN(brt) ? null : brt,
			noteType: sNoteType.get(i),
			animSuffix: sAnimSuffix.get(i),
			noteskin: sNoteskin.get(i),
			texture: sTexture.get(i),
			noteSplashTexture: sSplashTexture.get(i),
			noteData: iNoteData.raw(i),
			mania: iMania.raw(i) - 1,
			mustPress: flags.get(i, 0),
			oppNote: flags.get(i, 1),
			gfNote: flags.get(i, 2),
			noAnimation: flags.get(i, 3),
			noMissAnimation: flags.get(i, 4),
			isSustainNote: flags.get(i, 5),
			isSustainEnd: flags.get(i, 6),
			hitCausesMiss: flags.get(i, 7),
			ignoreNote: flags.get(i, 8),
			blockHit: flags.get(i, 9),
			lowPriority: flags.get(i, 10),
			wasHit: flags.get(i, 11),
			noteSplashDisabled: flags.get(i, 12),
			hitsoundDisabled: flags.get(i, 13)
		};
	}

	/** Column-level reads/writes. The turbo fold increments a representative's noteDensity long
	 *  after it was appended, and a write through a get() DTO cannot be written back. */
	public inline function noteDensityAt(i:Int):Float
		return (i >= 0 && i < length) ? fNoteDensity.get(i) : 0;

	public inline function setNoteDensity(i:Int, v:Float):Void
	{
		if (i < 0 || i >= length) return;
		fNoteDensity.set(i, v);
	}

	public inline function strumTimeAt(i:Int):Float
		return (i >= 0 && i < length) ? fStrumTime.get(i) : 0;

	/** isSustainNote or sustainLength > 0, without materialising a DTO per row. */
	public function hasHolds():Bool
	{
		for (i in 0...length)
		{
			if (flags.get(i, 5) || fSustainLength.get(i) > 0) return true;
		}
		return false;
	}

	/** Legacy array bridge for the paths that still need a real Array (non-streaming turbo fold). */
	public function toArray():Array<PreloadedChartNote>
	{
		var a:Array<PreloadedChartNote> = [];
		a.resize(length);
		for (i in 0...length) a[i] = get(i);
		return a;
	}

	public inline function getWasHit(i:Int):Bool
		return i >= 0 && i < length && flags.get(i, 11);

	public inline function setWasHit(i:Int, v:Bool):Void
	{
		if (i < 0 || i >= length) return;
		flags.put(i, 11, v);
	}
}

/**
 * The public face of ChartNotesData, shaped so the existing `unspawnNotes[i]` / `unspawnNotes.length`
 * call sites keep compiling unchanged.
 */
@:forward(length)
abstract ChartNotes(ChartNotesData)
{
	inline function new(d:ChartNotesData) this = d;

	@:from public static inline function fromArray(a:Array<PreloadedChartNote>):ChartNotes
		return new ChartNotes(ChartNotesData.pack(a));

	/** Empty store for "no chart loaded"; also how a song teardown drops every column at once. */
	public static inline function empty():ChartNotes return new ChartNotes(new ChartNotesData());

	/** Streaming builder: append notes as they are parsed, then call sortByStrumTime(). */
	public static inline function builder(estimated:Int):ChartNotes
		return new ChartNotes(ChartNotesData.builder(estimated));

	public inline function append(p:PreloadedChartNote):Void this.append(p);
	public inline function sortByStrumTime():Void this.sortByStrumTime();

	@:arrayAccess public inline function at(i:Int):PreloadedChartNote return this.get(i);

	public inline function noteDensityAt(i:Int):Float return this.noteDensityAt(i);
	public inline function setNoteDensity(i:Int, v:Float):Void this.setNoteDensity(i, v);
	public inline function strumTimeAt(i:Int):Float return this.strumTimeAt(i);
	public inline function hasHolds():Bool return this.hasHolds();
	public inline function toArray():Array<PreloadedChartNote> return this.toArray();

	public inline function getWasHit(i:Int):Bool return this.getWasHit(i);
	public inline function setWasHit(i:Int, v:Bool):Void this.setWasHit(i, v);

	public function iterator():Iterator<PreloadedChartNote>
	{
		var self:ChartNotesData = this;
		var i:Int = 0;
		return {
			hasNext: function() return i < self.length,
			next: function() return self.get(i++)
		};
	}
}
