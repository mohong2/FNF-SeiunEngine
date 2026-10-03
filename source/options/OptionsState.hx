package options;

import backend.MusicBeatState;
import backend.MusicBeatSubstate;
import states.MainMenuState;
import FlxTextMenuItem.FlxTextAttached;
import flixel.addons.display.FlxBackdrop;
#if cpp
import Discord.DiscordClient;
#end
import flixel.addons.display.FlxGridOverlay;
import flixel.FlxSubState;
import flixel.util.FlxSave;
import flixel.util.FlxTimer;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import haxe.Json;
import flixel.input.keyboard.FlxKey;
import flixel.graphics.FlxGraphic;
import flixel.util.FlxColor;
import openfl.Lib;
import flash.media.Sound;
import flixel.text.FlxText;
import flixel.FlxSprite;
import flixel.FlxBasic;
import Controls;
import flixel.math.FlxMath;
import Language;
import CoolUtil;
import Paths;
import ClientPrefs;
import Character;
import CheckboxThingie;
import Main;
import Note;
import StrumNote;
import StageData;
import states.PlayState;
import states.LoadingState;
import states.ModState;
import substates.ModSubState;
import mohong.TraceManager;
#if (desktop && cpp && windows)
import mohong.Windows;
import mohong.TraceConsole;
#end
#if android
import android.Tools as AndroidTools;
#end

using StringTools;

class OptionsState extends MusicBeatState
{
	static final MODE_CATEGORY:Int = 0;
	static final MODE_SETTINGS:Int = 1;
	static final TRANSITION_DURATION:Float = 0.3;
	static final ENTER_DURATION:Float = 0.4;

	// ═══════════════════════════════════════════════════════════════
	//  Category data — driven by OptionLoader
	// ═══════════════════════════════════════════════════════════════
	var optionIds:Array<String> = [];
	var optionTexts:Array<String> = [];

	/** Refresh category list from OptionLoader. */
	function refreshCategoryLists()
	{
		var categories = OptionLoader.getCategories(#if mobile true #else false #end);
		optionIds = [];
		optionTexts = [];
		for (cat in categories)
		{
			optionIds.push(cat.id);
			optionTexts.push(OptionLoader.getCategoryName(cat));
		}
	}

	static var curSelected:Int = 0;

	/** Settings page to open as soon as this state is ready (set before switching to it). */
	public static var openPageOnEnter:String = null;

	/**
	 * Jump straight to a settings page from outside (e.g. the storage-location warning).
	 * Reuses the running instance when there is one, otherwise opens the state and lets
	 * update() consume openPageOnEnter once everything is built.
	 */
	public static function openPageNow(id:String):Void
	{
		openPageOnEnter = id;

		var current:Dynamic = FlxG.state;
		if (Std.isOfType(current, OptionsState))
		{
			openPageOnEnter = null;
			var state:OptionsState = cast current;
			state.openSelectedCategory(id);
			return;
		}

		backend.MusicBeatState.switchState(new OptionsState());
	}

	public static var onPlayState:Bool = false;
	#if ONLINE_ALLOWED
	// When set, pressing BACK returns into the online RoomState instead of the main menu. Set by
	// `online.substates.RoomSettingsSubstate`, and cleared when options are opened from the main
	// menu or from the pause menu, the same way `onPlayState` is handled in
	// `source/states/MainMenuState.hx:521` / `source/substates/PauseSubState.hx:546`.
	// Defaults to false, so the offline options screen keeps its original BACK behaviour.
	public static var onOnlineRoom:Bool = false;
	#end

	var categorySprites:Array<FlxSprite>;
	var settingsSprites:Array<FlxSprite>;

	var catGrpOptions:FlxTypedGroup<FlxText>;
	var catGrid:FlxBackdrop;
	static var scrollOffset:Float = 0;
	var targetScrollOffset:Float = 0;
	var itemSpacing:Float = 105;
	var baseY:Float = 120;
	var visibleTop:Float = 0;
	var visibleBottom:Float = 720;
	var catSelectorLeft:FlxText;
	var catSelectorRight:FlxText;
	#if (TOUCH_CONTROLS || desktop)
	var catTipText:FlxText;
	#end
	var setGrpOptions:FlxTypedGroup<FlxTextMenuItem>;
	var setCheckboxGroup:FlxTypedGroup<CheckboxThingie>;
	var setGrpTexts:FlxTypedGroup<FlxTextAttached>;
	var setOptionsArray:Array<Option>;
	var setCurSelected:Int = 0;
	var setCurOption:Option = null;
	var setBoyfriend:Character = null;
	var setDescBox:FlxSprite;
	var setDescText:FlxText;
	var setTitleText:FlxTextMenuItem;

	/** 0.7.3+ note-skin preview (four StrumNotes at the top of the options page). */
	var settingsNotes:FlxTypedGroup<StrumNote> = null;
	/** Preview slide-in / slide-out tween. */
	var settingsNotesTween:Array<FlxTween> = [];
	/** Row index of the noteSkin option in the list (-1 = absent on this page). */
	var settingsNoteSkinID:Int = -1;

	var currentMode:Int = MODE_CATEGORY;
	var currentSettingsPage:String = '';
	var settingsPreviewMode:Bool = false;
	var currentPreviewPage:String = '';
	var optionPopupOpen:Bool = false;
	var previewCam:flixel.FlxCamera = null;
	var transitioning:Bool = false;

	var nextAccept:Int = 5;
	var holdTime:Float = 0;
	var holdValue:Float = 0;

	var bg:FlxSprite;

	// ═══════════════════════════════════════════════════════════════
	//  CREATE
	// ═══════════════════════════════════════════════════════════════
	override function create()
	{
		#if desktop
		DiscordClient.changePresence("Options Menu", null);
		#end
		FlxG.mouse.visible = true;

		registerCallbacks();

		bg = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.color = 0xff17719b;
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		bg.alpha = 0;
		add(bg);

		categorySprites = [];
		settingsSprites = [];

		buildCategoryView();
		playEnterAnimation();
		syncDragToWheel();

		// Settings are not saved in create(): nothing has changed yet, and a sync flush only costs a frame on mobile

		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, A_B_C);
		#end

		// Warn about a non-root storage location on the way in too, in case the boot warning
		// was already dismissed or never reached (idempotent per cold start).
		SUtil.checkStorageRootWarning();

		OptionLoader.reloadAll(); // hot‑reload on every entry

		super.create();
	}

	/** Register option onChange callbacks. */
	function registerCallbacks()
	{
		var callbacks = [
			'onChangeAntiAliasing'         => onChangeAntiAliasing,
			'onChangeSeparateUpdateDraw'   => onChangeSeparateUpdateDraw,
			'onChangeFramerate'            => onChangeFramerate,
			'onChangeDrawFramerate'        => onChangeDrawFramerate,
			#if desktop 'onChangeWindowMode' => onChangeWindowMode, 
			 'onChangeRunInBackground'      => onChangeRunInBackground,
			'onChangeBackgroundDim'        => onChangeBackgroundDim,#end
			'onChangeFPSCounter'           => onChangeFPSCounter,
			'onChangePauseMusic'           => onChangePauseMusic,
			'onChangeGameplayHitsoundVolume' => onChangeGameplayHitsoundVolume,
			'onChangeHitsound'             => onChangeHitsound,
			'onChangeMarvelousRatings'     => onChangeMarvelousRatings,
			'onChangeJudgementPreset'      => onChangeJudgementPreset,
			'onChangeMarvelousWindow'      => onChangeMarvelousWindow,
			'onChangeSickWindow'           => onChangeSickWindow,
			'onChangeGoodWindow'           => onChangeGoodWindow,
			'onChangeBadWindow'            => onChangeBadWindow,
			//'onChangeTailWindowMult'       => onChangeTailWindowMult,
			'onChangeLanguage'             => onChangeLanguage,
			'onChangeTraceConsole'         => onChangeTraceConsole,
			'onChangeTraceConsoleLevel'    => onChangeTraceConsoleLevel,
			'onChangeTouchSwipe'           => onChangeTouchSwipe,
			'onClearImageCache'            => onClearImageCache,
			'onChangeShowWatermark'        => onChangeShowWatermark,
			'onChangeShowNoteOptimizationNotice' => onChangeShowNoteOptimizationNotice,
			'onClearChartCache'            => onClearChartCache,
			'onChangeStorageType'          => onChangeStorageType,
			'onChangeAutoExtractAssets'    => onChangeAutoExtractAssets,
		];
		OptionLoader.setCallbacks(callbacks);
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (transitioning) return;

		// Deferred jump requested before this state existed (storage-location warning).
		if (openPageOnEnter != null)
		{
			var page:String = openPageOnEnter;
			openPageOnEnter = null;
			openSelectedCategory(page);
			return;
		}

		switch (currentMode)
		{
			case MODE_CATEGORY:  updateCategoryView(elapsed);
			case MODE_SETTINGS:  updateSettingsView(elapsed);
		}
	}

