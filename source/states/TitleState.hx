package states;
#if mobile
#if sys
import sys.io.File;
import sys.FileSystem;
#end

using StringTools;
#end

import mohong.TraceManager;
import backend.GitHubAPI;
import backend.NativeCrash;
#if VIDEOS_ALLOWED
import backend.VideoPreloader;
#end
#if MODS_ALLOWED
import states.ModState;
#end
import flixel.input.gamepad.FlxGamepad;
#if cpp
import Discord.DiscordClient;
import sys.thread.Thread;
#end

import flixel.FlxState;
import flixel.input.keyboard.FlxKey;
import flixel.addons.display.FlxGridOverlay;
import flixel.addons.transition.FlxTransitionSprite.GraphicTransTileDiamond;
import flixel.addons.transition.FlxTransitionableState;
import flixel.addons.transition.TransitionData;
import haxe.Json;
import openfl.display.Bitmap;
import openfl.display.BitmapData;
#if MODS_ALLOWED
import sys.FileSystem;
import sys.io.File;
#end
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.graphics.frames.FlxFrame;
import flixel.group.FlxGroup;
import flixel.math.FlxRect;
import flixel.system.FlxSound;
import flixel.system.ui.FlxSoundTray;
import lime.app.Application;
import openfl.Assets;

using StringTools;

typedef TitleData =
{
	titlex:Float,
	titley:Float,
	startx:Float,
	starty:Float,
	gfx:Float,
	gfy:Float,
	backgroundSprite:String,
	bpm:Int
}

class TitleState extends MusicBeatState
{
	public static var instance:TitleState;
	public static var muteKeys:Array<FlxKey> = [FlxKey.ZERO];
	public static var volumeDownKeys:Array<FlxKey> = [FlxKey.NUMPADMINUS, FlxKey.MINUS];
	public static var volumeUpKeys:Array<FlxKey> = [FlxKey.NUMPADPLUS, FlxKey.PLUS];

	public static var initialized:Bool = false;

	var blackScreen:FlxSprite;
	var credGroup:FlxGroup;
	var credTextShit:Alphabet;
	var textGroup:FlxGroup;
	var ngSpr:FlxSprite;

	var titleTextColors:Array<FlxColor> = [0xFF33FFFF, 0xFF3333CC];
	var titleTextAlphas:Array<Float> = [1, .64];

	var curWacky:Array<String> = [];

	var wackyImage:FlxSprite;

	#if TITLE_SCREEN_EASTER_EGG
	var easterEggKeys:Array<String> = [
		'SHADOW', 'RIVER', 'SHUBS', 'BBPANZU'
	];
	var allowedKeys:String = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
	var easterEggKeysBuffer:String = '';
	#end

	var mustUpdate:Bool = false;
	var _redirectChecked:Bool = false;

	var titleJSON:TitleData;

	public static var updateVersion:String = '';
	public static var updateAvailable:Bool = false;

