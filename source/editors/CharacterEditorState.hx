package editors;

#if cpp
import Discord.DiscordClient;
#end
import animateatlas.AtlasFrameMaker;

import flixel.FlxObject;

import flixel.FlxState;

import flixel.input.keyboard.FlxKey;
import flixel.addons.display.FlxGridOverlay;

import flixel.graphics.FlxGraphic;

import flixel.ui.FlxButton;
import flixel.ui.FlxSpriteButton;
import haxe.Json;
import editors.content.FileDialogHandler;
import Character;
import flixel.system.debug.interaction.tools.Pointer.GraphicCursorCross;
import lime.system.Clipboard;
import flixel.animation.FlxAnimation;
import backend.ui.*;

#if MODS_ALLOWED
import sys.FileSystem;
#end

using StringTools;

class CharacterEditorState extends MusicBeatState implements PsychUIEventHandler.PsychUIEvent
{
	var char:Character;
	var ghostChar:Character;
	var textAnim:EditorsText;
	var bgLayer:FlxTypedGroup<FlxSprite>;
	var charLayer:FlxTypedGroup<Character>;
	var dumbTexts:FlxTypedGroup<EditorsText>;
	var curAnim:Int = 0;
	var daAnim:String = 'spooky';
	var goToPlayState:Bool = true;
	var camFollow:FlxObject;

	/** Unsaved changes flag — prompts confirm dialog on exit. */
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

	public function new(daAnim:String = 'spooky', goToPlayState:Bool = true)
	{
		super();
		this.daAnim = daAnim;
		this.goToPlayState = goToPlayState;
	}

	var UI_box:PsychUIBox;
	var UI_characterbox:PsychUIBox;

	private var camEditor:FlxCamera;
	private var camHUD:FlxCamera;
	private var camMenu:FlxCamera;

	var changeBGbutton:PsychUIButton;
	var leHealthIcon:HealthIcon;
	var characterList:Array<String> = [];

	var cameraFollowPointer:FlxSprite;
	var healthBarBG:FlxSprite;

