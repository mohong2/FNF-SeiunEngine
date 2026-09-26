package online.substates;

import flixel.FlxObject;
import openfl.filters.BlurFilter;
import online.util.OnlineLang;

class SelectStageSubstate extends MusicBeatSubstate {
    var blurFilter:BlurFilter;
	public var coolCam:FlxCamera;

    public var options:FlxTypedGroup<StageText>;
    public var optionsDetails:FlxTypedGroup<FlxText>;
    public var curSelected:Int;

    var stageNames:Array<String>;
    var stageMods:Array<String>;

    override function create() {
		super.create();

		trace(GameClient.room.state.stageName);
		
		blurFilter = new BlurFilter();
		for (cam in FlxG.cameras.list) {
			if (cam.filters == null)
				cam.filters = [];
			cam.filters.push(blurFilter);
		}

		coolCam = new FlxCamera();
		coolCam.bgColor.alpha = 0;
		FlxG.cameras.add(coolCam, false);

		cameras = [coolCam];

        var bg = new FlxSprite();
		bg.makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
        bg.scrollFactor.set(0, 0);
		bg.alpha = 0.7;
		add(bg);

        var stages = listStages(true);
        stageNames = stages[0];
        stageMods = stages[1];

        var sortingStage = [];
		for (i in 0...stageNames.length) {
			sortingStage.push([stageNames[i], stageMods[i]]);
        }

		sortingStage.sort((a, b) -> {
            for (i in 0...Std.int(Math.min(a[0].length, b[0].length))) {
				final orderA = a[0].toLowerCase().charCodeAt(i);
                final orderB = b[0].toLowerCase().charCodeAt(i);

				if (orderA == orderB)
                    continue;

                return orderA < orderB ? -1 : 1;
            }

            return 0;
        });

		stageNames = [];
		stageMods = [];
		for (stageInfo in sortingStage) {
			stageNames.push(stageInfo[0]);
			stageMods.push(stageInfo[1]);
        }

        stageNames.unshift('(default)');
        stageMods.unshift('');

        add(options = new FlxTypedGroup<StageText>());
        add(optionsDetails = new FlxTypedGroup<FlxText>());

        var endScrollY:Float = FlxG.height;
        for (i in 0...stageNames.length) {
            var text = new StageText(this, 50, 50 + 50 * i, stageNames[i]);
            if (stageNames[i] == "(default)")
                text.createDetails(OnlineLang.L('stage.default.desc', 'Default option uses the stage of the currently selected song'));
            else {
                if (stageMods[i] != '') {
                    text.createDetails(OnlineLang.L('stage.from', ' from ') + stageMods[i].substr(0, 40) + (stageMods[i].length > 40 ? '...' : ''));
                }
                else {
                    text.createDetails(OnlineLang.L('stage.fromVanilla', ' from Vanilla'));
                }
            }
			text.ID = i;
			text.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
            text.cameras = [coolCam];
            endScrollY = text.y + text.height + 50;
            text.updateText();
			options.add(text);
        }

        coolCam.setScrollBounds(FlxG.width, FlxG.width, 0, endScrollY > FlxG.height ? endScrollY : FlxG.height);
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, A_B);
		addPadCamera();
		#end
    }

	/**
	 * This engine's `backend.Mods` shim has no `listStages`, so the body is taken from the source
	 * project's `backend/Mods.listStages` (source/backend/Mods.hx:305-355), re-pointing its `Mods.*`
	 * calls at the equivalent `Paths.*` API; the list is read with `Paths.txt('stageList')` (as
	 * `editors/ChartingState.hx:1179`), via `CoolUtil.coolTextFile(...)`. Returns [stageNames, stageModDirs].
	 */
	static var tempArray:Array<Dynamic> = [];
	static function listStages(?allMods:Bool = false):Array<Array<String>> {
		tempArray = [];

		#if MODS_ALLOWED
		var directories:Array<String> = [
			Paths.mods('stages/'),
			Paths.mods(Paths.currentModDirectory + '/stages/'),
			Paths.getPreloadPath('stages/')
		];
		for (mod in (allMods ? Mods.parseList().enabled : Paths.getGlobalMods()))
			directories.push(Paths.mods(mod + '/stages/'));
		#else
		var directories:Array<String> = [Paths.getPreloadPath('stages/')];
		#end

		var stageFile:Array<String> = CoolUtil.coolTextFile(Paths.txt('stageList'));
		var stages:Array<String> = [];
		var stagePaths:Array<String> = [];
		for (stage in stageFile) {
			if (stage.trim().length > 0) {
				stages.push(stage);
				stagePaths.push('');
			}
			tempArray.push(stage);
		}
		#if MODS_ALLOWED
		for (i in 0...directories.length) {
			var directory:String = directories[i];
			if (FileSystem.exists(directory)) {
				for (file in FileSystem.readDirectory(directory)) {
					var path = haxe.io.Path.join([directory, file]);
					if (!FileSystem.isDirectory(path) && file.endsWith('.json')) {
						var stageToCheck:String = file.substr(0, file.length - 5);
						if (stageToCheck.trim().length > 0 && !tempArray.contains(stageToCheck)) {
							tempArray.push(stageToCheck);
							stages.push(stageToCheck);
							stagePaths.push(directory.substr('mods/'.length, directory.length - ('/stages/'.length + 'mods/'.length)));
						}
					}
				}
			}
		}
		#end

		if (stages.length < 1) {
			stages.push('stage');
			stagePaths.push('');
		}

		return [stages, stagePaths];
	}

    var holdUp = 0.0;
    var holdDown = 0.0;
    override function update(elapsed) {
        super.update(elapsed);

        Conductor.songPosition = FlxG.sound.music.time;

        if (controls.BACK) {
            close();
        }

        if (controls.UI_UP)
            holdUp += elapsed;
        else
            holdUp = 0;

        if (controls.UI_DOWN)
            holdDown += elapsed;
        else
            holdDown = 0;

        if (controls.UI_UP_P || FlxG.mouse.wheel == 1) {
            curSelected -= FlxG.keys.pressed.SHIFT ? 3 : 1;
            updateSelection();
        }

        if (controls.UI_DOWN_P || FlxG.mouse.wheel == -1) {
            curSelected += FlxG.keys.pressed.SHIFT ? 3 : 1;
            updateSelection();
        }

        if (controls.ACCEPT || (FlxG.mouse.justPressed && mouseHovers(options.members[curSelected]))) {
            if (curSelected == 0) {
                Alert.alert(OnlineLang.L('stage.setDefault', 'Stage set to default!'));
                GameClient.send("setStage", ['', '', '']);
                close();
                return;
            }

            var stageURL = '';
            if (stageMods[curSelected] != "") {
                stageURL = OnlineMods.getModURL(stageMods[curSelected]);
            }
            GameClient.send("setStage", [stageNames[curSelected], stageMods[curSelected], stageURL]);
            Alert.alert(OnlineLang.L('stage.set', 'Stage set to ') + stageNames[curSelected] + "!");
            close();
        }
    }

	/**
	 * FlxG.mouse.overlaps() builds the pointer from the *main* camera but the object from the camera
	 * passed in, so every hit is off by the scroll difference between the two. This list scrolls with
	 * coolCam.follow(), so compare both sides in coolCam's world instead.
	 */
	public function mouseHovers(object:FlxObject):Bool {
		if (object == null || camera == null)
			return false;

		var point = FlxG.mouse.getWorldPosition(camera);
		var hit:Bool = object.overlapsPoint(point, false);
		point.put();
		return hit;
	}

    function updateSelection() {
        if (curSelected < 0)
            curSelected = options.length - 1;
    
        if (curSelected > options.length - 1)
            curSelected = 0;

        for (option in options) option.updateText();
    }

    override function destroy() {
		super.destroy();

		for (cam in FlxG.cameras.list) {
			if (cam != null && cam.filters != null)
				cam.filters.remove(blurFilter);
		}
		FlxG.cameras.remove(coolCam);
	}

    override function stepHit() {
        super.stepHit();

        if (holdUp > 0.5) {
            curSelected -= FlxG.keys.pressed.SHIFT ? 3 : 1;
            updateSelection();
        }

        if (holdDown > 0.5) {
            curSelected += FlxG.keys.pressed.SHIFT ? 3 : 1;
            updateSelection();
        }
    }
}

class StageText extends FlxText {
	public var parent:SelectStageSubstate;
    public var ogText:String;
    public var details:FlxText;

	public function new(parent:SelectStageSubstate, x:Float, y:Float, text:String) {
        super(x, y, 0, ogText = text);

        this.parent = parent;
        updateText();
    }

    override function update(elapsed) {
		if (parent.curSelected != ID && parent.mouseHovers(this)) {
            parent.curSelected = ID;
            for (option in parent.options) option.updateText();
        }
    }

    public function createDetails(content:String) {
        var details = new FlxText(x, y, 0, content);
        details.setFormat(OnlineLang.font(), 20, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
        details.cameras = [parent.coolCam];
        details.color = FlxColor.GRAY;
        details.y = y + 25;
        parent.optionsDetails.add(details);
    }

    public function updateText() {
        if (parent.curSelected == ID) {
            text = "> " + ogText;
			camera.follow(this, TOPDOWN, 0.1);
        }
        else {
            text = ogText;
        }
    }
}
