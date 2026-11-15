package editors;

import states.FreeplayState;
import states.MainMenuState;
#if cpp
import Discord.DiscordClient;
#end
import flixel.addons.display.FlxGridOverlay;
import flixel.addons.transition.FlxTransitionableState;

import flixel.sound.FlxSound;
import flixel.util.FlxSpriteUtil;
#if MODS_ALLOWED
import sys.FileSystem;
import sys.io.File;
import haxe.Json;
import openfl.display.BitmapData;
#end

using StringTools;

class MasterEditorMenu extends MusicBeatState
{
	var options:Array<String> = [
		'editors_week',
		'editors_menu_character',
		'editors_dialogue',
		'editors_dialogue_portrait',
		'editors_character',
		'editors_chart',
		'editors_chart_converter'//,
		//'editors_background'
		//,
		//'editors_credits'
	];
	private var grpTexts:FlxTypedGroup<FlxTextMenuItem>;
	#if MODS_ALLOWED
	private var directories:Array<String> = [null];
	#end

	private var curSelected = 0;
	private var curDirectory = 0;
	private var directoryTxt:EditorsText;

	// MOD list UI
	#if MODS_ALLOWED
	private var modsGroup:FlxTypedGroup<EditorModItem>;
	private var curSelectedMod:Int = 0;
	private var onMods:Bool = false;
	private var bgModList:FlxSprite;

	// Persist mod selection across state recreations
	static var lastSelectedMod:String = '';
	#end

