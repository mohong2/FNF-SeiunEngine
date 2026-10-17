package;

using StringTools;

class Highscore
{
    #if (haxe >= "4.0.0")
    public static var songScores:Map<String, haxe.Int64> = new Map();
    public static var songRating:Map<String, Float> = new Map();
    public static var weekScores:Map<String, haxe.Int64> = new Map();
    public static var songSicks:Map<String, haxe.Int64> = new Map();
    public static var songGoods:Map<String, haxe.Int64> = new Map();
    public static var songBads:Map<String, haxe.Int64> = new Map();
    public static var songShits:Map<String, haxe.Int64> = new Map();
    public static var songMisses:Map<String, haxe.Int64> = new Map();
    public static var songMaxCombo:Map<String, haxe.Int64> = new Map();
    #else
    public static var weekScores:Map<String, haxe.Int64> = new Map();
    public static var songRating:Map<String, Float> = new Map();
    public static var songSicks:Map<String, haxe.Int64> = new Map<String, haxe.Int64>();
    public static var songGoods:Map<String, haxe.Int64> = new Map<String, haxe.Int64>();
    public static var songBads:Map<String, haxe.Int64> = new Map<String, haxe.Int64>();
    public static var songShits:Map<String, haxe.Int64> = new Map<String, haxe.Int64>();
    public static var songMisses:Map<String, haxe.Int64> = new Map();
    public static var songMaxCombo:Map<String, haxe.Int64> = new Map();
    #end
    public static var songNoteHit:Map<String, Dynamic> = new Map<String, Dynamic>(); // Array<Array<Array<Float>>>
    public static var songDetails:Map<String, Array<Dynamic>> = new Map<String, Array<Dynamic>>();

    /**
     * FlxSave uses haxe.Serializer. Int64 does not round-trip reliably there (on cpp it may come
     * back as a plain Int for small values or as a cpp::Int64 object for large ones), so the save
     * payload stores each counter as an exact decimal string. loadIntMap() accepts both that new
     * shape and the old Int/Float maps from existing saves.
     */
    static function saveIntMap(fieldName:String, source:Map<String, haxe.Int64>):Void
    {
        var stored:Map<String, String> = new Map();
        for (key => value in source)
            stored.set(key, haxe.Int64.toStr(value));
        Reflect.setField(FlxG.save.data, fieldName, stored);
    }

    static function loadIntMap(fieldName:String, target:Map<String, haxe.Int64>):Void
    {
        var source:Dynamic = Reflect.field(FlxG.save.data, fieldName);
        if (source == null) return;
        target.clear();
        try
        {
            var map:Map<String, Dynamic> = cast source;
            for (key in map.keys())
                target.set(key, Int64Util.fromDynamic(map.get(key)));
            return;
        }
        catch (e:Dynamic) {}

        // Very old backups may store the map as an anonymous object instead of a haxe Map.
        for (key in Reflect.fields(source))
            target.set(key, Int64Util.fromDynamic(Reflect.field(source, key)));
    }

    public static function resetSong(song:String, diff:Int = 0):Void
    {
        var daSong:String = formatSong(song, diff);
        setScore(daSong, 0);
        setRating(daSong, 0);
        setSicks(daSong, 0);
        setGoods(daSong, 0);
        setBads(daSong, 0);
        setShits(daSong, 0);
        setMisses(daSong, 0);
        setMaxCombo(daSong, 0);
    }

    public static function resetWeek(week:String, diff:Int = 0):Void
    {
        var daWeek:String = formatSong(week, diff);
        setWeekScore(daWeek, 0);
    }

    public static function floorDecimal(value:Float, decimals:Int):Float
    {
        if (decimals < 1)
        {
            return Math.floor(value);
        }

        var tempMult:Float = 1;
        for (i in 0...decimals)
        {
            tempMult *= 10;
        }
        var newValue:Float = Math.floor(value * tempMult + 0.0000001);
        return newValue / tempMult;
    }

    public static function saveScore(song:String, score:haxe.Int64 = 0, ?diff:Int = 0, ?rating:Float = -1, ?sicks:haxe.Int64 = -1, ?goods:haxe.Int64 = -1,
        ?bads:haxe.Int64 = -1, ?shits:haxe.Int64 = -1, ?misses:haxe.Int64 = -1, ?maxCombo:haxe.Int64 = -1):Void
    {
        var daSong:String = formatSong(song, diff);

        if (songScores.exists(daSong))
        {
            if (songScores.get(daSong) < score)
            {
                setScore(daSong, score);
                if (rating >= 0) setRating(daSong, rating);
                if (sicks >= 0) setSicks(daSong, sicks);
                if (goods >= 0) setGoods(daSong, goods);
                if (bads >= 0) setBads(daSong, bads);
                if (shits >= 0) setShits(daSong, shits);
                if (misses >= 0) setMisses(daSong, misses);
                if (maxCombo >= 0) setMaxCombo(daSong, maxCombo);
            }
        }
        else
        {
            setScore(daSong, score);
            if (rating >= 0) setRating(daSong, rating);
            if (sicks >= 0) setSicks(daSong, sicks);
            if (goods >= 0) setGoods(daSong, goods);
            if (bads >= 0) setBads(daSong, bads);
            if (shits >= 0) setShits(daSong, shits);
            if (misses >= 0) setMisses(daSong, misses);
            if (maxCombo >= 0) setMaxCombo(daSong, maxCombo);
        }
    }

    public static function saveWeekScore(week:String, score:haxe.Int64 = 0, ?diff:Int = 0):Void
    {
        var daWeek:String = formatSong(week, diff);

        if (weekScores.exists(daWeek))
        {
            if (weekScores.get(daWeek) < score)
                setWeekScore(daWeek, score);
        }
        else
            setWeekScore(daWeek, score);
    }