	override function create()
	{
		clearUnsaved();
		camEditor = new FlxCamera();
		camHUD = new FlxCamera();
		camHUD.bgColor.alpha = 0;
		camMenu = new FlxCamera();
		camMenu.bgColor.alpha = 0;

		FlxG.cameras.reset(camEditor);
		FlxG.cameras.add(camHUD, false);
		FlxG.cameras.add(camMenu, false);
		FlxG.cameras.setDefaultDrawTarget(camEditor, true);

		bgLayer = new FlxTypedGroup<FlxSprite>();
		add(bgLayer);
		charLayer = new FlxTypedGroup<Character>();
		add(charLayer);

		var pointer:FlxGraphic = FlxGraphic.fromClass(GraphicCursorCross);
		cameraFollowPointer = new FlxSprite().loadGraphic(pointer);
		cameraFollowPointer.setGraphicSize(40, 40);
		cameraFollowPointer.updateHitbox();
		cameraFollowPointer.color = FlxColor.WHITE;
		add(cameraFollowPointer);

		changeBGbutton = new PsychUIButton(FlxG.width - 360, 25, '', function()
		{
			onPixelBG = !onPixelBG;
			reloadBGs();
		}, 80, 20);
		changeBGbutton.cameras = [camMenu];

		loadChar(!daAnim.startsWith('bf'), false);

		healthBarBG = new FlxSprite(30, FlxG.height - 75).loadGraphic(Paths.image('healthBar'));
		healthBarBG.scrollFactor.set();
		add(healthBarBG);
		healthBarBG.cameras = [camHUD];

		leHealthIcon = new HealthIcon(char.healthIcon, false);
		leHealthIcon.y = FlxG.height - 150;
		add(leHealthIcon);
		leHealthIcon.cameras = [camHUD];

		dumbTexts = new FlxTypedGroup<EditorsText>();
		add(dumbTexts);
		dumbTexts.cameras = [camHUD];

		textAnim = new EditorsText(300, 16);
		textAnim.setFormat(Paths.font("editors.ttf"), 16, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		textAnim.borderSize = 1;
		textAnim.size = 32;
		textAnim.scrollFactor.set();
		textAnim.cameras = [camHUD];
		add(textAnim);

		genBoyOffsets();

		camFollow = new FlxObject(0, 0, 2, 2);
		camFollow.screenCenter();
		add(camFollow);

		var tipTextArray:Array<String> = "E/Q - Camera Zoom In/Out
		\nR - Reset Camera Zoom
		\nJKLI - Move Camera
		\nW/S - Previous/Next Animation
		\nSpace - Play Animation
		\nArrow Keys - Move Character Offset
		\nT - Reset Current Offset
		\nHold Shift to Move 10x faster\n".split('\n');

		for (i in 0...tipTextArray.length-1)
		{
			var tipText:EditorsText = new EditorsText(FlxG.width - 320, FlxG.height - 15 - 16 * (tipTextArray.length - i), 300, tipTextArray[i], 12);
			tipText.cameras = [camHUD];
			tipText.setFormat(null, 12, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
			tipText.scrollFactor.set();
			tipText.borderSize = 1;
			add(tipText);
		}

		FlxG.camera.follow(camFollow);

		var tabs = [
			Language.get('characterEditor_settings', 'Settings')
		];

		UI_box = new PsychUIBox(FlxG.width - 275, 25, 250, 120, tabs);
		UI_box.cameras = [camMenu];
		UI_box.scrollFactor.set();

		var chartabs = [
			Language.get('characterEditor_character', 'Character'),
			Language.get('characterEditor_animations', 'Animations')
		];
		// 面板加宽到 380: 0.6.3 的 350px 放不下 "数字步进器 + 按钮" 这一整行,
	// 右边的 X/Y 两个步进器会叠在一起 (值被盖住、只剩一对 +/-)。
	UI_characterbox = new PsychUIBox(UI_box.x - 130, UI_box.y + UI_box.height, 380, 250, chartabs);
		UI_characterbox.cameras = [camMenu];
		UI_characterbox.scrollFactor.set();
		add(UI_characterbox);
		for (tab in UI_characterbox.tabs) tab.text.font = 'assets/fonts/editors.ttf';
		add(UI_box);
		for (tab in UI_box.tabs) tab.text.font = 'assets/fonts/editors.ttf';
		add(changeBGbutton);

		addSettingsUI();
		addCharacterUI();
		addAnimationsUI();
		UI_characterbox.selectedIndex = 0;

		FlxG.mouse.visible = true;
		reloadCharacterOptions();
		#if (android || desktop)
		addVirtualPad(LEFT_FULL, CHARACTER_EDITOR);
		addPadCamera();
		#end

		fileDialog = new FileDialogHandler();
		super.create();
	}

	var onPixelBG:Bool = false;
	var OFFSET_X:Float = 300;
	function reloadBGs() {
		var i:Int = bgLayer.members.length-1;
		while(i >= 0) {
			var memb:FlxSprite = bgLayer.members[i];
			if(memb != null) {
				memb.kill();
				bgLayer.remove(memb);
				memb.destroy();
			}
			--i;
		}
		bgLayer.clear();
		var playerXDifference = 0;
		if(char.isPlayer) playerXDifference = 670;

		if(onPixelBG) {
			var playerYDifference:Float = 0;
			if(char.isPlayer) {
				playerXDifference += 200;
				playerYDifference = 220;
			}

			var bgSky:BGSprite = new BGSprite('weeb/weebSky', OFFSET_X - (playerXDifference / 2) - 300, 0 - playerYDifference, 0.1, 0.1);
			bgLayer.add(bgSky);
			bgSky.antialiasing = false;

			var repositionShit = -200 + OFFSET_X - playerXDifference;

			var bgSchool:BGSprite = new BGSprite('weeb/weebSchool', repositionShit, -playerYDifference + 6, 0.6, 0.90);
			bgLayer.add(bgSchool);
			bgSchool.antialiasing = false;

			var bgStreet:BGSprite = new BGSprite('weeb/weebStreet', repositionShit, -playerYDifference, 0.95, 0.95);
			bgLayer.add(bgStreet);
			bgStreet.antialiasing = false;

			var widShit = Std.int(bgSky.width * 6);
			var bgTrees:FlxSprite = new FlxSprite(repositionShit - 380, -800 - playerYDifference);
			bgTrees.frames = Paths.getPackerAtlas('weeb/weebTrees');
			bgTrees.animation.add('treeLoop', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18], 12);
			bgTrees.animation.play('treeLoop');
			bgTrees.scrollFactor.set(0.85, 0.85);
			bgLayer.add(bgTrees);
			bgTrees.antialiasing = false;

			bgSky.setGraphicSize(widShit);
			bgSchool.setGraphicSize(widShit);
			bgStreet.setGraphicSize(widShit);
			bgTrees.setGraphicSize(Std.int(widShit * 1.4));

			bgSky.updateHitbox();
			bgSchool.updateHitbox();
			bgStreet.updateHitbox();
			bgTrees.updateHitbox();
			changeBGbutton.label = Language.get('characterEditor_regular_bg', 'Regular BG');
		} else {
			var bg:BGSprite = new BGSprite('stageback', -600 + OFFSET_X - playerXDifference, -300, 0.9, 0.9);
			bgLayer.add(bg);

			var stageFront:BGSprite = new BGSprite('stagefront', -650 + OFFSET_X - playerXDifference, 500, 0.9, 0.9);
			stageFront.setGraphicSize(Std.int(stageFront.width * 1.1));
			stageFront.updateHitbox();
			bgLayer.add(stageFront);
			changeBGbutton.label = Language.get('characterEditor_pixel_bg', 'Pixel BG');
		}
	}

	var TemplateCharacter:String = '{
			"animations": [
				{
					"loop": false,
					"offsets": [
						0,
						0
					],
					"fps": 24,
					"anim": "idle",
					"indices": [],
					"name": "Dad idle dance"
				},
				{
					"offsets": [
						0,
						0
					],
					"indices": [],
					"fps": 24,
					"anim": "singLEFT",
					"loop": false,
					"name": "Dad Sing Note LEFT"
				},
				{
					"offsets": [
						0,
						0
					],
					"indices": [],
					"fps": 24,
					"anim": "singDOWN",
					"loop": false,
					"name": "Dad Sing Note DOWN"
				},
				{
					"offsets": [
						0,
						0
					],
					"indices": [],
					"fps": 24,
					"anim": "singUP",
					"loop": false,
					"name": "Dad Sing Note UP"
				},
				{
					"offsets": [
						0,
						0
					],
					"indices": [],
					"fps": 24,
					"anim": "singRIGHT",
					"loop": false,
					"name": "Dad Sing Note RIGHT"
				}
			],
			"no_antialiasing": false,
			"image": "characters/DADDY_DEAREST",
			"position": [
				0,
				0
			],
			"healthicon": "face",
			"flip_x": false,
			"healthbar_colors": [
				161,
				161,
				161
			],
			"camera_position": [
				0,
				0
			],
			"sing_duration": 6.1,
			"scale": 1
		}';

