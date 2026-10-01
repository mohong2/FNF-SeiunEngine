package vlc;

#if hxvlc
import flixel.FlxG;
import hxvlc.flixel.FlxInternalVideo;
import openfl.display.BitmapData;
import openfl.events.Event;
import sys.FileSystem;
import backend.VideoPreloader;

/**
 * hxCodec 2.5.x `vlc.MP4Handler` compatibility layer, backed by hxvlc.
 *
 * Emulates the old VlcBitmap-based API (`playVideo`, `readyCallback`,
 * `finishCallback`, `repeat`, `volume`, ...) so existing engine code and mods
 * keep working without changes. Based on the FNF-PlusEngine wrappers.
 *
 * Unlike hxCodec 2.5.1, playback errors never `throw` - they clean up and run
 * `finishCallback` instead, so a missing/broken video can't crash the game.
 */
class MP4Handler extends FlxInternalVideo
{
	public var readyCallback:Void->Void;
	public var finishCallback:Void->Void;

	/**
	 * Psych Engine 1.0.4 startVideo(..., canSkip) 兼容: 为 false 时 ENTER/SPACE
	 * 不再跳过视频。
	 */
	public var canSkip:Bool = true;

	/**
	 * Psych Engine 1.0.4 startVideo(..., playOnLoad) 兼容: 为 false 时只加载不自动播放。
	 */
	public var autoPlay:Bool = true;

	var pauseMusic:Bool = false;
	var _location:String = null;
	var _repeat:Int = 0;
	var _isReady:Bool = false;
	var _isDisposed:Bool = false;
	var _finishing:Bool = false;
	var _autoScale:Bool = true;

	public var repeat(get, set):Int;
	public var location(get, never):String;

	/**
	 * hxCodec 2.5.1 兼容：显式公开当前视频帧位图。
	 * 模组常通过 `loadGraphic(video.bitmapData)` 把视频帧渲染到自己的 sprite 上，
	 * 这里 override 成公开 getter，保证 hscript/Lua 的 `video.bitmapData` 一定能访问到。
	 */
	public override function get_bitmapData():BitmapData {
		return super.bitmapData;
	}

	public function new(width:Float = 320, height:Float = 240, autoScale:Bool = true)
	{
		super();

		// SeiunEngine renders without Stage3D, so hxvlc's GPU texture path
		// (bitmapData.image == null) would show a black screen. Keep frames in
		// a CPU bitmap instead - works both for the overlay and for sprites
		// that copy `bitmapData` via loadGraphic().
		hxvlc.openfl.Video.useTexture = false;

		// Keep decoding/updating frames even when the overlay is invisible
		// (mods commonly hide the overlay and render bitmapData themselves).
		forceRendering = true;

		this.width = width;
		this.height = height;
		_autoScale = autoScale;

		onFormatSetup.add(onVLCVideoReady);
		onEndReached.add(onVLCComplete);
		onEncounteredError.add(onVLCError);

		try
		{
			FlxG.addChildBelowMouse(this);
		}
		catch (e:Dynamic)
		{
			trace('MP4Handler: addChildBelowMouse failed: $e');
		}

		#if FLX_KEYBOARD
		try
		{
			FlxG.stage.addEventListener(Event.ENTER_FRAME, update);
		}
		catch (e:Dynamic)
		{
			trace('MP4Handler: addEventListener failed: $e');
		}
		#end
	}

	#if FLX_KEYBOARD
	public function update(?e:Event):Void
	{
		// Original hxCodec behavior: ENTER / SPACE skips the video.
		if (canSkip && (FlxG.keys.justPressed.ENTER || FlxG.keys.justPressed.SPACE) && isPlaying)
			finishVideo();
	}
	#end

	function checkFile(fileName:String):String
	{
		#if sys
		#if !android
		var pDir = "";
		var appDir = Sys.getCwd();

		if (fileName.indexOf(":") == -1) // Not a path
			pDir = appDir;

		var fullPath = pDir + fileName;
		if (FileSystem.exists(fullPath))
			return fullPath;

		// Fallback: resolve relative paths against the executable's folder, since
		// cwd may differ when launched via shortcut or externally.
		var exeDir = haxe.io.Path.directory(Sys.programPath());
		if (exeDir != null && exeDir.length > 0)
		{
			var exeFull = exeDir + "/" + fileName;
			if (FileSystem.exists(exeFull))
				return exeFull;
		}

		return fileName;
		#else
		return fileName;
		#end
		#else
		return fileName;
		#end
	}

	function onVLCVideoReady():Void
	{
		// onFormatSetup can fire more than once (e.g. 1x1 placeholder -> real
		// size); make sure user callbacks only run on the first setup.
		if (_isReady)
			return;

		_isReady = true;

		if (_autoScale)
			resizeToStage();

		if (readyCallback != null)
			readyCallback();
	}

