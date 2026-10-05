package states;

import lime.app.Promise;
import lime.app.Future;
import flixel.FlxState;
import flixel.graphics.frames.FlxAtlasFrames;
import openfl.utils.Assets;
import lime.utils.Assets as LimeAssets;
import lime.utils.AssetLibrary;
import lime.utils.AssetManifest;

import haxe.io.Path;
import mohong.TraceManager;
#if sys
import sys.FileSystem;
import sys.io.File;
#end
#if VIDEOS_ALLOWED
import backend.VideoPreloader;
#end

class LoadingState extends MusicBeatState
{
	inline static var MIN_TIME = 1.0;
	/** Loading watchdog timeout in seconds; forces state transition if callbacks stall. */
	inline static var LOAD_WATCHDOG_S:Float = 90;
	public static var instance:LoadingState;
	// Browsers will load create(), you can make your song load a custom directory there
	// If you're compiling to desktop (or something that doesn't use NO_PRELOAD_ALL), search for getNextState instead
	// I'd recommend doing it on both actually lol
	
	// TO DO: Make this easier
	
	var target:FlxState;
	var stopMusic = false;
	var directory:String;
	var callbacks:MultiCallback;
	var targetShit:Float = 0;

	// Loading timeout watchdog and heartbeat state variables
	var loadStartAt:Float = 0;
	var switchStarted:Bool = false;
	var dbgAccum:Float = 0;

	function new(target:FlxState, stopMusic:Bool, directory:String)
	{
		super();
		this.target = target;
		this.stopMusic = stopMusic;
		this.directory = directory;
	}

	var funkay:FlxSprite;
	var loadBar:FlxSprite;
	override function create()
	{
		instance = this;

		#if sys
		loadStartAt = haxe.Timer.stamp();
		#end

		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end

		var bg:FlxSprite = new FlxSprite(0, 0).makeGraphic(FlxG.width, FlxG.height, 0xffcaff4d);
		add(bg);
		funkay = new FlxSprite(0, 0).loadGraphic(Paths.getPath('images/funkay.png', IMAGE));
		funkay.setGraphicSize(0, FlxG.height);
		funkay.updateHitbox();
		funkay.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(funkay);
		funkay.scrollFactor.set();
		funkay.screenCenter();

		loadBar = new FlxSprite(0, FlxG.height - 20).makeGraphic(FlxG.width, 10, 0xffff16d2);
		loadBar.screenCenter(X);
		loadBar.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(loadBar);
		
		initSongsManifest().onComplete
		(
			function (lib)
			{
				callbacks = new MultiCallback(onLoad);
				var introComplete = callbacks.add("introComplete");

				#if VIDEOS_ALLOWED
				// Make sure LibVLC is ready before entering the next state, so
				// the first cutscene video starts immediately instead of being
				// delayed by a lazy init (and without any main-thread freeze).
				var videoInitComplete = callbacks.add("videoInit");
				VideoPreloader.whenReady(function()
				{
					// Warm the one-time media player setup now, while the loading
					// screen is visible, so the first cutscene video doesn't pay
					// that cost (and doesn't cause a focus/delay hitch).
					VideoPreloader.prewarmMedia();
					videoInitComplete();
				});
				#end
				if (PlayState.SONG != null) {
					checkLoadSong(getSongPath());
					if (PlayState.SONG.needsVoices)
						checkLoadSong(getVocalPath());
				}
				checkLibrary("shared");
				if(directory != null && directory.length > 0 && directory != 'shared') {
					checkLibrary(directory);
				}

				var fadeTime = 0.5;
				FlxG.camera.fade(FlxG.camera.bgColor, fadeTime, true);
				new FlxTimer().start(fadeTime + MIN_TIME, function(_) introComplete());
			}
		);
	}
	
	function checkLoadSong(path:Dynamic)
	{
		if (path == null || !Std.isOfType(path, String)) return;
		var pathStr:String = cast path;
		if (!Assets.cache.hasSound(pathStr))
		{
			var library = Assets.getLibrary("songs");
			final symbolPath = pathStr.split(":").pop();
			// @:privateAccess
			// library.types.set(symbolPath, SOUND);
			// @:privateAccess
			// library.pathGroups.set(symbolPath, [library.__cacheBreak(symbolPath)]);
			var callback = callbacks.add("song:" + pathStr);
			var fut = Assets.loadSound(pathStr);
			fut.onComplete(function(_)
			{
				TraceManager.info('trace.loading.soundOk', 'sound loaded: {}', [pathStr]);
				callback();
			});
			// Allow continuation on failure to prevent sound issues from hanging the loading screen
			fut.onError(function(e)
			{
				TraceManager.warn('trace.loading.soundFail', 'sound load FAILED (skipping wait): {} [{}]', [pathStr, e]);
				callback();
			});
		}
	}
	