	override public function create():Void
	{
		instance = this;

		#if VIDEOS_ALLOWED
		// Retry/warm LibVLC once the game loop is definitely running.
		VideoPreloader.warmup();
		#end

		#if MODS_ALLOWED
		// Load persisted mod selection FIRST so window title & state replacements
		// are active before any state transition occurs.
		MainMenuState.loadActiveMod();
		Paths.currentModDirectory = MainMenuState.selectedModFolder;

		// ── Purge ALL cached assets from the previous session/mod ──
		Paths.clearStoredMemory();
		Paths.clearUnusedMemory();

		// ── Rebuild global mod list BEFORE applyModPackConfig ──
		// so that HScript.reloadGlobalScripts() (called inside applyModPackConfig)
		// picks up scripts from runsGlobally mods.
		Paths.pushGlobalMods();

		// ── Apply new mod's pack.json config ──
		ModState.applyModPackConfig(MainMenuState.selectedModFolder);
		#if HSCRIPT_ALLOWED
		HScript.loadModBootScript();
		#end
		#else
		// Non-MODS_ALLOWED: still clear caches so we don't hold stale data
		Paths.clearStoredMemory();
		Paths.clearUnusedMemory();
		#end

		#if android
		FlxG.android.preventDefaultKeys = [BACK];
		#end

		FlxG.game.focusLostFramerate = 60;
		FlxG.sound.muteKeys = muteKeys;
		FlxG.sound.volumeDownKeys = volumeDownKeys;
		FlxG.sound.volumeUpKeys = volumeUpKeys;
		FlxG.keys.preventDefaultKeys = [TAB];

		PlayerSettings.init();

		curWacky = FlxG.random.getObject(getIntroTextShit());

		swagShader = new ColorSwap();

		// Load preferences BEFORE super.create() so MusicBeatState → Language.load()
		// picks up the user's saved language preference. On mobile CopyState already
		// loaded them (it needs autoExtractAssets/storageType), so this is a no-op there.
		ClientPrefs.ensureLoaded();

		#if sys
		// Prefs are in memory now, so the storage root can finally be resolved against the
		// player's saved storageType instead of the version-aware default; re-apply it so
		// cwd, the crash directory and the linemap all agree. On mobile CopyState already
		// did this and the cached resolution makes the call cheap.
		SUtil.applyStorageDirectory();
		#end

#if ACHIEVEMENTS_ALLOWED
		// Load the achievement list before anything can unlock: a write that runs before this
		// point replaces the saved list with the in-memory one and loses previous unlocks.
		Achievements.load();
#end

#if ONLINE_ALLOWED
		// Credentials are keyed by server-list entry now, so Auth reads the server list --
			// which in turn seeds itself from the legacy address fields in ClientPrefs. The call is
			// made below loadPrefs() because nothing in between ever read authID/authToken.
		online.network.Auth.load();

			// Must run right after ClientPrefs.loadPrefs().
		// NoteSkinData.noteSkins starts as an empty array and GameClient.getOptions() does
		// NoteSkinData.getCurrent(-1).skin -- without this call the first createRoom/joinRoom
		// dereferences a null entry (native ACCESS_VIOLATION, crash map-located to
		// ?getOptions@GameClient_obj@@ +0x430).
		backend.NoteSkinData.reloadNoteSkins();
#end

		// Windows: Apply saved Trace Console preference (not before prefs are loaded).
		#if windows
		TraceManager.syncWithPrefs();
		#end

		super.create();

		#if sys
		// Previous process ended with a native crash (SEH / fatal signal / LuaJIT
		// panic). The native layer only writes a marker because it cannot safely
		// drive FlxG; consume it here once and roll into the crash-catcher screen.
		var pendingNativeCrash = NativeCrash.consumePendingNativeCrash();
		if (pendingNativeCrash != null)
		{
			var nativeCrashText:String = pendingNativeCrash.content;
			if (nativeCrashText.length > 4000)
				nativeCrashText = nativeCrashText.substr(0, 4000) + "\n... (truncated)";
			CrashCatcherState.lastCrashMessage = "Previous native crash detected:\n\n" + nativeCrashText;
			CrashCatcherState.lastCrashStack = "(see native crash log for the full backtrace)";
			CrashCatcherState.lastCrashPath = pendingNativeCrash.path;
			CrashCatcherState.crashCount++;

			try
			{
				var dialogTitle:String = Language.get("CrashCatcher.dialog.title", "Game Crashed!");
				var githubUrl:String = Language.get("CrashCatcher.reportURL", "https://github.com/mohong2/FNF-SeiunEngine/issues");
				var dialogMsg:String = Language.get("CrashCatcher.dialog.message",
					"The game has encountered an error and needs to recover.\n\nError: {error}\n\nCrash dump saved to: {path}\n\nPlease report this on GitHub:\n{url}\n\nClick OK to enter recovery screen.");
				dialogMsg = dialogMsg.replace("{error}", "Previous native crash detected (see log)");
				dialogMsg = dialogMsg.replace("{path}", pendingNativeCrash.path);
				dialogMsg = dialogMsg.replace("{url}", githubUrl);
				backend.Dialog.show(dialogTitle, dialogMsg, 'Error');
			}
			catch (e:Dynamic) {}

			FlxG.switchState(new CrashCatcherState());
		}
		#end

		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end

		#if CHECK_FOR_UPDATES
		updateAvailable = false;
		if(ClientPrefs.data.checkForUpdates && !closedState) {
			TraceManager.info('trace.title.checkUpdate', 'checking for update');
			checkForUpdate();
		}
		#end

		Highscore.load();

		titleJSON = Json.parse(Paths.getTextFromFile('images/gfDanceTitle.json'));

		#if TITLE_SCREEN_EASTER_EGG
		if (FlxG.save.data.psychDevsEasterEgg == null) FlxG.save.data.psychDevsEasterEgg = '';
		switch(FlxG.save.data.psychDevsEasterEgg.toUpperCase())
		{
			case 'SHADOW':
				titleJSON.gfx += 210;
				titleJSON.gfy += 40;
			case 'RIVER':
				titleJSON.gfx += 100;
				titleJSON.gfy += 20;
			case 'SHUBS':
				titleJSON.gfx += 160;
				titleJSON.gfy -= 10;
			case 'BBPANZU':
				titleJSON.gfx += 45;
				titleJSON.gfy += 100;
		}
		#end

		if(!initialized)
		{
			if(FlxG.save.data != null && FlxG.save.data.fullscreen)
			{
				FlxG.fullscreen = FlxG.save.data.fullscreen;
			}
			persistentUpdate = true;
			persistentDraw = true;
		}

		if (FlxG.save.data.weekCompleted != null)
		{
			StoryMenuState.weekCompleted = FlxG.save.data.weekCompleted;
		}

		FlxG.mouse.visible = false;

		// Asset extraction and readiness verification live in CopyState, which is the
		// first mobile state and hands over only once the storage root is verified. No
		// input path may switch states from here.
		continueNormalFlow();
	}

