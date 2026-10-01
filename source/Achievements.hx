package;

import flixel.FlxSprite;
import flixel.text.FlxText;
import flixel.group.FlxSpriteGroup;
import flixel.tweens.FlxTween;
import flixel.util.FlxColor;
import haxe.Json;
#if LUA_ALLOWED
import llua.Lua;
import llua.State;
#end
import Paths;
import CoolUtil;
#if MODS_ALLOWED
import sys.io.File;
import sys.FileSystem;
#end

typedef Achievement =
{
	var name:String;
	var description:String;
	@:optional var hidden:Bool;
	@:optional var maxScore:Float;
	@:optional var maxDecimals:Int;

	//handled automatically, ignore these two
	@:optional var mod:String;
	@:optional var ID:Int;
}

/**
 * SeiunEngine 成就类。
 *
 * 这里同时兼容：
 * - 旧版 Seiun 的 `achievementsStuff` / `achievementsMap` / `henchmenDeath` / `AchievementObject` 弹窗；
 * - Psych Engine 0.7.3 的 `Achievement` map、分数、解锁列表、`achievements.json` 加载和 Lua 回调。
 */
class Achievements {

	// ==================== 旧版 Seiun 兼容 ====================

	public static function getAchievementsStuff():Array<Dynamic> {
		Language.load();
		return [
			//Name, Description, Achievement save tag, Hidden achievement
			["Freaky on a Friday Night",    Language.get("friday_night_play", "Play on a Friday... Night."),                        'friday_night_play',     true],
			["She Calls Me Daddy Too",      Language.get("week1_nomiss", "Beat Week 1 on Hard with no Misses."),                'week1_nomiss',         false],
			["No More Tricks",              Language.get("week2_nomiss", "Beat Week 2 on Hard with no Misses."),                'week2_nomiss',         false],
			["Call Me The Hitman",          Language.get("week3_nomiss", "Beat Week 3 on Hard with no Misses."),                'week3_nomiss',         false],
			["Lady Killer",                 Language.get("week4_nomiss", "Beat Week 4 on Hard with no Misses."),                'week4_nomiss',         false],
			["Missless Christmas",          Language.get("week5_nomiss", "Beat Week 5 on Hard with no Misses."),                'week5_nomiss',         false],
			["Highscore!!",                 Language.get("week6_nomiss", "Beat Week 6 on Hard with no Misses."),                'week6_nomiss',         false],
			["God Effing Damn It!",         Language.get("week7_nomiss", "Beat Week 7 on Hard with no Misses."),                'week7_nomiss',         false],
			["What a Funkin' Disaster!",    Language.get("ur_bad", "Complete a Song with a rating lower than 20%."),    'ur_bad',               false],
			["You have a good one(phigros)",Language.get("line_blue", "The song is just a good 。"),            'line_blue',               false],
			["Perfectionist",               Language.get("ur_good", "Complete a Song with a rating of 100%."),            'ur_good',               false],
			["Roadkill Enthusiast",         Language.get("roadkill_enthusiast", "Watch the Henchmen die over 100 times."),            'roadkill_enthusiast', false],
			["Oversinging Much...?",        Language.get("oversinging", "Hold down a note for 10 seconds."),                    'oversinging',          false],
			["Hyperactive",                 Language.get("hype", "Finish a Song without going Idle."),                'hype',                  false],
			["Just the Two of Us",          Language.get("two_keys", "Finish a Song pressing only two keys."),            'two_keys',              false],
			["Toaster Gamer",               Language.get("toastie", "Have you tried to run the game on a toaster?"),    'toastie',              false],
			["Debugger",                    Language.get("debugger", "Beat the \"Test\" Stage from the Chart Editor."), 'debugger',               true]
		];
	}

	public static var achievementsStuff(get, never):Array<Dynamic>;
	private static function get_achievementsStuff():Array<Dynamic> {
		return getAchievementsStuff();
	}

	public static var achievementsMap:Map<String, Bool> = new Map<String, Bool>();
	public static var henchmenDeath:Int = 0;

	// ==================== 0.7.3 兼容 ====================

	public static var achievements:Map<String, Achievement> = new Map<String, Achievement>();
	public static var variables:Map<String, Float> = [];
	public static var achievementsUnlocked:Array<String> = [];
	private static var _firstLoad:Bool = true;

	static var _sortID = 0;
	static var _originalLength = -1;
	static var _lastUnlock:Int = -999;

