package;

import animateatlas.AtlasFrameMaker;
import flixel.addons.effects.FlxTrail;
import flixel.animation.FlxBaseAnimation;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.util.FlxDestroyUtil;
import flixel.util.FlxSort;
import Section.SwagSection;
#if MODS_ALLOWED
import sys.io.File;
import sys.FileSystem;
#end
#if flxanimate
import flxanimate.PsychFlxAnimate;
#end
import openfl.utils.AssetType;
import openfl.utils.Assets;
import haxe.Json;
import haxe.format.JsonParser;

using StringTools;

typedef CharacterFile = {
	var animations:Array<AnimArray>;
	var image:String;
	var scale:Float;
	var sing_duration:Float;
	var healthicon:String;

	var position:Array<Float>;
	var camera_position:Array<Float>;

	var flip_x:Bool;
	var no_antialiasing:Bool;
	var healthbar_colors:Array<Int>;
}

typedef AnimArray = {
	var anim:String;
	var name:String;
	var fps:Int;
	var loop:Bool;
	var indices:Array<Int>;
	var offsets:Array<Int>;
}

class Character extends FlxSprite
{
	public var animOffsets:Map<String, Array<Dynamic>>;
	public var debugMode:Bool = false;

	public var isPlayer:Bool = false;
	public var curCharacter:String = DEFAULT_CHARACTER;

	public var colorTween:FlxTween;
	public var holdTimer:Float = 0;
	public var heyTimer:Float = 0;
	public var specialAnim:Bool = false;
	public var animationNotes:Array<Dynamic> = [];
	public var stunned:Bool = false;
	public var singDuration:Float = 4; //Multiplier of how long a character holds the sing pose
	public var idleSuffix:String = '';
	public var danceIdle:Bool = false; //Character use "danceLeft" and "danceRight" instead of "idle"
	public var skipDance:Bool = false;

	public var healthIcon:String = 'face';
	public var animationsArray:Array<AnimArray> = [];

	public var positionArray:Array<Float> = [0, 0];
	public var cameraPosition:Array<Float> = [0, 0];

	public var hasMissAnimations:Bool = false;

	// Adobe Animate 图集（0.7.3/1.0.4 兼容）
	public var isAnimateAtlas:Bool = false;
	#if flxanimate
	public var atlas:PsychFlxAnimate = null;
	#end
	private var _lastPlayedAnimation:String = '';

	//Used on Character Editor
	public var imageFile:String = '';
	public var jsonScale:Float = 1;
	public var noAntialiasing:Bool = false;
	public var originalFlipX:Bool = false;
	public var healthColorArray:Array<Int> = [255, 0, 0];

	public static var DEFAULT_CHARACTER:String = 'bf'; //In case a character is missing, it will use BF on its place

	#if ONLINE_ALLOWED
	// ─── Online support: members the online code needs ──────────────────────────
	// These members are declared only for the online code; the lobby layout, skins and
	// chart analysis read them. Everything is guarded by ONLINE_ALLOWED so the
	// macro-off build is untouched.
	//
	// Members added below:
	//   ox                  -- horizontal sort/offset slot used by the lobby layout.
	//   loadFailed          -- set when the character json could not be loaded.
	//   noAnimationBullshit -- lets the lobby drive animations itself.
	//   noHoldBullshit      -- same idea for hold notes.
	// -------------------------------------------------------------------------
	/** Horizontal sort/offset slot used by the online lobby character layout. */
	public var ox:Int = 0;
	/** Set when the character json could not be loaded. */
	public var loadFailed:Bool = false;
	/** True while `playAnim` plays an animation whose name ends in "miss". */
	public var isMissing:Bool = false;
	/** When true, `update()` skips the idle/dance state machine entirely so the lobby can
	 *  drive animations through `playAnim`. */
	public var noAnimationBullshit:Bool = false;
	/** Same as above for hold notes. */
	public var noHoldBullshit:Bool = false;

