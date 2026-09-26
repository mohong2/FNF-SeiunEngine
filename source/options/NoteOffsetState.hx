package options;

import backend.MusicBeatState;
import flixel.util.FlxStringUtil;
 
import flixel.ui.FlxBar;
import KeyboardDisplay;

using StringTools;

class NoteOffsetState extends MusicBeatState
{
	var boyfriend:Character;
	var gf:Character;
	var keyboardDisplay:KeyboardDisplay;

	var msTxtKade:FlxText;
	public var camHUD:FlxCamera;
	public var camGame:FlxCamera;
	public var camOther:FlxCamera;

	var coolText:FlxText;
	var rating:FlxSprite;
	var comboNums:FlxSpriteGroup;
	var dumbTexts:FlxTypedGroup<FlxText>;

	var barPercent:Float = 0;
	var delayMin:Int = 0;
	var delayMax:Int = 500;
	var timeBarBG:FlxSprite;
	var timeBar:FlxBar;
	var timeTxt:FlxText;
	var beatText:FlxTextMenuItem;
	var beatTween:FlxTween;

	var changeModeText:FlxText;

	override public function create()
	{
		if(ClientPrefs.data.comboOffset.length < 8) {
			while(ClientPrefs.data.comboOffset.length < 8) 
				ClientPrefs.data.comboOffset.push(0);
		}
		
		// Cameras
		camGame = new FlxCamera();
		camHUD = new FlxCamera();
		camOther = new FlxCamera();
		camHUD.bgColor.alpha = 0;
		camOther.bgColor.alpha = 0;

		FlxG.cameras.reset(camGame);
		FlxG.cameras.add(camHUD, false);
		FlxG.cameras.add(camOther, false);

		FlxG.cameras.setDefaultDrawTarget(camGame, true);
		CustomFadeTransition.nextCamera = camOther;
		FlxG.camera.scroll.set(120, 130);

		persistentUpdate = true;
		FlxG.sound.pause();
		// Stage
		var bg:BGSprite = new BGSprite('stageback', -600, -200, 0.9, 0.9);
		add(bg);

		var stageFront:BGSprite = new BGSprite('stagefront', -650, 600, 0.9, 0.9);
		stageFront.setGraphicSize(Std.int(stageFront.width * 1.1));
		stageFront.updateHitbox();
		add(stageFront);

		if(!ClientPrefs.data.lowQuality) {
			var stageLight:BGSprite = new BGSprite('stage_light', -125, -100, 0.9, 0.9);
			stageLight.setGraphicSize(Std.int(stageLight.width * 1.1));
			stageLight.updateHitbox();
			add(stageLight);
			var stageLight:BGSprite = new BGSprite('stage_light', 1225, -100, 0.9, 0.9);
			stageLight.setGraphicSize(Std.int(stageLight.width * 1.1));
			stageLight.updateHitbox();
			stageLight.flipX = true;
			add(stageLight);

			var stageCurtains:BGSprite = new BGSprite('stagecurtains', -500, -300, 1.3, 1.3);
			stageCurtains.setGraphicSize(Std.int(stageCurtains.width * 0.9));
			stageCurtains.updateHitbox();
			add(stageCurtains);
		}

		// Characters
		gf = new Character(400, 130, 'gf');
		gf.x += gf.positionArray[0];
		gf.y += gf.positionArray[1];
		gf.scrollFactor.set(0.95, 0.95);
		boyfriend = new Character(770, 100, 'bf', true);
		boyfriend.x += boyfriend.positionArray[0];
		boyfriend.y += boyfriend.positionArray[1];
		add(gf);
		add(boyfriend);

		// Combo stuff

		coolText = new FlxText(0, 0, 0, '', 32);
		coolText.screenCenter();
		coolText.x = FlxG.width * 0.35;

		rating = new FlxSprite().loadGraphic(Paths.image('sick'));
		rating.cameras = [camHUD];
		rating.setGraphicSize(Std.int(rating.width * 0.7));
		rating.updateHitbox();
		rating.antialiasing = ClientPrefs.data.globalAntialiasing;
		
		add(rating);

		comboNums = new FlxSpriteGroup();
		comboNums.cameras = [camHUD];
		add(comboNums);

		// 添加键盘显示
		keyboardDisplay = new KeyboardDisplay(0, 0);
		keyboardDisplay.cameras = [camHUD];
		add(keyboardDisplay);

		msTxtKade = new FlxText(ClientPrefs.data.comboOffset[6],ClientPrefs.data.comboOffset[7], 0, "114514ms", 19);
		msTxtKade.cameras = [camHUD];
		msTxtKade.setFormat(19, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		msTxtKade.borderSize = 2;
		msTxtKade.color = 0x00FFFF;
		msTxtKade.font = Paths.font("kadems.ttf"); 
		add(msTxtKade);


		var seperatedScore:Array<Int> = [];
		for (i in 0...3)
		{
			seperatedScore.push(FlxG.random.int(0, 9));
		}

		var daLoop:Int = 0;
		for (i in seperatedScore)
		{
			var numScore:FlxSprite = new FlxSprite(43 * daLoop).loadGraphic(Paths.image('num' + i));
			numScore.cameras = [camHUD];
			numScore.setGraphicSize(Std.int(numScore.width * 0.5));
			numScore.updateHitbox();
			numScore.antialiasing = ClientPrefs.data.globalAntialiasing;
			comboNums.add(numScore);
			daLoop++;
		}

		dumbTexts = new FlxTypedGroup<FlxText>();
		dumbTexts.cameras = [camHUD];
		add(dumbTexts);
		createTexts();

		repositionCombo();

		// Note delay stuff
		
		beatText = new FlxTextMenuItem(0, 0, Language.get('NoteOffset.beatHit', 'Beat Hit!'), 48); beatText.isMenuItem = false;
		beatText.scale.x = 0.6;
		beatText.scale.y = 0.6;
		beatText.x += 260;
		beatText.alpha = 0;
		beatText.acceleration.y = 250;
		beatText.visible = false;
		add(beatText);
		
		timeTxt = new FlxText(0, 600, FlxG.width, "", 32);
		timeTxt.setFormat(Paths.font("vcr.ttf"), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		timeTxt.scrollFactor.set();
		timeTxt.borderSize = 2;
		timeTxt.visible = false;
		timeTxt.cameras = [camHUD];

		barPercent = ClientPrefs.data.noteOffset;
		updateNoteDelay();
		
		timeBarBG = new FlxSprite(0, timeTxt.y + 8).loadGraphic(Paths.image('timeBar'));
		timeBarBG.setGraphicSize(Std.int(timeBarBG.width * 1.2));
		timeBarBG.updateHitbox();
		timeBarBG.cameras = [camHUD];
		timeBarBG.screenCenter(X);
		timeBarBG.visible = false;

		timeBar = new FlxBar(0, timeBarBG.y + 4, LEFT_TO_RIGHT, Std.int(timeBarBG.width - 8), Std.int(timeBarBG.height - 8), this, 'barPercent', delayMin, delayMax);
		timeBar.scrollFactor.set();
		timeBar.screenCenter(X);
		timeBar.createFilledBar(0xFF000000, 0xFFFFFFFF);
		timeBar.numDivisions = 800; //How much lag this causes?? Should i tone it down to idk, 400 or 200?
		timeBar.visible = false;
		timeBar.cameras = [camHUD];

		add(timeBarBG);
		add(timeBar);
		add(timeTxt);

		///////////////////////

		var blackBox:FlxSprite = new FlxSprite().makeGraphic(FlxG.width, 40, FlxColor.BLACK);
		blackBox.scrollFactor.set();
		blackBox.alpha = 0.6;
		blackBox.cameras = [camHUD];
		add(blackBox);

		changeModeText = new FlxText(0, 4, FlxG.width, "", 32);
		changeModeText.setFormat(Paths.font("vcr.ttf"), 32, FlxColor.WHITE, CENTER);
		changeModeText.scrollFactor.set();
		changeModeText.cameras = [camHUD];
		add(changeModeText);
		updateMode();

		Conductor.changeBPM(128.0);
		FlxG.sound.playMusic(Paths.music('offsetSong'), 1, true);
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(LEFT_FULL, A_B_C);
		addPadCamera();
		#end
		
		super.create();
	}

	var holdTime:Float = 0;
	var onComboMenu:Bool = true;
	var holdingObjectType:Null<Int> = null; // 改为Int类型以支持键盘

	var startMousePos:FlxPoint = new FlxPoint();
	var startComboOffset:FlxPoint = new FlxPoint();

	override public function update(elapsed:Float)
	{
		var addNum:Int = 1;
		if(FlxG.keys.pressed.SHIFT) addNum = 10;

		if(onComboMenu)
		{
			var controlArray:Array<Bool> = [
				FlxG.keys.justPressed.LEFT,
				FlxG.keys.justPressed.RIGHT,
				FlxG.keys.justPressed.UP,
				FlxG.keys.justPressed.DOWN,
			
				FlxG.keys.justPressed.A,
				FlxG.keys.justPressed.D,
				FlxG.keys.justPressed.W,
				FlxG.keys.justPressed.S,

				FlxG.keys.justPressed.J,
				FlxG.keys.justPressed.L,
				FlxG.keys.justPressed.I,
				FlxG.keys.justPressed.K

			];

			if(controlArray.contains(true))
			{
				for (i in 0...controlArray.length)
				{
					if(controlArray[i])
					{
						switch(i)
						{
							case 0:
								ClientPrefs.data.comboOffset[0] -= addNum;
							case 1:
								ClientPrefs.data.comboOffset[0] += addNum;
							case 2:
								ClientPrefs.data.comboOffset[1] += addNum;
							case 3:
								ClientPrefs.data.comboOffset[1] -= addNum;
							case 4:
								ClientPrefs.data.comboOffset[2] -= addNum;
							case 5:
								ClientPrefs.data.comboOffset[2] += addNum;
							case 6:
								ClientPrefs.data.comboOffset[3] += addNum;
							case 7:
								ClientPrefs.data.comboOffset[3] -= addNum;
							case 8:
								ClientPrefs.data.comboOffset[6] -= addNum;
							case 9:
								ClientPrefs.data.comboOffset[6] += addNum;
							case 10: 
								ClientPrefs.data.comboOffset[7] -= addNum;
							case 11: 
								ClientPrefs.data.comboOffset[7] += addNum;
						}
					}
				}
				repositionCombo();
			}

			if (FlxG.mouse.justPressed && !(virtualPad != null && virtualPad.isMouseOverAnyButton()))
			{
				holdingObjectType = null;
				FlxG.mouse.getScreenPosition(camHUD, startMousePos);
				
				if (startMousePos.x - rating.x >= 0 && startMousePos.x - rating.x <= rating.width &&
					startMousePos.y - rating.y >= 0 && startMousePos.y - rating.y <= rating.height)
				{
					holdingObjectType = 0;
					startComboOffset.x = ClientPrefs.data.comboOffset[0];
					startComboOffset.y = ClientPrefs.data.comboOffset[1];
				}
				else if (startMousePos.x - comboNums.x >= 0 && startMousePos.x - comboNums.x <= comboNums.width &&
						 startMousePos.y - comboNums.y >= 0 && startMousePos.y - comboNums.y <= comboNums.height)
				{
					holdingObjectType = 1;
					startComboOffset.x = ClientPrefs.data.comboOffset[2];
					startComboOffset.y = ClientPrefs.data.comboOffset[3];
				}
				else if (startMousePos.x - keyboardDisplay.x >= 0 && startMousePos.x - keyboardDisplay.x <= keyboardDisplay.width &&
						 startMousePos.y - keyboardDisplay.y >= 0 && startMousePos.y - keyboardDisplay.y <= keyboardDisplay.height)
				{
					holdingObjectType = 2;
					startComboOffset.x = ClientPrefs.data.comboOffset[4];
					startComboOffset.y = ClientPrefs.data.comboOffset[5];
				}
				else if (startMousePos.x - msTxtKade.x >= 0 && msTxtKade.x - msTxtKade.x <= msTxtKade.width &&
						 startMousePos.y - msTxtKade.y >= 0 && msTxtKade.y - msTxtKade.y <= msTxtKade.height)
				{
					holdingObjectType = 3;
					startComboOffset.x = ClientPrefs.data.comboOffset[6];
					startComboOffset.y = ClientPrefs.data.comboOffset[7];
				}
			}
			
			if(FlxG.mouse.justReleased) {
				holdingObjectType = null;
			}

			if(holdingObjectType != null)
			{
				if(FlxG.mouse.justMoved)
				{
					var mousePos:FlxPoint = FlxG.mouse.getScreenPosition(camHUD);
					
					switch(holdingObjectType) {
						case 0: // 评分
							ClientPrefs.data.comboOffset[0] = Math.round((mousePos.x - startMousePos.x) + startComboOffset.x);
							ClientPrefs.data.comboOffset[1] = -Math.round((mousePos.y - startMousePos.y) - startComboOffset.y);
							
						case 1: // 数字
							ClientPrefs.data.comboOffset[2] = Math.round((mousePos.x - startMousePos.x) + startComboOffset.x);
							ClientPrefs.data.comboOffset[3] = -Math.round((mousePos.y - startMousePos.y) - startComboOffset.y);
							
						case 2: // 键盘
							ClientPrefs.data.comboOffset[4] = Math.round((mousePos.x - startMousePos.x) + startComboOffset.x);
							ClientPrefs.data.comboOffset[5] = Math.round((mousePos.y - startMousePos.y) + startComboOffset.y);
					
						case 3: 
							ClientPrefs.data.comboOffset[6] = Math.round((mousePos.x - startMousePos.x) + startComboOffset.x);
							ClientPrefs.data.comboOffset[7] = Math.round((mousePos.y - startMousePos.y) + startComboOffset.y);
					}
					
					repositionCombo();
				}
			}

			if(controls.RESET #if (TOUCH_CONTROLS || desktop) || (virtualPad != null && virtualPad.buttonC.justPressed) #end)
			{
				for (i in 0...ClientPrefs.data.comboOffset.length)
				{
					ClientPrefs.data.comboOffset[i] = 0;
					if(i == 4) ClientPrefs.data.comboOffset[i] = 530; // 键盘默认X
					if(i == 5) ClientPrefs.data.comboOffset[i] = 470; // 键盘默认Y
					if(i == 6) ClientPrefs.data.comboOffset[i] = 520; // msTxtKade 默认X
        			if(i == 7) ClientPrefs.data.comboOffset[i] = 350; // msTxtKade 默认Y
				}
				repositionCombo();
			}
		}
		else
		{
			if(controls.UI_LEFT_P)
			{
				barPercent = Math.max(delayMin, Math.min(ClientPrefs.data.noteOffset - 1, delayMax));
				updateNoteDelay();
			}
			else if(controls.UI_RIGHT_P)
			{
				barPercent = Math.max(delayMin, Math.min(ClientPrefs.data.noteOffset + 1, delayMax));
				updateNoteDelay();
			}

			var mult:Int = 1;
			if(controls.UI_LEFT || controls.UI_RIGHT)
			{
				holdTime += elapsed;
				if(controls.UI_LEFT) mult = -1;
			}

			if(controls.UI_LEFT_R || controls.UI_RIGHT_R) holdTime = 0;

			if(holdTime > 0.5)
			{
				barPercent += 100 * elapsed * mult;
				barPercent = Math.max(delayMin, Math.min(barPercent, delayMax));
				updateNoteDelay();
			}

			if(controls.RESET)
			{
				holdTime = 0;
				barPercent = 0;
				updateNoteDelay();
			}
		}

		if(controls.ACCEPT)
		{
			onComboMenu = !onComboMenu;
			updateMode();
		}

		if(controls.BACK)
		{
			if(zoomTween != null) zoomTween.cancel();
			if(beatTween != null) beatTween.cancel();

			persistentUpdate = false;
			CustomFadeTransition.nextCamera = camOther;
			MusicBeatState.switchState(new options.OptionsState());
			FlxG.sound.playMusic(Paths.music('freakyMenu'), 1, true);
			FlxG.mouse.visible = false;
		}

		Conductor.songPosition = FlxG.sound.music.time;
		super.update(elapsed);
	}

	var zoomTween:FlxTween;
	var lastBeatHit:Int = -1;
	override public function beatHit()
	{
		super.beatHit();

		if(lastBeatHit == curBeat)
		{
			return;
		}

		if(curBeat % 2 == 0)
		{
			boyfriend.dance();
			gf.dance();
		}
		
		if(curBeat % 4 == 2)
		{
			FlxG.camera.zoom = 1.15;

			if(zoomTween != null) zoomTween.cancel();
			zoomTween = FlxTween.tween(FlxG.camera, {zoom: 1}, 1, {ease: FlxEase.circOut, onComplete: function(twn:FlxTween)
				{
					zoomTween = null;
				}
			});

			beatText.alpha = 1;
			beatText.y = 320;
			beatText.velocity.y = -150;
			if(beatTween != null) beatTween.cancel();
			beatTween = FlxTween.tween(beatText, {alpha: 0}, 1, {ease: FlxEase.sineIn, onComplete: function(twn:FlxTween)
				{
					beatTween = null;
				}
			});
		}

		lastBeatHit = curBeat;
	}

	function repositionCombo()
	{
		rating.screenCenter();
		rating.x = coolText.x - 40 + ClientPrefs.data.comboOffset[0];
		rating.y -= 60 + ClientPrefs.data.comboOffset[1];

		comboNums.screenCenter();
		comboNums.x = coolText.x - 90 + ClientPrefs.data.comboOffset[2];
		comboNums.y += 80 - ClientPrefs.data.comboOffset[3];
		
		keyboardDisplay.x = ClientPrefs.data.comboOffset[4];
		keyboardDisplay.y = ClientPrefs.data.comboOffset[5];
		
		msTxtKade.x = ClientPrefs.data.comboOffset[6];
		msTxtKade.y = ClientPrefs.data.comboOffset[7];
		reloadTexts();
	}

	function createTexts()
	{
		for (i in 0...8)
		{
			var text:FlxText = new FlxText(10, 48 + (i * 30), 0, '', 24);
			text.setFormat(Paths.languageFont(), 24, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			text.scrollFactor.set();
			text.borderSize = 2;
			dumbTexts.add(text);
			text.cameras = [camHUD];

			if(i > 1)
			{
				text.y += 24;
			}
			if(i > 3)
			{
				text.y += 24;
			}
			if(i > 5)
			{
				text.y += 24;
			}
		}
	}

	function reloadTexts()
	{
		for (i in 0...dumbTexts.length)
		{
			switch(i)
			{
				case 0: dumbTexts.members[i].text = 'Rating Offset:';
				case 1: dumbTexts.members[i].text = '[' + ClientPrefs.data.comboOffset[0] + ', ' + ClientPrefs.data.comboOffset[1] + ']';
				case 2: dumbTexts.members[i].text = 'Numbers Offset:';
				case 3: dumbTexts.members[i].text = '[' + ClientPrefs.data.comboOffset[2] + ', ' + ClientPrefs.data.comboOffset[3] + ']';
				case 4: dumbTexts.members[i].text = 'Keyboard Offset:';
				case 5: dumbTexts.members[i].text = '[' + ClientPrefs.data.comboOffset[4] + ', ' + ClientPrefs.data.comboOffset[5] + ']';
				case 6: dumbTexts.members[i].text = 'SHOWMS Offset:';
				case 7: dumbTexts.members[i].text = '[' + ClientPrefs.data.comboOffset[6] + ', ' + ClientPrefs.data.comboOffset[7] + ']';
			}
		}
	}
	function updateNoteDelay()
	{
		ClientPrefs.data.noteOffset = Math.round(barPercent);
		timeTxt.text = 'Current offset: ' + Math.floor(barPercent) + ' ms';
	}

	function updateMode()
	{
		rating.visible = onComboMenu;
		comboNums.visible = onComboMenu;
		dumbTexts.visible = onComboMenu;
		keyboardDisplay.visible = onComboMenu;
		msTxtKade.visible = onComboMenu;
		
		timeBarBG.visible = !onComboMenu;
		timeBar.visible = !onComboMenu;
		timeTxt.visible = !onComboMenu;
		beatText.visible = !onComboMenu;

		if(onComboMenu)
			changeModeText.text = '< Combo Offset (Press Accept to Switch) >';
		else
			changeModeText.text = '< Note/Beat Delay (Press Accept to Switch) >';

		changeModeText.text = changeModeText.text.toUpperCase();
		FlxG.mouse.visible = onComboMenu;
	}
}
//看什么看,没见过bug里面写代码的吗