	function buildCategoryView()
	{
		refreshCategoryLists();
		categorySprites = [];

			catGrid = new FlxBackdrop(FlxGridOverlay.createGrid(80, 80, 160, 160, true, 0x33FFFFFF, 0x0));
		catGrid.velocity.set(40, 40);
		catGrid.alpha = 0;
		add(catGrid);
		categorySprites.push(catGrid);

		catGrpOptions = new FlxTypedGroup<FlxText>();
		add(catGrpOptions);

		for (i in 0...optionIds.length)
		{
			var txt = new FlxText(150, 0, 0, optionTexts[i], 32);
			txt.setFormat(Paths.optionsfont(), 50, FlxColor.WHITE, LEFT,
				FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
			txt.borderSize = 2.5;
			txt.ID = i;
			catGrpOptions.add(txt);
			categorySprites.push(txt);
		}

		catSelectorLeft = new FlxText(0, 0, 0, ">", 32);
		catSelectorLeft.setFormat(Paths.optionsfont(), 50, FlxColor.WHITE, LEFT,
			FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
		catSelectorLeft.borderSize = 2.5;
		add(catSelectorLeft);
		categorySprites.push(catSelectorLeft);

		catSelectorRight = new FlxText(0, 0, 0, "<", 32);
		catSelectorRight.setFormat(Paths.optionsfont(), 50, FlxColor.WHITE, LEFT,
			FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
		catSelectorRight.borderSize = 2.5;
		add(catSelectorRight);
		categorySprites.push(catSelectorRight);

		#if (TOUCH_CONTROLS || desktop)
		if (ClientPrefs.touchUIEnabled())
		{
			catTipText = new FlxText(10, FlxG.height - 24, 0,
				Language.get("option.tipText", "Press C to customize your mobile controls"), 16);
			catTipText.setFormat(Paths.optionsfont(), 16, FlxColor.WHITE, LEFT,
				FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
			catTipText.borderSize = 2.4;
			catTipText.scrollFactor.set();
			add(catTipText);
			categorySprites.push(catTipText);
		}
		#end

		targetScrollOffset = -(curSelected * itemSpacing);
		scrollOffset = targetScrollOffset;

		for (i in 0...catGrpOptions.length)
		{
			var item = catGrpOptions.members[i];
			if (item == null) continue;
			item.y = baseY + i * itemSpacing + scrollOffset;
		}

		changeCategorySelection(0);
	}

	function updateCategoryView(elapsed:Float)
	{
		scrollOffset = FlxMath.lerp(scrollOffset, targetScrollOffset,
			CoolUtil.boundTo(elapsed * 12, 0, 1));

		for (i in 0...catGrpOptions.length)
		{
			var item = catGrpOptions.members[i];
			if (item == null) continue;

			var screenY:Float = baseY + i * itemSpacing + scrollOffset;
			item.y = screenY;
			item.x = 150;

			var margin:Float = 80;
			var isVisible:Bool = (screenY + item.height > visibleTop - margin
							   && screenY < visibleBottom + margin);

			if (isVisible)
			{
				item.visible = true;
				item.active = true;
				var dist:Float = 0;
				if (screenY < visibleTop + margin)
					dist = (visibleTop + margin - screenY) / margin;
				else if (screenY + item.height > visibleBottom - margin)
					dist = (screenY + item.height - (visibleBottom - margin)) / margin;
				item.alpha = FlxMath.bound(1 - dist, 0, 1);
			}
			else
			{
				item.visible = false;
				item.active = false;
			}
		}

		var selItem = catGrpOptions.members[curSelected];
		if (selItem != null && selItem.visible)
		{
			catSelectorLeft.x = selItem.x - 63;
			catSelectorLeft.y = selItem.y;
			catSelectorRight.x = selItem.x + selItem.width + 15;
			catSelectorRight.y = selItem.y;
			catSelectorLeft.visible = true;
			catSelectorRight.visible = true;
			catSelectorLeft.alpha = selItem.alpha;
			catSelectorRight.alpha = selItem.alpha;
		}
		else
		{
			catSelectorLeft.visible = false;
			catSelectorRight.visible = false;
		}

		var keyboardUsed:Bool = controls.UI_UP_P || controls.UI_DOWN_P || controls.ACCEPT || controls.BACK;

		if (controls.UI_UP_P)    changeCategorySelection(-1);
		if (controls.UI_DOWN_P)  changeCategorySelection(1);

		if (!keyboardUsed)
		{
			if (FlxG.mouse.wheel > 0)   changeCategorySelection(-1);
			else if (FlxG.mouse.wheel < 0) changeCategorySelection(1);

			#if !TOUCH_CONTROLS
			{
				// Hover only emphasises: it must not move the selection, scroll the list or drag
				// the >/< cursor along with the pointer. Selecting and opening happen on click.
				var hovered:Int = -1;
				for (i in 0...catGrpOptions.length)
				{
					var item = catGrpOptions.members[i];
					if (item == null || !item.visible) continue;

					if (FlxG.mouse.overlaps(item, FlxG.camera))
					{
						hovered = i;
						break;
					}
				}

				if (hovered >= 0)
				{
					// Multiply the distance fade computed above so items scrolling in/out of
					// view keep fading instead of snapping to full opacity.
					for (j in 0...catGrpOptions.length)
					{
						var other = catGrpOptions.members[j];
						if (other == null || !other.visible) continue;
						if (j != hovered)
							other.alpha *= 0.6;
					}

					if (FlxG.mouse.justPressed && !(virtualPad != null && virtualPad.isMouseOverAnyButton()))
					{
						if (curSelected != hovered)
						{
							curSelected = hovered;
							targetScrollOffset = -(hovered * itemSpacing);
							updateCategoryPreview();
						}
						openSelectedCategory(optionIds[curSelected]);
					}
				}
			}
			#else
			{
				// Touch: one tap on a row selects *and* opens it. Mouse and touch share a single
				// trigger flag so they cannot both fire for the same gesture in one frame.
				var tapped:Bool = FlxG.mouse.justPressed;
				for (touch in FlxG.touches.list)
					if (touch.justPressed || touch.justReleased) tapped = true;

				if (tapped && !(virtualPad != null && virtualPad.isMouseOverAnyButton()))
				{
					for (i in 0...catGrpOptions.length)
					{
						var item = catGrpOptions.members[i];
						if (item == null || !item.visible) continue;

						var hit:Bool = FlxG.mouse.overlaps(item, FlxG.camera);
						if (!hit)
						{
							for (touch in FlxG.touches.list)
							{
								if (touch.overlaps(item))
								{
									hit = true;
									break;
								}
							}
						}
						if (!hit) continue;

						if (curSelected != i)
						{
							curSelected = i;
							targetScrollOffset = -(i * itemSpacing);
							updateCategoryPreview();
						}
						openSelectedCategory(optionIds[curSelected]);
						break;
					}
				}
			}
			#end
		}

		if (controls.ACCEPT)
			openSelectedCategory(optionIds[curSelected]);

		if (controls.BACK)
		{
			FlxG.sound.play(Paths.sound('cancelMenu'));
			playExitAnimation(function() {
				if (onPlayState)
				{
					StageData.loadDirectory(PlayState.SONG);
					LoadingState.loadAndSwitchState(new PlayState());
					FlxG.sound.music.volume = 0;
				}
				#if ONLINE_ALLOWED
				else if (onOnlineRoom)
					LoadingState.loadAndSwitchState(new online.states.RoomState());
				#end
				else
					MusicBeatState.switchState(new MainMenuState());
			});
		}

		#if (TOUCH_CONTROLS || desktop)
		if (virtualPad != null && virtualPad.buttonC.justPressed)
		{
			persistentUpdate = false;
			openSubState(new android.AndroidControlsSubState());
		}
		#end
	}

	function changeCategorySelection(change:Int = 0, ?playSound:Bool = true)
	{
		curSelected += change;
		if (curSelected < 0) curSelected = optionIds.length - 1;
		if (curSelected >= optionIds.length) curSelected = 0;

		targetScrollOffset = -(curSelected * itemSpacing);
		updateCategoryPreview();

		if (change != 0 && playSound) FlxG.sound.play(Paths.sound('scrollMenu'), 0.5);
	}

	/** Category preview temporarily disabled. Kept for later re-enable. */
	function updateCategoryPreview():Void
	{
		destroySettingsSprites();
		settingsPreviewMode = false;
		currentPreviewPage = '';
	}

	function bringCategoryToFront():Void
	{
		if (catGrpOptions != null) { remove(catGrpOptions); add(catGrpOptions); }
		if (catGrid != null) { remove(catGrid); add(catGrid); }
		if (catSelectorLeft != null) { remove(catSelectorLeft); add(catSelectorLeft); }
		if (catSelectorRight != null) { remove(catSelectorRight); add(catSelectorRight); }
		#if (TOUCH_CONTROLS || desktop)
		if (catTipText != null) { remove(catTipText); add(catTipText); }
		#end
	}

	function openSelectedCategory(id:String)
	{
		#if (TOUCH_CONTROLS || desktop)
		removeVirtualPad();
		#end

		var categories = OptionLoader.getCategories(true);
		var foundCat:Dynamic = null;
		for (cat in categories)
		{
			if (cat.id == id)
			{
				foundCat = cat;
				break;
			}
		}

		if (foundCat == null)
		{
			fallbackOpenCategory(id);
			return;
		}

		switch (foundCat.type)
		{
			case 'settings':
				switchToSettings(id);

			case 'substate':
				if (foundCat.substateClass == null)
				{
					fallbackOpenCategory(id);
					return;
				}

				// Touch controls: open the Android control substate on desktop too (also forces the class to compile)
				if (foundCat.id == 'touch_controls')
				{
					transitioning = true;
					playExitAnimation(function() {
						openSubState(new android.AndroidControlsSubState());
					});
					return;
				}

				// Mod category -> ModSubState (script driven)
				if (foundCat.modSource != null && foundCat.modSource.length > 0)
				{
					transitioning = true;
					playExitAnimation(function() {
						openSubState(new substates.ModSubState(foundCat.substateClass));
					});
					return;
				}

				// Built-in category -> try to resolve the class, fall back to ModSubState
				var resolvedClass = Type.resolveClass(foundCat.substateClass);
				if (resolvedClass != null)
				{
					var substateClass:Class<FlxSubState> = cast resolvedClass;
					transitioning = true;
					playExitAnimation(function() {
						openSubState(Type.createInstance(substateClass, []));
					});
				}
				else
				{
					transitioning = true;
					playExitAnimation(function() {
						openSubState(new substates.ModSubState(foundCat.substateClass));
					});
				}

			case 'state':
				if (foundCat.stateClass == null)
				{
					fallbackOpenCategory(id);
					return;
				}

				// Mod category -> ModState (script driven)
				if (foundCat.modSource != null && foundCat.modSource.length > 0)
				{
					LoadingState.loadAndSwitchState(new states.ModState(foundCat.stateClass));
					return;
				}

				// Built-in category -> try to resolve the class, fall back to ModState
				var resolvedStateClass = Type.resolveClass(foundCat.stateClass);
				if (resolvedStateClass != null)
				{
					var stateClass:Class<MusicBeatState> = cast resolvedStateClass;
					LoadingState.loadAndSwitchState(Type.createInstance(stateClass, []));
				}
				else
				{
					LoadingState.loadAndSwitchState(new states.ModState(foundCat.stateClass));
				}

			default:
				fallbackOpenCategory(id);
		}
	}

	/** Fallback hardcoded category routing. */
	function fallbackOpenCategory(id:String)
	{
		switch (id)
		{
			case 'notecolor':
				transitionToSettingsSubState('notecolor');
			case 'controls':
				transitionToSettingsSubState('controls');
			case 'backup':
				transitionToSettingsSubState('backup');
			case 'adjust':
				LoadingState.loadAndSwitchState(new options.NoteOffsetState());
			default:
				// Unknown category: fall back to the category view
				FlxG.sound.play(Paths.sound('cancelMenu'));
		}
	}

	/** For pages that use openSubState: exit animation first. */
	function transitionToSettingsSubState(id:String)
	{
		transitioning = true;
		playExitAnimation(function() {
			switch (id)
			{
				case 'notecolor': openSubState(new options.NotesSubState());
				case 'notecolor_rgb': openSubState(new options.NotesSubStateNew());
				case 'controls':  openSubState(new options.ControlsSubState());
				case 'backup':    openSubState(new options.BackupSettingsSubState());
			}
		});
	}

	// ═══════════════════════════════════════════════════════════════════════════
	//  Settings editing view
	// ═══════════════════════════════════════════════════════════════════════════

	function buildSettingsView(optionsArray:Array<Option>, title:String, rpcTitle:String, ?previewMode:Bool = false)
	{
		destroySettingsSprites();

		settingsPreviewMode = previewMode;
		currentPreviewPage = '';

		setOptionsArray = optionsArray;
		setCurSelected = 0;
		setCurOption = null;
		// setBoyfriend is not cleared: building bf is expensive (character JSON + atlas + animations), so it is reused
		nextAccept = 5;
		holdTime = 0;
		holdValue = 0;
		settingsSprites = [];

		#if desktop
		DiscordClient.changePresence(rpcTitle, null);
		#end

		setGrpOptions = new FlxTypedGroup<FlxTextMenuItem>();
		add(setGrpOptions);

		setGrpTexts = new FlxTypedGroup<FlxTextAttached>();
		add(setGrpTexts);

		setCheckboxGroup = new FlxTypedGroup<CheckboxThingie>();
		add(setCheckboxGroup);

		setDescBox = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		setDescBox.alpha = 0.6;
		add(setDescBox);
		settingsSprites.push(setDescBox);

		setTitleText = new FlxTextMenuItem(75, 40, title, 32);
		setTitleText.alpha = 0.4;
		add(setTitleText);
		settingsSprites.push(setTitleText);

		setDescText = new FlxText(50, 600, 1180, "", 32);
		// OUTLINE_FAST: the description text changes on every selection and a normal OUTLINE border re-rasterizes
		// the full width several times on mobile. OUTLINE_FAST draws the border in the shader and costs ~1/4.
		setDescText.setFormat(Paths.optionsfont(), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
		setDescText.scrollFactor.set();
		setDescText.borderSize = 2.4;
		add(setDescText);
		settingsSprites.push(setDescText);

		for (i in 0...setOptionsArray.length)
		{
			var optionText = new FlxTextMenuItem(290, 260, setOptionsArray[i].name, 48);
			optionText.isMenuItem = true;
			optionText.targetY = i;
			setGrpOptions.add(optionText);

			if (setOptionsArray[i].type == 'button')
			{
				optionText.x -= 10;
				optionText.startPosition.x -= 10;
				var valueText = new FlxTextAttached(
					Language.get("option.traceConsole.pressEnter", "[Press ENTER]"),
					36, optionText.width + 80);
				valueText.sprTracker = optionText;
				valueText.copyAlpha = true;
				valueText.ID = i;
				setGrpTexts.add(valueText);
				setOptionsArray[i].setChild(valueText);
			}
			else if (setOptionsArray[i].type == 'bool')
			{
				var checkbox = new CheckboxThingie(optionText.x - 10, optionText.y, setOptionsArray[i].getValue() == true);
				checkbox.sprTracker = optionText;
				checkbox.ID = i;
				setCheckboxGroup.add(checkbox);
			}
			else
			{
				optionText.x -= 10;
				optionText.startPosition.x -= 10;
				var valueText = new FlxTextAttached('' + setOptionsArray[i].getValue(), 48, optionText.width + 80);
				valueText.sprTracker = optionText;
				valueText.copyAlpha = true;
				valueText.ID = i;
				setGrpTexts.add(valueText);
				setOptionsArray[i].setChild(valueText);
			}
			settingsSprites.push(optionText);

			if (setOptionsArray[i].showBoyfriend)
			{
				settingsReloadBoyfriend();
			}
			settingsUpdateText(setOptionsArray[i]);
		}

		changeSettingsSelection(0, !previewMode);
		settingsReloadCheckboxes();
		settingsSetupNotePreview(optionsArray);

		if (previewMode)
		{
			// Category view shows the complete settings page in a dimmed right-side window.
			setupSettingsPreviewCamera();
			setSettingsPreviewAlpha(0.18);
		}
		else
		{
			#if (TOUCH_CONTROLS || desktop)
			addVirtualPad(LEFT_FULL, A_B_C);
			addPadCamera();
			#end
		}
	}

	function setupSettingsPreviewCamera():Void
	{
		var camX:Int = 460;
		var camW:Int = Std.int(FlxG.width - camX - 20);
		if (camW <= 0) return;

		// Scale the full settings page so it fits inside the right-side preview window.
		var camZoom:Float = camW / FlxG.width;
		previewCam = new flixel.FlxCamera(camX, 0, camW, FlxG.height, camZoom);
		previewCam.bgColor.alpha = 0;
		FlxG.cameras.add(previewCam, false);

		for (s in settingsSprites)
			if (s != null) s.cameras = [previewCam];
		for (item in setGrpOptions.members)
			if (item != null) item.cameras = [previewCam];
		for (item in setGrpTexts.members)
			if (item != null) item.cameras = [previewCam];
		for (item in setCheckboxGroup.members)
			if (item != null) item.cameras = [previewCam];
		if (settingsNotes != null)
			for (note in settingsNotes)
				if (note != null) note.cameras = [previewCam];
		if (setBoyfriend != null)
			setBoyfriend.cameras = [previewCam];
	}

	function setSettingsPreviewAlpha(alpha:Float):Void
	{
		for (s in settingsSprites)
			if (s != null) s.alpha = alpha;
		for (item in setGrpOptions.members)
			if (item != null) item.alpha = alpha;
		for (item in setGrpTexts.members)
			if (item != null) item.alpha = alpha;
		for (item in setCheckboxGroup.members)
			if (item != null) item.alpha = alpha;
		if (settingsNotes != null)
			for (note in settingsNotes)
				if (note != null) note.alpha = alpha;
	}

	function destroySettingsSprites()
	{
		if (previewCam != null)
		{
			FlxG.cameras.remove(previewCam, true);
			previewCam = null;
		}

		if (settingsSprites != null)
		{
			for (s in settingsSprites)
			{
				if (s != null)
				{
					remove(s);
					s.destroy();
				}
			}
		}
		if (setGrpOptions != null) { remove(setGrpOptions); setGrpOptions.destroy(); setGrpOptions = null; }
		if (setGrpTexts != null) { remove(setGrpTexts); setGrpTexts.destroy(); setGrpTexts = null; }
		if (setCheckboxGroup != null) { remove(setCheckboxGroup); setCheckboxGroup.destroy(); setCheckboxGroup = null; }
		// bf is not destroyed: it is kept hidden and reused (rebuilding is expensive) and released with the state
		if (setBoyfriend != null)
		{
			setBoyfriend.visible = false;
			setBoyfriend.active = false;
		}
		if (settingsNotes != null) { remove(settingsNotes); settingsNotes.destroy(); settingsNotes = null; }
		for (t in settingsNotesTween) if (t != null) t.cancel();
		settingsNotesTween = [];
		settingsNoteSkinID = -1;
	}

	/**
	 * 0.7.3+ note-skin preview: when the options page has a noteSkin option, four StrumNotes are shown
	 * at the top and refreshed on every skin change (same as the 0.6.3/0.7.3 VisualsUI).
	 */
	function settingsSetupNotePreview(optionsArray:Array<Option>)
	{
		if (settingsNotes != null) { remove(settingsNotes); settingsNotes.destroy(); settingsNotes = null; }
		settingsNoteSkinID = -1;
		for (t in settingsNotesTween) if (t != null) t.cancel();
		settingsNotesTween = [];

		var hasNoteSkin:Bool = false;
		for (i in 0...optionsArray.length)
		{
			var opt:Option = optionsArray[i];
			// The preview follows the note-skin and note-style options (Old = flat / New = 0.7.3 atlas)
			if (opt.variable == 'noteSkin' || opt.variable == 'noteStyle')
			{
				hasNoteSkin = true;
				// Preview slide-in row: prefer noteSkin, fall back to noteStyle
				if (opt.variable == 'noteSkin' || settingsNoteSkinID < 0)
					settingsNoteSkinID = i;
				var prevOnChange:Void->Void = opt.onChange;
				opt.onChange = function() {
					if (prevOnChange != null) prevOnChange();
					settingsReloadNoteSkin();
				};
			}
		}
		if (!hasNoteSkin) return;

		settingsNotes = new FlxTypedGroup<StrumNote>();
		add(settingsNotes);
		settingsNotesTween = [];
		for (i in 0...4)
		{
			var note:StrumNote = new StrumNote(370 + (560 / 4) * i, -200, i, 0);
			// Preview texture follows noteStyle (Old = flat NOTE_assets, New = noteSkins/NOTE_assets)
			note.texture = Note.defaultNoteSkin;
			note.reloadNote();
			note.centerOffsets();
			note.centerOrigin();
			note.playAnim('static');
			settingsNotes.add(note);
		}
		settingsNotes.visible = true;
		settingsReloadNoteSkin();
	}

	/** Refreshes the preview for the current noteSkin (StrumNote.reloadNote resolves the skin suffix). */
	function settingsReloadNoteSkin()
	{
		if (settingsNotes == null) return;
		for (note in settingsNotes)
		{
			// A noteStyle change needs the base texture swapped too; reloadNote alone only appends the skin suffix
			note.texture = Note.defaultNoteSkin;
			// The texture setter cannot be used: texture stays the base name (NOTE_assets), so changing the skin
			// leaves the value unchanged and the setter short-circuits. reloadNote re-resolves it via getNoteSkinPostfix.
			note.reloadNote();
			note.centerOffsets();
			note.centerOrigin();
			note.playAnim('static');
		}
	}

	function updateSettingsView(elapsed:Float)
	{
		// Keyboard always wins on the frame it is used; mouse is ignored that frame.
		var keyboardUsed:Bool = controls.UI_UP_P || controls.UI_DOWN_P
			|| controls.ACCEPT || controls.BACK || controls.UI_LEFT_P || controls.UI_RIGHT_P
			|| controls.RESET;

		if (!keyboardUsed)
		{
			if (FlxG.mouse.wheel != 0)
			{
				changeSettingsSelection(-FlxG.mouse.wheel);
				FlxG.sound.play(Paths.sound('scrollMenu'));
			}

			// Clicks on the virtual pad must not fall through to the option row (double trigger)
			if (FlxG.mouse.justPressed && !(virtualPad != null && virtualPad.isMouseOverAnyButton()))
			{
				for (checkbox in setCheckboxGroup)
				{
					if (FlxG.mouse.overlaps(checkbox))
					{
						setCurSelected = checkbox.ID;
						changeSettingsSelection(0);
						FlxG.sound.play(Paths.sound('scrollMenu'));
						setOptionsArray[checkbox.ID].setValue(!setOptionsArray[checkbox.ID].getValue());
						setOptionsArray[checkbox.ID].change();
						settingsReloadCheckboxes();
						break;
					}
				}
				for (text in setGrpTexts)
				{
					if (FlxG.mouse.overlaps(text))
					{
						setCurSelected = text.ID;
						changeSettingsSelection(0);

						var option = setOptionsArray[text.ID];
						if (option.type == 'string' || option.type == 'int'
							|| option.type == 'float' || option.type == 'percent')
						{
							openOptionPopup(option);
						}
						else if (option.type == 'button')
						{
							// Touch / mouse click on an action row = ACCEPT, which runs its onChange.
							FlxG.sound.play(Paths.sound('scrollMenu'));
							option.setValue((option.getValue() == true) ? false : true);
							option.change();
						}
						break;
					}
				}
			}
		}

		if (controls.UI_UP_P)   changeSettingsSelection(-1);
		if (controls.UI_DOWN_P) changeSettingsSelection(1);

		if (controls.BACK)
		{
			FlxG.sound.play(Paths.sound('cancelMenu'));
			settingsSaveState();
			switchToCategory();
			return;
		}

		if (nextAccept <= 0)
		{
			var usesCheckbox = (setCurOption != null && (setCurOption.type == 'bool' || setCurOption.type == 'button'));

			if (usesCheckbox)
			{
				if (controls.ACCEPT)
				{
					FlxG.sound.play(Paths.sound('scrollMenu'));
					setCurOption.setValue((setCurOption.getValue() == true) ? false : true);
					setCurOption.change();
					settingsReloadCheckboxes();
				}
			}
			else if (setCurOption != null)
			{
				if (controls.ACCEPT && (setCurOption.type == 'string'
					|| setCurOption.type == 'int' || setCurOption.type == 'float'
					|| setCurOption.type == 'percent'))
				{
					openOptionPopup(setCurOption);
					return;
				}

				var isWindowMode:Bool = (setCurOption.variable == 'windowedmode');

				if (controls.UI_LEFT || controls.UI_RIGHT)
				{
					var pressed = (controls.UI_LEFT_P || controls.UI_RIGHT_P);
					if (holdTime > 0.5 || pressed)
					{
						if (pressed)
						{
							var add:Dynamic = null;
							if (setCurOption.type != 'string')
								add = controls.UI_LEFT ? -setCurOption.changeValue : setCurOption.changeValue;

							switch (setCurOption.type)
							{
								case 'int' | 'float' | 'percent':
									holdValue = setCurOption.getValue() + add;
									if (holdValue < setCurOption.minValue) holdValue = setCurOption.minValue;
									else if (holdValue > setCurOption.maxValue) holdValue = setCurOption.maxValue;

									switch (setCurOption.type)
									{
										case 'int':
											holdValue = Math.round(holdValue);
											setCurOption.setValue(holdValue);
										case 'float' | 'percent':
											holdValue = FlxMath.roundDecimal(holdValue, setCurOption.decimals);
											setCurOption.setValue(holdValue);
									}
									settingsUpdateText(setCurOption);
									setCurOption.change();
									FlxG.sound.play(Paths.sound('scrollMenu'));

								case 'string':
									var num:Int = setCurOption.curOption;
									if (controls.UI_LEFT_P) --num;
									else num++;

									if (num < 0) num = setCurOption.options.length - 1;
									else if (num >= setCurOption.options.length) num = 0;

									setCurOption.curOption = num;
									setCurOption.setValue(setCurOption.options[num]);
									settingsUpdateText(setCurOption);

									if (!isWindowMode) setCurOption.change();
									FlxG.sound.play(Paths.sound('scrollMenu'));
							}
						}
						else if (setCurOption.type != 'string')
						{
							holdValue += setCurOption.scrollSpeed * elapsed * (controls.UI_LEFT ? -1 : 1);
							if (holdValue < setCurOption.minValue) holdValue = setCurOption.minValue;
							else if (holdValue > setCurOption.maxValue) holdValue = setCurOption.maxValue;

							switch (setCurOption.type)
							{
								case 'int':
									setCurOption.setValue(Math.round(holdValue));
								case 'float' | 'percent':
									setCurOption.setValue(FlxMath.roundDecimal(holdValue, setCurOption.decimals));
							}
							settingsUpdateText(setCurOption);
							setCurOption.change();
						}
					}

					if (setCurOption.type != 'string') holdTime += elapsed;
				}
				else if (controls.UI_LEFT_R || controls.UI_RIGHT_R)
				{
					settingsClearHold();
				}

				if (isWindowMode && controls.ACCEPT)
				{
					FlxG.sound.play(Paths.sound('confirmMenu'));
					setCurOption.change();
				}
			}

			if (#if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonC.justPressed) || #end controls.RESET)
			{
				for (i in 0...setOptionsArray.length)
				{
					var leOption = setOptionsArray[i];
					// A button row is an action with no default to restore; RESET must not run its onChange.
					if (leOption.type == 'button')
						continue;
					leOption.setValue(leOption.defaultValue);
					if (leOption.type != 'bool')
					{
						if (leOption.type == 'string')
							leOption.curOption = leOption.options.indexOf(leOption.getValue());
						settingsUpdateText(leOption);
					}
					leOption.change();
				}
				FlxG.sound.play(Paths.sound('cancelMenu'));
				settingsReloadCheckboxes();
			}
		}

		if (setBoyfriend != null && !setBoyfriend.isAnimationNull() && setBoyfriend.isAnimationFinished())
			setBoyfriend.dance();

		if (nextAccept > 0) nextAccept -= 1;
	}

	function settingsUpdateText(option:Option)
	{
		var text:String = option.displayFormat;
		var val:Dynamic = option.getValue();
		if (option.type == 'percent') val *= 100;
		else if (option.type == 'string') val = option.localizedValueText(val);
		var def:Dynamic = option.defaultValue;
		// A button row's child is the "[Press ENTER]" label, which has no %v to show and must not be overwritten.
		if (option.type != 'button')
			option.text = text.replace('%v', val).replace('%d', def);
		if (option.child != null)
		{
			var parentText = setGrpOptions.members[setOptionsArray.indexOf(option)];
			if (parentText != null)
				option.child.offsetX = parentText.width + 80;
		}
	}

	function settingsClearHold()
	{
		if (holdTime > 0.5) FlxG.sound.play(Paths.sound('scrollMenu'));
		holdTime = 0;
	}

	function openOptionPopup(option:Option):Void
	{
		if (option == null) return;
		optionPopupOpen = true;
		#if (TOUCH_CONTROLS || desktop)
		removeVirtualPad();
		#end
		openSubState(new OptionPopupSubState(option, function() {
			settingsUpdateText(option);
		}));
	}

	function changeSettingsSelection(change:Int = 0, ?playSound:Bool = true)
	{
		setCurSelected += change;
		if (setCurSelected < 0) setCurSelected = setOptionsArray.length - 1;
		if (setCurSelected >= setOptionsArray.length) setCurSelected = 0;

		setDescText.text = setOptionsArray[setCurSelected].description;
		setDescText.screenCenter(Y);
		setDescText.y += 270;

		var bullShit:Int = 0;
		for (item in setGrpOptions.members)
		{
			item.targetY = bullShit - setCurSelected;
			bullShit++;
			item.alpha = 0.6;
			if (item.targetY == 0) item.alpha = 1;
		}
		for (text in setGrpTexts)
		{
			text.alpha = 0.6;
			if (text.ID == setCurSelected) text.alpha = 1;
		}

		setDescBox.setPosition(setDescText.x - 10, setDescText.y - 10);
		setDescBox.setGraphicSize(Std.int(setDescText.width + 20), Std.int(setDescText.height + 25));
		setDescBox.updateHitbox();

		if (setBoyfriend != null)
			setBoyfriend.visible = setOptionsArray[setCurSelected].showBoyfriend;
		// 0.7.3+ note-skin preview: shown only while the noteSkin row is selected
		if (settingsNotes != null && settingsNoteSkinID >= 0)
		{
			// Slides in while the note-skin row is selected and out when it leaves
			var targetY:Float = (setCurSelected == settingsNoteSkinID) ? 120 : -200;
			for (i in 0...settingsNotes.members.length)
			{
				var note:StrumNote = settingsNotes.members[i];
				if (note == null) continue;
				if (settingsNotesTween[i] != null) settingsNotesTween[i].cancel();
				settingsNotesTween[i] = FlxTween.tween(note, {y: targetY},
					Math.abs(note.y - targetY) / 600, {ease: FlxEase.quadInOut});
			}
		}

		setCurOption = setOptionsArray[setCurSelected];
		if (playSound == true)
			FlxG.sound.play(Paths.sound('scrollMenu'));
	}

	function settingsReloadBoyfriend()
	{
		// Building bf parses the character JSON, loads atlases and rebuilds every animation: tens of
		// milliseconds on mobile. It is built once per OptionsState and reused across page visits.
		if (setBoyfriend == null)
		{
			setBoyfriend = new Character(840, 170, 'bf', true);
			setBoyfriend.setGraphicSize(Std.int(setBoyfriend.width * 0.75));
			setBoyfriend.updateHitbox();
			add(setBoyfriend);
		}
		else
		{
			// The preview camera may still be attached from previewMode; restore the default ones
			setBoyfriend.cameras = null;
			setBoyfriend.active = true;
		}
		if (!setBoyfriend.isAnimationNull())
			setBoyfriend.dance();
		setBoyfriend.visible = false;
	}

	function settingsReloadCheckboxes()
	{
		for (checkbox in setCheckboxGroup)
			checkbox.daValue = (setOptionsArray[checkbox.ID].getValue() == true);
	}

	function settingsSaveState()
	{
		ClientPrefs.saveSettings();
	}

	// Options built from JSON via OptionLoader — see assets/data/options/

	// ═══════════════════════════════════════════════════════════════════════════
	//  Transition animations
	// ═══════════════════════════════════════════════════════════════════════════

	/** Enter animation: items slide up with overshoot. */
	function playEnterAnimation()
	{
		bg.alpha = 0;
		FlxTween.tween(bg, {alpha: 1}, ENTER_DURATION * 0.7, {ease: FlxEase.quadOut});

		tweenEnterSprites(function(sprite) {
			sprite.y += 60;
			sprite.alpha = 0;
			FlxTween.tween(sprite, {y: sprite.y - 60, alpha: 1}, ENTER_DURATION * 1.2, {
				ease: FlxEase.backOut,
				startDelay: Math.random() * 0.2
			});
		});
	}

	/** Exit animation: fade out all. */
	function playExitAnimation(?onComplete:Void->Void)
	{
		transitioning = true;

		FlxTween.tween(bg, {alpha: 0}, 0.25, {ease: FlxEase.quadIn});

		var sprites = (currentMode == MODE_CATEGORY) ? categorySprites : settingsSprites;
		if (sprites != null)
		{
			for (s in sprites)
			{
				if (s == null) continue;
				FlxTween.tween(s, {alpha: 0}, 0.2, {
					ease: FlxEase.quadIn,
					startDelay: Math.random() * 0.1
				});
			}
		}

		if (onComplete != null)
			new FlxTimer().start(0.3, function(_) { onComplete(); });
	}

	/** Switch to settings view: category slides left, settings slides in. */
	function switchToSettings(page:String)
	{
		if (transitioning) return;
		transitioning = true;

		var categories = OptionLoader.getCategories(#if mobile true #else false #end);
		var catDef:Dynamic = null;
		for (c in categories)
			if (c.id == page) { catDef = c; break; }

		if (catDef == null)
		{
			TraceManager.error('trace.options.unknownCategory', 'Unknown settings category: {}', [page]);
			transitioning = false;
			return;
		}

		var optionsArray:Array<Option> = OptionLoader.loadOptionsForCategory(catDef);
		var title:String = OptionLoader.getCategoryName(catDef);
		var rpcTitle = (catDef.rpcTitleKey != null)
			? Language.get(catDef.rpcTitleKey, title + ' Settings Menu')
			: title + ' Settings Menu';

		if (optionsArray == null || optionsArray.length == 0)
		{
			TraceManager.warn('trace.options.emptyCategory', 'No options found for category: {}', [page]);
			transitioning = false;
			return;
		}

		hideAllSprites(settingsSprites);
		hideSubGroups();
		buildSettingsView(optionsArray, title, rpcTitle);
		for (s in settingsSprites)
		{
			if (s == null) continue;
			s.alpha = 0;
			s.visible = true;
		}
		setSubGroupsVisible(true);

		// The note-optimisation disclaimer belongs to this page, not to launch: raise it the
		// first time the page is opened in this process. showCustom does not block on
		// Android, so the slide-in transition below keeps running underneath either way.
		if (page == 'note_optimization' && backend.NoteOptimisationNotice.shouldShow())
			backend.NoteOptimisationNotice.show();

		currentMode = MODE_SETTINGS;
		currentSettingsPage = page;

		tweenSpriteSlideOut(categorySprites, -FlxG.width, TRANSITION_DURATION, FlxEase.cubeIn, function() {
			hideAllSprites(categorySprites);
		});

		setSubGroupsVisible(true);
		tweenSpriteSlideIn(settingsSprites, FlxG.width, TRANSITION_DURATION, FlxEase.backOut, function() {
			if (setDescBox != null) setDescBox.alpha = 0.6;
			transitioning = false;
		}, 0.1);

		#if (TOUCH_CONTROLS || desktop)
		removeVirtualPad();
		addVirtualPad(LEFT_FULL, A_B_C);
		#end
	}

	/** Switch to category view: settings slides right, category slides in. */
	function switchToCategory()
	{
		if (transitioning) return;
		transitioning = true;

		tweenSpriteSlideOut(settingsSprites, FlxG.width, TRANSITION_DURATION, FlxEase.cubeIn, function() {
			destroySettingsSprites();
		});

		bg.color = 0xff17719b;

		showAllSprites(categorySprites);
		catGrid.x = 0;
		for (i in 0...catGrpOptions.length)
		{
			var item = catGrpOptions.members[i];
			if (item == null) continue;
			item.x = 150;
			item.y = baseY + i * itemSpacing + scrollOffset;
		}
		var selItem = catGrpOptions.members[curSelected];
		if (selItem != null && selItem.visible)
		{
			catSelectorLeft.x = selItem.x - 63;
			catSelectorLeft.y = selItem.y;
			catSelectorRight.x = selItem.x + selItem.width + 15;
			catSelectorRight.y = selItem.y;
		}
		tweenSpriteSlideIn(categorySprites, -FlxG.width, TRANSITION_DURATION, FlxEase.backOut, function() {
			transitioning = false;
			currentMode = MODE_CATEGORY;
		}, 0.1);

		#if (TOUCH_CONTROLS || desktop)
		removeVirtualPad();
		addVirtualPad(UP_DOWN, A_B_C);
		#end
	}

	/** Tween enter sprites. */
	function tweenEnterSprites(fn:FlxSprite->Void)
	{
		var sprites = (currentMode == MODE_CATEGORY) ? categorySprites : settingsSprites;
		if (sprites == null) return;
		for (s in sprites)
		{
			if (s != null) fn(s);
		}
	}

	/** Slide sprites out by offsetX. */
	function tweenSpriteSlideOut(sprites:Array<FlxSprite>, offsetX:Float,
			duration:Float, ease:Float->Float, ?onComplete:Void->Void)
	{
		var completed:Int = 0;
		var total:Int = 0;
		for (s in sprites)
		{
			if (s == null) continue;
			total++;
			FlxTween.tween(s, {x: s.x + offsetX, alpha: 0}, duration, {
				ease: ease,
				onComplete: function(_) {
					completed++;
					if (completed >= total && onComplete != null) onComplete();
				}
			});
		}
		if (total == 0 && onComplete != null) onComplete();
	}

	/** Slide sprites in from offsetX. */
	function tweenSpriteSlideIn(sprites:Array<FlxSprite>, fromOffsetX:Float,
			duration:Float, ease:Float->Float, ?onComplete:Void->Void, startDelay:Float = 0)
	{
		var completed:Int = 0;
		var total:Int = 0;
		for (s in sprites)
		{
			if (s == null) continue;
			total++;
				var targetX = s.x;
			s.x = targetX + fromOffsetX;
			s.alpha = 0;
			FlxTween.tween(s, {x: targetX, alpha: 1}, duration, {
				ease: ease,
				startDelay: startDelay,
				onComplete: function(_) {
					completed++;
					if (completed >= total && onComplete != null) onComplete();
				}
			});
		}
		if (total == 0 && onComplete != null) onComplete();
	}

	/** Hide all sprites in array. */
	function hideAllSprites(sprites:Array<FlxSprite>)
	{
		if (sprites == null) return;
		for (s in sprites)
			if (s != null) s.visible = false;
	}

	/** Show all sprites in array. */
	function showAllSprites(sprites:Array<FlxSprite>)
	{
		if (sprites == null) return;
		for (s in sprites)
			if (s != null) s.visible = true;
	}

	/** Set settings sub-group visibility. */
	function setSubGroupsVisible(visible:Bool)
	{
		if (setGrpOptions != null) setGrpOptions.visible = visible;
		if (setGrpTexts != null) setGrpTexts.visible = visible;
		if (setCheckboxGroup != null) setCheckboxGroup.visible = visible;
	}

	/** Hide settings sub-groups. */
	function hideSubGroups() { setSubGroupsVisible(false); }

	// ═══════════════════════════════════════════════════════════════════════════
	//  Callbacks
	// ═══════════════════════════════════════════════════════════════════════════

	// ── Graphics ──

	function onChangeSeparateUpdateDraw()
	{
		if (FlxG.game != null)
			FlxG.game.separateUpdateDraw = ClientPrefs.data.separateUpdateDraw;

		// At a draw rate above the update rate most ticks run no logic step at all, and rebuilding
		// the draw list for an unchanged world is wasted work. Kept in lockstep with the mode
		// rather than the preference, in case anything changes the mode directly.
		// See FlxG.separateDrawSkipIdleFrames and FlxGame.invalidateDrawCache().
		FlxG.separateDrawSkipIdleFrames = (FlxG.game != null) ? FlxG.game.separateUpdateDraw : false;
	}

	function onChangeAntiAliasing()
	{
		forEachOfType(FlxSprite, function(s:FlxSprite) {
			if (!(s is FlxText))
				s.antialiasing = ClientPrefs.data.globalAntialiasing;
		});
	}

	function onChangeFramerate()
	{
		FlxG.updateFramerate = ClientPrefs.data.framerate;
		if (!ClientPrefs.data.separateUpdateDraw)
		{
			FlxG.drawFramerate = ClientPrefs.data.framerate;
			ClientPrefs.data.drawFramerate = ClientPrefs.data.framerate;
		}
	}

	function onChangeDrawFramerate()
	{
		FlxG.drawFramerate = ClientPrefs.data.drawFramerate;
		if (!ClientPrefs.data.separateUpdateDraw)
		{
			FlxG.updateFramerate = ClientPrefs.data.drawFramerate;
			ClientPrefs.data.framerate = ClientPrefs.data.drawFramerate;
		}
	}

	#if desktop
	function onChangeWindowMode()
	{
		var mode:String = ClientPrefs.data.windowedmode;

		try {
			var window = Lib.application.window;
			switch(mode)
			{
				case 'windowed':
					FlxG.fullscreen = false;
					Lib.application.window.fullscreen = false;
					Lib.application.window.borderless = false;
				case 'fullscreen':
					FlxG.fullscreen = true;
					Lib.application.window.fullscreen = true;
					Lib.application.window.borderless = false;

				case 'borderless':
				{
					// SDL3 borderless desktop fullscreen: one native switch instead of resizing through several black frames.
					// FlxG.fullscreen / window.borderless are left alone to avoid duplicate switches and style flicker.
					window.fullscreen = true;
				}

			}

		} catch(e:Dynamic) {
			TraceManager.error('trace.options.windowModeFailed', 'Failed to change window mode: {}', [e]);
		}
	}

	function onChangeRunInBackground()
	{
		FlxG.autoPause = ClientPrefs.data.runInBackground ? false : ClientPrefs.data.autoPause;
		Main.setupBackgroundDim();
	}

	function onChangeBackgroundDim()
	{
		if (!ClientPrefs.data.backgroundDim)
		{
			if (Main.originalVolume >= 0)
			{
				FlxG.sound.volume = Main.originalVolume;
				Main.originalVolume = -1;
			}
		}
		Main.setupBackgroundDim();
	}
	#end

	// ── Visuals ──

	function onChangeFPSCounter()
	{
		if (Main.fpsVar != null) {
			Main.fpsVar.visible = ClientPrefs.data.showFPS && !Main.useOldFPS;
			Main.oldFpsVar.visible = ClientPrefs.data.showFPS && Main.useOldFPS;
		}
	}

	function onChangePauseMusic()
	{
		// nothing needed
	}

	// ── Gameplay ──

	function onChangeGameplayHitsoundVolume()
	{
		onChangeHitsound();
	}


	function onChangeHitsound()
	{
		var hs:String = ClientPrefs.data.hitsound;
		if (hs == null || hs.length == 0 || hs.toLowerCase() == 'none' || ClientPrefs.data.hitsoundVolume <= 0) return;

		try
		{
			var loaded:Sound = Paths.sound('hitsounds/' + hs);
			if (loaded != null)
				FlxG.sound.play(loaded, ClientPrefs.data.hitsoundVolume);
		}
		catch (e:Dynamic)
		{
			// Fall back to the default hit sound when the custom file is missing
			try { FlxG.sound.play(Paths.sound('hitsound'), ClientPrefs.data.hitsoundVolume); } catch (_:Dynamic) {}
		}
	}

	function onChangeMarvelousRatings()
	{
		// Only saving is needed; ratingsData is rebuilt from this toggle on the next PlayState entry
		ClientPrefs.saveSettings();
	}

	function onChangeJudgementPreset()
	{
		var preset:String = ClientPrefs.data.judgementPreset;
		if (preset == null || preset.length == 0 || preset == 'Custom') return;

		var timings:Array<Int> = backend.Ratings.returnPreset(preset);
		if (timings == null || timings.length < 4) return;

		ClientPrefs.data.judgementTimings = timings.copy();
		backend.Ratings.syncWindows();

		// Refresh every option label (the window values change with the preset)
		if (setOptionsArray != null)
			for (opt in setOptionsArray) settingsUpdateText(opt);

		ClientPrefs.saveSettings();
	}

	function onChangeMarvelousWindow()
	{
		ClientPrefs.data.judgementTimings[0] = ClientPrefs.data.marvelousWindow;
		backend.Ratings.syncWindows();
		ClientPrefs.data.judgementPreset = 'Custom';
		refreshJudgementPresetText();
	}

	function onChangeSickWindow()
	{
		ClientPrefs.data.judgementTimings[1] = ClientPrefs.data.sickWindow;
		backend.Ratings.syncWindows();
		ClientPrefs.data.judgementPreset = 'Custom';
		refreshJudgementPresetText();
	}

	function onChangeGoodWindow()
	{
		ClientPrefs.data.judgementTimings[2] = ClientPrefs.data.goodWindow;
		backend.Ratings.syncWindows();
		ClientPrefs.data.judgementPreset = 'Custom';
		refreshJudgementPresetText();
	}

	function onChangeBadWindow()
	{
		ClientPrefs.data.judgementTimings[3] = ClientPrefs.data.badWindow;
		backend.Ratings.syncWindows();
		ClientPrefs.data.judgementPreset = 'Custom';
		refreshJudgementPresetText();
	}
	/*

	function onChangeTailWindowMult()
	{
		var m:Float = ClientPrefs.data.tailWindowMult;
		if (Math.isNaN(m) || m <= 0)
			ClientPrefs.data.tailWindowMult = 2.0;
		else if (m > 8)
			ClientPrefs.data.tailWindowMult = 8;
		ClientPrefs.saveSettings();
	}
*/
	/** Refreshes the judgement-preset label (updates immediately after it becomes Custom). */
	function refreshJudgementPresetText()
	{
		if (setOptionsArray == null) return;
		for (opt in setOptionsArray)
			if (opt.variable == 'judgementPreset') settingsUpdateText(opt);
	}

	// ── Extra ──

	function onChangeLanguage()
	{
		#if (TOUCH_CONTROLS || desktop)
		removeVirtualPad();
		#end
		Language.load();
		rebuildCurrentPage();
		updateCategoryTexts();
	}

	function onChangeTraceConsole()
	{
		#if (desktop && cpp && windows)
		mohong.TraceManager.enableConsoleOutput(false);
		mohong.TraceConsole.stop();

		if (mohong.Windows.hasConsole())
			mohong.Windows.freeConsole();
		else
		{
			if (mohong.Windows.allocConsole())
			{
				mohong.Windows.enableAnsiColors();
				mohong.TraceManager.enableConsoleOutput(true);
				mohong.TraceConsole.start();
			}
		}
		#end
	}

	function onChangeTraceConsoleLevel()
	{
		#if (desktop && cpp && windows)
		if (!mohong.Windows.hasConsole()) return;
		var level:String = ClientPrefs.data.traceConsoleLevel;
		if (level != null && level.length > 0)
			mohong.TraceManager.applyConsoleLevel(level);
		#end
	}

	function onChangeTouchSwipe()
	{
		syncDragToWheel();
	}

	/**
	 * The storage type decides where the process working directory, the extracted assets and
	 * the native crash directory live. Changing it therefore has to invalidate the cached
	 * resolution and make sure the new root gets populated: otherwise the next launch reads a
	 * directory that was never extracted into, which is the "settings shows nothing at all"
	 * failure.
	 */
	function onChangeStorageType()
	{
		ClientPrefs.saveSettings();
		SUtil.invalidateStorageCache();

		// Re-resolve through the normal path (getStorageDirectory(true) caches the *forced*
		// path, which is only a guess) and re-apply it, so cwd, the crash directory and the
		// linemap all move to the new root together.
		var resolved:String = SUtil.applyStorageDirectory();
		mohong.TraceManager.info('trace.options.storageTypeChanged',
			'Storage type {} now resolves to {}', [ClientPrefs.data.storageType, resolved]);

		// A new choice deserves a fresh warning if it is still not the public root.
		SUtil.resetRootWarningForSession();
		SUtil.checkStorageRootWarning();

		#if mobile
		if (isOnRootStorageType())
		{
			backend.Dialog.showYesNo(
				Language.get('option.storageType.movedTitle', 'Storage Changed'),
				Language.get('option.storageType.movedBody',
					'The assets have not been extracted into the new location yet.\n\n'
					+ 'Extract them now (this can take a few minutes), or let the next launch do it.'),
				function() reextractNow(),
				function() {});
		}
		#end
	}

	#if mobile
	/** Whether the *selected* type is the public root one; used only to word the prompt. */
	function isOnRootStorageType():Bool
	{
		#if android
		return ClientPrefs.data.storageType == 'EXTERNAL';
		#else
		return false;
		#end
	}

	/** Run the blocking extraction pass for the new root immediately. */
	function reextractNow():Void
	{
		backend.MusicBeatState.switchState(new states.CopyState());
	}
	#end

	/** Auto-extraction changed; nothing to do beyond persisting, but keep the callback explicit. */
	function onChangeAutoExtractAssets()
	{
		ClientPrefs.saveSettings();
		mohong.TraceManager.info('trace.options.autoExtractChanged',
			'Auto-extract assets is now {}', [ClientPrefs.data.autoExtractAssets]);
	}

	/** "Clear image cache" action: releases every unreferenced cached image and reports back in a popup. */
	function onClearImageCache()
	{
		var result = Paths.clearImageCache();
		var msg:String;
		if (result.count <= 0)
		{
			msg = Language.get('option.clearImageCache.none', 'No unused cached images to release.');
		}
		else
		{
			var mbStr:String = Std.string(Math.round(result.bytes / 1048576 * 10) / 10);
			msg = Language.get('option.clearImageCache.released', 'Released {n} graphics (~{mb} MB).')
				.replace('{n}', Std.string(result.count))
				.replace('{mb}', mbStr);
		}
		backend.Dialog.show(Language.get('option.clearImageCache.doneTitle', 'Image Cache'), msg, 'Info');
	}

	/** "Version watermark" toggle: the stage-level TextField follows the setting immediately. */
	function onChangeShowWatermark()
	{
		backend.Watermark.refresh();
	}

	/**
	 * "Show the notice again" action row on the note-optimisation page: re-display the
	 * disclaimer without a restart. Shares the body builder with the automatic popup
	 * (backend.NoteOptimisationNotice), so the two can never drift apart.
	 */
	function onChangeShowNoteOptimizationNotice()
	{
		backend.NoteOptimisationNotice.showAgain();
	}

	/** "Clear the chart cache" action: drops every cached note list and reports the freed space. */
	function onClearChartCache()
	{
		var freed:Float = ChartCache.clear();
		var mbStr:String = Std.string(Math.round(freed / 1048576 * 10) / 10);
		var msg:String = Language.get('option.clearChartCache.done', 'Deleted every cached chart note list (~{mb} MB).')
			.replace('{mb}', mbStr);
		backend.Dialog.show(Language.get('option.clearChartCache.doneTitle', 'Chart Cache'), msg, 'Info');
	}

	function syncDragToWheel()
	{
		#if !FLX_UNIT_TEST
		if (FlxG.mouse != null)
			FlxG.mouse.dragToWheelEnabled = ClientPrefs.data.touchSwipeEnabled;
		#end
	}

	// ── Helpers ──

	/** Rebuild current page (e.g. after language switch). */
	function rebuildCurrentPage()
	{
		OptionLoader.reloadAll();

		if (currentMode == MODE_CATEGORY)
		{
			updateCategoryTexts();
		}
		else
		{
			switchToSettings(currentSettingsPage);
		}
	}

	function updateCategoryTexts()
	{
		refreshCategoryLists();
		for (i in 0...catGrpOptions.length)
		{
			var item = catGrpOptions.members[i];
			if (item != null && i < optionTexts.length)
			{
				item.text = optionTexts[i];
				item.setFormat(Paths.optionsfont(), 50, FlxColor.WHITE, LEFT,
					FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
				item.borderSize = 2.5;
			}
		}
	}

	// ═══════════════════════════════════════════════════════════════
	//  SubState return recovery
	// ═══════════════════════════════════════════════════════════════
	override function closeSubState()
	{
		super.closeSubState();
		ClientPrefs.saveSettings();

		if (optionPopupOpen)
		{
			// Closing the dropdown/slider popup should stay in the settings page,
			// not bounce back to the category view.
			optionPopupOpen = false;
			transitioning = false;
			#if (TOUCH_CONTROLS || desktop)
			addVirtualPad(LEFT_FULL, A_B_C);
			addPadCamera();
			#end
			return;
		}

		OptionLoader.reloadAll();

		transitioning = false;
		currentMode = MODE_CATEGORY;
		destroySettingsSprites();

		bg.color = 0xff17719b;
		FlxTween.tween(bg, {alpha: 1}, 0.3, {ease: FlxEase.quadOut});

		showAllSprites(categorySprites);
		for (s in categorySprites)
		{
			if (s == null) continue;
			s.alpha = 1;
		}
		changeCategorySelection(0, false);

		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, A_B_C);
		#end
	}

	override function destroy()
	{
		super.destroy();
	}
}
	
