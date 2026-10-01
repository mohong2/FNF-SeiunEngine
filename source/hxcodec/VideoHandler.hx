package hxcodec;

#if hxvlc
import flixel.FlxG;
import flixel.input.keyboard.FlxKey;
import hxvlc.flixel.FlxInternalVideo;
import openfl.events.Event;
import sys.FileSystem;
import backend.VideoPreloader;

/**
 * hxCodec 2.6.x `hxcodec.VideoHandler` compatibility layer, backed by hxvlc.
 *
 * Emulates the hxCodec 2.x API (`canSkip`, `skipKeys`, `openingCallback`,
 * `finishCallback`, `calcSize`, ...) so mods written for 2.6.x keep working.
 */
class VideoHandler extends FlxInternalVideo
{
	public var canSkip:Bool = true;
	public var skipKeys:Array<FlxKey> = [FlxKey.SPACE];
	public var canUseSound:Bool = true;
	public var canUseAutoResize:Bool = true;

	/**
	 * 1.0.4 startVideo(..., playOnLoad) 兼容: 为 false 时只加载不自动播放。
	 * English: 1.0.4 startVideo playOnLoad — when false, load without playing.
	 */
	public var autoPlay:Bool = true;

	public var openingCallback:Void->Void = null;
	public var finishCallback:Void->Void = null;

	var pauseMusic:Bool = false;
	var _isPlaying:Bool = false;
	var _isDisposed:Bool = false;
	var _location:String = null;
	var _loop:Bool = false;
	var _keyListenerAdded:Bool = false;

	public var isDisplaying(get, never):Bool;
	public var videoWidth(get, never):Int;
	public var videoHeight(get, never):Int;
	public var location(get, never):String;

	public function new(IndexModifier:Int = 0):Void
	{
		super();

		// CPU rendering + keep updating frames while invisible
		// (see vlc.MP4Handler for details)
		hxvlc.openfl.Video.useTexture = false;
		forceRendering = true;

		onOpening.add(onVLCOpening);
		onEndReached.add(onVLCEndReached);
		onEncounteredError.add(onVLCEncounteredError);

		FlxG.addChildBelowMouse(this, IndexModifier);
	}