	function checkLibrary(library:String) {
		TraceManager.debug('trace.loading.checkLibrary', 'Checking library: {} - {}', [library, Assets.hasLibrary(library)]);
		#if ONLINE_ALLOWED
		// The mod directory is not a lime library but was being checked as one. To keep mod assets
		// from being redirected to assets/weekX, the asset directory (`directory`) is set to
		// `Mods.currentModDirectory` (the mod folder name, see getNextState's ONLINE_ALLOWED
		// block); `create()` then calls this function with it, and a mod name is neither in
		// `LimeAssets.libraryPaths` nor backed by a lime library, so this throws
		// `Missing library: <mod>` and a mod song dies right here. This engine resolves mod assets
		// from disk paths anyway (`Paths.modsImages/modsSounds/modsJson/...`), so no lime library
		// is needed and the check is skipped; real libraries still take the unchanged branch below.
		if (!Assets.hasLibrary(library) && backend.Mods.getModDirectories().contains(library))
		{
			TraceManager.info('trace.loading.modDirSkipLibrary',
				'asset folder is a mod directory (not a lime library), skipping library wait: {}', [library]);
			return;
		}
		#end
		if (Assets.getLibrary(library) == null)
		{
			@:privateAccess
			if (!LimeAssets.libraryPaths.exists(library))
			{
				// The asset folder asked for is not a lime library at all. A chart's stage file is
				// free to name any folder (BPM-2021's stages/BPM.json asks for "week0", which is
				// neither a real week nor a registered library), and there is nothing to wait for in
				// that case: Paths resolves the real assets from disk paths and falls back to
				// shared/ when the level folder does not exist. Only a genuinely stalled library
				// should hold the load, so an unknown name is skipped with a warning instead of
				// killing the whole song with "Missing library: <name>".
				TraceManager.warn('trace.loading.libraryNotRegistered',
					'asset folder is not a lime library, skipping library wait: {}', [library]);
				return;
			}

			var callback = callbacks.add("library:" + library);
			var fut = Assets.loadLibrary(library);
			fut.onComplete(function(_)
			{
				TraceManager.info('trace.loading.libraryOk', 'library loaded: {}', [library]);
				callback();
			});
			// Allow continuation on failure to prevent library load issues from hanging the loading screen
			fut.onError(function(e)
			{
				TraceManager.warn('trace.loading.libraryFail', 'library load FAILED (skipping wait): {} [{}]', [library, e]);
				callback();
			});
		}
	}
	