	/**
	 * Reads and parses a character json WITHOUT constructing the character.
	 * The engine's `new()` does the same lookup inline (source/Character.hx:108-131); this static
	 * helper exposes it separately because `online.states.SkinsState` needs the file's data before
	 * or without building the sprite.
	 * Falls back to `DEFAULT_CHARACTER` unless `nullOnFail` is set.
	 */
	public static function getCharacterFile(character:String, ?instance:Character, ?nullOnFail:Bool = false):CharacterFile {
		var characterPath:String = 'characters/' + character + '.json';

		#if MODS_ALLOWED
		var path:String = Paths.modFolders(characterPath);
		if (!FileSystem.exists(path)) {
			path = Paths.getPreloadPath(characterPath);
		}

		if (!FileSystem.exists(path))
		#else
		var path:String = Paths.getPreloadPath(characterPath);
		if (!Assets.exists(path))
		#end
		{
			if (instance != null)
				instance.loadFailed = true;
			if (nullOnFail)
				return null;
			path = Paths.getPreloadPath('characters/' + DEFAULT_CHARACTER + '.json'); // If a character couldn't be found, change him to BF just to prevent a crash
		}

		#if MODS_ALLOWED
		var rawJson = File.getContent(path);
		#else
		var rawJson = Assets.getText(path);
		#end

		return cast Json.parse(rawJson);
	}

