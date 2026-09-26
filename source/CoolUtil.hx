package;

 
import openfl.utils.Assets;
import lime.utils.Assets as LimeAssets;
import lime.utils.AssetLibrary;
import lime.utils.AssetManifest;
import flixel.system.FlxSound;
#if sys
import sys.io.File;
import sys.io.Process;
import sys.FileSystem;
#else
import openfl.utils.Assets;
#end

using StringTools;

import mohong.TraceManager;

class CoolUtil
{
	/**
	 *
	 * 已迁移到 TraceManager 系统，此方法保留为向后兼容。
	 * 
	 * 新代码请直接使用:
	 *   TraceManager.info('trace.fileSaved', 'File saved!');
	 *   TraceManager.info('trace.fileSaved', 'File saved: {}', [name]);
	 *   TraceManager.warn(...) / TraceManager.error(...) / TraceManager.debug(...)
	 * 
	 * @deprecated 请使用 TraceManager.info / warn / error / debug
	 */
	public static function traceMsg(key:String, defaultText:String, ?args:Array<Dynamic>):Void
	{
		TraceManager.info(key, defaultText, args);
	}

	public static var defaultDifficulties:Array<String> = [
		'Easy',
		'Normal',
		'Hard'
	];
	public static var defaultDifficulty:String = 'Normal'; //The chart that has no suffix and starting difficulty on Freeplay/Story Mode

	public static var difficulties:Array<String> = [];

	inline public static function quantize(f:Float, snap:Float){
		// changed so this actually works lol
		var m:Float = Math.fround(f * snap);
		trace(snap);
		return (m / snap);
	}
	
	inline public static function colorFromString(color:String):FlxColor
	{
		var hideChars = ~/[\t\n\r]/;
		var color:String = hideChars.split(color).join('').trim();
		if(color.startsWith('0x')) color = color.substring(color.length - 6);

		var colorNum:Null<FlxColor> = FlxColor.fromString(color);
		if(colorNum == null) colorNum = FlxColor.fromString('#$color');
		return colorNum != null ? colorNum : FlxColor.WHITE;
	}

	inline public static function capitalize(text:String)
		return text.charAt(0).toUpperCase() + text.substr(1).toLowerCase();
	
	public static function getDifficultyFilePath(num:Null<Int> = null)
	{
		if(num == null) num = PlayState.storyDifficulty;

		var fileSuffix:String = difficulties[num];
		if(fileSuffix != defaultDifficulty)
		{
			fileSuffix = '-' + fileSuffix;
		}
		else
		{
			fileSuffix = '';
		}
		return Paths.formatToSongPath(fileSuffix);
	}

	public static function difficultyString():String
	{
		if (difficulties.length < 1)
			return defaultDifficulty.toUpperCase();
		var idx:Int = PlayState.storyDifficulty;
		if (idx < 0 || idx >= difficulties.length)
			idx = difficulties.indexOf(defaultDifficulty);
		if (idx < 0) idx = 0;
		return difficulties[idx].toUpperCase();
	}

	inline public static function boundTo(value:Float, min:Float, max:Float):Float {
		return Math.max(min, Math.min(max, value));
	}