	#if CHECK_FOR_UPDATES
	function checkForUpdate():Void
	{
		var owner:String = "mohong2";
		var repo:String = "FNF-SeiunEngine";

		var onError = function(error:String)
		{
			TraceManager.error('trace.title.updateCheckError', 'error: {}', [error]);
		}

		var onData = function(data:Dynamic)
		{
			if (data == null) return;

			var releases:Array<Dynamic> = cast data;
			var best:Dynamic = null;
			var bestVersion:String = "";

			for (release in releases)
			{
				if (release == null) continue;
				if (Reflect.field(release, "draft") == true) continue;
				if (!ClientPrefs.data.checkForPrereleases && Reflect.field(release, "prerelease") == true) continue;

				var rawTag:Dynamic = Reflect.field(release, "tag_name");
				if (rawTag == null) continue;
				var tag:String = Std.string(rawTag);
				if (tag.length == 0) continue;

				var cleaned:String = GitHubAPI.normalizeVersion(tag);
				if (best == null || GitHubAPI.compareVersions(cleaned, bestVersion) > 0)
				{
					best = release;
					bestVersion = cleaned;
				}
			}

			if (best == null) return;

			var current:String = GitHubAPI.normalizeVersion(MainMenuState.seiunengineVersion);
			TraceManager.info('trace.title.versionCheck', 'version online: {}, your version: {}', [bestVersion, current]);

			if (GitHubAPI.compareVersions(bestVersion, current) > 0)
			{
				TraceManager.warn('trace.title.versionMismatch', 'versions arent matching!');
				updateVersion = Std.string(Reflect.field(best, "tag_name"));
				updateAvailable = true;
				mustUpdate = true;
			}
		}

		GitHubAPI.getReleases(owner, repo, 100, 1, onData, onError);
	}
	#end

	function continueNormalFlow():Void
	{
		#if android
		Language.load();
		// Once per cold start: tell the player when the data does not sit on the public root
		// directory, where the file manager, mods and saves can find it. Raised here rather
		// than in the boot state so it shares the proven-safe dialog slot below.
		SUtil.checkStorageRootWarning();
		SUtil.maybeRequestAllFilesAccess();
		SUtil.maybeRequestOverlayPermission();
		#end

		#if FREEPLAY
		MusicBeatState.switchState(new FreeplayState());
		#elseif CHARTING
		if(ClientPrefs.data.newchartingstate)
			MusicBeatState.loadAndSwitchState(new editors.NewChartingState());
		else
			MusicBeatState.loadAndSwitchState(new editors.ChartingState());
		#else
		if(FlxG.save.data.flashing == null && !FlashingState.leftState) {
			#if MODS_ALLOWED
			var skipFlashing:Bool = false;
			if (MainMenuState.selectedModFolder != null && MainMenuState.selectedModFolder.length > 0) {
				var modCfg = backend.ModConfig.load(MainMenuState.selectedModFolder);
				skipFlashing = modCfg.disableWarningScreen;
			}
			if (skipFlashing) {
				FlxG.save.data.flashing = true;
				FlxG.save.flush();
			} else {
				FlxTransitionableState.skipNextTransIn = true;
				FlxTransitionableState.skipNextTransOut = true;
				MusicBeatState.switchState(new FlashingState());
			}
			#else
			FlxTransitionableState.skipNextTransIn = true;
			FlxTransitionableState.skipNextTransOut = true;
			MusicBeatState.switchState(new FlashingState());
			#end
		} else {
			#if desktop
			if (!DiscordClient.isInitialized)
			{
				DiscordClient.initialize();
				Application.current.onExit.add (function (exitCode) {
					DiscordClient.shutdown();
				});
			}
			#end

			if (initialized)
				startIntro();
			else
			{
				new FlxTimer().start(1, function(tmr:FlxTimer)
				{
					startIntro();
				});
			}
		}
		#end
	}