	#if FLX_KEYBOARD
	public function update(?e:Event):Void
	{
		if (canSkip && (FlxG.keys.anyJustPressed(skipKeys) #if android || FlxG.android.justReleased.BACK #end) && _isPlaying && isDisplaying)
			onVLCEndReached();

		if (canUseAutoResize && (videoWidth > 0 && videoHeight > 0))
		{
			var newWidth:Int = calcSize(0);
			var newHeight:Int = calcSize(1);
			if (newWidth != _lastResizeWidth || newHeight != _lastResizeHeight)
			{
				_lastResizeWidth = newWidth;
				_lastResizeHeight = newHeight;
				width = newWidth;
				height = newHeight;
			}
		}
	}
	#end

	function onVLCOpening():Void
	{
		#if FLX_KEYBOARD
		if (!_keyListenerAdded)
		{
			FlxG.stage.addEventListener(Event.ENTER_FRAME, update);
			_keyListenerAdded = true;
		}
		#end

		if (openingCallback != null)
			openingCallback();
	}

	function onVLCEncounteredError(error:String):Void
	{
		trace('VideoHandler Error: $error');
		onVLCEndReached();
	}

	function onVLCEndReached():Void
	{
		_isPlaying = false;

		if (_loop)
		{
			stop();
			haxe.Timer.delay(function()
			{
				if (!_isDisposed && _location != null && load(_location))
				{
					_isPlaying = true;
					play();
				}
			}, 50);
			return;
		}

		if (pauseMusic && FlxG.sound.music != null)
			FlxG.sound.music.resume();

		#if FLX_KEYBOARD
		if (_keyListenerAdded)
		{
			FlxG.stage.removeEventListener(Event.ENTER_FRAME, update);
			_keyListenerAdded = false;
		}
		#end

		dispose();

		if (FlxG.game.contains(this))
			FlxG.game.removeChild(this);

		if (finishCallback != null)
			finishCallback();
	}

	/**
	 * Plays a video.
	 *
	 * @param Path Example: `your/video/here.mp4`
	 * @param Loop Loop the video.
	 * @param PauseMusic Pause music until the video ends.
	 */
	public function playVideo(Path:String, Loop:Bool = false, PauseMusic:Bool = false):Void
	{
		// Avoid blocking the main thread on the first LibVLC initialization.
		VideoPreloader.whenReady(function():Void
		{
			if (_isDisposed)
				return;

			if (VideoPreloader.isFailed())
			{
				onVLCEncounteredError('Unable to initialize video: $Path');
				return;
			}

			pauseMusic = PauseMusic;
			_loop = Loop;

			if (FlxG.sound.music != null && PauseMusic)
				FlxG.sound.music.pause();

			var videoPath = Path;
			if (FileSystem.exists(Sys.getCwd() + Path))
				videoPath = Sys.getCwd() + Path;

			_location = videoPath;

			if (load(videoPath))
			{
				_isPlaying = autoPlay;
				if (autoPlay)
					play();
			}
			else
			{
				onVLCEncounteredError('Unable to load video: $Path');
			}
		});
	}

	public function calcSize(Ind:Int):Int
	{
		var stageWidth = FlxG.stage.stageWidth;
		var stageHeight = FlxG.stage.stageHeight;

		var appliedWidth:Float = stageHeight * (FlxG.width / FlxG.height);
		var appliedHeight:Float = stageWidth * (FlxG.height / FlxG.width);

		if (appliedHeight > stageHeight)
			appliedHeight = stageHeight;

		if (appliedWidth > stageWidth)
			appliedWidth = stageWidth;

		switch (Ind)
		{
			case 0:
				return Std.int(appliedWidth);
			case 1:
				return Std.int(appliedHeight);
			default:
				return 0;
		}
	}

	@:noCompletion
	private function get_isDisplaying():Bool
	{
		return _isPlaying && bitmapData != null;
	}

	@:noCompletion
	private function get_videoWidth():Int
	{
		return bitmapData != null ? bitmapData.width : 0;
	}

	@:noCompletion
	private function get_videoHeight():Int
	{
		return bitmapData != null ? bitmapData.height : 0;
	}

	@:noCompletion
	private function get_location():String
	{
		return _location;
	}

	// Perf: cache the last applied auto-resize size so unchanged frames don't
	// re-trigger width/height assignment (each assignment walks the display
	// bounds in OpenFL).
	var _lastResizeWidth:Int = -1;
	var _lastResizeHeight:Int = -1;

	override public function dispose():Void
	{
		if (_isDisposed)
			return;

		_isDisposed = true;
		_isPlaying = false;
		_location = null;

		#if FLX_KEYBOARD
		if (_keyListenerAdded)
		{
			FlxG.stage.removeEventListener(Event.ENTER_FRAME, update);
			_keyListenerAdded = false;
		}
		#end

		super.dispose();
	}
}
#else
// Dummy fallback so `hxcodec.VideoHandler` always exists (e.g. HTML5 builds).
class VideoHandler
{
	public var canSkip:Bool = true;
	public var canUseSound:Bool = true;
	public var canUseAutoResize:Bool = true;
	public var openingCallback:Void->Void = null;
	public var finishCallback:Void->Void = null;
	public var isPlaying:Bool = false;
	public var isDisplaying:Bool = false;
	public var videoWidth:Int = 0;
	public var videoHeight:Int = 0;
	public var location:String = null;

	public function new(IndexModifier:Int = 0):Void
	{
		trace("VideoHandler: hxvlc is not available on this target!");
	}

	public function playVideo(Path:String, Loop:Bool = false, PauseMusic:Bool = false):Void
	{
		trace("VideoHandler.playVideo: hxvlc is not available on this target!");

		if (finishCallback != null)
			finishCallback();
	}

	public function pause():Void {}
	public function resume():Void {}
	public function stop():Void {}
	public function dispose():Void {}
}
#end