	public static function init()
	{
		createAchievement('friday_night_play',		{name: "Freaky on a Friday Night", description: "Play on a Friday... Night.", hidden: true});
		createAchievement('week1_nomiss',			{name: "She Calls Me Daddy Too", description: "Beat Week 1 on Hard with no Misses."});
		createAchievement('week2_nomiss',			{name: "No More Tricks", description: "Beat Week 2 on Hard with no Misses."});
		createAchievement('week3_nomiss',			{name: "Call Me The Hitman", description: "Beat Week 3 on Hard with no Misses."});
		createAchievement('week4_nomiss',			{name: "Lady Killer", description: "Beat Week 4 on Hard with no Misses."});
		createAchievement('week5_nomiss',			{name: "Missless Christmas", description: "Beat Week 5 on Hard with no Misses."});
		createAchievement('week6_nomiss',			{name: "Highscore!!", description: "Beat Week 6 on Hard with no Misses."});
		createAchievement('week7_nomiss',			{name: "God Effing Damn It!", description: "Beat Week 7 on Hard with no Misses."});
		createAchievement('ur_bad',					{name: "What a Funkin' Disaster!", description: "Complete a Song with a rating lower than 20%."});
		createAchievement('line_blue',				{name: "You have a good one(phigros)", description: "The song is just a good 。"});
		createAchievement('ur_good',				{name: "Perfectionist", description: "Complete a Song with a rating of 100%."});
		createAchievement('roadkill_enthusiast',	{name: "Roadkill Enthusiast", description: "Watch the Henchmen die over 100 times.", maxScore: 50, maxDecimals: 0});
		createAchievement('oversinging', 			{name: "Oversinging Much...?", description: "Sing for 10 seconds without going back to Idle."});
		createAchievement('hype',					{name: "Hyperactive", description: "Finish a Song without going back to Idle."});
		createAchievement('two_keys',				{name: "Just the Two of Us", description: "Finish a Song pressing only two keys."});
		createAchievement('toastie',				{name: "Toaster Gamer", description: "Have you tried to run the game on a toaster?"});
		createAchievement('debugger',				{name: "Debugger", description: "Beat the \"Test\" Stage from the Chart Editor.", hidden: true});

		_originalLength = _sortID + 1;
	}

	public static function get(name:String):Achievement
		return achievements.get(name);

	public static function exists(name:String):Bool
		return achievements.exists(name);

	public static function load():Void
	{
		if(!_firstLoad) return;

		if(_originalLength < 0) init();

		if(FlxG.save.data != null) {
			AchievementSave.load(FlxG.save.data, achievementsUnlocked, variables);
			_firstLoad = false;
		}

		// achievementsMap is only a view over achievementsUnlocked
		AchievementSave.rebuildMap(achievementsUnlocked, achievementsMap);
	}

	public static function save():Void
	{
		if (FlxG.save.data == null) return;
		AchievementSave.save(FlxG.save.data, achievementsUnlocked, achievementsMap, variables);
	}

	public static function getScore(name:String):Float
		return _scoreFunc(name, 0);

	public static function setScore(name:String, value:Float, saveIfNotUnlocked:Bool = true):Float
		return _scoreFunc(name, 1, value, saveIfNotUnlocked);

	public static function addScore(name:String, value:Float = 1, saveIfNotUnlocked:Bool = true):Float
		return _scoreFunc(name, 2, value, saveIfNotUnlocked);

	//mode 0 = get, 1 = set, 2 = add
	static function _scoreFunc(name:String, mode:Int = 0, addOrSet:Float = 1, saveIfNotUnlocked:Bool = true):Float
	{
		if(!variables.exists(name))
			variables.set(name, 0);

		if(achievements.exists(name))
		{
			var achievement:Achievement = achievements.get(name);
			if(achievement.maxScore < 1) return -1;

			if(achievementsUnlocked.contains(name)) return achievement.maxScore;

			var val = addOrSet;
			switch(mode)
			{
				case 0: return variables.get(name); //get
				case 2: val += variables.get(name); //add
			}

			if(val >= achievement.maxScore)
			{
				unlock(name);
				val = achievement.maxScore;
			}
			variables.set(name, val);

			Achievements.save();
			if(saveIfNotUnlocked || val >= achievement.maxScore) FlxG.save.flush();
			return val;
		}
		return -1;
	}

	public static function unlock(name:String, autoStartPopup:Bool = true):String {
		if(!achievements.exists(name))
		{
			FlxG.log.error('Achievement "$name" does not exists!');
			return null;
		}

		if(Achievements.isUnlocked(name)) return null;

		trace('Completed achievement "$name"');
		achievementsUnlocked.push(name);
		achievementsMap.set(name, true);

		var time:Int = openfl.Lib.getTimer();
		if(Math.abs(time - _lastUnlock) >= 100)
		{
			FlxG.sound.play(Paths.sound('confirmMenu'), 0.5);
			_lastUnlock = time;
		}

		Achievements.save();
		FlxG.save.flush();

		if(autoStartPopup) startPopup(name);
		return name;
	}