	var logoBl:FlxSprite;
	var gfDance:FlxSprite;
	var danceLeft:Bool = false;
	var titleText:FlxSprite;
	var swagShader:ColorSwap = null;

	// ── Title entrance / idle rock / exit animation state ──
	var titleBG:FlxSprite;
	var logoBaseX:Float = 0;
	var logoBaseY:Float = 0;
	var titleBaseX:Float = 0;
	var titleBaseY:Float = 0;
	var swaySpeed:Float = 1.8;
	var logoSwayTime:Float = 0;
	var logoSwayReady:Bool = false;
	var titleTextReady:Bool = false;
	var entranceStarted:Bool = false;
	var exitStarted:Bool = false;

	#if ONLINE_ALLOWED
		// Starts the standard menu theme and fades it in -- the same thing `startIntro()` already
		// does. There is no "favourite song as the menu theme" mode here (this engine has neither
		// ClientPrefs.data.favsAsMenuTheme / favSongs nor TrackSong), so only the standard theme is
		// handled.
		// The theme is a no-op while music is already playing. Guarded by ONLINE_ALLOWED so the
		// macro-off build stays untouched.
	public static function playFreakyMusic(?volume:Float = 0.7):Void
	{
		if (FlxG.sound.music != null && FlxG.sound.music.playing)
			return;

		if (FlxG.sound.music != null)
			FlxG.sound.music.stop();

		FreeplayState.destroyFreeplayVocals();

		FlxG.sound.playMusic(Paths.music('freakyMenu'), 0);
		FlxG.sound.music.fadeIn(4, 0, volume);
	}
	#end

