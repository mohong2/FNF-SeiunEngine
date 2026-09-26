package states;

#if cpp
import Discord.DiscordClient;
#end
import flash.text.TextField;
import flixel.addons.display.FlxGridOverlay;
#if MODS_ALLOWED
import sys.FileSystem;
import sys.io.File;
#end
import lime.utils.Assets;

import FlxTextMenuItem;

using StringTools;

class CreditsState extends MusicBeatState
{
	public static var instance:CreditsState;
	public var curSelected:Int = -1;

	public var grpOptions:FlxTypedGroup<FlxTextMenuItem>;
	public var iconArray:Array<AttachedSprite> = [];
	public var creditsStuff:Array<Array<String>> = [];

	public var bg:FlxSprite;
	public var descText:FlxText;
	public var intendedColor:Int;
	public var colorTween:FlxTween;
	public var descBox:AttachedSprite;

	public var offsetThing:Float = -75;

	static final MODE_CREDITS:Int = 0;
	static final MODE_THANKS:Int = 1;
	var currentMode:Int = MODE_CREDITS;
	var transitioning:Bool = false;
	var thanksCurSelected:Int = 0;

	var thanksGrpOptions:FlxTypedGroup<FlxTextMenuItem>;
	var thanksIcons:Array<AttachedSprite> = [];
	var thanksTitle:FlxTextMenuItem;
	var thanksDescText:FlxText;
	var thanksDescBox:AttachedSprite;
	var thanksStuff:Array<Array<String>> = [];