	inline public static function isUnlocked(name:String)
		return achievementsUnlocked.contains(name) || achievementsMap.exists(name);

	public static function startPopup(achieve:String, endFunc:Void->Void = null) {
		var pop:AchievementObject = new AchievementObject(achieve);
		if(endFunc != null) pop.onFinish = endFunc;
		if (PlayState.instance != null)
			PlayState.instance.add(pop);
		else if (FlxG.state != null)
			FlxG.state.add(pop);
	}

	public static function createAchievement(name:String, data:Achievement, ?mod:String = null)
	{
		data.ID = _sortID;
		data.mod = mod;
		achievements.set(name, data);
		_sortID++;
	}

	#if MODS_ALLOWED
	public static function reloadList()
	{
		if((_sortID + 1) > _originalLength)
			for (key => value in achievements)
				if(value.mod != null)
					achievements.remove(key);

		_sortID = _originalLength - 1;

		var modLoaded:String = backend.Mods.currentModDirectory;
		backend.Mods.currentModDirectory = '';
		loadAchievementJson(Paths.mods('data/achievements.json'));
		for (mod in backend.Mods.parseList().enabled)
		{
			backend.Mods.currentModDirectory = mod;
			loadAchievementJson(Paths.mods('$mod/data/achievements.json'));
		}
		backend.Mods.currentModDirectory = modLoaded;
	}

	inline static function loadAchievementJson(path:String, addMods:Bool = true)
	{
		var retVal:Array<Dynamic> = null;
		if(FileSystem.exists(path)) {
			try {
				var rawJson:String = File.getContent(path).trim();
				if(rawJson != null && rawJson.length > 0) retVal = tjson.TJSON.parse(rawJson);

				if(addMods && retVal != null)
				{
					for (i in 0...retVal.length)
					{
						var achieve:Dynamic = retVal[i];
						if(achieve == null) continue;

						var key:String = achieve.save;
						if(key == null || key.trim().length < 1) continue;
						key = key.trim();
						if(achievements.exists(key)) continue;

						createAchievement(key, achieve, backend.Mods.currentModDirectory);
					}
				}
			} catch(e:Dynamic) {
				trace('Error loading achievements.json: $e');
			}
		}
		return retVal;
	}
	#end

	// ==================== 旧版 Seiun API 适配 ====================

	public static function loadAchievements():Void {
		load();
		if(FlxG.save.data != null) {
			if(henchmenDeath == 0 && FlxG.save.data.henchmenDeath != null) {
				henchmenDeath = FlxG.save.data.henchmenDeath;
			}
		}
	}

	public static function unlockAchievement(name:String):Void {
		if(!achievements.exists(name)) {
			// legacy callers may unlock a name that has no 0.7.3 entry yet
			achievementsMap.set(name, true);
			if(!achievementsUnlocked.contains(name)) achievementsUnlocked.push(name);
			FlxG.log.add('Completed achievement "' + name +'"');
			FlxG.sound.play(Paths.sound('confirmMenu'), 0.7);
			save();
			FlxG.save.flush();
			return;
		}
		unlock(name, true);
	}

	/** Records an unlock whose popup the caller starts itself; persists immediately. */
	public static function markUnlocked(name:String):Bool {
		if (!AchievementSave.record(achievementsUnlocked, achievementsMap, name)) return false;
		save();
		FlxG.save.flush();
		return true;
	}

	public static function isAchievementUnlocked(name:String):Bool {
		return isUnlocked(name);
	}

	public static function getAchievementIndex(name:String):Int {
		for (i in 0...achievementsStuff.length) {
			if(achievementsStuff[i][2] == name) {
				return i;
			}
		}
		return -1;
	}

