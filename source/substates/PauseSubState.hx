package substates;

import states.StoryMenuState;
import states.FreeplayState;
import states.MainMenuState;

import backend.MusicBeatState;
import backend.UIScreen;
import Allscore;
import options.OptionsState;
import Controls.Control;
import flixel.FlxSubState;
import flixel.addons.transition.FlxTransitionableState;
import flixel.input.keyboard.FlxKey;
import flixel.system.FlxSound;
import flixel.util.FlxStringUtil;
import flixel.util.FlxSpriteUtil;
import flixel.tweens.FlxTween;
import flixel.tweens.FlxEase;
import flixel.math.FlxMath;

class PauseSubState extends MusicBeatSubstate
{
	public static var entries:ScoreEntry;

	// === Pause UI transparency (soft-coded) ===
	// 值越低越透明，玩家越能看到游戏实际情况；调高则遮罩更实、文字更清楚。
	// Lower = more see-through so players can see the actual gameplay.
	public static var BG_ALPHA:Float = 0.38;        // 全屏黑底遮罩 / full-screen dark backdrop
	public static var OVERLAY_ALPHA:Float = 0.85;   // 亚克力调色层整体 / acrylic tint layer overall
	public static var OVERLAY_TINT:Float = 0.40;    // 亚克力调色层的颜色不透明度 / acrylic tint color opacity
	public static var CARD_ALPHA:Float = 0.6;       // 玻璃卡片填充 / glass card fill

	var menuItems:Array<String> = [];
	var menuItemsOG:Array<String> = ['Resume', 'Restart Song', 'Change Difficulty', 'Options', 'Exit to menu'];
	var difficultyChoices:Array<String> = [];
	var curSelected:Int = 0;

	var pauseMusic:FlxSound;
	var practiceText:FlxText;
	var skipTimeText:FlxText;
	var skipTimeTracker:FlxText;
	var curTime:Float = Math.max(0, Conductor.songPosition);
	var difficultyWarningText:FlxText;

	var bg:FlxSprite;
	var acrylicOverlay:FlxSprite;
	var glassBorder:FlxSprite;
	var menuBg:FlxSprite;
	var infoBg:FlxSprite;
	var menuItemsGroup:FlxSpriteGroup;
	var selectionIndicator:FlxSprite;
	var slideGroup:FlxSpriteGroup;
	var indicatorTween:FlxTween;
	var substateCam:flixel.FlxCamera;
	var backdropCam:flixel.FlxCamera;
	var prevCamFilters:Array<openfl.filters.BitmapFilter> = null;

	// 3D perspective properties
	var perspAngleX:Float = 0;
	var perspAngleY:Float = 0;
	var perspOffsetX:Float = 0;
	var perspOffsetY:Float = 0;
	var perspScaleX:Float = 1;
	var perspScaleY:Float = 1;
	var isMouseDown:Bool = false;

	// Depth/parallax layer for enhanced 3D effect
	// (removed — was causing clutter)

	public static var songName:String = '';
	

	/** 暂停界面会打开引擎鼠标光标；退出暂停时恢复进暂停前的状态（见 destroy()）。 */
	var __prevMouseVisible:Bool = false;

	/** 关闭动画只允许启动一次：本地点击和联机的 "resumeGame" 都可能同时请求关闭。 */
	var closing:Bool = false;

	public function new(x:Float, y:Float)
	{
		super();
		__prevMouseVisible = FlxG.mouse.visible;
		FlxG.mouse.visible = true;
		Language.load();

		if(CoolUtil.difficulties.length < 2) menuItemsOG.remove('Change Difficulty');

		if(PlayState.replayMode)
		{
			if(menuItemsOG.contains('Change Difficulty'))
				menuItemsOG.remove('Change Difficulty');
		}

		if(PlayState.chartingMode)
		{
			menuItemsOG.insert(2, 'Leave Charting Mode');
			
			var num:Int = 0;
			if(!PlayState.instance.startingSong)
			{
				num = 1;
				menuItemsOG.insert(3, 'Skip Time');
			}
			menuItemsOG.insert(3 + num, 'End Song');
			menuItemsOG.insert(4 + num, 'Toggle Practice Mode');
			menuItemsOG.insert(5 + num, 'Toggle Botplay');
		}
		
		#if (TOUCH_CONTROLS || desktop)
		menuItemsOG.insert(2, 'Chart Editor');
		#end

		
		menuItems = menuItemsOG;

		#if ONLINE_ALLOWED
		// While online the pause menu is replaced with ['Resume', 'Exit to lobby']
			// because Restart / Change Difficulty / Exit to menu would
		// each drop the whole room unilaterally. Applied after the menu is built.
		if (online.GameClient.isConnected()) {
			menuItemsOG = ['Resume', 'Exit to lobby'];
			menuItems = menuItemsOG;
		}
		#end

		for (i in 0...CoolUtil.difficulties.length) {
			difficultyChoices.push(CoolUtil.difficulties[i]);
		}
		difficultyChoices.push('BACK');

		// === Acrylic / Glassmorphism Background ===
		bg = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.fromRGB(5, 8, 18));
		bg.alpha = 0;
		bg.scrollFactor.set();
		add(bg);