	override function create()
	{
		FlxG.camera.bgColor = FlxColor.BLACK;
		#if cpp
		// Updating Discord Rich Presence
		DiscordClient.changePresence("Editors Main Menu", null);
		#end

		var bg:FlxSprite = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.scrollFactor.set();
		bg.color = 0xFF353535;
		add(bg);

		grpTexts = new FlxTypedGroup<FlxTextMenuItem>();
		add(grpTexts);

		for (i in 0...options.length)
		{
			var displayText:String = getOptionDisplayName(options[i]);
			var leText:FlxTextMenuItem = new FlxTextMenuItem(90, 320, displayText, 48);
			leText.isMenuItem = true;
			leText.targetY = i;
			leText.setFormat(Paths.font("editors.ttf"), 48, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			leText.borderSize = 4;
			leText.antialiasing = ClientPrefs.data.globalAntialiasing;
			grpTexts.add(leText);
			leText.snapToPosition();
		}

		#if MODS_ALLOWED
		// ---- MOD list with icons (right side) ----
		directories = [null];
		for (folder in Paths.getModDirectories())
			directories.push(folder);

		// Restore last selected mod (persists across state recreations)
		var restoreMod:String = lastSelectedMod;
		if (restoreMod.length == 0)
			restoreMod = MainMenuState.selectedModFolder;
		if (restoreMod.length > 0) {
			var idx = directories.indexOf(restoreMod);
			if (idx >= 0) {
				curDirectory = idx;
				curSelectedMod = idx;
			}
		}
		// Also sync Paths.currentModDirectory to the restored selection
		var modDir:String = (directories[curDirectory] == null || directories[curDirectory].length < 1) ? '' : directories[curDirectory];
		Paths.currentModDirectory = modDir;

		var listX:Float = 900;
		var listY:Float = 100;
		var listWidth:Float = 320;
		var listHeight:Float = FlxG.height - 200;

		bgModList = FlxSpriteUtil.drawRoundRect(new FlxSprite(listX - 10, listY - 10).makeGraphic(Std.int(listWidth) + 20, Std.int(listHeight) + 20, FlxColor.TRANSPARENT), 0, 0, Std.int(listWidth) + 20, Std.int(listHeight) + 20, 15, 15, FlxColor.BLACK);
		bgModList.alpha = 0.4;
		add(bgModList);

		modsGroup = new FlxTypedGroup<EditorModItem>();
		for (i in 0...directories.length)
		{
			var folder = directories[i];
			var item:EditorModItem;
			if (folder == null)
				item = new EditorModItem(null);
			else
				item = new EditorModItem(folder);
			modsGroup.add(item);
		}
		add(modsGroup);

		curSelectedMod = curDirectory;
		updateModItemPositions();
		#end

		changeSelection();
		FlxG.mouse.visible = false;
		#if (android || desktop)
		addVirtualPad(LEFT_FULL, A_B);
		#end
		super.create();
	}

	function getOptionDisplayName(key:String):String
	{
		var displayNames:Map<String, String> = [
			'editors_week' => Language.get('editors_week', 'Week Editor'),
			'editors_menu_character' => Language.get('editors_menu_character', 'Menu Character Editor'),
			'editors_dialogue' => Language.get('editors_dialogue', 'Dialogue Editor'),
			'editors_dialogue_portrait' => Language.get('editors_dialogue_portrait', 'Dialogue Portrait Editor'),
			'editors_character' => Language.get('editors_character', 'Character Editor'),
			'editors_chart' => Language.get('editors_chart', 'Chart Editor'),
			'editors_new_chart' => Language.get('editors_new_chart', 'New Chart Editor'),
			'editors_chart_converter' => Language.get('editors_chart_converter', 'Chart Converter (osu!/Malody)'),
			'editors_background' => Language.get('editors_background', 'Background Editor'),
			'editors_credits' => Language.get('editors_credits', 'Credits Editor')
		];
		return displayNames.exists(key) ? displayNames.get(key) : key;
	}

	override function update(elapsed:Float)
	{
		#if MODS_ALLOWED
		if (onMods)
		{
			// focus on mod list
			if (controls.UI_UP_P #if (android || desktop) || (virtualPad != null && virtualPad.buttonUp.justPressed) #end)
				changeModSelection(-1);
			if (controls.UI_DOWN_P #if (android || desktop) || (virtualPad != null && virtualPad.buttonDown.justPressed) #end)
				changeModSelection(1);
			if (controls.UI_LEFT_P #if (android || desktop) || (virtualPad != null && virtualPad.buttonLeft.justPressed) #end
				|| controls.BACK #if (android || desktop) || (virtualPad != null && virtualPad.buttonB.justPressed) #end)
			{
				onMods = false;
				FlxG.sound.play(Paths.sound('cancelMenu'));
			}
			if (controls.ACCEPT #if (android || desktop) || (virtualPad != null && virtualPad.buttonA.justPressed) #end)
			{
				curDirectory = curSelectedMod;
				if (directories[curDirectory] == null || directories[curDirectory].length < 1)
					Paths.currentModDirectory = '';
				else
					Paths.currentModDirectory = directories[curDirectory];
				lastSelectedMod = Paths.currentModDirectory;
				// NOTE: Do NOT call WeekData.setDirectoryFromWeek() here.
				// It resets Paths.currentModDirectory to '' with no argument,
				// wiping the selection the player just made and making the
				// first editor entry load default (or the previously loaded mod)
				// resources. Only on a second entry (via the persisted
				// lastSelectedMod) would the chosen mod load correctly.
				FlxG.sound.play(Paths.sound('confirmMenu'));
				onMods = false;
			}
		}
		else
		{
			// focus on editor options
			if (controls.UI_UP_P #if (android || desktop) || (virtualPad != null && virtualPad.buttonUp.justPressed) #end)
				changeSelection(-1);
			if (controls.UI_DOWN_P #if (android || desktop) || (virtualPad != null && virtualPad.buttonDown.justPressed) #end)
				changeSelection(1);
			if (controls.UI_RIGHT_P #if (android || desktop) || (virtualPad != null && virtualPad.buttonRight.justPressed) #end)
			{
				onMods = true;
				FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
			}
			if (controls.BACK #if (android || desktop) || (virtualPad != null && virtualPad.buttonB.justPressed) #end)
			{
				MusicBeatState.switchState(new MainMenuState());
			}
			if (controls.ACCEPT #if (android || desktop) || (virtualPad != null && virtualPad.buttonA.justPressed) #end)
			{
				switch(options[curSelected]) {
					case 'editors_character':
						LoadingState.loadAndSwitchState(new CharacterEditorState(Character.DEFAULT_CHARACTER, false));
					case 'editors_week':
						MusicBeatState.switchState(new WeekEditorState());
					case 'editors_menu_character':
						MusicBeatState.switchState(new MenuCharacterEditorState());
					case 'editors_dialogue_portrait':
						LoadingState.loadAndSwitchState(new DialogueCharacterEditorState(), false);
					case 'editors_dialogue':
						LoadingState.loadAndSwitchState(new DialogueEditorState(), false);
					case 'editors_chart', 'editors_new_chart':
						// 旧版 / 新版编辑器已合并为同一个状态: 排版在编辑器里切换 (顶部 UI 按钮 / F9), 会记住选择
						LoadingState.loadAndSwitchState(new NewChartingState(), false);
					case 'editors_chart_converter':
						MusicBeatState.switchState(new ChartConverterState());
					case 'editors_background':
						LoadingState.loadAndSwitchState(new BackgroundEditorState(), false);
					case 'editors_credits':
						MusicBeatState.switchState(new CreditsEditorState());
				}
				FlxG.sound.music.volume = 0;
				#if PRELOAD_ALL
				FreeplayState.destroyFreeplayVocals();
				#end
			}
		}

		updateEditorItemsAlpha();
		updateModItemsAlpha();
		#else
		// Without MODS_ALLOWED
		if (controls.UI_UP_P #if (android || desktop) || (virtualPad != null && virtualPad.buttonUp.justPressed) #end)
			changeSelection(-1);
		if (controls.UI_DOWN_P #if (android || desktop) || (virtualPad != null && virtualPad.buttonDown.justPressed) #end)
			changeSelection(1);
		if (controls.BACK #if (android || desktop) || (virtualPad != null && virtualPad.buttonB.justPressed) #end)
			MusicBeatState.switchState(new MainMenuState());
		if (controls.ACCEPT #if (android || desktop) || (virtualPad != null && virtualPad.buttonA.justPressed) #end)
		{
			switch(options[curSelected]) {
				case 'editors_character':
					LoadingState.loadAndSwitchState(new CharacterEditorState(Character.DEFAULT_CHARACTER, false));
				case 'editors_week':
					MusicBeatState.switchState(new WeekEditorState());
				case 'editors_menu_character':
					MusicBeatState.switchState(new MenuCharacterEditorState());
				case 'editors_dialogue_portrait':
					LoadingState.loadAndSwitchState(new DialogueCharacterEditorState(), false);
				case 'editors_dialogue':
					LoadingState.loadAndSwitchState(new DialogueEditorState(), false);
				case 'editors_chart', 'editors_new_chart':
					// 旧版 / 新版编辑器已合并为同一个状态: 排版在编辑器里切换 (顶部 UI 按钮 / F9), 会记住选择
					LoadingState.loadAndSwitchState(new NewChartingState(), false);
				case 'editors_chart_converter':
					MusicBeatState.switchState(new ChartConverterState());
				case 'editors_background':
					LoadingState.loadAndSwitchState(new BackgroundEditorState(), false);
				case 'editors_credits':
					MusicBeatState.switchState(new CreditsEditorState());
			}
			FlxG.sound.music.volume = 0;
			#if PRELOAD_ALL
			FreeplayState.destroyFreeplayVocals();
			#end
		}
		#end

		var bullShit:Int = 0;
		for (item in grpTexts.members)
		{
			item.targetY = bullShit - curSelected;
			bullShit++;
		}
		super.update(elapsed);
	}

	function changeSelection(change:Int = 0)
	{
		FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);

		curSelected += change;

		if (curSelected < 0)
			curSelected = options.length - 1;
		if (curSelected >= options.length)
			curSelected = 0;
	}

	#if MODS_ALLOWED
	function changeModSelection(change:Int = 0)
	{
		FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);

		curSelectedMod += change;

		if (curSelectedMod < 0)
			curSelectedMod = directories.length - 1;
		if (curSelectedMod >= directories.length)
			curSelectedMod = 0;

		updateModItemPositions();
	}

	function updateModItemPositions()
	{
		var visibleCount:Int = Math.floor((bgModList.height - 20) / 86);
		var startIdx:Int = onMods ? curSelectedMod : curDirectory;
		var endIdx:Int = startIdx + visibleCount - 1;

		if (endIdx >= directories.length)
		{
			endIdx = directories.length - 1;
			startIdx = endIdx - visibleCount + 1;
			if (startIdx < 0) startIdx = 0;
		}

		for (i => item in modsGroup.members)
		{
			item.visible = (i >= startIdx && i <= endIdx);
			if (item.visible)
			{
				item.x = bgModList.x + 10;
				item.y = bgModList.y + 10 + (86 * (i - startIdx));
			}
		}
		updateModItemsAlpha();
	}

	function updateEditorItemsAlpha()
	{
		for (i => item in grpTexts.members)
		{
			item.alpha = onMods ? 0.3 : (i == curSelected) ? 1 : 0.6;
		}
	}

	function updateModItemsAlpha()
	{
		for (i => item in modsGroup.members)
		{
			if (!onMods)
			{
				item.alpha = (i == curDirectory) ? 1 : 0.3;
				item.selectBg.visible = (i == curDirectory);
			}
			else
			{
				item.alpha = (i == curSelectedMod) ? 1 : 0.6;
				item.selectBg.visible = (i == curSelectedMod);
			}
		}
	}
	#end
}

#if MODS_ALLOWED
class EditorModItem extends FlxSpriteGroup
{
	public var selectBg:FlxSprite;
	public var icon:FlxSprite;
	public var text:EditorsText;
	public var totalFrames:Int = 0;

	public var name:String = 'No Mod';
	public var desc:String = 'No description provided.';
	public var langdescription:String = null;
	public var bgColor:FlxColor = 0xFF665AFF;
	public var folder:String = null;
	public var mustRestart:Bool = false;

	public function new(?folder:String)
	{
		super();

		this.folder = folder;

		if (folder != null)
		{
			this.name = folder;
			var path = Paths.mods(folder + '/pack.json');
			if (FileSystem.exists(path))
			{
				try
				{
					var rawJson:String = File.getContent(path);
					if (rawJson != null && rawJson.length > 0)
					{
						var stuff:Dynamic = Json.parse(rawJson);

						var modName:String = Reflect.getProperty(stuff, "name");
						if (modName != null && modName.length > 0)
							this.name = modName;
						if (modName == 'Name')
							this.name = folder;

						if (Reflect.hasField(stuff, "restart")) this.mustRestart = Reflect.field(stuff, "restart");

						if (Reflect.hasField(stuff, "color"))
						{
							var colors:Array<Int> = Reflect.field(stuff, "color");
							if (colors != null && colors.length >= 3)
								this.bgColor = FlxColor.fromRGB(colors[0], colors[1], colors[2]);
						}
					}
				}
				catch (e:Dynamic)
				{
					CoolUtil.traceMsg('trace.modMetaError', 'Error loading mod metadata: {}', [e]);
				}
			}
		}
		else
		{
			this.name = 'No Mod';
		}

		selectBg = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE);
		selectBg.alpha = 0.8;
		selectBg.visible = false;
		add(selectBg);

		icon = new FlxSprite(5, 5);
		icon.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(icon);

		text = new EditorsText(95, 38, 230, "", 16);
		text.setFormat(Paths.font("editors.ttf"), 16, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		text.borderSize = 2;
		text.y -= Std.int(text.height / 2);
		add(text);

		if (folder != null)
		{
			var iconPath = Paths.mods('${folder}/pack.png');
			if (FileSystem.exists(iconPath))
			{
				var bmp = BitmapData.fromFile(iconPath);
				icon.loadGraphic(bmp, true, 150, 150);
				totalFrames = Math.floor(bmp.width / 150) * Math.floor(bmp.height / 150);
			}
			else
			{
				icon.loadGraphic(Paths.image('unknownMod'), true, 150, 150);
			}
		}
		else
		{
			icon.loadGraphic(Paths.image('unknownMod'), true, 150, 150);
		}
		icon.scale.set(0.5, 0.5);
		icon.updateHitbox();

		text.text = this.name;
		selectBg.scale.set(width + 5, height + 5);
		selectBg.updateHitbox();
	}
}
#end