	var charDropDown:PsychUIDropDownMenu;
	function addSettingsUI() {
		var tab = UI_box.getTab(Language.get('characterEditor_settings', 'Settings'));
		if(tab == null) return;
		var tab_group = tab.menu;

		var check_player = new PsychUICheckBox(10, 60, Language.get('characterEditor_playable_character', 'Playable Character'), 100, null);
		check_player.checked = daAnim.startsWith('bf');
		check_player.onClick = function()
		{
			char.isPlayer = !char.isPlayer;
			char.flipX = !char.flipX;
			updatePointerPos();
			reloadBGs();
			ghostChar.flipX = char.flipX;
		};

		charDropDown = new PsychUIDropDownMenu(10, 30, [''], function(index:Int, label:String)
		{
			daAnim = characterList[index];
			check_player.checked = daAnim.startsWith('bf');
			loadChar(!check_player.checked);
			updatePresence();
			reloadCharacterDropDown();
		});
		charDropDown.selectedLabel = daAnim;
		charDropDown.textObj.font = 'assets/fonts/editors.ttf';
		reloadCharacterDropDown();

		var reloadCharacter = new PsychUIButton(140, 20, Language.get('characterEditor_reload_char', 'Reload Char'), function()
		{
			loadChar(!check_player.checked);
			reloadCharacterDropDown();
		}, 80, 20);

		var templateCharacter = new PsychUIButton(140, 50, Language.get('characterEditor_load_template', 'Load Template'), function()
		{
			var parsedJson:CharacterFile = cast Json.parse(TemplateCharacter);
			var characters:Array<Character> = [char, ghostChar];
			for (character in characters)
			{
				character.animOffsets.clear();
				character.animationsArray = parsedJson.animations;
				for (anim in character.animationsArray)
				{
					character.addOffset(anim.anim, anim.offsets[0], anim.offsets[1]);
				}
				if(character.animationsArray[0] != null) {
					character.playAnim(character.animationsArray[0].anim, true);
				}

				character.singDuration = parsedJson.sing_duration;
				character.positionArray = parsedJson.position;
				character.cameraPosition = parsedJson.camera_position;

				character.imageFile = parsedJson.image;
				character.jsonScale = parsedJson.scale;
				character.noAntialiasing = parsedJson.no_antialiasing;
				character.originalFlipX = parsedJson.flip_x;
				character.healthIcon = parsedJson.healthicon;
				character.healthColorArray = parsedJson.healthbar_colors;
				character.setPosition(character.positionArray[0] + OFFSET_X + 100, character.positionArray[1]);
			}

			reloadCharacterImage();
			reloadCharacterDropDown();
			reloadCharacterOptions();
			resetHealthBarColor();
			updatePointerPos();
			genBoyOffsets();
		}, 80, 20);
		templateCharacter.normalStyle.bgColor = FlxColor.RED;
		templateCharacter.normalStyle.textColor = FlxColor.WHITE;

		tab_group.add(new EditorsText(charDropDown.x, charDropDown.y - 18, 0, Language.get('characterEditor_character_label', 'Character:')));
		tab_group.add(check_player);
		tab_group.add(reloadCharacter);
		tab_group.add(templateCharacter);
		tab_group.add(charDropDown);
	}

	var imageInputText:PsychUIInputText;
	var healthIconInputText:PsychUIInputText;

	var singDurationStepper:PsychUINumericStepper;
	var scaleStepper:PsychUINumericStepper;
	var positionXStepper:PsychUINumericStepper;
	var positionYStepper:PsychUINumericStepper;
	var positionCameraXStepper:PsychUINumericStepper;
	var positionCameraYStepper:PsychUINumericStepper;

	var flipXCheckBox:PsychUICheckBox;
	var noAntialiasingCheckBox:PsychUICheckBox;

	var healthColorStepperR:PsychUINumericStepper;
	var healthColorStepperG:PsychUINumericStepper;
	var healthColorStepperB:PsychUINumericStepper;