		// Dark acrylic overlay
		acrylicOverlay = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.fromRGBFloat(0.04, 0.06, 0.14, OVERLAY_TINT));
		acrylicOverlay.alpha = 0;
		acrylicOverlay.scrollFactor.set();
		add(acrylicOverlay);

		slideGroup = new FlxSpriteGroup();
		add(slideGroup);

		// --- Glass Card: Menu Panel (left) ---
		menuBg = createGlassCard(50, 50, 400, FlxG.height - 100, 24);
		menuBg.scrollFactor.set();
		slideGroup.add(menuBg);

		// Subtle glass border highlight
		glassBorder = createGlassBorder(50, 50, 400, FlxG.height - 100, 24);
		glassBorder.scrollFactor.set();
		slideGroup.add(glassBorder);

		// --- Glass Card: Info Panel (right) ---
		infoBg = createGlassCard(
			menuBg.x + menuBg.width + 20, 50,
			Std.int(FlxG.width - menuBg.width - 120), Std.int(FlxG.height - 100),
			24
		);
		infoBg.scrollFactor.set();
		slideGroup.add(infoBg);

		// --- Info Panel Content ---
		var contentX:Float = infoBg.x + 28;
		var contentW:Float = infoBg.width - 56;

		// Paused title with accent line
		var songInfoText = new FlxText(contentX, infoBg.y + 28, contentW, Language.get("Paused", "Paused"), 30);
		songInfoText.setFormat(Paths.languageFont(), 30, FlxColor.fromRGB(180, 200, 255), CENTER);
		songInfoText.scrollFactor.set();
		slideGroup.add(songInfoText);

		// Accent underline
		var accentLine = new FlxSprite(infoBg.x + (infoBg.width - 60) / 2, songInfoText.y + songInfoText.height + 6).makeGraphic(60, 3, FlxColor.fromRGB(100, 180, 255));
		accentLine.scrollFactor.set();
		slideGroup.add(accentLine);

		var songNameText = new FlxText(contentX, songInfoText.y + 56, contentW, PlayState.SONG.song, 28);
		songNameText.setFormat(Paths.languageFont(), 28, FlxColor.WHITE, CENTER);
		songNameText.scrollFactor.set();
		slideGroup.add(songNameText);

		var difficultyText = new FlxText(contentX, songNameText.y + 42, contentW, PlayState.displayDifficultyString(), 22);
		difficultyText.setFormat(Paths.languageFont(), 22, FlxColor.fromRGB(160, 180, 220), CENTER);
		difficultyText.scrollFactor.set();
		slideGroup.add(difficultyText);

		// Separator line
		var sepLine = new FlxSprite(infoBg.x + 24, difficultyText.y + 46).makeGraphic(Std.int(infoBg.width - 48), 1, FlxColor.fromRGBFloat(1, 1, 1, 0.08));
		sepLine.scrollFactor.set();
		slideGroup.add(sepLine);

		var blueballedText = new FlxText(contentX, difficultyText.y + 58, contentW,
			Language.get("Blueballed", "Blueballed") + ": " + PlayState.deathCounter, 20);
		blueballedText.setFormat(Paths.languageFont(), 20, FlxColor.fromRGB(255, 120, 120), CENTER);
		blueballedText.scrollFactor.set();
		slideGroup.add(blueballedText);

		if(PlayState.replayMode)
			blueballedText.text = Language.get("PauseSubState.Replay", "Replay");

		practiceText = new FlxText(contentX, blueballedText.y + 36, contentW,
			Language.get("Practice Mode", "PRACTICE MODE"), 22);
		practiceText.setFormat(Paths.languageFont(), 22, FlxColor.fromRGB(0, 220, 220), CENTER);
		practiceText.scrollFactor.set();
		practiceText.visible = PlayState.instance.practiceMode;
		slideGroup.add(practiceText);

		var chartingText = new FlxText(contentX, practiceText.y + 38, contentW,
			Language.get("Charting Mode", "CHARTING MODE"), 20);
		chartingText.setFormat(Paths.languageFont(), 20, FlxColor.fromRGB(255, 100, 100), CENTER);
		chartingText.scrollFactor.set();
		chartingText.visible = PlayState.chartingMode;
		slideGroup.add(chartingText);

		var warningY:Float = chartingText.visible ? chartingText.y + 34 : practiceText.y + 34;
		difficultyWarningText = new FlxText(contentX, warningY, contentW,
			Language.get("ReplayDifficultyLock", "In replay mode, adjusting the difficulty is not allowed."), 16);
		difficultyWarningText.setFormat(Paths.languageFont(), 16, FlxColor.fromRGB(255, 100, 100), CENTER);
		difficultyWarningText.scrollFactor.set();
		difficultyWarningText.visible = PlayState.replayMode;
		slideGroup.add(difficultyWarningText);

		// --- Replay Info ---
		if (PlayState.replayMode)
		{
			var replayInfoGroup = new FlxSpriteGroup();
			slideGroup.add(replayInfoGroup);

			var replayCardY:Float = difficultyWarningText.y + difficultyWarningText.height + 12;
			var replayCardH:Int = Std.int(infoBg.y + infoBg.height - replayCardY - 20);
			if (replayCardH < 80) replayCardH = 80;

			var replayCard = createGlassCard(
				infoBg.x + 24, replayCardY,
				Std.int(infoBg.width - 48), replayCardH,
				14
			);
			replayCard.scrollFactor.set();
			replayInfoGroup.add(replayCard);

			var replayTitle1 = new FlxText(replayCard.x + 12, replayCard.y + 8, replayCard.width - 24, Language.get("ScoreHistorySubstate.title", "Song History:"), 18);
			replayTitle1.setFormat(Paths.languageFont(), 18, FlxColor.fromRGB(255, 220, 80), CENTER);
			replayTitle1.scrollFactor.set();
			replayInfoGroup.add(replayTitle1);

			var detailStartY = replayTitle1.y + replayTitle1.height + 6;
			var detailLineHeight = 16;
			var detailX1 = replayCard.x + 14;
			var detailX2 = replayCard.x + replayCard.width / 2 + 4;
			var detailWidth = replayCard.width / 2 - 18;

			if (entries != null)
			{
				function addDetail(tg:FlxSpriteGroup, x:Float, y:Float, w:Float, label:String, val:String, ?clr:FlxColor = FlxColor.CYAN)
				{
					var t = new FlxText(x, y, w, label + ": " + val, detailLineHeight);
					t.setFormat(Paths.languageFont(), detailLineHeight, clr, LEFT);
					t.scrollFactor.set();
					tg.add(t);
				}

				addDetail(replayInfoGroup, detailX1, detailStartY, detailWidth, Language.get("ScoreHistorySubstate.date", "Date"), entries.date);
				addDetail(replayInfoGroup, detailX2, detailStartY, detailWidth, Language.get("ScoreHistorySubstate.score", "Score"), Std.string(entries.score));
				addDetail(replayInfoGroup, detailX1, detailStartY + detailLineHeight, detailWidth, Language.get("ScoreHistorySubstate.accuracy", "Accuracy"), Highscore.floorDecimal(entries.ratingPercent * 100, 2) + "%");
				addDetail(replayInfoGroup, detailX2, detailStartY + detailLineHeight, detailWidth, Language.get("ScoreHistorySubstate.rating", "Rating"), entries.ratingName);
				addDetail(replayInfoGroup, detailX1, detailStartY + detailLineHeight * 2, detailWidth, Language.get("ScoreHistorySubstate.songRating", "Song Rating"), entries.ratingFC);
				addDetail(replayInfoGroup, detailX2, detailStartY + detailLineHeight * 2, detailWidth, Language.get("ScoreHistorySubstate.misses", "Misses"), Std.string(entries.misses));
				addDetail(replayInfoGroup, detailX1, detailStartY + detailLineHeight * 3, detailWidth, Language.get("ScoreHistorySubstate.sicks", "Sicks"), Std.string(entries.sicks));
				addDetail(replayInfoGroup, detailX2, detailStartY + detailLineHeight * 3, detailWidth, Language.get("ScoreHistorySubstate.goods", "Goods"), Std.string(entries.goods));
				addDetail(replayInfoGroup, detailX1, detailStartY + detailLineHeight * 4, detailWidth, Language.get("ScoreHistorySubstate.bads", "Bads"), Std.string(entries.bads));
				addDetail(replayInfoGroup, detailX2, detailStartY + detailLineHeight * 4, detailWidth, Language.get("ScoreHistorySubstate.shits", "Shits"), Std.string(entries.shits));
				addDetail(replayInfoGroup, detailX1, detailStartY + detailLineHeight * 5, detailWidth, Language.get("ScoreHistorySubstate.maxCombo", "Max Combo"), Std.string(entries.maxCombo));
				addDetail(replayInfoGroup, detailX2, detailStartY + detailLineHeight * 5, detailWidth, Language.get("ScoreHistorySubstate.songSpeed", "Song Speed"), Std.string(entries.songSpeed));
				addDetail(replayInfoGroup, detailX1, detailStartY + detailLineHeight * 6, detailWidth, Language.get("ScoreHistorySubstate.playbackRate", "Playback Rate"), Std.string(entries.playbackRate));
				addDetail(replayInfoGroup, detailX2, detailStartY + detailLineHeight * 6, detailWidth, Language.get("ScoreHistorySubstate.songSpeedType", "Speed Type"), entries.songSpeedType);
			}
			else
			{
				var noDetailsText = new FlxText(replayCard.x + 10, detailStartY + 10, replayCard.width - 20,
					Language.get("ScoreHistorySubstate.emptyMsg", "No saved scores.\nPlay without Practice/Botplay to record."), detailLineHeight);
				noDetailsText.setFormat(Paths.languageFont(), detailLineHeight, FlxColor.GRAY, CENTER);
				noDetailsText.scrollFactor.set();
				replayInfoGroup.add(noDetailsText);
			}
		}

		menuItemsGroup = new FlxSpriteGroup();
		slideGroup.add(menuItemsGroup);

		// Selection indicator (rounded pill)
		selectionIndicator = new FlxSprite();
		selectionIndicator.makeGraphic(350, 40, FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(selectionIndicator, 0, 0, 350, 40, 12, 12, FlxColor.fromRGBFloat(0.5, 0.75, 1, 0.15));
		selectionIndicator.alpha = 0;
		selectionIndicator.scrollFactor.set();
		slideGroup.add(selectionIndicator);

		// Initialize menu
		regenMenu();

		// Background music
		pauseMusic = new FlxSound();
		if(songName != null) {
			pauseMusic.loadEmbedded(Paths.music(songName), true, true);
		} else if (songName != 'None') {
			pauseMusic.loadEmbedded(Paths.music(Paths.formatToSongPath(ClientPrefs.data.pauseMusic)), true, true);
		}
		pauseMusic.volume = 0;
		pauseMusic.play(false, FlxG.random.int(0, Std.int(pauseMusic.length / 2)));
		FlxG.sound.list.add(pauseMusic);

		bg.alpha = 0;
		acrylicOverlay.alpha = 0;
		slideGroup.y = FlxG.height;
		slideGroup.alpha = 0;
		slideGroup.scale.set(0.92, 0.92);

		FlxTween.tween(bg, {alpha: BG_ALPHA}, 0.5, {ease: FlxEase.sineOut});
		FlxTween.tween(acrylicOverlay, {alpha: OVERLAY_ALPHA}, 0.5, {ease: FlxEase.sineOut});
		FlxTween.tween(slideGroup, {y: 0}, 0.55, {ease: FlxEase.circOut});
		FlxTween.tween(slideGroup, {alpha: 1}, 0.4, {ease: FlxEase.sineOut});
		FlxTween.tween(slideGroup.scale, {x: 1, y: 1}, 0.55, {ease: FlxEase.circOut});

		// Dedicated static screen-space camera: keeps the pause UI and mouse hit
		// testing independent from camGame/camHUD scroll and zoom.
		substateCam = UIScreen.createScreenCamera();
		cameras = [substateCam];
		backdropCam = FlxG.camera;
		prevCamFilters = backdropCam.filters;
		UIScreen.applyBlur(backdropCam, 8);

		
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, A);
		addPadCamera();
		#end
	}

	#if (TOUCH_CONTROLS || desktop)
	var _padLeftRight:Bool = false;

	function updateVirtualPadForSelection():Void
	{
		var needLeftRight:Bool = (menuItems == menuItemsOG && curSelected >= 0 && curSelected < menuItems.length && menuItems[curSelected] == 'Skip Time');
		if (needLeftRight != _padLeftRight)
		{
			_padLeftRight = needLeftRight;
			removeVirtualPad();
			if (needLeftRight)
				addVirtualPad(LEFT_FULL, A);
			else
				addVirtualPad(UP_DOWN, A);
			addPadCamera();
		}
	}
	#end

	var holdTime:Float = 0;
	var cantUnpause:Float = 0.1;
	
	override function update(elapsed:Float)
	{
		cantUnpause -= elapsed;
		if (pauseMusic.volume < 0.5)
			pauseMusic.volume += 0.01 * elapsed;

		super.update(elapsed);
		updateSkipTextStuff();

		// 3D perspective tilt based on mouse position
		updatePerspective(elapsed);

		var upP = controls.UI_UP_P;
		var downP = controls.UI_DOWN_P;
		var accepted = controls.ACCEPT;

		if (upP)
		{
			changeSelection(-1);
		}
		if (downP)
		{
			changeSelection(1);
		}

		// --- Mouse / Touch hover + click support ---
		// Check if cursor overlaps any menu item and auto-select it
		var mouseActive:Bool = false;
		var mouseClicked:Bool = false;
		#if !TOUCH_CONTROLS
		mouseActive = (FlxG.mouse != null);
		mouseClicked = FlxG.mouse.justPressed;
		#else
		mouseActive = (FlxG.touches.list.length > 0);
		mouseClicked = mouseActive && FlxG.touches.list[0].justReleased;
		#end

		if (mouseActive)
		{
			// 防穿透: 鼠标/触摸在虚拟按键上时, 下层暂停菜单不做悬停/点击判定
			var overControls:Bool = (virtualPad != null && virtualPad.isMouseOverAnyButton());
			if (!overControls)
			{
			var hoverIdx:Int = getItemIndexUnderCursor();
			if (hoverIdx >= 0 && hoverIdx != curSelected)
			{
				changeSelection(hoverIdx - curSelected);
			}
			// 开启触屏支持后, 鼠标点击不再直接执行暂停菜单项, 防止误触
			if (mouseClicked && hoverIdx >= 0 && hoverIdx == curSelected && !ClientPrefs.data.touchControls && (cantUnpause <= 0 || !ClientPrefs.data.controllerMode))
			{
				executeSelectedItem();
			}
			}
		}

		var daSelected:String = menuItems[curSelected];

		if (daSelected == 'Skip Time')
		{
			if (controls.UI_LEFT_P)
			{
				FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
				curTime -= 1000;
				holdTime = 0;
			}
			if (controls.UI_RIGHT_P)
			{
				FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
				curTime += 1000;
				holdTime = 0;
			}

			if(controls.UI_LEFT || controls.UI_RIGHT)
			{
				holdTime += elapsed;
				if(holdTime > 0.5)
				{
					curTime += 45000 * elapsed * (controls.UI_LEFT ? -1 : 1);
				}

				if(curTime >= FlxG.sound.music.length) curTime -= FlxG.sound.music.length;
				else if(curTime < 0) curTime += FlxG.sound.music.length;
				updateSkipTimeText();
			}
		}

		if (accepted && (cantUnpause <= 0 || !ClientPrefs.data.controllerMode))
		{
			executeSelectedItem();
		}
	}

	/**
	 * Execute the action for the currently selected menu item.
	 * Shared between keyboard ACCEPT and mouse/touch click.
	 */
	function executeSelectedItem():Void
	{
		var daSelected:String = menuItems[curSelected];

		if (menuItems == difficultyChoices)
		{
			if(menuItems.length - 1 != curSelected && difficultyChoices.contains(daSelected)) {
				var name:String = PlayState.SONG.song;
				var poop = Highscore.formatSong(name, curSelected);
				PlayState.SONG = Song.loadFromJson(poop, name);
				PlayState.storyDifficulty = curSelected;
				// Changing difficulty reloads chart assets, switch via loading state for pre-decoding
				states.LoadingState.loadAndSwitchState(new PlayState(), true);
				FlxG.sound.music.volume = 0;
				PlayState.changedDifficulty = true;
				PlayState.chartingMode = false;
				return;
			}

			menuItems = menuItemsOG;
			regenMenu(true);
			return;
		}

		switch (daSelected)
		{
			#if ONLINE_ALLOWED
			case "Exit to lobby":
				// While online the pause menu only offers Resume / Exit to lobby (see new()).
				// Switching state locally would drop the room, so it asks the server to broadcast endSong.
				online.GameClient.send("requestEndSong");
			#end
			case "Resume", "Resume Online":
				// A room-wide pause owned by someone else: resuming alone would put this client (and
				// every note hit still coming in) ahead of the frozen room. The server enforces the
				// same rule; this gate is what keeps the player from being desynced by a click.
				if (PlayState.instance != null && !PlayState.instance.onlineResumeAllowed()) {
					FlxG.sound.play(Paths.sound('cancelMenu'));
					PlayState.instance.onlineResumeNotice();
					return;
				}
				closeWithSlideAnimation();
			case 'Change Difficulty':
				if (PlayState.replayMode)
				{
					FlxG.sound.play(Paths.sound('cancelMenu'));
					return;
				}
				menuItems = difficultyChoices;
				regenMenu(true);
			case 'Toggle Practice Mode':
				PlayState.instance.practiceMode = !PlayState.instance.practiceMode;
				PlayState.changedDifficulty = true;
				practiceText.visible = PlayState.instance.practiceMode;
			case "Restart Song":
				restartSong();
			case "Leave Charting Mode":
				restartSong();
				PlayState.chartingMode = false;
			#if (TOUCH_CONTROLS || desktop)
			case 'Chart Editor':
				PlayState.instance.openChartEditor();
			#end
			case 'Skip Time':
				if(curTime < Conductor.songPosition)
				{
					PlayState.startOnTime = curTime;
					restartSong(true);
				}
				else
				{
					if (curTime != Conductor.songPosition)
					{
						PlayState.instance.clearNotesBefore(curTime);
						PlayState.instance.setSongTime(curTime);
					}
					closeWithSlideAnimation();
				}
			case "End Song":
				closeWithSlideAnimation();
				PlayState.instance.finishSong(true);
			case 'Toggle Botplay':
				PlayState.instance.cpuControlled = !PlayState.instance.cpuControlled;
				PlayState.changedDifficulty = true;
				PlayState.instance.botplayTxt.visible = PlayState.instance.cpuControlled;
				PlayState.instance.botplayTxt.alpha = 1;
				PlayState.instance.botplaySine = 0;
			case 'Options':
				PlayState.instance.paused = true;
				PlayState.instance.vocals.volume = 0;
				MusicBeatState.switchState(new OptionsState());
				if(ClientPrefs.data.pauseMusic != 'None')
				{
					FlxG.sound.playMusic(Paths.music(Paths.formatToSongPath(ClientPrefs.data.pauseMusic)), pauseMusic.volume);
					FlxTween.tween(FlxG.sound.music, {volume: 1}, 0.8);
					FlxG.sound.music.time = pauseMusic.time;
				}
				OptionsState.onPlayState = true;
				#if ONLINE_ALLOWED
				// Mirrors source PauseSubState.hx:385
				OptionsState.onOnlineRoom = false;
				#end
			case "Exit to menu":
				PlayState.deathCounter = 0;
				PlayState.seenCutscene = false;

				Paths.currentModDirectory = MainMenuState.selectedModFolder;
				if(PlayState.isStoryMode) {
					MusicBeatState.switchState(new StoryMenuState());
				} else {
					MusicBeatState.switchState(new FreeplayState());
				}
				PlayState.cancelMusicFadeTween();
				// 音乐交给 FreeplayState.create() 统一处理（优先使用模组筛选目录）
				PlayState.changedDifficulty = false;
				PlayState.chartingMode = false;
		}
	}

	/**
	 * Get the index of the menu item under the mouse/touch cursor.
	 * Uses a dedicated screen-space camera to avoid PlayState's game camera
	 * scroll/zoom offsetting the hit detection.
	 * Returns -1 if no item is under the cursor.
	 */
	function getItemIndexUnderCursor():Int
	{
		if (menuItemsGroup == null || menuItemsGroup.members.length == 0) return -1;

		// Use the substate's own camera for coordinate conversion,
		// so PlayState's camGame scroll/zoom doesn't offset the hit test.
		var cam:FlxCamera = (cameras != null && cameras.length > 0) ? cameras[0] : FlxG.camera;

		// Get cursor position in the substate camera's world space
		#if TOUCH_CONTROLS
		if (FlxG.touches.list.length == 0) return -1;
		var touch = FlxG.touches.list[0];
		var point = touch.getWorldPosition(cam);
		#else
		var point = FlxG.mouse.getWorldPosition(cam);
		#end

		var mx:Float = point.x;
		var my:Float = point.y;

		// Account for slideGroup transform (offset + slight perspective scale)
		var ox:Float = (slideGroup != null) ? slideGroup.x : 0;
		var oy:Float = (slideGroup != null) ? slideGroup.y : 0;
		var sx:Float = (slideGroup != null) ? slideGroup.scale.x : 1;
		var sy:Float = (slideGroup != null) ? slideGroup.scale.y : 1;
		var ogx:Float = (slideGroup != null) ? slideGroup.origin.x : 0;
		var ogy:Float = (slideGroup != null) ? slideGroup.origin.y : 0;
		var gx:Float = ox + ogx;
		var gy:Float = oy + ogy;

		for (i in 0...menuItemsGroup.members.length)
		{
			var item:FlxSprite = menuItemsGroup.members[i];
			if (item == null || !item.visible) continue;

			// Compute world-space position: item within menuItemsGroup within slideGroup
			var localX:Float = item.x + menuItemsGroup.x;
			var localY:Float = item.y + menuItemsGroup.y;
			var ix:Float = gx + (localX - ogx) * sx;
			var iy:Float = gy + (localY - ogy) * sy;
			var iw:Float = item.width * sx;
			var ih:Float = item.height * sy;
			if (iw <= 0 || ih <= 0) continue;

			if (mx >= ix && mx <= ix + iw && my >= iy && my <= iy + ih)
				return i;
		}
		return -1;
	}

	// === Glass Card Helpers ===

	/**
	 * Create an acrylic/glassmorphism card with rounded corners.
	 */
	function createGlassCard(x:Float, y:Float, w:Int, h:Int, radius:Int = 18):FlxSprite
	{
		var card = new FlxSprite(x, y).makeGraphic(w, h, FlxColor.TRANSPARENT);
		// Deep dark semi-transparent fill (acrylic look)
		FlxSpriteUtil.drawRoundRect(card, 0, 0, w, h, radius, radius,
			FlxColor.fromRGBFloat(0.06, 0.09, 0.18, CARD_ALPHA),
			{thickness: 0, color: FlxColor.TRANSPARENT}
		);
		return card;
	}

	/**
	 * Subtle glass border highlight (1px inner border with low opacity white).
	 */
	function createGlassBorder(x:Float, y:Float, w:Int, h:Int, radius:Int = 18):FlxSprite
	{
		var border = new FlxSprite(x, y).makeGraphic(w, h, FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(border, 0, 0, w, h, radius, radius,
			FlxColor.TRANSPARENT,
			{thickness: 1, color: FlxColor.fromRGBFloat(1, 1, 1, 0.1)}
		);
		return border;
	}

	/**
	 * Apply 3D perspective tilt to the slide group based on mouse/touch position.
	 * The UI tilts slightly toward the cursor, creating a floating card effect.
	 * Depth layer (decorative circles) moves with stronger parallax for enhanced depth.
	 */
	function updatePerspective(elapsed:Float)
	{
		// Get cursor position in the substate's own camera space,
		// so PlayState's camGame scroll/zoom doesn't offset the perspective effect.
		var cam:FlxCamera = (cameras != null && cameras.length > 0) ? cameras[0] : FlxG.camera;
		#if !TOUCH_CONTROLS
		var point = (FlxG.mouse != null) ? FlxG.mouse.getWorldPosition(cam) : null;
		#else
		var point = (FlxG.touches.list.length > 0) ? FlxG.touches.list[0].getWorldPosition(cam) : null;
		#end

		var mx:Float = FlxG.width / 2;
		var my:Float = FlxG.height / 2;
		if (point != null)
		{
			mx = point.x;
			my = point.y;
		}

		var cx:Float = FlxG.width / 2;
		var cy:Float = FlxG.height / 2;

		var nx:Float = (mx - cx) / cx;
		var ny:Float = (my - cy) / cy;

		// Clamp
		nx = Math.max(-1, Math.min(1, nx));
		ny = Math.max(-1, Math.min(1, ny));

		// --- Layer 1: Slide group (UI panels) — moderate offset + scale ---
		var targetOffsetX:Float = nx * 12;
		var targetOffsetY:Float = ny * 8;
		var targetScale:Float = 1.0 - (Math.abs(nx) + Math.abs(ny)) * 0.005;

		var lerpSpeed:Float = Math.min(1, elapsed * 6);
		perspOffsetX = FlxMath.lerp(perspOffsetX, targetOffsetX, lerpSpeed);
		perspOffsetY = FlxMath.lerp(perspOffsetY, targetOffsetY, lerpSpeed);
		perspScaleX = FlxMath.lerp(perspScaleX, targetScale, lerpSpeed);
		perspScaleY = FlxMath.lerp(perspScaleY, targetScale, lerpSpeed);

		if (slideGroup != null)
		{
			slideGroup.x = perspOffsetX;
			slideGroup.y = perspOffsetY;
			slideGroup.scale.set(perspScaleX, perspScaleY);
		}

		// Glass border shimmer based on cursor distance from center
		if (glassBorder != null)
		{
			var dist:Float = Math.min(1, Math.sqrt(nx * nx + ny * ny));
			glassBorder.alpha = 0.25 + dist * 0.55;
		}
	}

	function closeWithSlideAnimation()
	{
		if (closing)
			return;
		closing = true;

		cantUnpause = 0.1;
		FlxTween.tween(slideGroup, {y: FlxG.height}, 0.4, {ease: FlxEase.quartIn, onComplete: function(_) {
			restoreBackdrop();
			close();
		}});
		FlxTween.tween(bg, {alpha: 0}, 0.4, {ease: FlxEase.quartIn});
		FlxTween.tween(acrylicOverlay, {alpha: 0}, 0.4, {ease: FlxEase.quartIn});
	}

	function deleteSkipTimeText()
	{
		if(skipTimeText != null)
		{
			skipTimeText.kill();
			remove(skipTimeText);
			skipTimeText.destroy();
		}
		skipTimeText = null;
		skipTimeTracker = null;
	}

	/** Online: the room was resumed by whoever owned the pause; leave this forced pause. */
	public function onlineResume():Void
	{
		if (closing)
			return;
		closeWithSlideAnimation();
	}

	public static function restartSong(noTrans:Bool = false)
	{
		PlayState.instance.paused = true;
		FlxG.sound.music.volume = 0;
		PlayState.instance.vocals.volume = 0;

		if(noTrans)
		{
			// Local restart (e.g. Skip Time): assets stay cached, reset state directly
			FlxTransitionableState.skipNextTransOut = true;
			FlxG.resetState();
		}
		else
		{
			// Full song restart: load via LoadingState to allow async texture pre-decoding
			states.LoadingState.loadAndSwitchState(new PlayState(), true);
		}
	}

	function restoreBackdrop():Void
	{
		if (backdropCam != null && FlxG.cameras.list.indexOf(backdropCam) != -1)
			backdropCam.filters = prevCamFilters;
	}

	override function destroy()
	{
		// 恢复进入暂停前的鼠标可见性，否则退出暂停后引擎光标会一直留在屏幕上。
		FlxG.mouse.visible = __prevMouseVisible;
		restoreBackdrop();
		if (substateCam != null)
		{
			FlxG.cameras.remove(substateCam, true);
			substateCam = null;
		}
		if(pauseMusic != null) pauseMusic.destroy();
		if(indicatorTween != null) indicatorTween.cancel();
		super.destroy();
	}

	function changeSelection(change:Int = 0):Void
	{
		curSelected += change;

		FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);

		if (curSelected < 0)
			curSelected = menuItems.length - 1;
		if (curSelected >= menuItems.length)
			curSelected = 0;

		var idx:Int = 0;

		for (item in menuItemsGroup.members)
		{
			// Dim non-selected items
			item.alpha = 0.5;
			item.color = FlxColor.fromRGB(180, 190, 210);

			if (idx == curSelected)
			{
				item.alpha = 1;
				item.color = FlxColor.fromRGB(100, 200, 255);
				// Scale up slightly for emphasis
				item.scale.set(1.05, 1.05);

				// Animate selection indicator to new position
				selectionIndicator.alpha = 1;
				if (indicatorTween != null) indicatorTween.cancel();
				indicatorTween = FlxTween.tween(selectionIndicator, {
					x: menuBg.x + 25,
					y: item.y - 5
				}, 0.15, {ease: FlxEase.quartOut});

				if(item == skipTimeTracker)
				{
					curTime = Math.max(0, Conductor.songPosition);
					updateSkipTimeText();
				}
			}
			else
			{
				item.scale.set(1, 1);
			}
			idx++;
		}

		#if (TOUCH_CONTROLS || desktop)
		updateVirtualPadForSelection();
		#end
	}

	function regenMenu(?animated:Bool = false):Void {
		if (animated && menuItemsGroup.members.length > 0)
		{
			// Fade out old items, then rebuild with fade-in
			for (member in menuItemsGroup.members)
				FlxTween.tween(member, {alpha: 0}, 0.1, {ease: FlxEase.sineIn});
			if (skipTimeText != null)
				FlxTween.tween(skipTimeText, {alpha: 0}, 0.1, {ease: FlxEase.sineIn});
			FlxTween.tween(selectionIndicator, {alpha: 0}, 0.1, {
				ease: FlxEase.sineIn,
				onComplete: function(_) { doRegenMenu(); }
			});
			return;
		}
		doRegenMenu();
	}

	function doRegenMenu():Void {
		for (i in 0...menuItemsGroup.members.length) {
			var obj = menuItemsGroup.members[0];
			obj.kill();
			menuItemsGroup.remove(obj, true);
			obj.destroy();
		}

		deleteSkipTimeText();

		for (i in 0...menuItems.length) {
			var itemText = Language.get(menuItems[i], menuItems[i]);
			var item = new FlxText(menuBg.x + 40, menuBg.y + 30 + (i * 52), 320, itemText, 24);
			item.setFormat(Paths.languageFont(), 24, FlxColor.fromRGB(200, 210, 230), LEFT);
			item.scrollFactor.set();
			item.alpha = 0;
			
			if(PlayState.replayMode && menuItems[i] == 'Change Difficulty') {
				item.color = FlxColor.fromRGB(100, 110, 130);
			}
			
			menuItemsGroup.add(item);

			if(menuItems[i] == 'Skip Time')
			{
				skipTimeText = new FlxText(infoBg.x + 28, infoBg.y + infoBg.height - 100, infoBg.width - 56, '', 20);
				skipTimeText.setFormat(Paths.languageFont(), 20, FlxColor.fromRGB(180, 200, 230), CENTER);
				skipTimeText.scrollFactor.set();
				skipTimeText.alpha = 0;
				skipTimeTracker = item;
				slideGroup.add(skipTimeText);

				updateSkipTextStuff();
				updateSkipTimeText();
			}

			// Staggered fade-in for each item
			FlxTween.tween(item, {alpha: 0.5}, 0.2, {ease: FlxEase.sineOut, startDelay: i * 0.04});
			if (PlayState.replayMode && menuItems[i] == 'Change Difficulty') {
				item.alpha = 0.35;
			}
		}

		curSelected = 0;
		
		if (menuItemsGroup.members.length > 0) {
			var firstItem = menuItemsGroup.members[0];
			firstItem.alpha = 1;
			firstItem.color = FlxColor.fromRGB(100, 200, 255);
			firstItem.scale.set(1.05, 1.05);
			selectionIndicator.setPosition(menuBg.x + 25, firstItem.y - 5);
			FlxTween.tween(selectionIndicator, {alpha: 1}, 0.25, {ease: FlxEase.sineOut});

			if (skipTimeText != null)
				FlxTween.tween(skipTimeText, {alpha: 1}, 0.3, {ease: FlxEase.sineOut, startDelay: 0.15});
		} else {
			selectionIndicator.alpha = 0;
		}

		#if (TOUCH_CONTROLS || desktop)
		updateVirtualPadForSelection();
		#end
	}
	
	function updateSkipTextStuff()
	{
		if(skipTimeText == null || skipTimeTracker == null) return;

		skipTimeText.x = infoBg.x + 28;
		skipTimeText.y = infoBg.y + infoBg.height - 80;
		skipTimeText.visible = (skipTimeTracker.alpha >= 1);
	}

	function updateSkipTimeText()
	{
		if(skipTimeText != null)
			skipTimeText.text = FlxStringUtil.formatTime(Math.max(0, Math.floor(curTime / 1000)), false) + ' / ' + FlxStringUtil.formatTime(Math.max(0, Math.floor(FlxG.sound.music.length / 1000)), false);
	}
}