	function startIntro()
	{
		#if HSCRIPT_ALLOWED
		callOnHscript('onStartIntro', []);
		#end
		if (!initialized)
		{
			if(FlxG.sound.music == null) {
				FlxG.sound.playMusic(Paths.music('freakyMenu'), 0);
			}
		}

		Conductor.changeBPM(titleJSON.bpm);
		persistentUpdate = true;

		titleBG = new FlxSprite();

		if (titleJSON.backgroundSprite != null && titleJSON.backgroundSprite.length > 0 && titleJSON.backgroundSprite != "none"){
			titleBG.loadGraphic(Paths.image(titleJSON.backgroundSprite));
		}else{
			titleBG.makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		}

		add(titleBG);

		logoBl = new FlxSprite(titleJSON.titlex, titleJSON.titley);
		logoBl.frames = Paths.getSparrowAtlas('logoBumpin');

		logoBl.antialiasing = ClientPrefs.data.globalAntialiasing;
		logoBl.animation.addByPrefix('bump', 'logo bumpin', 24, false);
		logoBl.animation.play('bump');
		logoBl.updateHitbox();


		swagShader = new ColorSwap();
		gfDance = new FlxSprite(titleJSON.gfx, titleJSON.gfy);

		var easterEgg:String = FlxG.save.data.psychDevsEasterEgg;
		if(easterEgg == null) easterEgg = '';

		switch(easterEgg.toUpperCase())
		{
			#if TITLE_SCREEN_EASTER_EGG
			case 'SHADOW':
				gfDance.frames = Paths.getSparrowAtlas('ShadowBump');
				gfDance.animation.addByPrefix('danceLeft', 'Shadow Title Bump', 24);
				gfDance.animation.addByPrefix('danceRight', 'Shadow Title Bump', 24);
			case 'RIVER':
				gfDance.frames = Paths.getSparrowAtlas('RiverBump');
				gfDance.animation.addByIndices('danceLeft', 'River Title Bump', [15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29], "", 24, false);
				gfDance.animation.addByIndices('danceRight', 'River Title Bump', [29, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14], "", 24, false);
			case 'SHUBS':
				gfDance.frames = Paths.getSparrowAtlas('ShubBump');
				gfDance.animation.addByPrefix('danceLeft', 'Shub Title Bump', 24, false);
				gfDance.animation.addByPrefix('danceRight', 'Shub Title Bump', 24, false);
			case 'BBPANZU':
				gfDance.frames = Paths.getSparrowAtlas('BBBump');
				gfDance.animation.addByIndices('danceLeft', 'BB Title Bump', [14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27], "", 24, false);
				gfDance.animation.addByIndices('danceRight', 'BB Title Bump', [27, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13], "", 24, false);
			#end

			default:
				gfDance.frames = Paths.getSparrowAtlas('gfDanceTitle');
				gfDance.animation.addByIndices('danceLeft', 'gfDance', [30, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14], "", 24, false);
				gfDance.animation.addByIndices('danceRight', 'gfDance', [15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29], "", 24, false);
		}
		gfDance.antialiasing = ClientPrefs.data.globalAntialiasing;

		add(gfDance);
		gfDance.shader = swagShader.shader;
		add(logoBl);
		logoBl.shader = swagShader.shader;

		titleText = new FlxSprite(titleJSON.startx, titleJSON.starty);
		#if (desktop && MODS_ALLOWED)
		var path = "mods/" + Paths.currentModDirectory + "/images/titleEnter.png";
		if (!FileSystem.exists(path)){
			path = "mods/images/titleEnter.png";
		}
		if (!FileSystem.exists(path)){
			path = "assets/images/titleEnter.png";
		}
		titleText.frames = FlxAtlasFrames.fromSparrow(BitmapData.fromFile(path),File.getContent(StringTools.replace(path,".png",".xml")));
		#else

		titleText.frames = Paths.getSparrowAtlas('titleEnter');
		#end
		var animFrames:Array<FlxFrame> = [];
		@:privateAccess {
			titleText.animation.findByPrefix(animFrames, "ENTER IDLE");
			titleText.animation.findByPrefix(animFrames, "ENTER FREEZE");
		}

		if (animFrames.length > 0) {
			newTitle = true;

			titleText.animation.addByPrefix('idle', "ENTER IDLE", 24);
			titleText.animation.addByPrefix('press', ClientPrefs.data.flashing ? "ENTER PRESSED" : "ENTER FREEZE", 24);
		}
		else {
			newTitle = false;

			titleText.animation.addByPrefix('idle', "Press Enter to Begin", 24);
			titleText.animation.addByPrefix('press', "ENTER PRESSED", 24);
		}

		titleText.antialiasing = ClientPrefs.data.globalAntialiasing;
		titleText.animation.play('idle');
		titleText.updateHitbox();
		add(titleText);

		// Remember resting poses for the entrance/rock/exit tweens.
		logoBaseX = logoBl.x;
		logoBaseY = logoBl.y;
		titleBaseX = titleText.x;
		titleBaseY = titleText.y;

		var swayBPM:Float = 102;
		if (titleJSON.bpm > 0)
			swayBPM = titleJSON.bpm;
		// One full left-right rock every 4 beats keeps the swing in sync with the music.
		swaySpeed = Math.PI * 2 / ((60 / swayBPM) * 4);

		var logo:FlxSprite = new FlxSprite().loadGraphic(Paths.image('logo'));
		logo.screenCenter();
		logo.antialiasing = ClientPrefs.data.globalAntialiasing;

		credGroup = new FlxGroup();
		add(credGroup);
		textGroup = new FlxGroup();

		blackScreen = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		credGroup.add(blackScreen);

		credTextShit = new Alphabet(0, 0, "", true);
		credTextShit.screenCenter();

		credTextShit.visible = false;

		ngSpr = new FlxSprite(0, FlxG.height * 0.52).loadGraphic(Paths.image('newgrounds_logo'));
		add(ngSpr);
		ngSpr.visible = false;
		ngSpr.setGraphicSize(Std.int(ngSpr.width * 0.8));
		ngSpr.updateHitbox();
		ngSpr.screenCenter(X);
		ngSpr.antialiasing = ClientPrefs.data.globalAntialiasing;

		FlxTween.tween(credTextShit, {y: credTextShit.y + 20}, 2.9, {ease: FlxEase.quadInOut, type: PINGPONG});
		
		if (initialized)
			skipIntro();
		else
			initialized = true;
	}

	function flashReveal(duration:Float = 0.6):Void
	{
		// Short, soft flash so the slide-up entrance stays visible underneath it.
		FlxG.camera.flash(ClientPrefs.data.flashing ? FlxColor.WHITE : 0x77FFFFFF, duration);
	}