	/** True when `AnimName` has an entry in `animOffsets`. */
	public function animExists(AnimName:String) {
		return animOffsets.exists(AnimName);
	}
	#end
	public function new(x:Float, y:Float, ?character:String = 'bf', ?isPlayer:Bool = false)
	{
		super(x, y);

		#if (haxe >= "4.0.0")
		animOffsets = new Map();
		#else
		animOffsets = new Map<String, Array<Dynamic>>();
		#end
		curCharacter = character;
		this.isPlayer = isPlayer;
		antialiasing = ClientPrefs.data.globalAntialiasing;
		var library:String = null;
		switch (curCharacter)
		{
			//case 'your character name in case you want to hardcode them instead':

			default:
				var characterPath:String = 'characters/' + curCharacter + '.json';

				#if MODS_ALLOWED
				var path:String = Paths.modFolders(characterPath);
				if (!FileSystem.exists(path)) {
					path = Paths.getPreloadPath(characterPath);
				}

				if (!FileSystem.exists(path))
				#else
				var path:String = Paths.getPreloadPath(characterPath);
				if (!Assets.exists(path))
				#end
				{
					path = Paths.getPreloadPath('characters/' + DEFAULT_CHARACTER + '.json'); //If a character couldn't be found, change him to BF just to prevent a crash
				}

				#if MODS_ALLOWED
				var rawJson = File.getContent(path);
				#else
				var rawJson = Assets.getText(path);
				#end

				var json:CharacterFile = cast Json.parse(rawJson);
				var spriteType = "sparrow";
				var animateFailed:Bool = false;
				//sparrow
				//packer
				//texture
				#if MODS_ALLOWED
				var modTxtToFind:String = Paths.modsTxt(json.image);
				var txtToFind:String = Paths.getPath('images/' + json.image + '.txt', TEXT);
				
				if (FileSystem.exists(modTxtToFind) || FileSystem.exists(txtToFind) || Assets.exists(txtToFind))
				#else
				if (Assets.exists(Paths.getPath('images/' + json.image + '.txt', TEXT)))
				#end
				{
					spriteType = "packer";
				}
				
				#if MODS_ALLOWED
				var modAnimToFind:String = Paths.modFolders('images/' + json.image + '/Animation.json');
				var animToFind:String = Paths.getPath('images/' + json.image + '/Animation.json', TEXT);
				
				if (FileSystem.exists(modAnimToFind) || FileSystem.exists(animToFind) || Assets.exists(animToFind))
				#else
				if (Assets.exists(Paths.getPath('images/' + json.image + '/Animation.json', TEXT)))
				#end
				{
					spriteType = "texture";
				}

				#if flxanimate
				// New Adobe Animate spritemap format (spritemap1.json) uses FlxAnimate.
				// Old 2018 spritemap.json stays on AtlasFrameMaker to avoid regressions.
				if (spriteType == "texture" && Paths.fileExists('images/' + json.image + '/spritemap1.json', TEXT))
				{
					isAnimateAtlas = true;
					atlas = new PsychFlxAnimate();
					atlas.showPivot = false;
					try
					{
						Paths.loadAnimateAtlas(atlas, json.image);
					}
					catch(e:Dynamic)
					{
						FlxG.log.warn('Could not load atlas ${json.image}: $e');
						atlas = null;
						isAnimateAtlas = false;
						animateFailed = true;
					}
				}
				#end

				if (isAnimateAtlas)
				{
					// atlas is already loaded by the block above
				}
				else
				{
					switch (spriteType){
						
						case "packer":
							frames = Paths.getPackerAtlas(json.image);
						
						case "sparrow":
							frames = Paths.getSparrowAtlas(json.image);
						
						case "texture":
							frames = AtlasFrameMaker.construct(json.image);
					}
				}
				if (animateFailed && frames != null) frames = null;
				imageFile = json.image;
				
				if (!isAnimateAtlas && frames == null)
				{
					loadGraphic(Paths.image(json.image));
					if (graphic != null && animation != null)
						animation.add('idle', [0], 1, true);
				}

				if(json.scale != 1) {
					jsonScale = json.scale;
					#if flxanimate
					if (isAnimateAtlas)
					{
						scale.set(jsonScale, jsonScale);
						updateHitbox();
					}
					else
					#end
					{
						setGraphicSize(Std.int(width * jsonScale));
						updateHitbox();
					}
				}

				positionArray = json.position;
				cameraPosition = json.camera_position;

				healthIcon = json.healthicon;
				singDuration = json.sing_duration;
				flipX = !!json.flip_x;
				if(json.no_antialiasing) {
					antialiasing = false;
					noAntialiasing = true;
				}

				if(json.healthbar_colors != null && json.healthbar_colors.length > 2)
					healthColorArray = json.healthbar_colors;

				antialiasing = !noAntialiasing;
				if(!ClientPrefs.data.globalAntialiasing) antialiasing = false;

				if (isAnimateAtlas || frames != null)
				{
					animationsArray = json.animations;
					if(animationsArray != null && animationsArray.length > 0) {
						for (anim in animationsArray) {
							var animAnim:String = '' + anim.anim;
							var animName:String = '' + anim.name;
							var animFps:Int = anim.fps;
							var animLoop:Bool = !!anim.loop; //Bruh
							var animIndices:Array<Int> = anim.indices;
							#if flxanimate
							if (isAnimateAtlas)
							{
								if(animIndices != null && animIndices.length > 0) {
									atlas.anim.addBySymbolIndices(animAnim, animName, animIndices, animFps, animLoop);
								} else {
									atlas.anim.addBySymbol(animAnim, animName, animFps, animLoop);
								}
							}
							else
							#end
							{
								if(animIndices != null && animIndices.length > 0) {
									animation.addByIndices(animAnim, animName, animIndices, "", animFps, animLoop);
								} else {
									animation.addByPrefix(animAnim, animName, animFps, animLoop);
								}
							}

							if(anim.offsets != null && anim.offsets.length > 1) {
								addOffset(anim.anim, anim.offsets[0], anim.offsets[1]);
							} else {
								addOffset(anim.anim, 0, 0);
							}
						}
					} else {
						#if flxanimate
						if (isAnimateAtlas)
						{
							if (atlas != null)
							{
								atlas.anim.addBySymbol('idle', 'BF idle dance', 24, false);
								addOffset('idle', 0, 0);
							}
						}
						else
						#end
						quickAnimAdd('idle', 'BF idle dance');
					}
				}
				#if flxanimate
				if (isAnimateAtlas) copyAtlasValues();
				#end
				//trace('Loaded file to character ' + curCharacter);
		}
		originalFlipX = flipX;

		if(animOffsets.exists('singLEFTmiss') || animOffsets.exists('singDOWNmiss') || animOffsets.exists('singUPmiss') || animOffsets.exists('singRIGHTmiss')) hasMissAnimations = true;
		recalculateDanceIdle();
		dance();

		if (isPlayer)
		{
			flipX = !flipX;

			/*// Doesn't flip for BF, since his are already in the right place???
			if (!curCharacter.startsWith('bf'))
			{
				// var animArray
				if(animation.getByName('singLEFT') != null && animation.getByName('singRIGHT') != null)
				{
					var oldRight = animation.getByName('singRIGHT').frames;
					animation.getByName('singRIGHT').frames = animation.getByName('singLEFT').frames;
					animation.getByName('singLEFT').frames = oldRight;
				}

				// IF THEY HAVE MISS ANIMATIONS??
				if (animation.getByName('singLEFTmiss') != null && animation.getByName('singRIGHTmiss') != null)
				{
					var oldMiss = animation.getByName('singRIGHTmiss').frames;
					animation.getByName('singRIGHTmiss').frames = animation.getByName('singLEFTmiss').frames;
					animation.getByName('singLEFTmiss').frames = oldMiss;
				}
			}*/
		}

		switch(curCharacter)
		{
			case 'pico-speaker':
				skipDance = true;
				loadMappedAnims();
				playAnim("shoot1");
		}
	}

