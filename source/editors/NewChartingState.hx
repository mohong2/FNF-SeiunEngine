package editors;

import backend.PsychCamera;
import backend.ui.*;
import flixel.FlxSubState;
import flixel.util.FlxSave;
import flixel.util.FlxSort;
import flixel.util.FlxSpriteUtil;
import flixel.util.FlxStringUtil;
import flixel.util.FlxDestroyUtil;
import flixel.input.keyboard.FlxKey;
import flixel.math.FlxRandom;

import lime.utils.Assets;
import lime.media.AudioBuffer;

import flash.media.Sound;
import flash.geom.Rectangle;
import flash.net.FileFilter;

import haxe.Json;
import haxe.Exception;
import haxe.io.Bytes;

import openfl.utils.Assets as OpenFlAssets;

import editors.content.MetaNote;
import editors.content.VSlice;
import editors.content.Prompt;
import editors.content.*;

import Song;
import StageData;
import Highscore;
import backend.Difficulty;
import CoolUtil;
import mohong.TraceManager;

import Section.SwagSection;
import Character;
import HealthIcon;
import Note;
import StrumNote;

using DateTools;

typedef UndoStruct = {
	var action:UndoAction;
	var data:Dynamic;
}

enum abstract UndoAction(String)
{
	var ADD_NOTE = 'Add Note';
	var DELETE_NOTE = 'Delete Note';
	var MOVE_NOTE = 'Move Note';
	var SELECT_NOTE = 'Select Note';
}

enum abstract ChartingTheme(String)
{
	var LIGHT = 'light';
	var DARK = 'dark';
	var DEFAULT = 'default';
	var VSLICE = 'vslice';
	var CUSTOM = 'custom';
}

enum abstract WaveformTarget(String)
{
	var INST = 'inst';
	var PLAYER = 'voc';
	var OPPONENT = 'opp';
}

class NewChartingState extends MusicBeatState implements PsychUIEventHandler.PsychUIEvent
{
    public static var noteTypeList:Array<String> = 
    [
            '',
            'Alt Animation',
            'Hey!',
            'Hurt Note',
            'GF Sing',
            'No Animation'
    ];

	public static function getDefaultEvents():Array<Array<String>>
	{
		return [
			['', Language.get('newchartEditor_nothing', "Nothing. Yep, that's right.")],
			['Dadbattle Spotlight', Language.get('newchartEditor_dadbattle_spotlight', "Used in Dad Battle,\nValue 1: 0/1 = ON/OFF,\n2 = Target Dad\n3 = Target BF")],
			['Hey!', Language.get('newchartEditor_hey', "Plays the \"Hey!\" animation from Bopeebo,\nValue 1: BF = Only Boyfriend, GF = Only Girlfriend,\nSomething else = Both.\nValue 2: Custom animation duration,\nleave it blank for 0.6s")],
			['Set GF Speed', Language.get('newchartEditor_set_gf_speed', "Sets GF head bopping speed,\nValue 1: 1 = Normal speed,\n2 = 1/2 speed, 4 = 1/4 speed etc.\nUsed on Fresh during the beatbox parts.\n\nWarning: Value must be integer!")],
			['Philly Glow', Language.get('newchartEditor_philly_glow', "Exclusive to Week 3\nValue 1: 0/1/2 = OFF/ON/Reset Gradient\n \nNo, i won't add it to other weeks.")],
			['Kill Henchmen', Language.get('newchartEditor_kill_henchmen', "For Mom's songs, don't use this please, i love them :(")],
			['Add Camera Zoom', Language.get('newchartEditor_add_camera_zoom', "Used on MILF on that one \"hard\" part\nValue 1: Camera zoom add (Default: 0.015)\nValue 2: UI zoom add (Default: 0.03)\nLeave the values blank if you want to use Default.")],
			['BG Freaks Expression', Language.get('newchartEditor_bg_freaks_expression', "Should be used only in \"school\" Stage!")],
			['Trigger BG Ghouls', Language.get('newchartEditor_trigger_bg_ghouls', "Should be used only in \"schoolEvil\" Stage!")],
			['Play Animation', Language.get('newchartEditor_play_animation', "Plays an animation on a Character,\nonce the animation is completed,\nthe animation changes to Idle\n\nValue 1: Animation to play.\nValue 2: Character (Dad, BF, GF)")],
			['Camera Follow Pos', Language.get('newchartEditor_camera_follow_pos', "Value 1: X\nValue 2: Y\n\nThe camera won't change the follow point\nafter using this, for getting it back\nto normal, leave both values blank.")],
			['Alt Idle Animation', Language.get('newchartEditor_alt_idle_animation', "Sets a specified postfix after the idle animation name.\nYou can use this to trigger 'idle-alt' if you set\nValue 2 to -alt\n\nValue 1: Character to set (Dad, BF or GF)\nValue 2: New postfix (Leave it blank to disable)")],
			['Screen Shake', Language.get('newchartEditor_screen_shake', "Value 1: Camera shake\nValue 2: HUD shake\n\nEvery value works as the following example: \"1, 0.05\".\nThe first number (1) is the duration.\nThe second number (0.05) is the intensity.")],
			['Change Character', Language.get('newchartEditor_change_character', "Value 1: Character to change (Dad, BF, GF)\nValue 2: New character's name")],
			['Change Scroll Speed', Language.get('newchartEditor_change_scroll_speed', "Value 1: Scroll Speed Multiplier (1 is default)\nValue 2: Time it takes to change fully in seconds.")],
			['Set Property', Language.get('newchartEditor_set_property', "Value 1: Variable name\nValue 2: New value")],
			['Play Sound', Language.get('newchartEditor_play_sound', "Value 1: Sound file name\nValue 2: Volume (Default: 1), ranges from 0 to 1")]
		];
	}

	public static var defaultEvents(get, null):Array<Array<String>>;
	static function get_defaultEvents():Array<Array<String>>
	{
		return getDefaultEvents();
	}
	
	public static var keysArray:Array<FlxKey> = [ONE, TWO, THREE, FOUR, FIVE, SIX, SEVEN, EIGHT]; //Used for Vortex Editor
	public static var SHOW_EVENT_COLUMN = true;
	/** 多k: 事件列固定宽度 (不随格宽缩小, 保证高 K 下仍可点击)。 */
	public static var EVENT_COLUMN_WIDTH:Int = 40;
	public static var GRID_COLUMNS_PER_PLAYER = 4;
	public static var GRID_PLAYERS = 2;
	public static var GRID_SIZE = 40;
	final BACKUP_EXT = '.bkp';

	/**
	 * 多k: 计算编辑器网格格宽。
	 * 1K~9K 沿用固定表 (gridSizes), 10K+ 按屏幕宽度自适应, 避免高 K 时 Note 过小。
	 */
	public static function editorGridSize(mania:Int):Int
	{
		var m:Int = EKData.clampMania(mania);
		if (m < 9) return Note.gridSizes[m];
		var cols:Int = Note.ammo[m] * GRID_PLAYERS;
		var usableW:Int = FlxG.width - 120 - (SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0);
		var auto:Int = Math.floor(usableW / cols);
		return Std.int(Math.max(auto, 18));
	}

	public var quantizations:Array<Int> = [
		4,
		6,
		8,
		12,
		16,
		20,
		24,
		32,
		48,
		64,
		96,
		128,
		192
	];
	public var quantColors:Array<FlxColor> = [
		0xFFDF0000,
		0xFF801080,
		0xFF4040CF,
		0xFFAF00AF,
		0xFFFFAF00,
		0xFFFFFFFF,
		0xFFFFA0FF,
		0xFFFF6030,
		0xFF00CFCF,
		0xFF00CF00,
		0xFF9F9F9F,
		0xFF5F5FAF,
		0xFF3F3F3F,
	];
	var curQuant(default, set):Int = 16;
	function set_curQuant(v:Int)
	{
		curQuant = v;
		updateVortexColor();
		return curQuant;
	}
	function updateVortexColor()
		vortexIndicator.color = quantColors[Std.int(FlxMath.bound(quantizations.indexOf(curQuant), 0, quantColors.length - 1))];

	var sectionFirstNoteID:Int = 0;
	var sectionFirstEventID:Int = 0;
	var curSec:Int = 0;

	/** Unsaved changes flag — prompts confirm dialog on exit / playtest. */
	public static var staticUnsavedChanges:Bool = false;
	public var unsavedChanges(get, set):Bool;
	function get_unsavedChanges():Bool return staticUnsavedChanges;
	function set_unsavedChanges(v:Bool):Bool
	{
		staticUnsavedChanges = v;
		backend.UnsavedChangesTracker.hasUnsavedChanges = v;
		if(v) backend.UnsavedChangesTracker.currentEditorState = this;
		return staticUnsavedChanges;
	}

	var chartEditorSave:FlxSave;
	var mainBox:PsychUIBox;
	var mainBoxPosition:FlxPoint = FlxPoint.get(920, 40);
	var infoBox:PsychUIBox;
	var infoBoxPosition:FlxPoint = FlxPoint.get(1000, 360);
	var upperBox:PsychUIBox;
	
	var camUI:FlxCamera;

	var prevGridBg:ChartingGridSprite;
	var gridBg:ChartingGridSprite;
	var nextGridBg:ChartingGridSprite;
	/** 多k: 小节内按 Change Mania 事件切分出的额外网格段 (前/中/后三窗的小节都可能被切分)。 */
	var gridSegments:Array<ChartingGridSprite> = [];
	/** 多k: 每个额外网格段所属窗口 (0=上 1=中 2=下)、小节、起止行 (Step*zoom) 与键数。 */
	var gridSegmentMeta:Array<{window:Int, sec:Int, startStep:Int, endStep:Int, k:Int}> = [];
	/** 多k: 分段网格是为哪个 curSec 构建的 (切节后重建)。 */
	var _segmentsBuildSec:Int = -999;
	var waveformSprite:FlxSprite;
	var scrollY:Float = 0;
	
	var zoomList:Array<Float> = [
		0.25,
		0.5,
		1,
		2,
		3,
		4,
		6,
		8,
		12,
		16,
		24
	];
	var curZoom:Float = 1;

	var mustHitIndicator:FlxSprite;
	var eventIcon:FlxSprite;
	var icons:Array<HealthIcon> = [];

	var events:Array<EventMetaNote> = [];
	var notes:Array<MetaNote> = [];

	var behindRenderedNotes:FlxTypedGroup<MetaNote> = new FlxTypedGroup<MetaNote>();
	var curRenderedNotes:FlxTypedGroup<MetaNote> = new FlxTypedGroup<MetaNote>();
	var movingNotes:FlxTypedGroup<MetaNote> = new FlxTypedGroup<MetaNote>();
	var eventLockOverlay:FlxSprite;
	var vortexIndicator:FlxSprite;
	var strumLineNotes:FlxTypedGroup<StrumNote> = new FlxTypedGroup<StrumNote>();
	var dummyArrow:FlxSprite;
	var isMovingNotes:Bool = false;
	var movingNotesLastData:Int = 0;
	var movingNotesLastY:Float = 0;
	
	var vocals:FlxSound = new FlxSound();
	var opponentVocals:FlxSound = new FlxSound();

	var timeLine:FlxSprite;
	var infoText:EditorsText;

	var autoSaveIcon:FlxSprite;
	var autoSaveTxt:FlxText;
	var outputTxt:EditorsText;
	var modIndicatorTxt:EditorsText;

	var selectionStart:FlxPoint = FlxPoint.get();
	var selectionBox:FlxSprite;

	var _shouldReset:Bool = true;
	public function new(?shouldReset:Bool = true)
	{
		this._shouldReset = shouldReset;
		super();
	}

	var bg:FlxSprite;
	var theme:ChartingTheme = DEFAULT;

	var copiedNotes:Array<Dynamic> = [];
	var copiedEvents:Array<Dynamic> = [];
	
	var _keysPressedBuffer:Array<Bool> = [];

	var tipBg:FlxSprite;
	var fullTipText:EditorsText;
	
	var vortexEnabled:Bool = false;
	var waveformEnabled:Bool = false;
	var waveformTarget:WaveformTarget = INST;

	public function initPsychCamera():PsychCamera
	{
		var camera = new PsychCamera();
		FlxG.cameras.reset(camera);
		FlxG.cameras.setDefaultDrawTarget(camera, true);
		//trace('initialized psych camera ' + Sys.cpuTime());
		return camera;
	}

	override function create()
	{
		clearUnsaved();
		if(Difficulty.list.length < 1) Difficulty.resetList();
		_keysPressedBuffer.resize(keysArray.length);

		if(_shouldReset) Conductor.songPosition = 0;
		persistentUpdate = false;
		FlxG.mouse.visible = true;
		FlxG.sound.list.add(vocals);
		FlxG.sound.list.add(opponentVocals);

		vocals.autoDestroy = false;
		vocals.looped = true;
		opponentVocals.autoDestroy = false;
		opponentVocals.looped = true;

		initPsychCamera();
		camUI = new FlxCamera();
		camUI.bgColor.alpha = 0;
		FlxG.cameras.add(camUI, false);

		chartEditorSave = new FlxSave();
		chartEditorSave.bind('chart_editor_data', CoolUtil.getSavePath());

		bg = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		bg.scrollFactor.set();
		add(bg);

		if(chartEditorSave.data.autoSave != null) autoSaveCap = chartEditorSave.data.autoSave;
		if(chartEditorSave.data.backupLimit != null) backupLimit = chartEditorSave.data.backupLimit;
		if(chartEditorSave.data.vortex != null) vortexEnabled = chartEditorSave.data.vortex;

		if(chartEditorSave.data.customBgColor == null) chartEditorSave.data.customBgColor = '303030';
		if(chartEditorSave.data.customGridColors == null || chartEditorSave.data.customGridColors.length < 2)
			chartEditorSave.data.customGridColors = ['DFDFDF', 'BFBFBF'];
		if(chartEditorSave.data.customNextGridColors == null || chartEditorSave.data.customNextGridColors.length < 2)
			chartEditorSave.data.customNextGridColors = ['5F5F5F', '4A4A4A'];
		
		changeTheme(chartEditorSave.data.theme != null ? chartEditorSave.data.theme : DEFAULT, false);

		// 多k: 进入编辑器时同步键数与网格尺寸
		if (PlayState.SONG != null)
		{
			if (PlayState.SONG.mania == null) PlayState.SONG.mania = Note.defaultMania;
			PlayState.mania = EKData.clampMania(PlayState.SONG.mania);
			GRID_COLUMNS_PER_PLAYER = Note.ammo[PlayState.mania];
			GRID_SIZE = editorGridSize(PlayState.mania);
		}
		TraceManager.info('trace.editor.create2', 'NewChartingState create() #{} mania={} notes={}', [Math.floor(FlxG.random.float(0, 100000)), PlayState.mania, PlayState.SONG != null ? PlayState.SONG.notes.length : 0]);

		createGrids();

		waveformSprite = new FlxSprite(gridBg.x + (SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0), 0).makeGraphic(1, 1, 0x00FFFFFF);
		waveformSprite.scrollFactor.x = 0;
		waveformSprite.visible = false;
		add(waveformSprite);

		dummyArrow = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE);
		dummyArrow.setGraphicSize(GRID_SIZE, GRID_SIZE);
		dummyArrow.updateHitbox();
		dummyArrow.scrollFactor.x = 0;
		add(dummyArrow);

		vortexIndicator = new FlxSprite(gridBg.x - (SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : GRID_SIZE), FlxG.height/2).loadGraphic(Paths.image('editors/vortex_indicator'));
		vortexIndicator.setGraphicSize(GRID_SIZE);
		vortexIndicator.updateHitbox();
		vortexIndicator.scrollFactor.set();
		vortexIndicator.active = false;
		updateVortexColor();
		add(vortexIndicator);
		add(strumLineNotes);

		add(behindRenderedNotes);
		add(curRenderedNotes);
		add(movingNotes);

		eventLockOverlay = new FlxSprite(gridBg.x, 0).makeGraphic(1, 1, FlxColor.BLACK);
		eventLockOverlay.alpha = 0.6;
		eventLockOverlay.visible = false;
		eventLockOverlay.scrollFactor.x = 0;
		eventLockOverlay.scale.x = SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : GRID_SIZE;
		eventLockOverlay.updateHitbox();
		add(eventLockOverlay);

		timeLine = new FlxSprite(gridBg.x, 0).makeGraphic(1, 1, FlxColor.WHITE);
		timeLine.setGraphicSize(Std.int(gridBg.width), 4);
		timeLine.updateHitbox();
		timeLine.screenCenter(Y);
		timeLine.scrollFactor.set();
		add(timeLine);

		rebuildStrumNotes();
		buildEditorUI();
		super.create();
	}

	/** 多k: 仅重建 strum 列 (mania 变化时调用, 不碰 UI)。 */
	function rebuildStrumNotes():Void
	{
		if (strumLineNotes == null || gridBg == null) return;
		strumLineNotes.clear();
		var startX:Float = gridBg.x;
		var startY:Float = FlxG.height/2;
		vortexIndicator.visible = strumLineNotes.visible = strumLineNotes.active = vortexEnabled;
		if(SHOW_EVENT_COLUMN) startX += EVENT_COLUMN_WIDTH;

		for (i in 0...Std.int(GRID_PLAYERS * GRID_COLUMNS_PER_PLAYER))
		{
			var note:StrumNote = new StrumNote(startX + (GRID_SIZE * i), startY, i % GRID_COLUMNS_PER_PLAYER, 0);
			note.scrollFactor.set();
			note.playAnim('static');
			note.alpha = 0.4;
			note.updateHitbox();
			if(note.width > note.height)
				note.setGraphicSize(GRID_SIZE);
			else
				note.setGraphicSize(0, GRID_SIZE);

			note.updateHitbox();
			note.x += GRID_SIZE/2 - note.width/2;
			note.y += GRID_SIZE/2 - note.height/2;
			strumLineNotes.add(note);
		}
	}

	/** 多k: 重排编辑器头部图标/网格分隔线 (mania 变化时调用, 不重建对象)。 */
	function repositionEditorUI():Void
	{
		if (gridBg == null || eventIcon == null || icons == null) return;
		var columns:Int = 0;
		var iconX:Float = gridBg.x;
		if(SHOW_EVENT_COLUMN)
		{
			// 多k: 事件图标大小随格宽缩放
			eventIcon.setGraphicSize(EVENT_COLUMN_WIDTH, EVENT_COLUMN_WIDTH);
			eventIcon.updateHitbox();
			eventIcon.x = iconX + (EVENT_COLUMN_WIDTH * 0.5) - eventIcon.width/2;
			iconX += EVENT_COLUMN_WIDTH;
			columns++;
		}
		for (i in 0...GRID_PLAYERS)
		{
			columns += GRID_COLUMNS_PER_PLAYER;
			if (i < icons.length)
				icons[i].x = iconX + GRID_SIZE * (GRID_COLUMNS_PER_PLAYER/2) - icons[i].width/2;
			iconX += GRID_SIZE * GRID_COLUMNS_PER_PLAYER;
		}
		// 多k: 各网格段分隔线按各自键数计算
		updateGridSegmentStripes();

		// 多k: 事件锁遮罩/时间线宽度随新格宽同步
		if (eventLockOverlay != null)
		{
			eventLockOverlay.x = gridBg.x;
			eventLockOverlay.scale.x = SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : NewChartingState.GRID_SIZE;
			eventLockOverlay.updateHitbox();
		}
		if (timeLine != null)
		{
			timeLine.x = gridBg.x;
			// 多k: 时间线宽度按当前小节最大宽度 (含事件后 9K 段)
			timeLine.setGraphicSize(Std.int(sectionWidthPx(curSec)), 4);
			timeLine.updateHitbox();
		}
		if (waveformSprite != null)
		{
			waveformSprite.x = gridBg.x + (SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0);
		}
		if (dummyArrow != null)
		{
			dummyArrow.setGraphicSize(NewChartingState.GRID_SIZE, NewChartingState.GRID_SIZE);
			dummyArrow.updateHitbox();
		}
		if (vortexIndicator != null)
		{
			vortexIndicator.x = gridBg.x - (SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : NewChartingState.GRID_SIZE);
			vortexIndicator.setGraphicSize(NewChartingState.GRID_SIZE);
			vortexIndicator.updateHitbox();
		}
		updateHeads(true);
	}

	/** 编辑器 UI 构建 (仅 create() 调用一次, 切K不重建)。 */
	function buildEditorUI():Void
	{
		var columns:Int = 0;
		var iconX:Float = gridBg.x;
		var iconY:Float = 50;
		if(SHOW_EVENT_COLUMN)
		{
			eventIcon = new FlxSprite(0, iconY).loadGraphic(Paths.image('editors/eventIcon'));
			eventIcon.antialiasing = ClientPrefs.data.globalAntialiasing;
			eventIcon.alpha = 0.6;
			eventIcon.setGraphicSize(EVENT_COLUMN_WIDTH, EVENT_COLUMN_WIDTH); // 固定可点击尺寸
			eventIcon.updateHitbox();
			eventIcon.scrollFactor.set();
			add(eventIcon);
			eventIcon.x = iconX + (EVENT_COLUMN_WIDTH * 0.5) - eventIcon.width/2;
			iconX += EVENT_COLUMN_WIDTH;

			columns++;
		}

		mustHitIndicator = FlxSpriteUtil.drawTriangle(new FlxSprite(0, iconY - 20).makeGraphic(16, 16, FlxColor.TRANSPARENT), 0, 0, 16);
		mustHitIndicator.scrollFactor.set();
		mustHitIndicator.flipY = true;
		mustHitIndicator.offset.x += mustHitIndicator.width/2;
		add(mustHitIndicator);

		var gridStripes:Array<Int> = [];
		for (i in 0...GRID_PLAYERS)
		{
			if(columns > 0) gridStripes.push(columns);
			columns += GRID_COLUMNS_PER_PLAYER;

			var icon:HealthIcon = new HealthIcon();
			icon.autoAdjustOffset = false;
			icon.y = iconY;
			icon.alpha = 0.6;
			icon.scrollFactor.set();
			icon.scale.set(0.3, 0.3);
			icon.updateHitbox();
			icon.ID = i+1;
			add(icon);
			icons.push(icon);
			
			icon.x = iconX + GRID_SIZE * (GRID_COLUMNS_PER_PLAYER/2) - icon.width/2;
			iconX += GRID_SIZE * GRID_COLUMNS_PER_PLAYER;
		}
		prevGridBg.stripes = nextGridBg.stripes = gridBg.stripes = gridStripes;
		
		selectionBox = new FlxSprite().makeGraphic(1, 1, FlxColor.CYAN);
		selectionBox.alpha = 0.4;
		selectionBox.blend = ADD;
		selectionBox.scrollFactor.set();
		selectionBox.visible = false;
		add(selectionBox);

		infoBox = new PsychUIBox(infoBoxPosition.x, infoBoxPosition.y, 220, 220, ['newchartEditor_information']);
		infoBox.scrollFactor.set();
		infoBox.cameras = [camUI];
		infoText = new EditorsText(15, 0, 230, '', 16);
		infoText.font = Paths.font('editors.ttf');
		infoText.scrollFactor.set();
		infoBox.getTab('newchartEditor_information').menu.add(infoText);
		add(infoBox);

		mainBox = new PsychUIBox(mainBoxPosition.x, mainBoxPosition.y, 300, 280, ['newchartEditor_charting', 'newchartEditor_data', 'newchartEditor_events', 'newchartEditor_note', 'newchartEditor_section', 'newchartEditor_song']);
		mainBox.selectedName = 'Song';
		mainBox.scrollFactor.set();
		mainBox.cameras = [camUI];
		add(mainBox);

		autoSaveIcon = new FlxSprite(50).loadGraphic(Paths.image('editors/autosave'));
		autoSaveIcon.screenCenter(Y);
		autoSaveIcon.scale.set(0.6, 0.6);
		autoSaveIcon.antialiasing = ClientPrefs.data.globalAntialiasing;
		autoSaveIcon.scrollFactor.set();
		autoSaveIcon.alpha = 0;
		add(autoSaveIcon);

		autoSaveTxt = new FlxText(autoSaveIcon.x + autoSaveIcon.width * 0.6 + 6, autoSaveIcon.y, 160, '', 14);
		autoSaveTxt.font = 'assets/fonts/editors.ttf';
		autoSaveTxt.color = FlxColor.WHITE;
		autoSaveTxt.scrollFactor.set();
		autoSaveTxt.visible = false;
		add(autoSaveTxt);

		// save data positions for the UI boxes
		if(chartEditorSave.data.mainBoxPosition != null && chartEditorSave.data.mainBoxPosition.length > 1)
			mainBox.setPosition(chartEditorSave.data.mainBoxPosition[0], chartEditorSave.data.mainBoxPosition[1]);
		if(chartEditorSave.data.infoBoxPosition != null && chartEditorSave.data.infoBoxPosition.length > 1)
			infoBox.setPosition(chartEditorSave.data.infoBoxPosition[0], chartEditorSave.data.infoBoxPosition[1]);

		upperBox = new PsychUIBox(40, 40, 330, 300, ['newchartEditor_file', 'newchartEditor_edit', 'newchartEditor_view']);
		upperBox.scrollFactor.set();
		upperBox.isMinimized = true;
		upperBox.minimizeOnFocusLost = true;
		upperBox.canMove = false;
		upperBox.cameras = [camUI];
		upperBox.bg.visible = false;
		add(upperBox);

		outputTxt = new EditorsText(25, FlxG.height - 50, FlxG.width - 50, '', 20);
		outputTxt.borderSize = 2;
		outputTxt.font = 'assets/fonts/vcrcn.ttf';
		outputTxt.borderStyle = OUTLINE_FAST;
		outputTxt.scrollFactor.set();
		outputTxt.cameras = [camUI];
		outputTxt.alpha = 0;
		add(outputTxt);

		// Modified status indicator (shows ● when unsaved changes exist)
		modIndicatorTxt = new EditorsText(25, 8, 200, '', 14);
		modIndicatorTxt.font = Paths.font('editors.ttf');
		modIndicatorTxt.setFormat(null, 14, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
		modIndicatorTxt.borderSize = 1;
		modIndicatorTxt.scrollFactor.set();
		modIndicatorTxt.cameras = [camUI];
		add(modIndicatorTxt);

		if(PlayState.SONG == null) //Atleast try to avoid crashes
		{
			openNewChart();
		}

		updateJsonData();
		
		// TABS
		////// for main box
		addChartingTab();
		addDataTab();
		addEventsTab();
		addNoteTab();
		addSectionTab();
		addSongTab();
		
		////// for upper box
		addFileTab();
		addEditTab();
		addViewTab();
		//

		loadMusic();
		reloadNotesDropdowns();
		if(!_shouldReset)
		{
			vocals.time = opponentVocals.time = FlxG.sound.music.time = Conductor.songPosition - Conductor.offset;
			if(FlxG.sound.music.time >= vocals.length)
				vocals.pause();
			if(FlxG.sound.music.time >= opponentVocals.length)
				opponentVocals.pause();
		}

		reloadNotes();
		updateGridVisibility();

		// CHARACTERS FOR THE DROP DOWNS
		var gameOverCharacters:Array<String> = loadFileList('characters/', 'data/characterList.txt');
		var characterList:Array<String> = gameOverCharacters.filter((name:String) -> (!name.endsWith('-dead') && !name.endsWith('-death')));
		playerDropDown.list = characterList;
		opponentDropDown.list = characterList;
		girlfriendDropDown.list = characterList;

		gameOverCharacters.insert(0, '');
		gameOverCharacters.sort(function(a:String, b:String)
		{
			if((a == '' || a.endsWith('-dead') || a.endsWith('-death')) && !(b == '' || b.endsWith('-dead') || b.endsWith('-death'))) return -1; //Prioritize "-dead" or "-death" characters
			return 0;
		});
		gameOverCharDropDown.list = gameOverCharacters;
		gameOverCharDropDown.maxItems = 12;

		stageDropDown.list = loadFileList('stages/', 'data/stageList.txt');
		onChartLoaded();

		var tipText:EditorsText = new EditorsText(FlxG.width - 210, FlxG.height - 30, 200, Language.get('newchartEditor_press_f1_for_help', 'Press F1 for Help'), 20);
		tipText.cameras = [camUI];
		tipText.setFormat(Paths.font('editors.ttf'), 16, FlxColor.WHITE, RIGHT);
		tipText.borderColor = FlxColor.BLACK;
		tipText.scrollFactor.set();
		tipText.borderSize = 1;
		tipText.active = false;
		add(tipText);

		tipBg = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		tipBg.cameras = [camUI];
		tipBg.scale.set(FlxG.width, FlxG.height);
		tipBg.updateHitbox();
		tipBg.scrollFactor.set();
		tipBg.visible = tipBg.active = false;
		tipBg.alpha = 0.6;
		add(tipBg);
		
		fullTipText = new EditorsText(0, 0, FlxG.width - 200);
		fullTipText.setFormat(Paths.font('editors.ttf'), Std.parseInt(Language.get('newchartEditor_help_text_size', '24')), FlxColor.WHITE, CENTER);
		fullTipText.cameras = [camUI];
		fullTipText.scrollFactor.set();
		fullTipText.visible = fullTipText.active = false;
		var helpTexts:Array<String> = Language.get('newchartEditor_help_text', '').split('\n');
			if(helpTexts.length > 0 && helpTexts[0] != '')
			{
				fullTipText.text = helpTexts.join('\n');
			}
			else
			{
				fullTipText.text = [
					"W/S/Mouse Wheel - Move Conductor's Time",
					"A/D - Change Sections",
					"Q/E - Decrease/Increase Note Sustain Length",
					"Hold Shift/Alt to Increase/Decrease move by 4x",
					"",
					"F12 - Preview Chart",
					"Enter - Playtest Chart",
					"Space - Stop/Resume song",
					"",
					"Alt + Click - Select Note(s)",
					"Shift + Click - Select/Unselect Note(s)",
					"Right Click - Selection Box",
					"",
					"R - Reset Section",
					"Shift + R - Go Back to the Start of the Song",
					"Z/X - Zoom in/out",
					"Left/Right - Change Snap",
					#if FLX_PITCH
					"Left Bracket / Right Bracket - Change Song Playback Rate",
					"ALT + Left Bracket / Right Bracket - Reset Song Playback Rate",
					#end
					"",
					"Ctrl + Z - Undo",
					"Ctrl + Y - Redo",
					"Ctrl + X - Cut Selected Notes",
					"Ctrl + C - Copy Selected Notes",
					"Ctrl + V - Paste Copied Notes",
					"Ctrl + A - Select all in current Section",
					"Ctrl + S - Quicksave",
				].join('\n');
			}
    
		fullTipText.screenCenter();
		add(fullTipText);
		#if (android || desktop)
		addVirtualPad(LEFT_FULL, NEW_CHART_EDITOR);
		#end
	}

	var gridColors:Array<FlxColor>;
	var gridColorsOther:Array<FlxColor>;
	function changeTheme(changeTo:ChartingTheme, ?doSave:Bool = true)
	{
		var oldTheme:ChartingTheme = theme;
		theme = changeTo;
		chartEditorSave.data.theme = changeTo;
		if(doSave) chartEditorSave.flush();

		switch(theme)
		{
			case LIGHT:
				bg.color = 0xFFA0A0A0;
				gridColors = [0xFFDFDFDF, 0xFFBFBFBF];
				gridColorsOther = [0xFF5F5F5F, 0xFF4A4A4A];
			case DARK:
				bg.color = 0xFF222222;
				gridColors = [0xFF3F3F3F, 0xFF2F2F2F];
				gridColorsOther = [0xFF1F1F1F, 0xFF111111];
			case VSLICE:
				bg.color = 0xFF673AB7;
				gridColors = [0xFFD0D0D0, 0xFFAFAFAF];
				gridColorsOther = [0xFF595959, 0xFF464646];
			case CUSTOM:
				bg.color = CoolUtil.colorFromString(chartEditorSave.data.customBgColor);
				gridColors = [CoolUtil.colorFromString(chartEditorSave.data.customGridColors[0]), CoolUtil.colorFromString(chartEditorSave.data.customGridColors[1])];
				gridColorsOther = [CoolUtil.colorFromString(chartEditorSave.data.customNextGridColors[0]), CoolUtil.colorFromString(chartEditorSave.data.customNextGridColors[1])];
			default:
				bg.color = 0xFF303030;
				gridColors = [0xFFDFDFDF, 0xFFBFBFBF];
				gridColorsOther = [0xFF5F5F5F, 0xFF4A4A4A];
		}

		if(theme != oldTheme || theme == CUSTOM)
		{
			if(gridBg != null)
			{
				gridBg.loadGrid(gridColors[0], gridColors[1]);
				gridBg.vortexLineEnabled = vortexEnabled;
				gridBg.vortexLineSpace = GRID_SIZE * 4 * curZoom;
			}
			if(prevGridBg != null)
			{
				prevGridBg.loadGrid(gridColorsOther[0], gridColorsOther[1]);
				prevGridBg.vortexLineEnabled = vortexEnabled;
				prevGridBg.vortexLineSpace = GRID_SIZE * 4 * curZoom;
			}
			if(nextGridBg != null)
			{
				nextGridBg.loadGrid(gridColorsOther[0], gridColorsOther[1]);
				nextGridBg.vortexLineEnabled = vortexEnabled;
				nextGridBg.vortexLineSpace = GRID_SIZE * 4 * curZoom;
			}
			// 多k: 额外网格段同步换色 (中窗用当前色, 上下窗用相邻色)
			for (i => seg in gridSegments)
			{
				if (seg == null || i >= gridSegmentMeta.length) continue;
				var meta = gridSegmentMeta[i];
				seg.loadGrid((meta.window == 1) ? gridColors[0] : gridColorsOther[0], (meta.window == 1) ? gridColors[1] : gridColorsOther[1]);
				seg.vortexLineEnabled = vortexEnabled;
				seg.vortexLineSpace = GRID_SIZE * 4 * curZoom;
			}
		}
	}

	function openNewChart()
	{
		var song:SwagSong = {
			song: 'Test',
			notes: [],
			events: [],
			bpm: 150,
			needsVoices: true,
			speed: 1,
			offset: 0,

			arrowSkin: '',
			splashSkin: 'noteSplashes',
			player1: 'bf',
			player2: 'dad',
			gfVersion: 'gf',
			stage: 'stage',
			format: 'psych_v1',

            validScore: true,
		};
		Song.chartPath = null;
		loadChart(song);
	}

	function prepareReload()
	{
		if(unsavedChanges)
		{
			openSubState(new editors.content.Prompt(
				Language.get('newchartEditor_unsaved_reload', 'You have unsaved changes.\nReload anyway?'),
				function()
				{
					doPrepareReload();
				}
			));
		}
		else
		{
			doPrepareReload();
		}
	}

	function doPrepareReload():Void
	{
		updateJsonData();
		_cacheSections(); // must be called BEFORE reloadNotes so cachedSectionCrochets is fresh
		// 多k: 任何加载/重载路径, 只要键数变了就重建网格/轨道/头部,
		// 保证打开 7K 谱面后网格与键数显示立即同步。
		if (_lastGridMania != PlayState.mania)
		{
			try
			{
				createGrids(false);
				rebuildStrumNotes();
				repositionEditorUI();
				updateGridVisibility();
			}
			catch (e:Dynamic)
			{
				TraceManager.error('trace.editor.exception', 'grid rebuild failed: {}', [Std.string(e)]);
			}
		}
		loadMusic();
		reloadNotes();
		onChartLoaded();
		updateHeads(true);
		
		autoSaveTime = 0;
		Conductor.songPosition = 0;
		if(FlxG.sound.music != null) FlxG.sound.music.time = 0;
		curSec = 0;
		loadSection();
		forceDataUpdate = true;
		clearUnsaved();
	}

	function onChartLoaded()
	{
		if(PlayState.SONG == null) return;

		// SONG TAB
		songNameInputText.text = PlayState.SONG.song;
		allowVocalsCheckBox.checked = (PlayState.SONG.needsVoices != false); //If the song for some reason does not have this value, it will be set to true

		bpmStepper.value = PlayState.SONG.bpm;
		scrollSpeedStepper.value = PlayState.SONG.speed;
		audioOffsetStepper.value = Reflect.hasField(PlayState.SONG, 'offset') ? PlayState.SONG.offset : 0;
		maniaStepper.value = (PlayState.SONG.mania != null ? PlayState.SONG.mania : Note.defaultMania) + 1;
		Conductor.offset = audioOffsetStepper.value;

		playerDropDown.selectedLabel = PlayState.SONG.player1;
		opponentDropDown.selectedLabel = PlayState.SONG.player2;
		girlfriendDropDown.selectedLabel = PlayState.SONG.gfVersion;
		stageDropDown.selectedLabel = PlayState.SONG.stage;
		StageData.loadDirectory(PlayState.SONG);

		// DATA TAB
		gameOverCharDropDown.selectedLabel = PlayState.SONG.gameOverChar;
		gameOverSndInputText.text = PlayState.SONG.gameOverSound;
		gameOverLoopInputText.text = PlayState.SONG.gameOverLoop;
		gameOverRetryInputText.text = PlayState.SONG.gameOverEnd;

		noRGBCheckBox.checked = (PlayState.SONG.disableNoteRGB == true);

		noteTextureInputText.text = PlayState.SONG.arrowSkin;
		noteSplashesInputText.text = PlayState.SONG.splashSkin;
	}
	
	var noteSelectionSine:Float = 0;
	var selectedNotes:Array<MetaNote> = [];
	var ignoreClickForThisFrame:Bool = false;
	var outputAlpha:Float = 0;
	var songFinished:Bool = false;

	#if android
	var _longPressNote:MetaNote = null;
	var _longPressTimer:Float = 0;
	var _longPressThreshold:Float = 0.4; // seconds
	#end

	var fileDialog:FileDialogHandler = new FileDialogHandler();
	var _exportKeyMode:Int = 0; // 0 = auto (4K/8K), 4 = force 4K, 8 = force 8K
	var _exportCreator:String = ''; // optional author/creator override for osu!/Malody export
	var lastFocus:PsychUIInputText;

	var autoSaveTime:Float = 0;
	var autoSaveCap:Int = 2; //in minutes
	var backupLimit:Int = 10;

	var lastBeatHit:Int = 0;
	override function update(elapsed:Float)
	{
		if(!fileDialog.completed)
		{
			lastFocus = PsychUIInputText.focusOn;
			return;
		}

		// 多k: Change Mania 事件键数输入结束后执行一次重编码 + 网格重建
		var focusOnEventInput:Bool = (PsychUIInputText.focusOn == value1InputText || PsychUIInputText.focusOn == value2InputText);
		if(focusOnEventInput) _eventInputFocused = true;
		else if(_eventInputFocused)
		{
			_eventInputFocused = false;
			if(_pendingManiaReencode)
			{
				_pendingManiaReencode = false;
				refreshAfterManiaEventEdit(_pendingManiaOldEvents);
			}
		}

		for (num => key in keysArray)
			_keysPressedBuffer[num] = FlxG.keys.checkStatus(key, JUST_PRESSED);

		autoSaveTxt.visible = false;
		if(ClientPrefs.data.chartAutosave && autoSaveCap > 0)
		{
			autoSaveTime += elapsed / 60.0;
			// 自动保存倒计时显示
			var remainingSecs:Int = Std.int(Math.max(0, (autoSaveCap - autoSaveTime) * 60));
			autoSaveTxt.text = Std.string(Std.int(remainingSecs / 60)) + ':' + StringTools.lpad(Std.string(remainingSecs % 60), '0', 2);
			autoSaveTxt.visible = true;
			//trace(autoSaveTime);
			//#if debug if(FlxG.keys.justPressed.J) autoSaveTime += 20/60.0; #end
			if(autoSaveTime >= autoSaveCap #if debug || FlxG.keys.justPressed.NUMPADMULTIPLY #end)
			{
				// 自动保存跑在主循环里，任何一步（建目录/写文件/清理旧备份）失败抛出的
				// 异常都会穿透 lime 的事件分发直接崩溃进程；自动保存只许失败、不许崩溃。
				FlxTween.cancelTweensOf(autoSaveIcon);
				autoSaveTime = 0;
				autoSaveIcon.alpha = 0;
				try
				{
					updateChartData();
					var chartName:String = 'unknown';
					if (PlayState.SONG.song != null) chartName = PlayState.SONG.song;
					if(Song.chartPath != null && PlayState.SONG.song != null)
					{
						chartName = Song.chartPath.replace('\\', '/');
						chartName = chartName.substring(chartName.lastIndexOf('/')+1, chartName.lastIndexOf('.'));
					}

					chartName += DateTools.format(Date.now(), '_%Y-%m-%d_%H-%M-%S');
					var songCopy:SwagSong = Reflect.copy(PlayState.SONG);
					Reflect.setField(songCopy, '__original_path', Song.chartPath);
					var dataToSave:String = haxe.Json.stringify(songCopy);
					//trace(chartName, dataToSave);
					#if sys
					if(!FileSystem.isDirectory('backups')) FileSystem.createDirectory('backups');
					File.saveContent('backups/$chartName.$BACKUP_EXT', dataToSave);

					if(backupLimit > 0)
					{
						var files:Array<String> = FileSystem.readDirectory('backups/').filter((file:String) -> file.endsWith('.$BACKUP_EXT'));
						if(files.length > backupLimit)
						{
							var incorrect:Array<String> = [];
							var map:Map<String, Float> = [];
							for(file in files)
							{
								var split:Array<String> = file.split('_');
								if(split.length > 2) //is properly formatted
								{
									try
									{
										var timeStr:String = split[split.length-1].replace('-', ':');
										timeStr = timeStr.substr(0, timeStr.indexOf('.'));

										var fileJoin:String = split[split.length-2] + ' ' + timeStr;
										var date:Date = Date.fromString(fileJoin);
										//trace(fileJoin, date.getTime());
										map.set(file, date.getTime());
									}
									catch(e:Exception)
									{
										incorrect.push(file);
									}
								}
								else incorrect.push(file);
							}

							if(incorrect.length > 0) files = files.filter((file:String) -> !incorrect.contains(file));
							files.sort(function(a:String, b:String) return map.get(a) > map.get(b) ? 1 : -1);

							while(files.length > backupLimit)
							{
								var file = files.shift();
								//trace('removed $file');
								try
								{
									FileSystem.deleteFile('backups/$file');
								}
								catch(e:Exception) {}
							}
						}
					}
					#end

					FlxTween.tween(autoSaveIcon, {alpha: 1}, 0.5, {onComplete: function(_)
						FlxTween.tween(autoSaveIcon, {alpha: 0}, 0.5, {startDelay: 2})
					});
				}
				catch(e:Dynamic)
				{
					TraceManager.error('trace.editor.exception', 'Autosave failed: {}', [Std.string(e)]);
					showOutput('newchartEditor_error_autosave_failed', true, [Std.string(e)]);
				}
			}
		}

		ClientPrefs.toggleVolumeKeys(PsychUIInputText.focusOn == null);

		var lastTime:Float = Conductor.songPosition;
		outputAlpha = Math.max(0, outputAlpha - elapsed);
		var holdingAlt:Bool = FlxG.keys.pressed.ALT;
		if(FlxG.sound.music != null)
		{
			if(PsychUIInputText.focusOn == null) //If not typing anything
			{
				if(FlxG.keys.justPressed.F12)
				{
					super.update(elapsed);
					openEditorPlayState();
					lastFocus = PsychUIInputText.focusOn;
					return;
				}
				else if(FlxG.keys.justPressed.F1)
				{
					var vis:Bool = !fullTipText.visible;
					tipBg.visible = tipBg.active = fullTipText.visible = fullTipText.active = vis;
				}

				var goingBack:Bool = false;
				if(FlxG.keys.pressed.RBRACKET || (FlxG.keys.pressed.LBRACKET && (goingBack = true)))
				{
					if(holdingAlt)
					{
						if(playbackRate != 1)
						{
							playbackRate = 1;
							setPitch();
						}
					}
					else
					{
						playbackRate = FlxMath.bound(playbackRate + elapsed * (!goingBack ? 1 : -1), playbackSlider.min, playbackSlider.max);
						setPitch();
					}
					playbackSlider.value = playbackRate;
				}

				if(vortexEnabled && _keysPressedBuffer.contains(true))
				{
					var typeSelected:String = noteTypes[noteTypeDropDown.selectedIndex];
					if(typeSelected != null)
					{
						typeSelected = typeSelected.trim();
						if(typeSelected.length < 1) typeSelected = null;
					}

					var sectionStart:Float = cachedSectionTimes[curSec];
					var strumTime:Float = Conductor.songPosition - sectionStart;
					strumTime -= strumTime % (Conductor.stepCrochet * 16 / curQuant);
					strumTime += sectionStart;

					TraceManager.debug('trace.editor.vortexPress', 'Vortex editor press at time: {}', [strumTime]);
					var deletedNotes:Array<MetaNote> = [];
					var addedNotes:Array<MetaNote> = [];
					for (num => press in _keysPressedBuffer)
					{
						if(!press) continue;

						// Try to find a note to delete first
						var didDelete:Bool = false;
						for (note in curRenderedNotes)
						{
							if(note == null || note.isEvent) continue;

							if(note.songData[1] == num && Math.abs(strumTime - note.strumTime) < 1)
							{
								deletedNotes.push(note);
								didDelete = true;
								break;
							}
						}

						if(didDelete) continue;

						// If no notes were found, add a new in its place
						var didAdd:Bool = false;
						var noteSetupData:Array<Dynamic> = [strumTime, num, 0];
						if(typeSelected != null) noteSetupData.push(typeSelected);
	
						var noteAdded:MetaNote = createNote(noteSetupData);
						for (num in sectionFirstNoteID...notes.length)
						{
							var note = notes[num];
							if(note.strumTime >= strumTime)
							{
								notes.insert(num, noteAdded);
								didAdd = true;
								break;
							}
						}
						if(!didAdd) notes.push(noteAdded);
						addedNotes.push(noteAdded);
					}

					if(deletedNotes.length > 0)
					{
						var wasSelected:Bool = false;
						for (note in deletedNotes)
						{
							if(selectedNotes.contains(note))
							{
								selectedNotes.remove(note);
								wasSelected = true;
							}
							notes.remove(note);
						}
						if(wasSelected) onSelectNote();
						addUndoAction(DELETE_NOTE, {notes: deletedNotes});
					}
					if(addedNotes.length > 0)
						addUndoAction(ADD_NOTE, {notes: addedNotes});

					softReloadNotes(true);
				}
				else if((#if (android || desktop) (virtualPad != null && virtualPad.buttonLeft.justPressed) || #end FlxG.keys.justPressed.A) != (#if (android || desktop) (virtualPad != null && virtualPad.buttonRight.justPressed) || #end FlxG.keys.justPressed.D) && !holdingAlt)
				{
					if(FlxG.sound.music.playing)
						setSongPlaying(false);

					var shiftAdd:Int = (#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.SHIFT) ? 4 : 1;

					if(#if (android || desktop) (virtualPad != null && virtualPad.buttonLeft.justPressed) || #end FlxG.keys.justPressed.A)
					{
						if(curSec - shiftAdd < 0) shiftAdd = curSec;

						if(shiftAdd > 0)
						{
							loadSection(curSec - shiftAdd);
							var targetTime:Float = cachedSectionTimes[curSec] - Conductor.offset + 0.000001;
							FlxTween.cancelTweensOf(FlxG.sound.music);
							FlxTween.tween(FlxG.sound.music, {time: targetTime}, 0.2, {ease: FlxEase.circOut});
							Conductor.songPosition = targetTime;
						}
					}
					else if(#if (android || desktop) (virtualPad != null && virtualPad.buttonRight.justPressed) || #end FlxG.keys.justPressed.D)
					{
						if(curSec + shiftAdd >= PlayState.SONG.notes.length) shiftAdd = PlayState.SONG.notes.length - curSec - 1;
                        
						if(shiftAdd > 0)
						{
							loadSection(curSec + shiftAdd);
							var targetTime:Float = cachedSectionTimes[curSec] - Conductor.offset + 0.000001;
							FlxTween.cancelTweensOf(FlxG.sound.music);
							FlxTween.tween(FlxG.sound.music, {time: targetTime}, 0.2, {ease: FlxEase.circOut});
							Conductor.songPosition = targetTime;
						}
					}
				}
				else if(FlxG.keys.justPressed.HOME)
				{
					setSongPlaying(false);
					loadSection(0);
					FlxTween.cancelTweensOf(FlxG.sound.music);
					FlxTween.tween(FlxG.sound.music, {time: 0}, 0.3, {ease: FlxEase.circOut});
					Conductor.songPosition = 0;
				}
				else if(FlxG.keys.justPressed.END)
				{
					setSongPlaying(false);
					loadSection(PlayState.SONG.notes.length - 1);
					Conductor.songPosition = FlxG.sound.music.time = FlxG.sound.music.length - 1;
				}
				else if(#if (android || desktop) (virtualPad != null && virtualPad.buttonB.justPressed) || #end FlxG.keys.justPressed.R)
				{
					var timeToGoBack:Float = 0;
					if(#if (android || desktop) (virtualPad == null || !virtualPad.buttonY.pressed) || #end !FlxG.keys.pressed.SHIFT) timeToGoBack = cachedSectionTimes[curSec] + (curSec > 0 ? 0.000001 : 0);
					else loadSection(0);
					FlxTween.cancelTweensOf(FlxG.sound.music);
					FlxTween.tween(FlxG.sound.music, {time: timeToGoBack}, 0.2, {ease: FlxEase.circOut});
					Conductor.songPosition = timeToGoBack;
				}
				else if(!PsychUIDropDownMenu.anyDropdownOpen && ((FlxG.keys.pressed.W #if (android || desktop) || (virtualPad != null && virtualPad.buttonUp.pressed) #end) != (FlxG.keys.pressed.S #if (android || desktop) || (virtualPad != null && virtualPad.buttonDown.pressed) #end) || FlxG.mouse.wheel != 0))
				{
					if(FlxG.sound.music.playing)
						setSongPlaying(false);

					if(mouseSnapCheckBox.checked && FlxG.mouse.wheel != 0)
					{
						var snap:Float = Conductor.stepCrochet / (curQuant/16) / curZoom;
						var timeAdd:Float = (#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.SHIFT ? 4 : 1) / (holdingAlt ? 4 : 1) * -FlxG.mouse.wheel * snap;
						var targetTime:Float = Math.round((FlxG.sound.music.time + timeAdd) / snap) * snap;
						if(targetTime > 0) targetTime += 0.000001;
						FlxTween.cancelTweensOf(FlxG.sound.music);
						FlxTween.tween(FlxG.sound.music, {time: targetTime}, 0.15, {ease: FlxEase.circOut});
					}
					else
					{
						var speedMult:Float = (#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.SHIFT ? 4 : 1) * (FlxG.mouse.wheel != 0 ? 4 : 1) / (holdingAlt ? 4 : 1);
						if((FlxG.keys.pressed.W #if (android || desktop) || (virtualPad != null && virtualPad.buttonUp.pressed) #end) || FlxG.mouse.wheel > 0)
							FlxG.sound.music.time -= Conductor.crochet * speedMult * 1.5 * elapsed / curZoom;
						else if((FlxG.keys.pressed.S #if (android || desktop) || (virtualPad != null && virtualPad.buttonDown.pressed) #end) || FlxG.mouse.wheel < 0)
							FlxG.sound.music.time += Conductor.crochet * speedMult * 1.5 * elapsed / curZoom;
					}

					FlxG.sound.music.time = FlxMath.bound(FlxG.sound.music.time, 0, FlxG.sound.music.length - 1);
					if(FlxG.sound.music.playing) setSongPlaying(!FlxG.sound.music.playing);
				}
				else if(#if (android || desktop) (virtualPad != null && virtualPad.buttonX.justPressed) || #end FlxG.keys.justPressed.SPACE)
				{
					setSongPlaying(!FlxG.sound.music.playing);
				}
			}

			if(!songFinished) Conductor.songPosition = FlxMath.bound(FlxG.sound.music.time + Conductor.offset, 0, FlxG.sound.music.length - 1);
			updateScrollY();
		}

		super.update(elapsed);

		if(songFinished)
		{
			onSongComplete();
			lastTime = FlxG.sound.music.time;
			songFinished = false;
		}
		else if(FlxG.sound.music != null)
		{
			if(FlxG.sound.music.time >= vocals.length)
				vocals.pause();
			if(FlxG.sound.music.time >= opponentVocals.length)
				opponentVocals.pause();

			while(curSec > 0 && Conductor.songPosition < cachedSectionTimes[curSec])
				loadSection(curSec - 1);
			while(curSec < cachedSectionTimes.length - 1 && Conductor.songPosition >= cachedSectionTimes[curSec + 1])
				loadSection(curSec + 1);
		}

		if(PsychUIInputText.focusOn == null && lastFocus == null)
		{
			var doCut:Bool = false;
			var canContinue:Bool = true;
			if(#if (android || desktop) (virtualPad != null && virtualPad.buttonA.justPressed) || #end FlxG.keys.justPressed.ENTER)
			{
				goToPlayState();
				return;
			}
			else if(FlxG.keys.pressed.CONTROL && !isMovingNotes && (FlxG.keys.justPressed.Z || FlxG.keys.justPressed.Y || FlxG.keys.justPressed.X ||
				FlxG.keys.justPressed.C || FlxG.keys.justPressed.V || FlxG.keys.justPressed.A || FlxG.keys.justPressed.S || FlxG.keys.justPressed.R))
			{
				canContinue = false;
				if(FlxG.keys.justPressed.Z)
					undo();
				else if(FlxG.keys.justPressed.Y)
					redo();
				else if((doCut = FlxG.keys.justPressed.X) || FlxG.keys.justPressed.C) // Cut (Ctrl + X) and Copy (Ctrl + C)
				{
					if(selectedNotes.length > 0)
					{
						copiedNotes = [];
						copiedEvents = [];
						var pushedNotes:Array<Array<Dynamic>> = [];

						for (note in selectedNotes)
						{
							if(note == null) continue;

							var copied:Array<Dynamic> = makeNoteDataCopy(note.songData, note.isEvent);
							pushedNotes.push(copied);
							if(note.isEvent) copiedEvents.push(copied);
							else copiedNotes.push(copied);
						}
						pushedNotes.sort((a:Array<Dynamic>, b:Array<Dynamic>) -> FlxSort.byValues(FlxSort.ASCENDING, a[0], b[0]));
						
						var minTime:Float = pushedNotes[0][0];
						for (note in pushedNotes)
							note[0] -= minTime;
					}
				}
				else if(FlxG.keys.justPressed.V) // Paste (Ctrl + V)
				{
					if(copiedNotes.length > 0 || copiedEvents.length > 0)
					{
						selectionBox.visible = false;
						stopMovingNotes();
						resetSelectedNotes();
						selectedNotes = pasteCopiedNotesToSection();
						selectedNotes.sort(PlayState.sortByTime);

						var didFind:Bool = false;
						var minNoteData:Float = Math.POSITIVE_INFINITY;
						for (note in selectedNotes)
						{
							if(note == null || note.isEvent) continue;

							if(minNoteData > note.songData[1]) minNoteData = note.songData[1];
							didFind = true;
						}
						if(!didFind) minNoteData = 0;
						
						var pushedNotes:Array<MetaNote> = [];
						var pushedEvents:Array<EventMetaNote> = [];
						for (note in selectedNotes)
						{
							if(note == null) continue;

							if(!note.isEvent)
							{
								note.changeNoteData(Std.int(note.songData[1] - minNoteData));
								pushedNotes.push(note);
							}
							else pushedEvents.push(cast (note, EventMetaNote));
						}
						addUndoAction(ADD_NOTE, {notes: pushedNotes, events: pushedEvents});
						moveSelectedNotes(Std.int(minNoteData), selectedNotes[0].y);
					}
				}
				else if(FlxG.keys.justPressed.A) // Select All (Ctrl + A)
				{
					var sel = selectedNotes;
					selectedNotes = curRenderedNotes.members.copy();
					addUndoAction(SELECT_NOTE, {old: sel, current: selectedNotes.copy()});
					onSelectNote();
					TraceManager.debug('trace.editor.noteSelected', 'Notes selected: {}', [selectedNotes.length]);
				}
				else if(FlxG.keys.justPressed.S) // Save (Ctrl + S)
					saveChart();
				else if(FlxG.keys.justPressed.R) // Reload (Ctrl + R)
				{
					if(Song.chartPath != null)
					{
						prepareReload();
						showOutput('newchartEditor_reloaded', false);
					}
					else
						showOutput('newchartEditor_no_chart_loaded', true);
				}
			}
			
			if(doCut || FlxG.keys.justPressed.DELETE || FlxG.keys.justPressed.BACKSPACE || (isMovingNotes && (FlxG.mouse.justPressedRight || FlxG.keys.justPressed.ESCAPE))) // Delete button
			{
				if(selectedNotes.length > 0)
				{
					// 多k: 删除 Change Mania 事件 -> 记录快照, 删除后按工具箱模式重编码
					var oldEvents:Array<Dynamic> = deepCopyEditorEvents();
					var removedNotes:Array<MetaNote> = [];
					var removedEvents:Array<EventMetaNote> = [];
					while(selectedNotes.length > 0)
					{
						var note:MetaNote = selectedNotes[0];
						selectedNotes.shift();
						if(note == null) continue;
		
						var kind:String = !note.isEvent ? 'note' : 'event';
						TraceManager.debug('trace.editor.noteRemoved', 'Removed {} at time: {}', [kind, note.strumTime]);
						if(!note.isEvent)
						{
							notes.remove(note);
							removedNotes.push(note);
						}
						else
						{
							var ev:EventMetaNote = cast (note, EventMetaNote);
							events.remove(ev);
							removedEvents.push(ev);
						}
					}
					movingNotes.clear();
					isMovingNotes = false;
					selectedNotes = [];
					onSelectNote();
					// 删除残影动画 (ghost fade-out)
					for (n in removedNotes) spawnDeleteGhost(n);
					for (ev in removedEvents) spawnDeleteGhost(ev);
					softReloadNotes();
					addUndoAction(DELETE_NOTE, {notes: removedNotes, events: removedEvents});
					for (ev in removedEvents)
						if (eventHasChangeMania(ev)) { refreshAfterManiaEventEdit(oldEvents); break; }
				}
			}
			else if(canContinue)
			{
				if(FlxG.keys.justPressed.LEFT != FlxG.keys.justPressed.RIGHT) //Lower/Higher quant
				{
					if (FlxG.keys.pressed.CONTROL)
					{
						// Coarse preset jumps (power-of-two beat snaps)
						var presetSnaps:Array<Int> = [4, 8, 16, 32, 64, 128, 192];
						var idx:Int = presetSnaps.indexOf(curQuant);
						if (idx < 0) idx = 0;
						idx += FlxG.keys.justPressed.RIGHT ? 1 : -1;
						if (idx < 0) idx = presetSnaps.length - 1;
						if (idx >= presetSnaps.length) idx = 0;
						curQuant = presetSnaps[idx];
					}
					else
					{
						if(FlxG.keys.justPressed.LEFT)
							curQuant = quantizations[Std.int(Math.max(quantizations.indexOf(curQuant) - 1, 0))];
						else
							curQuant = quantizations[Std.int(Math.min(quantizations.indexOf(curQuant) + 1, quantizations.length - 1))];
					}
					forceDataUpdate = true;
				}
			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonZ.justPressed) || #end FlxG.keys.justPressed.Z != #if (android || desktop) (virtualPad != null && virtualPad.buttonD.justPressed) || #end FlxG.keys.justPressed.X) //Decrease/Increase Zoom
				{
					if (#if (android || desktop) (virtualPad != null && virtualPad.buttonZ.justPressed) || #end FlxG.keys.justPressed.Z)
						curZoom = zoomList[Std.int(Math.max(zoomList.indexOf(curZoom) - 1, 0))];
					else
						curZoom = zoomList[Std.int(Math.min(zoomList.indexOf(curZoom) + 1, zoomList.length - 1))];
					notes.sort(PlayState.sortByTime);
					var noteSec:Int = 0;
					for (num => note in notes)
					{
						if(note == null) continue;
						while(noteSec < cachedSectionTimes.length - 1 && cachedSectionTimes[noteSec + 1] <= note.strumTime) noteSec++;
						note.updateSustainToZoom(cachedSectionCrochets[noteSec] / 4, curZoom);
						var targetY:Float = calcNoteY(note.strumTime, noteSec, curZoom);
						targetY += (GRID_SIZE/2 - note.height/2);
						note.chartY = targetY;
						// Skip per-note FlxTween for large note counts
						note.y = targetY;
					}

					noteSec = 0;
					for (event in events)
					{
						while(noteSec < cachedSectionTimes.length - 1 && cachedSectionTimes[noteSec + 1] <= event.strumTime) noteSec++;
						var targetY:Float = calcNoteY(event.strumTime, noteSec, curZoom);
						targetY += (GRID_SIZE/2 - event.height/2);
						event.y = targetY;
					}
					loadSection();
					showOutput('${Language.get('newchartEditor_error_zoom','Zoom')}: ${Math.round(curZoom * 100)}%');
					updateScrollY();
				}
			}
		}

		if(selectionBox.visible)
		{
			if(FlxG.mouse.releasedRight)
			{
				var sel = selectedNotes.copy();
				updateSelectionBox();
				if(#if (android || desktop) (virtualPad == null || !virtualPad.buttonY.pressed) || #end !FlxG.keys.pressed.SHIFT && !holdingAlt)
					resetSelectedNotes();

				var selectionBounds = selectionBox.getScreenBounds(null, camUI);
				for (note in curRenderedNotes)
				{
					if(note == null) continue;

					if(!selectedNotes.contains(note) || holdingAlt /*&& FlxG.overlap(selectionBox, note)*/) //overlap doesnt work here
					{
						var noteBounds = note.getScreenBounds(null, camUI);
						noteBounds.top -= scrollY;
						noteBounds.bottom -= scrollY;

						if(selectionBounds.overlaps(noteBounds))
						{
							if(holdingAlt && selectedNotes.contains(note))
							{
								selectedNotes.remove(note);
								note.colorTransform.redMultiplier = note.colorTransform.greenMultiplier = note.colorTransform.blueMultiplier = 1;
								if(note.animation.curAnim != null) note.animation.curAnim.curFrame = 0;
							}
							else selectedNotes.push(note);
							onSelectNote();
						}
					}
				}
				selectionBox.visible = false;
				addUndoAction(SELECT_NOTE, {old: sel, current: selectedNotes.copy()});
			}
			else if(FlxG.mouse.justMoved)
				updateSelectionBox();
		}
		else if(FlxG.mouse.pressedRight && (FlxG.mouse.deltaScreenX != 0 || FlxG.mouse.deltaScreenY != 0))
		{
			selectionBox.setPosition(FlxG.mouse.screenX, FlxG.mouse.screenY);
			selectionStart.set(FlxG.mouse.screenX, FlxG.mouse.screenY);
			selectionBox.visible = true;
			updateSelectionBox();
		}
		
		if(FlxG.mouse.justPressed && (FlxG.mouse.overlaps(mainBox.bg) || FlxG.mouse.overlaps(infoBox.bg)
			#if (android || desktop)
			|| (virtualPad != null && virtualPad.isMouseOverAnyButton())
			#end
		))
			ignoreClickForThisFrame = true;

		var minX:Float = gridBg.x;
		if(SHOW_EVENT_COLUMN && lockedEvents) minX += EVENT_COLUMN_WIDTH;

		if(isMovingNotes && FlxG.mouse.justReleased)
			stopMovingNotes();

		// 多k: 点击范围按当前小节最大宽度计算 (事件后 9K 段比 4K 段宽)
		if(FlxG.mouse.x >= minX && FlxG.mouse.x < gridBg.x + sectionWidthPx(curSec))
		{
			var diffX:Float = FlxG.mouse.x - gridBg.x;
			var diffY:Float = FlxG.mouse.y - gridBg.y;
			if(#if (android || desktop) (virtualPad == null || !virtualPad.buttonY.pressed) || #end !FlxG.keys.pressed.SHIFT)
				diffY -= diffY % (GRID_SIZE / (curQuant/16));

			// 多k: 高度边界按各小节总高度 (含事件切分段) 计算
			if(nextGridBg.visible) diffY = Math.min(diffY, sectionHeightPx(curSec) + sectionHeightPx(curSec + 1));
			else diffY = Math.min(diffY, sectionHeightPx(curSec));

			if(prevGridBg.visible) diffY = Math.max(diffY, -sectionHeightPx(curSec - 1));
			else diffY = Math.max(diffY, 0);

			var noteData:Int;
			var eventColW:Int = SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0;
			if (SHOW_EVENT_COLUMN && diffX < EVENT_COLUMN_WIDTH)
				noteData = -1; // 事件列
			else
				noteData = Math.floor((diffX - eventColW) / GRID_SIZE);
			// 多k: 幽灵箭头/放 Note 的列范围按鼠标位置所属 k 段限制:
			// 4K 段只允许 0~7 列, 9K 段才允许 0~17 列, 避免 4K 段点到 9K 列
			if (noteData >= 0 && diffY >= 0 && diffY < sectionHeightPx(curSec))
			{
				var partTime:Float = (diffY / GRID_SIZE * (cachedSectionCrochets[curSec] / 4) / curZoom) + cachedSectionTimes[curSec];
				var partMania:Int = EKData.effectiveManiaAtTime((PlayState.SONG != null) ? PlayState.SONG.events : null, chartBaseMania(), partTime);
				var partAmmo:Int = Note.ammo[EKData.clampMania(partMania)];
				if (noteData >= partAmmo * GRID_PLAYERS) noteData = partAmmo * GRID_PLAYERS - 1;
			}
			dummyArrow.visible = !selectionBox.visible;
			if (noteData < 0)
				dummyArrow.x = gridBg.x + (EVENT_COLUMN_WIDTH - dummyArrow.width) / 2;
			else
				dummyArrow.x = gridBg.x + eventColW + noteData * GRID_SIZE + (GRID_SIZE - dummyArrow.width) / 2;

			if(#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.SHIFT || FlxG.mouse.y >= gridBg.y || !prevGridBg.visible)
				dummyArrow.y = gridBg.y + diffY;
			else
			{
				var t:Float = (diffY - (GRID_SIZE / (curQuant/16)));
				if(FlxG.mouse.y >= gridBg.y) t *= curZoom;
				dummyArrow.y = gridBg.y + t;
			}

			if(isMovingNotes)
			{
				// Move note data
				var nData:Int = Std.int(Math.max(0, noteData));
				if(movingNotesLastData != nData)
				{
					var isFirst:Bool = true;
					var movingNotesMinData:Int = 0;
					var movingNotesMaxData:Int = 0;
					for (note in selectedNotes) //Find boundaries first
					{
						if(note == null || note.isEvent) continue;
	
						var data:Int = note.songData[1];
						if(isFirst || data < movingNotesMinData) movingNotesMinData = data;
						if(data > movingNotesMaxData) movingNotesMaxData = data;
						isFirst = false;
					}

					var diff:Int = nData - movingNotesLastData;
					var maxn:Int = (GRID_PLAYERS * GRID_COLUMNS_PER_PLAYER) - 1;
					movingNotesMinData += diff;
					movingNotesMaxData += diff;
					if(movingNotesMinData < 0)
						diff -= movingNotesMinData;
					else if(movingNotesMaxData > maxn)
						diff -= movingNotesMaxData - maxn;

					for (note in movingNotes)
					{
						if(note == null || note.isEvent) continue; //Events shouldn't change note data as they don't have one

						note.changeNoteData(note.songData[1] + diff);
						positionNoteXByData(note);
					}
				}
				movingNotesLastData = nData;

				// Move note strum time
				if(dummyArrow.y != movingNotesLastY)
				{
					var diff:Float = dummyArrow.y - movingNotesLastY;
					var curSecRow:Int = 0;
					for (note in movingNotes) //Try to figure out new strum time for the notes, DEFINITELY INACCURATE WITH BPM CHANGING, ALTHOUGH UNTESTED
					{
						if(note == null) continue;

						note.chartY += diff;
						var row:Float = (note.chartY / GRID_SIZE) * curZoom;
						while(curSecRow + 1 < cachedSectionRow.length && cachedSectionRow[curSecRow] <= row)
						{
							curSecRow++;
						}

						note.setStrumTime(Math.max(-5000, note.strumTime + (diff * cachedSectionCrochets[curSecRow] / 4) / GRID_SIZE * curZoom));
						positionNoteYOnTime(note, curSecRow);
						if(note.isEvent) cast (note, EventMetaNote).updateEventText();
					}
					movingNotesLastY = dummyArrow.y;
				}
			}
			else if(FlxG.mouse.justPressed && !ignoreClickForThisFrame)
			{
				// 多k: 点击范围按当前小节最大宽度计算 (事件后 9K 段比 4K 段宽)
				if(FlxG.mouse.x >= gridBg.x && FlxG.mouse.x < gridBg.x + sectionWidthPx(curSec))
				{
					var closest:MetaNote = null;
					if(FlxG.mouse.overlaps(curRenderedNotes))
					{
						for (note in curRenderedNotes)
						{
							if(note != null && FlxG.mouse.overlaps(note))
							{
								var isMatch:Bool = (note.isEvent && noteData < 0) || (!note.isEvent && note.songData[1] == noteData);
								if(isMatch && (!note.isEvent || !lockedEvents))
								{
									closest = note;
									break;
								}
							}
						}
					}
					if(closest != null)
					{
						if(FlxG.keys.pressed.CONTROL) // Ctrl+Click = Select Note (like ChartingState)
						{
							var sel = selectedNotes.copy();
							resetSelectedNotes();
							selectedNotes.push(closest);
							addUndoAction(SELECT_NOTE, {old: sel, current: selectedNotes.copy()});
							TraceManager.debug('trace.editor.noteSelected', 'Notes selected: {}', [selectedNotes.length]);
						}
						else if(FlxG.keys.pressed.SHIFT || holdingAlt) // Shift/Alt+Click = Select/Unselect Note
						{
							var sel = selectedNotes.copy();
							if(!selectedNotes.contains(closest))
							{
								selectedNotes.push(closest);
								addUndoAction(SELECT_NOTE, {old: sel, current: selectedNotes.copy()});
							}
							else if(!holdingAlt)
							{
								resetSelectedNotes();
								selectedNotes.remove(closest);
								addUndoAction(SELECT_NOTE, {old: sel, current: selectedNotes.copy()});
							}
							TraceManager.debug('trace.editor.noteSelected', 'Notes selected: {}', [selectedNotes.length]);
						}
						else // Click = Delete immediately (like ChartingState)
						{
							#if android
							// On Android: start long-press timer instead of deleting immediately.
							// Hold finger on note > 0.4s to select it; release early to delete.
							_longPressNote = closest;
							_longPressTimer = 0;
							#else
							doDeleteNote(closest);
							#end
						}
						if(selectedNotes.length == 1) onSelectNote();
						forceDataUpdate = true;
					}
					else if(FlxG.keys.pressed.CONTROL) // Ctrl+Click on empty space = Move selected notes
					{
						if(selectedNotes.length > 0)
							moveSelectedNotes(noteData, dummyArrow.y);
						else
							showOutput('newchartEditor_error_note_must_select', true);
					}
					// 多k: 放置范围按当前小节总高度 (含事件切分段)
					else if(!holdingAlt && FlxG.mouse.y >= gridBg.y && FlxG.mouse.y < gridBg.y + sectionHeightPx(curSec)) // Add note
					{
						var strumTime:Float = (diffY / GRID_SIZE * (cachedSectionCrochets[curSec] / 4) / curZoom) + cachedSectionTimes[curSec];
						if(noteData >= 0)
						{
							TraceManager.debug('trace.editor.noteAdded', 'Added note at time: {}', [strumTime]);
							var didAdd:Bool = false;

							var noteSetupData:Array<Dynamic> = [strumTime, noteData, 0];
							var typeSelected:String = noteTypes[noteTypeDropDown.selectedIndex].trim();
							if(typeSelected != null && typeSelected.length > 0)
								noteSetupData.push(typeSelected);

							var noteAdded:MetaNote = createNote(noteSetupData);
							for (num in sectionFirstNoteID...notes.length)
							{
								var note = notes[num];
								if(note.strumTime >= strumTime)
								{
									notes.insert(num, noteAdded);
									didAdd = true;
									break;
								}
							}
							if(!didAdd) notes.push(noteAdded);

							if(!holdingAlt)
								resetSelectedNotes();

							selectedNotes.push(noteAdded);
							addUndoAction(ADD_NOTE, {notes: [noteAdded]});
						}
						else if(!lockedEvents)
						{
							TraceManager.debug('trace.editor.eventAdded', 'Added event at time: {}', [strumTime]);
							var didAdd:Bool = false;

							// 多k: 新增 Change Mania 事件 -> 记录快照, 插入后按工具箱模式重编码
							var addEventName:String = eventsList[Std.int(Math.max(eventDropDown.selectedIndex, 0))][0];
							var oldEvents:Array<Dynamic> = (addEventName == 'Change Mania') ? deepCopyEditorEvents() : null;
							var eventAdded:EventMetaNote = createEvent([strumTime, [[eventsList[Std.int(Math.max(eventDropDown.selectedIndex, 0))][0], value1InputText.text, value2InputText.text]]]);
							for (num in sectionFirstEventID...events.length)
							{
								var event = events[num];
								if(event.strumTime >= strumTime)
								{
									events.insert(num, eventAdded);
									didAdd = true;
									break;
								}
							}
							if(!didAdd) events.push(eventAdded);

							if(!holdingAlt)
								resetSelectedNotes();

							selectedNotes.push(eventAdded);
							addUndoAction(ADD_NOTE, {events: [eventAdded]});
							if(oldEvents != null) refreshAfterManiaEventEdit(oldEvents);
						}
						onSelectNote();
						softReloadNotes();
					}
				}
			}
		}
		else if(!ignoreClickForThisFrame)
		{
			if(FlxG.mouse.justPressed)
				resetSelectedNotes();

			dummyArrow.visible = false;
		}
		ignoreClickForThisFrame = false;

		#if android
		// Android long-press: hold finger on a note > 0.4s → select it (like Ctrl+Click)
		if (_longPressNote != null)
		{
			if (FlxG.mouse.justReleased)
			{
				// Released early → delete the note
				if (_longPressNote.exists)
					doDeleteNote(_longPressNote);
				_longPressNote = null;
			}
			else if (FlxG.mouse.pressed && FlxG.mouse.overlaps(_longPressNote))
			{
				_longPressTimer += elapsed;
				if (_longPressTimer >= _longPressThreshold)
				{
					// Long-press threshold reached → select the note (Ctrl+Click behavior)
					if (_longPressNote.exists)
					{
						var sel = selectedNotes.copy();
						resetSelectedNotes();
						selectedNotes.push(_longPressNote);
						addUndoAction(SELECT_NOTE, {old: sel, current: selectedNotes.copy()});
						onSelectNote();
						forceDataUpdate = true;
						TraceManager.debug('trace.editor.noteSelected', 'Android long-press selected note');
					}
					_longPressNote = null;
				}
			}
			else
			{
				// Finger moved off the note → cancel
				_longPressNote = null;
			}
		}
		#end

		if(Conductor.songPosition != lastTime || forceDataUpdate)
		{
			var curTime:String = FlxStringUtil.formatTime(Conductor.songPosition / 1000, true);
			var songLength:String = (FlxG.sound.music != null) ? FlxStringUtil.formatTime(FlxG.sound.music.length / 1000, true) : '???';
			var str:String =  '$curTime / $songLength' +
							  '\n\n${Language.get('newchartEditor_section',"Section")}: $curSec' +
							  '\n${Language.get('newchartEditor_beat',"Beat")}: $curBeat' +
							  '\n${Language.get('newchartEditor_step',"Step")}: $curStep' +
							  '\n\n${Language.get('newchartEditor_beat_snap',"Beat Snap")}: ${curQuant} / 16' +
							  '\n${Language.get('newchartEditor_selected',"Selected")}: ${selectedNotes.length}';
			if(str != infoText.text)
			{
				infoText.text = str;
				if(infoText.autoSize) infoText.autoSize = false;
			}

			var playing:Bool = (FlxG.sound.music != null && FlxG.sound.music.playing);
			var songPos:Float = Conductor.songPosition;

			// Mark dirty when position changes (triggers note alpha refresh)
			if(Conductor.songPosition != lastTime) _noteAlphaDirty = true;

			if(_noteAlphaDirty)
			{
				for (note in curRenderedNotes)
				{
					if(note == null || note.isEvent) continue;
					note.alpha = (note.strumTime >= songPos) ? 1 : 0.6;
				}
				_noteAlphaDirty = false;
			}

			// Only check hitsound / vortex animation while playing
			if(playing && lastTime < songPos)
			{
				var hitSoundPlayer:Bool = (hitsoundPlayerStepper.value > 0);
				var hitSoundOpp:Bool = (hitsoundOpponentStepper.value > 0);
				var vortexPlaying:Bool = (vortexEnabled && playing);
				for (note in curRenderedNotes)
				{
					if(note == null || note.isEvent) continue;
					if(songPos > note.strumTime && lastTime <= note.strumTime)
					{
						if(hitSoundPlayer && note.mustPress)
						{
							FlxG.sound.play(Paths.sound('hitsound'), hitsoundPlayerStepper.value);
							hitSoundPlayer = false;
						}
						else if(hitSoundOpp && !note.mustPress)
						{
							FlxG.sound.play(Paths.sound('hitsound'), hitsoundOpponentStepper.value);
							hitSoundOpp = false;
						}

						if(vortexPlaying)
						{
							var strumNote:StrumNote = strumLineNotes.members[note.songData[1]];
							if(strumNote != null)
							{
								strumNote.playAnim('confirm', true);
								strumNote.resetAnim = Math.max(Conductor.stepCrochet * 1.25, note.sustainLength) / 1000 / playbackRate;
							}
						}
					}
				}
			}
			// 多k: 播放中网格按播放位置动态预览 Change Mania 事件 (前进/回退均会更新)
			if (playing) checkManiaEvents(lastTime, songPos);
			forceDataUpdate = false;
			
			// moved from beatHit()
			if(metronomeStepper.value > 0 && lastBeatHit != curBeat)
				FlxG.sound.play(Paths.sound('Metronome_Tick'), metronomeStepper.value);

			lastBeatHit = curBeat;
		}

		if(selectedNotes.length > 0)
		{
			noteSelectionSine += elapsed;
			var sineValue:Float = 0.75 + Math.cos(Math.PI * noteSelectionSine * (isMovingNotes ? 8 : 2)) / 4;
			//trace(sineValue);

			var qPress = #if (android || desktop) (virtualPad != null && virtualPad.buttonUp2.justPressed)  || #end FlxG.keys.justPressed.Q;
			var ePress = #if (android || desktop) (virtualPad != null && virtualPad.buttonDown2.justPressed)  || #end FlxG.keys.justPressed.E;
			var addSus = (FlxG.keys.pressed.SHIFT ? 4 : 1) * (Conductor.stepCrochet / 2);
			if(qPress) addSus *= -1;

			if(qPress != ePress && selectedNotes.length != 1)
				susLengthStepper.value += addSus;

			var noteSec:Int = 0;
			for (note in selectedNotes)
			{
				if(note == null || !note.exists) continue;

				if(!note.isEvent)
				{
					if(qPress != ePress)
					{
						while(cachedSectionTimes.length > noteSec + 1 && cachedSectionTimes[noteSec + 1] <= note.strumTime)
							noteSec++;

						note.setSustainLength(note.sustainLength + addSus, cachedSectionCrochets[noteSec] / 4, curZoom);
						if(selectedNotes.length == 1)
							susLengthStepper.value = note.sustainLength;
					}
					note.animation.update(elapsed); //let selected notes be animated for better visibility
				}
				note.colorTransform.redMultiplier = note.colorTransform.greenMultiplier = note.colorTransform.blueMultiplier = sineValue;
			}
		}
		else noteSelectionSine = 0;

		outputTxt.alpha = outputAlpha;
		outputTxt.visible = (outputAlpha > 0);

		// Update modified indicator
		if(modIndicatorTxt != null)
		{
			if(unsavedChanges)
			{
				modIndicatorTxt.text = '● ' + Language.get('newchartEditor_modified', 'Modified');
				modIndicatorTxt.color = FlxColor.YELLOW;
			}
			else
			{
				modIndicatorTxt.text = '● ' + Language.get('newchartEditor_saved', 'Saved');
				modIndicatorTxt.color = FlxColor.LIME;
			}
		}

		FlxG.camera.scroll.y = scrollY;
		camUI.scroll.y = 0;
		lastFocus = PsychUIInputText.focusOn;
	}

	function moveSelectedNotes(noteData:Int = 0, lastY:Float) //This turns selected notes into moving notes
	{
		var originalNotes:Array<MetaNote> = [];
		var originalEvents:Array<EventMetaNote> = [];
		var movedNotes:Array<MetaNote> = [];
		var movedEvents:Array<EventMetaNote> = [];
		// 多k: 拖动 Change Mania 事件前记录事件快照, 放下后按工具箱模式重编码
		_moveHadChangeMania = false;
		for (sel in selectedNotes)
			if (sel != null && sel.isEvent && eventHasChangeMania(cast (sel, EventMetaNote))) { _moveHadChangeMania = true; break; }
		_moveOldEvents = _moveHadChangeMania ? deepCopyEditorEvents() : null;
		for (note in selectedNotes)
		{
			if(note == null) continue;

			if(!note.isEvent)
			{
				notes.remove(note);
				var secNum:Int = 0;
				for (time in cachedSectionTimes)
				{
					if(time > note.strumTime) break;
					secNum++;
				}
				originalNotes.push(note);
				var mov:MetaNote = createNote(note.songData, secNum);
				movingNotes.add(mov);
				movedNotes.push(mov);
			}
			else
			{
				events.remove(cast (note, EventMetaNote));
				originalEvents.push(cast (note, EventMetaNote));
				var mov:EventMetaNote = createEvent(note.songData);
				movingNotes.add(mov);
				movedEvents.push(mov);
			}
		}
		selectedNotes = movingNotes.members.copy();
		isMovingNotes = true;
		movingNotesLastY = lastY;
		movingNotesLastData = noteData;
		movingNotes.sort(cast PlayState.sortByTime);
		addUndoAction(MOVE_NOTE, {originalNotes: originalNotes, originalEvents: originalEvents, movedNotes: movedNotes, movedEvents: movedEvents});
		softReloadNotes();
	}

	function stopMovingNotes() //This turns moving notes into saved notes
	{
		var pushedNotes:Array<MetaNote> = [];
		var pushedEvents:Array<EventMetaNote> = [];
		movingNotes.forEachAlive(function(note:MetaNote)
		{
			if(!note.isEvent)
			{
				notes.push(note);
				pushedNotes.push(note);
			}
			else
			{
				events.push(cast (note, EventMetaNote));
				pushedEvents.push(cast (note, EventMetaNote));
			}
		});
		notes.sort(PlayState.sortByTime);
		events.sort(PlayState.sortByTime);
		movingNotes.clear();
		isMovingNotes = false;
		markUnsaved();
		softReloadNotes();
		if(_moveHadChangeMania && _moveOldEvents != null)
		{
			_moveHadChangeMania = false;
			refreshAfterManiaEventEdit(_moveOldEvents);
			_moveOldEvents = null;
		}
	}

	function makeNoteDataCopy(originalData:Array<Dynamic>, isEvent:Bool)
	{
		var dataCopy:Array<Dynamic> = originalData.copy();
		if(isEvent)
		{
			var eventGrp:Array<Array<Dynamic>> = cast dataCopy[1].copy();
			for (num => subEvent in eventGrp)
				eventGrp[num] = subEvent.copy();

			dataCopy[1] = eventGrp;
		}
		return dataCopy;
	}

	function updateScrollY()
	{
		var secStartTime:Null<Float> = cast cachedSectionTimes[curSec];
		var secCrochet:Null<Float> = cast cachedSectionCrochets[curSec];
		var secRows:Null<Float> = cast cachedSectionRow[curSec];
		if(secStartTime == null || secCrochet == null || secRows == null) return;

		scrollY = (((Conductor.songPosition - secStartTime) / secCrochet * GRID_SIZE * 4) + (secRows * GRID_SIZE)) * curZoom - FlxG.height/2;
	}

	function updateSelectionBox()
	{
		var diffX:Float = FlxG.mouse.screenX - selectionStart.x;
		var diffY:Float = FlxG.mouse.screenY - selectionStart.y;
		selectionBox.setPosition(selectionStart.x, selectionStart.y);

		if(diffX < 0) //Fixes negative X scale
		{
			diffX = Math.abs(diffX);
			selectionBox.x -= diffX;
		}
		if(diffY < 0) //Fixes negative Y scale
		{
			diffY = Math.abs(diffY);
			selectionBox.y -= diffY;
		}
		selectionBox.scale.set(diffX, diffY);
		selectionBox.updateHitbox();
	}

	/** Mark the chart as having unsaved changes. */
	function markUnsaved():Void
	{
		unsavedChanges = true;
	}

	/** Clear the unsaved changes flag (called after save / load / discard). */
	function clearUnsaved():Void
	{
		unsavedChanges = false;
	}

	function showOutput(message:String, isError:Bool = false, ?params:Array<Dynamic> = null)
	{
		if (Language.has(message))
			message = Language.get(message);
		if (params != null) {
			var paramIndex:Int = 0;
			while (message.indexOf('%s') != -1 && paramIndex < params.length) {
				message = StringTools.replace(message, '%s', Std.string(params[paramIndex]));
				paramIndex++;
			}
		}

		trace(message);
		outputTxt.text = message;
		outputTxt.y = FlxG.height - outputTxt.height - 30;
		outputTxt.font = 'assets/fonts/editors.ttf';
		outputAlpha = 4;


		if(isError)
		{
			FlxG.sound.play(Paths.sound('cancelMenu'), 0.6);
			outputTxt.color = FlxColor.RED;
		}
		else
		{
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
			outputTxt.color = FlxColor.WHITE;
		}
	}

	/** Show an exit-confirmation prompt if there are unsaved changes. */
	function confirmExit(?onConfirm:Void->Void):Void
	{
		if(unsavedChanges)
		{
			openSubState(new editors.content.Prompt(
				Language.get('newchartEditor_unsaved_exit', 'There\'s unsaved progress,\nare you sure you want to exit?'),
				function()
				{
					clearUnsaved();
					if(onConfirm != null) onConfirm();
					else
					{
						PlayState.chartingMode = false;
						MusicBeatState.switchState(new editors.MasterEditorMenu());
						FlxG.sound.playMusic(Paths.music('freakyMenu'));
						FlxG.mouse.visible = false;
					}
				}
			));
		}
		else
		{
			if(onConfirm != null) onConfirm();
			else
			{
				PlayState.chartingMode = false;
				MusicBeatState.switchState(new editors.MasterEditorMenu());
				FlxG.sound.playMusic(Paths.music('freakyMenu'));
				FlxG.mouse.visible = false;
			}
		}
	}

	/** Show a confirmation prompt before playtesting if there are unsaved changes. */
	function confirmPlaytest():Void
	{
		if(unsavedChanges)
		{
			openSubState(new editors.content.Prompt(
				Language.get('newchartEditor_unsaved_playtest', 'You have unsaved changes.\nPlaytest anyway? (Changes won\'t be lost)'),
				function()
				{
					createPlaytestBackup();
					doGoToPlayState();
				},
				'newchartEditor_play', // Yes - "Play"
				'newchartEditor_cancel' // No - "Cancel"
			));
		}
		else
		{
			doGoToPlayState();
		}
	}

	/** Create a timestamped backup before playtesting, to prevent data loss. */
	function createPlaytestBackup():Void
	{
		// Only create backups when the player opted in to auto-save.
		if(!ClientPrefs.data.chartAutosave) return;
		#if sys
		try
		{
			var backupDir:String = 'backups/';
			if(!FileSystem.exists(backupDir)) FileSystem.createDirectory(backupDir);

			var chartName:String = Paths.formatToSongPath(PlayState.SONG.song);
			var timestamp:String = DateTools.format(Date.now(), '%Y-%m-%d_%H-%M-%S');
			var backupName:String = '${chartName}_playtest_$timestamp.$BACKUP_EXT';

			var songCopy:SwagSong = Reflect.copy(PlayState.SONG);
			Reflect.setField(songCopy, '__original_path', Song.chartPath);
			var dataToSave:String = haxe.Json.stringify(songCopy);
			File.saveContent('$backupDir$backupName', dataToSave);
			trace('Playtest backup saved: $backupName');
		}
		catch(e:Dynamic)
		{
			trace('Failed to create playtest backup: $e');
		}
		#end
	}

	/** Actually switch to PlayState (after save confirmation). */
	function doGoToPlayState():Void
	{
		persistentUpdate = false;
		FlxG.mouse.visible = false;
		chartEditorSave.flush();
		autosaveSong();
		updateChartData();
		StageData.loadDirectory(PlayState.SONG);
		PlayState.chartingMode = true;
		PlayState.replayMode = false;
		LoadingState.loadAndSwitchState(new PlayState());
		ClientPrefs.toggleVolumeKeys(true);
	}

	/** Delete a note/event immediately. Extracted as helper for Android long-press logic. */
	function doDeleteNote(note:MetaNote):Void
	{
		TraceManager.debug('trace.editor.noteRemoved', 'Removed {} at time: {}', [!note.isEvent ? 'note' : 'event', note.strumTime]);
		// 多k: 删除 Change Mania 事件 -> 记录快照, 删除后按工具箱模式重编码
		var oldEvents:Array<Dynamic> = (note.isEvent && eventHasChangeMania(cast (note, EventMetaNote)))
			? deepCopyEditorEvents() : null;
		if(!note.isEvent)
			notes.remove(note);
		else
			events.remove(cast (note, EventMetaNote));

		selectedNotes.remove(note);
		curRenderedNotes.remove(note, true);
		addUndoAction(DELETE_NOTE, !note.isEvent ? {notes: [note]} : {events: [note]});
		if(oldEvents != null) refreshAfterManiaEventEdit(oldEvents);
	}

	function resetSelectedNotes()
	{
		for (note in selectedNotes)
		{
			if(note == null || !note.exists) continue;

			note.colorTransform.redMultiplier = note.colorTransform.greenMultiplier = note.colorTransform.blueMultiplier = 1;
			if(note.animation.curAnim != null) note.animation.curAnim.curFrame = 0;
		}
		selectedNotes = [];
		onSelectNote();
		forceDataUpdate = true;
	}

	function onSelectNote()
	{
		if(selectedNotes.length == 1) //Only one note selected
		{
			var note:MetaNote = selectedNotes[0];
			strumTimeStepper.value = note.strumTime;
			if(!note.isEvent) //Normal note
			{
				if(!note.isEvent)
				{
					susLengthLastVal = susLengthStepper.value = note.sustainLength;
					noteTypeDropDown.selectedIndex = Std.int(Math.max(0, noteTypes.indexOf(note.noteType)));
				}
				else
				{
					susLengthLastVal = susLengthStepper.value = 0;
					noteTypeDropDown.selectedLabel = '';
				}
			}
			else //Event note
			{
				var eventNote:EventMetaNote = cast (selectedNotes[0], EventMetaNote);
				updateSelectedEventText();
			}
		}
		else if(selectedNotes.length > 1)
		{
			susLengthStepper.min = -susLengthStepper.max;
			susLengthLastVal = susLengthStepper.value = 0;
			strumTimeStepper.value = selectedNotes[0].strumTime;
			noteTypeDropDown.selectedLabel = '';
			eventDropDown.selectedLabel = '';
			value1InputText.text = '';
			value2InputText.text = '';
		}
		forceDataUpdate = true;
	}

	function updateSelectedEventText()
	{
		// 事件标签页 UI 尚未创建（如 createGrids/loadSection 早期）时直接跳过，
		// 避免 value1InputText 等为空导致 Null Object Reference 崩溃。
		if (value1InputText == null || value2InputText == null || selectedEventText == null || eventDropDown == null)
			return;

		if(selectedNotes.length == 1 && selectedNotes[0].isEvent)
		{
			var eventNote:EventMetaNote = cast (selectedNotes[0], EventMetaNote);
			curEventSelected = Std.int(FlxMath.bound(curEventSelected, 0, eventNote.events.length - 1));
			selectedEventText.text = '${Language.get('newchartEditor_selected_event', 'Selected Event:')}: ${curEventSelected + 1} / ${eventNote.events.length}';
			selectedEventText.visible = true;
			
			var myEvent:Array<String> = eventNote.events[curEventSelected];
			if(myEvent != null)
			{
				var eventName:String = (myEvent[0] != null) ? myEvent[0] : '';
				for (num => event in eventsList)
				{
					if(event[0] == eventName)
					{
						eventDropDown.selectedIndex = num;
						break;
					}
				}
				value1InputText.text = (myEvent[1] != null) ? myEvent[1] : '';
				value2InputText.text = (myEvent[2] != null) ? myEvent[2] : '';
			}
		}
		else selectedEventText.visible = false;
	}

	function createGrids(?doLoadSection:Bool = true)
	{
		var destroyed:Bool = false;
		if(prevGridBg != null)
		{
			remove(prevGridBg);
			remove(gridBg);
			remove(nextGridBg);
			prevGridBg = FlxDestroyUtil.destroy(prevGridBg);
			gridBg = FlxDestroyUtil.destroy(gridBg);
			nextGridBg = FlxDestroyUtil.destroy(nextGridBg);
			destroyed = true;
		}

		// 多k: 网格列数按各小节生效键数 (Change Mania 事件分段):
		// 事件前的小节显示 4K 网格, 事件后的小节显示 9K 网格, 无需播放经过事件才更新。
		// SONG 尚未加载 (create 早期) 时全部回退到当前 k, 避免空引用
		var songReady:Bool = (PlayState.SONG != null && PlayState.SONG.notes != null);
		var fallbackK:Int = EKData.clampMania(PlayState.mania);
		var curSegs:Array<{startStep:Int, k:Int}> = songReady ? sectionSegments(curSec) : [{startStep: 0, k: fallbackK}];
		var prevSegs:Array<{startStep:Int, k:Int}> = (songReady && curSec > 0) ? sectionSegments(curSec - 1) : [{startStep: 0, k: fallbackK}];
		var nextSegs:Array<{startStep:Int, k:Int}> = (songReady && curSec < PlayState.SONG.notes.length - 1) ? sectionSegments(curSec + 1) : [{startStep: 0, k: fallbackK}];
		var prevColumnCount:Int = (Note.ammo[prevSegs[0].k] * GRID_PLAYERS) + (SHOW_EVENT_COLUMN ? 1 : 0);
		var curColumnCount:Int = (Note.ammo[curSegs[0].k] * GRID_PLAYERS) + (SHOW_EVENT_COLUMN ? 1 : 0);
		var nextColumnCount:Int = (Note.ammo[nextSegs[0].k] * GRID_PLAYERS) + (SHOW_EVENT_COLUMN ? 1 : 0);

		gridBg = new ChartingGridSprite(curColumnCount, gridColors[0], gridColors[1], NewChartingState.GRID_SIZE, SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0);
		gridBg.screenCenter(X);

		prevGridBg = new ChartingGridSprite(prevColumnCount, gridColorsOther[0], gridColorsOther[1], NewChartingState.GRID_SIZE, SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0);
		nextGridBg = new ChartingGridSprite(nextColumnCount, gridColorsOther[0], gridColorsOther[1], NewChartingState.GRID_SIZE, SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0);
		prevGridBg.x = nextGridBg.x = gridBg.x;

		if(destroyed)
		{
			insert(getFirstNull(), prevGridBg);
			insert(getFirstNull(), nextGridBg);
			insert(getFirstNull(), gridBg);
			if (doLoadSection) loadSection();
		}
		else
		{
			add(prevGridBg);
			add(nextGridBg);
			add(gridBg);
		}
		_lastGridMania = PlayState.mania;
		// 多k: 分段网格在下次 loadSection 时按当前 curSec 窗口重建
		_segmentsBuildSec = -999;
	}

	/** 多k: 当前谱面基准键数 (0 基)。 */
	function chartBaseMania():Int
	{
		if (PlayState.SONG == null) return Note.defaultMania;
		return (PlayState.SONG.mania != null) ? EKData.clampMania(PlayState.SONG.mania) : Note.defaultMania;
	}

	/** 多k: 计算某小节起始时刻 (ms), 与 _cacheSections 同一公式。 */
	function sectionStartTimeMs(sec:Int):Float
	{
		if (PlayState.SONG == null || PlayState.SONG.notes == null || sec < 0) return 0;
		var time:Float = 0;
		var bpm:Float = (PlayState.SONG.bpm > 0) ? PlayState.SONG.bpm : 100;
		var end:Int = Std.int(Math.min(sec, PlayState.SONG.notes.length));
		for (i in 0...end)
		{
			var section = PlayState.SONG.notes[i];
			if (section == null) continue;
			if (section.changeBPM && section.bpm > 0) bpm = section.bpm;
			var secs:Null<Float> = cast section.sectionBeats;
			var beats:Float = (secs != null && secs > 0) ? secs : 4;
			time += Conductor.calculateCrochet(bpm) * beats;
		}
		return time;
	}

	/** 多k: 某小节每 Step 的毫秒数 (按该小节生效的 BPM, 与 _cacheSections 同一公式)。 */
	function sectionStepMs(sec:Int):Float
	{
		if (PlayState.SONG == null || PlayState.SONG.notes == null) return Conductor.stepCrochet;
		var bpm:Float = (PlayState.SONG.bpm > 0) ? PlayState.SONG.bpm : 100;
		var end:Int = Std.int(Math.min(sec + 1, PlayState.SONG.notes.length));
		for (i in 0...end)
		{
			var section = PlayState.SONG.notes[i];
			if (section == null) continue;
			if (section.changeBPM && section.bpm > 0) bpm = section.bpm;
		}
		return Conductor.calculateCrochet(bpm) / 4;
	}

	/** 多k: 某小节的 Step 总数 (4 * 拍数)。 */
	function sectionSteps(sec:Int):Int
	{
		if (PlayState.SONG == null || PlayState.SONG.notes == null || sec < 0 || sec >= PlayState.SONG.notes.length) return 16;
		var secs:Null<Float> = cast PlayState.SONG.notes[sec].sectionBeats;
		var beats:Float = (secs != null && secs > 0) ? secs : 4;
		return Std.int(Math.max(1, Math.round(4 * beats)));
	}

	/**
	 * 多k: 某小节按 Change Mania 事件切分出的网格段 (Step 级)。
	 * 返回 [{startStep, k}, ...]: 事件所在 Step 之后换新键数网格列数,
	 * 事件之前的行保持旧键数, 与"上面 4K 网格 / 下面 9K 网格"一致。
	 */
	function sectionSegments(sec:Int):Array<{startStep:Int, k:Int}>
	{
		var segs:Array<{startStep:Int, k:Int}> = [];
		if (PlayState.SONG == null || PlayState.SONG.notes == null || sec < 0 || sec >= PlayState.SONG.notes.length)
		{
			segs.push({startStep: 0, k: EKData.clampMania(PlayState.mania)});
			return segs;
		}
		var events:Array<Dynamic> = PlayState.SONG.events;
		var base:Int = chartBaseMania();
		var secStart:Float = sectionStartTimeMs(sec);
		var secEnd:Float = sectionStartTimeMs(sec + 1);
		var steps:Int = sectionSteps(sec);
		var stepMs:Float = sectionStepMs(sec);
		segs.push({startStep: 0, k: EKData.effectiveManiaAtTime(events, base, secStart)});

		var bounds:Map<Int, Float> = [];
		if (events != null)
		{
			for (event in events)
			{
				if (event == null || event[0] == null || event[1] == null) continue;
				var evTime:Float = Std.parseFloat(Std.string(event[0]));
				if (Math.isNaN(evTime) || evTime <= secStart || evTime >= secEnd) continue;
				var subs:Array<Dynamic> = cast event[1];
				if (subs == null) continue;
				for (sub in subs)
				{
					if (sub == null || sub.length < 2) continue;
					if (Std.string(sub[0]) != 'Change Mania') continue;
					var s:Int = Std.int(Math.floor((evTime - secStart) / stepMs));
					if (s < 1) s = 1;
					if (s >= steps) s = steps - 1;
					// 同一步多个事件时取最晚事件时刻: 该步结束时真正生效的 k
					var prevT:Float = bounds.exists(s) ? bounds.get(s) : Math.NEGATIVE_INFINITY;
					if (evTime > prevT) bounds.set(s, evTime);
				}
			}
		}
		var boundSteps:Array<Int> = [for (s in bounds.keys()) s];
		boundSteps.sort((a, b) -> a - b);
		for (s in boundSteps)
			segs.push({startStep: s, k: EKData.effectiveManiaAtTime(events, base, bounds.get(s))});
		return segs;
	}

	/** 多k: 销毁并清空额外的网格分段。 */
	function destroyGridSegments():Void
	{
		for (seg in gridSegments)
		{
			if (seg == null) continue;
			remove(seg);
			seg = FlxDestroyUtil.destroy(seg);
		}
		gridSegments = [];
		gridSegmentMeta = [];
	}

	/** 多k: 为某个窗口构建小节内事件切分出的额外网格段。 */
	function buildExtraSegs(segs:Array<{startStep:Int, k:Int}>, window:Int, sec:Int, colors:Array<FlxColor>):Void
	{
		var steps:Int = sectionSteps(sec);
		for (i in 1...segs.length)
		{
			var colCount:Int = (Note.ammo[segs[i].k] * GRID_PLAYERS) + (SHOW_EVENT_COLUMN ? 1 : 0);
			var s:ChartingGridSprite = new ChartingGridSprite(colCount, colors[0], colors[1], NewChartingState.GRID_SIZE, SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0);
			s.x = gridBg.x;
			s.stripes = gridStripesForMania(segs[i].k);
			gridSegments.push(s);
			var endStep:Int = (i + 1 < segs.length) ? segs[i + 1].startStep : steps;
			gridSegmentMeta.push({window: window, sec: sec, startStep: segs[i].startStep, endStep: endStep, k: segs[i].k});
		}
	}

	/**
	 * 多k: 按当前 curSec 的三窗 (上/中/下小节) 重建全部网格 (主网格 + 事件分段) 并定位。
	 * 主网格的列数随窗口小节变化 (columns 只读, 必须重建), 否则切到 9K 小节时
	 * 网格仍是 4K 列数渲染不出来。
	 */
	function rebuildGridsForCurrentWindow():Void
	{
		destroyGridSegments();
		var songReady:Bool = (PlayState.SONG != null && PlayState.SONG.notes != null);
		var fallbackK:Int = EKData.clampMania(PlayState.mania);
		var curSegs:Array<{startStep:Int, k:Int}> = songReady ? sectionSegments(curSec) : [{startStep: 0, k: fallbackK}];
		var prevSegs:Array<{startStep:Int, k:Int}> = (songReady && curSec > 0) ? sectionSegments(curSec - 1) : [{startStep: 0, k: fallbackK}];
		var nextSegs:Array<{startStep:Int, k:Int}> = (songReady && curSec < PlayState.SONG.notes.length - 1) ? sectionSegments(curSec + 1) : [{startStep: 0, k: fallbackK}];

		// 主网格: 保持左起点不变, 按各窗口小节键数重建列数
		var anchorX:Float = (gridBg != null) ? gridBg.x : 0;
		gridBg = replaceGridSprite(gridBg, (Note.ammo[curSegs[0].k] * GRID_PLAYERS) + (SHOW_EVENT_COLUMN ? 1 : 0), gridColors[0], gridColors[1], anchorX);
		prevGridBg = replaceGridSprite(prevGridBg, (Note.ammo[prevSegs[0].k] * GRID_PLAYERS) + (SHOW_EVENT_COLUMN ? 1 : 0), gridColorsOther[0], gridColorsOther[1], anchorX);
		nextGridBg = replaceGridSprite(nextGridBg, (Note.ammo[nextSegs[0].k] * GRID_PLAYERS) + (SHOW_EVENT_COLUMN ? 1 : 0), gridColorsOther[0], gridColorsOther[1], anchorX);

		buildExtraSegs(curSegs, 1, curSec, gridColors);
		buildExtraSegs(prevSegs, 0, curSec - 1, gridColorsOther);
		buildExtraSegs(nextSegs, 2, curSec + 1, gridColorsOther);
		// 多k: 分段网格必须插在音符组之前 (否则盖住 Note/事件图标且无法点击);
		// 不能直接 add() 追加到末尾 (首次重建无空槽时会被追加到最顶层)
		var gridInsertIdx:Int = members.indexOf(nextGridBg);
		for (seg in gridSegments)
		{
			gridInsertIdx++;
			insert(gridInsertIdx, seg);
		}
		updateGridSegmentStripes();
		positionGridSegments();
		_segmentsBuildSec = curSec;
	}

	/** 多k: 用新列数的网格替换旧网格, 保持原 members 位置 (网格始终在音符组之前)。 */
	function replaceGridSprite(oldSprite:ChartingGridSprite, columns:Int, color1:FlxColor, color2:FlxColor, anchorX:Float):ChartingGridSprite
	{
		var idx:Int = (oldSprite != null) ? members.indexOf(oldSprite) : -1;
		if (oldSprite != null)
		{
			remove(oldSprite);
			oldSprite = FlxDestroyUtil.destroy(oldSprite);
		}
		var sp:ChartingGridSprite = new ChartingGridSprite(columns, color1, color2, NewChartingState.GRID_SIZE, SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0);
		sp.x = anchorX;
		if (idx >= 0) insert(idx, sp);
		else add(sp);
		return sp;
	}

	/** 多k: 刷新所有网格段 (主网格 + 分段) 的玩家/对手分隔线。 */
	function updateGridSegmentStripes():Void
	{
		if (gridBg != null) gridBg.stripes = gridStripesForMania(mainGridK(1));
		if (prevGridBg != null) prevGridBg.stripes = gridStripesForMania(mainGridK(0));
		if (nextGridBg != null) nextGridBg.stripes = gridStripesForMania(mainGridK(2));
		for (i => seg in gridSegments)
			if (seg != null && i < gridSegmentMeta.length)
				seg.stripes = gridStripesForMania(gridSegmentMeta[i].k);
	}

	/** 多k: 主网格 (每窗第一段) 的键数。window: 0=prev 1=cur 2=next。 */
	function mainGridK(window:Int):Int
	{
		var sec:Int = curSec + (window - 1);
		if (sec < 0 || PlayState.SONG == null || PlayState.SONG.notes == null || sec >= PlayState.SONG.notes.length)
			return EKData.clampMania(PlayState.mania);
		return sectionSegments(sec)[0].k;
	}

	/** 多k: 定位额外网格分段 (y/行数/可见性), 在 loadSection 与 updateGridVisibility 时调用。 */
	function positionGridSegments():Void
	{
		for (i => seg in gridSegments)
		{
			if (seg == null || i >= gridSegmentMeta.length) continue;
			var meta = gridSegmentMeta[i];
			var sec:Int = meta.sec;
			if (sec < 0 || sec >= cachedSectionRow.length) { seg.visible = false; continue; }
			var visible:Bool = false;
			switch(meta.window)
			{
				case 0: visible = (curSec > 0 && showPreviousSection);
				case 1: visible = true;
				case 2: visible = (curSec < PlayState.SONG.notes.length - 1 && showNextSection);
			}
			seg.visible = visible;
			seg.y = cachedSectionRow[sec] * GRID_SIZE * curZoom + meta.startStep * GRID_SIZE * curZoom;
			seg.rows = (meta.endStep - meta.startStep) * curZoom;
			seg.vortexLineEnabled = vortexEnabled;
			seg.vortexLineSpace = GRID_SIZE * 4 * curZoom;
		}
	}

	/** 多k: 某小节总高度 (Step 数 * 格高 * zoom)。 */
	function sectionHeightPx(sec:Int):Float
	{
		return sectionSteps(sec) * GRID_SIZE * curZoom;
	}

	/** 多k: 某小节网格最大宽度 (取段内最大键数, 供鼠标点击边界使用)。 */
	function sectionWidthPx(sec:Int):Float
	{
		var maxK:Int = EKData.clampMania(PlayState.mania);
		for (seg in sectionSegments(sec))
			if (seg.k > maxK) maxK = seg.k;
		return (SHOW_EVENT_COLUMN ? EVENT_COLUMN_WIDTH : 0) + Note.ammo[maxK] * GRID_PLAYERS * GRID_SIZE;
	}

	/** 多k: 主网格 (每窗第一段) 的行数: 小节内首个事件之前的 Step 数 * zoom。 */
	function mainGridRows(sec:Int, zoom:Float):Float
	{
		var segs:Array<{startStep:Int, k:Int}> = sectionSegments(sec);
		if (segs.length > 1) return segs[1].startStep * zoom;
		return sectionSteps(sec) * zoom;
	}

	/** 多k: 某键数网格的玩家/对手分隔线列号 (与旧逻辑一致, 列数随键数变化)。 */
	function gridStripesForMania(mania:Int):Array<Int>
	{
		var columns:Int = SHOW_EVENT_COLUMN ? 1 : 0;
		var stripes:Array<Int> = [];
		var ammo:Int = Note.ammo[EKData.clampMania(mania)];
		for (i in 0...GRID_PLAYERS)
		{
			if (columns > 0) stripes.push(columns);
			columns += ammo;
		}
		return stripes;
	}

	var cachedSectionRow:Array<Int>;
	var cachedSectionTimes:Array<Float>;
	var cachedSectionCrochets:Array<Float>;
	var cachedSectionBPMs:Array<Float>;
	function loadChart(song:SwagSong)
	{
		PlayState.SONG = song;
		// 多k: 键数与网格尺寸同步 (旧 4K 谱面无 mania 字段)
		if (PlayState.SONG.mania == null) PlayState.SONG.mania = Note.defaultMania;
		PlayState.mania = EKData.clampMania(PlayState.SONG.mania);
		PlayState.SONG.mania = PlayState.mania;
		GRID_COLUMNS_PER_PLAYER = Note.ammo[PlayState.mania];
		GRID_SIZE = editorGridSize(PlayState.mania);

		// 多k: 打开不同键数的谱面时, 网格/轨道/头部图标必须按新键数重建,
		// 否则只更新了静态列数, 网格精灵还是旧键数的样子 (打开 7K 谱仍显示 4K)。
		if (gridBg != null)
		{
			try
			{
				// 空谱/直接进入时 section 缓存尚未建立, 必须先缓存,
				// 否则 updateGridVisibility -> softReloadNotes 越界读空数组 (release 下挂死)
				_cacheSections();
				createGrids(false);
				rebuildStrumNotes();
				repositionEditorUI();
				updateGridVisibility();
			}
			catch (e:Dynamic)
			{
				TraceManager.error('trace.editor.exception', 'loadChart grid rebuild failed: {}', [Std.string(e)]);
			}
		}

		// Smart defaults matching PlayState.create() logic
		if(PlayState.SONG.stage == null || PlayState.SONG.stage.length < 1)
		{
			var songName:String = Paths.formatToSongPath(PlayState.SONG.song);
			switch(songName)
			{
				case 'spookeez' | 'south' | 'monster': PlayState.SONG.stage = 'spooky';
				case 'pico' | 'blammed' | 'philly' | 'philly-nice': PlayState.SONG.stage = 'philly';
				case 'milf' | 'satin-panties' | 'high': PlayState.SONG.stage = 'limo';
				case 'cocoa' | 'eggnog': PlayState.SONG.stage = 'mall';
				case 'winter-horrorland': PlayState.SONG.stage = 'mallEvil';
				case 'senpai' | 'roses': PlayState.SONG.stage = 'school';
				case 'thorns': PlayState.SONG.stage = 'schoolEvil';
				case 'ugh' | 'guns' | 'stress': PlayState.SONG.stage = 'tank';
				default: PlayState.SONG.stage = 'stage';
			}
		}
		if(PlayState.SONG.gfVersion == null || PlayState.SONG.gfVersion.length < 1)
		{
			switch(PlayState.SONG.stage)
			{
				case 'limo': PlayState.SONG.gfVersion = 'gf-car';
				case 'mall' | 'mallEvil': PlayState.SONG.gfVersion = 'gf-christmas';
				case 'school' | 'schoolEvil': PlayState.SONG.gfVersion = 'gf-pixel';
				case 'tank': PlayState.SONG.gfVersion = 'gf-tankmen';
				default: PlayState.SONG.gfVersion = 'gf';
			}
			var songName:String = Paths.formatToSongPath(PlayState.SONG.song);
			switch(songName)
			{
				case 'stress': PlayState.SONG.gfVersion = 'pico-speaker';
			}
		}
		if(PlayState.SONG.arrowSkin == null) PlayState.SONG.arrowSkin = '';
		if(PlayState.SONG.splashSkin == null) PlayState.SONG.splashSkin = 'noteSplashes';

		// Initialize pixel stage flag from the stage file
		var stageFile = StageData.getStageFile(PlayState.SONG.stage);
		if(stageFile != null) PlayState.isPixelStage = stageFile.isPixelStage;

		StageData.loadDirectory(PlayState.SONG);
		Conductor.bpm = PlayState.SONG.bpm;
		clearUnsaved();
	}

	function loadMusic(?killAudio:Bool = false)
	{
		setSongPlaying(false);
		var time:Float = Conductor.songPosition;

		if(killAudio)
		{
			var sndsToKill:Array<String> = [];
			for (key => snd in Paths.currentTrackedSounds)
			{
				//trace(key, snd);
				if(key.contains('/songs/${Paths.formatToSongPath(PlayState.SONG.song)}/') && snd != null)
				{
					sndsToKill.push(key);
					snd.close();
				}
			}

			for (key in sndsToKill)
			{
				Assets.cache.clear(key);
				Paths.currentTrackedSounds.remove(key);
				Paths.untrackLocalAsset(key);
			}
		}

		try
		{
			FlxG.sound.playMusic(Paths.inst(PlayState.SONG.song), 0);
			FlxG.sound.music.pause();
			FlxG.sound.music.time = time;
			FlxG.sound.music.onComplete = (function() songFinished = true);
		}
		catch(e:Exception)
		{
			FlxG.log.error('Error loading song: $e');
			return;
		}

		@:privateAccess vocals.cleanup(true);
		@:privateAccess opponentVocals.cleanup(true);
		if (PlayState.SONG.needsVoices)
		{
			try
			{
				var file:Dynamic = Paths.voices(Paths.formatToSongPath(PlayState.SONG.song));
				vocals = new FlxSound();
				opponentVocals = new FlxSound();
				if (Std.isOfType(file, Sound) || OpenFlAssets.exists(file)) {
					vocals.loadEmbedded(file);
					FlxG.sound.list.add(vocals);
				}
				var bfVocalPath = 'songs/' + Paths.formatToSongPath(PlayState.SONG.song) + '/Voices-Player.ogg';
				var dadVocalPath = 'songs/' + Paths.formatToSongPath(PlayState.SONG.song) + '/Voices-Opponent.ogg';

				#if MODS_ALLOWED
				if (sys.FileSystem.exists(Paths.modFolders(bfVocalPath))) {
					vocals.loadEmbedded(Paths.modFolders(bfVocalPath));
				} 
				#end
				if (OpenFlAssets.exists(bfVocalPath)) {
					vocals.loadEmbedded(bfVocalPath);
				}
				#if MODS_ALLOWED
				if (sys.FileSystem.exists(Paths.modFolders(dadVocalPath))) {
					opponentVocals.loadEmbedded(Paths.modFolders(dadVocalPath));
				}
				#end
				if (OpenFlAssets.exists(dadVocalPath)) {
					opponentVocals.loadEmbedded(dadVocalPath);
				}
			}
			catch (e:Dynamic) {
				CoolUtil.traceMsg('trace.vocalsError', 'Error loading vocals: {}', [e]);
			}
		}

		#if DISCORD_ALLOWED
		DiscordClient.changePresence('Chart Editor', 'Song: ' + PlayState.SONG.song);
		#end

		updateAudioVolume();
		setPitch();
		_cacheSections();
	}

	function onSongComplete()
	{
		TraceManager.debug('trace.editor.songCompleted', 'song completed');
		setSongPlaying(false);
		Conductor.songPosition = FlxG.sound.music.time = vocals.time = opponentVocals.time = FlxG.sound.music.length - 1;
		curSec = PlayState.SONG.notes.length - 1;
		forceDataUpdate = true;
	}

	function updateAudioVolume()
	{
		FlxG.sound.music.volume = instVolumeStepper.value;
		vocals.volume = playerVolumeStepper.value;
		opponentVocals.volume = opponentVolumeStepper.value;
		if(instMuteCheckBox.checked) FlxG.sound.music.volume = 0;
		if(playerMuteCheckBox.checked) vocals.volume = 0;
		if(opponentMuteCheckBox.checked) opponentVocals.volume = 0;
	}

	var playbackRate:Float = 1;
	function setPitch(?value:Null<Float>)
	{
		#if FLX_PITCH
		if(value == null) value = playbackRate;
		FlxG.sound.music.pitch = value;
		vocals.pitch = value;
		opponentVocals.pitch = value;
		#end
	}

	function setSongPlaying(doPlay:Bool)
	{
		if(FlxG.sound.music == null) return;

		vocals.time = FlxG.sound.music.time;
		opponentVocals.time = FlxG.sound.music.time;

		if(doPlay)
		{
			FlxG.sound.music.play();
			if(FlxG.sound.music.time < vocals.length) vocals.play(true, FlxG.sound.music.time);
			if(FlxG.sound.music.time < opponentVocals.length) opponentVocals.play(true, FlxG.sound.music.time);
			updateAudioVolume();
		}
		else
		{
			FlxG.sound.music.pause();
			vocals.pause();
			opponentVocals.pause();
		}

		for (note in strumLineNotes)
		{
			note.alpha = doPlay ? 1 : 0.4;
			if(!doPlay)
			{
				note.playAnim('static');
				note.resetAnim = 0;
			}
		}
	}

	function reloadNotes()
	{
		MetaNote.clearStaticCache();
		selectedNotes = [];
		for (note in notes) if(note != null) note.destroy();
		for (event in events) if(event != null) event.destroy();
		notes = [];
		events = [];
		undoActions = [];

		for (secNum => section in PlayState.SONG.notes)
			for (note in section.sectionNotes)
				if(note != null)
					notes.push(createNote(note, secNum));

		for (eventNum => event in PlayState.SONG.events)
			if(event != null && (cachedSectionTimes.length < 1 || event[0] < cachedSectionTimes[cachedSectionTimes.length-1])) //dont spawn events over the time limit
				events.push(createEvent(event));

		notes.sort(PlayState.sortByTime);
		events.sort(PlayState.sortByTime);

		TraceManager.debug('trace.editor.noteCount', 'Note count: {}', [notes.length]);
		TraceManager.debug('trace.editor.eventCount', 'Events count: {}', [events.length]);
		loadSection();
	}

	/**
	 * 多k: 切 K 后快速更新现有 Note (数据/动画/颜色/尺寸/位置), 不重建对象。
	 * 物量极大的谱面切 K 不再逐 Note destroy/create, 避免卡顿; 也避免重建中断丢 Note。
	 */
	function updateNotesForMania():Void
	{
		for (n in notes)
		{
			if (n == null || n.isEvent) continue;
			var raw:Int = Std.int(n.songData[1]);
			if (raw < 0) continue;
			// 多k: 按该 Note 自身时间点的生效键数解释, 不随播放头 k 变化
			n.mania = EKData.effectiveManiaAtTime((PlayState.SONG != null) ? PlayState.SONG.events : null, chartBaseMania(), n.strumTime);
			var noteAmmo:Int = Note.ammo[EKData.clampMania(n.mania)];
			if (n.chartNoteData != raw || n.noteData != raw % noteAmmo)
			{
				n.changeNoteData(raw); // 更新动画/颜色/尺寸 (songData[1] 保持完整 raw, 保留 side)
			}
			else
				n.applyLaneColor();
			positionNoteXByData(n);
			// 切 K 后 GRID_SIZE 变化, 必须重算 Y, 否则 Note 停留在旧位置 (渲染成空气/错位)
			var secNum:Int = 0;
			while (secNum + 1 < cachedSectionTimes.length && cachedSectionTimes[secNum + 1] <= n.strumTime) secNum++;
			positionNoteYOnTime(n, secNum);
		}
		for (e in events)
		{
			if (e == null) continue;
			e.x = gridBg.x; // 网格重居中后事件列位置同步
			var secNum:Int = 0;
			while (secNum + 1 < cachedSectionTimes.length && cachedSectionTimes[secNum + 1] <= e.strumTime) secNum++;
			positionNoteYOnTime(e, secNum);
		}
		loadSection(); // 重排 Y / 事件 / 相邻段落
	}

	/** 多k: 预览模式下的网格键数 (-1 = 未预览, 使用谱面基准 SONG.mania)。 */
	var previewMania:Int = -1;

	/** 多k: 事件输入 (键数) 编辑会话, 焦点释放后统一重编码, 避免逐字符中间态。 */
	var _pendingManiaReencode:Bool = false;
	var _pendingManiaOldEvents:Array<Dynamic> = null;
	var _eventInputFocused:Bool = false;
	/** 多k: 拖动事件期间的事件快照 (移动 Change Mania 事件位置后重编码用)。 */
	var _moveOldEvents:Array<Dynamic> = null;
	var _moveHadChangeMania:Bool = false;

	/** 多k: 计算某时间点应生效的键数 (0 基): 取该时间前最近一次 Change Mania 事件的 k 值。 */
	function computeManiaAtTime(time:Float):Int
	{
		if (PlayState.SONG == null) return Note.defaultMania;
		var base:Int = (PlayState.SONG.mania != null) ? EKData.clampMania(PlayState.SONG.mania) : Note.defaultMania;
		return EKData.effectiveManiaAtTime(PlayState.SONG.events, base, time);
	}

	/**
	 * 多k: 编辑器网格按播放位置动态预览 Change Mania 事件 (预览模式)。
	 * - 事件之前显示谱面基准 k, 经过事件后显示新 k, 回退到事件前自动恢复;
	 * - 只改 previewMania / PlayState.mania 显示, 不修改 SONG.mania 谱面数据。
	 * @param lastTime 上一次播放位置 (仅用于判断位置是否有变化, 本实现按当前位置全量计算)
	 * @param songPos  当前播放位置
	 */
	function checkManiaEvents(lastTime:Float, songPos:Float):Void
	{
		if (PlayState.SONG == null || FlxG.sound.music == null) return;
		var target:Int = computeManiaAtTime(songPos);
		if (target == (previewMania >= 0 ? previewMania : ((PlayState.SONG.mania != null) ? EKData.clampMania(PlayState.SONG.mania) : Note.defaultMania)))
			return; // 显示键数未变化
		previewMania = target;
		PlayState.mania = target;
		GRID_COLUMNS_PER_PLAYER = Note.ammo[PlayState.mania];
		var oldGridSize:Int = GRID_SIZE;
		var newGridSize:Int = editorGridSize(PlayState.mania);
		GRID_SIZE = newGridSize;
		try
		{
			// 多k: 网格列数按事件静态分段, 播放经过事件时只有跨 k 格宽变化才重建网格,
			// 避免滑动时整段重建成像闪烁 (4K<->9K 格宽同为 40, 无需重建)。
			if (newGridSize != oldGridSize) createGrids(false);
			rebuildStrumNotes();
			repositionEditorUI();
			updateGridVisibility();
			updateNotesForMania();
			updateHeads(true);
			updateScrollY();
		}
		catch (e2:Dynamic)
		{
			TraceManager.error('trace.editor.maniaEventError', 'Change Mania 事件更新网格出错: {}', [Std.string(e2)]);
		}
		if (maniaStepper != null) maniaStepper.value = target + 1;
	}

	/**
	 * 多k: 切 K 时转换谱面 Note 数据。
	 * - 玩家方/对手方归属 (side) 始终保持;
	 * - 轨道号按新 K 取模;
	 * - mode=1/3: 每个 (side, strumTime) 组内轨道随机重排 (组内数量超过新轨道数时保持映射, 避免冲突丢 Note);
	 * - mode=2/3: 每组只有 1 个 Note 时自动复制到同侧空轨道组成双押。
	 */
	function convertChartNoteData(oldMania:Int, newMania:Int, mode:Int = 0):Void
	{
		if (oldMania == newMania || PlayState.SONG == null) return;
		var oldAmmo:Int = Note.ammo[EKData.clampMania(oldMania)];
		var newAmmo:Int = Note.ammo[EKData.clampMania(newMania)];
		if (oldAmmo < 1 || newAmmo < 1) return;

		// 记录 Note -> 所属 section, 避免补双押时 O(n^2) 查找 (物量大谱面卡顿/丢 Note)
		var noteSection:Map<Array<Dynamic>, SwagSection> = [];
		var all:Array<Array<Dynamic>> = [];
		for (section in PlayState.SONG.notes)
		{
			if (section == null || section.sectionNotes == null) continue;
			for (note in section.sectionNotes)
			{
				if (note == null || note.length < 2) continue;
				var raw:Int = Std.int(note[1]);
				if (raw < 0) continue; // 事件 Note (data = -1)
				noteSection.set(note, section);
				all.push(note);
			}
		}

		// 1. 基础映射: side 保持, lane 按新 K 取模
		for (note in all)
		{
			var raw:Int = Std.int(note[1]);
			var side:Int = Std.int(raw / oldAmmo);
			if (side > 1) side = 1; // 防御: 只允许玩家/对手两侧
			var lane:Int = raw % oldAmmo;
			note[1] = side * newAmmo + (lane % newAmmo);
		}

		// 2. 自动打乱: 每个 (side, strumTime) 组内的轨道随机重排 (确定性 seed)
		var doShuffle:Bool = (mode == 1 || mode == 3);
		var doFill:Bool = (mode == 2 || mode == 3);
		if (doShuffle && newAmmo > oldAmmo)
		{
			var groups:Map<String, Array<{note:Array<Dynamic>, side:Int}>> = [];
			for (note in all)
			{
				var raw:Int = Std.int(note[1]);
				var side:Int = Std.int(raw / newAmmo);
				var key:String = side + ':' + note[0];
				if (!groups.exists(key)) groups.set(key, []);
				groups.get(key).push({note: note, side: side});
			}
			for (key => grp in groups)
			{
				// 组内数量超过新轨道数时保持基础映射, 避免同轨冲突导致 Note 重叠/丢失
				if (grp.length < 2 || grp.length > newAmmo) continue;
				var targets:Array<Int> = [for (i in 0...newAmmo) i];
				// xorshift 确定性随机 (FlxRandom 的 LCG 在 32 位 Int 下溢出, 分布偏斜)
				var rstate:Int = hashStr(key);
				if (rstate == 0) rstate = 0x9E3779B9;
				var i:Int = targets.length - 1;
				while (i >= 1)
				{
					rstate ^= (rstate << 13);
					rstate ^= (rstate >>> 17);
					rstate ^= (rstate << 5);
					var j:Int = (rstate & 0x7FFFFFFF) % (i + 1);
					var tmp:Int = targets[i];
					targets[i] = targets[j];
					targets[j] = tmp;
					i--;
				}
				for (i in 0...grp.length)
					grp[i].note[1] = grp[0].side * newAmmo + targets[i];
			}
		}

		// 3. 自动补双押: 每组只有 1 个 Note 时复制到同侧空轨道
		if (doFill && newAmmo > oldAmmo)
		{
			var groups2:Map<String, Array<Array<Dynamic>>> = [];
			for (note in all)
			{
				var raw:Int = Std.int(note[1]);
				var side:Int = Std.int(raw / newAmmo);
				var key:String = side + ':' + note[0];
				if (!groups2.exists(key)) groups2.set(key, []);
				groups2.get(key).push(note);
			}
			for (key => grp in groups2)
			{
				if (grp.length != 1) continue; // 已是双押/多押则跳过
				var raw:Int = Std.int(grp[0][1]);
				var side:Int = Std.int(raw / newAmmo);
				var used:Array<Bool> = [for (i in 0...newAmmo) false];
				for (n in grp) used[Std.int(n[1]) % newAmmo] = true;
				var free:Array<Int> = [for (i in 0...newAmmo) if (!used[i]) i];
				if (free.length < 1) continue;
				var seed:Int = hashStr(key);
				var newLane:Int = free[Std.int(Math.abs(seed)) % free.length];
				var copyNote:Array<Dynamic> = grp[0].copy();
				copyNote[1] = side * newAmmo + newLane;
				var sec:SwagSection = noteSection.get(grp[0]);
				if (sec != null && sec.sectionNotes != null) sec.sectionNotes.push(copyNote);
			}
		}
	}

	/**
	 * 多k: 事件列表变化 (增删改 Change Mania) 后, 把受影响 Note 从旧生效键数
	 * 重编码到新生效键数, 遵循"多k工具"里的转换模式。
	 * - 顺序映射 (mode=0): side 保持, lane 按新 k 取模;
	 * - mode=1/3: 每个 (side, 旧k, 时间) 组内确定性重排;
	 * - mode=2/3: 单押自动复制到同侧空轨道组成双押。
	 */
	function reencodeNotesForEventChange(oldEvents:Array<Dynamic>, newEvents:Array<Dynamic>, mode:Int):Void
	{
		if (PlayState.SONG == null || PlayState.SONG.notes == null) return;
		var baseMania:Int = chartBaseMania();
		var noteSection:Map<Array<Dynamic>, SwagSection> = [];
		var all:Array<Array<Dynamic>> = [];
		for (section in PlayState.SONG.notes)
		{
			if (section == null || section.sectionNotes == null) continue;
			for (note in section.sectionNotes)
			{
				if (note == null || note.length < 2) continue;
				var raw:Int = Std.int(note[1]);
				if (raw < 0) continue; // 事件 Note
				noteSection.set(note, section);
				all.push(note);
			}
		}
		if (all.length < 1) return;

		// 筛选受影响 Note (新旧事件列表下生效键数不同的), 并记录旧键数
		var changed:Array<Array<Dynamic>> = [];
		var oldKOf:Map<Array<Dynamic>, Int> = [];
		for (note in all)
		{
			var t:Float = Std.parseFloat(Std.string(note[0]));
			var oldK:Int = EKData.effectiveManiaAtTime(oldEvents, baseMania, t);
			var newK:Int = EKData.effectiveManiaAtTime(newEvents, baseMania, t);
			if (oldK == newK) continue;
			oldKOf.set(note, oldK);
			changed.push(note);
		}
		if (changed.length < 1) return;

		// 1. 顺序映射基础: side 保持, lane 按新 k 取模
		for (note in changed)
		{
			var t:Float = Std.parseFloat(Std.string(note[0]));
			var newK:Int = EKData.effectiveManiaAtTime(newEvents, baseMania, t);
			note[1] = EKData.convertRawData(Std.int(note[1]), oldKOf.get(note), newK);
		}

		var doShuffle:Bool = (mode == 1 || mode == 3);
		var doFill:Bool = (mode == 2 || mode == 3);
		if (!doShuffle && !doFill) return;

		// 2. 按 (side, 旧k, 新k, 时间) 分组
		var groups:Map<String, Array<{note:Array<Dynamic>, side:Int, newK:Int, newAmmo:Int}>> = [];
		for (note in changed)
		{
			var t:Float = Std.parseFloat(Std.string(note[0]));
			var newK:Int = EKData.effectiveManiaAtTime(newEvents, baseMania, t);
			var raw:Int = Std.int(note[1]);
			var newAmmo:Int = Note.ammo[newK];
			var side:Int = Std.int(raw / newAmmo);
			if (side > 1) side = 1;
			var key:String = side + ':' + oldKOf.get(note) + ':' + newK + ':' + note[0];
			if (!groups.exists(key)) groups.set(key, []);
			groups.get(key).push({note: note, side: side, newK: newK, newAmmo: newAmmo});
		}

		for (key => grp in groups)
		{
			var oldK:Int = oldKOf.get(grp[0].note);
			if (grp[0].newAmmo <= Note.ammo[oldK]) continue; // 只在扩容时重排/补双押

			if (doShuffle && grp.length >= 2 && grp.length <= grp[0].newAmmo)
			{
				var targets:Array<Int> = [for (i in 0...grp[0].newAmmo) i];
				var rstate:Int = hashStr(key);
				if (rstate == 0) rstate = 0x9E3779B9;
				var i:Int = targets.length - 1;
				while (i >= 1)
				{
					rstate ^= (rstate << 13);
					rstate ^= (rstate >>> 17);
					rstate ^= (rstate << 5);
					var j:Int = (rstate & 0x7FFFFFFF) % (i + 1);
					var tmp:Int = targets[i];
					targets[i] = targets[j];
					targets[j] = tmp;
					i--;
				}
				for (i in 0...grp.length)
					grp[i].note[1] = grp[0].side * grp[0].newAmmo + targets[i];
			}
			else if (doFill && grp.length == 1)
			{
				var used:Array<Bool> = [for (i in 0...grp[0].newAmmo) false];
				used[Std.int(grp[0].note[1]) % grp[0].newAmmo] = true;
				var free:Array<Int> = [for (i in 0...grp[0].newAmmo) if (!used[i]) i];
				if (free.length < 1) continue;
				var seed:Int = hashStr(key);
				var newLane:Int = free[Std.int(Math.abs(seed)) % free.length];
				var copyNote:Array<Dynamic> = grp[0].note.copy();
				copyNote[1] = grp[0].side * grp[0].newAmmo + newLane;
				var sec:SwagSection = noteSection.get(grp[0].note);
				if (sec != null && sec.sectionNotes != null) sec.sectionNotes.push(copyNote);
			}
		}
	}

	/** 多k: Change Mania 事件编辑后统一处理: 重编码受影响 Note + 重建网格/音符。 */
	function refreshAfterManiaEventEdit(oldEvents:Array<Dynamic>):Void
	{
		if (PlayState.SONG == null) return;
		var mode:Int = (convertModeDropDown != null) ? convertModeDropDown.selectedIndex : 0;
		// 编辑器事件数组是权威数据, 先同步回 SONG.events 再重编码
		try { _cacheSections(); updateChartData(); } catch (e:Dynamic) {}
		reencodeNotesForEventChange(oldEvents, PlayState.SONG.events, mode);
		try
		{
			createGrids(false);
			rebuildStrumNotes();
			repositionEditorUI();
			updateGridVisibility();
			// 补双押模式会新增 Note, 需要整表重载; 其余模式复用现有 Note 快速更新
			if (mode == 2 || mode == 3)
				reloadNotes();
			else
				updateNotesForMania();
			updateHeads(true);
			updateScrollY();
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.editor.maniaEventError', 'Change Mania 事件更新网格出错: {}', [Std.string(e)]);
		}
		markUnsaved();
	}

	/** 多k: 深拷贝编辑器当前事件数组 (格式同 EKData.deepCopyEvents, 不共享内部数组)。 */
	function deepCopyEditorEvents():Array<Dynamic>
	{
		var ret:Array<Dynamic> = [];
		for (ev in events)
		{
			if (ev == null || ev.songData == null) continue;
			var dataCopy:Array<Dynamic> = ev.songData.copy();
			if (dataCopy[1] != null)
			{
				var subs:Array<Dynamic> = cast dataCopy[1].copy();
				for (i => sub in subs)
					if (sub != null) subs[i] = sub.copy();
				dataCopy[1] = subs;
			}
			ret.push(dataCopy);
		}
		return ret;
	}

	/** 多k: 标记 Change Mania 事件键数输入会话 (首次输入时记录事件快照)。 */
	function markPendingManiaReencode():Void
	{
		if(!_pendingManiaReencode)
			_pendingManiaOldEvents = deepCopyEditorEvents();
		_pendingManiaReencode = true;
	}

	/** 多k: 该事件对象是否包含 Change Mania 子事件。 */
	function eventHasChangeMania(ev:EventMetaNote):Bool
	{
		if (ev == null || ev.events == null) return false;
		for (sub in ev.events)
			if (sub != null && Std.string(sub[0]) == 'Change Mania') return true;
		return false;
	}

	/** 字符串哈希, 用作确定性随机种子。 */
	static function hashStr(s:String):Int
	{
		var h:Int = 0;
		for (i in 0...s.length)
			h = ((h << 5) - h) + s.charCodeAt(i);
		return h;
	}

	/** 安全获取 section 开始时间; 缓存缺失/过期时从头累加计算, 绝不静默返回 0。 */
	function safeSectionStart(secNum:Int):Float
	{
		if (PlayState.SONG == null) return 0;
		if (secNum < cachedSectionTimes.length)
			return cachedSectionTimes[secNum];
		var t:Float = 0;
		var bpm:Float = PlayState.SONG.bpm;
		for (i in 0...secNum)
		{
			if (i >= PlayState.SONG.notes.length) break;
			var sec:SwagSection = PlayState.SONG.notes[i];
			if (sec == null) continue;
			if (sec.changeBPM && sec.bpm != null && sec.bpm > 0) bpm = sec.bpm;
			var sb:Null<Float> = sec.sectionBeats;
			var beats:Float = (sb != null && sb > 0) ? sb : 4;
			t += Conductor.calculateCrochet(bpm) * beats;
		}
		return t;
	}

	/** 安全获取 section 的 16 分音符步长 (ms); 缓存缺失时按 BPM 推算。 */
	function safeSectionStepMs(secNum:Int):Float
	{
		if (PlayState.SONG == null) return 150;
		if (secNum < cachedSectionCrochets.length && cachedSectionCrochets[secNum] > 0)
			return cachedSectionCrochets[secNum] / 4;
		var bpm:Float = PlayState.SONG.bpm;
		for (i in 0...secNum)
		{
			if (i >= PlayState.SONG.notes.length) break;
			var sec:SwagSection = PlayState.SONG.notes[i];
			if (sec != null && sec.changeBPM && sec.bpm != null && sec.bpm > 0) bpm = sec.bpm;
		}
		var step:Float = Conductor.calculateCrochet(bpm) / 4;
		return (step > 0) ? step : 150;
	}

	/** 歌曲总时长 (ms), 用于 clamp 生成 Note 的时间。 */
	inline function songLengthMs():Float
	{
		return (FlxG.sound.music != null) ? FlxG.sound.music.length : Math.POSITIVE_INFINITY;
	}

	/**
	 * 多k: 一键写大粪。
	 * 先把当前谱面切到目标 K (键数处先调好, 例如 4K -> 9K), 再点此按钮:
	 * - 分析人声 (vocals) 能量, 人声密集处生成更多 Note;
	 * - 现有 Note 按人声能量附加 1~3 个随机轨道副本 (粪谱多押);
	 * - 人声强且没有 Note 的 16 分位置补随机轨道 Note。
	 */
	function writeDumbChart():Void
	{
		if (PlayState.SONG == null) return;
		_cacheSections(); // 先刷新 section 缓存, 避免过期缓存导致时间错位
		var ammo:Int = Note.ammo[PlayState.mania];
		if (ammo < 5)
		{
			showOutput('请先切换到 5K 以上再一键写大粪', true);
			return;
		}
		var energy:Array<Float> = analyzeVocalEnergy();
		var avg:Float = 0;
		for (e in energy) avg += e;
		if (energy.length > 0) avg /= energy.length;
		var rnd:FlxRandom = new FlxRandom();
		var totalAdd:Int = 0;

		for (secNum => section in PlayState.SONG.notes)
		{
			if (section == null || section.sectionNotes == null) continue;
			var secStart:Float = safeSectionStart(secNum);
			var stepMs:Float = safeSectionStepMs(secNum);
			var sb:Null<Float> = section.sectionBeats;
			var beats:Float = (sb != null && sb > 0) ? sb : 4;
			var steps:Int = Std.int(Math.max(4, beats * 4));
			var maxTime:Float = songLengthMs();
			var used:Map<String, Bool> = [];
			var addList:Array<Array<Dynamic>> = [];

			// 记录已用轨道 + 按 (side:strumTime) 分组的单押
			var groups:Map<String, Array<Array<Dynamic>>> = [];
			for (n in section.sectionNotes)
			{
				if (n == null || n.length < 2) continue;
				var raw:Int = Std.int(n[1]);
				if (raw < 0) continue;
				var side:Int = Std.int(raw / ammo);
				var lane:Int = raw % ammo;
				used.set(Std.string(n[0]) + ':' + side + ':' + lane, true);
				var key:String = side + ':' + n[0];
				if (!groups.exists(key)) groups.set(key, []);
				groups.get(key).push(n);
			}

			// 1) 现有 Note 按人声能量多押化 (4K -> 多K 粪谱)
			for (key => grp in groups)
			{
				var raw:Int = Std.int(grp[0][1]);
				var side:Int = Std.int(raw / ammo);
				var t:Float = Std.parseFloat(Std.string(grp[0][0]));
				var e:Float = energyAt(energy, t);
				var extra:Int = 0;
				if (e > avg * 1.3) extra = rnd.int(2, 3);
				else if (e > avg * 0.7) extra = 1;
				else if (rnd.float() < 0.25) extra = 1;
				for (k in 0...extra)
				{
					var freeLanes:Array<Int> = [];
					for (lane in 0...ammo)
						if (!used.exists(Std.string(t) + ':' + side + ':' + lane)) freeLanes.push(lane);
					if (freeLanes.length < 1) break;
					var newLane:Int = freeLanes[rnd.int(0, freeLanes.length - 1)];
					var copyNote:Array<Dynamic> = grp[0].copy();
					copyNote[1] = side * ammo + newLane;
					addList.push(copyNote);
					used.set(Std.string(t) + ':' + side + ':' + newLane, true);
				}
			}

			// 2) 人声强且无 Note 的 16 分位置补随机轨道 Note
			for (i in 0...steps)
			{
				var st:Float = secStart + i * stepMs;
				if (st >= maxTime - 1) break; // 不生成超出歌曲长度的 Note
				var e:Float = energyAt(energy, st);
				if (e <= avg * 1.2) continue;
				var side:Int = rnd.int(0, 1);
				var has:Bool = false;
				for (lane in 0...ammo)
					if (used.exists(Std.string(st) + ':' + side + ':' + lane)) { has = true; break; }
				if (has) continue;
				var lane:Int = rnd.int(0, ammo - 1);
				var key:String = Std.string(st) + ':' + side + ':' + lane;
				if (used.exists(key)) continue;
				addList.push([st, side * ammo + lane, 0]);
				used.set(key, true);
			}

			for (n in addList) section.sectionNotes.push(n);
			totalAdd += addList.length;
		}

		markUnsaved();
		reloadNotes();
		showOutput('一键写大粪完成(匹配人声), 新增 ' + totalAdd + ' 个 Note');
	}

	/**
	 * 多k: 分析人声轨能量, 每 25ms 一个能量桶 (0~1 平均绝对值)。
	 */
	function analyzeVocalEnergy():Array<Float>
	{
		var result:Array<Float> = [];
		#if (lime_cffi && !macro)
		@:privateAccess
		if (vocals != null && vocals._sound != null && vocals._sound.__buffer != null)
		{
			var buffer:AudioBuffer = vocals._sound.__buffer;
			if (buffer != null && buffer.data != null)
			{
				var bytes:Bytes = buffer.data.toBytes();
				var channels:Int = buffer.channels;
				if (channels >= 1 && bytes != null && bytes.length >= 2)
				{
					var samplesPerBucket:Int = Math.round(buffer.sampleRate * 0.025);
					if (samplesPerBucket < 1) samplesPerBucket = 1;
					var totalFrames:Int = Math.floor(bytes.length / (2 * channels));
					var bucketCount:Int = Math.floor(totalFrames / samplesPerBucket) + 1;
					var sums:Array<Float> = [for (i in 0...bucketCount) 0.0];
					var counts:Array<Int> = [for (i in 0...bucketCount) 0];
					var i:Int = 0;
					while (i < totalFrames)
					{
						var byte:Int = bytes.getUInt16(i * channels * 2);
						if (byte > 65535 / 2) byte -= 65535;
						var sample:Float = byte / 65535;
						if (channels >= 2)
						{
							byte = bytes.getUInt16(i * channels * 2 + 2);
							if (byte > 65535 / 2) byte -= 65535;
							var s2:Float = byte / 65535;
							if (Math.abs(s2) > Math.abs(sample)) sample = s2;
						}
						var bucket:Int = Math.floor(i / samplesPerBucket);
						if (bucket < bucketCount)
						{
							sums[bucket] += Math.abs(sample);
							counts[bucket]++;
						}
						i++;
					}
					result = [for (b in 0...bucketCount) (counts[b] > 0) ? sums[b] / counts[b] : 0];
				}
			}
		}
		#end
		return result;
	}

	/** 查询某时刻的人声能量 (25ms 桶)。 */
	inline function energyAt(energy:Array<Float>, t:Float):Float
	{
		if (energy == null || energy.length < 1 || t < 0) return 0;
		var idx:Int = Std.int(t / 25);
		if (idx >= energy.length) return 0;
		return energy[idx];
	}

	/**
	 * 多k: 密度增强。
	 * 按 1 拍窗口统计 Note 密度, 窗口内 Note 数 >= 阈值 (玩家可调) 时,
	 * 在该拍内补充 1~2 个随机轨道 Note。
	 */
	function boostDensity(threshold:Int):Void
	{
		if (PlayState.SONG == null) return;
		_cacheSections(); // 先刷新 section 缓存
		if (threshold < 1) threshold = 1;
		var ammo:Int = Note.ammo[PlayState.mania];
		var rnd:FlxRandom = new FlxRandom();
		var totalAdd:Int = 0;
		var maxTime:Float = songLengthMs();

		for (secNum => section in PlayState.SONG.notes)
		{
			if (section == null || section.sectionNotes == null) continue;
			var stepMs:Float = safeSectionStepMs(secNum);
			var beatMs:Float = stepMs * 4;
			var secStart:Float = safeSectionStart(secNum);
			var sb:Null<Float> = section.sectionBeats;
			var beats:Float = (sb != null && sb > 0) ? sb : 4;
			var steps:Int = Std.int(Math.max(4, beats * 4));
			var used:Map<String, Bool> = [];
			var addList:Array<Array<Dynamic>> = [];

			for (n in section.sectionNotes)
			{
				if (n == null || n.length < 2) continue;
				var raw:Int = Std.int(n[1]);
				if (raw < 0) continue;
				var side:Int = Std.int(raw / ammo);
				var lane:Int = raw % ammo;
				used.set(Std.string(n[0]) + ':' + side + ':' + lane, true);
			}

			// 按拍遍历 (每拍一个密度窗口, 避免同一拍被重复处理)
			var beatCount:Int = Std.int(Math.max(1, beats));
			for (b in 0...beatCount)
			{
				var beatStart:Float = secStart + b * beatMs;
				if (beatStart >= maxTime - 1) break;
				var count:Int = 0;
				for (n in section.sectionNotes)
				{
					if (n == null || n.length < 2) continue;
					var t:Float = Std.parseFloat(Std.string(n[0]));
					if (t >= beatStart && t < beatStart + beatMs) count++;
				}
				if (count < threshold) continue;
				var toAdd:Int = rnd.int(1, 2);
				for (k in 0...toAdd)
				{
					var st:Float = beatStart + rnd.int(0, 3) * stepMs;
					if (st >= maxTime - 1) continue;
					var side:Int = rnd.int(0, 1);
					var lane:Int = rnd.int(0, ammo - 1);
					var key:String = Std.string(st) + ':' + side + ':' + lane;
					if (used.exists(key)) continue;
					addList.push([st, side * ammo + lane, 0]);
					used.set(key, true);
				}
			}

			for (n in addList) section.sectionNotes.push(n);
			totalAdd += addList.length;
		}

		markUnsaved();
		reloadNotes();
		showOutput('密度增强完成(阈值 ' + threshold + '), 新增 ' + totalAdd + ' 个 Note');
	}

		function createNote(note:Dynamic, ?secNum:Null<Int> = null)
		{
			if(secNum == null) secNum = curSec;
			var section = PlayState.SONG.notes[secNum];

			var daStrumTime:Float = note[0];
			var rawNoteData:Int = Std.int(note[1]);
			if (rawNoteData < 0) rawNoteData = 0; // safety: clamp negative values
			// 多k: 按该 Note 自身时间点的生效键数解释 (Change Mania 事件分段, 各段各自解释)
			var noteMania:Int = EKData.effectiveManiaAtTime((PlayState.SONG != null) ? PlayState.SONG.events : null, chartBaseMania(), daStrumTime);
			var noteAmmo:Int = Note.ammo[EKData.clampMania(noteMania)];
			var daNoteData:Int = rawNoteData % noteAmmo;
			// 谱面加载时已通过 Song.convert() 统一转为 psych_v1 格式
			// 转换后: data 0-3 = 玩家Note, data 4-7 = 对手Note
			// 因此使用新逻辑: (rawNoteData < noteAmmo)
			var gottaHitNote:Bool = (rawNoteData < noteAmmo);

			var swagNote:MetaNote = new MetaNote(daStrumTime, daNoteData, note);
			swagNote.mania = noteMania; // 记录该 Note 所属 k, 使后续渲染/颜色按正确 k
			swagNote.mustPress = gottaHitNote;
			// 构造时着色器按 PlayState.mania 应用过颜色, 这里按 Note 自身 k 重刷
			swagNote.applyLaneColor();
			// 缓存越界保护: 防止缓存与小节数不一致时中断导致 Note 链丢失
			var susStep:Float = (secNum < cachedSectionCrochets.length && cachedSectionCrochets[secNum] > 0)
				? cachedSectionCrochets[secNum] / 4 : Conductor.stepCrochet;
			swagNote.setSustainLength(note[2], susStep, curZoom);
			swagNote.gfNote = (section.gfSection && gottaHitNote);
			swagNote.noteType = note[3];
			swagNote.scrollFactor.x = 0;

			var colArray:Array<String> = ['purple', 'blue', 'green', 'red'];
			var animToPlay:String = colArray[swagNote.baseTex()] + 'Scroll';
			if(swagNote.animation.getByName(animToPlay) != null)
				swagNote.animation.play(animToPlay);

			var txt:FlxText = swagNote.findNoteTypeText(swagNote.noteType != null ? noteTypes.indexOf(swagNote.noteType) : 0);
			if(txt != null) txt.visible = showNoteTypeLabels;

			swagNote.updateHitbox();
			if(swagNote.width > swagNote.height)
				swagNote.setGraphicSize(GRID_SIZE);
			else
				swagNote.setGraphicSize(0, GRID_SIZE);

			swagNote.updateHitbox();
			swagNote.active = false;
			positionNoteXByData(swagNote);
			positionNoteYOnTime(swagNote, secNum);
			return swagNote;
		}

	function createEvent(event:Dynamic)
	{
		var daStrumTime:Float = event[0];
		var swagEvent:EventMetaNote = new EventMetaNote(daStrumTime, event);
		swagEvent.x = gridBg.x;
		swagEvent.eventText.x = swagEvent.x - swagEvent.eventText.width - 10;
		swagEvent.scrollFactor.x = 0;
		swagEvent.active = false;

		var secNum:Int = 0;
		for (i in 1...cachedSectionTimes.length)
		{
			if(cachedSectionTimes[i] > daStrumTime) break;
			secNum++;
		}
		positionNoteYOnTime(swagEvent, secNum);
		return swagEvent;
	}

	function _cacheSections()
	{
		var time:Float = 0;
		var row:Int = 0;
		cachedSectionRow = [];
		cachedSectionTimes = [];
		cachedSectionCrochets = [];
		cachedSectionBPMs = [];

		if(PlayState.SONG == null)
		{
			cachedSectionRow.push(0);
			cachedSectionTimes.push(0);
			cachedSectionCrochets.push(0);
			cachedSectionBPMs.push(0);
			return;
		}

		var bpm:Float = PlayState.SONG.bpm;
		var reachedLimit:Bool = false;
		for (secNum => section in PlayState.SONG.notes)
		{
			var secs:Null<Float> = cast section.sectionBeats;
			if(secs == null || Math.isNaN(secs) || secs <= 0) section.sectionBeats = 4;

			if(section.changeBPM) bpm = section.bpm;
			var beat:Float = Conductor.calculateCrochet(bpm);

			cachedSectionRow.push(row);
			cachedSectionTimes.push(time);
			cachedSectionCrochets.push(beat);
			cachedSectionBPMs.push(bpm);

			var rowRound:Int = Math.round(4 * section.sectionBeats);
			if(rowRound < 1) rowRound = 1;
			row += rowRound;
			// 精确拍数推进时间线 (行数取整只影响网格行, 不影响真实时间),
			// 避免取整漂移导致缓存时间线提前越过音乐长度。
			time += beat * section.sectionBeats;

			// 注意: 绝不在缓存时删除/篡改谱面段落或音符时间!
			// (旧逻辑会按音乐长度 pop 掉后面的段落, 导致长谱/音频短于谱面时
			//  所有后续 Note 连同段落一起消失, 且切换多K重新缓存时反复触发)
		}

		if(FlxG.sound.music != null && time < FlxG.sound.music.length) //Pad blank sections only when chart shorter than music
		{
			var lastSection = PlayState.SONG.notes[PlayState.SONG.notes.length-1];
			var beat:Float = Conductor.calculateCrochet(bpm);
			var sectionBeats:Float = lastSection != null ? lastSection.sectionBeats : 4;
			var rowRound:Int = Math.round(4 * sectionBeats);
			if(rowRound < 1) rowRound = 1;
			var timeAdd:Float = beat * sectionBeats;
			var mustHitSec:Bool = lastSection != null ? lastSection.mustHitSection : true;
			var changeBpmSec:Bool = lastSection != null ? lastSection.changeBPM : false;
			var altAnimSec:Bool = lastSection != null ? lastSection.altAnim : false;
			var gfSec:Bool = lastSection != null ? lastSection.gfSection : false;

			while(time < FlxG.sound.music.length)
			{
				PlayState.SONG.notes.push({
					sectionNotes: [],
					sectionBeats: sectionBeats,
					mustHitSection: mustHitSec,
					bpm: bpm,
					changeBPM: changeBpmSec,
					altAnim: altAnimSec,
					gfSection: gfSec
				});

				cachedSectionRow.push(row);
				cachedSectionTimes.push(time);
				cachedSectionCrochets.push(beat);
				cachedSectionBPMs.push(bpm);

				row += rowRound;
				time += timeAdd;

				if(time >= FlxG.sound.music.length)
				{
					TraceManager.debug('trace.editor.sectionsCreated', 'created sections until {}', [PlayState.SONG.notes.length-1]);
					reachedLimit = true;
				}
			}
		}
		cachedSectionRow.push(row);
		cachedSectionTimes.push(time);
	}

	var showPreviousSection:Bool = true;
	var showNextSection:Bool = true;
	var showNoteTypeLabels:Bool = true;
	var forceDataUpdate:Bool = true;
	function loadSection(?sec:Null<Int> = null)
	{
		if(sec != null) curSec = sec;
		curSec = Std.int(FlxMath.bound(curSec, 0, Math.max(0, PlayState.SONG.notes.length-1)));
		Conductor.bpm = cachedSectionBPMs[curSec];

		// 多k: 切节后先按新的上/中/下三窗重建主网格与事件分段 (主网格列数随窗口小节变化)
		if (_segmentsBuildSec != curSec)
			rebuildGridsForCurrentWindow();

		var hei:Float = 0;
		if(curSec > 0)
		{
			prevGridBg.y = cachedSectionRow[curSec-1] * GRID_SIZE * curZoom;
			// 多k: 主网格只画到小节内首个 Change Mania 事件为止, 之后由分段网格接管
			prevGridBg.rows = mainGridRows(curSec - 1, curZoom);
			prevGridBg.visible = showPreviousSection;
			hei += sectionHeightPx(curSec - 1);
			eventLockOverlay.y = prevGridBg.y;
		}
		else prevGridBg.visible = false;

		if(curSec < PlayState.SONG.notes.length - 1)
		{
			nextGridBg.y = cachedSectionRow[curSec+1] * GRID_SIZE * curZoom;
			nextGridBg.rows = mainGridRows(curSec + 1, curZoom);
			nextGridBg.visible = showNextSection;
			hei += sectionHeightPx(curSec + 1);
		}
		else nextGridBg.visible = false;

		gridBg.y = cachedSectionRow[curSec] * GRID_SIZE * curZoom;
		gridBg.rows = mainGridRows(curSec, curZoom);
		hei += sectionHeightPx(curSec);

		// 多k: 小节内事件切分出的网格段定位 (y/行数/可见性)
		positionGridSegments();

		if(!prevGridBg.visible) eventLockOverlay.y = gridBg.y;
		eventLockOverlay.scale.y = hei;
		eventLockOverlay.updateHitbox();

		softReloadNotes();
		updateHeads();

		var sec = getCurChartSection();
		if(sec != null)
		{
			mustHitCheckBox.checked = sec.mustHitSection;
			gfSectionCheckBox.checked = sec.gfSection;
			altAnimSectionCheckBox.checked = sec.altAnim;
			changeBpmCheckBox.checked = sec.changeBPM;
			changeBpmStepper.value = Conductor.bpm;
			beatsPerSecStepper.value = sec.sectionBeats;

			strumTimeStepper.step = Conductor.stepCrochet;
			susLengthStepper.step = cachedSectionCrochets[curSec] / 4 / 2;
			susLengthStepper.max = susLengthStepper.step * 128;
			if(selectedNotes.length > 1) susLengthStepper.min = -susLengthStepper.max;
			else susLengthStepper.min = 0;
		}
		prevGridBg.vortexLineEnabled = gridBg.vortexLineEnabled = nextGridBg.vortexLineEnabled = vortexEnabled;
		prevGridBg.vortexLineSpace = gridBg.vortexLineSpace = nextGridBg.vortexLineSpace = GRID_SIZE * 4 * curZoom;
		updateWaveform();
	}

	var _noteAlphaDirty:Bool = true; // Dirty flag: note alpha needs refresh

	/** Binary search: first index with strumTime >= target */
	function binarySearchNotes(arr:Array<MetaNote>, target:Float):Int
	{
		var lo:Int = 0, hi:Int = arr.length - 1;
		while(lo <= hi)
		{
			var mid:Int = (lo + hi) >>> 1;
			if(arr[mid] == null) { lo = mid + 1; continue; }
			if(arr[mid].strumTime < target) lo = mid + 1;
			else hi = mid - 1;
		}
		return lo;
	}

	/**
	 * Efficiently reload notes for current and adjacent sections.
	 * Uses binary search to locate section boundaries in the sorted array, avoiding full linear scan.
	 */
	function softReloadNotes(onlyCurrent:Bool = false)
	{
		if(!onlyCurrent) behindRenderedNotes.clear();
		curRenderedNotes.clear();

		// 缓存未建立 (空谱直接进入) 时回退到当前步长, 避免越界读空数组
		final curStepCrochet:Float = (curSec >= 0 && curSec < cachedSectionCrochets.length) ? cachedSectionCrochets[curSec] / 4 : Conductor.stepCrochet;
		final songPos:Float = Conductor.songPosition;

		// 当前段落的时间范围
		final minTime:Float = getMinNoteTime(curSec);
		final maxTime:Float = getMaxNoteTime(curSec);

		// Adjacent section time ranges (lazy computed)
		var prevMinTime:Float = Math.NEGATIVE_INFINITY, prevMaxTime:Float = Math.NEGATIVE_INFINITY;
		var nextMinTime:Float = Math.NEGATIVE_INFINITY, nextMaxTime:Float = Math.NEGATIVE_INFINITY;
		if(!onlyCurrent)
		{
			if(prevGridBg.visible) { prevMinTime = getMinNoteTime(curSec-1); prevMaxTime = getMaxNoteTime(curSec-1); }
			if(nextGridBg.visible) { nextMinTime = getMinNoteTime(curSec+1); nextMaxTime = getMaxNoteTime(curSec+1); }
		}

		sectionFirstNoteID = 0;
		sectionFirstEventID = 0;
		var foundFirstNote:Bool = false;
		var foundFirstEvent:Bool = false;

		// Start from the first note that may fall in current section
		var startIdx:Int = binarySearchNotes(notes, minTime);
		for (num in startIdx...notes.length)
		{
			var note:MetaNote = notes[num];
			if(note == null) continue;
			final t:Float = note.strumTime;
			if(t >= maxTime) break; // Past section time range, stop

			if(!foundFirstNote) { sectionFirstNoteID = num; foundFirstNote = true; }
			curRenderedNotes.add(note);
			note.alpha = (t >= songPos) ? 1 : 0.6;
			if(note.hasSustain) note.updateSustainToZoom(curStepCrochet, curZoom);
		}

		// 相邻段落 Note（独立扫描，范围较小）
		if(!onlyCurrent)
		{
			if(prevGridBg.visible)
			{
				startIdx = binarySearchNotes(notes, prevMinTime);
				for (num in startIdx...notes.length)
				{
					var note:MetaNote = notes[num];
					if(note == null) continue;
					final t:Float = note.strumTime;
					if(t >= prevMaxTime) break;
					behindRenderedNotes.add(note);
					note.alpha = 0.4;
					if(note.hasSustain) note.updateSustainToZoom(curStepCrochet, curZoom);
				}
			}
			if(nextGridBg.visible)
			{
				startIdx = binarySearchNotes(notes, nextMinTime);
				for (num in startIdx...notes.length)
				{
					var note:MetaNote = notes[num];
					if(note == null) continue;
					final t:Float = note.strumTime;
					if(t >= nextMaxTime) break;
					behindRenderedNotes.add(note);
					note.alpha = 0.4;
					if(note.hasSustain) note.updateSustainToZoom(curStepCrochet, curZoom);
				}
			}
		}

		if(SHOW_EVENT_COLUMN)
		{
			// Events are typically few, linear scan is fine
			for (num => event in events)
			{
				if(event == null) continue;
				final t:Float = event.strumTime;

				if(t >= minTime && t < maxTime)
				{
					if(!foundFirstEvent) { sectionFirstEventID = num; foundFirstEvent = true; }
					curRenderedNotes.add(event);
					event.alpha = (t >= songPos) ? 1 : 0.6;
					event.eventText.visible = true;
				}
				else if(!onlyCurrent && ((prevGridBg.visible && t >= prevMinTime && t < prevMaxTime)
					|| (nextGridBg.visible && t >= nextMinTime && t < nextMaxTime)))
				{
					behindRenderedNotes.add(event);
					event.alpha = 0.4;
					event.eventText.visible = false;
				}
			}
		}
		_noteAlphaDirty = false;
	}

	function getMinNoteTime(sec:Int)
	{
		var minTime:Float = Math.NEGATIVE_INFINITY;
		if(sec > 0)
			minTime = cachedSectionTimes[sec];
		return minTime;
	}

	function getMaxNoteTime(sec:Int)
	{
		var maxTime:Float = Math.POSITIVE_INFINITY;
		if(sec + 1 < cachedSectionTimes.length)
			maxTime = cachedSectionTimes[sec + 1];
		return maxTime;
	}

	/** 根据 strumTime 和章节信息快速计算 Note 的 Y 坐标（不含居中偏移） */
	inline function calcNoteY(strumTime:Float, sec:Int, zoom:Float):Float
	{
		// 缓存越界保护: 防止缓存与小节数不一致时中断导致 Note 链丢失
		var secTime:Float = (sec < cachedSectionTimes.length) ? cachedSectionTimes[sec] : 0;
		var secCrochet:Float = (sec < cachedSectionCrochets.length && cachedSectionCrochets[sec] > 0) ? cachedSectionCrochets[sec] : Conductor.stepCrochet * 4;
		var secRow:Int = (sec < cachedSectionRow.length) ? cachedSectionRow[sec] : 0;
		return Math.max(((strumTime - secTime) / secCrochet) * GRID_SIZE * 4 * zoom + secRow * GRID_SIZE * zoom, -150);
	}

	function positionNoteXByData(note:MetaNote, ?data:Null<Int> = null)
	{
		if(data == null) data = note.songData[1];

		var noteX:Float = gridBg.x + (GRID_SIZE - note.width) / 2;
		if(SHOW_EVENT_COLUMN) noteX += EVENT_COLUMN_WIDTH;

		noteX += GRID_SIZE * data;
		note.x = noteX;
		//trace(gridBg.x, noteX);
	}

	function positionNoteYOnTime(note:MetaNote, section:Int)
	{
		var noteY:Float = calcNoteY(note.strumTime, section, curZoom);
		note.y = noteY + (GRID_SIZE/2 - note.height/2);
		note.chartY = noteY;
	}

	var characterData:Dynamic = {};
	function updateJsonData():Void
	{
		for (i in 1...GRID_PLAYERS+1)
		{
			//trace('adding iconP$i');
			var data:CharacterFile = loadCharacterFile(Reflect.field(PlayState.SONG, 'player$i'));
			Reflect.setField(characterData, 'iconP$i', data != null && data.healthicon != null ? data.healthicon : 'face');
			//Reflect.setField(characterData, 'vocalsP$i', data != null && data.vocals_file != null ? data.vocals_file : '');
		}

		// 角色数据变化后立即刷新头部图标 (初次进入时 updateHeads 先于本函数执行,
		// 图标加载成回退图; 若不在此刷新, 优化守卫会一直跳过)
		updateHeads(true);
	}
	
	var _lastSec:Int = -1;
	var _lastGfSection:Null<Bool> = null;
	/** 网格当前使用的键数 (用于加载不同 K 谱面时强制重建网格)。 */
	var _lastGridMania:Int = -1;
	function updateHeads(ignoreCheck:Bool = false):Void
	{
		var curSecData:SwagSection = PlayState.SONG.notes[curSec];
		var isGfSection:Bool = (curSecData != null && curSecData.gfSection == true);

		// 小节状态没变也可能需要刷图标: characterData 可能在两次调用之间被
		// updateJsonData 更新 (初次进入加载了回退图标), 只按小节状态判断会漏刷。
		var iconsMismatch:Bool = false;
		for (i in 0...GRID_PLAYERS)
		{
			var icon:HealthIcon = icons[i];
			if (icon == null) continue;
			var target:String = Reflect.field(characterData, 'iconP${icon.ID}');
			if (icon.getCharacter() != target) { iconsMismatch = true; break; }
		}

		if(!ignoreCheck && !iconsMismatch && _lastGfSection == isGfSection && _lastSec == curSec) return; //optimization

		for (i in 0...GRID_PLAYERS)
		{
			var icon:HealthIcon = icons[i];
			//trace('changing iconP${icon.ID}');
			var iconName:String = Reflect.field(characterData, 'iconP${icon.ID}');
			if (iconName != null) icon.changeIcon(iconName);
		}

		if(icons.length > 1)
		{
			var iconP1:HealthIcon = icons[0];
			var iconP2:HealthIcon = icons[1];
			var mustHitSection:Bool = (curSecData != null && curSecData.mustHitSection == true);
			if (isGfSection)
			{
				if (mustHitSection)
					iconP1.changeIcon('gf');
				else
					iconP2.changeIcon('gf');
			}

			if(mustHitSection)
				mustHitIndicator.x = iconP1.x + iconP1.width/2;
			else
				mustHitIndicator.x = iconP2.x + iconP2.width/2;
		}
		_lastGfSection = isGfSection;
		_lastSec = curSec;
	}

	var playbackSlider:PsychUISlider;

	var mouseSnapCheckBox:PsychUICheckBox;
	var ignoreProgressCheckBox:PsychUICheckBox;
	var hitsoundPlayerStepper:PsychUINumericStepper;
	var hitsoundOpponentStepper:PsychUINumericStepper;
	var metronomeStepper:PsychUINumericStepper;

	var instVolumeStepper:PsychUINumericStepper;
	var instMuteCheckBox:PsychUICheckBox;
	var playerVolumeStepper:PsychUINumericStepper;
	var playerMuteCheckBox:PsychUICheckBox;
	var opponentVolumeStepper:PsychUINumericStepper;
	var opponentMuteCheckBox:PsychUICheckBox;
	function addChartingTab()
	{
		var tab_group = mainBox.getTab('newchartEditor_charting').menu;
		var objX = 10;
		var objY = 10;

		var txt = new EditorsText(objX, objY, 280, Language.get("newchartEditor_any_options_note", "Any options here won't actually affect gameplay!"));
		txt.alignment = CENTER;
		tab_group.add(txt);

		objY += 25;
		playbackSlider = new PsychUISlider(50, objY, function(v:Float) setPitch(playbackRate = v), 1, 0.1, 5.0, 200);
		playbackSlider.label = Language.get('newchartEditor_playback_rate', 'Playback Rate');
		
		objY += 60;
		mouseSnapCheckBox = new PsychUICheckBox(objX, objY, Language.get('newchartEditor_mouse_scroll_snap', 'Mouse Scroll Snap'), 100, function() chartEditorSave.data.mouseScrollSnap = mouseSnapCheckBox.checked);
		mouseSnapCheckBox.checked = chartEditorSave.data.mouseScrollSnap;

		ignoreProgressCheckBox = new PsychUICheckBox(objX + 150, objY, Language.get('newchartEditor_ignore_progress_warnings', 'Ignore Progress Warnings'), 100, function() chartEditorSave.data.ignoreProgressWarns = ignoreProgressCheckBox.checked);
		ignoreProgressCheckBox.checked = chartEditorSave.data.ignoreProgressWarns;

		objY += 50;
		hitsoundPlayerStepper = new PsychUINumericStepper(objX, objY, 0.2, 0, 0, 1, 1);
		hitsoundOpponentStepper = new PsychUINumericStepper(objX + 100, objY, 0.2, 0, 0, 1, 1);
		metronomeStepper = new PsychUINumericStepper(objX + 200, objY, 0.2, 0, 0, 1, 1);

		objY += 50;
		instVolumeStepper = new PsychUINumericStepper(objX, objY, 0.1, 0.6, 0, 1, 1);
		instVolumeStepper.onValueChange = updateAudioVolume;
		playerVolumeStepper = new PsychUINumericStepper(objX + 100, objY, 0.1, 1, 0, 1, 1);
		playerVolumeStepper.onValueChange = updateAudioVolume;
		opponentVolumeStepper = new PsychUINumericStepper(objX + 200, objY, 0.1, 1, 0, 1, 1);
		opponentVolumeStepper.onValueChange = updateAudioVolume;

		objY += 25;
		instMuteCheckBox = new PsychUICheckBox(objX, objY, Language.get('newchartEditor_mute', 'Mute'), 60, updateAudioVolume);
		playerMuteCheckBox = new PsychUICheckBox(objX + 100, objY, Language.get('newchartEditor_mute', 'Mute'), 60, updateAudioVolume);
		opponentMuteCheckBox = new PsychUICheckBox(objX + 200, objY, Language.get('newchartEditor_mute', 'Mute'), 60, updateAudioVolume);

		tab_group.add(playbackSlider);
		tab_group.add(mouseSnapCheckBox);
		tab_group.add(ignoreProgressCheckBox);

		tab_group.add(new EditorsText(hitsoundPlayerStepper.x, hitsoundPlayerStepper.y - 15, 100, Language.get("newchartEditor_hitsound_player", 'Hitsound (Player):')));
		tab_group.add(new EditorsText(hitsoundOpponentStepper.x, hitsoundOpponentStepper.y - 15, 100, Language.get("newchartEditor_hitsound_opponent", 'Hitsound (Opp.):')));
		tab_group.add(new EditorsText(metronomeStepper.x, metronomeStepper.y - 15, 100, Language.get("newchartEditor_metronome", 'Metronome:')));
		tab_group.add(hitsoundPlayerStepper);
		tab_group.add(hitsoundOpponentStepper);
		tab_group.add(metronomeStepper);
		
		tab_group.add(new EditorsText(instVolumeStepper.x, instVolumeStepper.y - 15, 100, Language.get("newchartEditor_inst_volume", 'Inst. Volume:')));
		tab_group.add(new EditorsText(playerVolumeStepper.x, playerVolumeStepper.y - 15, 100, Language.get("newchartEditor_main_vocals", 'Main Vocals:')));
		tab_group.add(new EditorsText(opponentVolumeStepper.x, opponentVolumeStepper.y - 15, 100, Language.get("newchartEditor_opp_vocals", 'Opp. Vocals:')));
		tab_group.add(instVolumeStepper);
		tab_group.add(instMuteCheckBox);
		tab_group.add(playerVolumeStepper);
		tab_group.add(playerMuteCheckBox);
		tab_group.add(opponentVolumeStepper);
		tab_group.add(opponentMuteCheckBox);
	}

	var gameOverCharDropDown:PsychUIDropDownMenu;
	var gameOverSndInputText:PsychUIInputText;
	var gameOverLoopInputText:PsychUIInputText;
	var gameOverRetryInputText:PsychUIInputText;
	var noRGBCheckBox:PsychUICheckBox;
	var noteTextureInputText:PsychUIInputText;
	var noteSplashesInputText:PsychUIInputText;
	function addDataTab()
	{
		var tab_group = mainBox.getTab('newchartEditor_data').menu;
		var objX = 10;
		var objY = 25;
		gameOverCharDropDown = new PsychUIDropDownMenu(objX, objY, [''], function(id:Int, character:String)
		{
			PlayState.SONG.gameOverChar = character;
			if(character.length < 1) Reflect.deleteField(PlayState.SONG, 'gameOverChar');
			TraceManager.debug('trace.editor.characterSelected', 'selected {}', [character]);
		});

		objY += 40;
		gameOverSndInputText = new PsychUIInputText(objX, objY, 120, '', 8);
		gameOverSndInputText.onChange = function(old:String, cur:String)
		{
			PlayState.SONG.gameOverSound = cur;
			if(cur.trim().length < 1) Reflect.deleteField(PlayState.SONG, 'gameOverSound');
		}
		objY += 40;
		gameOverLoopInputText = new PsychUIInputText(objX, objY, 120, '', 8);
		gameOverLoopInputText.onChange = function(old:String, cur:String)
		{
			PlayState.SONG.gameOverLoop = cur;
			if(cur.trim().length < 1) Reflect.deleteField(PlayState.SONG, 'gameOverLoop');
		}
		objY += 40;
		gameOverRetryInputText = new PsychUIInputText(objX, objY, 120, '', 8);
		gameOverRetryInputText.onChange = function(old:String, cur:String)
		{
			PlayState.SONG.gameOverEnd = cur;
			if(cur.trim().length < 1) Reflect.deleteField(PlayState.SONG, 'gameOverEnd');
		}

		objY += 35;
		noRGBCheckBox = new PsychUICheckBox(objX, objY, Language.get('newchartEditor_disable_note_rgb', 'Disable Note RGB'), 100, updateNotesRGB);
		
		objY += 40;
		noteTextureInputText = new PsychUIInputText(objX, objY, 120, '');
		noteTextureInputText.unfocus = function()
		{
			var changed:Bool = false;
			if(PlayState.SONG.arrowSkin != noteTextureInputText.text) changed = true;
			PlayState.SONG.arrowSkin = noteTextureInputText.text.trim();
			if(PlayState.SONG.arrowSkin.trim().length < 1) PlayState.SONG.arrowSkin = null;

			if(changed)
			{
				var textureLoad:String = 'images/${noteTextureInputText.text}.png';
				if(Paths.fileExists(textureLoad, IMAGE) || noteTextureInputText.text.trim() == '')
				{
					for (note in notes)
					{
						if(note == null) continue;
						note.reloadNote(); // 重载当前 arrowSkin (之前误把纹理名传成 prefix)
		
						if(note.width > note.height)
							note.setGraphicSize(GRID_SIZE);
						else
							note.setGraphicSize(0, GRID_SIZE);
		
						note.updateHitbox();
					}
					if(noteTextureInputText.text.trim().length > 0) showOutput('${Language.get('newchartEditor_error_note_texture','Note Texture')}: "$textureLoad"');
					else showOutput('newchartEditor_notes_reloaded_default');
					
				}
				else showOutput('newchartEditor_error_texture_not_found' + '($textureLoad)', true);
			}
		};

		noteSplashesInputText = new PsychUIInputText(objX + 140, objY, 120, '');
		noteSplashesInputText.onChange = function(old:String, cur:String)
		{
			PlayState.SONG.splashSkin = cur;
			if(cur.trim().length < 1) PlayState.SONG.splashSkin = null;
		}
	
		tab_group.add(new EditorsText(gameOverCharDropDown.x, gameOverCharDropDown.y - 15, 120, Language.get('newchartEditor_game_over_character', 'Game Over Character:')));
		tab_group.add(new EditorsText(gameOverSndInputText.x, gameOverSndInputText.y - 15, 180, Language.get('newchartEditor_game_over_death_sound', 'Game Over Death Sound (sounds/):')));
		tab_group.add(new EditorsText(gameOverLoopInputText.x, gameOverLoopInputText.y - 15, 180, Language.get('newchartEditor_game_over_loop_music', 'Game Over Loop Music (music/):')));
		tab_group.add(new EditorsText(gameOverRetryInputText.x, gameOverRetryInputText.y - 15, 180, Language.get('newchartEditor_game_over_retry_music', 'Game Over Retry Music (music/):')));
		tab_group.add(gameOverSndInputText);
		tab_group.add(gameOverLoopInputText);
		tab_group.add(gameOverRetryInputText);
		tab_group.add(noRGBCheckBox);

		tab_group.add(new EditorsText(noteTextureInputText.x, noteTextureInputText.y - 15, 100, Language.get('newchartEditor_note_texture', 'Note Texture:')));
		tab_group.add(new EditorsText(noteSplashesInputText.x, noteSplashesInputText.y - 15, 120, Language.get('newchartEditor_note_splashes_texture', 'Note Splashes Texture:')));
		tab_group.add(noteTextureInputText);
		tab_group.add(noteSplashesInputText);

		tab_group.add(gameOverCharDropDown); //lowest priority to display properly
	}

	var eventDropDown:PsychUIDropDownMenu;
	var value1InputText:PsychUIInputText;
	var value2InputText:PsychUIInputText;
	var selectedEventText:EditorsText;
	var eventDescriptionText:EditorsText;

	var eventsList:Array<Array<String>>;
	var curEventSelected:Int = 0;
	function addEventsTab()
	{
		var tab_group = mainBox.getTab('newchartEditor_events').menu;
		var objX = 10;
		var objY = 25;

		eventDropDown = new PsychUIDropDownMenu(objX, objY, [], function(id:Int, character:String)
		{
			var eventSelected:Array<String> = eventsList[id];
			var eventName:String = eventSelected[0];
			var description:String = eventSelected[1];
			eventDescriptionText.text = description;
			// 多k: 事件改名 (含改为/改掉 Change Mania) -> 记录快照, 改完按工具箱模式重编码
			var oldEvents:Array<Dynamic> = deepCopyEditorEvents();
			if(selectedNotes.length > 1)
			{
				for (note in selectedNotes)
				{
					if(note == null || !note.isEvent) continue;

					var event:EventMetaNote = cast (note, EventMetaNote);
					event.events[event.events.length - 1][0] = eventName;
					event.updateEventText();
				}
			}
			else if(selectedNotes.length == 1 && selectedNotes[0].isEvent)
			{
				var event:EventMetaNote = cast (selectedNotes[0], EventMetaNote);
				event.events[Std.int(FlxMath.bound(curEventSelected, 0, event.events.length - 1))][0] = eventName;
				event.updateEventText();
			}
			refreshAfterManiaEventEdit(oldEvents);
		});

		function genericEventButton(func:EventMetaNote->Void)
		{
			if(selectedNotes.length == 1)
			{
				if(selectedNotes[0].isEvent)
				{
					var event:EventMetaNote = cast (selectedNotes[0], EventMetaNote);
					func(event);
					updateSelectedEventText();
				}
				else showOutput('newchartEditor_error_note_must_be_event', true);
			}
			else showOutput('newchartEditor_error_note_must_select', true);
		}

		var objX2 = 140;
		var removeButton:PsychUIButton = new PsychUIButton(objX2, objY, '-', function()
		{
			genericEventButton(function(event:EventMetaNote)
			{
				// 多k: 删除事件 -> 记录快照, 删除后按工具箱模式重编码
				var oldEvents:Array<Dynamic> = deepCopyEditorEvents();
				if(event.events.length > 1)
				{
					var selectedEvent = event.events[curEventSelected];
					if(selectedEvent != null)
					{
						event.events.remove(selectedEvent);
						event.updateEventText();
						curEventSelected--;
					}
					else showOutput('newchartEditor_error_no_event_selected', true);
				}
				else
				{
					selectedNotes.remove(event);
					events.remove(event);
					curRenderedNotes.remove(event, true);
					addUndoAction(DELETE_NOTE, {events: [event]});
				}
				refreshAfterManiaEventEdit(oldEvents);
			});
		}, 20, Paths.font("editors.ttf"), 12);
		var addButton:PsychUIButton = new PsychUIButton(objX2 + 30, objY, '+', function()
		{
			genericEventButton(function(event:EventMetaNote)
			{
				// 多k: 新增子事件 (可能是 Change Mania) -> 记录快照, 插入后按工具箱模式重编码
				var oldEvents:Array<Dynamic> = deepCopyEditorEvents();
				event.events.push([eventsList[Std.int(Math.max(eventDropDown.selectedIndex, 0))][0], value1InputText.text, value2InputText.text]);
				event.updateEventText();
				curEventSelected++;
				refreshAfterManiaEventEdit(oldEvents);
			});
		}, 20, Paths.font("editors.ttf"), 12);
		var leftButton:PsychUIButton = new PsychUIButton(objX2 + 80, objY, '<', function()
		{
			genericEventButton(function(event:EventMetaNote) curEventSelected = FlxMath.wrap(curEventSelected - 1, 0, event.events.length - 1));
		}, 20, Paths.font("editors.ttf"), 12);
		var rightButton:PsychUIButton = new PsychUIButton(objX2 + 110, objY, '>', function()
		{
			genericEventButton(function(event:EventMetaNote) curEventSelected = FlxMath.wrap(curEventSelected + 1, 0, event.events.length - 1));
		}, 20, Paths.font("editors.ttf"), 12);
		removeButton.normalStyle.bgColor = FlxColor.RED;
		removeButton.normalStyle.textColor = FlxColor.WHITE;
		addButton.normalStyle.bgColor = FlxColor.GREEN;
		addButton.normalStyle.textColor = FlxColor.WHITE;

		selectedEventText = new EditorsText(150, objY + 30, 150, '');
		selectedEventText.visible = false;

		function changeEventsValue(str:String, n:Int)
		{
			if(selectedNotes.length > 1)
			{
				for (note in selectedNotes)
				{
					if(note == null || !note.isEvent) continue;

					var event:EventMetaNote = cast (note, EventMetaNote);
					event.events[event.events.length - 1][n] = str;
					event.updateEventText();
				}
			}
			else if(selectedNotes.length == 1 && selectedNotes[0].isEvent)
			{
				var event:EventMetaNote = cast (selectedNotes[0], EventMetaNote);
				event.events[Std.int(FlxMath.bound(curEventSelected, 0, event.events.length - 1))][n] = str;
				event.updateEventText();
			}
			// 多k: Change Mania 事件改键数 -> 延迟到输入结束再重编码, 避免逐字符中间态
			if (n == 1 && selectedNotes.length == 1 && selectedNotes[0] != null && selectedNotes[0].isEvent)
			{
				var ev:EventMetaNote = cast selectedNotes[0];
				var sub:Dynamic = ev.events[Std.int(FlxMath.bound(curEventSelected, 0, ev.events.length - 1))];
				if (sub != null && Std.string(sub[0]) == 'Change Mania')
					markPendingManiaReencode();
			}
		}

		objY += 70;
		value1InputText = new PsychUIInputText(objX, objY, 120, '', 8);
		value1InputText.onChange = function(old:String, cur:String) changeEventsValue(cur, 1);
		value2InputText = new PsychUIInputText(objX + 150, objY, 120, '', 8);
		value2InputText.onChange = function(old:String, cur:String) changeEventsValue(cur, 2);

		objY += 40;
		eventDescriptionText = new EditorsText(objX, objY, 280, defaultEvents[0][1]);

		tab_group.add(new EditorsText(eventDropDown.x, eventDropDown.y - 15, 80, Language.get('newchartEditor_event', 'Event:')));
		tab_group.add(new EditorsText(value1InputText.x, value1InputText.y - 15, 80, Language.get('newchartEditor_value_1', 'Value 1:')));
		tab_group.add(new EditorsText(value2InputText.x, value2InputText.y - 15, 80, Language.get('newchartEditor_value_2', 'Value 2:')));

		tab_group.add(removeButton);
		tab_group.add(addButton);
		tab_group.add(leftButton);
		tab_group.add(rightButton);
		tab_group.add(selectedEventText);

		tab_group.add(value1InputText);
		tab_group.add(value2InputText);
		tab_group.add(eventDescriptionText);
		
		tab_group.add(eventDropDown); //lowest priority to display properly
	}

	var susLengthLastVal:Float = 0; //used for multiple notes selected
	var susLengthStepper:PsychUINumericStepper;
	var strumTimeStepper:PsychUINumericStepper;
	var noteTypeDropDown:PsychUIDropDownMenu;
	var noteTypes:Array<String>;
	function addNoteTab()
	{
		var tab_group = mainBox.getTab('newchartEditor_note').menu;
		var objX = 10;
		var objY = 25;

		susLengthStepper = new PsychUINumericStepper(objX, objY, Conductor.stepCrochet / 2, 0, 0, Conductor.stepCrochet * 128, 1, 80);
		susLengthStepper.onValueChange = function()
		{
			var halfStep:Float = (Conductor.stepCrochet / 2);
			trace(halfStep, susLengthStepper.value);
			var val:Float = Math.round(susLengthStepper.value / halfStep) * halfStep;
			susLengthStepper.value = val;
			if(susLengthLastVal != susLengthStepper.value)
			{
				if(selectedNotes.length > 1)
				{
					for (note in selectedNotes)
					{
						if(note == null && !note.isEvent) continue;
						note.setSustainLength(note.sustainLength + (susLengthStepper.value - susLengthLastVal), Conductor.stepCrochet, curZoom);
					}
				}
				else if(selectedNotes.length == 1) selectedNotes[0].setSustainLength(susLengthStepper.value, Conductor.stepCrochet, curZoom);
				susLengthLastVal = susLengthStepper.value;
			}
		};

		objY += 40;
		strumTimeStepper = new PsychUINumericStepper(objX, objY, Conductor.stepCrochet, 0, -5000, Math.POSITIVE_INFINITY, 3, 120);
		strumTimeStepper.onValueChange = function()
		{
			if(selectedNotes.length < 1) return;

			var firstTime:Float = selectedNotes[0].strumTime;
			// 多k: 移动 Change Mania 事件位置 -> 记录快照, 移动后按工具箱模式重编码
			var hasManiaEvent:Bool = false;
			for (note in selectedNotes)
				if (note != null && note.isEvent && eventHasChangeMania(cast (note, EventMetaNote))) { hasManiaEvent = true; break; }
			var oldEvents:Array<Dynamic> = hasManiaEvent ? deepCopyEditorEvents() : null;
			for (note in selectedNotes)
			{
				if(note == null) continue;

				note.setStrumTime(Math.max(-5000, strumTimeStepper.value + (note.strumTime - firstTime)));
				positionNoteYOnTime(note, curSec);

				if(note.isEvent)
				{
					cast (note, EventMetaNote).updateEventText();
				}
			}
			softReloadNotes();
			if(oldEvents != null) refreshAfterManiaEventEdit(oldEvents);
		};
		
		objY += 40;
		noteTypeDropDown = new PsychUIDropDownMenu(objX, objY, [], function(id:Int, changeToType:String)
		{
			var newSelected:Array<MetaNote> = [];
			var typeSelected:String = noteTypes[id].trim();
			for (note in selectedNotes)
			{
				if(note == null || note.isEvent) continue;

				if(typeSelected != null && typeSelected.length > 0)
					note.songData[3] = typeSelected;
				else
					note.songData.remove(note.songData[3]);

				var id:Int = notes.indexOf(note);
				if(id > -1)
				{
					notes[id] = createNote(note.songData, curSec);
					actionReplaceNotes(note, notes[id]);
					newSelected.push(notes[id]);
					note.destroy();
				}
			}
			selectedNotes = newSelected;
			softReloadNotes();
		}, 150);
		
		tab_group.add(new EditorsText(susLengthStepper.x, susLengthStepper.y - 15, 80, Language.get('newchartEditor_sustain_length', 'Sustain length:')));
		tab_group.add(new EditorsText(strumTimeStepper.x, strumTimeStepper.y - 15, 100, Language.get('newchartEditor_note_hit_time', 'Note Hit time (ms):')));
		tab_group.add(new EditorsText(noteTypeDropDown.x, noteTypeDropDown.y - 15, 80, Language.get('newchartEditor_note_type', 'Note Type:')));
		tab_group.add(susLengthStepper);
		tab_group.add(strumTimeStepper);
		tab_group.add(noteTypeDropDown);
	}

	var mustHitCheckBox:PsychUICheckBox;
	var gfSectionCheckBox:PsychUICheckBox;
	var altAnimSectionCheckBox:PsychUICheckBox;

	var changeBpmCheckBox:PsychUICheckBox;
	var changeBpmStepper:PsychUINumericStepper;
	var beatsPerSecStepper:PsychUINumericStepper;

	function addSectionTab()
	{
		var affectNotes:PsychUICheckBox = null;
		var affectEvents:PsychUICheckBox = null;
		var copyLastSecStepper:PsychUINumericStepper = null;
		var tab_group = mainBox.getTab('newchartEditor_section').menu;
		var objX = 10;
		var objY = 10;
		function copyNotesOnSection(?secOff:Int = 0, ?showMessage:Bool = true) //Used on "Copy Section" and "Copy Last Section" buttons
		{
			var curSectionTime:Null<Float> = cachedSectionTimes[curSec - secOff];
			if(curSectionTime == null)
			{
				//showOutput('ERROR: Unknown section??', true);
				return;
			}

			var nextSectionTime:Null<Float> = cachedSectionTimes[curSec - secOff + 1];
			if(nextSectionTime == null) nextSectionTime = Math.POSITIVE_INFINITY;

			var notesCopyNum:Int = 0;
			if(affectNotes.checked)
			{
				copiedNotes = [];
				for (note in notes)
				{
					if(note.strumTime >= curSectionTime && note.strumTime < nextSectionTime)
					{
						var dataCopy:Array<Dynamic> = makeNoteDataCopy(note.songData, false);
						dataCopy[0] = note.strumTime - curSectionTime;
						copiedNotes.push(dataCopy);
						notesCopyNum++;
					}
				}
			}

			var eventsCopyNum:Int = 0;
			if(affectEvents.checked)
			{
				copiedEvents = [];
				for (event in events)
				{
					if(event.strumTime >= curSectionTime && event.strumTime < nextSectionTime)
					{
						var dataCopy:Array<Dynamic> = makeNoteDataCopy(event.songData, true);
						dataCopy[0] = event.strumTime - curSectionTime;
						copiedEvents.push(dataCopy);
						eventsCopyNum++;
					}
				}
			}

			if(showMessage)
			{
				if(notesCopyNum == 0 && eventsCopyNum == 0)
				{
					showOutput('newchartEditor_nothing_to_copy');
					return;
				}

				var str:String = '';
				if(notesCopyNum > 0) str += '${Language.get("newchartEditor_notes_copied",'Notes Copied')}: $notesCopyNum';
				if(eventsCopyNum > 0)
				{
					if(str.length > 0) str += '\n';
					str += '${Language.get("newchartEditor_events_copied",'Events Copied')}: $eventsCopyNum';
				}
	
				if(str.length > 0) showOutput(str);
			}
		}

		mustHitCheckBox = new PsychUICheckBox(objX, objY, Language.get('newchartEditor_must_hit_sec', 'Must Hit Sec.'), 70, function()
		{
			var sec = getCurChartSection();
			if(sec != null) sec.mustHitSection = mustHitCheckBox.checked;
			updateHeads(true);
		});
		gfSectionCheckBox = new PsychUICheckBox(objX + 100, objY, Language.get('newchartEditor_gf_section', 'GF Section'), 70, function()
		{
			var sec = getCurChartSection();
			if(sec != null) sec.gfSection = gfSectionCheckBox.checked;
			updateHeads(true);
		});
		altAnimSectionCheckBox = new PsychUICheckBox(objX + 200, objY, Language.get('newchartEditor_alt_anim', 'Alt Anim'), 70, function()
		{
			var sec = getCurChartSection();
			if(sec != null) sec.altAnim = altAnimSectionCheckBox.checked;
		});

		objY += 40;
		changeBpmCheckBox = new PsychUICheckBox(objX, objY, Language.get('newchartEditor_change_bpm', 'Change BPM'), 80, function()
		{
			var sec = getCurChartSection();
			if(sec != null)
			{
				var oldTimes:Array<Float> = cachedSectionTimes.copy();
				sec.changeBPM = changeBpmCheckBox.checked;
				if(!Reflect.hasField(sec, 'bpm')) sec.bpm = changeBpmStepper.value;
				adaptNotesToNewTimes(oldTimes);
			}
		});

		objY += 25;
		changeBpmStepper = new PsychUINumericStepper(objX, objY, 1, 0, 1, 400, 3);
		changeBpmStepper.onValueChange = function()
		{
			var sec = getCurChartSection();
			if(sec != null)
			{
				var oldTimes:Array<Float> = cachedSectionTimes.copy();
				sec.bpm = changeBpmStepper.value;
				sec.changeBPM = true;
				changeBpmCheckBox.checked = true;
				adaptNotesToNewTimes(oldTimes);
			}
		};

		beatsPerSecStepper = new PsychUINumericStepper(objX + 150, objY, 1, 4, 1, 16, 2);
		beatsPerSecStepper.onValueChange = function()
		{
			beatsPerSecStepper.value = Math.round(beatsPerSecStepper.value * 4) / 4;
			var sec = getCurChartSection();
			if(sec != null)
			{
				var oldTimes:Array<Float> = cachedSectionTimes.copy();
				sec.sectionBeats = beatsPerSecStepper.value;
				adaptNotesToNewTimes(oldTimes);
			}
		};

		objY += 40;
		var copyButton:PsychUIButton = new PsychUIButton(objX, objY, 'newchartEditor_copy_section', copyNotesOnSection.bind());
		var pasteButton:PsychUIButton = new PsychUIButton(objX + 100, objY, 'newchartEditor_paste_section', function()
		{
			pasteCopiedNotesToSection(affectNotes.checked, affectEvents.checked);
		});
		var clearButton:PsychUIButton = new PsychUIButton(objX + 200, objY, 'newchartEditor_clear', function()
		{
			for (note in curRenderedNotes)
			{
				if(note == null) continue;

				if(!note.isEvent && affectNotes.checked)
					notes.remove(note);
				if(note.isEvent && affectEvents.checked)
					events.remove(cast (note, EventMetaNote));

				selectedNotes.remove(note);
			}
			softReloadNotes(true);
		});
		clearButton.normalStyle.bgColor = FlxColor.RED;
		clearButton.normalStyle.textColor = FlxColor.WHITE;

		objY += 25;
		affectNotes = new PsychUICheckBox(objX, objY, Language.get('newchartEditor_notes', 'Notes'), 60);
		affectNotes.checked = true;
		affectEvents = new PsychUICheckBox(objX + 100, objY, Language.get('newchartEditor_events', 'Events'), 60);

		objY += 32;
		var copyLastSecButton:PsychUIButton = new PsychUIButton(objX, objY, 'newchartEditor_copy_last_section', function()
		{
			var lastCopiedNotes = copiedNotes;
			var lastCopiedEvents = copiedEvents;
			copyNotesOnSection(Std.int(copyLastSecStepper.value), false);
			pasteCopiedNotesToSection(affectNotes.checked, affectEvents.checked);
			copiedNotes = lastCopiedNotes;
			copiedEvents = lastCopiedEvents;
		});
		copyLastSecButton.resize(80, 26);
		copyLastSecStepper = new PsychUINumericStepper(objX + 110, objY + 2, 1, 1, -999, 999, 0);
		
		objY += 40;
		var swapSectionButton:PsychUIButton = new PsychUIButton(objX, objY, 'newchartEditor_swap_section', function()
		{
			var maxData:Int = GRID_COLUMNS_PER_PLAYER * GRID_PLAYERS;
			for (note in curRenderedNotes)
			{
				if(note != null && !note.isEvent)
				{
					var data:Int = note.songData[1] + GRID_COLUMNS_PER_PLAYER;
					if(data >= maxData) data -= maxData;
					note.changeNoteData(data);
					positionNoteXByData(note);
				}
			}
			softReloadNotes(true);
		});
		var duetSectionButton:PsychUIButton = new PsychUIButton(objX + 100, objY, 'newchartEditor_duet_section', function()
		{
			var side:Int = -1;
			for (note in curRenderedNotes.members)
			{
				if(note == null || note.isEvent) continue;

				//First figure out if there are notes on more than one player's sides to cancel operation early
				if(side > -1)
				{
					if(Math.floor(note.songData[1] / GRID_COLUMNS_PER_PLAYER) != side)
					{
						showOutput('newchartEditor_error_cannot_duet');
						return;
					}
				}
				else side = Math.floor(note.songData[1] / GRID_COLUMNS_PER_PLAYER);
			}

			var pushedNotes:Array<MetaNote> = [];
			for (note in curRenderedNotes.members)
			{
				if(note == null || note.isEvent) continue;

				for (i in 0...GRID_PLAYERS)
				{
					if(i == side) continue;

					var songDataCopy:Array<Dynamic> = note.songData.copy();
					songDataCopy[1] = note.noteData + i * GRID_COLUMNS_PER_PLAYER;
					var newNote = createNote(songDataCopy);
					notes.push(newNote);
					pushedNotes.push(newNote);
				}
			}
			notes.sort(PlayState.sortByTime);
			softReloadNotes(true);
			
			addUndoAction(ADD_NOTE, {notes: pushedNotes});
		});
		var mirrorNotesButton:PsychUIButton = new PsychUIButton(objX + 200, objY, 'newchartEditor_mirror_notes', function()
		{
			var maxData:Int = GRID_COLUMNS_PER_PLAYER * GRID_PLAYERS;
			for (note in curRenderedNotes)
			{
				if(note == null || note.isEvent) continue;

				var data:Int = Std.int(note.songData[1]);
				note.changeNoteData((Math.floor(data / GRID_COLUMNS_PER_PLAYER) * GRID_COLUMNS_PER_PLAYER) + GRID_COLUMNS_PER_PLAYER - note.noteData - 1);
				positionNoteXByData(note);
			}
			softReloadNotes(true);
		});

		tab_group.add(mustHitCheckBox);
		tab_group.add(gfSectionCheckBox);
		tab_group.add(altAnimSectionCheckBox);

		tab_group.add(new EditorsText(beatsPerSecStepper.x, beatsPerSecStepper.y - 15, 100, Language.get('newchartEditor_beats_per_section', 'Beats per Section:')));
		tab_group.add(changeBpmCheckBox);
		tab_group.add(changeBpmStepper);
		tab_group.add(beatsPerSecStepper);
		
		tab_group.add(copyButton);
		tab_group.add(pasteButton);
		tab_group.add(clearButton);
		tab_group.add(affectNotes);
		tab_group.add(affectEvents);

		tab_group.add(copyLastSecButton);
		tab_group.add(copyLastSecStepper);

		tab_group.add(swapSectionButton);
		tab_group.add(duetSectionButton);
		tab_group.add(mirrorNotesButton);
	}

	function reloadNotesDropdowns()
	{
		// Event drop down
		if(eventDropDown != null)
		{
			eventsList = [];
			var eventFiles:Array<String> = loadFileList('custom_events/', null, ['.txt']);
			for (file in eventFiles)
			{
				var desc:String;
				try {
					desc = Paths.getTextFromFile('custom_events/$file.txt');
				} catch(e:Dynamic) {
					desc = Language.get('newchartEditor_custom_event_desc', 'Custom event, no description available.');
				}
				eventsList.push([file, desc]);
			}

			for (id => event in defaultEvents)
				if(!eventsList.contains(event))
					eventsList.insert(id, event);
			
			var displayEventsList:Array<String> = [];
			for (id => data in eventsList)
			{
				if(id > 0)
					displayEventsList[id] = '$id. ${data[0]}';
				else
					displayEventsList.push('');
			}

			var lastSelected:String = eventDropDown.selectedLabel;
			eventDropDown.list = displayEventsList;
			eventDropDown.maxItems = 12;
			eventDropDown.selectedLabel = lastSelected;
		}


		// Note type drop down
		if(noteTypeDropDown != null)
		{
			var exts:Array<String> = ['.txt'];
			#if LUA_ALLOWED exts.push('.lua'); #end
			#if HSCRIPT_ALLOWED exts.push('.hx'); #end
			noteTypes = loadFileList('custom_notetypes/', null, exts);
			for (id => noteType in noteTypeList)
				if(!noteTypes.contains(noteType))
					noteTypes.insert(id, noteType);

			if(Song.chartPath != null && Song.chartPath.length > 0)
			{
				var parentFolder:String = Song.chartPath.replace('\\', '/');
				parentFolder = parentFolder.substr(0, Song.chartPath.lastIndexOf('/')+1);
				var notetypeFile:Array<String> = CoolUtil.coolTextFile(parentFolder + 'notetypes.txt');
				if(notetypeFile.length > 0)
				{
					for (ntTyp in notetypeFile)
					{
						var name:String = ntTyp.trim();
						if(!noteTypes.contains(name))
							noteTypes.push(name);
					}
				}
			}
			
			var displayNoteTypes:Array<String> = noteTypes.copy();
			for (id => key in displayNoteTypes)
			{
				if(id == 0) continue;
				displayNoteTypes[id] = '$id. $key';
			}
			
			var lastSelected:String = noteTypeDropDown.selectedLabel;
			noteTypeDropDown.list = displayNoteTypes;
			noteTypeDropDown.maxItems = 12;
			noteTypeDropDown.selectedLabel = lastSelected;
		}
	}

	function pasteCopiedNotesToSection(?canCopyNotes:Bool = true, ?canCopyEvents:Bool = true, ?showMessage:Bool = true) //Used on "Paste Section" and "Copy Last Section" buttons
	{
		var curSectionTime:Null<Float> = cachedSectionTimes[curSec];
		if(curSectionTime == null)
		{
			showOutput('newchartEditor_error_unknown_section', true);
			return [];
		}

		var pushedNotes:Array<MetaNote> = [];
		var nts:Array<MetaNote> = [];
		var evs:Array<EventMetaNote> = [];
		// 多k: 粘贴 Change Mania 事件 -> 记录快照, 粘贴后按工具箱模式重编码
		var oldEvents:Array<Dynamic> = null;
		if(canCopyEvents && copiedEvents.length > 0)
		{
			for (ev in copiedEvents)
			{
				if (ev == null || ev[1] == null) continue;
				var subs:Array<Dynamic> = cast ev[1];
				for (sub in subs)
					if (sub != null && Std.string(sub[0]) == 'Change Mania') { oldEvents = deepCopyEditorEvents(); break; }
				if (oldEvents != null) break;
			}
		}
		if(canCopyNotes && copiedNotes.length > 0)
		{
			for (note in copiedNotes)
			{
				if(note == null) continue;
				var dataCopy:Array<Dynamic> = makeNoteDataCopy(note, false);
				dataCopy[0] += curSectionTime;

				var createdNote = createNote(dataCopy, curSec);
				notes.push(createdNote);
				pushedNotes.push(createdNote);
				nts.push(createdNote);
			}
			notes.sort(PlayState.sortByTime);
		}

		if(canCopyEvents && copiedEvents.length > 0)
		{
			for (event in copiedEvents)
			{
				if(event == null) continue;
				var dataCopy:Array<Dynamic> = makeNoteDataCopy(event, true);
				dataCopy[0] += curSectionTime;

				var createdEvent = createEvent(dataCopy);
				events.push(createdEvent);
				pushedNotes.push(createdEvent);
				evs.push(createdEvent);
			}
			events.sort(PlayState.sortByTime);
		}
		if(oldEvents != null) refreshAfterManiaEventEdit(oldEvents);
		loadSection();
		
		if(showMessage)
		{
			if(nts.length == 0 && evs.length == 0)
			{
				showOutput('newchartEditor_nothing_to_paste', true);
				return [];
			}

			var str:String = '';
			if(nts.length > 0) str += '${Language.get("newchartEditor_notes_added",'Notes Added')}: ${nts.length}';
			if(evs.length > 0)
			{
				if(str.length > 0) str += '\n';
				str += '${Language.get("newchartEditor_events_added",'Events Added')}: ${evs.length}';
			}

			if(str.length > 0) showOutput(str);
		}
		addUndoAction(ADD_NOTE, {notes: nts, events: evs});
		return pushedNotes;
	}

	var songNameInputText:PsychUIInputText;
	var allowVocalsCheckBox:PsychUICheckBox;

	var bpmStepper:PsychUINumericStepper;
	var scrollSpeedStepper:PsychUINumericStepper;
	var audioOffsetStepper:PsychUINumericStepper;
	var maniaStepper:PsychUINumericStepper;
	/** Key conversion mode. */
	var convertModeDropDown:PsychUIDropDownMenu;
	var stageDropDown:PsychUIDropDownMenu;
	var playerDropDown:PsychUIDropDownMenu;
	var opponentDropDown:PsychUIDropDownMenu;
	var girlfriendDropDown:PsychUIDropDownMenu;
	
	function addSongTab()
	{
		var tab_group = mainBox.getTab('newchartEditor_song').menu;
		var objX = 10;
		var objY = 25;

		songNameInputText = new PsychUIInputText(objX, objY, 100, 'None', 8);
		songNameInputText.onChange = function(old:String, cur:String) PlayState.SONG.song = cur;

		allowVocalsCheckBox = new PsychUICheckBox(objX, objY + 20, Language.get('newchartEditor_allow_vocals', 'Allow Vocals'), 80, function()
		{
			PlayState.SONG.needsVoices = allowVocalsCheckBox.checked;
			loadMusic();
		});
		var reloadAudioButton:PsychUIButton = new PsychUIButton(objX + 120, objY, 'newchartEditor_reload_audio', function() loadMusic(true), 80);

		#if mac
		var reloadJsonButton:PsychUIButton = new PsychUIButton(objX + 205, objY, 'newchartEditor_reload_json', function()
		{
			var cur = Paths.formatToSongPath(songNameInputText.text);
			var curdiff = Highscore.formatSong(cur, PlayState.storyDifficulty);
			var diff = false;
			var loadedChart:SwagSong = try {
				diff = true;
				Song.getChart(curdiff, cur);
			} catch (e) {
				diff = false;
				Song.getChart(cur, cur);
			}
			if(loadedChart == null || !Reflect.hasField(loadedChart, 'song'))
			{
				showOutput('newchartEditor_error_file_not_chart', true);
				return;
			}

			var func:Void->Void = function()
			{
				loadChart(loadedChart);
				Song.chartPath = diff ? curdiff : cur;
				reloadNotesDropdowns();
				prepareReload();
				showOutput('newchartEditor_chart_opened', false, [diff ? curdiff : cur]);
			}
					
			if(!ignoreProgressCheckBox.checked) openSubState(new Prompt('Warning: Any unsaved progress\nwill be lost.', func));
			else func();
		}, 80);
		#end

		objY += 65;
		bpmStepper = new PsychUINumericStepper(objX, objY, 1, 1, 1, 400, 3);
		bpmStepper.onValueChange = function()
		{
			var oldTimes:Array<Float> = cachedSectionTimes.copy();
			PlayState.SONG.bpm = bpmStepper.value;
			adaptNotesToNewTimes(oldTimes);
		};

		scrollSpeedStepper = new PsychUINumericStepper(objX + 90, objY, 0.1, 1, 0.1, 10, 2);
		scrollSpeedStepper.onValueChange = function() PlayState.SONG.speed = scrollSpeedStepper.value;

		audioOffsetStepper = new PsychUINumericStepper(objX + 180, objY, 1, 0, -500, 500, 0);
		audioOffsetStepper.onValueChange = function()
		{
			PlayState.SONG.offset = audioOffsetStepper.value;
			Conductor.offset = audioOffsetStepper.value;
			updateWaveform();
		};

		// 键数 (显示 1-18, 内部 mania = 值-1): 作为整张谱面的单一键数映射保留
		maniaStepper = new PsychUINumericStepper(objX, objY + 40, 1, (PlayState.SONG.mania != null ? PlayState.SONG.mania : Note.defaultMania) + 1, 1, Note.maxMania + 1, 0, 45);
		// Key conversion mode: sequential / shuffle / auto-double / shuffle+double.
		convertModeDropDown = new PsychUIDropDownMenu(objX + 55, objY + 40, [
			Language.get('newchartEditor_convert_sequential', '顺序映射'),
			Language.get('newchartEditor_convert_shuffle', '自动打乱'),
			Language.get('newchartEditor_convert_double', '自动补双押'),
			Language.get('newchartEditor_convert_shuffle_double', '打乱+双押')
		], function(id:Int, label:String) {}, 110);
		convertModeDropDown.selectedIndex = 0;
		maniaStepper.onValueChange = function()
		{
			var newMania:Int = EKData.clampMania(Std.int(maniaStepper.value) - 1);
			if (previewMania >= 0) previewMania = -1; // 手动切 K: 退出事件预览模式
			if (PlayState.SONG.mania != null && newMania == PlayState.SONG.mania) return; // 防抖
			var oldMania:Int = (PlayState.SONG.mania != null) ? EKData.clampMania(PlayState.SONG.mania) : Note.defaultMania;
			_cacheSections(); // 先刷新 section 缓存, 避免转换/重排使用过期时间表
			convertChartNoteData(oldMania, newMania, (convertModeDropDown != null) ? convertModeDropDown.selectedIndex : 0);
			PlayState.SONG.mania = newMania;
			PlayState.mania = EKData.clampMania(PlayState.SONG.mania);
			GRID_COLUMNS_PER_PLAYER = Note.ammo[PlayState.mania];
			GRID_SIZE = editorGridSize(PlayState.mania);
			TraceManager.info('trace.editor.mania2', 'Change mania -> {} (stepper={}) membersBefore={}', [newMania, maniaStepper.value, members.length]);
			try
			{
				createGrids(false); // 不重复 loadSection (reloadNotes 内部以 loadSection 收尾)
				rebuildStrumNotes();
				repositionEditorUI();
				updateGridVisibility();
				updateNotesForMania(); // 复用现有 Note 快速更新, 物量大谱面切 K 不重建不卡顿
				updateHeads(true);
				updateScrollY();
			}
			catch (e:Dynamic)
			{
				TraceManager.error('trace.editor.maniaError', '切换键数时出错: {}', [Std.string(e)]);
			}
			TraceManager.info('trace.editor.maniaAfter2', 'membersAfter={}', [members.length]);
			markUnsaved();
		};

		tab_group.add(new EditorsText(songNameInputText.x, songNameInputText.y - 15, 80, Language.get('newchartEditor_song_name', 'Song Name:')));
		tab_group.add(songNameInputText);
		tab_group.add(allowVocalsCheckBox);
		tab_group.add(reloadAudioButton);
		#if mac
		tab_group.add(reloadJsonButton);
		#end

		objY += 80;
		
		var characters:Array<String> = loadFileList('characters/', 'data/characterList.txt');
		
		playerDropDown = new PsychUIDropDownMenu(objX, objY, characters, function(id:Int, character:String)
		{
			PlayState.SONG.player1 = character;
			updateJsonData();
			updateHeads(true);
			loadMusic();
			TraceManager.debug('trace.editor.characterSelected', 'selected {}', [character]);
		});
		
		stageDropDown = new PsychUIDropDownMenu(objX + 140, objY, loadFileList('stages/', 'data/stageList.txt'), function(id:Int, stage:String)
		{
			PlayState.SONG.stage = stage;
			StageData.loadDirectory(PlayState.SONG);
			// Update pixel stage flag from the stage file, then reload note textures
			var sf = StageData.getStageFile(stage);
			if(sf != null) PlayState.isPixelStage = sf.isPixelStage;
			MetaNote.clearStaticCache();
			reloadNotes();
			TraceManager.debug('trace.editor.stageSelected', 'selected {}', [stage]);
		});
		
		opponentDropDown = new PsychUIDropDownMenu(objX, objY + 40, characters, function(id:Int, character:String)
		{
			PlayState.SONG.player2 = character;
			updateJsonData();
			updateHeads(true);
			loadMusic();
			TraceManager.debug('trace.editor.characterSelected', 'selected {}', [character]);
		});
		
		girlfriendDropDown = new PsychUIDropDownMenu(objX, objY + 80, characters, function(id:Int, character:String)
		{
			PlayState.SONG.gfVersion = character;
			TraceManager.debug('trace.editor.characterSelected', 'selected {}', [character]);
		});
		
		playerDropDown.selectedLabel = PlayState.SONG.player1;
		opponentDropDown.selectedLabel = PlayState.SONG.player2;
		girlfriendDropDown.selectedLabel = PlayState.SONG.gfVersion;
		stageDropDown.selectedLabel = PlayState.SONG.stage;
		playerDropDown.maxItems = 12; // 角色/舞台列表可能很长, 窗口化展开避免面板超出屏幕
		opponentDropDown.maxItems = 12;
		girlfriendDropDown.maxItems = 12;
		stageDropDown.maxItems = 12;

		tab_group.add(new EditorsText(bpmStepper.x, bpmStepper.y - 15, 50, Language.get('newchartEditor_bpm', 'BPM:')));
		tab_group.add(new EditorsText(scrollSpeedStepper.x, scrollSpeedStepper.y - 15, 80, Language.get('newchartEditor_scroll_speed', 'Scroll Speed:')));
		tab_group.add(new EditorsText(audioOffsetStepper.x, audioOffsetStepper.y - 15, 100, Language.get('newchartEditor_audio_offset', 'Audio Offset (ms):')));
		tab_group.add(new EditorsText(maniaStepper.x, maniaStepper.y - 15, 80, Language.get('newchartEditor_keys', 'Keys (1-18):')));
		tab_group.add(bpmStepper);
		tab_group.add(scrollSpeedStepper);
		tab_group.add(audioOffsetStepper);
		tab_group.add(maniaStepper);

		tab_group.add(new EditorsText(stageDropDown.x, stageDropDown.y - 15, 80, Language.get('newchartEditor_stage', 'Stage:')));
		tab_group.add(new EditorsText(playerDropDown.x, playerDropDown.y - 15, 80, Language.get('newchartEditor_player', 'Player:')));
		tab_group.add(new EditorsText(opponentDropDown.x, opponentDropDown.y - 15, 80, Language.get('newchartEditor_opponent', 'Opponent:')));
		tab_group.add(new EditorsText(girlfriendDropDown.x, girlfriendDropDown.y - 15, 80, Language.get('newchartEditor_girlfriend', 'Girlfriend:')));
		tab_group.add(stageDropDown);
		tab_group.add(girlfriendDropDown);
		tab_group.add(opponentDropDown);
		tab_group.add(playerDropDown);
		tab_group.add(convertModeDropDown);
	}

	// ========================================================================
	//  EXTERNAL CHART IMPORT (osu! / Malody / OSZ / MCZ)
	// ========================================================================

	function finishOpenChart(loadedChart:SwagSong, filePath:String):Void
	{
		if (loadedChart == null || !Reflect.hasField(loadedChart, 'song'))
		{
			showOutput('newchartEditor_error_file_not_chart', true);
			return;
		}

		var func:Void->Void = function()
		{
			loadChart(loadedChart);
			Song.chartPath = filePath;
			reloadNotesDropdowns();
			prepareReload();
			showOutput('newchartEditor_chart_opened', false, [Song.chartPath]);
		}

		if(!ignoreProgressCheckBox.checked) openSubState(new Prompt('newchartEditor_warning_unsaved_progress', func));
		else func();
	}

	/**
	 * Shows the import options prompt (music + key mapping) for an external
	 * chart, then converts and loads it. format: 0 = osu, 1 = malody.
	 */
	function promptExternalChartImport(rawText:String, format:Int, sourcePath:String, ?audioBytes:haxe.io.Bytes, ?audioName:String):Void
	{
		var audioRef:String = audioName;
		if (audioRef == null || audioRef.length == 0)
			audioRef = OsuMalodyConvert.chartAudioName(rawText, format);

		var hasAudio:Bool = (audioBytes != null) || (OsuMalodyConvert.findAdjacentAudio(sourcePath, audioRef) != null);

		ClientPrefs.toggleVolumeKeys(false);

		var musicCheck:PsychUICheckBox = new PsychUICheckBox(0, 0, Language.get('newchartEditor_import_music', 'Import music'), 240);
		musicCheck.checked = hasAudio;

		var destNames:Array<String> = [
			Language.get('newchartEditor_music_dest_disk', 'To disk (mods/songs/)'),
			Language.get('newchartEditor_music_dest_ram', 'Load into RAM only')
		];
		var destGrp:PsychUIRadioGroup = new PsychUIRadioGroup(0, 0, destNames, 20, 5, false, 260);
		destGrp.checked = 0;

		var mapNames:Array<String> = [
			Language.get('newchartEditor_map_auto', 'Keep original K'),
			Language.get('newchartEditor_map_4k', 'Compress to 4K'),
			Language.get('newchartEditor_map_8k', 'Split 4K + Opponent'),
			Language.get('newchartEditor_map_custom', 'Custom K')
		];
		var mapGrp:PsychUIRadioGroup = new PsychUIRadioGroup(0, 0, mapNames, 24, 5, false, 260);
		mapGrp.checked = 0;
		// 自定义键数默认跟随源谱面实际 K (避免玩家选"自定义"后不改数字被默认 4 压成 4K)
		var srcK:Int = (format == 0)
			? OsuMalodyConvert.osuKeyCount(rawText)
			: OsuMalodyConvert.malodyKeyCount(rawText);
		if (srcK < 1) srcK = 4;
		var customStepper:PsychUINumericStepper = new PsychUINumericStepper(0, 0, 1, srcK, 1, 18, 0, 60);

		openSubState(new BasePrompt(520, 400, Language.get('newchartEditor_import_options', 'Import Options...'), function(state:BasePrompt)
		{
			musicCheck.x = state.bg.x + 30;
			musicCheck.y = state.bg.y + 40;
			musicCheck.cameras = state.cameras;
			state.add(musicCheck);

			destGrp.x = state.bg.x + 30;
			destGrp.y = state.bg.y + 70;
			destGrp.cameras = state.cameras;
			state.add(destGrp);

			var ramWarn:EditorsText = new EditorsText(state.bg.x + 30, state.bg.y + 118, 460,
				Language.get('newchartEditor_ram_warning', 'RAM mode: session only, lost on restart, uses memory!'));
			ramWarn.cameras = state.cameras;
			ramWarn.color = FlxColor.YELLOW;
			state.add(ramWarn);

			var mapTxt:EditorsText = new EditorsText(state.bg.x + 30, state.bg.y + 146, 200, Language.get('newchartEditor_key_mapping', 'Key mapping:'));
			mapTxt.cameras = state.cameras;
			state.add(mapTxt);

			var detectedTxt:EditorsText = new EditorsText(state.bg.x + 210, state.bg.y + 146, 280,
				Language.get('newchartEditor_detected_k', 'Detected source: %sK').replace('%s', Std.string(srcK)));
			detectedTxt.cameras = state.cameras;
			detectedTxt.color = FlxColor.fromRGB(140, 220, 140);
			state.add(detectedTxt);

			mapGrp.x = state.bg.x + 30;
			mapGrp.y = state.bg.y + 166;
			mapGrp.cameras = state.cameras;
			state.add(mapGrp);

			var customTxt:EditorsText = new EditorsText(state.bg.x + 30, state.bg.y + 254, 130, Language.get('newchartEditor_custom_k', 'Custom K:'));
			customTxt.cameras = state.cameras;
			state.add(customTxt);

			customStepper.x = state.bg.x + 130;
			customStepper.y = state.bg.y + 248;
			customStepper.cameras = state.cameras;
			state.add(customStepper);

			var btnY:Float = state.bg.y + state.bg.height - 45;
			var saveBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_save_btn', 'Save'), function()
			{
				var mapMode:Int = mapGrp.checked;
				var customK:Int = Std.int(customStepper.value);
				var doMusic:Bool = musicCheck.checked;
				state.close();

				haxe.Timer.delay(function()
				{
					try
					{
						var loadedChart:SwagSong = (format == 0)
							? OsuMalodyConvert.osuToPsych(rawText, mapMode, customK)
							: OsuMalodyConvert.malodyToPsych(rawText, mapMode, customK);
						loadedChart.format = "psych_v1_convert";

						if (doMusic)
						{
							var imported:Bool = false;
							var useRam:Bool = (destGrp.checked == 1);

							// RAM mode: decode straight into memory, no file written
							if (useRam)
							{
								var ramBytes:haxe.io.Bytes = audioBytes;
								if (ramBytes == null)
								{
									var adj:String = OsuMalodyConvert.findAdjacentAudio(sourcePath, audioRef);
									#if sys
									if (adj != null && sys.FileSystem.exists(adj))
										ramBytes = sys.io.File.getBytes(adj);
									#end
								}
								if (ramBytes != null)
								{
									var ramExt:String = 'ogg';
									if (audioRef != null && audioRef.length > 0)
									{
										var rdot:Int = audioRef.lastIndexOf('.');
										if (rdot > 0) ramExt = audioRef.substr(rdot + 1).toLowerCase();
									}
									imported = importSongAudioToRam(loadedChart.song, ramBytes, ramExt);
								}
							}
							else
							{
								if (audioBytes != null)
								{
									var ext:String = 'ogg';
									if (audioRef != null && audioRef.length > 0)
									{
										var dot:Int = audioRef.lastIndexOf('.');
										if (dot > 0) ext = audioRef.substr(dot + 1).toLowerCase();
									}
									imported = importSongAudio(loadedChart.song, audioBytes, null, ext);
								}
								else
								{
									var adj:String = OsuMalodyConvert.findAdjacentAudio(sourcePath, audioRef);
									if (adj != null) imported = importSongAudio(loadedChart.song, null, adj);
								}
							}

							if (imported && useRam)
								showOutput('newchartEditor_music_loaded_ram', false, [loadedChart.song]);
							else if (imported) {
								#if MODS_ALLOWED
								showOutput('newchartEditor_music_imported', false, [Paths.mods('songs/' + Paths.formatToSongPath(loadedChart.song))]);
								#else
								showOutput('newchartEditor_music_imported', false, ['songs/' + Paths.formatToSongPath(loadedChart.song)]);
								#end
							}
							else
								showOutput('newchartEditor_music_not_found', true);
						}

						finishOpenChart(loadedChart, sourcePath);
					}
					catch(e:Dynamic)
					{
						// hxcpp 底层文件错误(如 fopen 失败)抛的是普通值, 不是 Exception 实例
						showOutput('newchartEditor_error', true, [Std.string(e)]);
						TraceManager.error('trace.editor.exception', 'Exception: {}', [Std.string(e)]);
					}
				}, 400);
			});
			saveBtn.screenCenter(X);
			saveBtn.x -= 80;
			saveBtn.cameras = state.cameras;
			saveBtn.normalStyle.bgColor = FlxColor.GREEN;
			saveBtn.normalStyle.textColor = FlxColor.WHITE;
			state.add(saveBtn);

			var cancelBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_cancel_btn', 'Cancel'), function()
			{
				state.close();
			});
			cancelBtn.screenCenter(X);
			cancelBtn.x += 80;
			cancelBtn.cameras = state.cameras;
			state.add(cancelBtn);
		}));
	}

	/** Opens an .osz / .mcz package: lists difficulties, lets the player pick. */
	function importPackageChart(pkgPath:String):Void
	{
		try
		{
			var entries:Array<Dynamic> = OsuMalodyConvert.readPackageEntries(pkgPath);
			var chartList:Array<Dynamic> = OsuMalodyConvert.packageChartList(entries);
			if (chartList.length == 0)
			{
				showOutput('newchartEditor_error_no_chart_in_package', true);
				return;
			}

			if (chartList.length == 1)
			{
				startPackageChartImport(entries, chartList[0], pkgPath);
				return;
			}

			var labels:Array<String> = [];
			for (c in chartList) labels.push(c.label);
			var pick:PsychUIDropDownMenu = new PsychUIDropDownMenu(0, 0, labels, function(id:Int, label:String) {}, 320);
			pick.selectedLabel = labels[0];

			openSubState(new BasePrompt(460, 210, Language.get('newchartEditor_pick_difficulty', 'Choose a difficulty...'), function(state:BasePrompt)
			{
				pick.x = state.bg.x + 30;
				pick.y = state.bg.y + 45;
				pick.cameras = state.cameras;
				state.add(pick);

				var btnY:Float = state.bg.y + state.bg.height - 45;
				var loadBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_load_btn', 'Load'), function()
				{
					var idx:Int = labels.indexOf(pick.selectedLabel);
					if (idx < 0) idx = 0;
					state.close();
					haxe.Timer.delay(function()
					{
						startPackageChartImport(entries, chartList[idx], pkgPath);
					}, 400);
				});
				loadBtn.screenCenter(X);
				loadBtn.x -= 80;
				loadBtn.cameras = state.cameras;
				loadBtn.normalStyle.bgColor = FlxColor.GREEN;
				loadBtn.normalStyle.textColor = FlxColor.WHITE;
				state.add(loadBtn);

				var cancelBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_cancel_btn', 'Cancel'), state.close);
				cancelBtn.screenCenter(X);
				cancelBtn.x += 80;
				cancelBtn.cameras = state.cameras;
				state.add(cancelBtn);
			}));
		}
		catch(e:Exception)
		{
			showOutput('newchartEditor_error', true, [e.message]);
			TraceManager.error('trace.editor.exception', 'Exception: {}', [e.stack]);
		}
	}

	function startPackageChartImport(entries:Array<Dynamic>, chartInfo:Dynamic, pkgPath:String):Void
	{
		var foundAudio:Dynamic = OsuMalodyConvert.findPackageAudio(entries, chartInfo.audioName);
		var audioBytes:haxe.io.Bytes = (foundAudio != null) ? foundAudio.data : null;
		// Prefer the real entry name: the extension must match the actual file bytes
		var audioName:String = (foundAudio != null) ? foundAudio.name : chartInfo.audioName;
		promptExternalChartImport(chartInfo.content, chartInfo.format, pkgPath, audioBytes, audioName);
	}

	/**
	 * Writes the imported audio to mods/songs/<song>/Inst.<ext> so Paths.inst
	 * can find it. Returns true on success.
	 */
	function importSongAudio(songName:String, ?audioBytes:haxe.io.Bytes, ?audioFilePath:String, ?audioExt:String):Bool
	{
		#if sys
		try
		{
			var ext:String = 'ogg';
			if (audioExt != null && audioExt.length > 0)
				ext = audioExt.toLowerCase();
			else if (audioFilePath != null)
			{
				var fdot:Int = audioFilePath.lastIndexOf('.');
				if (fdot > 0) ext = audioFilePath.substr(fdot + 1).toLowerCase();
			}
			var dot:Int = ext.lastIndexOf('.');
			if (dot >= 0) ext = ext.substr(dot + 1);

			// MP3 (and other formats lime can't decode) -> decode to WAV so it
			// plays on every platform (Windows & Android)
			var wavBytes:haxe.io.Bytes = null;
			if (ext != 'ogg' && ext != 'wav')
			{
				if (audioBytes != null)
					wavBytes = OsuMalodyConvert.audioBytesToWav(audioBytes);
				else if (audioFilePath != null && sys.FileSystem.exists(audioFilePath))
					wavBytes = OsuMalodyConvert.audioBytesToWav(sys.io.File.getBytes(audioFilePath));
				if (wavBytes != null) ext = 'wav';
			}

			var dir:String = Paths.mods('songs/' + Paths.formatToSongPath(songName));
			if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);

			var target:String = dir + '/Inst.' + ext;
			if (wavBytes != null)
				sys.io.File.saveBytes(target, wavBytes);
			else if (audioBytes != null)
				sys.io.File.saveBytes(target, audioBytes);
			else if (audioFilePath != null && sys.FileSystem.exists(audioFilePath))
				sys.io.File.copy(audioFilePath, target);
			else
				return false;

			// Drop stale cached sounds for this song so the editor picks up the new file
			var songKey:String = '/songs/' + Paths.formatToSongPath(songName) + '/';
			for (key => snd in Paths.currentTrackedSounds)
			{
				if (snd != null && key.contains(songKey))
				{
					snd.close();
					Paths.currentTrackedSounds.remove(key);
				}
			}
			return true;
		}
		catch(e:Dynamic)
		{
			TraceManager.error('trace.editor.exception', 'Exception: {}', [e]);
			return false;
		}
		#else
		return false;
		#end
	}

	/**
	 * Decodes the audio directly into memory (no file written) and registers
	 * it so Paths.inst() returns it for this session. RAM import is volatile:
	 * the caller should have already shown the player the warning.
	 */
	function importSongAudioToRam(songName:String, audioBytes:haxe.io.Bytes, ?srcExt:String):Bool
	{
		try
		{
			if (audioBytes == null || audioBytes.length == 0) return false;

			// Decode MP3 first: lime can't decode MP3 from bytes on Windows/Android
			var playable:haxe.io.Bytes = audioBytes;
			if (srcExt != 'ogg' && srcExt != 'wav')
			{
				var wav:haxe.io.Bytes = OsuMalodyConvert.audioBytesToWav(audioBytes);
				if (wav == null) return false;
				playable = wav;
			}

			var limeBytes:lime.utils.Bytes = lime.utils.Bytes.ofData(playable.getData());
			var buffer:lime.media.AudioBuffer = lime.media.AudioBuffer.fromBytes(limeBytes);
			if (buffer == null) return false;

			var sound:Sound = Sound.fromAudioBuffer(buffer);
			Paths.setRamInst(songName, sound);
			Paths.setRamInstBytes(songName, playable);

			// Drop any stale on-disk cached sound so the RAM one takes over
			var songKey:String = '/songs/' + Paths.formatToSongPath(songName) + '/';
			for (key => snd in Paths.currentTrackedSounds)
			{
				if (snd != null && key.contains(songKey))
				{
					snd.close();
					Paths.currentTrackedSounds.remove(key);
				}
			}
			return true;
		}
		catch(e:Dynamic)
		{
			TraceManager.error('trace.editor.exception', 'Exception: {}', [e]);
			return false;
		}
	}

	function addFileTab()
	{
		var tab = upperBox.getTab('newchartEditor_file');
		var tab_group = tab.menu;
		var btnX = tab.x - upperBox.x;
		var btnY = 1;
		var btnWid = Std.int(tab.width);

		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_new', function()
		{
			var func:Void->Void = function()
			{
				openNewChart();
				reloadNotesDropdowns();
				prepareReload();
			}

			if(!ignoreProgressCheckBox.checked) openSubState(new Prompt('newchartEditor_sure_to_start_over', func));
			else func();
		}, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_open_chart', function()
		{
			if(!fileDialog.completed) return;
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;

			fileDialog.open(null, Language.get('newchartEditor_open_chart_title', 'Open Chart...'),
				[new FileFilter('Chart Files', 'json;osu;mc;osz;mcz'), new FileFilter('All Files', '*.*')], function()
			{
				try
				{
					var filePath:String = fileDialog.path.replace('\\', '/');

					// OSZ/MCZ packages may contain several difficulties + the audio file
					if (OsuMalodyConvert.isPackageFile(filePath))
					{
						importPackageChart(filePath);
						return;
					}

					// Detect CNE format
					if (CneExport.isCneFormat(fileDialog.data))
					{
						var loadedChart:SwagSong = CneExport.cneToPsych(fileDialog.data);
						loadedChart.format = "psych_v1_convert";
						finishOpenChart(loadedChart, filePath);
					}
					else if (OsuMalodyConvert.isOsuFile(fileDialog.data) || OsuMalodyConvert.isMalodyFile(fileDialog.data))
					{
						// osu!/Malody charts: let the player configure key mapping + music import
						var extFormat:Int = OsuMalodyConvert.isOsuFile(fileDialog.data) ? 0 : 1;
						promptExternalChartImport(fileDialog.data, extFormat, filePath, null, null);
					}
					else
					{
						var loadedChart:SwagSong = Song.parseJSON(fileDialog.data, filePath.substr(filePath.lastIndexOf('/')));
						finishOpenChart(loadedChart, filePath);
					}
				}
				catch(e:Exception)
				{
					var diag:String = e.message;
					#if android
					diag += ' | path=' + (fileDialog.path != null ? fileDialog.path : 'null')
						+ ' | dataLen=' + (fileDialog.data != null ? Std.string(fileDialog.data.length) : 'null')
						+ ' | dataHead=' + (fileDialog.data != null && fileDialog.data.length > 0 ? fileDialog.data.substr(0, 30) : 'NULL');
					#end
					showOutput('newchartEditor_error', true, [diag]);
					TraceManager.error('trace.editor.exception', 'Exception: {}', [e.stack]);
				}
			});
		}, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_open_autosave', function()
		{
			if(!fileDialog.completed) return;
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;

			#if sys
			if(!FileSystem.exists('backups/'))
			{
				showOutput('newchartEditor_error_no_autosave_folder', true);
				return;
			}
			#else
			showOutput('newchartEditor_error_no_autosave_folder', true);
			return;
			#end
			
			#if sys
			var fileList:Array<String> = FileSystem.readDirectory('backups/')
				.filter((file:String) -> file.endsWith('.$BACKUP_EXT') || file == 'autosave.json');
			#else
			var fileList:Array<String> = [];
			#end
			if(fileList.length < 1)
			{
				showOutput('newchartEditor_error_no_autosave_files', true);
				return;
			}

			fileList.sort((a:String, b:String) -> (a.toUpperCase() < b.toUpperCase()) ? 1 : -1); //Sort alphabetically descending
			var maxItems:Int = Std.int(Math.min(5, fileList.length));
			var radioGrp:PsychUIRadioGroup = new PsychUIRadioGroup(0, 0, fileList, 25, maxItems, false, 240);
			radioGrp.checked = 0;

			var hei:Float = radioGrp.height + 160;
			openSubState(new BasePrompt(420, hei, 'newchartEditor_choose_autosave',
				function(state:BasePrompt) {
					upperBox.isMinimized = true;
					upperBox.bg.visible = false;

					radioGrp.screenCenter(X);
					radioGrp.y = state.bg.y + 80;
					radioGrp.cameras = state.cameras;
					state.add(radioGrp);

					var btn:PsychUIButton = new PsychUIButton(0, radioGrp.y + radioGrp.height + 20, 'newchartEditor_load', function()
					{
						var autosaveName:String = fileList[radioGrp.checked];
						var path:String = 'backups/$autosaveName';
						state.close();

						#if sys
						if(FileSystem.exists(path))
						{
							try
							{
								var loadedChart:SwagSong = Song.parseJSON(File.getContent(path), autosaveName, null);
								if(loadedChart == null || !Reflect.hasField(loadedChart, '__original_path'))
								{
									showOutput('newchartEditor_error_not_valid_autosave', true);
									return;
	
								}
	
								var originalPath:String = Reflect.field(loadedChart, '__original_path');
								Reflect.deleteField(loadedChart, '__original_path');
	
								var func:Void->Void = function()
								{
									#if sys
									Song.chartPath = FileSystem.exists(originalPath) ? originalPath : null;
									#else
									Song.chartPath = null;
									#end
									loadChart(loadedChart);
									reloadNotesDropdowns();
									prepareReload();
	
									showOutput('newchartEditor_autosave_opened', false, [autosaveName]);
								}
								
								if(!ignoreProgressCheckBox.checked) openSubState(new Prompt('newchartEditor_warning_unsaved_progress', func));
								else func();
							}
							catch(e:Exception)
							{
								showOutput('${Language.get('newchartEditor_error_on_loading_autosave', "Error on loading autosave")}: ${e.message}', true);
							}
						}
						else showOutput('newchartEditor_error_autosave_not_found', true);
						#else
						showOutput('newchartEditor_error_autosave_not_found', true);
						#end
					});
					btn.cameras = tab_group.cameras; 
					btn.screenCenter(X);
					state.add(btn);
				}
			));
		}, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		if(SHOW_EVENT_COLUMN)
		{
			btnY += 20;
			var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_open_events', function()
			{
				if(!fileDialog.completed) return;
				upperBox.isMinimized = true;
				upperBox.bg.visible = false;
	
				fileDialog.open(function()
				{
					try
					{
						var filePath:String = fileDialog.path.replace('\\', '/');
						var eventsFile:SwagSong = Song.parseJSON(fileDialog.data, filePath.substr(filePath.lastIndexOf('/')));
						if(eventsFile == null || Reflect.hasField(eventsFile, 'scrollSpeed') || eventsFile.events == null)
						{
							showOutput('newchartEditor_error_not_valid_events', true);
							return;
						}
	
						var loadedEvents:Array<Dynamic> = eventsFile.events;
						if(loadedEvents.length < 1)
						{
							showOutput('newchartEditor_error_events_empty', true);
							return;
						}
	
						openSubState(new BasePrompt(420, 400, 'newchartEditor_events_found',
							function(state:BasePrompt)
							{
								var btnY = 390;
								var btn:PsychUIButton = new PsychUIButton(0, btnY, 'newchartEditor_replace_all', function()
								{
									for (event in events)
									{
										if(event != null)
										{
											event.destroy();
											selectedNotes.remove(event);
										}
									}
									undoActions = [];
									events = [];
	
									for (event in loadedEvents)
										events.push(createEvent(event));
	
									softReloadNotes();
									state.close();
									showOutput('newchartEditor_events_loaded');
								});
								btn.normalStyle.bgColor = FlxColor.RED;
								btn.normalStyle.textColor = FlxColor.WHITE;
								btn.screenCenter(X);
								btn.x -= 125;
								btn.cameras = tab_group.cameras; 
								state.add(btn);
								
								var btn:PsychUIButton = new PsychUIButton(0, btnY, 'newchartEditor_add', function()
								{
									for (event in loadedEvents)
										events.push(createEvent(event));
	
									softReloadNotes();
									state.close();
									showOutput('newchartEditor_events_added_success');
								});
								btn.screenCenter(X);
								btn.cameras = tab_group.cameras; 
								state.add(btn);
						
								var btn:PsychUIButton = new PsychUIButton(0, btnY, 'newchartEditor_cancel', state.close);
								btn.screenCenter(X);
								btn.x += 125;
								btn.cameras = tab_group.cameras; 
								state.add(btn);
							}
						));
					}
					catch(e:Dynamic)
					{
						// hxcpp 底层文件错误(如 fopen 失败)抛的是普通值, 不是 Exception 实例
						showOutput('newchartEditor_error', true, [Std.string(e)]);
						TraceManager.error('trace.editor.exception', 'Exception: {}', [Std.string(e)]);
					}
				});
			}, btnWid);
			btn.text.alignment = LEFT;
			tab_group.add(btn);
		}

		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_save', function()
		{
			if(!fileDialog.completed) return;
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;

			openSaveFormatPrompt();
		}, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_reload_chart', function()
		{
			var func:Void->Void = function()
			{
				if(Song.chartPath == null)
				{
					showOutput('newchartEditor_error_must_save_first', true);
					return;
				}
	
			#if sys
			if(FileSystem.exists(Song.chartPath))
			{
				try
				{
						var rawContent:String = File.getContent(Song.chartPath);
						var reloadedChart:SwagSong;
						if (CneExport.isCneFormat(rawContent))
						{
							reloadedChart = CneExport.cneToPsych(rawContent);
							reloadedChart.format = "psych_v1_convert";
						}
						else if (OsuMalodyConvert.isOsuFile(rawContent))
						{
							reloadedChart = OsuMalodyConvert.osuToPsych(rawContent);
							reloadedChart.format = "psych_v1_convert";
						}
						else if (OsuMalodyConvert.isMalodyFile(rawContent))
						{
							reloadedChart = OsuMalodyConvert.malodyToPsych(rawContent);
							reloadedChart.format = "psych_v1_convert";
						}
						else
						{
							reloadedChart = Song.parseJSON(rawContent);
						}
						loadChart(reloadedChart);
						reloadNotesDropdowns();
						prepareReload();
						showOutput('newchartEditor_chart_reloaded');
					}
					catch(e:Dynamic)
					{
						// hxcpp 底层文件错误(如 fopen 失败)抛的是普通值, 不是 Exception 实例
						showOutput('newchartEditor_error', true, [Std.string(e)]);
						TraceManager.error('trace.editor.exception', 'Exception: {}', [Std.string(e)]);
					}
				}
				else showOutput('newchartEditor_error_must_save_first', true);
			#else
			showOutput('newchartEditor_error_must_save_first', true);
			#end
				
			}

			if(!ignoreProgressCheckBox.checked) openSubState(new Prompt('newchartEditor_warning_unsaved_progress', func));
			else func();
		}, btnWid);
		btn.text.alignment = LEFT;

		tab_group.add(btn);
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_old_reload_json', function()
		{
			var songLowercase:String = Paths.formatToSongPath(PlayState.SONG.song).toLowerCase();

			var func:Void->Void = function()
			{
				// Delay to ensure the Prompt fully closes before opening a new substate
				haxe.Timer.delay(function() {
					loadJsonWithDifficulty(songLowercase);
				}, 200);
			}

			if(!ignoreProgressCheckBox.checked)
				openSubState(new Prompt('newchartEditor_warning_unsaved_progress', func));
			else
				func();
		}, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);
		
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_psych_to_vslice', function()
		{
			if(!fileDialog.completed) return;
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;

			fileDialog.open('song.json', 'Open a Psych Engine Chart JSON', function()
			{
				var filePath:String = fileDialog.path.replace('\\', '/');
				var loadedChart:SwagSong = null;
				try { loadedChart = Song.parseJSON(fileDialog.data, filePath.substr(filePath.lastIndexOf('/'))); }
				catch(e:Dynamic) { loadedChart = null; }
				if(loadedChart == null || !Reflect.hasField(loadedChart, 'song')) //Check if chart is ACTUALLY a chart and valid
				{
					showOutput('newchartEditor_error_file_not_psych_chart', true);
					return;
				}

				var pack:VSlicePackage = VSlice.export(loadedChart);
				if(pack.chart == null || pack.metadata == null)
				{
					showOutput('newchartEditor_error_not_valid_chart', true);
					return;
				}

				ClientPrefs.toggleVolumeKeys(false);
				openSubState(new BasePrompt('newchartEditor_metadata',
					function(state:BasePrompt)
					{
						var songName:String = Paths.formatToSongPath(pack.metadata.songName);
						var parentFolder:String = filePath.substring(0, filePath.lastIndexOf('/')+1);
						var artistInput, charterInput, difficultiesInput:PsychUIInputText = null;

						var btnX = 640;
						var btnY = 400;
						var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_save', function()
						{
							try
							{
								#if sys
								var diffs:Array<String> = pack.metadata.playData.difficulties;
								if(diffs != null && diffs.length > 0)
								{
									var diffsFound:Array<String> = [];
									var defaultDiff:String = Paths.formatToSongPath(Difficulty.getDefault());
									for (diff in diffs)
									{
										var diffPostfix:String = (diff != defaultDiff) ? '-$diff' : '';
										var chartToFind:String = parentFolder + songName + diffPostfix + '.json';
										if(FileSystem.exists(chartToFind))
										{
											var diffChart:SwagSong = Song.parseJSON(File.getContent(chartToFind), songName + diffPostfix);
											if(diffChart != null)
											{
												var subpack:VSlicePackage = VSlice.export(diffChart, diff);
												var diffSpeed:Dynamic = Reflect.field(subpack.chart.scrollSpeed, diff);
												var diffNotes:Array<VSliceNote> = Reflect.field(subpack.chart.notes, diff);
												if(diffSpeed != null && diffNotes != null)
												{
													Reflect.setField(pack.chart.scrollSpeed, diff, diffSpeed);
													Reflect.setField(pack.chart.notes, diff, diffNotes);
												}
												//trace(diff, diffSpeed, diffNotes.length);
											}
										}
										else CoolUtil.traceMsg('trace.fileNotFound', 'File not found: {}', [chartToFind]);
									}
									
									var chartToFind:String = parentFolder + 'events.json';
									if(FileSystem.exists(chartToFind))
									{
										var eventsChart:SwagSong = Song.parseJSON(File.getContent(chartToFind), 'events');
										if(eventsChart != null)
										{
											var subpack:VSlicePackage = VSlice.export(eventsChart);
											if(subpack.chart.events != null && subpack.chart.events.length > 0)
											{
												for (event in subpack.chart.events)
												{
													if(event == null) continue;
													pack.chart.events.push(event);
												}
											}
											@:privateAccess pack.chart.events.sort(VSlice.sortByTime);
										}
									}

									fileDialog.openDirectory('Save V-Slice Chart/Metadata JSONs', function()
									{
										overwriteSavedSomething = false;
										var path:String = fileDialog.path.replace('\\', '/');
										if(path.endsWith('/')) path = path.substr(0, path.length-1);
										overwriteCheck('$path/$songName-chart.json', '$songName-chart.json', PsychJsonPrinter.print(pack.chart, ['events', 'notes', 'scrollSpeed']), function()
										{
											overwriteCheck('$path/$songName-metadata.json', '$songName-metadata.json', PsychJsonPrinter.print(pack.metadata, ['characters', 'difficulties', 'timeChanges']), function()
											{
												if(overwriteSavedSomething)
													showOutput('newchartEditor_files_saved', false, [path]);
											});
										});
									});
								}
								else showOutput('newchartEditor_error_need_one_difficulty', true);
								#else
								showOutput('newchartEditor_error_need_one_difficulty', true);
								#end
							}
							catch(e:Exception)
							{
								showOutput('newchartEditor_error', true, [e.message]);
								TraceManager.error('trace.editor.exception', 'Exception: {}', [e.stack]);
							}
							state.close();
						});
						btn.normalStyle.bgColor = FlxColor.GREEN;
						btn.normalStyle.textColor = FlxColor.WHITE;
						btn.cameras = tab_group.cameras; 
						state.add(btn);
						
						var btn:PsychUIButton = new PsychUIButton(btnX + 100, btnY, 'newchartEditor_cancel', state.close);
						btn.cameras = tab_group.cameras; 
						state.add(btn);
						
						var textX = FlxG.width/2 - 180;
						var textY = 360;
						artistInput = new PsychUIInputText(textX, textY, 120, pack.metadata.artist, 8);
						artistInput.cameras = state.cameras;
						artistInput.onChange = function(old:String, cur:String) pack.metadata.artist = cur;
	
						charterInput = new PsychUIInputText(textX + 150, textY, 120, pack.metadata.charter, 8);
						charterInput.cameras = state.cameras;
						charterInput.onChange = function(old:String, cur:String) pack.metadata.charter = cur;

						var diffs:Array<String> = pack.metadata.playData.difficulties;
						if(diffs == null || diffs.length < 0) pack.metadata.playData.difficulties = diffs = ['easy', 'normal', 'hard'];
						difficultiesInput = new PsychUIInputText(textX, textY + 42, 160, diffs.join(', '), 8);
						difficultiesInput.cameras = state.cameras;
						difficultiesInput.forceCase = LOWER_CASE;
						difficultiesInput.onChange = function(old:String, cur:String)
						{
							pack.metadata.playData.difficulties = cur.split(',');

							var diffs:Array<String> = pack.metadata.playData.difficulties;
							for (num => diff in diffs)
								diffs[num] = Paths.formatToSongPath(diff);

							while(diffs.contains('')) //Clear invalids cuz people might be stupid
								diffs.remove('');
						}
						
						var artistTxt:EditorsText = new EditorsText(artistInput.x, artistInput.y - 15, 100, Language.get('newchartEditor_artist_composer', 'Artist/Composer:'));
						artistTxt.cameras = state.cameras;
						artistTxt.font = 'assets/fonts/editors.ttf';
						var charterTxt:EditorsText = new EditorsText(charterInput.x, charterInput.y - 15, 100, Language.get('newchartEditor_charter', 'Charter:'));
						charterTxt.cameras = state.cameras;
						charterTxt.font = 'assets/fonts/editors.ttf';
						var difficultiesTxt:EditorsText = new EditorsText(difficultiesInput.x, difficultiesInput.y - 15, 100, Language.get('newchartEditor_difficulties', 'Difficulties:'));
						difficultiesTxt.cameras = state.cameras;
						difficultiesTxt.font = 'assets/fonts/editors.ttf';
						state.add(artistTxt);
						state.add(charterTxt);
						state.add(difficultiesTxt);
						state.add(artistInput);
						state.add(charterInput);
						state.add(difficultiesInput);
					}
				));
			});
		},btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_vslice_to_psych', function()
		{
			if(!fileDialog.completed) return;
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;

			fileDialog.open('chart.json', 'Open a V-Slice Chart file', function()
			{
				var chart:VSliceChart = null;
				try { chart = cast Json.parse(fileDialog.data); } catch(e:Dynamic) { chart = null; }
				if(chart == null || chart.version == null || chart.notes == null || chart.scrollSpeed == null)
				{
					showOutput('newchartEditor_error_invalid_vslice_chart', true);
					return;
				}

				fileDialog.open('metadata.json', 'Open a V-Slice Metadata file', function()
				{
					var metadata:VSliceMetadata = null;
					try { metadata = cast Json.parse(fileDialog.data); } catch(e:Dynamic) { metadata = null; }
					if(metadata == null || metadata.version == null || metadata.playData == null || metadata.songName == null ||
						metadata.playData.difficulties == null || metadata.timeChanges == null || metadata.timeChanges.length < 1)
					{
						showOutput('newchartEditor_error_invalid_vslice_metadata', true);
						return;
					}

					try
					{
						var pack:PsychPackage = VSlice.convertToPsych(chart, metadata);
						if(pack.difficulties != null)
						{
							fileDialog.openDirectory('Save Converted Psych JSONs', function()
							{
								var path:String = fileDialog.path.replace('\\', '/');
								if(!path.endsWith('/')) path += '/';

								var diffs:Array<String> = metadata.playData.difficulties.copy();
								var defaultDiff:String = Paths.formatToSongPath(Difficulty.getDefault());
								function nextChart()
								{
									while(diffs.length > 0)
									{
										var diffName:String = diffs[0];
										diffs.remove(diffName);
										if(!pack.difficulties.exists(diffName)) continue;
		
										var diffPostfix:String = (diffName != defaultDiff) ? '-$diffName' : '';
										var chartData:SwagSong = pack.difficulties.get(diffName);
										var chartName:String = Paths.formatToSongPath(chartData.song) + diffPostfix + '.json';
										overwriteCheck(path + chartName, chartName, PsychJsonPrinter.print(chartData, ['sectionNotes', 'events']), nextChart, true);
										return;
									}
	
									if(pack.events != null)
									{
										overwriteCheck(path + 'events.json', 'events.json', PsychJsonPrinter.print(pack.events, ['events']), function()
										{
											if(overwriteSavedSomething)
												showOutput('newchartEditor_files_saved', false, [fileDialog.path]);
										}, true);
									}
									else if(overwriteSavedSomething)
										showOutput('newchartEditor_files_saved', false, [fileDialog.path]);
								}
								
								overwriteSavedSomething = false;
								nextChart();
							});
						}
						else showOutput('newchartEditor_error_no_difficulties', true);
					}
					catch(e:Dynamic)
					{
						// hxcpp 底层文件错误(如 fopen 失败)抛的是普通值, 不是 Exception 实例
						showOutput('newchartEditor_error', true, [Std.string(e)]);
						TraceManager.error('trace.editor.exception', 'Exception: {}', [Std.string(e)]);
					}
				});
			});
		},btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);
		/*
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_save_as_1x', function()
		{
			if(!fileDialog.completed) return;
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;

			updateChartData();
			var chartName:String = Paths.formatToSongPath(PlayState.SONG.song) + '.json';
			if(Song.chartPath != null) chartName = Song.chartPath.substr(Song.chartPath.lastIndexOf('/')).trim();
			
			fileDialog.save(chartName, PsychJsonPrinter.print(PlayState.SONG, ['sectionNotes', 'events']),
				function()
				{
					var newPath:String = fileDialog.path;
					Song.chartPath = newPath.replace('\\', '/');
					reloadNotesDropdowns();
					showOutput('Chart saved as 1.x.x to: $newPath');
				}, null, function() showOutput('Error on saving chart!', true));
		}, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);
		*/

		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_preview', openEditorPlayState, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);
		
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_playtest', goToPlayState, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_exit', function() confirmExit(), btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);
	}

	var lockedEvents:Bool = false;
	function addEditTab()
	{
		var tab = upperBox.getTab('newchartEditor_edit');
		var tab_group = tab.menu;
		var btnX = tab.x - upperBox.x;
		var btnY = 1;
		var btnWid = Std.int(tab.width);

		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_undo', undo, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_redo', redo, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_select_all', function()
		{
			var sel = selectedNotes;
			selectedNotes = curRenderedNotes.members.copy();
			addUndoAction(SELECT_NOTE, {old: sel, current: selectedNotes.copy()});
			onSelectNote();
			TraceManager.debug('trace.editor.noteSelected', 'Notes selected: {}', [selectedNotes.length]);
		}, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		if(SHOW_EVENT_COLUMN)
		{
			btnY++;
			btnY += 20;
			var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_lock_events', btnWid);
			btn.onClick = function()
			{
				lockedEvents = !lockedEvents;
				if(lockedEvents) btn.text.text = Language.get('newchartEditor_unlock_events', 'Unlock Events');
				else btn.text.text = Language.get('newchartEditor_lock_events', 'Lock Events');
				eventLockOverlay.visible = lockedEvents;
	
				if(selectedNotes.length >= 1)
				{
					var sel = selectedNotes;
					var onlyNotes = selectedNotes.filter((note:MetaNote) -> !note.isEvent);
					resetSelectedNotes();
					selectedNotes = onlyNotes;
					addUndoAction(SELECT_NOTE, {old: sel, current: selectedNotes.copy()});
					if(selectedNotes.length == 1) onSelectNote();
				}
				softReloadNotes();
			};
			btn.text.alignment = LEFT;
			tab_group.add(btn);
		}
		
		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_autosave_settings', btnWid);
		btn.onClick = function()
		{
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;
			openSubState(new BasePrompt(400, 160, 'newchartEditor_autosave_settings_title',
				function(state:BasePrompt)
				{
					var checkbox:PsychUICheckBox = null;
					var timeStepper:PsychUINumericStepper = null;

					timeStepper = new PsychUINumericStepper(state.bg.x + 50, state.bg.y + 90, 1, autoSaveCap, 1, 30, 0);
					timeStepper.onValueChange = function() {
						autoSaveTime = 0;
						checkbox.checked = true;
						autoSaveCap = chartEditorSave.data.autoSave = Std.int(timeStepper.value);
					};
					timeStepper.cameras = state.cameras;

					checkbox = new PsychUICheckBox(timeStepper.x + 80, timeStepper.y, Language.get('newchartEditor_enabled', 'Enabled'), 60, function() {
						autoSaveTime = 0;
						autoSaveCap = chartEditorSave.data.autoSave = checkbox.checked ? Std.int(timeStepper.value) : 0;
					});
					checkbox.checked = (autoSaveCap > 0);
					checkbox.cameras = state.cameras;
					
					var maxFileStepper:PsychUINumericStepper = new PsychUINumericStepper(checkbox.x + 140, checkbox.y, 1, backupLimit, 0, 50, 0);
					maxFileStepper.onValueChange = function() {
						autoSaveTime = 0;
						checkbox.checked = true;
						chartEditorSave.data.backupLimit = backupLimit = Std.int(maxFileStepper.value);
					};
					maxFileStepper.cameras = state.cameras;

					var txt1:EditorsText = new EditorsText(timeStepper.x, timeStepper.y - 15, 100, Language.get('newchartEditor_time_in_minutes', 'Time (in minutes):'));
					txt1.cameras = state.cameras;
					var txt2:EditorsText = new EditorsText(maxFileStepper.x, maxFileStepper.y - 15, 100, Language.get('newchartEditor_file_limit', 'File Limit:'));
					txt2.cameras = state.cameras;

					state.add(txt1);
					state.add(txt2);
					state.add(checkbox);
					state.add(timeStepper);
					state.add(maxFileStepper);
				}
			));

		};
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_clear_all_notes', function()
		{
			var func:Void->Void = function()
			{
				resetSelectedNotes();
				addUndoAction(DELETE_NOTE, {notes: notes.copy()});
				notes = [];
				loadSection();
			}

			if(!ignoreProgressCheckBox.checked) openSubState(new Prompt('newchartEditor_delete_all_notes', func));
			else func();
		}, btnWid);
		btn.normalStyle.bgColor = FlxColor.RED;
		btn.normalStyle.textColor = FlxColor.WHITE;
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		if(SHOW_EVENT_COLUMN)
		{
			btnY += 20;
			var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_clear_all_events', function()
			{
				var func:Void->Void = function()
				{
					resetSelectedNotes();
					addUndoAction(DELETE_NOTE, {events: events.copy()});
					events = [];
					loadSection();
				}
	
				if(!ignoreProgressCheckBox.checked) openSubState(new Prompt('newchartEditor_delete_all_events', func));
				else func();
			}, btnWid);
			btn.normalStyle.bgColor = FlxColor.RED;
			btn.normalStyle.textColor = FlxColor.WHITE;
			btn.text.alignment = LEFT;
			tab_group.add(btn);
		}
	}

	var showLastGridButton:PsychUIButton;
	var showNextGridButton:PsychUIButton;
	var noteTypeLabelsButton:PsychUIButton;
	var vortexEditorButton:PsychUIButton;
	function addViewTab()
	{
		var tab = upperBox.getTab('newchartEditor_view');
		var tab_group = tab.menu;
		var btnX = tab.x - upperBox.x;
		var btnY = 1;
		var btnWid = Std.int(tab.width);

		if(chartEditorSave.data.waveformEnabled != null)
			waveformEnabled = chartEditorSave.data.waveformEnabled;
		if(chartEditorSave.data.waveformTarget != null)
			waveformTarget = chartEditorSave.data.waveformTarget;
		if(chartEditorSave.data.waveformColor != null)
			waveformSprite.color = CoolUtil.colorFromString(chartEditorSave.data.waveformColor);

		showLastGridButton = new PsychUIButton(btnX, btnY, '', function()
		{
			showPreviousSection = !showPreviousSection;
			updateGridVisibility();
		}, btnWid);
		showLastGridButton.text.alignment = LEFT;
		tab_group.add(showLastGridButton);

		btnY += 20;
		showNextGridButton = new PsychUIButton(btnX, btnY, '', function()
		{
			showNextSection = !showNextSection;
			updateGridVisibility();
		}, btnWid);
		showNextGridButton.text.alignment = LEFT;
		tab_group.add(showNextGridButton);

		btnY++;
		btnY += 20;
		noteTypeLabelsButton = new PsychUIButton(btnX, btnY, '', function()
		{
			showNoteTypeLabels = !showNoteTypeLabels;
			updateGridVisibility();
		}, btnWid);
		noteTypeLabelsButton.text.alignment = LEFT;
		tab_group.add(noteTypeLabelsButton);

		btnY++;
		btnY += 20;
		vortexEditorButton = new PsychUIButton(btnX, btnY, vortexEnabled ? 'newchartEditor_vortex_editor_on' : 'newchartEditor_vortex_editor_off', function()
		{
			vortexEnabled = !vortexEnabled;
			chartEditorSave.data.vortex = vortexEnabled;
			vortexIndicator.visible = strumLineNotes.visible = strumLineNotes.active = vortexEnabled;
			vortexEditorButton.text.text = vortexEnabled ? Language.get('newchartEditor_vortex_editor_on', 'Vortex Editor ON') : Language.get('newchartEditor_vortex_editor_off', 'Vortex Editor OFF');

			for (note in strumLineNotes)
			{
				note.playAnim('static');
				note.resetAnim = 0;
			}
			prevGridBg.vortexLineEnabled = gridBg.vortexLineEnabled = nextGridBg.vortexLineEnabled = vortexEnabled;
		}, btnWid);
		vortexEditorButton.text.y += 5;
		vortexEditorButton.text.alignment = LEFT;
		tab_group.add(vortexEditorButton);
		
		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_waveform', function()
		{
			ClientPrefs.toggleVolumeKeys(false);
			openSubState(new BasePrompt(320, 200, Language.get('newchartEditor_waveform_settings', 'Waveform Settings'),
				function(state:BasePrompt) {
					upperBox.isMinimized = true;
					upperBox.bg.visible = false;

					var check:PsychUICheckBox = new PsychUICheckBox(state.bg.x + 40, state.bg.y + 80, Language.get('newchartEditor_enabled', 'Enabled'), 60);
					check.onClick = function()
					{
						chartEditorSave.data.waveformEnabled = waveformEnabled = check.checked;
						updateWaveform();
					};
					check.cameras = state.cameras;
					check.checked = waveformEnabled;
					state.add(check);

					var waveformC:String = '0000FF';
					if(chartEditorSave.data.waveformColor != null)
						waveformC = chartEditorSave.data.waveformColor;

					var input:PsychUIInputText = new PsychUIInputText(check.x, check.y + 50, 60, waveformC, 10);
					input.onChange = function(old:String, cur:String)
					{
						chartEditorSave.data.waveformColor = cur;
						waveformSprite.color = CoolUtil.colorFromString(cur);
					}
					input.maxLength = 6;
					input.filterMode = ONLY_HEXADECIMAL;
					input.cameras = state.cameras;
					input.forceCase = UPPER_CASE;

					var options:Array<WaveformTarget> = [INST, PLAYER, OPPONENT];
					var radioGrp:PsychUIRadioGroup = new PsychUIRadioGroup(check.x + 120, check.y, [Language.get('newchartEditor_instrumental', 'Instrumental'), Language.get('newchartEditor_main_vocals_label', 'Main Vocals'), Language.get('newchartEditor_opponent_vocals_label', 'Opponent Vocals')]);
					radioGrp.cameras = state.cameras;
					radioGrp.onClick = function()
					{
						waveformTarget = chartEditorSave.data.waveformTarget = options[radioGrp.checked];
						updateWaveform();
					};
					radioGrp.checked = options.indexOf(waveformTarget);
					state.add(radioGrp);

					var txt1:EditorsText = new EditorsText(input.x, input.y - 15, 80, Language.get('newchartEditor_color_hex', 'Color (Hex):'));
					txt1.cameras = state.cameras;
					state.add(txt1);
					state.add(input);
				}
			));
		}, btnWid);
		btn.text.y += 5;
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_go_to', function()
		{
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;
			openSubState(new BasePrompt(420, 200, 'newchartEditor_go_to_title',
				function(state:BasePrompt)
				{
					var curTime:Float = Conductor.songPosition;
					var currentSec:Int = curSec;

					var timeStepper:PsychUINumericStepper = new PsychUINumericStepper(state.bg.x + 100, state.bg.y + 90, 1, Math.floor(curTime)/1000, 0, FlxG.sound.music.length/1000 - 0.01, 2, 80);
					timeStepper.cameras = state.cameras;
					var sectionStepper:PsychUINumericStepper = new PsychUINumericStepper(timeStepper.x + 160, timeStepper.y, 1, currentSec, 0, PlayState.SONG.notes.length - 1, 0);
					sectionStepper.cameras = state.cameras;

					var txt1:EditorsText = new EditorsText(timeStepper.x, timeStepper.y - 15, 100, Language.get('newchartEditor_time_in_seconds', 'Time (in seconds):'));
					txt1.font = 'assets/fonts/editors.ttf';
					var txt2:EditorsText = new EditorsText(sectionStepper.x, sectionStepper.y - 15, 100, Language.get('newchartEditor_section', 'Section:'));
					txt2.font = 'assets/fonts/editors.ttf';

					txt1.cameras = state.cameras;
					txt2.cameras = state.cameras;
					state.add(txt1);
					state.add(txt2);
					state.add(timeStepper);
					state.add(sectionStepper);

					var timeTxt:EditorsText = new EditorsText(15, state.bg.y + state.bg.height - 75, 230, '', 16);
					timeTxt.alignment = CENTER;
					timeTxt.screenCenter(X);
					timeTxt.cameras = state.cameras;

					state.add(timeTxt);
					function updateTime()
					{
						var tm:String = FlxStringUtil.formatTime(curTime / 1000, true);
						var ln:String = FlxStringUtil.formatTime(FlxG.sound.music.length / 1000, true);
						timeTxt.text = '$tm / $ln';
					}
					updateTime();

					timeStepper.onValueChange = function()
					{
						curTime = timeStepper.value * 1000;
						for (i => time in cachedSectionTimes)
						{
							if(time <= curTime)
								currentSec = i;
							else break;
						}
						updateTime();
					};
					sectionStepper.onValueChange = function()
					{
						currentSec = Std.int(sectionStepper.value);
						curTime = cachedSectionTimes[currentSec] + 0.000001;
						updateTime();
					};

					var btn:PsychUIButton = new PsychUIButton(0, timeTxt.y + 35, 'newchartEditor_go_to', function()
					{
						curSec = currentSec;
						FlxG.sound.music.time = FlxMath.bound(curTime, 0, FlxG.sound.music.length - 1);
						loadSection();
						state.close();
					});

					btn.cameras = tab_group.cameras; 
					btn.screenCenter(X);
					btn.x -= 60;
					state.add(btn);

					var btn:PsychUIButton = new PsychUIButton(0, btn.y, 'newchartEditor_cancel', state.close);
					btn.cameras = tab_group.cameras; 
					btn.screenCenter(X);
					btn.x += 60;
					state.add(btn);
				}
			));
		}, btnWid);
		btn.text.y += 3;
		btn.text.alignment = LEFT;
		btn.cameras = tab_group.cameras; 
		tab_group.add(btn);

		btnY++;
		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_theme', function()
		{
			if(!fileDialog.completed) return;
			upperBox.isMinimized = true;
			upperBox.bg.visible = false;

			openSubState(new BasePrompt(500, 260, 'newchartEditor_theme_title',
				function(state:BasePrompt)
				{
					var btnY = 320;
					var btn:PsychUIButton = new PsychUIButton(0, btnY, 'newchartEditor_light', changeTheme.bind(LIGHT));
					btn.screenCenter(X);
					btn.x -= 180;
					btn.cameras = tab_group.cameras; 
					state.add(btn);
			
					var btn:PsychUIButton = new PsychUIButton(0, btnY, 'newchartEditor_dark', changeTheme.bind(DARK));
					btn.screenCenter(X);
					btn.x -= 60;
					btn.cameras = tab_group.cameras; 
					state.add(btn);
					
					var btn:PsychUIButton = new PsychUIButton(0, btnY, 'newchartEditor_default', changeTheme.bind(DEFAULT));
					btn.screenCenter(X);
					btn.cameras = tab_group.cameras; 
					btn.x += 60;
					state.add(btn);
			
					var btn:PsychUIButton = new PsychUIButton(0, btnY, 'newchartEditor_vslice', changeTheme.bind(VSLICE));
					btn.screenCenter(X);
					btn.x += 180;
					btn.cameras = tab_group.cameras; 
					state.add(btn);

					btnY += 60;
					var btn:PsychUIButton = new PsychUIButton(0, btnY, 'newchartEditor_custom', changeTheme.bind(CUSTOM));
					btn.screenCenter(X);
					btn.x -= 180;
					btn.cameras = tab_group.cameras; 
					state.add(btn);

					var customBgC:String = '303030';
					if(chartEditorSave.data.customBgColor != null)
						customBgC = chartEditorSave.data.customBgColor;

					var input:PsychUIInputText = new PsychUIInputText(0, btnY, 80, customBgC, 10);
					input.maxLength = 6;
					input.filterMode = ONLY_HEXADECIMAL;
					input.forceCase = UPPER_CASE;
					input.screenCenter(X);
					input.x -= 60;
					input.cameras = state.cameras;
					input.onChange = function(old:String, cur:String)
					{
						chartEditorSave.data.customBgColor = cur;
						changeTheme(CUSTOM);
					}

					var txt:EditorsText = new EditorsText(input.x, input.y - 15, 120, Language.get('newchartEditor_bg_color', 'BG Color:'));
					txt.font = 'assets/fonts/editors.ttf';
					txt.cameras = state.cameras;
					state.add(txt);
					state.add(input);

					var customGridC:Array<String> = ['DFDFDF', 'BFBFBF'];
					if(chartEditorSave.data.customGridColors != null && chartEditorSave.data.customGridColors.length > 1)
						customGridC = chartEditorSave.data.customGridColors;

					var input:PsychUIInputText = new PsychUIInputText(0, btnY, 80, customGridC[0], 10);
					input.maxLength = 6;
					input.filterMode = ONLY_HEXADECIMAL;
					input.forceCase = UPPER_CASE;
					input.screenCenter(X);
					input.x += 60;
					input.cameras = state.cameras;
					input.onChange = function(old:String, cur:String)
					{
						chartEditorSave.data.customGridColors[0] = cur;
						changeTheme(CUSTOM);
					}

					var txt:EditorsText = new EditorsText(input.x, input.y - 15, 120, Language.get('newchartEditor_grid_colors', 'Grid Colors:'));
					txt.font = 'assets/fonts/editors.ttf';
					txt.cameras = state.cameras;
					state.add(txt);
					state.add(input);

					var input:PsychUIInputText = new PsychUIInputText(0, btnY + 30, 80, customGridC[1], 10);
					input.maxLength = 6;
					input.filterMode = ONLY_HEXADECIMAL;
					input.forceCase = UPPER_CASE;
					input.screenCenter(X);
					input.x += 60;
					input.cameras = state.cameras;
					input.onChange = function(old:String, cur:String)
					{
						chartEditorSave.data.customGridColors[1] = cur;
						changeTheme(CUSTOM);
					}
					state.add(input);

					var customGridOtherC:Array<String> = ['5F5F5F', '4A4A4A'];
					if(chartEditorSave.data.customNextGridColors != null && chartEditorSave.data.customNextGridColors.length > 1)
						customGridOtherC = chartEditorSave.data.customNextGridColors;

					var input:PsychUIInputText = new PsychUIInputText(0, btnY, 80, customGridOtherC[0], 10);
					input.maxLength = 6;
					input.filterMode = ONLY_HEXADECIMAL;
					input.forceCase = UPPER_CASE;
					input.screenCenter(X);
					input.x += 180;
					input.cameras = state.cameras;
					input.onChange = function(old:String, cur:String)
					{
						chartEditorSave.data.customNextGridColors[0] = cur;
						changeTheme(CUSTOM);
					}

					var txt:EditorsText = new EditorsText(input.x, input.y - 15, 120, Language.get('newchartEditor_next_grid_colors', 'Next Grid Color:'));
					txt.font = 'assets/fonts/editors.ttf';
					txt.cameras = state.cameras;
					state.add(txt);
					state.add(input);

					var input:PsychUIInputText = new PsychUIInputText(0, btnY + 30, 80, customGridOtherC[1], 10);
					input.maxLength = 6;
					input.filterMode = ONLY_HEXADECIMAL;
					input.forceCase = UPPER_CASE;
					input.screenCenter(X);
					input.x += 180;
					input.cameras = state.cameras;
					input.onChange = function(old:String, cur:String)
					{
						chartEditorSave.data.customNextGridColors[1] = cur;
						changeTheme(CUSTOM);
					}
					state.add(input);
				}
			));
		}, btnWid);
		btn.text.alignment = LEFT;
		tab_group.add(btn);

		btnY += 20;
		var btn:PsychUIButton = new PsychUIButton(btnX, btnY, 'newchartEditor_reset_ui_boxes', function()
		{
			mainBox.setPosition(mainBoxPosition.x, mainBoxPosition.y);
			infoBox.setPosition(infoBoxPosition.x, infoBoxPosition.y);
			UIEvent(PsychUIBox.DROP_EVENT, btn); //to force a save
		}, btnWid);
		btn.text.y = btn.y + 5;
		btn.text.alignment = LEFT;
		tab_group.add(btn);
	}

	function updateChartData()
	{
		for (secNum => section in PlayState.SONG.notes)
			PlayState.SONG.notes[secNum].sectionNotes = [];

		notes.sort(PlayState.sortByTime);
		var noteSec:Int = 0;
		var nextSectionTime:Float = cachedSectionTimes[noteSec + 1];
		var curSectionTime:Float = cachedSectionTimes[noteSec];

		for (num => note in notes)
		{
			if(note == null) continue;

			while(cachedSectionTimes[noteSec + 1] <= note.strumTime)
			{
				noteSec++;
				nextSectionTime = cachedSectionTimes[noteSec + 1];
				curSectionTime = cachedSectionTimes[noteSec];
			}

			var arr:Array<Dynamic> = PlayState.SONG.notes[noteSec].sectionNotes;
			//trace('Added note with time ${note.songData[0]} at section $noteSec');
			arr.push(note.songData);
		}

		events.sort(PlayState.sortByTime);
		PlayState.SONG.events = [];
		for (event in events)
			PlayState.SONG.events.push(event.songData);
	}

	function saveChart(includeEvents:Bool = true)
	{
		updateChartData();
		// 多k: 4K 谱面可选择是否导出 mania 字段; 非 4K 必须导出 (锁死)
		if (PlayState.SONG.mania == null || PlayState.SONG.mania == Note.defaultMania)
		{
			openSubState(new BasePrompt(420, 180, Language.get('newchartEditor_export_mania_title', 'Export Multi-K Field?'),
				function(state:BasePrompt)
				{
					var check:PsychUICheckBox = new PsychUICheckBox(state.bg.x + 60, state.bg.y + 80,
						Language.get('newchartEditor_export_mania_label', 'Include mania field (4K)'), 500);
					check.checked = false;
					check.cameras = state.cameras;
					state.add(check);

					var saveBtn:PsychUIButton = new PsychUIButton(0, state.bg.y + state.bg.height - 45,
						Language.get('newchartEditor_save_btn', 'Save'), function()
						{
							state.close();
							haxe.Timer.delay(function() { doSaveChart(check.checked, includeEvents); }, 200);
						});
					saveBtn.screenCenter(X);
					saveBtn.x -= 80;
					saveBtn.cameras = state.cameras;
					saveBtn.normalStyle.bgColor = FlxColor.GREEN;
					saveBtn.normalStyle.textColor = FlxColor.WHITE;
					state.add(saveBtn);

					var cancelBtn:PsychUIButton = new PsychUIButton(0, state.bg.y + state.bg.height - 45,
						Language.get('newchartEditor_cancel_btn', 'Cancel'), function() { state.close(); });
					cancelBtn.screenCenter(X);
					cancelBtn.x += 80;
					cancelBtn.cameras = state.cameras;
					state.add(cancelBtn);
				}));
			return;
		}
		doSaveChart(true, includeEvents);
	}

	function doSaveChart(includeManiaField:Bool, includeEvents:Bool = true)
	{
		var songCopy:Dynamic = {};
		for (f in Reflect.fields(PlayState.SONG))
			Reflect.setField(songCopy, f, Reflect.field(PlayState.SONG, f));
		if (!includeManiaField) Reflect.deleteField(songCopy, 'mania');
		if (!includeEvents) Reflect.setField(songCopy, 'events', []);
		var chartData:String = PsychJsonPrinter.print(songCopy, ['sectionNotes', 'events']);

		var chartName:String = Paths.formatToSongPath(PlayState.SONG.song) + '.json';
		if(Song.chartPath != null)
		{
			var lastSlash:Int = Song.chartPath.lastIndexOf('/');
			if(lastSlash >= 0)
				chartName = Song.chartPath.substring(lastSlash + 1);
			else
				chartName = Song.chartPath;
			var dot:Int = chartName.lastIndexOf('.');
			if(dot > 0) chartName = chartName.substr(0, dot);
			chartName += '.json';
		}

		fileDialog.save(chartName, chartData,
			function()
			{
				var newPath:String = fileDialog.path;
				Song.chartPath = newPath.replace('\\', '/');
				reloadNotesDropdowns();
				clearUnsaved();
				showOutput('newchartEditor_chart_saved',false,[newPath]);
			}, null, function() showOutput('newchartEditor_error_save', true));
	}

	// ── Unified Save Format Prompt ──

	function openSaveFormatPrompt()
	{
		ClientPrefs.toggleVolumeKeys(false);

		var formatNames:Array<String> = [
			Language.get('newchartEditor_format_psych_v1', 'Psych Engine v1.0'),
			Language.get('newchartEditor_format_psych_v0', 'Psych Engine v0.x (Legacy)'),
			Language.get('newchartEditor_format_cne', 'Codename Engine (CNE)'),
			Language.get('newchartEditor_format_vslice', 'V-Slice'),
			Language.get('newchartEditor_format_events', 'Events Only'),
			Language.get('newchartEditor_format_events_pe063', 'Events Only (PE063)'),
			Language.get('newchartEditor_format_osu', 'osu!mania (.osu)'),
			Language.get('newchartEditor_format_malody', 'Malody (.mc)')
		];

		var radioGrp:PsychUIRadioGroup = new PsychUIRadioGroup(0, 0, formatNames, 35, formatNames.length, false, 260);
		radioGrp.checked = 0;

		var keyNames:Array<String> = [
			Language.get('newchartEditor_key_auto', 'Auto (chart K)'),
			Language.get('newchartEditor_key_4k', '4K'),
			Language.get('newchartEditor_key_8k', '8K')
		];
		var keyGrp:PsychUIRadioGroup = new PsychUIRadioGroup(0, 0, keyNames, 24, 5, true, 100);
		keyGrp.checked = 0;

		var promptHeight:Float = 100 + formatNames.length * 35 + 70 + 85 + 40;
		openSubState(new BasePrompt(420, promptHeight,
			Language.get('newchartEditor_save_format_title', 'Save Chart As...'),
			function(state:BasePrompt)
			{
				radioGrp.x = state.bg.x + 30;
				radioGrp.y = state.bg.y + 55;
				radioGrp.cameras = state.cameras;
				state.add(radioGrp);

				var keyTxt:EditorsText = new EditorsText(state.bg.x + 30, radioGrp.y + formatNames.length * 35 + 8, 260,
					Language.get('newchartEditor_export_keys', 'Key count (osu/Malody):'));
				keyTxt.cameras = state.cameras;
				state.add(keyTxt);

				keyGrp.x = state.bg.x + 30;
				keyGrp.y = keyTxt.y + 18;
				keyGrp.cameras = state.cameras;
				state.add(keyGrp);

				// Optional author/creator override for osu!/Malody export.
				_exportCreator = (PlayState.SONG.chartCreator != null) ? PlayState.SONG.chartCreator : '';
				var creatorTxt:EditorsText = new EditorsText(state.bg.x + 30, keyGrp.y + 32, 260,
					Language.get('newchartEditor_creator', 'Author/Creator (optional):'));
				creatorTxt.cameras = state.cameras;
				state.add(creatorTxt);

				var creatorInput:PsychUIInputText = new PsychUIInputText(state.bg.x + 30, creatorTxt.y + 18, 220, _exportCreator, 8);
				creatorInput.cameras = state.cameras;
				state.add(creatorInput);

				var includeEventsCheck:PsychUICheckBox = new PsychUICheckBox(state.bg.x + 30, creatorInput.y + 30,
					Language.get('newchartEditor_include_events', 'Include events (Psych/Legacy)'), 260);
				includeEventsCheck.checked = true;
				includeEventsCheck.cameras = state.cameras;
				state.add(includeEventsCheck);

				var btnY:Float = state.bg.y + state.bg.height - 45;
				var saveBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_save_btn', 'Save'), function()
				{
					var choice:Int = radioGrp.checked;
					var includeEvents:Bool = includeEventsCheck.checked;
					_exportKeyMode = switch(keyGrp.checked) { case 1: 4; case 2: 8; default: 0; }
					_exportCreator = StringTools.trim(creatorInput.text);
					state.close();
					// Delay to ensure prompt closes before file dialog opens
					haxe.Timer.delay(function() {
						switch(choice)
						{
							case 0: saveChart(includeEvents);
							case 1: saveAsOldFormat(includeEvents);
							case 2: saveAsCne();
							case 3: saveAsVslice();
							case 4: saveEventsOnly();
							case 5: saveEventsOnly063();
							case 6: saveAsOsu();
							case 7: saveAsMalody();
						}
					}, 200);
				});
				saveBtn.screenCenter(X);
				saveBtn.x -= 80;
				saveBtn.cameras = state.cameras;
				saveBtn.normalStyle.bgColor = FlxColor.GREEN;
				saveBtn.normalStyle.textColor = FlxColor.WHITE;
				state.add(saveBtn);

				var cancelBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_cancel_btn', 'Cancel'), function()
				{
					state.close();
				});
				cancelBtn.screenCenter(X);
				cancelBtn.x += 80;
				cancelBtn.cameras = state.cameras;
				state.add(cancelBtn);
			}
		));
	}

	function saveAsOldFormat(includeEvents:Bool = true)
	{
		updateChartData();
		var oldFormatSong:SwagSong = convertToOldFormat(PlayState.SONG);
		if(!includeEvents) oldFormatSong.events = [];

		var chartName:String = Paths.formatToSongPath(PlayState.SONG.song) + '.json';
		if(Song.chartPath != null)
		{
			var lastSlash:Int = Song.chartPath.lastIndexOf('/');
			if(lastSlash >= 0)
				chartName = Song.chartPath.substring(lastSlash + 1);
			else
				chartName = Song.chartPath;
			var dot:Int = chartName.lastIndexOf('.');
			if(dot > 0) chartName = chartName.substr(0, dot);
			chartName += '.json';
		}

		fileDialog.save(chartName, Json.stringify({song: oldFormatSong}, "\t"),
			function()
			{
				var newPath:String = fileDialog.path;
				showOutput('newchartEditor_chart_saved_as_0x', false, [newPath]);
			}, null, function() showOutput('newchartEditor_error_save', true));
	}

	function saveAsCne()
	{
		updateChartData();
		var cneJson:String = CneExport.psychToCne(PlayState.SONG);

		var chartName:String = Paths.formatToSongPath(PlayState.SONG.song) + '.json';
		if(Song.chartPath != null)
		{
			var lastSlash:Int = Song.chartPath.lastIndexOf('/');
			if(lastSlash >= 0)
				chartName = Song.chartPath.substring(lastSlash + 1);
			else
				chartName = Song.chartPath;
		}
		// CNE chart files typically go in a charts/ subfolder, but we save as selected
		fileDialog.save(chartName, cneJson,
			function()
			{
				var newPath:String = fileDialog.path;
				Song.chartPath = newPath.replace('\\', '/');
				showOutput('newchartEditor_cne_saved', false, [newPath]);
			}, null, function() showOutput('newchartEditor_error_save', true));
	}

	function saveAsOsu()
	{
		updateChartData();
		var audioInfo:Dynamic = OsuMalodyConvert.findInstAudioFile(PlayState.SONG.song);
		var audioRef:String = null;
		if (audioInfo != null)
			audioRef = Paths.formatToSongPath(PlayState.SONG.song) + '.' + audioInfo.ext;
		if (_exportCreator.length > 0)
			PlayState.SONG.chartCreator = _exportCreator;
		var osuText:String = OsuMalodyConvert.psychToOsu(PlayState.SONG, _exportKeyMode, audioRef);

		var chartName:String = Paths.formatToSongPath(PlayState.SONG.song) + '.osu';
		if(Song.chartPath != null)
		{
			var lastSlash:Int = Song.chartPath.lastIndexOf('/');
			var baseName:String = lastSlash >= 0 ? Song.chartPath.substring(lastSlash + 1) : Song.chartPath;
			var dot:Int = baseName.lastIndexOf('.');
			if(dot > 0) baseName = baseName.substr(0, dot);
			chartName = baseName + '.osu';
		}

		fileDialog.save(chartName, osuText,
			function()
			{
				var newPath:String = fileDialog.path;
				var msg:String = StringTools.replace(Language.get('newchartEditor_osu_saved', 'Chart saved as osu!mania to: %s'), '%s', newPath);
				if (audioRef != null && audioInfo != null)
				{
					if (OsuMalodyConvert.exportAudioAlongside(newPath, audioInfo.path, audioRef))
						msg += '\n' + StringTools.replace(Language.get('newchartEditor_audio_exported', 'Audio copied next to chart: %s'), '%s', audioRef);
					else
						msg += '\n' + Language.get('newchartEditor_audio_copy_failed', 'Audio copy failed!');
				}
				else
					msg += '\n' + Language.get('newchartEditor_audio_not_found_export', 'Music not found on disk, chart exported without audio.');
				showOutput(msg, false);
			}, null, function() showOutput('newchartEditor_error_save', true));
	}

	function saveAsMalody()
	{
		updateChartData();
		var audioInfo:Dynamic = OsuMalodyConvert.findInstAudioFile(PlayState.SONG.song);
		var songKey:String = Paths.formatToSongPath(PlayState.SONG.song) + '/Inst';
		var audioRef:String = null;
		var audioWavBytes:haxe.io.Bytes = null; // mp3 (or RAM) audio converted to WAV
		var convertedFrom:String = null;

		// Malody can't reliably play MP3: convert to WAV unless we already have ogg/wav
		if (audioInfo != null && (audioInfo.ext == 'ogg' || audioInfo.ext == 'wav'))
		{
			audioRef = Paths.formatToSongPath(PlayState.SONG.song) + '.' + audioInfo.ext;
		}
		else if (audioInfo != null)
		{
			convertedFrom = audioInfo.ext;
			audioRef = Paths.formatToSongPath(PlayState.SONG.song) + '.wav';
			#if sys
			audioWavBytes = OsuMalodyConvert.audioBytesToWav(sys.io.File.getBytes(audioInfo.path));
			#end
		}
		else if (Paths.ramInstBytes.exists(songKey))
		{
			convertedFrom = 'RAM';
			audioRef = Paths.formatToSongPath(PlayState.SONG.song) + '.wav';
			audioWavBytes = OsuMalodyConvert.audioBytesToWav(Paths.ramInstBytes.get(songKey));
		}

		if (_exportCreator.length > 0)
			PlayState.SONG.chartCreator = _exportCreator;
		var malodyText:String = OsuMalodyConvert.psychToMalody(PlayState.SONG, _exportKeyMode, audioRef);

		var chartName:String = Paths.formatToSongPath(PlayState.SONG.song) + '.mc';
		if(Song.chartPath != null)
		{
			var lastSlash:Int = Song.chartPath.lastIndexOf('/');
			var baseName:String = lastSlash >= 0 ? Song.chartPath.substring(lastSlash + 1) : Song.chartPath;
			var dot:Int = baseName.lastIndexOf('.');
			if(dot > 0) baseName = baseName.substr(0, dot);
			chartName = baseName + '.mc';
		}

		fileDialog.save(chartName, malodyText,
			function()
			{
				var newPath:String = fileDialog.path;
				var msg:String = StringTools.replace(Language.get('newchartEditor_malody_saved', 'Chart saved as Malody to: %s'), '%s', newPath);
				if (audioRef != null)
				{
					var exportedAudio:Bool = false;
					if (audioWavBytes != null)
						exportedAudio = OsuMalodyConvert.writeAudioAlongside(newPath, audioWavBytes, audioRef);
					else if (audioInfo != null)
						exportedAudio = OsuMalodyConvert.exportAudioAlongside(newPath, audioInfo.path, audioRef);

					if (exportedAudio)
					{
						msg += '\n' + StringTools.replace(Language.get('newchartEditor_audio_exported', 'Audio copied next to chart: %s'), '%s', audioRef);
						if (convertedFrom != null)
							msg += '\n' + StringTools.replace(Language.get('newchartEditor_audio_converted', 'Converted from %s to WAV for Malody'), '%s', convertedFrom);
					}
					else
						msg += '\n' + Language.get('newchartEditor_audio_copy_failed', 'Audio copy failed!');
				}
				else
					msg += '\n' + Language.get('newchartEditor_audio_not_found_export', 'Music not found on disk, chart exported without audio.');
				showOutput(msg, false);
			}, null, function() showOutput('newchartEditor_error_save', true));
	}

	function saveAsVslice()
	{
		updateChartData();
		var pack:VSlicePackage = VSlice.export(PlayState.SONG);

		fileDialog.openDirectory(Language.get('newchartEditor_save_vslice_dir', 'Save V-Slice Chart/Metadata JSONs'), function()
		{
			try
			{
				var path:String = fileDialog.path.replace('\\', '/');

				var chartName:String = Paths.formatToSongPath(PlayState.SONG.song);
				chartName = chartName.substring(chartName.lastIndexOf('/')+1);

				var chartFile:String = '$path/$chartName-chart.json';
				var metadataFile:String = '$path/$chartName-metadata.json';

				ClientPrefs.toggleVolumeKeys(false);
				openSubState(new BasePrompt('newchartEditor_metadata',
					function(state:BasePrompt)
					{
						var btnLX = 640;
						var btnLY = 400;
						var saveBtn:PsychUIButton = new PsychUIButton(btnLX, btnLY, Language.get('newchartEditor_save_btn', 'Save'), function()
						{
							overwriteSavedSomething = false;
							overwriteCheck(chartFile, '$chartName-chart.json', PsychJsonPrinter.print(pack.chart, ['events', 'notes', 'scrollSpeed']), function()
							{
								overwriteCheck(metadataFile, '$chartName-metadata.json', PsychJsonPrinter.print(pack.metadata, ['characters', 'difficulties', 'timeChanges']), function()
								{
									if(overwriteSavedSomething)
										showOutput('newchartEditor_files_saved', false, [path]);
								});
							});
							state.close();
						});
						saveBtn.normalStyle.bgColor = FlxColor.GREEN;
						saveBtn.normalStyle.textColor = FlxColor.WHITE;
						saveBtn.cameras = state.cameras;
						state.add(saveBtn);

						var cancelBtn:PsychUIButton = new PsychUIButton(btnLX + 100, btnLY, Language.get('newchartEditor_cancel_btn', 'Cancel'), state.close);
						cancelBtn.cameras = state.cameras;
						state.add(cancelBtn);

						var textX = FlxG.width/2 - 155;
						var textY = 360;
						var artistInput:PsychUIInputText = new PsychUIInputText(textX, textY, 120, pack.metadata.artist, 8);
						artistInput.cameras = state.cameras;
						artistInput.onChange = function(old:String, cur:String) pack.metadata.artist = cur;

						var charterInput:PsychUIInputText = new PsychUIInputText(textX + 190, textY, 120, pack.metadata.charter, 8);
						charterInput.cameras = state.cameras;
						charterInput.onChange = function(old:String, cur:String) pack.metadata.charter = cur;

						var artistTxt:EditorsText = new EditorsText(artistInput.x, artistInput.y - 15, 100, Language.get('newchartEditor_artist_composer', 'Artist/Composer:'));
						artistTxt.cameras = state.cameras;
						var charterTxt:EditorsText = new EditorsText(charterInput.x, charterInput.y - 15, 100, Language.get('newchartEditor_charter', 'Charter:'));
						charterTxt.cameras = state.cameras;
						state.add(artistTxt);
						state.add(charterTxt);
						state.add(artistInput);
						state.add(charterInput);
					}
				));
			}
			catch(e:Dynamic)
			{
				showOutput('newchartEditor_error', true, [Std.string(e)]);
			}
		});
	}

	function saveEventsOnly()
	{
		updateChartData();
		fileDialog.save('events.json', PsychJsonPrinter.print({events: PlayState.SONG.events, format: 'psych_v1'}, ['events']),
			function() showOutput('newchartEditor_events_saved', false, [fileDialog.path]), null,
			function() showOutput('newchartEditor_error_save_events', true));
	}

	function saveEventsOnly063()
	{
		updateChartData();
		var eventsFile:String = Json.stringify({song: {events: PlayState.SONG.events}}, "\t");
		fileDialog.save('events.json', eventsFile.trim(),
			function() showOutput('newchartEditor_events_pe063_saved', false, [fileDialog.path]), null,
			function() showOutput('newchartEditor_error_save_events', true));
	}
	
	inline function getCurChartSection()
	{
		return PlayState.SONG.notes != null ? PlayState.SONG.notes[curSec] : null;
	}
    /**
	function updateNotesRGB()
	{
		PlayState.SONG.disableNoteRGB = noRGBCheckBox.checked;

		for (note in notes)
		{
			if(note == null) continue;

			note.rgbShader.enabled = !noRGBCheckBox.checked;
			if(note.rgbShader.enabled)
			{
				var data = backend.NoteTypesConfig.loadNoteTypeData(note.noteType);
				if(data == null || data.length < 1) continue;

				for (line in data)
				{
					var prop:String = line.property.join('.');
					if(prop == 'rgbShader.enabled')
						note.rgbShader.enabled = line.value;
				}
			}
		}

		for (note in strumLineNotes)
			note.rgbShader.enabled = !noRGBCheckBox.checked;
	}
        */
        function updateNotesRGB():Void
        {
            var disableRGB:Bool = (PlayState.SONG.disableNoteRGB == true);

            for (note in curRenderedNotes)
            {
                if (note == null || note.noteData < 0) continue;

                if (note.colorSwap != null)
                {
                    if (disableRGB)
                    {
                        note.colorSwap.hue = 0;
                        note.colorSwap.saturation = 0;
                        note.colorSwap.brightness = 0;
                    }
                    else
                        note.applyLaneColor();
                }
            }
        }


	function spawnDeleteGhost(note:MetaNote):Void
	{
		if (note == null || note.frames == null || note.graphic == null || note.graphic.bitmap == null) return;
		var ghost:FlxSprite = new FlxSprite(note.x, note.y);
		ghost.frames = note.frames;
		ghost.animation.copyFrom(note.animation);
		ghost.alpha = 0.65;
		ghost.scrollFactor.copyFrom(note.scrollFactor);
		ghost.cameras = note.cameras;
		add(ghost);
		FlxTween.tween(ghost, {alpha: 0, 'scale.x': ghost.scale.x * 1.25, 'scale.y': ghost.scale.y * 1.25}, 0.25, {ease: FlxEase.quadOut,
			onComplete: function(_) ghost.destroy()});
	}

	function updateGridVisibility()
	{
		// loadChart 在编辑器 UI 构建前就会调用本函数 (网格重建链),
		// 此时 showLastGridButton 等控件还是 null, 直接访问会空引用挂死。
		if (showLastGridButton == null) { return; }
		showLastGridButton.text.text = showPreviousSection	? Language.get('newchartEditor_hide_last_section', 'Hide Last Section') :  Language.get('newchartEditor_show_last_section', 'Show Last Section');
		showNextGridButton.text.text = showNextSection		? Language.get('newchartEditor_hide_next_section', 'Hide Next Section') :  Language.get('newchartEditor_show_next_section', 'Show Next Section');

		prevGridBg.visible = (curSec > 0 && showPreviousSection);
		nextGridBg.visible = (curSec < PlayState.SONG.notes.length - 1 && showNextSection);
		positionGridSegments();
		
		noteTypeLabelsButton.text.text = showNoteTypeLabels ? Language.get('newchartEditor_hide_note_labels', 'Hide Note Labels') : Language.get('newchartEditor_show_note_labels', 'Show Note Labels');
		for (num => text in MetaNote.noteTypeTexts)
			text.visible = showNoteTypeLabels;
		softReloadNotes();
	}

	function adaptNotesToNewTimes(oldTimes:Array<Float>)
	{
		undoActions = [];
		setSongPlaying(false);
		var gridLerp:Float = FlxMath.bound((scrollY + FlxG.height/2 - gridBg.y) / gridBg.height, 0.000001, 0.999999);
		notes.sort(PlayState.sortByTime);
		_cacheSections();

		var noteSec:Int = 0;
		var oldNextSectionTime:Float = oldTimes[noteSec + 1];
		var oldCurSectionTime:Float = oldTimes[noteSec];
		var nextSectionTime:Float = cachedSectionTimes[noteSec + 1];
		var curSectionTime:Float = cachedSectionTimes[noteSec];

		for (num => note in notes)
		{
			if(note == null || note.strumTime <= 0) continue;

			while(noteSec + 2 < oldTimes.length && oldTimes[noteSec + 1] <= note.strumTime)
			{
				noteSec++;
				oldNextSectionTime = oldTimes[noteSec + 1];
				oldCurSectionTime = oldTimes[noteSec];
				nextSectionTime = cachedSectionTimes[noteSec + 1];
				curSectionTime = cachedSectionTimes[noteSec];

				if(noteSec + 1 >= cachedSectionTimes.length)
				{
					TraceManager.warn('trace.editor.failsafe', 'failsafe, cancel early and delete notes after this');
					var changedSelected:Bool = false;
					var i:Int = notes.length - 1;
					while (i >= num)
					{
						var n:MetaNote = notes[i];
						if(n != null)
						{
							if(selectedNotes.contains(n))
							{
								selectedNotes.remove(n);
								changedSelected = true;
							}
							notes.splice(i, 1);
							n.destroy();
						}
						i--;
					}
					if(changedSelected) onSelectNote();
					loadSection();
					return;
				}
				//trace('changed section: $noteSec, $oldNextSectionTime, $oldCurSectionTime, $nextSectionTime, $curSectionTime');
			}

			var shouldBound:Bool = (note.strumTime >= oldCurSectionTime && note.strumTime < oldNextSectionTime);
			var strumTime:Float = note.strumTime;

			var ratio:Float = (nextSectionTime - curSectionTime) / (oldNextSectionTime - oldCurSectionTime);
			var adaptedStrumTime:Float = ((note.strumTime - oldCurSectionTime) * ratio) + curSectionTime;
			note.setStrumTime(adaptedStrumTime);
			if(shouldBound)
				note.setStrumTime(FlxMath.bound(note.strumTime, curSectionTime, nextSectionTime));

			positionNoteYOnTime(note, noteSec);
			note.updateSustainToStepCrochet(cachedSectionCrochets[noteSec] / 4);
		}
		
		for (event in events)
		{
			var secNum:Int = 0;
			for (time in cachedSectionTimes)
			{
				if(time > event.strumTime) break;
				secNum++;
			}
			positionNoteYOnTime(event, secNum);
		}
		
		var time:Float = FlxMath.remapToRange(gridLerp, 0, 1, cachedSectionTimes[curSec], cachedSectionTimes[curSec + 1]);
		if(Math.isNaN(time))
		{
			time = 0;
			curSec = 0;
		}
		
		if(FlxG.sound.music != null && time >= FlxG.sound.music.length)
		{
			time = FlxG.sound.music.length - 1;
			curSec = PlayState.SONG.notes.length - 1;
		}
		FlxG.sound.music.time = time;
		Conductor.songPosition = time;
		forceDataUpdate = true;
		loadSection();
	}

	public function UIEvent(id:String, sender:Dynamic)
	{
		//trace(id, sender);
		switch(id)
		{
			case PsychUIButton.CLICK_EVENT, PsychUIDropDownMenu.CLICK_EVENT:
				ignoreClickForThisFrame = true;

			case PsychUIBox.CLICK_EVENT:
				ignoreClickForThisFrame = true;

			case PsychUIBox.MINIMIZE_EVENT:
				chartEditorSave.data.mainBoxPosition = [mainBox.x, mainBox.y];
				chartEditorSave.data.infoBoxPosition = [infoBox.x, infoBox.y];
		}
	}
	function openEditorPlayState()
	{
		if(FlxG.sound.music == null)
		{
			showOutput('newchartEditor_error_load_valid_song', true);
			return;
		}

		// Warn about unsaved changes before previewing
		if(unsavedChanges)
		{
			openSubState(new editors.content.Prompt(
				Language.get('newchartEditor_unsaved_preview', 'You have unsaved changes.\nPreview anyway? (Changes won\'t be lost)'),
				function()
				{
					doOpenEditorPlayState();
				},
				'newchartEditor_preview',
				'newchartEditor_cancel'
			));
		}
		else
		{
			doOpenEditorPlayState();
		}
	}

	function doOpenEditorPlayState():Void
	{
		setSongPlaying(false);
		chartEditorSave.flush(); //just in case a random crash happens before loading
		autosaveSong();
		LoadingState.loadAndSwitchState(new editors.EditorPlayState(sectionStartTime(), PlayState.SONG.mania));
		upperBox.isMinimized = true;
		upperBox.visible = mainBox.visible = infoBox.visible = false;
	}
    function autosaveSong():Void
	{
		// Autosave is opt-in via the Chart Auto-save setting.
		// When disabled, we never touch the player's chart / autosave data.
		if(!ClientPrefs.data.chartAutosave) return;
		var data:String = Json.stringify({"song": PlayState.SONG});
		try
		{
			// 大谱面直接落盘到文件 (FlxG.save 对大 JSON 有截断风险, 会导致
			// 重新打开时后半段谱面丢失); 文件版本可被 "Open Autosave" 直接读取。
			#if sys
			if(!FileSystem.isDirectory('backups')) FileSystem.createDirectory('backups');
			File.saveContent('backups/autosave.json', data);
			#else
			FlxG.save.data.autosave = data;
			FlxG.save.flush();
			#end
		}
		catch(e:Dynamic)
		{
			// Fall back to FlxG.save only if the file write fails
			FlxG.save.data.autosave = data;
			FlxG.save.flush();
		}
	}
    function sectionStartTime(add:Int = 0):Float
	{
		var daBPM:Float = PlayState.SONG.bpm;
		var daPos:Float = 0;
		for (i in 0...curSec + add)
		{
			if(PlayState.SONG.notes[i] != null)
			{
				if (PlayState.SONG.notes[i].changeBPM)
				{
					daBPM = PlayState.SONG.notes[i].bpm;
				}
				daPos += getSectionBeats(i) * (1000 * 60 / daBPM);
			}
		}
		return daPos;
	}
    function getSectionBeats(?section:Null<Int> = null)
	{
		if (section == null) section = curSec;
		var val:Null<Float> = null;
		
		if(PlayState.SONG.notes[section] != null) val = PlayState.SONG.notes[section].sectionBeats;
		return val != null ? val : 4;
	}


	function goToPlayState()
	{
		confirmPlaytest();
	}

	override function closeSubState()
	{
		ClientPrefs.toggleVolumeKeys(true);
		super.closeSubState();
		upperBox.isMinimized = true;
		upperBox.visible = mainBox.visible = infoBox.visible = true;
		updateAudioVolume();
	}

	override function destroy()
	{
		//Note.globalRgbShaders = [];

		for (num => text in MetaNote.noteTypeTexts)
			text.destroy();

		MetaNote.noteTypeTexts = [];
		fileDialog.destroy();
		super.destroy();
	}

	function loadFileList(mainFolder:String, ?optionalList:String = null, ?fileTypes:Array<String> = null)
	{
		if(fileTypes == null) fileTypes = ['.json'];

		var fileList:Array<String> = [];
		var tempMap:Map<String, Bool> = new Map<String, Bool>();
		
		if(optionalList != null)
		{
			for (file in Paths.mergeAllTextsNamed(optionalList))
			{
				file = file.trim();
				if(file.length > 0 && !tempMap.exists(file))
				{
					fileList.push(file);
					tempMap.set(file, true);
				}
			}
		}

		var preloadPath:String = Paths.getPreloadPath(mainFolder);
		#if sys
		if(FileSystem.exists(preloadPath))
		{
			for (file in FileSystem.readDirectory(preloadPath))
			{
				var path = haxe.io.Path.join([preloadPath, file.trim()]);
				if (!FileSystem.isDirectory(path) && !file.startsWith('readme.'))
				{
					for (fileType in fileTypes)
					{
						var fileToCheck:String = file.substr(0, file.length - fileType.length);
						if(fileToCheck.length > 0 && path.endsWith(fileType) && !tempMap.exists(fileToCheck))
						{
							fileList.push(fileToCheck);
							tempMap.set(fileToCheck, true);
							break;
						}
					}
				}
			}
		}
		#else
		var prefix:String = preloadPath + '/';
		for(asset in lime.utils.Assets.list())
		{
			if(!asset.startsWith(prefix)) continue;
			var file:String = asset.substr(prefix.length);
			if(file.indexOf('/') >= 0 || file.startsWith('readme.')) continue;
			var path:String = asset;
			for (fileType in fileTypes)
			{
				var fileToCheck:String = file.substr(0, file.length - fileType.length);
				if(fileToCheck.length > 0 && path.endsWith(fileType) && !tempMap.exists(fileToCheck))
				{
					fileList.push(fileToCheck);
					tempMap.set(fileToCheck, true);
					break;
				}
			}
		}
		#end
		#if MODS_ALLOWED

		var modsPath:String = Paths.mods(mainFolder);
		if(FileSystem.exists(modsPath))
		{
			for (file in FileSystem.readDirectory(modsPath))
			{
				var path = haxe.io.Path.join([modsPath, file.trim()]);
				if (!FileSystem.isDirectory(path) && !file.startsWith('readme.'))
				{
					for (fileType in fileTypes)
					{
						var fileToCheck:String = file.substr(0, file.length - fileType.length);
						if(fileToCheck.length > 0 && path.endsWith(fileType) && !tempMap.exists(fileToCheck))
						{
							fileList.push(fileToCheck);
							tempMap.set(fileToCheck, true);
							break;
						}
					}
				}
			}
		}
		if(Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
		{
			var currentModPath:String = Paths.mods(Paths.currentModDirectory + '/' + mainFolder);
			if(FileSystem.exists(currentModPath))
			{
				for (file in FileSystem.readDirectory(currentModPath))
				{
					var path = haxe.io.Path.join([currentModPath, file.trim()]);
					if (!FileSystem.isDirectory(path) && !file.startsWith('readme.'))
					{
						for (fileType in fileTypes)
						{
							var fileToCheck:String = file.substr(0, file.length - fileType.length);
							if(fileToCheck.length > 0 && path.endsWith(fileType) && !tempMap.exists(fileToCheck))
							{
								fileList.push(fileToCheck);
								tempMap.set(fileToCheck, true);
								break;
							}
						}
					}
				}
			}
		}

		for(mod in Paths.getGlobalMods())
		{
			var globalModPath:String = Paths.mods(mod + '/' + mainFolder);
			if(FileSystem.exists(globalModPath))
			{
				for (file in FileSystem.readDirectory(globalModPath))
				{
					var path = haxe.io.Path.join([globalModPath, file.trim()]);
					if (!FileSystem.isDirectory(path) && !file.startsWith('readme.'))
					{
						for (fileType in fileTypes)
						{
							var fileToCheck:String = file.substr(0, file.length - fileType.length);
							if(fileToCheck.length > 0 && path.endsWith(fileType) && !tempMap.exists(fileToCheck))
							{
								fileList.push(fileToCheck);
								tempMap.set(fileToCheck, true);
								break;
							}
						}
					}
				}
			}
		}
		#end

		return fileList;
	}
	
	function loadCharacterFile(char:String):CharacterFile
	{
		if(char != null)
		{
			try
			{
				var characterPath:String = 'characters/' + char + '.json';
				var path:String = '';
				
				#if MODS_ALLOWED
				path = Paths.modFolders(characterPath);
				if (!FileSystem.exists(path)) {
					path = Paths.getPreloadPath(characterPath);
				}
				#else
				path = Paths.getPreloadPath(characterPath);
				#end

				#if sys
				if (!FileSystem.exists(path))
				#else
				if (!OpenFlAssets.exists(path, TEXT))
				#end
				{
					path = Paths.getPreloadPath('characters/' + Character.DEFAULT_CHARACTER + '.json');
				}

				#if MODS_ALLOWED
				var rawJson = File.getContent(path);
				#else
				var rawJson = OpenFlAssets.getText(path);
				#end

				return cast Json.parse(rawJson);
			}
			catch (e:Dynamic) 
			{
				CoolUtil.traceMsg('trace.charLoadError', 'Error loading character: {} - {}', [char, e]);
			}
		}
		return null;
	}

	var overwriteSavedSomething:Bool = false;
	function overwriteCheck(savePath:String, overwriteName:String, saveData:String, continueFunc:Void->Void = null, ?continueOnCancel:Bool = false)
	{
		#if sys
		function doSave():Void
		{
			try
			{
				// Make sure the parent directory exists before writing. Folder
				// pickers can hand back odd paths, and saveContent on a missing
				// parent used to crash the whole editor.
				var parent:String = savePath.substr(0, savePath.lastIndexOf('/'));
				if (parent.length > 0 && !FileSystem.exists(parent))
					FileSystem.createDirectory(parent);
				File.saveContent(savePath, saveData);
				overwriteSavedSomething = true;
				if(continueFunc != null) continueFunc();
			}
			catch(e:Dynamic)
			{
				showOutput('newchartEditor_error_save', true);
				TraceManager.error('trace.editor.fileSavePathError', 'Save failed: {} - {}', [savePath, Std.string(e)]);
			}
		}
		if(FileSystem.exists(savePath))
		{
			openSubState(new Prompt('${Language.get("newchartEditor_overwrite", "Overwrite")}: "$overwriteName"?', doSave,
			continueOnCancel ? (function() if(continueFunc != null) continueFunc()) : null));
		}
		else doSave();
		#else
		overwriteSavedSomething = true;
		if(continueFunc != null) continueFunc();
		#end
	}

	// Undo/Redo stuff
	var undoActions:Array<UndoStruct> = [];
	var currentUndo:Int = 0;
	function addUndoAction(action:UndoAction, data:Dynamic)
	{
		function destroyFromArr(arr:Array<MetaNote>)
		{
			if(arr == null || arr.length < 1) return;

			for (note in arr)
				if(note != null)
					note.destroy();
		}

		//trace('pushed action: $action');
		if(currentUndo > 0) undoActions = undoActions.slice(currentUndo);
		currentUndo = 0;
		undoActions.insert(0, {action: action, data: data});
		markUnsaved(); // Any undoable action means chart data changed
		while(undoActions.length > 15)
		{
			var lastAction:UndoStruct = undoActions.pop();
			if(lastAction != null)
			{
				switch(lastAction.action)
				{
					case DELETE_NOTE:
						destroyFromArr(lastAction.data.notes);
						destroyFromArr(lastAction.data.events);
					case MOVE_NOTE:
						destroyFromArr(lastAction.data.originalNotes);
						destroyFromArr(lastAction.data.originalEvents);
					default:
				}
			}
		}
	}

	function undo()
	{
		if(isMovingNotes || currentUndo >= undoActions.length)
		{
			FlxG.sound.play(Paths.sound('cancelMenu'), 0.4);
			return;
		}

		var action:UndoStruct = undoActions[currentUndo];
		switch(action.action)
		{
			case ADD_NOTE:
				actionRemoveNotes(action.data.notes, action.data.events);

			case DELETE_NOTE:
				actionPushNotes(action.data.notes, action.data.events);

			case MOVE_NOTE:
				actionRemoveNotes(action.data.movedNotes, action.data.movedEvents);
				actionPushNotes(action.data.originalNotes, action.data.originalEvents);
				onSelectNote();

			case SELECT_NOTE:
				resetSelectedNotes();
				selectedNotes = action.data.old;
				if(lockedEvents) selectedNotes = selectedNotes.filter((note:MetaNote) -> !note.isEvent);
				onSelectNote();
		}
		if (action.action != SELECT_NOTE)
		{
			// 多k: 撤销涉及事件/音符结构变化时, 重同步 SONG 数据并重建网格
			try
			{
				_cacheSections();
				updateChartData();
				createGrids(false);
				rebuildStrumNotes();
				repositionEditorUI();
				updateGridVisibility();
				updateNotesForMania();
				updateHeads(true);
				updateScrollY();
			}
			catch (e:Dynamic) {}
		}
		showOutput('${Language.get("newchartEditor_undo", "Undo")} #${currentUndo+1}: ${action.action}');
		FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
		currentUndo++;
	}
	function redo()
	{
		if(isMovingNotes || currentUndo < 1)
		{
			FlxG.sound.play(Paths.sound('cancelMenu'), 0.4);
			return;
		}

		currentUndo--;
		var action:UndoStruct = undoActions[currentUndo];
		switch(action.action)
		{
			case ADD_NOTE:
				actionPushNotes(action.data.notes, action.data.events);

			case DELETE_NOTE:
				actionRemoveNotes(action.data.notes, action.data.events);

			case MOVE_NOTE:
				actionRemoveNotes(action.data.originalNotes, action.data.originalEvents);
				actionPushNotes(action.data.movedNotes, action.data.movedEvents);
				onSelectNote();

			case SELECT_NOTE:
				resetSelectedNotes();
				selectedNotes = action.data.current;
				if(lockedEvents) selectedNotes = selectedNotes.filter((note:MetaNote) -> !note.isEvent);
				onSelectNote();
		}
		if (action.action != SELECT_NOTE)
		{
			// 多k: 重做涉及事件/音符结构变化时, 重同步 SONG 数据并重建网格
			try
			{
				_cacheSections();
				updateChartData();
				createGrids(false);
				rebuildStrumNotes();
				repositionEditorUI();
				updateGridVisibility();
				updateNotesForMania();
				updateHeads(true);
				updateScrollY();
			}
			catch (e:Dynamic) {}
		}
		showOutput('${Language.get("newchartEditor_redo", "Redo")} #${currentUndo+1}: ${action.action}');
		FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
	}

	function actionPushNotes(dataNotes:Array<MetaNote>, dataEvents:Array<EventMetaNote>)
	{
		resetSelectedNotes();
		if(dataNotes != null && dataNotes.length > 0)
		{
			for (note in dataNotes)
			{
				if(note != null)
				{
					notes.push(note);
					selectedNotes.push(note);
					note.songData[0] = note.strumTime;
					note.songData[1] = note.chartNoteData;
				}
			}
			notes.sort(PlayState.sortByTime);
		}
		if(dataEvents != null && dataEvents.length > 0)
		{
			for (event in dataEvents)
			{
				if(event != null)
				{
					events.push(event);
					selectedNotes.push(event);
					event.songData[0] = event.strumTime;
				}
			}
			events.sort(PlayState.sortByTime);
		}
		softReloadNotes();
	}

	function actionRemoveNotes(dataNotes:Array<MetaNote>, dataEvents:Array<EventMetaNote>)
	{
		if(dataNotes != null && dataNotes.length > 0)
		{
			for (note in dataNotes)
			{
				if(note != null)
				{
					notes.remove(note);
					selectedNotes.remove(note);

					if(note.exists)
					{
						note.colorTransform.redMultiplier = note.colorTransform.greenMultiplier = note.colorTransform.blueMultiplier = 1;
						if(note.animation.curAnim != null) note.animation.curAnim.curFrame = 0;
					}
				}

			}
		}
		if(dataEvents != null && dataEvents.length > 0)
		{
			for (event in dataEvents)
			{
				if(event != null)
				{
					trace(events.remove(event));
					selectedNotes.remove(event);

					if(event.exists)
					{
						event.colorTransform.redMultiplier = event.colorTransform.greenMultiplier = event.colorTransform.blueMultiplier = 1;
						if(event.animation.curAnim != null) event.animation.curAnim.curFrame = 0;
					}
				}
			}
		}
		softReloadNotes();
	}

	function actionReplaceNotes(oldNote:MetaNote, newNote:MetaNote)
	{
		for (act in undoActions)
		{
			for (field in Reflect.fields(act.data))
			{
				var fld:Array<MetaNote> = cast Reflect.field(act.data, field);
				if(fld != null && fld.length > 0)
					for (num => actNote in fld)
						if(actNote == oldNote)
							fld[num] = newNote;
			}
		}
	}

	// Waveform cache (shared with the old chart editor).
	var wavData:Array<Array<Array<Float>>> = [[[0], [0]], [[0], [0]]];
	function updateWaveform() {
		#if (lime_cffi && !macro)
		if(curSec < 0 || curSec >= cachedSectionTimes.length || !waveformEnabled)
		{
			waveformSprite.visible = false;
			return;
		}

		waveformSprite.visible = true;
		waveformSprite.y = gridBg.y;
		var width:Int = Std.int(GRID_SIZE * GRID_COLUMNS_PER_PLAYER * GRID_PLAYERS);
		// 多k: 波形高度按当前小节总高度 (含事件切分段)
		var height:Int = Std.int(sectionHeightPx(curSec));
		if(Std.int(waveformSprite.height) != height && waveformSprite.pixels != null)
		{
			waveformSprite.pixels.dispose();
			waveformSprite.pixels.disposeImage();
			waveformSprite.makeGraphic(width, height, 0x00FFFFFF);
		}
		waveformSprite.pixels.fillRect(new Rectangle(0, 0, width, height), 0x00FFFFFF);

		wavData[0][0].resize(0);
		wavData[0][1].resize(0);
		wavData[1][0].resize(0);
		wavData[1][1].resize(0);

		var sound:FlxSound = switch(waveformTarget)
		{
			case INST:
				FlxG.sound.music;
			case PLAYER:
				vocals;
			case OPPONENT:
				opponentVocals;
			default:
				null;
		}
		
		@:privateAccess
		if (sound != null && sound._sound != null && sound._sound.__buffer != null)
		{
			var bytes:Bytes = sound._sound.__buffer.data.toBytes();
			wavData = waveformData(sound._sound.__buffer, bytes, cachedSectionTimes[curSec] - Conductor.offset, cachedSectionTimes[curSec+1] - Conductor.offset, 1, wavData, height);
		}

		// Draws
		var gSize:Int = Std.int(GRID_SIZE * 8);
		var hSize:Int = Std.int(gSize / 2);
		var size:Float = 1;

		var leftLength:Int = (wavData[0][0].length > wavData[0][1].length ? wavData[0][0].length : wavData[0][1].length);
		var rightLength:Int = (wavData[1][0].length > wavData[1][1].length ? wavData[1][0].length : wavData[1][1].length);

		var length:Int = leftLength > rightLength ? leftLength : rightLength;

		for (index in 0...length)
		{
			var lmin:Float = FlxMath.bound(((index < wavData[0][0].length && index >= 0) ? wavData[0][0][index] : 0) * (gSize / 1.12), -hSize, hSize) / 2;
			var lmax:Float = FlxMath.bound(((index < wavData[0][1].length && index >= 0) ? wavData[0][1][index] : 0) * (gSize / 1.12), -hSize, hSize) / 2;

			var rmin:Float = FlxMath.bound(((index < wavData[1][0].length && index >= 0) ? wavData[1][0][index] : 0) * (gSize / 1.12), -hSize, hSize) / 2;
			var rmax:Float = FlxMath.bound(((index < wavData[1][1].length && index >= 0) ? wavData[1][1][index] : 0) * (gSize / 1.12), -hSize, hSize) / 2;

			waveformSprite.pixels.fillRect(new Rectangle(hSize - (lmin + rmin), index * size, (lmin + rmin) + (lmax + rmax), size), FlxColor.WHITE);
		}
		#else
		waveformSprite.visible = false;
		#end
	}

	function waveformData(buffer:AudioBuffer, bytes:Bytes, time:Float, endTime:Float, multiply:Float = 1, ?array:Array<Array<Array<Float>>>, ?steps:Float):Array<Array<Array<Float>>>
	{
		#if (lime_cffi && !macro)
		if (buffer == null || buffer.data == null) return [[[0], [0]], [[0], [0]]];

		var khz:Float = (buffer.sampleRate / 1000);
		var channels:Int = buffer.channels;

		var index:Int = Std.int(time * khz);

		var samples:Float = ((endTime - time) * khz);

		if (steps == null) steps = 1280;

		var samplesPerRow:Float = samples / steps;
		var samplesPerRowI:Int = Std.int(samplesPerRow);

		var gotIndex:Int = 0;

		var lmin:Float = 0;
		var lmax:Float = 0;

		var rmin:Float = 0;
		var rmax:Float = 0;

		var rows:Float = 0;

		var simpleSample:Bool = true;//samples > 17200;
		var v1:Bool = false;

		if (array == null) array = [[[0], [0]], [[0], [0]]];

		while (index < (bytes.length - 1)) {
			if (index >= 0) {
				var byte:Int = bytes.getUInt16(index * channels * 2);

				if (byte > 65535 / 2) byte -= 65535;

				var sample:Float = (byte / 65535);

				if (sample > 0)
					if (sample > lmax) lmax = sample;
				else if (sample < 0)
					if (sample < lmin) lmin = sample;

				if (channels >= 2) {
					byte = bytes.getUInt16((index * channels * 2) + 2);

					if (byte > 65535 / 2) byte -= 65535;

					sample = (byte / 65535);

					if (sample > 0) {
						if (sample > rmax) rmax = sample;
					} else if (sample < 0) {
						if (sample < rmin) rmin = sample;
					}
				}
			}

			v1 = samplesPerRowI > 0 ? (index % samplesPerRowI == 0) : false;
			while (simpleSample ? v1 : rows >= samplesPerRow) {
				v1 = false;
				rows -= samplesPerRow;

				gotIndex++;

				var lRMin:Float = Math.abs(lmin) * multiply;
				var lRMax:Float = lmax * multiply;

				var rRMin:Float = Math.abs(rmin) * multiply;
				var rRMax:Float = rmax * multiply;

				if (gotIndex > array[0][0].length) array[0][0].push(lRMin);
					else array[0][0][gotIndex - 1] = array[0][0][gotIndex - 1] + lRMin;

				if (gotIndex > array[0][1].length) array[0][1].push(lRMax);
					else array[0][1][gotIndex - 1] = array[0][1][gotIndex - 1] + lRMax;

				if (channels >= 2)
				{
					if (gotIndex > array[1][0].length) array[1][0].push(rRMin);
						else array[1][0][gotIndex - 1] = array[1][0][gotIndex - 1] + rRMin;

					if (gotIndex > array[1][1].length) array[1][1].push(rRMax);
						else array[1][1][gotIndex - 1] = array[1][1][gotIndex - 1] + rRMax;
				}
				else
				{
					if (gotIndex > array[1][0].length) array[1][0].push(lRMin);
						else array[1][0][gotIndex - 1] = array[1][0][gotIndex - 1] + lRMin;

					if (gotIndex > array[1][1].length) array[1][1].push(lRMax);
						else array[1][1][gotIndex - 1] = array[1][1][gotIndex - 1] + lRMax;
				}

				lmin = 0;
				lmax = 0;

				rmin = 0;
				rmax = 0;
			}

			index++;
			rows++;
			if(gotIndex > steps) break;
		}

		return array;
		#else
		return [[[0], [0]], [[0], [0]]];
		#end
	}
	function convertToOldFormat(song:SwagSong):SwagSong
	{
		// 深拷贝：避免修改 PlayState.SONG 的数据影响编辑器状态
		var oldSong:SwagSong = Reflect.copy(song);
		oldSong.notes = song.notes.copy();
		for (i in 0...oldSong.notes.length)
		{
			var srcSec = song.notes[i];
			var dstSec:SwagSection = Reflect.copy(srcSec);
			dstSec.sectionNotes = srcSec.sectionNotes.copy();
			for (j in 0...dstSec.sectionNotes.length)
				dstSec.sectionNotes[j] = srcSec.sectionNotes[j].copy();
			oldSong.notes[i] = dstSec;
		}
		oldSong.events = song.events.copy();
		for (i in 0...oldSong.events.length)
		{
			oldSong.events[i] = song.events[i].copy();
			// 二级 deep copy 事件子数组
			var evt:Array<Dynamic> = oldSong.events[i];
			if (evt.length > 1 && evt[1] != null)
			{
				evt[1] = evt[1].copy();
				for (j in 0...evt[1].length)
				{
					var sub:Array<Dynamic> = evt[1][j];
					if (sub != null) evt[1][j] = sub.copy();
				}
			}
		}

		// ── 确保旧引擎必需的字段 ──

		// 1. gfVersion 不可为 null（旧引擎 onLoadJson 会检查它）
		if (oldSong.gfVersion == null || oldSong.gfVersion.length == 0)
			oldSong.gfVersion = 'gf';

		// 2. player3 兼容字段：旧引擎在 gfVersion==null 时会回退到 player3
		Reflect.setField(oldSong, 'player3', oldSong.gfVersion);

		// 3. validScore：旧引擎 parseJSONshit() 会设置它，但旧格式需要它存在
		oldSong.validScore = true;

		// 4. 确保 arrowSkin / splashSkin 为字符串（旧格式中它们是必需字段）
		if (oldSong.arrowSkin == null) oldSong.arrowSkin = '';
		if (oldSong.splashSkin == null) oldSong.splashSkin = 'noteSplashes';

		// ── 移除新格式特有的字段（旧引擎不认识它们） ──
		for (field in ['format', 'offset', 'gameOverChar', 'gameOverSound', 'gameOverLoop', 'gameOverEnd', 'disableNoteRGB'])
		{
			if (Reflect.hasField(oldSong, field))
				Reflect.deleteField(oldSong, field);
		}

		// ── 将 psych_v1 格式的 note data 转换为旧格式 ──
		// psych_v1: data 0~(K-1) = 玩家/当前活跃方，K~2K-1 = 对方
		// 旧格式:   data 0~(K-1) = 左半，K~2K-1 = 右半，
		//           必须按 mustHitSection 决定哪一半是玩家。
		// 多k: K 取谱面 mania 对应的键数；当 mustHitSection=false 时翻转两半。
		var mania:Int = (oldSong.mania != null && oldSong.mania >= 0 && oldSong.mania < Note.ammo.length) ? Std.int(oldSong.mania) : Note.defaultMania;
		var ammo:Int = Note.ammo[mania];
		for (sec in oldSong.notes)
		{
			for (note in sec.sectionNotes)
			{
				// 跳过事件 note（data = -1）
				var noteData:Int = Std.int(note[1]);
				if (noteData < 0) continue;

				// 转换 note data 布局
				if (!sec.mustHitSection)
				{
					if (noteData >= ammo)
						noteData -= ammo;
					else
						noteData += ammo;
					note[1] = noteData;
				}

				// 转换 noteType：字符串 → 数字索引（旧格式用数字）
				if (note.length > 3 && Std.isOfType(note[3], String) && note[3] != null && note[3].length > 0)
				{
					var typeIndex:Int = Note.defaultNoteTypes.indexOf(note[3]);
					note[3] = (typeIndex >= 0) ? typeIndex : 0;
				}
				else if (note.length <= 3)
				{
					note.push(0); // 补上默认 noteType
				}
				else
				{
					note[3] = 0;
				}
			}
		}

		// ── events 数组 ──
		// 旧 0.6.3 引擎的 SwagSong 原生支持 events 字段，onLoadJson 仅在
		// events==null 时才会从 inline notes 提取。我们直接保留 events 数组即可，
		// 不需要（也不能！）再写回 inline notes，否则 data=-1 的笔记会留在
		// sectionNotes 中，导致旧引擎创建 Note 时 noteData=-1 → colorSwap=null → 崩溃。
		// 若 events 为 null，设空数组以保持旧引擎兼容。
		if (oldSong.events == null)
			oldSong.events = [];

		return oldSong;
	}
	
	function getSectionBeatsForSong(song:SwagSong, section:Int):Float
	{
		var val:Null<Float> = null;
		if(song.notes[section] != null) val = song.notes[section].sectionBeats;
		return val != null ? val : 4;
	}

	// ---- Safe JSON loading with difficulty detection ----

	function loadJsonWithDifficulty(songLowercase:String):Void
	{
		// Ensure CoolUtil.difficulties matches Difficulty.list for Highscore.formatSong
		if(CoolUtil.difficulties.length < 1 && Difficulty.list.length > 0)
			CoolUtil.difficulties = Difficulty.list.copy();

		var foundDifficulties:Array<{name:String, chartName:String, index:Int}> = [];
		var defaultIndex:Int = 0;

		// 1) Standard difficulties from the difficulty list
		for(i in 0...Difficulty.list.length)
		{
			var diff:String = Difficulty.list[i];
			var chartName:String = songLowercase + Difficulty.getFilePath(i);

			if(chartFileExists(songLowercase, chartName))
			{
				foundDifficulties.push({name: diff, chartName: chartName, index: i});
				if(diff == Difficulty.getDefault()) defaultIndex = foundDifficulties.length - 1;
			}
		}

		// 2) Extra difficulties found on disk: any <song>-<something>.json file
		var extraNames:Array<String> = [];
		for(dir in songChartFolders(songLowercase))
		{
			#if sys
			if(!FileSystem.exists(dir)) continue;
			for(file in FileSystem.readDirectory(dir))
			{
				var lower:String = file.toLowerCase();
				if(!lower.startsWith(songLowercase + '-') || !lower.endsWith('.json')) continue;
				var name:String = lower.substr(songLowercase.length + 1, lower.length - songLowercase.length - 6);
				if(name.length < 1 || name == 'events') continue;
				if(!extraNames.contains(name)) extraNames.push(name);
			}
			#else
			var prefix:String = dir + '/';
			for(asset in lime.utils.Assets.list())
			{
				if(!asset.startsWith(prefix)) continue;
				var file:String = asset.substr(prefix.length);
				var lower:String = file.toLowerCase();
				if(!lower.startsWith(songLowercase + '-') || !lower.endsWith('.json')) continue;
				var name:String = lower.substr(songLowercase.length + 1, lower.length - songLowercase.length - 6);
				if(name.length < 1 || name == 'events') continue;
				if(!extraNames.contains(name)) extraNames.push(name);
			}
			#end
		}
		for(name in extraNames)
		{
			var already:Bool = false;
			for(d in foundDifficulties)
			{
				if(d.chartName == '$songLowercase-$name' || d.name.toLowerCase() == name)
				{
					already = true;
					break;
				}
			}
			if(already) continue;
			foundDifficulties.push({name: name.charAt(0).toUpperCase() + name.substr(1), chartName: '$songLowercase-$name', index: -1});
		}

		if(foundDifficulties.length < 1)
		{
			// Try loading without any difficulty suffix
			if(chartFileExists(songLowercase, songLowercase))
				doLoadJson(songLowercase, -1);
			else
				showOutput('newchartEditor_error_not_valid_chart', true);
			return;
		}

		if(foundDifficulties.length == 1)
		{
			doLoadJson(songLowercase, foundDifficulties[0].index, foundDifficulties[0].chartName);
			return;
		}

		// Multiple difficulties found — show selection prompt
		var diffLabels:Array<String> = [];
		for(d in foundDifficulties)
			diffLabels.push(d.name);

		var radioGrp:PsychUIRadioGroup = new PsychUIRadioGroup(0, 0, diffLabels, 35, 6, false, 200);
		radioGrp.checked = defaultIndex;

		var itemCount:Int = Std.int(Math.min(diffLabels.length, 6));
		var promptHeight:Float = 100 + itemCount * 35 + 70;
		openSubState(new BasePrompt(420, promptHeight,
			'newchartEditor_select_difficulty',
			function(state:BasePrompt)
			{
				radioGrp.x = state.bg.x + 20;
				radioGrp.y = state.bg.y + 60;
				radioGrp.cameras = state.cameras;
				state.add(radioGrp);

				var btnY:Float = state.bg.y + state.bg.height - 45;
				var confirmBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_load_btn', 'Load'), function()
				{
					state.close();
					doLoadJson(songLowercase, foundDifficulties[radioGrp.checked].index, foundDifficulties[radioGrp.checked].chartName);
				});
				confirmBtn.screenCenter(X);
				confirmBtn.x -= 100;
				confirmBtn.cameras = state.cameras;
				confirmBtn.normalStyle.bgColor = FlxColor.GREEN;
				confirmBtn.normalStyle.textColor = FlxColor.WHITE;
				state.add(confirmBtn);

				var cancelBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_cancel_btn', 'Cancel'), function()
				{
					state.close();
				});
				cancelBtn.screenCenter(X);
				cancelBtn.x += 100;
				cancelBtn.cameras = state.cameras;
				state.add(cancelBtn);
			}
		));
	}

	function doLoadJson(songLowercase:String, diffIndex:Int, ?chartName:String = null):Void
	{
		var loadedChart:SwagSong = null;

		if(chartName != null && chartName.length > 0)
		{
			// Explicit chart file name (also covers custom difficulties)
			loadedChart = Song.getChart(chartName, songLowercase);
			if(loadedChart != null && Reflect.hasField(loadedChart, 'song') && diffIndex >= 0)
				PlayState.storyDifficulty = diffIndex;
		}
		else if(diffIndex >= 0)
		{
			var chartName:String = songLowercase + Difficulty.getFilePath(diffIndex);
			loadedChart = Song.getChart(chartName, songLowercase);
			if(loadedChart != null && Reflect.hasField(loadedChart, 'song'))
				PlayState.storyDifficulty = diffIndex;
		}
		else
		{
			loadedChart = Song.getChart(songLowercase, songLowercase);
		}

		// Try CNE format detection if normal parse didn't yield a valid chart
		if(loadedChart == null || !Reflect.hasField(loadedChart, 'song'))
		{
			// Attempt to read the raw file and check for CNE format
			var rawJson:String = null;
			var baseChart:String = (chartName != null && chartName.length > 0) ? chartName : songLowercase;
			#if MODS_ALLOWED
			var moddyFile:String = Paths.modsJson('$songLowercase/$baseChart');
			if(FileSystem.exists(moddyFile)) rawJson = File.getContent(moddyFile).trim();
			#end
			if(rawJson == null)
			{
				try {
					var path:String = Paths.json('$songLowercase/$baseChart');
					#if sys
					if(FileSystem.exists(path)) rawJson = File.getContent(path).trim();
					#else
					if(Assets.exists(path)) rawJson = Assets.getText(path).trim();
					#end
				} catch(e:Dynamic) {}
			}

			if(rawJson != null && CneExport.isCneFormat(rawJson))
			{
				loadedChart = CneExport.cneToPsych(rawJson);
				loadedChart.format = "psych_v1_convert";
			}
		}

		if(loadedChart == null || !Reflect.hasField(loadedChart, 'song'))
		{
			showOutput('newchartEditor_error_not_valid_chart', true);
			return;
		}

		loadChart(loadedChart);
		Song.chartPath = songLowercase;
		reloadNotesDropdowns();
		prepareReload();
		showOutput('newchartEditor_chart_reloaded_old', false, [songLowercase]);
	}

	/** True when a chart file exists for the given song folder + chart name. */
	function chartFileExists(songLowercase:String, chartName:String):Bool
	{
		#if MODS_ALLOWED
		if(FileSystem.exists(Paths.modsJson('$songLowercase/$chartName'))) return true;
		if(FileSystem.exists(Paths.json('$songLowercase/$chartName'))) return true;
		#else
		try { if(Assets.exists(Paths.json('$songLowercase/$chartName'))) return true; } catch(e:Dynamic) {}
		#end
		return false;
	}

	/** Data folders that may contain chart files for this song. */
	function songChartFolders(songLowercase:String):Array<String>
	{
		var dirs:Array<String> = [];
		#if MODS_ALLOWED
		if(Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			dirs.push(Paths.mods(Paths.currentModDirectory + '/data/' + songLowercase));
		for(mod in Paths.getGlobalMods())
			dirs.push(Paths.mods(mod + '/data/' + songLowercase));
		dirs.push(Paths.mods('data/' + songLowercase));
		#end
		dirs.push(Paths.getPreloadPath('data/' + songLowercase));
		return dirs;
	}

}