	function startTitleEntrance():Void
	{
		if (entranceStarted || logoBl == null) return;
		entranceStarted = true;
		exitStarted = false;
		logoSwayReady = titleTextReady = false;
		logoSwayTime = 0;

		var dropY:Float = FlxG.height + 140;

		// Logo: rockets up from below the screen, slams to a stop, dips once from the impact.
		logoBl.x = logoBaseX;
		logoBl.y = dropY;
		FlxTween.tween(logoBl, {y: logoBaseY}, 0.65, {startDelay: 0.2, ease: FlxEase.expoOut, onComplete:
			function(twn:FlxTween)
			{
				logoBl.animation.play('bump', true); // impact pulse right on the hard stop
				FlxTween.tween(logoBl, {y: logoBaseY + 9}, 0.05, {ease: FlxEase.quadIn, onComplete:
					function(twn2:FlxTween)
					{
						FlxTween.tween(logoBl, {y: logoBaseY}, 0.14, {ease: FlxEase.quadOut, onComplete:
							function(twn3:FlxTween)
							{
								logoSwayReady = true;
							}});
					}});
			}
		});

		// "Press Enter" text: rises last and fades in; the idle pulse takes over afterwards.
		titleText.x = titleBaseX;
		titleText.y = dropY + 40;
		titleText.alpha = 0;
		FlxTween.tween(titleText, {y: titleBaseY, alpha: 1}, 0.55, {startDelay: 0.6, ease: FlxEase.expoOut, onComplete:
			function(twn:FlxTween)
			{
				titleTextReady = true;
			}});
	}

	function startTitleExit():Void
	{
		if (exitStarted || logoBl == null) return;
		exitStarted = true;
		logoSwayReady = titleTextReady = false;

		// Kill any in-flight entrance tweens and snap to the resting pose.
		FlxTween.cancelTweensOf(logoBl);
		FlxTween.cancelTweensOf(titleText);
		logoBl.y = logoBaseY;
		logoBl.angle = 0;
		titleText.y = titleBaseY;
		titleText.alpha = 1;

		// The screen drops away like a floor giving way: the background sinks
		// first, everything else follows with a slight lag so the fall reads
		// as a chain. Distance covers the highest top edge so nothing stays visible.
		var minTop:Float = Math.min(gfDance.y, Math.min(logoBl.y, titleText.y));
		if (titleBG != null)
			minTop = Math.min(minTop, titleBG.y);
		var dropDist:Float = FlxG.height + 60 - minTop;
		FlxTween.tween(titleBG, {y: titleBG.y + dropDist}, 0.55, {ease: FlxEase.quadIn});
		FlxTween.tween(gfDance, {y: gfDance.y + dropDist}, 0.55, {startDelay: 0.05, ease: FlxEase.quadIn});
		FlxTween.tween(logoBl, {y: logoBl.y + dropDist}, 0.55, {startDelay: 0.1, ease: FlxEase.quadIn});
		FlxTween.tween(titleText, {y: titleText.y + dropDist}, 0.55, {startDelay: 0.15, ease: FlxEase.quadIn});
	}

	function getIntroTextShit():Array<Array<String>>
	{
		var fullText:String = Assets.getText(Paths.txt('introText'));

		var firstArray:Array<String> = fullText.split('\n');
		var swagGoodArray:Array<Array<String>> = [];

		for (i in firstArray)
		{
			swagGoodArray.push(i.split('--'));
		}

		return swagGoodArray;
	}

	var transitioning:Bool = false;
	private static var playJingle:Bool = false;

	var newTitle:Bool = false;
	var titleTimer:Float = 0;