	function resizeToStage():Void
	{
		if (bitmapData == null || bitmapData.width <= 0 || bitmapData.height <= 0)
			return;

		var aspect:Float = bitmapData.width / bitmapData.height;
		var stageW:Float = FlxG.stage.stageWidth;
		var stageH:Float = FlxG.stage.stageHeight;

		if (stageW / stageH > aspect)
		{
			height = stageH;
			width = stageH * aspect;
		}
		else
		{
			width = stageW;
			height = stageW / aspect;
		}
	}

	function onVLCError(error:String):Void
	{
		trace("MP4Handler: VLC error: " + error);
		finishVideo();
	}

	function onVLCComplete():Void
	{
		if (_repeat < 0) // Infinite loop
		{
			stop();
			haxe.Timer.delay(function()
			{
				if (!_isDisposed && _location != null && load(_location))
					play();
			}, 50);
		}
		else if (_repeat > 0)
		{
			_repeat--;
			stop();
			haxe.Timer.delay(function()
			{
				if (!_isDisposed && _location != null && load(_location))
					play();
			}, 50);
		}
		else
		{
			finishVideo();
		}
	}

	public function finishVideo():Void
	{
		if (_finishing || _isDisposed)
			return;

		_finishing = true;

		try
		{
			if (pauseMusic && FlxG.sound.music != null)
				FlxG.sound.music.resume();

			#if FLX_KEYBOARD
			FlxG.stage.removeEventListener(Event.ENTER_FRAME, update);
			#end

			dispose();

			if (FlxG.game.contains(this))
				FlxG.game.removeChild(this);
		}
		catch (e:Dynamic)
		{
			trace('MP4Handler: finishVideo cleanup failed: $e');
		}

		_finishing = false;

		if (finishCallback != null)
			finishCallback();
	}

	/**
	 * Native video support for Flixel & OpenFL
	 * @param path Example: `your/video/here.mp4`
	 * @param repeat Repeat the video.
	 * @param pauseMusic Pause music until done video.
	 */
	public function playVideo(path:String, ?repeat:Bool = false, pauseMusic:Bool = false):Void
	{
		// Don't let the first-time LibVLC initialization freeze the caller.
		// `VideoPreloader.whenReady` runs immediately when already initialized.
		VideoPreloader.whenReady(function():Void
		{
			if (_isDisposed)
				return;

			if (VideoPreloader.isFailed())
			{
				onVLCError('Unable to initialize video: $path');
				return;
			}

			this.pauseMusic = pauseMusic;
			this._repeat = repeat ? -1 : 0;

			if (FlxG.sound.music != null && pauseMusic)
				FlxG.sound.music.pause();

			var videoPath = checkFile(path);
			_location = videoPath;

			try
			{
				if (load(videoPath))
				{
					try
					{
						if (autoPlay) play();
					}
					catch (e:Dynamic)
					{
						trace('MP4Handler: play() failed: $e');
						onVLCError('Unable to play video: $path');
					}
				}
				else
					onVLCError('Unable to load video: $path');
			}
			catch (e:Dynamic)
			{
				trace('MP4Handler: load() failed: $e');
				onVLCError('Unable to load video: $path');
			}
		});
	}

	@:noCompletion
	private function get_repeat():Int
	{
		return _repeat;
	}

	@:noCompletion
	private function set_repeat(value:Int):Int
	{
		_repeat = value;
		return _repeat;
	}

	@:noCompletion
	private function get_location():String
	{
		return _location;
	}

	override public function dispose():Void
	{
		if (_isDisposed)
			return;

		_isDisposed = true;
		_isReady = false;
		_location = null;

		super.dispose();
	}
}
#else
// Dummy fallback so `vlc.MP4Handler` always exists (e.g. HTML5 builds).
class MP4Handler
{
	public var readyCallback:Void->Void;
	public var finishCallback:Void->Void;
	public var repeat:Int = 0;
	public var location:String = null;
	public var volume:Int = 100;
	public var isPlaying:Bool = false;
	public var width:Float = 0;
	public var height:Float = 0;

	public function new(width:Float = 320, height:Float = 240, autoScale:Bool = true)
	{
		this.width = width;
		this.height = height;
		trace("MP4Handler: hxvlc is not available on this target!");
	}

	public function playVideo(path:String, ?repeat:Bool = false, pauseMusic:Bool = false):Void
	{
		trace("MP4Handler.playVideo: hxvlc is not available on this target!");

		if (finishCallback != null)
			finishCallback();
	}

	public function finishVideo():Void
	{
		if (finishCallback != null)
			finishCallback();
	}

	public function pause():Void {}
	public function resume():Void {}
	public function stop():Void {}
	public function dispose():Void {}
}
#end