	function addCharacterUI() {
		var tab = UI_characterbox.getTab(Language.get('characterEditor_character', 'Character'));
		if(tab == null) return;
		var tab_group = tab.menu;

		imageInputText = new PsychUIInputText(15, 30, 200, 'characters/BOYFRIEND', 8);
		imageInputText.onChange = function(oldText:String, newText:String) {
			char.imageFile = newText;
		};

		var reloadImage = new PsychUIButton(imageInputText.x + 210, imageInputText.y - 3, Language.get('characterEditor_reload_image', 'Reload Image'), function()
		{
			char.imageFile = imageInputText.text;
			reloadCharacterImage();
			if(char.animation.curAnim != null) {
				char.playAnim(char.animation.curAnim.name, true);
			}
		}, 80, 20);

		var decideIconColor = new PsychUIButton(reloadImage.x, reloadImage.y + 30, Language.get('characterEditor_get_icon_color', 'Get Icon Color'), function()
			{
				var coolColor = FlxColor.fromInt(CoolUtil.dominantColor(leHealthIcon));
				healthColorStepperR.value = coolColor.red;
				healthColorStepperG.value = coolColor.green;
				healthColorStepperB.value = coolColor.blue;
				onHealthColorChange();
			}, 80, 20);

		healthIconInputText = new PsychUIInputText(15, imageInputText.y + 35, 75, leHealthIcon.getCharacter(), 8);
		healthIconInputText.onChange = function(oldText:String, newText:String) {
			leHealthIcon.changeIcon(newText);
			char.healthIcon = newText;
			updatePresence();
		};

		singDurationStepper = new PsychUINumericStepper(15, healthIconInputText.y + 45, 0.1, 4, 0, 999, 1);
		singDurationStepper.textObj.font = 'assets/fonts/editors.ttf';
		singDurationStepper.onValueChange = function() {
			char.singDuration = singDurationStepper.value;
		};

		scaleStepper = new PsychUINumericStepper(15, singDurationStepper.y + 40, 0.1, 1, 0.05, 10, 1);
		scaleStepper.textObj.font = 'assets/fonts/editors.ttf';
		scaleStepper.onValueChange = function() {
			reloadCharacterImage();
			char.jsonScale = scaleStepper.value;
			char.setGraphicSize(Std.int(char.width * char.jsonScale));
			char.updateHitbox();
			ghostChar.setGraphicSize(Std.int(ghostChar.width * char.jsonScale));
			ghostChar.updateHitbox();
			reloadGhost();
			updatePointerPos();

			if(char.animation.curAnim != null) {
				char.playAnim(char.animation.curAnim.name, true);
			}
		};

		flipXCheckBox = new PsychUICheckBox(singDurationStepper.x + 100, singDurationStepper.y, Language.get('characterEditor_flip_x', 'Flip X'), 70, null);
		flipXCheckBox.checked = char.flipX;
		if(char.isPlayer) flipXCheckBox.checked = !flipXCheckBox.checked;
		flipXCheckBox.onClick = function() {
			char.originalFlipX = !char.originalFlipX;
			char.flipX = char.originalFlipX;
			if(char.isPlayer) char.flipX = !char.flipX;

			ghostChar.flipX = char.flipX;
		};

		noAntialiasingCheckBox = new PsychUICheckBox(flipXCheckBox.x, flipXCheckBox.y + 40, Language.get('characterEditor_no_antialiasing', 'No Antialiasing'), 80, null);
		noAntialiasingCheckBox.checked = char.noAntialiasing;
		noAntialiasingCheckBox.onClick = function() {
			char.antialiasing = false;
			if(!noAntialiasingCheckBox.checked && ClientPrefs.data.globalAntialiasing) {
				char.antialiasing = true;
			}
			char.noAntialiasing = noAntialiasingCheckBox.checked;
			ghostChar.antialiasing = char.antialiasing;
		};

		positionXStepper = new PsychUINumericStepper(flipXCheckBox.x + 105, flipXCheckBox.y, 10, char.positionArray[0], -9000, 9000, 0, 45);
		positionXStepper.textObj.font = 'assets/fonts/editors.ttf';
		positionXStepper.onValueChange = function() {
			char.positionArray[0] = positionXStepper.value;
			char.x = char.positionArray[0] + OFFSET_X + 100;
			updatePointerPos();
		};

		positionYStepper = new PsychUINumericStepper(positionXStepper.x + 85, positionXStepper.y, 10, char.positionArray[1], -9000, 9000, 0, 45);
		positionYStepper.textObj.font = 'assets/fonts/editors.ttf';
		positionYStepper.onValueChange = function() {
			char.positionArray[1] = positionYStepper.value;
			char.y = char.positionArray[1];
			updatePointerPos();
		};

		positionCameraXStepper = new PsychUINumericStepper(positionXStepper.x, positionXStepper.y + 40, 10, char.cameraPosition[0], -9000, 9000, 0);
		positionCameraXStepper.textObj.font = 'assets/fonts/editors.ttf';
		positionCameraXStepper.onValueChange = function() {
			char.cameraPosition[0] = positionCameraXStepper.value;
			updatePointerPos();
		};

		positionCameraYStepper = new PsychUINumericStepper(positionYStepper.x, positionYStepper.y + 40, 10, char.cameraPosition[1], -9000, 9000, 0);
		positionCameraYStepper.textObj.font = 'assets/fonts/editors.ttf';
		positionCameraYStepper.onValueChange = function() {
			char.cameraPosition[1] = positionCameraYStepper.value;
			updatePointerPos();
		};

		var saveCharacterButton = new PsychUIButton(290, noAntialiasingCheckBox.y + 40, Language.get('characterEditor_save_character', 'Save Character'), function() {
			saveCharacter();
		}, 80, 20);

		healthColorStepperR = new PsychUINumericStepper(singDurationStepper.x, saveCharacterButton.y, 20, char.healthColorArray[0], 0, 255, 0, 45);
		healthColorStepperR.textObj.font = 'assets/fonts/editors.ttf';
		healthColorStepperR.onValueChange = onHealthColorChange;
		healthColorStepperG = new PsychUINumericStepper(singDurationStepper.x + 95, saveCharacterButton.y, 20, char.healthColorArray[1], 0, 255, 0, 45);
		healthColorStepperG.textObj.font = 'assets/fonts/editors.ttf';
		healthColorStepperG.onValueChange = onHealthColorChange;
		healthColorStepperB = new PsychUINumericStepper(singDurationStepper.x + 190, saveCharacterButton.y, 20, char.healthColorArray[2], 0, 255, 0, 45);
		healthColorStepperB.textObj.font = 'assets/fonts/editors.ttf';
		healthColorStepperB.onValueChange = onHealthColorChange;

		tab_group.add(new EditorsText(15, imageInputText.y - 18, 0, Language.get('characterEditor_image_file', 'Image file name:')));
		tab_group.add(new EditorsText(15, healthIconInputText.y - 18, 0, Language.get('characterEditor_health_icon', 'Health icon name:')));
		tab_group.add(new EditorsText(15, singDurationStepper.y - 18, 0, Language.get('characterEditor_sing_duration', 'Sing Animation length:')));
		tab_group.add(new EditorsText(15, scaleStepper.y - 18, 0, Language.get('characterEditor_scale', 'Scale:')));
		tab_group.add(new EditorsText(positionXStepper.x, positionXStepper.y - 18, 0, Language.get('characterEditor_char_xy', 'Character X/Y:')));
		tab_group.add(new EditorsText(positionCameraXStepper.x, positionCameraXStepper.y - 18, 0, Language.get('characterEditor_camera_xy', 'Camera X/Y:')));
		tab_group.add(new EditorsText(healthColorStepperR.x, healthColorStepperR.y - 18, 0, Language.get('characterEditor_health_rgb', 'Health bar R/G/B:')));
		tab_group.add(imageInputText);
		tab_group.add(reloadImage);
		tab_group.add(decideIconColor);
		tab_group.add(healthIconInputText);
		tab_group.add(singDurationStepper);
		tab_group.add(scaleStepper);
		tab_group.add(flipXCheckBox);
		tab_group.add(noAntialiasingCheckBox);
		tab_group.add(positionXStepper);
		tab_group.add(positionYStepper);
		tab_group.add(positionCameraXStepper);
		tab_group.add(positionCameraYStepper);
		tab_group.add(healthColorStepperR);
		tab_group.add(healthColorStepperG);
		tab_group.add(healthColorStepperB);
		tab_group.add(saveCharacterButton);
	}

	function onHealthColorChange() {
		char.healthColorArray[0] = Math.round(healthColorStepperR.value);
		char.healthColorArray[1] = Math.round(healthColorStepperG.value);
		char.healthColorArray[2] = Math.round(healthColorStepperB.value);
		healthBarBG.color = FlxColor.fromRGB(char.healthColorArray[0], char.healthColorArray[1], char.healthColorArray[2]);
	}