	override function create()
	{
		instance = this;
		#if cpp
		// Updating Discord Rich Presence
		DiscordClient.changePresence("In the Menus", null);
		#end

		persistentUpdate = true;
		bg = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		add(bg);
		bg.screenCenter();
		bg.scrollFactor.set();
		FlxG.camera.follow(null);
		FlxG.camera.scroll.set(0, 0);
		
		grpOptions = new FlxTypedGroup<FlxTextMenuItem>();
		add(grpOptions);

		#if MODS_ALLOWED
		var path:String = 'modsList.txt';
		if(FileSystem.exists(path))
		{
			var leMods:Array<String> = CoolUtil.coolTextFile(path);
			for (i in 0...leMods.length)
			{
				if(leMods.length > 1 && leMods[0].length > 0) {
					var modSplit:Array<String> = leMods[i].split('|');
					if(!Paths.ignoreModFolders.contains(modSplit[0].toLowerCase()) && !modsAdded.contains(modSplit[0]))
					{
						if(modSplit[1] == '1')
							pushModCreditsToList(modSplit[0]);
						else
							modsAdded.push(modSplit[0]);
					}
				}
			}
		}

		var arrayOfFolders:Array<String> = Paths.getModDirectories();
		arrayOfFolders.push('');
		for (folder in arrayOfFolders)
		{
			pushModCreditsToList(folder);
		}
		#end

		var pisspoop:Array<Array<String>> = [ //Name - Icon name - Description - Link - BG Color
			['Seiun Engine Team'],
			['mo_hong',	'mohong','Main Programmer of Seiun Engine(Modified from Psych Engine)','https://space.bilibili.com/672029688',	'87ceeb'],
			['Li.tmc', 'Li.tmc', '(Old Mohong Engine)Engine icon', 'https://space.bilibili.com/3537117498051255', 'FF69B4'],
			['None', 'none', 'Android port lol.', 'https://space.bilibili.com/392851046', 'A07275'],
			['SeiunEngine 鸣谢名单', 'none', 'SeiunEngine 特别鸣谢人员（按确定查看）', '', 'FF69B4'],
			[''],
			['Online UI / Protocol Reference'],
			['Snirozu (Funkin-Psych-Online)', 'none', 'Online menu UI and room/protocol model reference (Apache-2.0)', 'https://github.com/Snirozu/Funkin-Psych-Online', '7C5CFF'],
			[''],
			['Psych Engine Team'],
			['Shadow Mario',		'shadowmario',		'Main Programmer of Psych Engine',								'https://twitter.com/Shadow_Mario_',	'444444'],
			['RiverOaken',			'river',			'Main Artist/Animator of Psych Engine',							'https://twitter.com/RiverOaken',		'B42F71'],
			['shubs',				'shubs',			'Additional Programmer of Psych Engine',						'https://twitter.com/yoshubs',			'5E99DF'],
			[''],
			['Codename Engine Team'],
			['CodenameCrew',		'none',				'ModState scripting & pack.json mod API design inspiration',	'https://github.com/CodenameCrew',		'7F5FA5'],
			[''],
			['Former Engine Members'],
			['bb-panzu',			'bb',				'Ex-Programmer of Psych Engine',								'https://twitter.com/bbsub3',			'3E813A'],
			[''],
			['Engine Contributors'],
			['iFlicky',				'flicky',			'Composer of Psync and Tea Time\nMade the Dialogue Sounds',		'https://twitter.com/flicky_i',			'9E29CF'],
			['SqirraRNG',			'sqirra',			'Crash Handler and Base code for\nChart Editor\'s Waveform',	'https://twitter.com/gedehari',			'E1843A'],
			['EliteMasterEric',		'mastereric',		'Runtime Shaders support',										'https://twitter.com/EliteMasterEric',	'FFBD40'],
			['MAJigsaw77',			'jigsaw',			'.MP4 Video Loader Library (hxvlc)\nhxCodec Compatibility Layer',	'https://github.com/MAJigsaw77/hxvlc',	'5D9CEC'],
			['KadeDev',				'kade',				'Fixed some cool stuff on Chart Editor\nand other PRs',			'https://twitter.com/kade0912',			'64A250'],
			['Keoiki',				'keoiki',			'Note Splash Animations',										'https://twitter.com/Keoiki_',			'D2D2D2'],
			['Nebula the Zorua',	'nebula',			'LUA JIT Fork and some Lua reworks',							'https://twitter.com/Nebula_Zorua',		'7D40B2'],
			['Smokey',				'smokey',			'Sprite Atlas Support',											'https://twitter.com/Smokey_5_',		'483D92'],
			[''],
			["Funkin' Crew"],
			['ninjamuffin99',		'ninjamuffin99',	"Programmer of Friday Night Funkin'",							'https://twitter.com/ninja_muffin99',	'CF2D2D'],
			['PhantomArcade',		'phantomarcade',	"Animator of Friday Night Funkin'",								'https://twitter.com/PhantomArcade3K',	'FADC45'],
			['evilsk8r',			'evilsk8r',			"Artist of Friday Night Funkin'",								'https://twitter.com/evilsk8r',			'5ABD4B'],
			['kawaisprite',			'kawaisprite',		"Composer of Friday Night Funkin'",								'https://twitter.com/kawaisprite',		'378FC7']
		];
		
		for(i in pisspoop){
			creditsStuff.push(i);
		}
	
		var savedModDir:String = Paths.currentModDirectory;
		for (i in 0...creditsStuff.length)
		{
			var isSelectable:Bool = !unselectableCheck(i);
			var optionText:FlxTextMenuItem = new FlxTextMenuItem(FlxG.width / 2, 300, creditsStuff[i][0], 48);
			optionText.isMenuItem = true;
			optionText.targetY = i;
			optionText.changeX = false;
			optionText.bold = !isSelectable;
			optionText.snapToPosition();
			grpOptions.add(optionText);

			if(isSelectable) {
				if(creditsStuff[i][5] != null)
				{
					Paths.currentModDirectory = creditsStuff[i][5];
				}

				var icon:AttachedSprite = new AttachedSprite('credits/' + creditsStuff[i][1]);
				icon.xAdd = optionText.width + 10;
				icon.sprTracker = optionText;
	
				// using a FlxGroup is too much fuss!
				iconArray.push(icon);
				add(icon);
				Paths.currentModDirectory = savedModDir;

				if(curSelected == -1) curSelected = i;
			}
			else
			{
				optionText.alignment = CENTER;
				optionText.screenCenter(X);
			}
		}
		
		descBox = new AttachedSprite();
		descBox.makeGraphic(1, 1, FlxColor.BLACK);
		descBox.xAdd = -10;
		descBox.yAdd = -10;
		descBox.alphaMult = 0.6;
		descBox.alpha = 0.6;
		add(descBox);

		descText = new FlxText(50, FlxG.height + offsetThing - 25, 1180, "", 32);
		descText.setFormat(Paths.languageFont(), 32, FlxColor.WHITE, CENTER/*, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK*/);
		descText.scrollFactor.set();
		//descText.borderSize = 2.4;
		descBox.sprTracker = descText;
		add(descText);

		buildThanksView();

		bg.color = getCurrentBGColor();
		intendedColor = bg.color;
		changeSelection();
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, A_B_C);
		#end
		super.create();

		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end
	}

	function buildThanksView()
	{
		thanksStuff = [
			['CitriSnow', 'CitriSnow', '为引擎提供了部分脚本设计方案并在开发引擎的这一段时间内一直提供支持', 'https://space.bilibili.com/1951803423', 'FFB6C1'],
			['慕雪', 'muxue', '为引擎找到了数不尽的bug，为引擎的稳定性和做出了重要贡献并在开发引擎的这一段时间内一直提供支持', 'https://space.bilibili.com/3493084289566971', '87CEEB'],
			['Pico（非 FNF 角色 Pico）', 'pico', '自 MohongEngine 时期起便持续支持本引擎的制作，并为引擎提供了若干宝贵的 Bug 反馈', 'https://space.bilibili.com/3546752359598592', '97A2F2'],
			['Wolf Yeying', 'xiaolangyeying', '为引擎发现了若干 Bug，为引擎的稳定运行作出了贡献', 'https://space.bilibili.com/3493115727972533', '88B6D8'],
			['一只可爱的bf呀', 'bfya', '提供了精神支持和一些想法 lol', 'https://space.bilibili.com/3546642993122123', '67DFFF'],
			['Bonus-XK', 'bonusxk', '另一款引擎（FNF-MeteoricEngine）的作者，与 SeiunEngine 作者时常交流，并在引擎开发期间给予了重要的精神支持与鼓励', 'https://space.bilibili.com/3461572190013717', '00FF1A']
		];

		thanksGrpOptions = new FlxTypedGroup<FlxTextMenuItem>();
		add(thanksGrpOptions);

		var baseX:Float = -FlxG.width + 200;
		var baseY:Float = 260;
		for (i in 0...thanksStuff.length)
		{
			var item:FlxTextMenuItem = new FlxTextMenuItem(baseX, baseY + i * 120, thanksStuff[i][0], 48);
			item.isMenuItem = true;
			item.targetY = i;
			item.startPosition.set(baseX, baseY);
			item.snapToPosition();
			thanksGrpOptions.add(item);

			var icon:AttachedSprite = new AttachedSprite('credits/' + thanksStuff[i][1]);
			icon.xAdd = item.width + 10;
			icon.sprTracker = item;
			thanksIcons.push(icon);
			add(icon);
		}

		thanksTitle = new FlxTextMenuItem(-FlxG.width + 75, 40, 'SeiunEngine 鸣谢名单', 32);
		thanksTitle.isMenuItem = false;
		thanksTitle.alpha = 0.4;
		add(thanksTitle);

		thanksDescBox = new AttachedSprite();
		thanksDescBox.makeGraphic(1, 1, FlxColor.BLACK);
		thanksDescBox.xAdd = -10;
		thanksDescBox.yAdd = -10;
		thanksDescBox.alphaMult = 0.6;
		thanksDescBox.alpha = 0.6;
		add(thanksDescBox);

		thanksDescText = new FlxText(-FlxG.width + 50, FlxG.height - 160, 1180, "", 32);
		thanksDescText.setFormat(Paths.languageFont(), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		thanksDescText.borderSize = 2.4;
		add(thanksDescText);
		thanksDescBox.sprTracker = thanksDescText;

		changeThanksSelection(0, false);
	}

	function openThanks()
	{
		if(transitioning) return;
		transitioning = true;
		FlxG.sound.play(Paths.sound('confirmMenu'));
		currentMode = MODE_THANKS;
		descBox.visible = false;
		descText.visible = false;
		FlxTween.tween(FlxG.camera.scroll, {x: -FlxG.width}, 0.45, {
			ease: FlxEase.cubeInOut,
			onComplete: function(twn:FlxTween) {
				transitioning = false;
			}
		});
	}

	function closeThanks()
	{
		if(transitioning) return;
		transitioning = true;
		FlxG.sound.play(Paths.sound('cancelMenu'));
		FlxTween.tween(FlxG.camera.scroll, {x: 0}, 0.45, {
			ease: FlxEase.cubeInOut,
			onComplete: function(twn:FlxTween) {
				currentMode = MODE_CREDITS;
				transitioning = false;
				descBox.visible = true;
				descText.visible = true;
			}
		});
	}

	function updateThanks(elapsed:Float)
	{
		if(controls.UI_UP_P) changeThanksSelection(-1);
		if(controls.UI_DOWN_P) changeThanksSelection(1);
		if(controls.ACCEPT)
		{
			FlxG.sound.play(Paths.sound('confirmMenu'), 0.6);
			if(thanksStuff[thanksCurSelected][3] != null && thanksStuff[thanksCurSelected][3].length > 4)
				CoolUtil.browserLoad(thanksStuff[thanksCurSelected][3]);
		}
		if(controls.BACK) closeThanks();
	}

	function changeThanksSelection(change:Int = 0, playSound:Bool = true)
	{
		thanksCurSelected += change;
		if(thanksCurSelected < 0) thanksCurSelected = thanksStuff.length - 1;
		if(thanksCurSelected >= thanksStuff.length) thanksCurSelected = 0;

		var bullShit:Int = 0;
		for(item in thanksGrpOptions.members)
		{
			item.targetY = bullShit - thanksCurSelected;
			bullShit++;
			item.alpha = 0.6;
			if(item.targetY == 0) item.alpha = 1;
		}

		thanksDescText.text = thanksStuff[thanksCurSelected][2];
		thanksDescText.x = -FlxG.width + 50;
		thanksDescText.y = FlxG.height - thanksDescText.height - 80;
		thanksDescBox.setGraphicSize(Std.int(thanksDescText.width + 20), Std.int(thanksDescText.height + 25));
		thanksDescBox.updateHitbox();

		if(playSound) FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
	}

	var quitting:Bool = false;
	var holdTime:Float = 0;

	override function update(elapsed:Float)
	{
		#if LUA_ALLOWED
		callOnLuas('onUpdate', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdate', [elapsed]);
		#end
			FlxG.sound.music.volume += 0.5 * FlxG.elapsed;
		

		if(!quitting && !transitioning)
		{
			if(currentMode == MODE_THANKS)
			{
				updateThanks(elapsed);
			}
			else
			{
				if(creditsStuff.length > 1)
				{
					var shiftMult:Int = 1;
					if(#if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonC.pressed) || #end FlxG.keys.pressed.SHIFT) shiftMult = 3;

					var upP = controls.UI_UP_P;
					var downP = controls.UI_DOWN_P;

					if (upP)
					{
						changeSelection(-shiftMult);
						holdTime = 0;
					}
					if (downP)
					{
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
						}
					}
				}

				if(controls.ACCEPT)
				{
					if(creditsStuff[curSelected][0] == 'SeiunEngine 鸣谢名单')
						openThanks();
					else if(creditsStuff[curSelected][3] != null && creditsStuff[curSelected][3].length > 4)
						CoolUtil.browserLoad(creditsStuff[curSelected][3]);
				}
				if (controls.BACK)
				{
					if(colorTween != null) {
						colorTween.cancel();
					}
					FlxG.sound.play(Paths.sound('cancelMenu'));
					MusicBeatState.switchState(new MainMenuState());
					quitting = true;
				}
			}
		}
		
		for (item in grpOptions.members)
		{
			if(!item.bold)
			{
				var lerpVal:Float = CoolUtil.boundTo(elapsed * 12, 0, 1);
				if(item.targetY == 0)
				{
					var lastX:Float = item.x;
					item.screenCenter(X);
					item.x = FlxMath.lerp(lastX, item.x - 70, lerpVal);
				}
				else
				{
					item.x = FlxMath.lerp(item.x, 200 + -40 * Math.abs(item.targetY), lerpVal);
				}
			}
		}
		super.update(elapsed);
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdatePost', [elapsed]);
		#end
	}

	var moveTween:FlxTween = null;
	function changeSelection(change:Int = 0)
	{
		FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
		do {
			curSelected += change;
			if (curSelected < 0)
				curSelected = creditsStuff.length - 1;
			if (curSelected >= creditsStuff.length)
				curSelected = 0;
		} while(unselectableCheck(curSelected));

		var newColor:Int =  getCurrentBGColor();
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

		var bullShit:Int = 0;

		for (item in grpOptions.members)
		{
			item.targetY = bullShit - curSelected;
			bullShit++;

			if(!unselectableCheck(bullShit-1)) {
				item.alpha = 0.6;
				if (item.targetY == 0) {
					item.alpha = 1;
				}
			}
		}

		descText.text = creditsStuff[curSelected][2];
		descText.y = FlxG.height - descText.height + offsetThing - 60;

		if(moveTween != null) moveTween.cancel();
		moveTween = FlxTween.tween(descText, {y : descText.y + 75}, 0.25, {ease: FlxEase.sineOut});

		descBox.setGraphicSize(Std.int(descText.width + 20), Std.int(descText.height + 25));
		descBox.updateHitbox();
	}

	#if MODS_ALLOWED
	private var modsAdded:Array<String> = [];
	function pushModCreditsToList(folder:String)
	{
		if(modsAdded.contains(folder)) return;

		var creditsFile:String = null;
		if(folder != null && folder.trim().length > 0) creditsFile = Paths.mods(folder + '/data/credits.txt');
		else creditsFile = Paths.mods('data/credits.txt');

		if (FileSystem.exists(creditsFile))
		{
			var firstarray:Array<String> = File.getContent(creditsFile).split('\n');
			for(i in firstarray)
			{
				var arr:Array<String> = i.replace('\\n', '\n').split("::");
				if(arr.length >= 5) arr.push(folder);
				creditsStuff.push(arr);
			}
			creditsStuff.push(['']);
		}
		modsAdded.push(folder);
	}
	#end

	function getCurrentBGColor() {
		var bgColor:String = creditsStuff[curSelected][4];
		if(!bgColor.startsWith('0x')) {
			bgColor = '0xFF' + bgColor;
		}
		return Std.parseInt(bgColor);
	}

	private function unselectableCheck(num:Int):Bool {
		return creditsStuff[num].length <= 1;
	}
	override function destroy() {
		instance = null;
		super.destroy();
	}
}