    static function setKeyHit(song:String, group:Array<Array<Array<Float>>>):Void
    {
        // Reminder that I don't need to format this song, it should come formatted!
        songNoteHit.set(song, group);
        FlxG.save.data.songNoteHit = songNoteHit;
        FlxG.save.flush();
    }

    static function setDetails(song:String, group:Array<Dynamic>):Void
    {
        // Reminder that I don't need to format this song, it should come formatted!
        songDetails.set(song, group);
        FlxG.save.data.songDetails = songDetails;
        FlxG.save.flush();
    }

    /**
     * YOU SHOULD FORMAT SONG WITH formatSong() BEFORE TOSSING IN SONG VARIABLE
     */
    static function setScore(song:String, score:haxe.Int64):Void
    {
        // Reminder that I don't need to format this song, it should come formatted!
        songScores.set(song, score);
        saveIntMap('songScores', songScores);
        FlxG.save.flush();
    }

    static function setWeekScore(week:String, score:haxe.Int64):Void
    {
        // Reminder that I don't need to format this song, it should come formatted!
        weekScores.set(week, score);
        saveIntMap('weekScores', weekScores);
        FlxG.save.flush();
    }

    static function setRating(song:String, rating:Float):Void
    {
        // Reminder that I don't need to format this song, it should come formatted!
        songRating.set(song, rating);
        FlxG.save.data.songRating = songRating;
        FlxG.save.flush();
    }

    public static function formatSong(song:String, diff:Int):String
    {
        return Paths.formatToSongPath(song) + CoolUtil.getDifficultyFilePath(diff);
    }

    public static function getScore(song:String, diff:Int):haxe.Int64
    {
        var daSong:String = formatSong(song, diff);
        if (!songScores.exists(daSong))
            setScore(daSong, 0);

        return songScores.get(daSong);
    }

    public static function getRating(song:String, diff:Int):Float
    {
        var daSong:String = formatSong(song, diff);
        if (!songRating.exists(daSong))
            setRating(daSong, 0);

        return songRating.get(daSong);
    }

    public static function getWeekScore(week:String, diff:Int):haxe.Int64
    {
        var daWeek:String = formatSong(week, diff);
        if (!weekScores.exists(daWeek))
            setWeekScore(daWeek, 0);

        return weekScores.get(daWeek);
    }

    public static function load():Void
    {
        loadIntMap('weekScores', weekScores);
        loadIntMap('songScores', songScores);
        if (FlxG.save.data.songRating != null)
            songRating = FlxG.save.data.songRating;
        loadIntMap('songSicks', songSicks);
        loadIntMap('songGoods', songGoods);
        loadIntMap('songBads', songBads);
        loadIntMap('songShits', songShits);
        loadIntMap('songMisses', songMisses);
        loadIntMap('songMaxCombo', songMaxCombo);
    }

    public static function getSicks(song:String, diff:Int):haxe.Int64
    {
        var daSong:String = formatSong(song, diff);
        if (!songSicks.exists(daSong))
            setSicks(daSong, 0);

        return songSicks.get(daSong);
    }

    public static function setSicks(song:String, sicks:haxe.Int64):Void
    {
        songSicks.set(song, sicks);
        saveIntMap('songSicks', songSicks);
        FlxG.save.flush();
    }

    public static function getGoods(song:String, diff:Int):haxe.Int64
    {
        var daSong:String = formatSong(song, diff);
        if (!songGoods.exists(daSong))
            setGoods(daSong, 0);

        return songGoods.get(daSong);
    }

    public static function setGoods(song:String, goods:haxe.Int64):Void
    {
        songGoods.set(song, goods);
        saveIntMap('songGoods', songGoods);
        FlxG.save.flush();
    }

    public static function getBads(song:String, diff:Int):haxe.Int64
    {
        var daSong:String = formatSong(song, diff);
        if (!songBads.exists(daSong))
            setBads(daSong, 0);

        return songBads.get(daSong);
    }

    public static function setBads(song:String, bads:haxe.Int64):Void
    {
        songBads.set(song, bads);
        saveIntMap('songBads', songBads);
        FlxG.save.flush();
    }

    public static function getShits(song:String, diff:Int):haxe.Int64
    {
        var daSong:String = formatSong(song, diff);
        if (!songShits.exists(daSong))
            setShits(daSong, 0);

        return songShits.get(daSong);
    }

    public static function setShits(song:String, shits:haxe.Int64):Void
    {
        songShits.set(song, shits);
        saveIntMap('songShits', songShits);
        FlxG.save.flush();
    }

    public static function getMisses(song:String, diff:Int):haxe.Int64
    {
        var daSong:String = formatSong(song, diff);
        if (!songMisses.exists(daSong))
            setMisses(daSong, 0);

        return songMisses.get(daSong);
    }

    public static function setMisses(song:String, misses:haxe.Int64):Void
    {
        songMisses.set(song, misses);
        saveIntMap('songMisses', songMisses);
        FlxG.save.flush();
    }

    public static function getMaxCombo(song:String, diff:Int):haxe.Int64
    {
        var daSong:String = formatSong(song, diff);
        if (!songMaxCombo.exists(daSong))
            setMaxCombo(daSong, 0);

        return songMaxCombo.get(daSong);
    }

    public static function setMaxCombo(song:String, maxCombo:haxe.Int64):Void
    {
        songMaxCombo.set(song, maxCombo);
        saveIntMap('songMaxCombo', songMaxCombo);
        FlxG.save.flush();
    }
}