	public static function coolTextFile(path:String):Array<String>
	{
		var daList:Array<String> = [];
		#if sys
		if(FileSystem.exists(path)) daList = File.getContent(path).trim().split('\n');
		#else
		if(Assets.exists(path)) daList = Assets.getText(path).trim().split('\n');
		#end

		for (i in 0...daList.length)
		{
			daList[i] = daList[i].trim();
		}

		return daList;
	}
	public static function listFromString(string:String):Array<String>
	{
		var daList:Array<String> = [];
		daList = string.trim().split('\n');

		for (i in 0...daList.length)
		{
			daList[i] = daList[i].trim();
		}

		return daList;
	}
	#if ONLINE_ALLOWED
	/**
	 * Converts a Colyseus `ArraySchema<T>` into a plain `Array<T>`. The online `RoomState` receives
	 * the room's difficulty list as an `ArraySchema<String>` while `Difficulty.list` is a plain
	 * `Array<String>`.
	 *
	 * It lives here (rather than inline in `RoomState`) for reuse; the parameter type is the only
	 * reason the function needs the online guard on this engine's side.
	 */
	public static function asta<T>(arr:io.colyseus.serializer.schema.types.ArraySchema<T>) {
		var haxArr = [];
		for (i => thing in arr.items) {
			haxArr[i] = thing;
		}
		return haxArr;
	}
	#end
	public static function floorDecimal(value:Float, decimals:Int):Float
	{
		if(decimals < 1)
			return Math.floor(value);

		return Math.floor(value * Math.pow(10, decimals) + 0.0000001) / Math.pow(10, decimals);
	}

	inline public static function dominantColor(sprite:flixel.FlxSprite):Int
	{
		var countByColor:Map<Int, Int> = [];
		for(col in 0...sprite.frameWidth)
		{
			for(row in 0...sprite.frameHeight)
			{
				var colorOfThisPixel:FlxColor = sprite.pixels.getPixel32(col, row);
				if(colorOfThisPixel.alphaFloat > 0.05)
				{
					colorOfThisPixel = FlxColor.fromRGB(colorOfThisPixel.red, colorOfThisPixel.green, colorOfThisPixel.blue, 255);
					var count:Int = countByColor.exists(colorOfThisPixel) ? countByColor[colorOfThisPixel] : 0;
					countByColor[colorOfThisPixel] = count + 1;
				}
			}
		}

		var maxCount = 0;
		var maxKey:Int = 0; //after the loop this will store the max color
		countByColor[FlxColor.BLACK] = 0;
		for(key => count in countByColor)
		{
			if(count >= maxCount)
			{
				maxCount = count;
				maxKey = key;
			}
		}
		countByColor = [];
		return maxKey;
	}

	inline public static function numberArray(max:Int, ?min = 0):Array<Int>
	{
		var dumbArray:Array<Int> = [];
		for (i in min...max) dumbArray.push(i);

		return dumbArray;
	}

	public static function browserLoad(site:String) {
		FlxG.openURL(site);
	}
	inline public static function openFolder(folder:String, absolute:Bool = false) {
		#if sys
			if(!absolute) folder =  Sys.getCwd() + '$folder';

			folder = haxe.io.Path.normalize(folder);
			if(folder.endsWith('/')) folder = folder.substr(0, folder.length - 1);

			#if linux
			var command:String = '/usr/bin/xdg-open';
			#elseif mac
			var command:String = 'open';
			#else
			var command:String = 'explorer.exe';
			#end
			Sys.command(command, [folder]);
			trace('$command $folder');
		#else
			FlxG.log.error("Platform is not supported for CoolUtil.openFolder");
		#end
	}


	//uhhhh does this even work at all? i'm starting to doubt
	public static function precacheSound(sound:String, ?library:String = null):Void {
		Paths.sound(sound, library);
	}

	public static function precacheMusic(sound:String, ?library:String = null):Void {
		Paths.music(sound, library);
	}

	/**
		Helper Function to Fix Save Files for Flixel 5

		-- EDIT: [November 29, 2023] --

		this function is used to get the save path, period.
		since newer flixel versions are being enforced anyways.
		@crowplexus
	**/
	@:access(flixel.util.FlxSave.validate)
	inline public static function getSavePath():String {
		final company:String = FlxG.stage.application.meta.get('company');
		#if (flixel < "5.0.0") return company; #else
		return '${company}/${flixel.util.FlxSave.validate(FlxG.stage.application.meta.get('file'))}';
	#end
	}

	#if sys
	/** Return an absolute, writable path for replay temp files. */
	public static function getReplayTempDir():String
	{
		return SUtil.getStorageDirectory() + '.scores/replay_temp/';
	}
	#end
}