	#if LUA_ALLOWED
	public static function addLuaCallbacks(lua:State)
	{
		Lua_helper.add_callback(lua, "getAchievementScore", function(name:String):Float
		{
			if(!achievements.exists(name))
			{
				trace('getAchievementScore: Couldnt find achievement: $name');
				return -1;
			}
			return getScore(name);
		});
		// 1.0.4 把默认 value 从 1 改成 0; 0.6.3/0.7.3 保持 1。
		Lua_helper.add_callback(lua, "setAchievementScore", function(name:String, ?value:Null<Float> = null, ?saveIfNotUnlocked:Bool = true):Float
		{
			if(value == null) value = backend.CompatEngine.defaultAchievementScore();
			if(!achievements.exists(name))
			{
				trace('setAchievementScore: Couldnt find achievement: $name');
				return -1;
			}
			return setScore(name, value, saveIfNotUnlocked);
		});
		Lua_helper.add_callback(lua, "addAchievementScore", function(name:String, ?value:Float = 1, ?saveIfNotUnlocked:Bool = true):Float
		{
			if(!achievements.exists(name))
			{
				trace('addAchievementScore: Couldnt find achievement: $name');
				return -1;
			}
			return addScore(name, value, saveIfNotUnlocked);
		});
		Lua_helper.add_callback(lua, "unlockAchievement", function(name:String):Dynamic
		{
			if(!achievements.exists(name))
			{
				trace('unlockAchievement: Couldnt find achievement: $name');
				return null;
			}
			return unlock(name);
		});
		Lua_helper.add_callback(lua, "isAchievementUnlocked", function(name:String):Dynamic
		{
			if(!achievements.exists(name))
			{
				trace('isAchievementUnlocked: Couldnt find achievement: $name');
				return null;
			}
			return isUnlocked(name);
		});
		Lua_helper.add_callback(lua, "achievementExists", function(name:String) return achievements.exists(name));
	}
	#end
}

class AttachedAchievement extends FlxSprite {
	public var sprTracker:FlxSprite;
	private var tag:String;
	public function new(x:Float = 0, y:Float = 0, name:String) {
		super(x, y);
		changeAchievement(name);
		antialiasing = ClientPrefs.data.globalAntialiasing;
	}

	public function changeAchievement(tag:String) {
		this.tag = tag;
		reloadAchievementImage();
	}

	public function reloadAchievementImage() {
		if(Achievements.isAchievementUnlocked(tag)) {
			loadGraphic(Paths.image('achievements/' + tag));
		} else {
			loadGraphic(Paths.image('achievements/lockedachievement'));
		}
		scale.set(0.7, 0.7);
		updateHitbox();
	}

	override function update(elapsed:Float) {
		if (sprTracker != null)
			setPosition(sprTracker.x - 130, sprTracker.y + 25);

		super.update(elapsed);
	}
}

class AchievementObject extends FlxSpriteGroup {
	public var onFinish:Void->Void = null;
	var alphaTween:FlxTween;
	public function new(name:String, ?camera:FlxCamera = null)
	{
		super(x, y);
		Language.load();

		ClientPrefs.saveSettings();
		var id:Int = Achievements.getAchievementIndex(name);
		var achievementBG:FlxSprite = new FlxSprite(60, 50).makeGraphic(420, 120, FlxColor.BLACK);
		achievementBG.scrollFactor.set();

		var achievementIcon:FlxSprite = new FlxSprite(achievementBG.x + 10, achievementBG.y + 10).loadGraphic(Paths.image('achievements/' + name));
		achievementIcon.scrollFactor.set();
		achievementIcon.setGraphicSize(Std.int(achievementIcon.width * (2 / 3)));
		achievementIcon.updateHitbox();
		achievementIcon.antialiasing = ClientPrefs.data.globalAntialiasing;

		var achievementName:FlxText = new FlxText(achievementIcon.x + achievementIcon.width + 20, achievementIcon.y + 16, 280, Achievements.achievementsStuff[id][0], 16);
		achievementName.setFormat(Paths.font("vcr.ttf"), 16, FlxColor.WHITE, LEFT);
		achievementName.scrollFactor.set();

		var achievementText:FlxText = new FlxText(achievementName.x, achievementName.y + 32, 280, Achievements.achievementsStuff[id][1], 16);
		achievementText.setFormat(Paths.font("vcr.ttf"), 16, FlxColor.WHITE, LEFT);
		achievementText.scrollFactor.set();

		add(achievementBG);
		add(achievementName);
		add(achievementText);
		add(achievementIcon);

		var cam:Array<FlxCamera> = FlxG.cameras.list;
		if(camera != null) {
			cam = [camera];
		}
		alpha = 0;
		achievementBG.cameras = cam;
		achievementName.cameras = cam;
		achievementText.cameras = cam;
		achievementIcon.cameras = cam;
		alphaTween = FlxTween.tween(this, {alpha: 1}, 0.5, {onComplete: function (twn:FlxTween) {
			alphaTween = FlxTween.tween(this, {alpha: 0}, 0.5, {
				startDelay: 2.5,
				onComplete: function(twn:FlxTween) {
					alphaTween = null;
					remove(this);
					if(onFinish != null) onFinish();
				}
			});
		}});
	}

	override function destroy() {
		if(alphaTween != null) {
			alphaTween.cancel();
		}
		super.destroy();
	}
}
