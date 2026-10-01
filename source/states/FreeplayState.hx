package states;

import backend.seiun.ui.*;
import substates.ResetScoreSubState;
import substates.GameplayChangersSubstate;
import substates.ScoreHistorySubstate;
import substates.ModSelectSubstate;

import flixel.ui.FlxBar;
#if ONLINE_ALLOWED
// Only the `LockInSprite`/`Heart` helpers added at the bottom of this file under
// ONLINE_ALLOWED need this type; importing it inside the guard keeps the macro-off
// module imports (and therefore the macro-off build) unchanged.
import flixel.system.FlxAssets.FlxGraphicAsset;
// Needed for online song selection sync and for returning to the room from Freeplay.
import online.GameClient;
#end
import flixel.effects.FlxFlicker;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.FlxCamera;
#if cpp
import Discord.DiscordClient;
#end
import editors.ChartingState;
import flash.text.TextField;
import flixel.addons.display.FlxGridOverlay;
import flixel.addons.transition.FlxTransitionableState;
import lime.utils.Assets;
import flixel.system.FlxSound;
import flixel.util.FlxTimer;
import openfl.utils.Assets as OpenFlAssets;
import WeekData;
import mohong.TraceManager;
import flixel.input.keyboard.FlxKey;
#if MODS_ALLOWED
import sys.FileSystem;
#end

using StringTools;

class FreeplayState extends SeiunMenuState
{
	public static var instance:FreeplayState = null;
	public var songs:Array<SongMetadata> = [];
	public var playingMusic:Bool = false;
	public var paused:Bool = false;
	public var curTime:Float = 0;
	public var previewSongTxt:FlxText;
	public var previewTimeTxt:FlxText;
	public var progressBar:FlxBar;
	public var confirmTween:FlxTween;
	public var canInput:Bool = true; 
	public var previewBG:FlxSprite;
	public var previewGlow:FlxSprite;
	public var previewLabel:FlxText;
	public var previewEq:FlxTypedGroup<FlxSprite>;
	public var previewEqBars:Array<FlxSprite> = [];
	public var previewGroup:FlxTypedGroup<FlxSprite>;
	public var previewExiting:Bool = false;
	public var wasVisible:Map<FlxSprite, Bool> = new Map(); 
	public var playbackRate:Float = 1.0;
	public var selector:FlxText;
	public static var curSelected:Int = 0;
	public static var vocals:FlxSound = null;
	public var currentsongname:String = "";
	public var curDifficulty:Int = -1;
	public static var lastDifficultyName:String = '';
	public var scoreBG:FlxSprite;
	public var scoreText:FlxText;
	public var diffText:FlxText;
	/** Multi-file (segmented) chart state of the selected song; see ChartParts. */
	public var multiFileText:FlxText;
	public var lerpScore:Int = 0;
	public var lerpRating:Float = 0;
	public var intendedScore:Int = 0;
	public var intendedRating:Float = 0;
	
	public var grpSongs:FlxTypedGroup<Alphabet>;
	public var iconArray:Array<HealthIcon> = [];

	public var bg:FlxSprite;
	public var intendedColor:Int;
	public var colorTween:FlxTween;
	public var mouseOverlapIndex:Int = -1;
	
	private var curPlaying:Bool = false;
	private var holdTime:Float = 0;
	private var instPlaying:Int = -1;

	// === Seiun menu animation layers ===
	var particleGroup:FlxTypedGroup<FlxSprite>;
	var auroraGlowA:FlxSprite;
	var auroraGlowB:FlxSprite;
	var selGlow:FlxSprite;
	var selCursor:Alphabet;
	var ambientTimer:Float = 0;
	var autoPreviewNext:Bool = false;
	var autoMusicActive:Bool = false;
	var holdingNav:Bool = false;
	var holdStartSelected:Int = -1;
	var autoMusicSong:String = '';
	var autoMusicTimer:FlxTimer = null;

	// 新增：错误提示相关变量
	public var missingTextBG:FlxSprite;
	public var missingText:FlxText;
	public var isShowingError:Bool = false;

	// === NEW: Mod folder filtering ===
	public static inline var ALL_FILTER:String = '__ALL__'; // Sentinel for "show all songs"
	public var modList:Array<String> = [];        // Unique mod folders (sorted, vanilla first, ALL_FILTER first)
	public var filteredSongIndices:Array<Int> = []; // Maps visual index → songs array index
	static var curSelectedMod:Int = 0;            // Persists across state recreations
	static var lastSelectedModFolder:String = ALL_FILTER;  // Folder name for restoring after state rebuild; starts at "All"
	var modFilterText:FlxText;                    // Shows current filter name