	override function update(elapsed:Float)
	{
		#if ONLINE_ALLOWED
		// Short-circuits the idle/dance state machine when the online lobby wants to drive
		// animations itself, leaving the animation control to the lobby. Guarded so the
		// macro-off build is byte-for-byte unchanged.
		if (noAnimationBullshit) {
			super.update(elapsed);
			return;
		}
		#end

		#if flxanimate
		if (isAnimateAtlas && atlas != null && atlas.anim != null) atlas.update(elapsed);
		#end

		if(!debugMode && (!isAnimateAtlas ? (animation.curAnim != null) : #if flxanimate (atlas != null && atlas.anim != null && atlas.anim.curInstance != null && atlas.anim.curSymbol != null) #else false #end))
		{
			if(heyTimer > 0)
			{
				var playbackRate:Float = (PlayState.instance != null) ? PlayState.instance.playbackRate : 1;
				heyTimer -= elapsed * playbackRate;
				if(heyTimer <= 0)
				{
					if(specialAnim && (getAnimationName() == 'hey' || getAnimationName() == 'cheer'))
					{
						specialAnim = false;
						dance();
					}
					heyTimer = 0;
				}
			} else if(specialAnim && isAnimationFinished())
			{
				specialAnim = false;
				dance();
			}
			
			switch(curCharacter)
			{
				case 'pico-speaker':
					if(animationNotes.length > 0 && Conductor.songPosition > animationNotes[0][0])
					{
						var noteData:Int = 1;
						if(animationNotes[0][1] > 2) noteData = 3;

						noteData += FlxG.random.int(0, 1);
						playAnim('shoot' + noteData, true);
						animationNotes.shift();
					}
					if(isAnimationFinished()) playAnim(getAnimationName(), false, false, getAnimationLength() - 3);
			}

			if (!isPlayer)
			{
				if (getAnimationName().startsWith('sing'))
				{
					holdTimer += elapsed;
				}

				if (holdTimer >= Conductor.stepCrochet * (0.0011 / (FlxG.sound.music != null ? FlxG.sound.music.pitch : 1)) * singDuration)
				{
					dance();
					holdTimer = 0;
				}
			}

			if(isAnimationFinished() && hasAnimation(getAnimationName() + '-loop'))
			{
				playAnim(getAnimationName() + '-loop');
			}
		}
		super.update(elapsed);
	}

	public var danced:Bool = false;

	/**
	 * FOR GF DANCING SHIT
	 */
	public function dance()
	{
		if (animation == null) return;
		if (!debugMode && !skipDance && !specialAnim)
		{
			if(danceIdle)
			{
				danced = !danced;

				if (danced)
					playAnim('danceRight' + idleSuffix);
				else
					playAnim('danceLeft' + idleSuffix);
			}
			else if(hasAnimation('idle' + idleSuffix)) {
					playAnim('idle' + idleSuffix);
			}
		}
	}

	public function playAnim(AnimName:String, Force:Bool = false, Reversed:Bool = false, Frame:Int = 0):Void
	{
		#if flxanimate
		if (isAnimateAtlas)
		{
			if (atlas == null || atlas.anim == null) return;
			atlas.anim.play(AnimName, Force, Reversed, Frame);
			atlas.update(0);
		}
		else
		#end
		{
			if (animation == null) return;
			animation.play(AnimName, Force, Reversed, Frame);
		}

		#if ONLINE_ALLOWED
		// Records whether the animation just played is a miss animation; the online lobby reads
		// `isMissing`.
		// `specialAnim` is deliberately NOT cleared here: this engine's `specialAnim` state machine
		// (set for hey/cheer) is different and clearing it here would change single-player behaviour
		// inside the same build.
		isMissing = AnimName.endsWith("miss");
		#end
		_lastPlayedAnimation = AnimName;
		specialAnim = false;

		var daOffset = animOffsets.get(AnimName);
		if (animOffsets.exists(AnimName))
		{
			offset.set(daOffset[0], daOffset[1]);
		}
		else
			offset.set(0, 0);

		if (curCharacter.startsWith('gf'))
		{
			if (AnimName == 'singLEFT')
			{
				danced = true;
			}
			else if (AnimName == 'singRIGHT')
			{
				danced = false;
			}

			if (AnimName == 'singUP' || AnimName == 'singDOWN')
			{
				danced = !danced;
			}
		}
	}
	
	function loadMappedAnims():Void
	{
		if (PlayState.SONG == null || PlayState.SONG.song == null) return;
		var chart = Song.loadFromJson('picospeaker', Paths.formatToSongPath(PlayState.SONG.song));
		if (chart == null || chart.notes == null) return;
		var noteData:Array<SwagSection> = chart.notes;
		for (section in noteData) {
			if (section == null || section.sectionNotes == null) continue;
			for (songNotes in section.sectionNotes) {
				if (songNotes != null)
					animationNotes.push(songNotes);
			}
		}
		TankmenBG.animationNotes = animationNotes;
		animationNotes.sort(sortAnims);
	}

	function sortAnims(Obj1:Array<Dynamic>, Obj2:Array<Dynamic>):Int
	{
		return FlxSort.byValues(FlxSort.ASCENDING, Obj1[0], Obj2[0]);
	}

	public var danceEveryNumBeats:Int = 2;
	private var settingCharacterUp:Bool = true;
	public function recalculateDanceIdle() {
		var lastDanceIdle:Bool = danceIdle;
		danceIdle = (hasAnimation('danceLeft' + idleSuffix) && hasAnimation('danceRight' + idleSuffix));

		if(settingCharacterUp)
		{
			danceEveryNumBeats = (danceIdle ? 1 : 2);
		}
		else if(lastDanceIdle != danceIdle)
		{
			var calc:Float = danceEveryNumBeats;
			if(danceIdle)
				calc /= 2;
			else
				calc *= 2;

			danceEveryNumBeats = Math.round(Math.max(calc, 1));
		}
		settingCharacterUp = false;
	}

	public function addOffset(name:String, x:Float = 0, y:Float = 0)
	{
		animOffsets[name] = [x, y];
	}

	public function quickAnimAdd(name:String, anim:String)
	{
		animation.addByPrefix(name, anim, 24, false);
	}

	// ===== 兼容 Psych 0.7.3+ 回调必需的辅助方法 =====

	inline public function isAnimationNull():Bool
	{
		#if flxanimate
		if (isAnimateAtlas) return atlas == null || atlas.anim == null || atlas.anim.curInstance == null || atlas.anim.curSymbol == null;
		#end
		return animation.curAnim == null;
	}

	/** 获取当前播放的动画名称 (HScript 回调如 goodNoteHit/opponentNoteHit 等依赖此方法) */
	public function getAnimationName():String
	{
		if (isAnimationNull()) return '';
		#if flxanimate
		if (isAnimateAtlas) return _lastPlayedAnimation;
		#end
		return animation.curAnim.name;
	}

	/** 获取当前动画总帧数 */
	public function getAnimationLength():Int
	{
		#if flxanimate
		if (isAnimateAtlas && atlas != null && atlas.anim != null) return atlas.anim.length;
		#end
		if (animation.curAnim == null) return 0;
		return animation.curAnim.frames.length;
	}

	/** 获取当前动画帧号 */
	public function getAnimationFrame():Int
	{
		#if flxanimate
		if (isAnimateAtlas && atlas != null && atlas.anim != null) return atlas.anim.curFrame;
		#end
		if (animation.curAnim == null) return 0;
		return animation.curAnim.curFrame;
	}

	/** 检查当前动画是否播放完毕 */
	public function isAnimationFinished():Bool
	{
		if (isAnimationNull()) return false;
		#if flxanimate
		if (isAnimateAtlas) return atlas.anim.finished;
		#end
		return animation.curAnim.finished;
	}

	/** 强制结束当前动画 */
	public function finishAnimation():Void
	{
		if (isAnimationNull()) return;
		#if flxanimate
		if (isAnimateAtlas)
		{
			atlas.anim.curFrame = atlas.anim.length - 1;
			return;
		}
		#end
		animation.curAnim.finish();
	}

	/** 检查某动画名称是否存在 (通过 animOffsets 判断，兼容 104 版 Character API) */
	public function hasAnimation(anim:String):Bool
	{
		#if flxanimate
		if (isAnimateAtlas) return animOffsets.exists(anim);
		#end
		return animation.getByName(anim) != null;
	}

	#if flxanimate
	public override function draw()
	{
		if (isAnimateAtlas)
		{
			if (atlas != null && atlas.anim != null && atlas.anim.curInstance != null && atlas.anim.curSymbol != null)
			{
				copyAtlasValues();
				atlas.draw();
			}
			return;
		}
		super.draw();
	}

	public function copyAtlasValues()
	{
		if (atlas == null) return;
		@:privateAccess
		{
			atlas.cameras = cameras;
			atlas.scrollFactor = scrollFactor;
			atlas.scale = scale;
			atlas.offset = offset;
			atlas.origin = origin;
			atlas.x = x;
			atlas.y = y;
			atlas.angle = angle;
			atlas.alpha = alpha;
			atlas.visible = visible;
			atlas.flipX = flipX;
			atlas.flipY = flipY;
			atlas.shader = shader;
			atlas.antialiasing = antialiasing;
			atlas.color = color;
		}
	}

	public override function destroy()
	{
		atlas = FlxDestroyUtil.destroy(atlas);
		super.destroy();
	}
	#end

	#if ONLINE_ALLOWED
	/**
	 * The room's per-player "noteHold" callback writes it on the remote player's character;
	 * the setter echoes the LOCAL player's own hold state back to the room.
	 *
	 * The setter condition is `PlayState.isCharacterPlayer(this)`, i.e. the same
	 * `playsAsBF() ? boyfriend : dad` definition as the `self` check. `online.GameClient.send()`
	 * is a no-op while disconnected.
	 * Guarded and appended at the very end of the class body so the macro-off build is
	 * unchanged.
	 * unchanged.
	 */
	public var noteHold(default, set):Bool = false;

	function set_noteHold(v:Bool):Bool {
		if (online.GameClient.isConnected() && PlayState.isCharacterPlayer(this) && noteHold != v)
			online.GameClient.send("noteHold", v);

		return noteHold = v;
	}
	#end
}