	override function update(elapsed:Float)
	{
		#if LUA_ALLOWED
		callOnLuas('onUpdate', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdate', [elapsed]);
		#end
		super.update(elapsed);
		#if LUA_ALLOWED
		callOnLuas('onUpdatePost', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdatePost', [elapsed]);
		#end
		funkay.setGraphicSize(Std.int(0.88 * FlxG.width + 0.9 * (funkay.width - 0.88 * FlxG.width)));
		funkay.updateHitbox();
		if(controls.ACCEPT)
		{
			funkay.setGraphicSize(Std.int(funkay.width + 60));
			funkay.updateHitbox();
		}

		if(callbacks != null) {
			targetShit = FlxMath.remapToRange(callbacks.numRemaining / callbacks.length, 1, 0, 0, 1);
			loadBar.scale.x += 0.5 * (targetShit - loadBar.scale.x);
		}

		#if sys
		// Watchdog: force continue after timeout to prevent hanging on loading screen
		if (loadStartAt > 0 && !switchStarted && (haxe.Timer.stamp() - loadStartAt) > LOAD_WATCHDOG_S)
		{
			switchStarted = true; // Prevent re-entry inside onLoad
			TraceManager.error('trace.loading.watchdog',
				'LoadingState watchdog fired after {}s, forcing continue', [LOAD_WATCHDOG_S]);
			onLoad();
		}
		#end
	}
	
	function onLoad()
	{
		// Prevent late callbacks from triggering duplicate state transitions after watchdog forced exit
		if (switchStarted) return;
		switchStarted = true;

		if (stopMusic && FlxG.sound.music != null)
			FlxG.sound.music.stop();
		
		MusicBeatState.switchState(target);
	}
	
	static function getSongPath()
	{
		if (PlayState.SONG == null || PlayState.SONG.song == null) return null;
		return Paths.inst(PlayState.SONG.song);
	}
	
	static function getVocalPath()
	{
		if (PlayState.SONG == null || PlayState.SONG.song == null) return null;
		return Paths.voices(PlayState.SONG.song);
	}
	
	inline static public function loadAndSwitchState(target:FlxState, stopMusic = false)
	{
		MusicBeatState.switchState(getNextState(target, stopMusic));
	}
	
	static function getNextState(target:FlxState, stopMusic = false):FlxState
	{
		var directory:String = 'shared';
		var weekDir:String = StageData.forceNextDirectory;
		StageData.forceNextDirectory = null;

		#if ONLINE_ALLOWED
		// A song that comes from a mod must use the mod directory, otherwise assets are
		// redirected to assets/weekX (log: "Re-derived asset folder from SONG: week7").
		// Only weekDir's initial value changes; the original logic below is untouched.
		if ((weekDir == null || weekDir.length <= 0) && Std.isOfType(target, PlayState) && PlayState.SONG != null
			&& backend.Mods.currentModDirectory != null && backend.Mods.currentModDirectory != '')
			weekDir = backend.Mods.currentModDirectory;
		#end

		// When restarting/changing difficulty in pause menu, re-derive week directory from SONG
		// to prevent falling back to 'shared' and failing to load week-specific assets.
		if ((weekDir == null || weekDir.length <= 0) && Std.isOfType(target, PlayState) && PlayState.SONG != null)
		{
			StageData.loadDirectory(PlayState.SONG);
			weekDir = StageData.forceNextDirectory;
			StageData.forceNextDirectory = null;
			TraceManager.info('trace.loading.rederiveFolder',
				'Re-derived asset folder from SONG: {}', [weekDir != null ? weekDir : 'shared']);
		}

		if(weekDir != null && weekDir.length > 0 && weekDir != '') directory = weekDir;

		Paths.setCurrentLevel(directory);
		TraceManager.info('trace.loading.setAssetFolder', 'Setting asset folder to {}', [directory]);

		/*#if NO_PRELOAD_ALL
		var loaded:Bool = false;
		if (PlayState.SONG != null) {
			loaded = isSoundLoaded(getSongPath()) && (!PlayState.SONG.needsVoices || isSoundLoaded(getVocalPath())) && isLibraryLoaded("shared") && isLibraryLoaded(directory);
		}
		
		if (!loaded)
			return new LoadingState(target, stopMusic, directory);
		#end*/
		if (stopMusic && FlxG.sound.music != null)
			FlxG.sound.music.stop();
		
		return target;
	}
	
	/*#if NO_PRELOAD_ALL
	static function isSoundLoaded(path:String):Bool
	{
		return Assets.cache.hasSound(path);
	}
	
	static function isLibraryLoaded(library:String):Bool
	{
		return Assets.getLibrary(library) != null;
	}
	#end*/
	
	override function destroy()
	{
		instance = null;
		super.destroy();
		
		callbacks = null;
	}
	
	static function initSongsManifest()
	{
		var id = "songs";
		var promise = new Promise<AssetLibrary>();

		var library = LimeAssets.getLibrary(id);

		if (library != null)
		{
			return Future.withValue(library);
		}

		var path = id;
		var rootPath = null;

		@:privateAccess
		var libraryPaths = LimeAssets.libraryPaths;
		if (libraryPaths.exists(id))
		{
			path = libraryPaths[id];
			rootPath = Path.directory(path);
		}
		else
		{
			if (StringTools.endsWith(path, ".bundle"))
			{
				rootPath = path;
				path += "/library.json";
			}
			else
			{
				rootPath = Path.directory(path);
			}
			@:privateAccess
			path = LimeAssets.__cacheBreak(path);
		}

		AssetManifest.loadFromFile(path, rootPath).onComplete(function(manifest)
		{
			if (manifest == null)
			{
				promise.error("Cannot parse asset manifest for library \"" + id + "\"");
				return;
			}

			var library = AssetLibrary.fromManifest(manifest);

			if (library == null)
			{
				promise.error("Cannot open library \"" + id + "\"");
			}
			else
			{
				@:privateAccess
				LimeAssets.libraries.set(id, library);
				library.onChange.add(LimeAssets.onChange.dispatch);
				promise.completeWith(Future.withValue(library));
			}
		}).onError(function(_)
		{
			promise.error("There is no asset library with an ID of \"" + id + "\"");
		});

		return promise.future;
	}
}

class MultiCallback
{
	public var callback:Void->Void;
	public var logId:String = null;
	public var length(default, null) = 0;
	public var numRemaining(default, null) = 0;
	
	var unfired = new Map<String, Void->Void>();
	var fired = new Array<String>();
	
	public function new (callback:Void->Void, logId:String = null)
	{
		this.callback = callback;
		this.logId = logId;
	}
	
	public function add(id = "untitled")
	{
		id = '$length:$id';
		length++;
		numRemaining++;
		var func:Void->Void = null;
		func = function ()
		{
			if (unfired.exists(id))
			{
				unfired.remove(id);
				fired.push(id);
				numRemaining--;
				
				if (logId != null)
					log('fired $id, $numRemaining remaining');
				
				if (numRemaining == 0)
				{
					if (logId != null)
						log('all callbacks fired');
					callback();
				}
			}
			else
				log('already fired $id');
		}
		unfired[id] = func;
		return func;
	}
	
	inline function log(msg):Void
	{
		if (logId != null)
			TraceManager.debug('trace.loading.log', '{}: {}', [logId, msg]);
	}
	
	public function getFired() return fired.copy();
	public function getUnfired() return [for (id in unfired.keys()) id];
}