	var ghostDropDown:PsychUIDropDownMenu;
	var animationDropDown:PsychUIDropDownMenu;
	var animationInputText:PsychUIInputText;
	var animationNameInputText:PsychUIInputText;
	var animationIndicesInputText:PsychUIInputText;
	var animationNameFramerate:PsychUINumericStepper;
	var animationLoopCheckBox:PsychUICheckBox;
	function addAnimationsUI() {
		var tab = UI_characterbox.getTab(Language.get('characterEditor_animations', 'Animations'));
		if(tab == null) return;
		var tab_group = tab.menu;

		animationInputText = new PsychUIInputText(15, 85, 80, '', 8);
		animationNameInputText = new PsychUIInputText(animationInputText.x, animationInputText.y + 35, 150, '', 8);
		animationIndicesInputText = new PsychUIInputText(animationNameInputText.x, animationNameInputText.y + 40, 250, '', 8);
		animationNameFramerate = new PsychUINumericStepper(animationInputText.x + 170, animationInputText.y, 1, 24, 0, 240, 0);
		animationNameFramerate.textObj.font = 'assets/fonts/editors.ttf';
		animationLoopCheckBox = new PsychUICheckBox(animationNameInputText.x + 170, animationNameInputText.y - 1, Language.get('characterEditor_should_loop', 'Should it Loop?'), 100, null);

		animationDropDown = new PsychUIDropDownMenu(15, animationInputText.y - 55, [''], function(index:Int, label:String) {
			var anim:AnimArray = char.animationsArray[index];
			if(anim == null) return;
			animationInputText.text = anim.anim;
			animationNameInputText.text = anim.name;
			animationLoopCheckBox.checked = anim.loop;
			animationNameFramerate.value = anim.fps;

			var indicesStr:String = anim.indices.toString();
			animationIndicesInputText.text = indicesStr.substr(1, indicesStr.length - 2);
		});
		animationDropDown.textObj.font = 'assets/fonts/editors.ttf';

		ghostDropDown = new PsychUIDropDownMenu(animationDropDown.x + 150, animationDropDown.y, [''], function(index:Int, label:String) {
			ghostChar.visible = false;
			char.alpha = 1;
			if(index > 0) {
				ghostChar.visible = true;
				ghostChar.playAnim(ghostChar.animationsArray[index-1].anim, true);
				char.alpha = 0.85;
			}
		});
		ghostDropDown.textObj.font = 'assets/fonts/editors.ttf';

		var addUpdateButton = new PsychUIButton(70, animationIndicesInputText.y + 30, Language.get('characterEditor_add_update', 'Add/Update'), function() {
			var indices:Array<Int> = [];
			var indicesStr:Array<String> = animationIndicesInputText.text.trim().split(',');
			if(indicesStr.length > 1) {
				for (i in 0...indicesStr.length) {
					var index:Int = Std.parseInt(indicesStr[i]);
					if(indicesStr[i] != null && indicesStr[i] != '' && !Math.isNaN(index) && index > -1) {
						indices.push(index);
					}
				}
			}

			var lastAnim:String = '';
			if(char.animationsArray[curAnim] != null) {
				lastAnim = char.animationsArray[curAnim].anim;
			}

			var lastOffsets:Array<Int> = [0, 0];
			for (anim in char.animationsArray) {
				if(animationInputText.text == anim.anim) {
					lastOffsets = anim.offsets;
					if(char.animation.getByName(animationInputText.text) != null) {
						char.animation.remove(animationInputText.text);
					}
					char.animationsArray.remove(anim);
				}
			}

			var newAnim:AnimArray = {
				anim: animationInputText.text,
				name: animationNameInputText.text,
				fps: Math.round(animationNameFramerate.value),
				loop: animationLoopCheckBox.checked,
				indices: indices,
				offsets: lastOffsets
			};
			if(indices != null && indices.length > 0) {
				char.animation.addByIndices(newAnim.anim, newAnim.name, newAnim.indices, "", newAnim.fps, newAnim.loop);
			} else {
				char.animation.addByPrefix(newAnim.anim, newAnim.name, newAnim.fps, newAnim.loop);
			}

			if(!char.animOffsets.exists(newAnim.anim)) {
				char.addOffset(newAnim.anim, 0, 0);
			}
			char.animationsArray.push(newAnim);

			if(lastAnim == animationInputText.text) {
				var leAnim:FlxAnimation = char.animation.getByName(lastAnim);
				if(leAnim != null && leAnim.frames.length > 0) {
					char.playAnim(lastAnim, true);
				} else {
					for(i in 0...char.animationsArray.length) {
						if(char.animationsArray[i] != null) {
							leAnim = char.animation.getByName(char.animationsArray[i].anim);
							if(leAnim != null && leAnim.frames.length > 0) {
								char.playAnim(char.animationsArray[i].anim, true);
								curAnim = i;
								break;
							}
						}
					}
				}
			}

			reloadAnimationDropDown();
			genBoyOffsets();
			CoolUtil.traceMsg('trace.animAdded', 'Added/Updated animation: {}', [animationInputText.text]);
		}, 100, 20);

		var removeButton = new PsychUIButton(180, animationIndicesInputText.y + 30, Language.get('characterEditor_remove', 'Remove'), function() {
			for (anim in char.animationsArray) {
				if(animationInputText.text == anim.anim) {
					var resetAnim:Bool = false;
					if(char.animation.curAnim != null && anim.anim == char.animation.curAnim.name) resetAnim = true;

					if(char.animation.getByName(anim.anim) != null) {
						char.animation.remove(anim.anim);
					}
					if(char.animOffsets.exists(anim.anim)) {
						char.animOffsets.remove(anim.anim);
					}
					char.animationsArray.remove(anim);

					if(resetAnim && char.animationsArray.length > 0) {
						char.playAnim(char.animationsArray[0].anim, true);
					}
					reloadAnimationDropDown();
					genBoyOffsets();
					CoolUtil.traceMsg('trace.animRemoved', 'Removed animation: {}', [animationInputText.text]);
					break;
				}
			}
		}, 80, 20);

		tab_group.add(new EditorsText(animationDropDown.x, animationDropDown.y - 18, 0, Language.get('characterEditor_animations_label', 'Animations:')));
		tab_group.add(new EditorsText(ghostDropDown.x, ghostDropDown.y - 18, 0, Language.get('characterEditor_animation_ghost', 'Animation Ghost:')));
		tab_group.add(new EditorsText(animationInputText.x, animationInputText.y - 18, 0, Language.get('characterEditor_animation_name', 'Animation name:')));
		tab_group.add(new EditorsText(animationNameFramerate.x, animationNameFramerate.y - 18, 0, Language.get('characterEditor_framerate', 'Framerate:')));
		tab_group.add(new EditorsText(animationNameInputText.x, animationNameInputText.y - 18, 0, Language.get('characterEditor_animation_xml', 'Animation on .XML/.TXT file:')));
		tab_group.add(new EditorsText(animationIndicesInputText.x, animationIndicesInputText.y - 18, 0, Language.get('characterEditor_animation_indices', 'ADVANCED - Animation Indices:')));

		tab_group.add(animationInputText);
		tab_group.add(animationNameInputText);
		tab_group.add(animationIndicesInputText);
		tab_group.add(animationNameFramerate);
		tab_group.add(animationLoopCheckBox);
		tab_group.add(addUpdateButton);
		tab_group.add(removeButton);
		tab_group.add(ghostDropDown);
		tab_group.add(animationDropDown);
	}

