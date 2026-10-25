package;

import haxe.Int64;

/**
 * Shared Int64 helpers for the gameplay counters and the save/replay boundaries.
 *
 * Haxe's Int64 has no implicit conversion to Float/Int, and haxe.Json/haxe.Serializer do not
 * round-trip it as a plain JSON number. Gameplay counters are Int64, but the HUD, rating math,
 * scripts and save files still need a well-defined conversion:
 *  - toFloat() is exact for every integer a Float can hold (up to 2^53);
 *  - fromDynamic() accepts old saves (Int/Float/String) and new string-encoded Int64 values;
 *  - toSaveString() keeps the exact 64-bit value in JSON/save payloads;
 *  - jsonSafe() makes a Dynamic tree serialisable (haxe.Json cannot reflect cpp.Int64);
 *  - toScript() hands Lua/HScript a number for a boxed Int64.
 */
class Int64Util
{
    public static inline function toFloat(v:Int64):Float
    {
        var low:Float = v.low;
        if (low < 0) low += 4294967296.0;
        return v.high * 4294967296.0 + low;
    }

    /**
     * Value handed to Lua / HScript: a boxed Int64 becomes a Float, everything else is untouched.
     *
     * Why only boxed values: hxcpp reflection represents a non-negative Int64 below 2^31 as a
     * plain Int (Type.typeof == TInt), so scripts already see a number and it must stay an Int
     * (turning it into a Float would break array indexing and Int-typed arguments). Negative
     * values and anything >= 2^31 come back as TClass(cpp.Int64); those are the ones Lua's
     * Convert.toLua would push as nil and HScript would treat as a string in arithmetic.
     */
    public static function toScript(value:Dynamic):Dynamic
    {
        if (value == null) return null;
        return switch (Type.typeof(value))
        {
            case TClass(_): Int64.isInt64(value) ? toFloat(cast value) : value;
            default: value;
        }
    }

    public static function fromDynamic(v:Dynamic, ?fallback:Int64 = 0):Int64
    {
        if (v == null) return fallback;
        if (Int64.isInt64(v)) return cast v;
        if (Std.isOfType(v, Int)) return Int64.ofInt(cast v);
        if (Std.isOfType(v, Float)) return Int64.fromFloat(cast v);

        var s:String = Std.string(v);
        if (s == null || s.length == 0) return fallback;
        try return Int64.parseString(s) catch (e:Dynamic) {}
        try return Int64.fromFloat(Std.parseFloat(s)) catch (e:Dynamic) {}
        return fallback;
    }

    public static inline function toSaveString(v:Int64):String
        return Int64.toStr(v);

    /** Convert a value read from JSON (old numeric or new string form) to Int64. */
    public static inline function fromJson(v:Dynamic, ?fallback:Int64 = 0):Int64
        return fromDynamic(v, fallback);

    /**
     * Deep copy of `value` with every Int64 replaced by its numeric value, safe to hand to
     * `haxe.Json.stringify`.
     *
     * Why this exists: on cpp, `haxe.Int64` is the native `cpp.Int64` class. haxe.format.JsonPrinter
     * treats any non-String/Array/Date class as an object and calls `Reflect.fields()` on it; for a
     * native class that returns null, and iterating the null field list throws "Null Object Reference".
     * `Allscore` stores the gameplay counters inside the score entry's `details` array (score,
     * songHits, songMisses, maxCombo are Int64 since the Int64 migration), so serialising a finished
     * run used to throw before the file was written -- at song end, from Lime's audio-completion
     * timer, i.e. outside the crash handler's reach.
     *
     * Numbers restore exactly the pre-Int64 on-disk shape (details were plain JSON numbers before)
     * and every value a human-playable score can reach is exactly representable as a Float. Only
     * the dedicated save fields keep the exact decimal-string form (see toSaveString).
     */
    public static function jsonSafe(value:Dynamic):Dynamic
    {
        if (value == null) return null;
        if (Int64.isInt64(value)) return toFloat(cast value);

        switch (Type.typeof(value))
        {
            case TClass(c):
                if (c == Array)
                {
                    var src:Array<Dynamic> = cast value;
                    var out:Array<Dynamic> = [];
                    out.resize(src.length);
                    for (i in 0...src.length) out[i] = jsonSafe(src[i]);
                    return out;
                }
                // Other classes are not part of the save payload; leave them alone rather than
                // reflecting native types (the exact operation that crashes).
                return value;
            case TObject:
                var src:Dynamic = value;
                var out:Dynamic = {};
                for (field in Reflect.fields(src)) Reflect.setField(out, field, jsonSafe(Reflect.field(src, field)));
                return out;
            default:
                return value;
        }
    }

    /** jsonSafe() for the array-shaped payloads (Allscore details), preserving null. */
    public static function jsonSafeArray(values:Array<Dynamic>):Array<Dynamic>
        return values == null ? null : cast jsonSafe(values);
}