	override function update(elapsed:Float)
	{
		#if MODS_ALLOWED
		// On the first update frame, check if TitleState should be replaced
		// by the active mod's stateRedirects.
		if (!_redirectChecked) {
			_redirectChecked = true;
			if (ModState.stateReplacements.exists("TitleState")) {
				MusicBeatState.switchState(new ModState(ModState.stateReplacements["TitleState"]));
				return;
			}
		}
		#end

		#if LUA_ALLOWED
		callOnLuas('onUpdate', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdate', [elapsed]);
		#end

		if (FlxG.sound.music != null)
			Conductor.songPosition = FlxG.sound.music.time;

		var pressedEnter:Bool = FlxG.keys.justPressed.ENTER || controls.ACCEPT || FlxG.mouse.justPressed;

		#if mobile
		for (touch in FlxG.touches.list)
		{
			if (touch.justPressed)
			{
				pressedEnter = true;
			}
		}
		#end

		var gamepad:FlxGamepad = FlxG.gamepads.lastActive;

		if (gamepad != null)
		{
			if (gamepad.justPressed.START)
				pressedEnter = true;

			#if switch
			if (gamepad.justPressed.B)
				pressedEnter = true;
			#end
		}

		if (newTitle) {
			titleTimer += CoolUtil.boundTo(elapsed, 0, 1);
			if (titleTimer > 2) titleTimer -= 2;
		}

		if (initialized && !transitioning && skippedIntro)
		{
			if (newTitle && !pressedEnter && titleTextReady)
			{
				var timer:Float = titleTimer;
				if (timer >= 1)
					timer = (-timer) + 2;

				timer = FlxEase.quadInOut(timer);

				titleText.color = FlxColor.interpolate(titleTextColors[0], titleTextColors[1], timer);
				titleText.alpha = FlxMath.lerp(titleTextAlphas[0], titleTextAlphas[1], timer);
			}

			if(pressedEnter)
			{
				titleText.color = FlxColor.WHITE;
				titleText.alpha = 1;

				if(titleText != null) titleText.animation.play('press');

				FlxG.camera.flash(ClientPrefs.data.flashing ? FlxColor.WHITE : 0x4CFFFFFF, 0.5);
				FlxG.sound.play(Paths.sound('confirmMenu'), 0.7);

				// Slide the whole title screen out before the state switch kicks in.
				startTitleExit();

				transitioning = true;

				new FlxTimer().start(1, function(tmr:FlxTimer)
				{
					if (mustUpdate) {
						MusicBeatState.switchState(new OutdatedState());
					} else {
						MusicBeatState.switchState(new MainMenuState());
					}
					closedState = true;
				});
			}
			#if TITLE_SCREEN_EASTER_EGG
			else if (FlxG.keys.firstJustPressed() != FlxKey.NONE)
			{
				var keyPressed:FlxKey = FlxG.keys.firstJustPressed();
				var keyName:String = Std.string(keyPressed);
				if(allowedKeys.contains(keyName)) {
					easterEggKeysBuffer += keyName;
					if(easterEggKeysBuffer.length >= 32) easterEggKeysBuffer = easterEggKeysBuffer.substring(1);

					for (wordRaw in easterEggKeys)
					{
						var word:String = wordRaw.toUpperCase();
						if (easterEggKeysBuffer.contains(word))
						{
							if (FlxG.save.data.psychDevsEasterEgg == word)
								FlxG.save.data.psychDevsEasterEgg = '';
							else
								FlxG.save.data.psychDevsEasterEgg = word;
							FlxG.save.flush();

							FlxG.sound.play(Paths.sound('ToggleJingle'));

							var black:FlxSprite = new FlxSprite(0, 0).makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
							black.alpha = 0;
							add(black);

							FlxTween.tween(black, {alpha: 1}, 1, {onComplete:
								function(twn:FlxTween) {
									FlxTransitionableState.skipNextTransIn = true;
									FlxTransitionableState.skipNextTransOut = true;
									MusicBeatState.switchState(new TitleState());
								}
							});
							FlxG.sound.music.fadeOut();
							if(FreeplayState.vocals != null)
							{
								FreeplayState.vocals.fadeOut();
							}
							closedState = true;
							transitioning = true;
							playJingle = true;
							easterEggKeysBuffer = '';
							break;
						}
					}
				}
			}
			#end
		}

		if (initialized && pressedEnter && !skippedIntro)
		{
			skipIntro();
		}

		// Idle rock: once settled, the logo gently swings left-right around its center.
		if (logoSwayReady && !exitStarted && logoBl != null)
		{
			logoSwayTime += elapsed;
			logoBl.angle = Math.sin(logoSwayTime * swaySpeed) * 3;
		}

		if(swagShader != null)
		{
			if(controls.UI_LEFT) swagShader.hue -= elapsed * 0.1;
			if(controls.UI_RIGHT) swagShader.hue += elapsed * 0.1;
		}

		#if LUA_ALLOWED
		callOnLuas('onUpdatePost', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdatePost', [elapsed]);
		#end
		super.update(elapsed);
	}

	function createCoolText(textArray:Array<String>, ?offset:Float = 0)
	{
		for (i in 0...textArray.length)
		{
			var money:Alphabet = new Alphabet(0, 0, textArray[i], true);
			money.screenCenter(X);
			money.y += (i * 60) + 200 + offset;
			if(credGroup != null && textGroup != null) {
				credGroup.add(money);
				textGroup.add(money);
			}
		}
	}

	function addMoreText(text:String, ?offset:Float = 0)
	{
		if(textGroup != null && credGroup != null) {
			var coolText:Alphabet = new Alphabet(0, 0, text, true);
			coolText.screenCenter(X);
			coolText.y += (textGroup.length * 60) + 200 + offset;
			credGroup.add(coolText);
			textGroup.add(coolText);
		}
	}

	function deleteCoolText()
	{
		while (textGroup.members.length > 0)
		{
			credGroup.remove(textGroup.members[0], true);
			textGroup.remove(textGroup.members[0], true);
		}
	}

	private var sickBeats:Int = 0;
	public static var closedState:Bool = false;
	override function beatHit()
	{
		super.beatHit();
		#if HSCRIPT_ALLOWED
		callOnHscript('onBeatHit', []);
		#end

		if(logoBl != null)
			logoBl.animation.play('bump', true);

		if(gfDance != null) {
			danceLeft = !danceLeft;
			if (danceLeft)
				gfDance.animation.play('danceRight');
			else
				gfDance.animation.play('danceLeft');
		}

		if(!closedState) {
			sickBeats++;
			switch (sickBeats)
			{
				case 1:
					FlxG.sound.playMusic(Paths.music('freakyMenu'), 0);
					FlxG.sound.music.fadeIn(4, 0, 0.7);
				case 2:
					#if PSYCH_WATERMARKS
					createCoolText(['Seiun Engine by'], 15);
					#else
					createCoolText(['ninjamuffin99', 'phantomArcade', 'kawaisprite', 'evilsk8er']);
					#end
				case 4:
					#if PSYCH_WATERMARKS
					addMoreText('Mo_hong', 15);
					addMoreText('Psych Engine by ', 15);
					addMoreText('Shadow Mario', 15);
					addMoreText('RiverOaken', 15);
					addMoreText('shubs', 15);
					#else
					addMoreText('present');
					#end
				case 5:
					deleteCoolText();
				case 6:
					#if PSYCH_WATERMARKS
					createCoolText(['Not associated', 'with'], -40);
					#else
					createCoolText(['In association', 'with'], -40);
					#end
				case 8:
					addMoreText('newgrounds', -40);
					ngSpr.visible = true;
				case 9:
					deleteCoolText();
					ngSpr.visible = false;
				case 10:
					createCoolText([curWacky[0]]);
				case 12:
					addMoreText(curWacky[1]);
				case 13:
					deleteCoolText();
				case 14:
					addMoreText('Friday');
				case 15:
					addMoreText('Night');
				case 16:
					addMoreText('Funkin');
				case 17:
					skipIntro();
			}
		}
	}

	var skippedIntro:Bool = false;
	var increaseVolume:Bool = false;
	function skipIntro():Void
	{
		#if HSCRIPT_ALLOWED
		callOnHscript('onSkipIntro', []);
		#end
		if (!skippedIntro)
		{
			if (playJingle)
			{
				var easteregg:String = FlxG.save.data.psychDevsEasterEgg;
				if (easteregg == null) easteregg = '';
				easteregg = easteregg.toUpperCase();

				var sound:FlxSound = null;
				switch(easteregg)
				{
					case 'RIVER':
						sound = FlxG.sound.play(Paths.sound('JingleRiver'));
					case 'SHUBS':
						sound = FlxG.sound.play(Paths.sound('JingleShubs'));
					case 'SHADOW':
						FlxG.sound.play(Paths.sound('JingleShadow'));
					case 'BBPANZU':
						sound = FlxG.sound.play(Paths.sound('JingleBB'));

					default:
						remove(ngSpr);
						remove(credGroup);
						flashReveal(0.6);
						startTitleEntrance();
						skippedIntro = true;
						playJingle = false;

						FlxG.sound.playMusic(Paths.music('freakyMenu'), 0);
						FlxG.sound.music.fadeIn(4, 0, 0.7);
						return;
				}

				transitioning = true;
				if(easteregg == 'SHADOW')
				{
					new FlxTimer().start(3.2, function(tmr:FlxTimer)
					{
						remove(ngSpr);
						remove(credGroup);
						flashReveal(0.6);
						startTitleEntrance();
						transitioning = false;
					});
				}
				else
				{
					remove(ngSpr);
					remove(credGroup);
					flashReveal(0.6);
					startTitleEntrance();
					sound.onComplete = function() {
						FlxG.sound.playMusic(Paths.music('freakyMenu'), 0);
						FlxG.sound.music.fadeIn(4, 0, 0.7);
						transitioning = false;
					};
				}
				playJingle = false;
			}
			else
			{
				remove(ngSpr);
				remove(credGroup);
				flashReveal(0.6);
				startTitleEntrance();

				var easteregg:String = FlxG.save.data.psychDevsEasterEgg;
				if (easteregg == null) easteregg = '';
				easteregg = easteregg.toUpperCase();
				#if TITLE_SCREEN_EASTER_EGG
				if(easteregg == 'SHADOW')
				{
					FlxG.sound.music.fadeOut();
					if(FreeplayState.vocals != null)
					{
						FreeplayState.vocals.fadeOut();
					}
				}
				#end
			}
			skippedIntro = true;
		}
	}
	override function destroy()
	{
		instance = null;
		super.destroy();
	}
}