	public function UIEvent(id:String, sender:Dynamic) {
		// events handled via direct callbacks
	}

	function reloadCharacterImage() {
		var lastAnim:String = '';
		if(char.animation.curAnim != null) {
			lastAnim = char.animation.curAnim.name;
		}
		var anims:Array<AnimArray> = char.animationsArray.copy();
		if(Paths.fileExists('images/' + char.imageFile + '/Animation.json', TEXT)) {
			char.frames = AtlasFrameMaker.construct(char.imageFile);
		} else if(Paths.fileExists('images/' + char.imageFile + '.txt', TEXT)) {
			char.frames = Paths.getPackerAtlas(char.imageFile);
		} else {
			char.frames = Paths.getSparrowAtlas(char.imageFile);
		}

		if(char.animationsArray != null && char.animationsArray.length > 0) {
			for (anim in char.animationsArray) {
				var animAnim:String = '' + anim.anim;
				var animName:String = '' + anim.name;
				var animFps:Int = anim.fps;
				var animLoop:Bool = !!anim.loop;
				var animIndices:Array<Int> = anim.indices;
				if(animIndices != null && animIndices.length > 0) {
					char.animation.addByIndices(animAnim, animName, animIndices, "", animFps, animLoop);
				} else {
					char.animation.addByPrefix(animAnim, animName, animFps, animLoop);
				}
			}
		} else {
			char.quickAnimAdd('idle', 'BF idle dance');
		}

		if(lastAnim != '') {
			char.playAnim(lastAnim, true);
		} else {
			char.dance();
		}
		ghostDropDown.selectedLabel = '';
		reloadGhost();
	}