	override function create()
	{
		Paths.clearStoredMemory();
		Paths.clearUnusedMemory();
		instance = this;
		persistentUpdate = true;
		PlayState.isStoryMode = false;
		WeekData.reloadWeekFiles(false);
		FlxG.mouse.visible = true;
		#if cpp
		// Updating Discord Rich Presence
		DiscordClient.changePresence("In the Menus", null);
		#end

		for (i in 0...WeekData.weeksList.length) {
			if(weekIsLocked(WeekData.weeksList[i])) continue;

			var leWeek:WeekData = WeekData.weeksLoaded.get(WeekData.weeksList[i]);
			var leSongs:Array<String> = [];
			var leChars:Array<String> = [];

			for (j in 0...leWeek.songs.length)
			{
				leSongs.push(leWeek.songs[j][0]);
				leChars.push(leWeek.songs[j][1]);
			}

			WeekData.setDirectoryFromWeek(leWeek);
			for (song in leWeek.songs)
			{
				var colors:Array<Int> = song[2];
				if(colors == null || colors.length < 3)
				{
					colors = [146, 113, 253];
				}
				// Pass the week's mod folder to identify which mod this song belongs to
				var weekModFolder:String = (leWeek.folder != null && leWeek.folder.length > 0) ? leWeek.folder : '';
				addSong(song[0], i, song[1], FlxColor.fromRGB(colors[0], colors[1], colors[2]), weekModFolder);
			}
		}
		// The globally active mod (selected via MainMenuState's ModSelectSubstate)
		// always determines asset loading.  Freeplay's own mod filter is only
		// for song display — it does NOT change which mod's assets are used.
		// However, if the Freeplay filter is set to a specific mod folder, we
		// must point Paths.currentModDirectory there so PlayState can resolve
		// the mod's audio/images when the user enters a song.
		Paths.currentModDirectory = MainMenuState.selectedModFolder;

		// === Build mod folder list and restore last selected mod ===
		buildModList();
		FlxG.keys.preventDefaultKeys.remove(TAB);

		// Apply the restored filter: for ALL_FILTER keep the MainMenu mod,
		// for a specific mod switch to it.
		if (curSelectedMod >= 0 && curSelectedMod < modList.length)
		{
			var selMod:String = modList[curSelectedMod];
			if (selMod != ALL_FILTER) Paths.currentModDirectory = selMod;
		}

		/*		//KIND OF BROKEN NOW AND ALSO PRETTY USELESS//

		var initSonglist = CoolUtil.coolTextFile(Paths.txt('freeplaySonglist'));
		for (i in 0...initSonglist.length)
		{
			if(initSonglist[i] != null && initSonglist[i].length > 0) {
				var songArray:Array<String> = initSonglist[i].split(":");
				addSong(songArray[0], 0, songArray[1], Std.parseInt(songArray[2]));
			}
		}*/

		bg = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(bg);
		bg.screenCenter();

		if (MenuFX.enabled())
		{
			// ── Seiun aurora: drifting additive glows tinted by the song color ──
			auroraGlowA = MenuFX.makeGlow(900, 0xFFFD719B, 0.3);
			auroraGlowA.blend = ADD;
			auroraGlowA.scrollFactor.set(0, 0);
			auroraGlowA.screenCenter();
			add(auroraGlowA);

			auroraGlowB = MenuFX.makeGlow(740, 0xFF8A5CFF, 0.24);
			auroraGlowB.blend = ADD;
			auroraGlowB.scrollFactor.set(0, 0);
			auroraGlowB.screenCenter();
			add(auroraGlowB);
		}

		if (MenuFX.enabled())
		{
			// Halo that follows the selected song. Added before the song list so
			// it renders *behind* the text instead of washing it out.
			selGlow = MenuFX.makeGlow(300, 0xFFFFFFFF, 0.5);
			selGlow.scale.set(1.5, 0.8);
			selGlow.updateHitbox();
			selGlow.blend = ADD;
			selGlow.visible = false;
			add(selGlow);
		}

		grpSongs = new FlxTypedGroup<Alphabet>();
		add(grpSongs);

		if (MenuFX.enabled())
		{
			selCursor = new Alphabet(0, 0, '>', true);
			selCursor.visible = false;
			add(selCursor);
		}

		previewGroup = new FlxTypedGroup<FlxSprite>();

		previewBG = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		previewBG.alpha = 0;
		previewGroup.add(previewBG);

		// ── Seiun preview cosmetics: glow, "now playing" label, equalizer ──
		previewGlow = MenuFX.makeGlow(760, 0xFFFD719B, 0.5);
		previewGlow.blend = ADD;
		previewGlow.scrollFactor.set();
		previewGlow.screenCenter();
		previewGlow.alpha = 0;
		previewGroup.add(previewGlow);

		previewLabel = new FlxText(0, 0, FlxG.width, "NOW PLAYING", 22);
		previewLabel.setFormat(Paths.languageFont(), 22, 0xFFFFD6F4, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		previewLabel.borderSize = 2;
		previewLabel.scrollFactor.set();
		previewLabel.alpha = 0;
		previewGroup.add(previewLabel);

		previewEq = new FlxTypedGroup<FlxSprite>();
		for (i in 0...7)
		{
			var bar:FlxSprite = new FlxSprite(0, 0).makeGraphic(12, 72, FlxColor.WHITE);
			bar.antialiasing = false;
			bar.scrollFactor.set();
			bar.visible = false;
			previewEq.add(bar);
			previewEqBars.push(bar);
		}

		previewSongTxt = new FlxText(0, 0, FlxG.width, "", 44);
		previewSongTxt.setFormat(Paths.languageFont(), 44, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		previewSongTxt.borderSize = 3;
		previewSongTxt.scrollFactor.set();
		previewSongTxt.alpha = 0;
		previewGroup.add(previewSongTxt);

		previewTimeTxt = new FlxText(0, 0, FlxG.width, "", 22);
		previewTimeTxt.setFormat(Paths.languageFont(), 22, 0xFFFFE9F5, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		previewTimeTxt.borderSize = 2;
		previewTimeTxt.scrollFactor.set();
		previewTimeTxt.alpha = 0;
		previewGroup.add(previewTimeTxt);

		progressBar = new FlxBar(0, 0, LEFT_TO_RIGHT, Std.int(FlxG.width * 0.55), 18, null, "", 0, 100, true);
		progressBar.createFilledBar(0xFF1E1B2E, 0xFFFD719B);
		progressBar.scrollFactor.set();
		progressBar.alpha = 0;
		previewGroup.add(progressBar);

		previewGroup.visible = false;
		add(previewGroup);
		add(previewEq);

		// === Create mod filter header bar ===
		createModFilterUI();

		// === Only create song items for the currently selected mod folder ===
		rebuildFilteredSongs();
		WeekData.setDirectoryFromWeek();

		// Sync the asset directory with Freeplay's own mod filter.
		// This ensures PlayState loads the correct mod resources without touching
		// MainMenuState.selectedModFolder (the "fully loaded mod").
		// NOTE: must be placed AFTER WeekData.setDirectoryFromWeek() which resets to "".
		if (curSelectedMod >= 0 && curSelectedMod < modList.length)
		{
			var selMod:String = modList[curSelectedMod];
			if (selMod != ALL_FILTER) Paths.currentModDirectory = selMod;
		}

		// Always reload background and menu music from the (possibly updated) directory.
		// This also cleanly replaces any music started by PlayStateResultsSubstate / PauseSubState
		// before switching back here, so there is no one-frame "vanilla music" artifact.
		bg.loadGraphic(Paths.image('menuDesat'));
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		MenuFX.ensureMenuMusic(1);

		scoreText = new FlxText(FlxG.width * 0.7, 5, 0, "", 32);
		scoreText.setFormat(Paths.languageFont(), 32, FlxColor.WHITE, RIGHT);

		scoreBG = new FlxSprite(scoreText.x - 6, 0).makeGraphic(1, 66, 0xFF000000);
		scoreBG.alpha = 0.6;
		add(scoreBG);

		diffText = new FlxText(scoreText.x, scoreText.y + 36, 0, "", 24);
		diffText.font = Paths.font("vcr.ttf"); 
		add(diffText);

		// Which multi-file mode this song will load with, toggled in place with M (PC) / the
		// on-screen D button (Android). Screen-wide and right aligned, so neither a long localised
		// label nor the key hint can leave the screen; see updateMultiFileText().
		// Paths.languageFont(), not vcr.ttf: the label is localised, and vcrcn (the Chinese font the
		// language files select through their "ttf" key) is what carries the CJK glyphs.
		multiFileText = new FlxText(6, diffText.y + 28, FlxG.width - 12, "", 18);
		multiFileText.setFormat(Paths.languageFont(), 18, FlxColor.WHITE, RIGHT);
		multiFileText.alpha = 0.75;
		add(multiFileText);

		add(scoreText);

		missingTextBG = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		missingTextBG.alpha = 0.6;
		missingTextBG.visible = false;
		add(missingTextBG);
		
		missingText = new FlxText(50, 0, FlxG.width - 100, '', 24);
		missingText.setFormat(Paths.font("vcr.ttf"), 24, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		missingText.scrollFactor.set();
		missingText.visible = false;
		add(missingText);

		if(curSelected >= filteredSongIndices.length) curSelected = 0;
		var initSong = getCurrentSong();
		if(initSong != null) {
			bg.color = initSong.color;
			intendedColor = bg.color;
		}
		MenuFX.accentColor = bg.color;


		if(lastDifficultyName == '')
		{
			lastDifficultyName = CoolUtil.defaultDifficulty;
		}

		curDifficulty = Math.round(Math.max(0, CoolUtil.defaultDifficulties.indexOf(lastDifficultyName)));
		
		changeSelection();
		changeDiff();

		// ── Entry animation: songs cascade in with a stagger ──
		if (MenuFX.enabled())
		{
			particleGroup = new FlxTypedGroup<FlxSprite>();
			add(particleGroup);
		}
		for (i in 0...grpSongs.length)
		{
			var it = grpSongs.members[i];
			var icon = iconArray[i];
			var targetAlpha:Float = (i == curSelected) ? 1 : 0.6;
			// Stagger by distance from the selected song so the song the player
			// last chose (even at the bottom of the list) appears immediately.
			var delay:Float = Math.min(Math.abs(i - curSelected) * 0.035, 0.4);
			it.alpha = 0;
			icon.alpha = 0;
			FlxTween.tween(it, {alpha: targetAlpha}, 0.3, {startDelay: delay, ease: FlxEase.sineOut});
			var baseScale:Float = (i == curSelected) ? 1.2 : 0.85;
			FlxTween.cancelTweensOf(icon.scale);
			icon.scale.set(baseScale * 0.5, baseScale * 0.5);
			FlxTween.tween(icon.scale, {x: baseScale, y: baseScale}, 0.4, {startDelay: delay, ease: FlxEase.backOut});
			FlxTween.tween(icon, {alpha: targetAlpha}, 0.3, {startDelay: delay, ease: FlxEase.sineOut});
		}

		#if PRELOAD_ALL
		// Auto-play the selected song's BGM after the menu settles in
		if (ClientPrefs.data.freeplayAutoPreview)
			new FlxTimer().start(1.1, function(tmr:FlxTimer)
			{
				if (ClientPrefs.data.freeplayAutoPreview && !playingMusic && !paused && canInput)
					startAutoMusic();
			});
		#end

		var swag:Alphabet = new Alphabet(1, 0, "swag");

		// JUST DOIN THIS SHIT FOR TESTING!!!
		/* 
			var md:String = Markdown.markdownToHtml(Assets.getText('CHANGELOG.md'));

			var texFel:TextField = new TextField();
			texFel.width = FlxG.width;
			texFel.height = FlxG.height;
			// texFel.
			texFel.htmlText = md;

			FlxG.stage.addChild(texFel);

			// scoreText.textField.htmlText = md;

			trace(md);
		 */

		var textBG:FlxSprite = new FlxSprite(0, FlxG.height - 26).makeGraphic(FlxG.width, 26, 0xFF000000);
		textBG.alpha = 0.6;
		add(textBG);


		#if PRELOAD_ALL
		var leText:String = ClientPrefs.touchUIEnabled()
			? Language.get("FreeplayState.leText.android", "Press X to listen to the Song / Press C to open the Gameplay Changers Menu / Press Y to Reset your Score and Accuracy. / Press V to view the Score History.")
			: Language.get("FreeplayState.leText", "Press SPACE to listen to the Song / Press CTRL to open the Gameplay Changers Menu / Press RESET to Reset your Score and Accuracy. / Press H to view the Score History.");
		var size:Int = 16;

		#else
		var leText:String = ClientPrefs.touchUIEnabled()
			? Language.get("FreeplayState.leText.NOTRELOAD_ALL.android", "Press C to open the Gameplay Changers Menu / Press Y to Reset your Score and Accuracy. / Press V to view the Score History.")
			: Language.get("FreeplayState.leText.NOTRELOAD_ALL", "Press CTRL to open the Gameplay Changers Menu / Press RESET to Reset your Score and Accuracy. / Press H to view the Score History.");
		var size:Int = 18;

		#end
		var text:FlxText = new FlxText(textBG.x, textBG.y + 4, FlxG.width, leText, size);
		text.setFormat(Paths.languageFont(), size, FlxColor.WHITE, RIGHT);
		text.scrollFactor.set();
		add(text);
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(LEFT_FULL, A_B_C_V_X_Y_D);
		#end
		super.create();

		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end
	}


	override function closeSubState() {
		if (pendingModIndex >= 0)
		{
			applyPendingModSelection();
		}
		changeSelection(0, false);
		persistentUpdate = true;
		canInput = true;
		#if (TOUCH_CONTROLS || desktop)
		removeVirtualPad();
		addVirtualPad(LEFT_FULL, A_B_C_V_X_Y_D);
		#end
		super.closeSubState();
	}

	public function addSong(songName:String, weekNum:Int, songCharacter:String, color:Int, ?modFolder:String = '')
	{
		songs.push(new SongMetadata(songName, weekNum, songCharacter, color, modFolder));
	}

	// === NEW: Mod folder filtering functions ===

	/** Get the real songs[] index for the currently selected filtered item */
	function getRealSelectedIndex():Int
	{
		if (filteredSongIndices.length == 0) return -1;
		if (curSelected < 0 || curSelected >= filteredSongIndices.length) return -1;
		return filteredSongIndices[curSelected];
	}

	/** Get the current SongMetadata from the filtered list */
	public function getCurrentSong():SongMetadata
	{
		var idx = getRealSelectedIndex();
		return (idx >= 0) ? songs[idx] : null;
	}

	function buildModList()
	{
		modList = [];
		// "All Songs" filter goes first
		modList.push(ALL_FILTER);
		for (song in songs)
		{
			var mf:String = (song.modFolder != null && song.modFolder.length > 0) ? song.modFolder : '';
			if (!modList.contains(mf))
				modList.push(mf);
		}
		// Sort the non-sentinel entries: vanilla first, then alphabetically
		var tail:Array<String> = modList.filter(function(v) return v != ALL_FILTER);
		tail.sort(function(a, b) {
			if (a == '') return -1;
			if (b == '') return 1;
			return (a < b) ? -1 : ((a > b) ? 1 : 0);
		});
		modList = [ALL_FILTER].concat(tail);

		// Restore previously selected mod:
		// - If lastSelectedModFolder is ALL_FILTER (initial/default), stay on "All" (index 0).
		// - Otherwise try to restore the exact folder the user picked (including '' for Vanilla).
		curSelectedMod = 0;
		if (lastSelectedModFolder != ALL_FILTER)
		{
			var idx = modList.indexOf(lastSelectedModFolder);
			if (idx >= 0) curSelectedMod = idx;
		}
		if (curSelectedMod >= modList.length) curSelectedMod = 0;
	}

	function createModFilterUI()
	{
		// Current filter name (top-left)
		modFilterText = new FlxText(10, 10, 0, '', 20);
		modFilterText.setFormat(Paths.languageFont(), 20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		modFilterText.borderSize = 1.5;
		modFilterText.scrollFactor.set();
		add(modFilterText);

		// Small hint for mod switching
		var hint = new FlxText(FlxG.width - 5, FlxG.height - 50, 0,
			ClientPrefs.touchUIEnabled()
				? Language.get('Mod.hint.android', '[G] Switch Mod')
				: Language.get('Mod.hint', '[TAB] Switch Mod'),
			16);
		hint.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, RIGHT);
		hint.alpha = 0.5;
		hint.x = FlxG.width - hint.width - 10;
		add(hint);
	}

	function refreshModFilterUI()
	{
		updateModFilterText();
	}

	// Pending mod switch (set by substate callback, applied in closeSubState)
	var pendingModIndex:Int = -1;

	function openModSelect()
	{
		// Stop preview if playing
		if (playingMusic) stopPreview();

		pendingModIndex = -1;
		persistentUpdate = false;
		var substate = new ModSelectSubstate(
			modList,
			curSelectedMod,
			function(newModIndex:Int) {
				pendingModIndex = newModIndex;
			},
			function() {
				// Cancel - do nothing
			}
		);
		// Freeplay 的模组切换仅用于过滤歌曲列表，不涉及游戏重启，隐藏重启警告
		substate.suppressRestartWarning = true;
		openSubState(substate);
	}

	function applyPendingModSelection()
	{
		if (pendingModIndex < 0 || pendingModIndex >= modList.length || pendingModIndex == curSelectedMod)
		{
			pendingModIndex = -1;
			return;
		}

		curSelectedMod = pendingModIndex;
		lastSelectedModFolder = modList[curSelectedMod]; // Save for next state creation
		pendingModIndex = -1;
		curSelected = 0;
		holdTime = 0;

		// When the user picks a different mod filter via TAB, switch asset
		// loading to that mod so background, character icons, menu music etc.
		// resolve correctly.  This does NOT affect the "fully loaded mod"
		// selected in MainMenuState — that one controls TitleState, window
		// title/icon and other global aspects.
		var modFolder:String = modList[curSelectedMod];
		if (modFolder == ALL_FILTER)
		{
			// "All" filter — keep MainMenu's active mod for asset loading
			Paths.currentModDirectory = MainMenuState.selectedModFolder;
		}
		else
		{
			Paths.currentModDirectory = modFolder;
		}

		// Reload background image from the (possibly new) mod — for ALL_FILTER
		// this stays on MainMenu's mod so the background is consistent.
		bg.loadGraphic(Paths.image('menuDesat'));
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;

		// Rebuild song list with the new mod's songs
		rebuildFilteredSongs();
		changeSelection(0, false);
		changeDiff();

		#if PRELOAD_ALL
		// Reload music: auto BGM follows the new selection, otherwise menu music
		if (ClientPrefs.data.freeplayAutoPreview && !playingMusic && !paused)
			scheduleAutoMusic(0.1);
		else
			MenuFX.playMenuMusic(1);
		#else
		MenuFX.playMenuMusic(1);
		#end

		FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
	}

	function rebuildFilteredSongs()
	{
		// Clear existing song display
		grpSongs.clear();
		for (icon in iconArray)
		{
			remove(icon);
			icon.destroy();
		}
		iconArray = [];
		mouseOverlapIndex = -1; // Reset mouse tracking to prevent stale index crash

		// Build filtered indices
		var currentModFolder:String = modList[curSelectedMod];
		var isAllFilter:Bool = (currentModFolder == ALL_FILTER);
		filteredSongIndices = [];
		for (i in 0...songs.length)
		{
			if (isAllFilter)
			{
				filteredSongIndices.push(i); // Show ALL songs
			}
			else
			{
				var mf:String = (songs[i].modFolder != null && songs[i].modFolder.length > 0) ? songs[i].modFolder : '';
				if (mf == currentModFolder)
					filteredSongIndices.push(i);
			}
		}

		// Create display items for filtered songs
		var savedModDir:String = Paths.currentModDirectory;
		for (vi in 0...filteredSongIndices.length)
		{
			var realIndex:Int = filteredSongIndices[vi];
			var songData:SongMetadata = songs[realIndex];

			// Use plain song name (mod is shown at top)
			var songText:Alphabet = new Alphabet(90, 325, songData.songName, true);
			songText.isMenuItem = true;
			songText.targetY = vi;
			grpSongs.add(songText);

			var maxWidth = 980;
			if (songText.width > maxWidth)
			{
				songText.scaleX = maxWidth / songText.width;
			}
			songText.snapToPosition();

			// Temporarily switch to the song's original mod folder to load its
			// character icon, then restore the active (fully loaded) mod.
			Paths.currentModDirectory = songData.folder;
			var icon:HealthIcon = new HealthIcon(songData.songCharacter);
			Paths.currentModDirectory = savedModDir;
			icon.sprTracker = songText;
			iconArray.push(icon);
			add(icon);
		}

		if (filteredSongIndices.length > 0)
		{
			if (curSelected >= filteredSongIndices.length) curSelected = filteredSongIndices.length - 1;
			if (curSelected < 0) curSelected = 0;
			bg.color = songs[filteredSongIndices[curSelected]].color;
			intendedColor = bg.color;
		}

		// Update the filter display text
		updateModFilterText();
	}

	function updateModFilterText()
	{
		if (modFilterText == null) return;
		var currentModFolder:String = modList[curSelectedMod];
		var label:String;
		if (currentModFolder == ALL_FILTER)
			label = Language.get("FreeplayState.allMods", "All Mods");
		else
			label = WeekData.getModFolderDisplayName(currentModFolder);
		modFilterText.text = Language.get("FreeplayState.modFilter", "Mod: ") + label;
	}

	public function weekIsLocked(name:String):Bool {
		var leWeek:WeekData = WeekData.weeksLoaded.get(name);
		return (!leWeek.startUnlocked && leWeek.weekBefore.length > 0 && (!StoryMenuState.weekCompleted.exists(leWeek.weekBefore) || !StoryMenuState.weekCompleted.get(leWeek.weekBefore)));
	}

	/*public function addWeek(songs:Array<String>, weekNum:Int, weekColor:Int, ?songCharacters:Array<String>)
	{
		if (songCharacters == null)
			songCharacters = ['bf'];

		var num:Int = 0;
		for (song in songs)
		{
			addSong(song, weekNum, songCharacters[num]);
			this.songs[this.songs.length-1].color = weekColor;

			if (songCharacters.length != 1)
				num++;
		}
	}*/

	override function update(elapsed:Float)
	{
		#if LUA_ALLOWED
		callOnLuas('onUpdate', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdate', [elapsed]);
		#end

		var curSong = getCurrentSong();
		if(curSong != null) currentsongname = curSong.songName;
		
		if (FlxG.sound.music.volume < 0.7)
		{
			FlxG.sound.music.volume += 0.5 * FlxG.elapsed;
		}

		// ── Seiun menu animations ──
		if (auroraGlowA != null)
		{
			var t:Float = MenuFX.time;
			var baseCol:Int = bg.color;
			MenuFX.driftGlow(auroraGlowA, t, FlxG.width * 0.42, FlxG.height * 0.42, 150, 75, 0.35, 0.28, 0, 0, 0.26, 0.08, 0.5, 0, 0xFFFD719B, 0, baseCol, 0.55);
			MenuFX.driftGlow(auroraGlowB, t, FlxG.width * 0.76, FlxG.height * 0.66, 125, 65, 0.23, 0.31, 2.1, 1.2, 0.2, 0.07, 0.42, 1.0, 0xFF8A5CFF, 0, baseCol, 0.45);
		}

		if (curSelected >= 0 && curSelected < grpSongs.length)
		{
			var sel:Alphabet = grpSongs.members[curSelected];

			if (selGlow != null)
			{
				selGlow.visible = !playingMusic;
				selGlow.x = sel.x + sel.width * 0.5 - selGlow.width * selGlow.scale.x * 0.5;
				selGlow.y = sel.y + sel.height * 0.5 - selGlow.height * selGlow.scale.y * 0.5;
				selGlow.color = bg.color;
			}
			if (selCursor != null)
			{
				selCursor.visible = !playingMusic;
				selCursor.x = sel.x - selCursor.width - 14;
				selCursor.y = sel.y + sel.height * 0.5 - selCursor.height * 0.5 + MenuFX.bob(6, 3.2, 0);
			}
		}
		else
		{
			if (selGlow != null) selGlow.visible = false;
			if (selCursor != null) selCursor.visible = false;
		}

		// Ambient sparkles drifting in the background
		ambientTimer += elapsed;
		if (ambientTimer > 0.16)
		{
			ambientTimer = 0;
			MenuFX.ambientSparkle(particleGroup,
				FlxG.random.float(0, FlxG.width),
				FlxG.random.float(FlxG.height * 0.15, FlxG.height * 0.85),
				FlxColor.fromRGB(255, 240, 220),
				FlxG.random.float(3, 6));
		}

		lerpScore = Math.floor(FlxMath.lerp(lerpScore, intendedScore, CoolUtil.boundTo(elapsed * 24, 0, 1)));
		lerpRating = FlxMath.lerp(lerpRating, intendedRating, CoolUtil.boundTo(elapsed * 12, 0, 1));

		if (Math.abs(lerpScore - intendedScore) <= 10)
			lerpScore = intendedScore;
		if (Math.abs(lerpRating - intendedRating) <= 0.01)
			lerpRating = intendedRating;

		var ratingSplit:Array<String> = Std.string(Highscore.floorDecimal(lerpRating * 100, 2)).split('.');
		if(ratingSplit.length < 2) { //No decimals, add an empty space
			ratingSplit.push('');
		}
		
		while(ratingSplit[1].length < 2) { //Less than 2 decimals in it, add decimals then
			ratingSplit[1] += '0';
		}
		scoreText.text = Language.get("FreeplayState.scoreText", "PERSONAL BEST:") + lerpScore + ' (' + ratingSplit.join('.') + '%)';
		positionHighscore();

		var upP = controls.UI_UP_P;
		var downP = controls.UI_DOWN_P;
		var accepted = controls.ACCEPT;
		var space = #if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonX.justPressed)  || #end	FlxG.keys.justPressed.SPACE;
		var ctrl = #if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonC.justPressed)   || #end FlxG.keys.justPressed.CONTROL;
		var history = #if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonV.justPressed) || #end FlxG.keys.justPressed.H;
		// Multi-file chart toggle: M (PC) / the on-screen D button (Android, addVirtualPad above).
		var multiFileToggle = #if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonD.justPressed) || #end FlxG.keys.justPressed.M;
		// === Mod folder switching: TAB (PC) / G button (Android) to open selection overlay ===
		if (!playingMusic)
		{
			if (FlxG.keys.justPressed.TAB
				#if (TOUCH_CONTROLS || desktop) || (virtualPad != null && virtualPad.buttonEx.justPressed) #end)
			{
				openModSelect();
				return;
			}
		}
		#if !TOUCH_CONTROLS
		// 防穿透: 鼠标在虚拟按键上时, 下层歌曲列表不做悬停/点击判定
		var overControls:Bool = (virtualPad != null && virtualPad.isMouseOverAnyButton());
		if (!overControls)
		{
		var newMouseOverlapIndex = -1;
		for (i in 0...grpSongs.length) {
			var song = grpSongs.members[i];
			var icon = iconArray[i];
			if (FlxG.mouse.overlaps(song) || FlxG.mouse.overlaps(icon)) {
				newMouseOverlapIndex = i;
				break;
			}
		}
		
		if (mouseOverlapIndex != newMouseOverlapIndex) {
			if (mouseOverlapIndex >= 0 && mouseOverlapIndex < grpSongs.length && mouseOverlapIndex != curSelected) {
				MenuFX.fadeAlpha(grpSongs.members[mouseOverlapIndex], 0.6, 0.15);
				if (mouseOverlapIndex < iconArray.length)
					MenuFX.fadeAlpha(iconArray[mouseOverlapIndex], 0.6, 0.15);
			}
			
			if (newMouseOverlapIndex >= 0 && newMouseOverlapIndex != curSelected) {
				MenuFX.fadeAlpha(grpSongs.members[newMouseOverlapIndex], 1.0, 0.15);
				if (newMouseOverlapIndex < iconArray.length)
					MenuFX.fadeAlpha(iconArray[newMouseOverlapIndex], 1.0, 0.15);
			}
			
			mouseOverlapIndex = newMouseOverlapIndex;
		}
		
		if (FlxG.mouse.justPressed && mouseOverlapIndex >= 0 && mouseOverlapIndex != curSelected && !playingMusic) {
			curSelected = mouseOverlapIndex;
			autoPreviewNext = true;
			changeSelection();
			changeDiff();
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
		}
		}
		#end
		// 开启触屏支持后, 鼠标点击不再直接进歌, 防止误触 (用虚拟按键/键盘确认)
		if (FlxG.mouse.justPressed && mouseOverlapIndex == curSelected && !playingMusic && !ClientPrefs.data.touchControls) {
			if (canInput) {
				accepted = true; 
			}
		}

		var shiftMult:Int = 1;
		if(#if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonZ.pressed) || #end FlxG.keys.pressed.SHIFT) shiftMult = 3;
		if (!playingMusic){
		if(filteredSongIndices.length > 1)
		{
			if (upP)
			{
				holdingNav = true;
				holdStartSelected = curSelected;
				autoPreviewNext = true;
				changeSelection(-shiftMult);
				holdTime = 0;
			}
			if (downP)
			{
				holdingNav = true;
				holdStartSelected = curSelected;
				autoPreviewNext = true;
				changeSelection(shiftMult);
				holdTime = 0;
			}
		
			if(controls.UI_DOWN || controls.UI_UP)
			{
				var checkLastHold:Int = Math.floor((holdTime - 0.5) * 10);
				holdTime += elapsed;
				var checkNewHold:Int = Math.floor((holdTime - 0.5) * 10);

				if(holdTime > 0.5 && checkNewHold - checkLastHold > 0)
				{
					changeSelection((checkNewHold - checkLastHold) * (controls.UI_UP ? -shiftMult : shiftMult));
					changeDiff();
				}
			}
			else if (holdingNav)
			{
				// Key released: settle the auto BGM on the final selected song
				holdingNav = false;
				#if PRELOAD_ALL
				if (ClientPrefs.data.freeplayAutoPreview && !playingMusic && !paused
					&& curSelected != holdStartSelected)
					scheduleAutoMusic(0.2);
				#end
			}

			if(FlxG.mouse.wheel != 0)
			{
				FlxG.sound.play(Paths.sound('scrollMenu'), 0.2);
				autoPreviewNext = true;
				changeSelection(-shiftMult * FlxG.mouse.wheel, false);
				changeDiff();
				}
			}
	
		if (controls.UI_LEFT_P)
			changeDiff(-1);
		else if (controls.UI_RIGHT_P)
			changeDiff(1);
		else if (upP || downP) changeDiff();
}
	

		if (controls.BACK && canInput)
		{
			if (playingMusic)
			{
				stopPreview();
			}else{
			persistentUpdate = false;
			if(colorTween != null) {
				colorTween.cancel();
			}
			FlxG.sound.play(Paths.sound('cancelMenu'));
			canInput = false;
			stopAutoMusic();
			// Smooth exit: songs fly out, then a short fade into the main menu
			for (i in 0...grpSongs.length)
			{
				var it:Alphabet = grpSongs.members[i];
				var icon:HealthIcon = iconArray[i];
				var delay:Float = (grpSongs.length - 1 - i) * 0.025;
				FlxTween.tween(it, {alpha: 0, x: it.x - 260}, 0.28, {startDelay: delay, ease: FlxEase.quadIn});
				FlxTween.tween(icon, {alpha: 0}, 0.28, {startDelay: delay, ease: FlxEase.quadIn});
			}
			new FlxTimer().start(0.42, function(tmr:FlxTimer)
			{
				#if ONLINE_ALLOWED
				// While online and connected, leaving Freeplay returns to the room screen instead of
				// the main menu (early return below).
				if (GameClient.isConnected())
				{
					MenuFX.menuSwitch(new online.states.RoomState());
					return;
				}
				#end
				MenuFX.menuSwitch(new MainMenuState());
			});
			}
		}
		if (space && canInput)
    	{
		var realIdx = getRealSelectedIndex();
        if (instPlaying != realIdx && !playingMusic)
        {
            startPreview();
        }
        else if (instPlaying == realIdx && playingMusic)
        {
            if (paused)
            {
                resumePreview();
            }
            else
            {
                pausePreview();
            }
        }
		}
		if (playingMusic && !paused)
    	{
        curTime = FlxG.sound.music.time;
        updatePreviewTexts();

		// ── Animated preview cosmetics: glow pulse + equalizer bars ──
		if (!previewExiting && previewGlow != null)
		{
			previewGlow.color = bg.color;
			previewGlow.alpha = 0.34 + Math.sin(MenuFX.time * 3) * 0.09;
		}
		if (!previewExiting && previewLabel != null)
			previewLabel.alpha = 0.7 + Math.sin(MenuFX.time * 4) * 0.3;
		var eqBaseY:Float = FlxG.height * 0.6;
		if (!previewExiting)
		{
			for (i in 0...previewEqBars.length)
			{
				var bar:FlxSprite = previewEqBars[i];
				var s:Float = 0.22 + 0.78 * Math.abs(Math.sin(MenuFX.time * (2.1 + i * 0.24) + i * 1.15));
				bar.scale.y = s;
				bar.y = eqBaseY - bar.height * s;
				bar.color = bg.color;
			}
		}
        
        if (controls.UI_LEFT_P)
        {
            jumpPreview(-5000);
        }
        if (controls.UI_RIGHT_P)
        {
            jumpPreview(5000);
        }
        
        if (controls.RESET)
        {
            jumpPreview(0); 
        }
        

        if (curTime >= FlxG.sound.music.length)
        {
            stopPreview();
        }
    }
	    if (playingMusic)
   		 {
			if (FlxG.keys.justPressed.UP #if (TOUCH_CONTROLS || desktop) || (virtualPad != null && virtualPad.buttonUp.justPressed) #end)
			{
				playbackRate += 0.05;
				if (playbackRate > 3.0) playbackRate = 3.0;
				setPlaybackRate();
				updatePreviewTexts();
				FlxG.sound.play(Paths.sound('scrollMenu'), 0.5);
			}
			else if (FlxG.keys.justPressed.DOWN	#if (TOUCH_CONTROLS || desktop) || (virtualPad != null && virtualPad.buttonDown.justPressed) #end)
			{
				playbackRate -= 0.05;
				if (playbackRate < 0.25) playbackRate = 0.25;
				setPlaybackRate();
				updatePreviewTexts();
				FlxG.sound.play(Paths.sound('scrollMenu'), 0.5);
			}
	}
		if(ctrl)
		{
			persistentUpdate = false;
			openSubState(new GameplayChangersSubstate());
		}
		else if(history)
		{
			canInput = false;
			persistentUpdate = false;
    		openSubState(new ScoreHistorySubstate(getCurrentSong().songName, curDifficulty));
		}
		else if(multiFileToggle && canInput)
		{
			// Per-song, on the spot: the next chart load of this song uses the new mode.
			var multiFileSong:String = currentMultiFileSongKey();
			if (multiFileSong != null)
			{
				ChartParts.cycleSongOverride(multiFileSong, ClientPrefs.segmentedChartMode());
				updateMultiFileText();
				FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
			}
		}
		else if(space && canInput)
		{
			var realIdx = getRealSelectedIndex();
			if(instPlaying != realIdx)
			{
				#if PRELOAD_ALL
				destroyFreeplayVocals();
				FlxG.sound.music.volume = 0;

				// Temporarily switch to the song's mod folder for chart/voice loading,
				// then restore the globally active mod.
				var prevModDir:String = Paths.currentModDirectory;
				Paths.currentModDirectory = getCurrentSong().folder;
				var poop:String = Highscore.formatSong(getCurrentSong().songName.toLowerCase(), curDifficulty);
				// A streaming-sized chart is not parsed just to preview the song: this block runs on
				// every selection (PRELOAD_ALL) and loadFromJson() scans the whole chart file, which is
				// seconds for a 2 GB chart and minutes for a segmented 8 GB one. The preview only needs
				// the song name and needsVoices, so the parse is skipped and the selection still counts
				// as handled (instPlaying is advanced below).
				var previewSongName:String = getCurrentSong().songName.toLowerCase();
				if (!chartFileIsLarge(previewSongName, poop))
				{
					PlayState.SONG = Song.loadFromJson(poop, previewSongName);
					if (PlayState.SONG.needsVoices)
						vocals = new FlxSound().loadEmbedded(Paths.voices(PlayState.SONG.song));
					else
						vocals = new FlxSound();

					FlxG.sound.list.add(vocals);
					FlxG.sound.playMusic(Paths.inst(PlayState.SONG.song), 0.7);
					vocals.play();
					vocals.persist = true;
					vocals.looped = true;
					vocals.volume = 0.7;
				}
				else
				{
					TraceManager.info('trace.freeplay.previewSkip',
						'preview chart parse skipped, chart file is streaming-sized: {} / {}',
						[previewSongName, poop]);
				}
				Paths.currentModDirectory = prevModDir;
				instPlaying = realIdx;
				#end
			}
		}
		else if (accepted && canInput && !isShowingError)
		{
			#if ONLINE_ALLOWED
			// While online, selecting a song in Freeplay only syncs the song/mod to the room
			// (server RoomLogic.hx "setSong" handler) instead of entering local PlayState.
			// The freeplay ACCEPT handler is diverted before the local song-entry path below.
			// `GameClient.isConnected()` is a runtime condition and cannot be used in `#if`, so a runtime
			// flag wraps the local song-entry logic; with the macro off the block disappears.
			var onlineBlocked:Bool = GameClient.isConnected();
			if (onlineBlocked)
				sendOnlineSong();
			if (!onlineBlocked)
			{
			#end
			PlayState.replayMode = false;
			var selectedSong:Alphabet = grpSongs.members[curSelected];
			var icon:HealthIcon = iconArray[curSelected]; 
			
			var curSongData = getCurrentSong();
			var songLowercase:String = Paths.formatToSongPath(curSongData.songName);
			var poop:String = Highscore.formatSong(songLowercase, curDifficulty);
			
			// Switch to the song's own mod folder so chart JSON loads correctly.
			// DO NOT restore prevModDir after success — PlayState must keep this
			// mod directory to resolve the mod's audio/images during gameplay.
			// FreeplayState.create() will re-sync the directory when we return.
			var prevModDir:String = Paths.currentModDirectory;
			Paths.currentModDirectory = curSongData.folder;
			try
			{
				var testSong = Song.loadFromJson(poop, songLowercase);
				if (testSong == null)
				{
					Paths.currentModDirectory = prevModDir;
					throw "Song data is null";
				}
				PlayState.SONG = testSong;
				PlayState.isStoryMode = false;
				PlayState.storyDifficulty = curDifficulty;
				// Intentionally NOT restoring prevModDir — PlayState needs this.
			}
			catch(e:Dynamic)
			{
				Paths.currentModDirectory = prevModDir;
				TraceManager.error('trace.freeplay.loadError', 'ERROR! {}', [e]);
				var errorStr:String = e.toString();
				if (Std.string(e).startsWith('[file_contents,assets/data/')) 
					errorStr = 'Missing file: ' + errorStr.substring(34, errorStr.length-1);
				else if (errorStr == "Song data is null")
					errorStr = "Song data is empty or corrupted";
				
				missingText.text = 'ERROR WHILE LOADING CHART:\n$errorStr';
				missingText.screenCenter(Y);
				missingText.visible = true;
				missingTextBG.visible = true;
				FlxG.sound.play(Paths.sound('cancelMenu'));
				
				isShowingError = true;
				canInput = true;
				persistentUpdate = true;
				return;
			}
			
			canInput = false;
			persistentUpdate = false;
			FlxG.sound.play(Paths.sound('confirmMenu'), 0.7);
			MenuFX.screenFlash(FlxG.camera, 0xFFFFFFFF, 0.45, 0.55);
			MenuFX.punchZoom(0.06);
			var sel:Alphabet = grpSongs.members[curSelected];
			MenuFX.burstParticles(particleGroup, sel.x + sel.width * 0.5, sel.y + sel.height * 0.5, curSongData.color, 26, 380);
			
			TraceManager.info('trace.freeplay.currentWeek', 'CURRENT WEEK: {}', [WeekData.getWeekFileName()]);
				if(colorTween != null) {
				colorTween.cancel();
			}
						
			missingText.visible = false;
			missingTextBG.visible = false;

			#if (TOUCH_CONTROLS || desktop)
			// 在切换状态前移除虚拟手柄，防止按键状态残留到 PlayState
			removeVirtualPad();
			#end

			if (FlxG.keys.pressed.SHIFT){
			if(ClientPrefs.data.newchartingstate)
			LoadingState.loadAndSwitchState(new editors.NewChartingState());
			else
				LoadingState.loadAndSwitchState(new editors.ChartingState());
				FlxG.sound.music.volume = 0;
				destroyFreeplayVocals();
			}else{
				// Simple, safe exit: selected song pops, others fade, then a
				// normal transition takes us into PlayState. No camera
				// zoom/scroll tricks that could leak into gameplay.
				FlxTween.tween(sel.scale, {x: 1.45, y: 1.45}, 0.25, {ease: FlxEase.quadOut});
				FlxTween.tween(icon.scale, {x: 1.45, y: 1.45}, 0.25, {ease: FlxEase.quadOut});
				MenuFX.shockwaveRing(particleGroup, sel.x + sel.width * 0.5, sel.y + sel.height * 0.5, curSongData.color, 240, 8);
				for (i in 0...grpSongs.length)
				{
					if (i == curSelected) continue;
					FlxTween.tween(grpSongs.members[i], {alpha: 0, x: grpSongs.members[i].x + 220}, 0.3, {ease: FlxEase.quadIn});
					if (i < iconArray.length)
						FlxTween.tween(iconArray[i], {alpha: 0}, 0.3, {ease: FlxEase.quadIn});
				}
				stopAutoMusic();
				destroyFreeplayVocals();
				FlxG.sound.music.volume = 0;
				new FlxTimer().start(0.3, function(tmr:FlxTimer)
				{
					LoadingState.loadAndSwitchState(new PlayState());
				});
			}
			trace(poop);
			#if ONLINE_ALLOWED
			}
			#end
		}
		else if(#if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonY.justPressed) ||#end controls.RESET)
		{
			persistentUpdate = false;
			var resetSong = getCurrentSong();
			openSubState(new ResetScoreSubState(resetSong.songName, curDifficulty, resetSong.songCharacter));
			FlxG.sound.play(Paths.sound('scrollMenu'));
		}
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdatePost', [elapsed]);
		#end
		super.update(elapsed);
	}

	public static function destroyFreeplayVocals() {
		if(vocals != null) {
			vocals.stop();
			vocals.destroy();
		}
		vocals = null;
	}

	public function changeDiff(change:Int = 0)
	{
		curDifficulty += change;

		if (curDifficulty < 0)
			curDifficulty = CoolUtil.difficulties.length-1;
		if (curDifficulty >= CoolUtil.difficulties.length)
			curDifficulty = 0;

		lastDifficultyName = CoolUtil.difficulties[curDifficulty];

		var curSong = getCurrentSong();
		#if !switch
		if(curSong != null) {
			intendedScore = Highscore.getScore(curSong.songName, curDifficulty);
			intendedRating = Highscore.getRating(curSong.songName, curDifficulty);
		}
		#end

		PlayState.storyDifficulty = curDifficulty;
		if (CoolUtil.difficulties.length == 1) diffText.text = '' + CoolUtil.difficultyString() + ' ';
		else 
		diffText.text = '< ' + CoolUtil.difficultyString() + ' >';

		positionHighscore();
		updateMultiFileText();
		missingText.visible = false;
		missingTextBG.visible = false;
		isShowingError = false;
	}

	public function changeSelection(change:Int = 0, playSound:Bool = true)
	{
		
		if(playSound) FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);

		curSelected += change;

		var maxVis:Int = filteredSongIndices.length;
		if (curSelected < 0)
			curSelected = maxVis - 1;
		if (curSelected >= maxVis)
			curSelected = 0;

		var curSong = getCurrentSong();
		if(curSong == null) return;

		// Carry the song color into the shared menu palette (cross-state continuity)
		MenuFX.accentColor = curSong.color;

		var newColor:Int = curSong.color;
		if(newColor != intendedColor) {
			if(colorTween != null) {
				colorTween.cancel();
			}
			intendedColor = newColor;
			colorTween = FlxTween.color(bg, 1, bg.color, intendedColor, {
				onComplete: function(twn:FlxTween) {
					colorTween = null;
				}
			});
		}
		
		missingText.visible = false;
		missingTextBG.visible = false;
		isShowingError = false;
		
		for (i in 0...grpSongs.length) {
			var item = grpSongs.members[i];
			var icon = iconArray[i];
			FlxTween.cancelTweensOf(item.scale);
			FlxTween.cancelTweensOf(icon.scale);
			if (i == curSelected)
			{
				FlxTween.tween(item.scale, {x: 1.2, y: 1.2}, 0.25, {ease: FlxEase.backOut});
				FlxTween.tween(icon.scale, {x: 1.2, y: 1.2}, 0.25, {ease: FlxEase.backOut});
			}
			else
			{
				FlxTween.tween(item.scale, {x: 0.85, y: 0.85}, 0.25, {ease: FlxEase.quadOut});
				FlxTween.tween(icon.scale, {x: 0.85, y: 0.85}, 0.25, {ease: FlxEase.quadOut});
			}
		}

		// Icon highlight + losing/winning face (health icons with 3 frames)
		for (i in 0...iconArray.length) {
			var isSel:Bool = (i == curSelected);
			iconArray[i].alpha = isSel ? 1 : 0.6;
			if (iconArray[i].frameCount == 3) {
				iconArray[i].animation.curAnim.curFrame = isSel ? 2 : 0;
			}
		}

		// selector.y = (70 * curSelected) + 30;

		#if !switch
		if(curSong != null) {
			intendedScore = Highscore.getScore(curSong.songName, curDifficulty);
			intendedRating = Highscore.getRating(curSong.songName, curDifficulty);
		}
		#end

		var bullShit:Int = 0;
		for (item in grpSongs.members)
		{
			item.targetY = bullShit - curSelected;
			bullShit++;
			item.alpha = (item.targetY == 0) ? 1 : 0.6;
		}

		// NOTE: Do NOT set Paths.currentModDirectory here!
		// The globally active mod (selected via ModSelectSubstate / MainMenuState)
		// must stay intact. Song-specific mod folders are only used temporarily
		// when actually loading chart/voice data (see preview & accept handlers).
		PlayState.storyWeek = curSong.week;

		CoolUtil.difficulties = CoolUtil.defaultDifficulties.copy();
		var diffStr:String = WeekData.getCurrentWeek().difficulties;
		if(diffStr != null) diffStr = diffStr.trim(); //Fuck you HTML5

		if(diffStr != null && diffStr.length > 0)
		{
			var diffs:Array<String> = diffStr.split(',');
			var i:Int = diffs.length - 1;
			while (i > 0)
			{
				if(diffs[i] != null)
				{
					diffs[i] = diffs[i].trim();
					if(diffs[i].length < 1) diffs.remove(diffs[i]);
				}
				--i;
			}

			if(diffs.length > 0 && diffs[0].length > 0)
			{
				CoolUtil.difficulties = diffs;
			}
		}
		
		if(CoolUtil.difficulties.contains(CoolUtil.defaultDifficulty))
		{
			curDifficulty = Math.round(Math.max(0, CoolUtil.defaultDifficulties.indexOf(CoolUtil.defaultDifficulty)));
		}
		else
		{
			curDifficulty = 0;
		}

		var newPos:Int = CoolUtil.difficulties.indexOf(lastDifficultyName);
		//trace('Pos of ' + lastDifficultyName + ' is ' + newPos);
		if(newPos > -1)
		{
			curDifficulty = newPos;
		}

		// ── Seiun selection juice ──
		if (curSelected >= 0 && curSelected < grpSongs.length)
		{
			var sel:Alphabet = grpSongs.members[curSelected];
			// Note: the icon "pop" is already handled by the backOut scale tween
			// above, so we avoid a second scale pulse that would fight it.
			MenuFX.punchZoom(0.018);
			MenuFX.burstParticles(particleGroup, sel.x + sel.width * 0.5, sel.y + sel.height * 0.5, curSong.color, 10, 190);
			if (selGlow != null) MenuFX.pulse(selGlow, 0.25, 0.25);
		}

		// Auto BGM follows the selected song (no preview UI, no vocals)
		#if PRELOAD_ALL
		if (ClientPrefs.data.freeplayAutoPreview && !playingMusic && !paused)
		{
			if (autoPreviewNext || !autoMusicActive)
				scheduleAutoMusic();
		}
		autoPreviewNext = false;
		#else
		autoPreviewNext = false;
		#end
	}

	public function positionHighscore() {
		scoreText.x = FlxG.width - scoreText.width - 6;

		scoreBG.scale.x = FlxG.width - scoreText.x + 6;
		scoreBG.x = FlxG.width - (scoreBG.scale.x / 2);
		diffText.x = Std.int(scoreBG.x + (scoreBG.width / 2));
		diffText.x -= diffText.width / 2;
	}

	/** Arrange the preview UI elements (called when a preview starts). */
	function layoutPreviewUI():Void
	{
		previewSongTxt.screenCenter(X);
		previewSongTxt.y = FlxG.height * 0.3;
		previewTimeTxt.screenCenter(X);
		previewTimeTxt.y = FlxG.height * 0.44;
		progressBar.x = (FlxG.width - progressBar.width) * 0.5;
		progressBar.y = FlxG.height * 0.49;
		previewLabel.screenCenter(X);
		previewLabel.y = FlxG.height * 0.24;
		previewGlow.screenCenter();
		for (i in 0...previewEqBars.length)
		{
			var bar:FlxSprite = previewEqBars[i];
			bar.x = FlxG.width * 0.5 + (i - 3) * 34 - bar.width * 0.5;
			bar.scale.y = 0.25;
		}
	}

	/** Smooth staggered entrance for the preview UI. */
	function showPreviewUI():Void
	{
		previewGroup.visible = true;
		layoutPreviewUI();

		// Backdrop fades in first
		previewBG.alpha = 0;
		FlxTween.tween(previewBG, {alpha: 0.62}, 0.3, {ease: FlxEase.sineOut});
		previewGlow.alpha = 0;
		FlxTween.tween(previewGlow, {alpha: 0.5}, 0.4, {ease: FlxEase.sineOut});

		// Foreground elements slide up with a stagger
		var order:Array<FlxSprite> = [previewLabel, previewSongTxt, previewTimeTxt, progressBar];
		for (i in 0...order.length)
		{
			var member:FlxSprite = order[i];
			if (member == null) continue;
			FlxTween.cancelTweensOf(member);
			member.alpha = 0;
			member.y += 26;
			FlxTween.tween(member, {alpha: 1, y: member.y - 26}, 0.35, {
				startDelay: 0.08 + i * 0.06,
				ease: FlxEase.sineOut
			});
		}
		for (i in 0...previewEqBars.length)
		{
			var bar:FlxSprite = previewEqBars[i];
			bar.visible = true;
			bar.alpha = 0;
			FlxTween.tween(bar, {alpha: 1}, 0.3, {startDelay: 0.2 + i * 0.04, ease: FlxEase.sineOut});
		}
	}

	/** Smooth fade-out for the preview UI, then calls onComplete. */
	function hidePreviewUI(onComplete:Void->Void):Void
	{
		previewExiting = true;
		FlxTween.tween(previewBG, {alpha: 0}, 0.25, {ease: FlxEase.quadIn});
		FlxTween.tween(previewGlow, {alpha: 0}, 0.25, {ease: FlxEase.quadIn});
		for (bar in previewEqBars)
			FlxTween.tween(bar, {alpha: 0}, 0.2, {ease: FlxEase.quadIn});

		var order:Array<FlxSprite> = [previewLabel, previewSongTxt, previewTimeTxt, progressBar];
		var done:Int = 0;
		for (member in order)
		{
			if (member == null) { done++; continue; }
			FlxTween.tween(member, {alpha: 0, y: member.y + 18}, 0.22, {
				ease: FlxEase.quadIn,
				onComplete: function(twn:FlxTween)
				{
					done++;
					if (done >= order.length)
					{
						if (!previewExiting) return; // a new preview already started
						previewGroup.visible = false;
						previewExiting = false;
						if (onComplete != null) onComplete();
					}
				}
			});
		}
	}
	
	public function startPreview()
	{
		autoMusicActive = false;
		previewExiting = false;
		FlxTween.cancelTweensOf(previewBG);
		FlxTween.cancelTweensOf(previewGlow);
		for (bar in previewEqBars) FlxTween.cancelTweensOf(bar);
		#if PRELOAD_ALL
		destroyFreeplayVocals();
		FlxG.sound.music.volume = 0;
		var previewSong = getCurrentSong();

		// Temporarily switch to the song's mod for chart/voice loading,
		// then restore the globally active mod.
		var prevModDir:String = Paths.currentModDirectory;
		Paths.currentModDirectory = previewSong.folder;
		var poop:String = Highscore.formatSong(previewSong.songName.toLowerCase(), curDifficulty);
		PlayState.SONG = Song.loadFromJson(poop, previewSong.songName.toLowerCase());
		
		if (PlayState.SONG.needsVoices)
			vocals = new FlxSound().loadEmbedded(Paths.voices(PlayState.SONG.song));
		else
			vocals = new FlxSound();

		FlxG.sound.list.add(vocals);
		MenuFX.markMenuMusicStopped();
		FlxG.sound.playMusic(Paths.inst(PlayState.SONG.song), 0.7);
		vocals.play();
		vocals.persist = true;
		vocals.looped = true;
		vocals.volume = 0.7;
		Paths.currentModDirectory = prevModDir;
		#end
		
		instPlaying = getRealSelectedIndex();
		playingMusic = true;
		paused = false;
		curTime = 0;
		playbackRate = 1.0;
		
		hideNonPreviewElements();
		
		showPreviewUI();
		updatePreviewTexts();
	}

	public function stopPreview()
	{
		playingMusic = false;
		paused = false;
		playbackRate = 1.0;
		destroyFreeplayVocals();
		FlxG.sound.music.stop();
		FlxG.sound.music.volume = 0;
		instPlaying = -1;

		hidePreviewUI(function()
		{
			restoreNonPreviewElements();
			MenuFX.playMenuMusic(1);

			#if PRELOAD_ALL
			// Auto BGM resumes after a manual preview is closed (if enabled)
			if (ClientPrefs.data.freeplayAutoPreview && !playingMusic && canInput)
				scheduleAutoMusic(0.3);
			#end
		});
	}

	/** Play the selected song's instrumental quietly as background music (no preview UI, no vocals). */
	public function startAutoMusic()
	{
		#if PRELOAD_ALL
		var autoSong = getCurrentSong();
		if (autoSong == null) return;
		var songKey:String = autoSong.folder + ':' + autoSong.songName;
		if (autoMusicActive && autoMusicSong == songKey) return; // already playing this song

		destroyFreeplayVocals();
		MenuFX.markMenuMusicStopped();

		var prevModDir:String = Paths.currentModDirectory;
		Paths.currentModDirectory = autoSong.folder;
		FlxG.sound.music.stop();
		FlxG.sound.music.volume = 0;
		FlxG.sound.playMusic(Paths.inst(autoSong.songName), 0.55);
		Paths.currentModDirectory = prevModDir;

		autoMusicActive = true;
		autoMusicSong = songKey;
		#end
	}

	/** Debounced auto BGM switch: waits for the player to settle on a song. */
	public function scheduleAutoMusic(delay:Float = 0.45):Void
	{
		#if PRELOAD_ALL
		if (autoMusicTimer != null)
		{
			autoMusicTimer.cancel();
			autoMusicTimer = null;
		}
		autoMusicTimer = new FlxTimer().start(delay, function(tmr:FlxTimer)
		{
			autoMusicTimer = null;
			if (ClientPrefs.data.freeplayAutoPreview && !playingMusic && !paused && canInput)
				startAutoMusic();
		});
		#end
	}

	/** Stop the background auto BGM (restores nothing; menu music is handled by callers). */
	public function stopAutoMusic()
	{
		if (!autoMusicActive) return;
		autoMusicActive = false;
		FlxG.sound.music.stop();
		FlxG.sound.music.volume = 0;
	}

	public function setPlaybackRate()
	{
		FlxG.sound.music.pitch = playbackRate;
		if (vocals != null) vocals.pitch = playbackRate;
	}

	#if ONLINE_ALLOWED
	/**
	 * Applies the room's `songspeed` gameplay setting to the freeplay/lobby BGM.
	 * `online/states/RoomState.hx` calls it when the host changes that setting, so the local
	 * lobby/room music follows the host.
	 *
	 * The speed is resolved through `PlayState.songSpeed` / `playbackRate`
	 * (`PlayState.set_playbackRate`, `source/states/PlayState.hx:1995`, which sets
	 * `FlxAnimationController.globalSpeed` as a side effect this helper must not duplicate).
	 * `ClientPrefs.getGameplaySetting(name)` takes an optional default.
	 * Only a single `vocals` track is handled because the freeplay state holds one; there is no
	 * separate opponent-vocals track to keep in sync.
	 * Guarded by ONLINE_ALLOWED because only the online room flow calls it.
	 */
	public static function updateFreeplayMusicPitch()
	{
		// `getGameplaySetting` returns `Dynamic`; on static targets a `Dynamic` that holds null cannot
		// be implicitly read into a non-nullable `Float`, so it is read as `Null<Float>` first.
		var setting:Null<Float> = ClientPrefs.getGameplaySetting('songspeed', 1);
		var rate:Float = (setting != null && !Math.isNaN(setting) && setting > 0) ? setting : 1;

		for (v in [FlxG.sound.music, vocals])
		{
			if (v == null) continue;
			v.pitch = rate;
		}
	}
	#end
	
	public function pausePreview()
	{
		if (playingMusic && !paused)
		{
			paused = true;
			FlxG.sound.music.pause();
			if (vocals != null) vocals.pause();
			updatePreviewTexts();
		}
	}

	public function resumePreview()
	{
		if (playingMusic && paused)
		{
			paused = false;
			FlxG.sound.music.resume();
			if (vocals != null) vocals.resume();
			updatePreviewTexts();
		}
	}

	public function jumpPreview(amount:Float)
	{
		if (!playingMusic) return;
		
		var wasPlaying = !paused;
		if (wasPlaying) pausePreview();
		
		curTime += amount;
		if (curTime < 0) curTime = 0;
		if (curTime > FlxG.sound.music.length) curTime = FlxG.sound.music.length;
		
		FlxG.sound.music.time = curTime;
		if (vocals != null) vocals.time = curTime;
		
		if (wasPlaying) resumePreview();
		
		updatePreviewTexts();
	}

	/**
	 * Song key for the per-song multi-file choice: the same value Song.loadFromJson() receives as its
	 * folder, so a choice made here is picked up by the next chart load of this song.
	 */
	function currentMultiFileSongKey():String
	{
		var song = getCurrentSong();
		return (song == null) ? null : Paths.formatToSongPath(song.songName);
	}

	/**
	 * Labels the selected song's multi-file state: whether it is a segmented chart at all, which mode
	 * it will load with, and the key that switches it. Non-segmented songs are labelled too, so the
	 * two kinds can be told apart at a glance -- but dimmed, and without a key hint that would do
	 * nothing there.
	 */
	function updateMultiFileText():Void
	{
		if (multiFileText == null) return;

		var key:String = currentMultiFileSongKey();
		var segmented:Bool = songHasSegmentedChart(key);
		var label:String;
		if (!segmented)
		{
			label = Language.get('FreeplayState.multiFileNone', 'MULTI-FILE: NONE');
		}
		else
		{
			var mode:String = ChartParts.effectiveSongMode(key, ClientPrefs.segmentedChartMode());
			if (mode == ChartParts.MODE_OFF)
				label = Language.get('FreeplayState.multiFileSegments', 'MULTI-FILE: SEGMENTS ONLY');
			else if (mode == ChartParts.MODE_MANIFEST)
				label = Language.get('FreeplayState.multiFileManifest', 'MULTI-FILE: MANIFEST ONLY');
			else
				label = Language.get('FreeplayState.multiFileMerged', 'MULTI-FILE: MERGED');

			// "*" marks a choice made for this song rather than the saved option.
			if (ChartParts.songOverride(key) != null) label += ' *';
			// The key that switches it, shown next to the state it switches (touch UI uses its button).
			label += '  ' + (ClientPrefs.touchUIEnabled()
				? Language.get('FreeplayState.multiFileKeyHint.android', '[D]')
				: Language.get('FreeplayState.multiFileKeyHint', '[M]'));
		}

		multiFileText.text = label;
		multiFileText.y = diffText.y + 28;
		// Dim the "nothing to merge here" case so segmented songs stay the ones that stand out.
		multiFileText.alpha = segmented ? 0.75 : 0.4;
		multiFileText.visible = true;
	}

	/**
	 * Whether the chart a preview would load is large enough that parsing it would stall the menu.
	 *
	 * Mirrors Song.loadFromJson()'s lookup order (mod file, then the plain path) and falls back to
	 * the segmented-chart part list, because a segmented chart has no one-file chart at all. The
	 * threshold is ChartStream's own streaming threshold, so preview and loader agree on "large".
	 */
	static function chartFileIsLarge(songLowercase:String, chartKey:String):Bool
	{
		#if sys
		var oneFile:Array<String> = [];
		#if MODS_ALLOWED
		oneFile.push(Paths.modsJson(songLowercase + '/' + chartKey));
		#end
		oneFile.push(Paths.json(songLowercase + '/' + chartKey));
		for (c in oneFile)
		{
			if (c == null || !FileSystem.exists(c)) continue;
			if (ChartStream.isLargeChart(c)) return true;
		}

		// Segmented chart: every part counts, and there is no <song>.json to find.
		var dirs:Array<String> = [];
		#if MODS_ALLOWED
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			dirs.push(Paths.mods(Paths.currentModDirectory + '/data/' + songLowercase));
		dirs.push(Paths.mods('data/' + songLowercase));
		#end
		dirs.push(Paths.getPreloadPath('data/' + songLowercase));
		for (dir in dirs)
		{
			var parts:Array<String> = ChartParts.resolveForChart(dir, songLowercase, chartKey, ChartParts.MODE_AUTO);
			if (parts == null) continue;
			var total:Float = 0;
			for (part in parts)
			{
				var st = FileSystem.stat(part);
				if (st != null) total += st.size;
			}
			if (total >= ChartStream.MIN_STREAM_BYTES) return true;
		}
		#end
		return false;
	}

	/** Per-session cache of "does this song's chart folder hold a segmented chart". */
	static var segmentedSongCache:Map<String, Bool> = new Map<String, Bool>();

	/**
	 * Whether the selected song's chart folder holds a segmented chart (see ChartParts), so the state
	 * line and its key hint appear exactly when they are useful instead of on every song.
	 */
	function songHasSegmentedChart(songKey:String):Bool
	{
		if (songKey == null || songKey.length == 0) return false;
		if (segmentedSongCache.exists(songKey)) return segmentedSongCache.get(songKey);

		var song:Dynamic = getCurrentSong();
		var dirs:Array<String> = [];
		#if MODS_ALLOWED
		if (song != null && song.folder != null && song.folder.length > 0)
			dirs.push(Paths.mods(song.folder + '/data/' + songKey));
		dirs.push(Paths.mods('data/' + songKey));
		#end
		dirs.push(Paths.getPreloadPath('data/' + songKey));

		// MODE_AUTO on purpose: the question is "does this song have parts at all", independent of
		// the mode in use (MODE_OFF would hide the parts and mislabel the song as not segmented).
		var found:Bool = false;
		for (dir in dirs)
		{
			if (ChartParts.resolveForChart(dir, songKey, songKey, ChartParts.MODE_AUTO) != null)
			{
				found = true;
				break;
			}
		}
		segmentedSongCache.set(songKey, found);
		return found;
	}

	public function updatePreviewTexts()
	{
		if (!playingMusic) return;
		
		var timeStr = formatTime(curTime / 1000) + ' / ' + formatTime(FlxG.sound.music.length / 1000);
		previewTimeTxt.text = timeStr;

		if (FlxG.sound.music.length > 0) {
			var progress = (curTime / FlxG.sound.music.length) * 100;
			progressBar.value = progress;
		}

		var rateText:String = (playbackRate != 1) ? '  (' + playbackRate + 'x)' : '';
		var pSong = getCurrentSong();
		var pName:String = (pSong != null) ? pSong.songName : '?';
		previewSongTxt.text = pName;
		if (paused)
		{
			previewLabel.text = Language.get("FreeplayState.paused", "PAUSED");
			previewTimeTxt.text = timeStr + '  (PAUSED)';
		}
		else
		{
			previewLabel.text = Language.get("FreeplayState.nowPlaying", "NOW PLAYING");
			previewTimeTxt.text = timeStr + rateText;
		}
	}
	
	public function formatTime(seconds:Float):String
	{
		var minutes:Int = Math.floor(seconds / 60);
		var sec:Int = Math.floor(seconds % 60);
		return minutes + ':' + (sec < 10 ? '0' : '') + sec;
	}
	
	public function hideNonPreviewElements()
	{
		wasVisible = new Map();
		
		for (i in 0...grpSongs.length) {
			// Hide every song (including the selected one) so the preview UI
			// never overlaps the list.
			wasVisible.set(grpSongs.members[i], grpSongs.members[i].visible);
			grpSongs.members[i].visible = false;
		}
		
		for (i in 0...iconArray.length) {
			wasVisible.set(iconArray[i], iconArray[i].visible);
			iconArray[i].visible = false;
		}
		
		wasVisible.set(scoreBG, scoreBG.visible);
		wasVisible.set(scoreText, scoreText.visible);
		wasVisible.set(diffText, diffText.visible);
		wasVisible.set(multiFileText, multiFileText.visible);
		
		scoreBG.visible = false;
		scoreText.visible = false;
		diffText.visible = false;
		multiFileText.visible = false;
	}

	public function restoreNonPreviewElements()
	{
		for (i in 0...grpSongs.length) {
			if (wasVisible.exists(grpSongs.members[i])) {
				grpSongs.members[i].visible = wasVisible.get(grpSongs.members[i]);
			}
		}
		
		for (i in 0...iconArray.length) {
			if (wasVisible.exists(iconArray[i])) {
				iconArray[i].visible = wasVisible.get(iconArray[i]);
			}
		}
		if (wasVisible.exists(scoreBG)) scoreBG.visible = wasVisible.get(scoreBG);
		if (wasVisible.exists(scoreText)) scoreText.visible = wasVisible.get(scoreText);
		if (wasVisible.exists(diffText)) diffText.visible = wasVisible.get(diffText);
		if (wasVisible.exists(multiFileText)) multiFileText.visible = wasVisible.get(multiFileText);
	}

	override function onMenuBeat(beat:Int):Void
	{
		if (playingMusic || paused || grpSongs == null || grpSongs.length == 0
			|| curSelected < 0 || curSelected >= grpSongs.length)
			return;

		if (curSelected < iconArray.length)
			MenuFX.pulse(iconArray[curSelected], 0.1, 0.16);
		if (selCursor != null)
			MenuFX.pulse(selCursor, 0.22, 0.14);
		MenuFX.glowPulse(selGlow, 0.95, 0.5, 0.4);
		MenuFX.punchZoom(0.012);
	}

	override function destroy()
    {
		if (particleGroup != null)
			for (p in particleGroup) FlxTween.cancelTweensOf(p);
		if (autoMusicTimer != null)
		{
			autoMusicTimer.cancel();
			autoMusicTimer = null;
		}
		instance = null;
        super.destroy();
    }

	#if ONLINE_ALLOWED
	/**
	 * Sends the song selected in Freeplay to the online room.
	 *
	 * Called from the freeplay ACCEPT handler (`selectedItem == 0`) while the client is
	 * connected; it builds the payload and calls `GameClient.send("setSong", data)`.
	 * The data shape matches `applySong` in the server's `RoomLogic.hx`:
	 *   `[songLowercase, formattedChart, diff, md5, modDir, modUrl, diffList]`
	 *
	 * When a mod has no valid URL, the mod is still sent and the situation is reported through
	 * `Alert` (other players receive the URL).
	 *
	 * The chart hash is wrapped in `ShitUtil.tempSwitchMod` before hashing: without that step
	 * `Song.loadRawSong()` throws `Missing file:` for mod songs and `setSong` is never sent.
	 *
	 * Only the song metadata is broadcast; the audio itself is transferred separately.
	 */
	function sendOnlineSong():Void {
		var songData = getCurrentSong();
		var songLowercase:String = Paths.formatToSongPath(songData.songName);
		var poop:String = Highscore.formatSong(songLowercase, curDifficulty);

		var modDir:String = songData.folder;
		if (modDir == null)
			modDir = "";

		var modUrl:String = online.mods.OnlineMods.getModURL(modDir);

		try {
			// The chart hash is built after switching `Mods.currentModDirectory` to the song's mod.
			// Without it
			// `Paths.modsJson()` inside `Song.loadRawSong()` only looks in the base directory
			// (`assets/data/<song>/`), so mod songs throw `Missing file:` and the catch below
			// swallows it -- `setSong` is never sent and the room `song` stays at its default.
			// `ShitUtil.tempSwitchMod` adds this step (restored on the way out, so Freeplay's
			// later `currentModDirectory` is unchanged). `songData.folder` is the song's mod:
			// `WeekData.setDirectoryFromWeek()` (`WeekData.hx:263-268`) sets it to
			// `leWeek.folder` before `addSong()`, and `SongMetadata.folder` records that value.
			var chartMd5:String = "";
			online.util.ShitUtil.tempSwitchMod(modDir, function () {
				chartMd5 = Song.hashRawSong(poop, songLowercase);
			});

			var data:Array<Dynamic> = [
				songLowercase,
				poop,
				curDifficulty,
				chartMd5,
				modDir,
				modUrl,
				backend.Difficulty.list
			];
			trace(data);
			GameClient.send("setSong", data);
			online.gui.Alert.alert("Room song set to:\n" + songLowercase + " (" + poop + ")"
				+ (modDir != "" ? "\nMod: " + modDir + (modUrl == null || modUrl == "" ? "\n(WARNING: this mod has no URL, others can't download it)" : "") : ""));
		}
		catch (e:Dynamic) {
			trace('ERROR! $e');
			online.gui.Alert.alert("Couldn't set the room song!", Std.string(e));
		}
	}
	#end
}

class SongMetadata
{
	public var songName:String = "";
	public var week:Int = 0;
	public var songCharacter:String = "";
	public var color:Int = -7179779;
	public var folder:String = "";
	public var modFolder:String = "";

	public function new(song:String, week:Int, songCharacter:String, color:Int, ?modFolder:String = '')
	{
		this.songName = song;
		this.week = week;
		this.songCharacter = songCharacter;
		this.color = color;
		this.folder = Paths.currentModDirectory;
		if(this.folder == null) this.folder = '';
		this.modFolder = (modFolder != null && modFolder.length > 0) ? modFolder : this.folder;
	}
}

#if ONLINE_ALLOWED
	/**
	 * Two small helper classes used by the "favourite skins" overlay:
	 * `class Heart extends LockInSprite` / `class LockInSprite extends FlxSprite`.
	 * The only consumer is `online/states/SkinsState.hx`, which does
	 * `selState.grpIconsOverlay.recycle(Heart)` in its `renderCallback`
	 * (`source/online/states/SkinsState.hx:659`).
	 *
	 * `Paths.image('heart')` resolves to `assets/shared/images/heart.png`, an asset that only these
	 * helper classes use.
	 *
	 * The overlay only appears for a *favourited* skin and the surrounding menu is part of the
	 * mod-download/GameBanana flow, which cannot be exercised offline; the path therefore stays
	 * unverified at runtime. Guarded by ONLINE_ALLOWED because nothing else declares these
	 * helper classes.
	 */
class Heart extends LockInSprite {
	public function new(?target:FlxSprite) {
		super(target, Paths.image('heart'));
	}
}

class LockInSprite extends FlxSprite {
	public var target(default, set):FlxSprite;

	public function new(target:FlxSprite, ?asset:FlxGraphicAsset) {
		super(0, 0, asset);

		this.target = target;
	}

	public var copyScaling:Bool = true;

	override function update(elapsed) {
		super.update(elapsed);

		if (target == null || !target.alive) {
			kill();
			return;
		}

		x = target.x;
		y = target.y;
		alpha = target.alpha;
		if (copyScaling) {
			scale.x = target.scale.x;
			scale.y = target.scale.y;
		}
		visible = target.active && target.visible;
	}

	function set_target(v:FlxSprite) {
		target = v;
		revive();
		return target;
	}
}
#end
