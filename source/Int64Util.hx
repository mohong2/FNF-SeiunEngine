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
 *  - toSaveString() keeps the exact 64-bit value in JSON/save payloads.
 */
class Int64Util
{
    public static inline function toFloat(v:Int64):Float
    {
        var low:Float = v.low;
        if (low < 0) low += 4294967296.0;
        return v.high * 4294967296.0 + low;
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
}