	function genBoyOffsets():Void
	{
		var daLoop:Int = 0;

		var i:Int = dumbTexts.members.length-1;
		while(i >= 0) {
			var memb:EditorsText = dumbTexts.members[i];
			if(memb != null) {
				memb.kill();
				dumbTexts.remove(memb);
				memb.destroy();
			}
			--i;
		}
		dumbTexts.clear();

		for (anim => offsets in char.animOffsets)
		{
			var text:EditorsText = new EditorsText(10, 20 + (18 * daLoop), 0, anim + ": " + offsets, 15);
			text.setFormat(null, 16, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			text.scrollFactor.set();
			text.borderSize = 1;
			dumbTexts.add(text);
			text.cameras = [camHUD];

			daLoop++;
		}

		textAnim.visible = true;
		if(dumbTexts.length < 1) {
			var text:EditorsText = new EditorsText(10, 38, 0, "ERROR! No animations found.", 15);
			text.scrollFactor.set();
			text.borderSize = 1;
			dumbTexts.add(text);
			textAnim.visible = false;
		}
	}

	function loadChar(isDad:Bool, blahBlahBlah:Bool = true) {
		var i:Int = charLayer.members.length-1;
		while(i >= 0) {
			var memb:Character = charLayer.members[i];
			if(memb != null) {
				memb.kill();
				charLayer.remove(memb);
				memb.destroy();
			}
			--i;
		}
		charLayer.clear();
		ghostChar = new Character(0, 0, daAnim, !isDad);
		ghostChar.debugMode = true;
		ghostChar.alpha = 0.6;

		char = new Character(0, 0, daAnim, !isDad);
		if(char.animationsArray[0] != null) {
			char.playAnim(char.animationsArray[0].anim, true);
		}
		char.debugMode = true;

		charLayer.add(ghostChar);
		charLayer.add(char);

		char.setPosition(char.positionArray[0] + OFFSET_X + 100, char.positionArray[1]);

		if(blahBlahBlah) {
			genBoyOffsets();
		}
		reloadCharacterOptions();
		reloadBGs();
		updatePointerPos();
	}

	function updatePointerPos() {
		var x:Float = char.getMidpoint().x;
		var y:Float = char.getMidpoint().y;
		if(!char.isPlayer) {
			x += 150 + char.cameraPosition[0];
		} else {
			x -= 100 + char.cameraPosition[0];
		}
		y -= 100 - char.cameraPosition[1];

		x -= cameraFollowPointer.width / 2;
		y -= cameraFollowPointer.height / 2;
		cameraFollowPointer.setPosition(x, y);
	}

	function findAnimationByName(name:String):AnimArray {
		for (anim in char.animationsArray) {
			if(anim.anim == name) {
				return anim;
			}
		}
		return null;
	}

	function reloadCharacterOptions() {
		if(UI_characterbox != null) {
			imageInputText.text = char.imageFile;
			healthIconInputText.text = char.healthIcon;
			singDurationStepper.value = char.singDuration;
			scaleStepper.value = char.jsonScale;
			flipXCheckBox.checked = char.originalFlipX;
			noAntialiasingCheckBox.checked = char.noAntialiasing;
			resetHealthBarColor();
			leHealthIcon.changeIcon(healthIconInputText.text);
			positionXStepper.value = char.positionArray[0];
			positionYStepper.value = char.positionArray[1];
			positionCameraXStepper.value = char.cameraPosition[0];
			positionCameraYStepper.value = char.cameraPosition[1];
			reloadAnimationDropDown();
			updatePresence();
		}
	}

	function reloadAnimationDropDown() {
		var anims:Array<String> = [];
		var ghostAnims:Array<String> = [''];
		for (anim in char.animationsArray) {
			anims.push(anim.anim);
			ghostAnims.push(anim.anim);
		}
		if(anims.length < 1) anims.push('NO ANIMATIONS');

		animationDropDown.list = anims;
		ghostDropDown.list = ghostAnims;
		reloadGhost();
	}

	function reloadGhost() {
		ghostChar.frames = char.frames;
		for (anim in char.animationsArray) {
			var animAnim:String = '' + anim.anim;
			var animName:String = '' + anim.name;
			var animFps:Int = anim.fps;
			var animLoop:Bool = !!anim.loop;
			var animIndices:Array<Int> = anim.indices;
			if(animIndices != null && animIndices.length > 0) {
				ghostChar.animation.addByIndices(animAnim, animName, animIndices, "", animFps, animLoop);
			} else {
				ghostChar.animation.addByPrefix(animAnim, animName, animFps, animLoop);
			}

			if(anim.offsets != null && anim.offsets.length > 1) {
				ghostChar.addOffset(anim.anim, anim.offsets[0], anim.offsets[1]);
			}
		}

		char.alpha = 0.85;
		ghostChar.visible = true;
		if(ghostDropDown.selectedLabel == '') {
			ghostChar.visible = false;
			char.alpha = 1;
		}
		ghostChar.color = 0xFF666688;
		ghostChar.antialiasing = char.antialiasing;
	}

	function reloadCharacterDropDown() {
		var charsLoaded:Map<String, Bool> = new Map();

		#if MODS_ALLOWED
		characterList = [];
		var directories:Array<String> = [Paths.mods('characters/'), Paths.mods(Paths.currentModDirectory + '/characters/'), Paths.getPreloadPath('characters/')];
		for(mod in Paths.getGlobalMods())
			directories.push(Paths.mods(mod + '/characters/'));
		for (i in 0...directories.length) {
			var directory:String = directories[i];
			if(FileSystem.exists(directory)) {
				for (file in FileSystem.readDirectory(directory)) {
					var path = haxe.io.Path.join([directory, file]);
					if (!sys.FileSystem.isDirectory(path) && file.endsWith('.json')) {
						var charToCheck:String = file.substr(0, file.length - 5);
						if(!charsLoaded.exists(charToCheck)) {
							characterList.push(charToCheck);
							charsLoaded.set(charToCheck, true);
						}
					}
				}
			}
		}
		#else
		characterList = CoolUtil.coolTextFile(Paths.txt('characterList'));
		#end

		charDropDown.list = characterList;
		charDropDown.selectedLabel = daAnim;
	}

	function resetHealthBarColor() {
		healthColorStepperR.value = char.healthColorArray[0];
		healthColorStepperG.value = char.healthColorArray[1];
		healthColorStepperB.value = char.healthColorArray[2];
		healthBarBG.color = FlxColor.fromRGB(char.healthColorArray[0], char.healthColorArray[1], char.healthColorArray[2]);
	}

	function updatePresence() {
		#if cpp
		DiscordClient.changePresence("Character Editor", "Character: " + daAnim, leHealthIcon.getCharacter());
		#end
	}

	override function update(elapsed:Float)
	{
		MusicBeatState.camBeat = FlxG.camera;
		if(char.animationsArray[curAnim] != null) {
			textAnim.text = char.animationsArray[curAnim].anim;

			var curAnim:FlxAnimation = char.animation.getByName(char.animationsArray[curAnim].anim);
			if(curAnim == null || curAnim.frames.length < 1) {
				textAnim.text += ' (ERROR!)';
			}
		} else {
			textAnim.text = '';
		}

		var inputTexts:Array<PsychUIInputText> = [animationInputText, imageInputText, healthIconInputText, animationNameInputText, animationIndicesInputText];
		for (i in 0...inputTexts.length) {
			if(PsychUIInputText.focusOn == inputTexts[i]) {
				FlxG.sound.muteKeys = [];
				FlxG.sound.volumeDownKeys = [];
				FlxG.sound.volumeUpKeys = [];
				super.update(elapsed);
				return;
			}
		}
		FlxG.sound.muteKeys = TitleState.muteKeys;
		FlxG.sound.volumeDownKeys = TitleState.volumeDownKeys;
		FlxG.sound.volumeUpKeys = TitleState.volumeUpKeys;

		if(PsychUIInputText.focusOn == null) {
			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonB.justPressed) || #end FlxG.keys.justPressed.ESCAPE) {
				confirmExit();
				return;
			}

			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonZ.justPressed) || #end FlxG.keys.justPressed.R) {
				FlxG.camera.zoom = 1;
			}

			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonX.pressed) || #end FlxG.keys.pressed.E && FlxG.camera.zoom < 3) {
				FlxG.camera.zoom += elapsed * FlxG.camera.zoom;
				if(FlxG.camera.zoom > 3) FlxG.camera.zoom = 3;
			}
			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.Q && FlxG.camera.zoom > 0.1) {
				FlxG.camera.zoom -= elapsed * FlxG.camera.zoom;
				if(FlxG.camera.zoom < 0.1) FlxG.camera.zoom = 0.1;
			}

			if (#if (android || desktop) (virtualPad != null && ((virtualPad.buttonG.pressed && virtualPad.buttonLeft.pressed) || (virtualPad.buttonG.pressed && virtualPad.buttonDown.pressed) || (virtualPad.buttonG.pressed && virtualPad.buttonRight.pressed) || (virtualPad.buttonG.pressed && virtualPad.buttonUp.pressed))) || #end FlxG.keys.pressed.I || FlxG.keys.pressed.J || FlxG.keys.pressed.K || FlxG.keys.pressed.L)
			{
				var addToCam:Float = 500 * elapsed;
				if (FlxG.keys.pressed.SHIFT)
					addToCam *= 4;

				if (#if (android || desktop) (virtualPad != null && (virtualPad.buttonG.pressed && virtualPad.buttonUp.pressed)) || #end FlxG.keys.pressed.I)
					camFollow.y -= addToCam;
				else if (#if (android || desktop) (virtualPad != null && (virtualPad.buttonG.pressed && virtualPad.buttonDown.pressed)) || #end FlxG.keys.pressed.K)
					camFollow.y += addToCam;

				if (#if (android || desktop) (virtualPad != null && (virtualPad.buttonG.pressed && virtualPad.buttonLeft.pressed)) || #end FlxG.keys.pressed.J)
					camFollow.x -= addToCam;
				else if (#if (android || desktop) (virtualPad != null && (virtualPad.buttonG.pressed && virtualPad.buttonRight.pressed)) ||	#end FlxG.keys.pressed.L)
					camFollow.x += addToCam;
			}

			if(char.animationsArray.length > 0) {
				if (#if (android || desktop) (virtualPad != null && (virtualPad.buttonV.justPressed && !virtualPad.buttonG.pressed)) ||  #end FlxG.keys.justPressed.W)
				{
					curAnim -= 1;
				}

				if (#if (android || desktop) (virtualPad != null && (virtualPad.buttonD.justPressed && !virtualPad.buttonG.pressed)) || #end FlxG.keys.justPressed.S)
				{
					curAnim += 1;
				}

				if (curAnim < 0)
					curAnim = char.animationsArray.length - 1;

				if (curAnim >= char.animationsArray.length)
					curAnim = 0;

				if ((#if (android || desktop) (virtualPad != null && virtualPad.buttonD.justPressed) ||	#end FlxG.keys.justPressed.S) || (#if (android || desktop) (virtualPad != null && virtualPad.buttonV.justPressed) || #end FlxG.keys.justPressed.W) ||  FlxG.keys.justPressed.SPACE)
				{
					char.playAnim(char.animationsArray[curAnim].anim, true);
					genBoyOffsets();
				}
				if (#if (android || desktop) (virtualPad != null && virtualPad.buttonA.justPressed) ||  #end FlxG.keys.justPressed.T)
				{
					char.animationsArray[curAnim].offsets = [0, 0];

					char.addOffset(char.animationsArray[curAnim].anim, char.animationsArray[curAnim].offsets[0], char.animationsArray[curAnim].offsets[1]);
					ghostChar.addOffset(char.animationsArray[curAnim].anim, char.animationsArray[curAnim].offsets[0], char.animationsArray[curAnim].offsets[1]);
					genBoyOffsets();
				}

				var controlArray:Array<Bool> = [#if (android || desktop) (virtualPad != null && (virtualPad.buttonLeft.justPressed && !virtualPad.buttonG.pressed)) || #end FlxG.keys.justPressed.LEFT,#if (android || desktop) (virtualPad != null && (virtualPad.buttonRight.justPressed && !virtualPad.buttonG.pressed)) || #end FlxG.keys.justPressed.RIGHT,#if (android || desktop) (virtualPad != null && (virtualPad.buttonUp.justPressed && !virtualPad.buttonG.pressed)) || #end FlxG.keys.justPressed.UP, #if (android || desktop) (virtualPad != null && (virtualPad.buttonDown.justPressed && !virtualPad.buttonG.pressed)) || #end FlxG.keys.justPressed.DOWN];

				for (i in 0...controlArray.length) {
					if(controlArray[i]) {
						var holdShift = #if (android || desktop) (virtualPad != null && virtualPad.buttonC.pressed) || #end  FlxG.keys.pressed.SHIFT;
						var multiplier = 1;
						if (holdShift)
							multiplier = 10;

						var arrayVal = 0;
						if(i > 1) arrayVal = 1;

						var negaMult:Int = 1;
						if(i % 2 == 1) negaMult = -1;
						char.animationsArray[curAnim].offsets[arrayVal] += negaMult * multiplier;

						char.addOffset(char.animationsArray[curAnim].anim, char.animationsArray[curAnim].offsets[0], char.animationsArray[curAnim].offsets[1]);
						ghostChar.addOffset(char.animationsArray[curAnim].anim, char.animationsArray[curAnim].offsets[0], char.animationsArray[curAnim].offsets[1]);

						char.playAnim(char.animationsArray[curAnim].anim, false);
						if(ghostChar.animation.curAnim != null && char.animation.curAnim != null && char.animation.curAnim.name == ghostChar.animation.curAnim.name) {
							ghostChar.playAnim(char.animation.curAnim.name, false);
						}
						genBoyOffsets();
					}
				}
			}
		}
		ghostChar.setPosition(char.x, char.y);
		super.update(elapsed);
	}

	var fileDialog:FileDialogHandler;

	/** Mark the character as having unsaved changes. */
	function markUnsaved():Void { unsavedChanges = true; }
	/** Clear the unsaved changes flag. */
	function clearUnsaved():Void { unsavedChanges = false; }

	/** Confirm exit if there are unsaved changes. */
	function confirmExit():Void
	{
		if(unsavedChanges)
		{
			openSubState(new editors.content.Prompt(
				'There\'s unsaved progress,\nare you sure you want to exit?',
				function()
				{
					clearUnsaved();
					doExit();
				}
			));
		}
		else
		{
			doExit();
		}
	}
	function doExit():Void
	{
		if(goToPlayState) {
			MusicBeatState.switchState(new PlayState());
		} else {
			MusicBeatState.switchState(new editors.MasterEditorMenu());
			FlxG.sound.playMusic(Paths.music('freakyMenu'));
		}
		FlxG.mouse.visible = false;
	}

	function saveCharacter() {
		var json = {
			"animations": char.animationsArray,
			"image": char.imageFile,
			"scale": char.jsonScale,
			"sing_duration": char.singDuration,
			"healthicon": char.healthIcon,

			"position":	char.positionArray,
			"camera_position": char.cameraPosition,

			"flip_x": char.originalFlipX,
			"no_antialiasing": char.noAntialiasing,
			"healthbar_colors": char.healthColorArray
		};

		var data:String = Json.stringify(json, "\t");

		if (data.length > 0)
		{
			fileDialog.save(daAnim + '.json', data, function() {
			clearUnsaved();
			CoolUtil.traceMsg('trace.charSaved', 'Character saved successfully!');
			}, null, function() {
				FlxG.log.error('Problem saving file');
			});
		}
	}

	function ClipboardAdd(prefix:String = ''):String {
		if(prefix.toLowerCase().endsWith('v'))
		{
			prefix = prefix.substring(0, prefix.length-1);
		}

		var text:String = prefix + Clipboard.text.replace('\n', '');
		return text;
	}
}
