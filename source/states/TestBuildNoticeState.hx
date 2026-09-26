package states;

import flixel.FlxState;
import flixel.addons.transition.FlxTransitionableState;

/**
 * Cold-start notice for TEST BUILDS ONLY: shown once per launch, before the title screen,
 * when the version string carries "pre"/"beta" (BuildInfo.isTestBuild()). Release builds
 * never see it (shouldShow() returns false and the boot goes straight to TitleState).
 *
 * Kept separate from the note-optimisation disclaimer on purpose: this one is about the
 * build itself and belongs at launch, that one is about one settings page and belongs
 * where the player opens that page (backend.NoteOptimisationNotice).
 *
 * It sits in the boot chain rather than in the options menu: desktop boots straight into it
 * (Main.setupGame replaces initialState) and mobile reaches it from CopyState.handOver()
 * once the assets are verified. It is un-skippable but never dead-ends: ENTER / SPACE /
 * BACK, the virtual pad's A button or a click on the Continue button hands over to the
 * title state.
 *
 * "Every cold start" is a process-local decision on purpose. Persisting it would turn it
 * into FlashingState's show-once behaviour, which is not what was asked for.
 *
 * The hand-over uses plain FlxG.switchState: the boot path must not create a
 * CustomFadeTransition substate (see the long comment in CopyState.handOver()).
 */
class TestBuildNoticeState extends MusicBeatState
{
	/** False until this process showed the notice; deliberately never written to disk. */
	public static var shownThisSession:Bool = false;

	/** Input is ignored for a moment so the window activation click cannot dismiss it. */
	static inline var INPUT_GRACE:Float = 0.3;
	static inline var BUTTON_WIDTH:Int = 340;
	static inline var BUTTON_HEIGHT:Int = 64;

	var leaving:Bool = false;
	var age:Float = 0;
	var continueButton:FlxSprite;

	public function new()
	{
		super();
	}

	/** True when this process still owes the test-build notice. Never true on a release build. */
	public static function shouldShow():Bool
	{
		return !shownThisSession && BuildInfo.isTestBuild();
	}

	/**
	 * Body of the test-build notice. The English default is inlined so a missing language
	 * file can never show an empty page (same style as FlashingState).
	 */
	public static function body():String
	{
		return Language.get('TestBuildNotice.body',
			'{version} ({build}) is a development build.\n'
			+ 'Features may be incomplete or change at any time, and save data may change format '
			+ 'between builds.\n'
			+ 'Keep a backup of anything you care about.')
			.replace('{version}', BuildInfo.appVersion())
			.replace('{build}', BuildInfo.buildId());
	}

	override function create():Void
	{
		shownThisSession = true;

		#if !mobile
		// Desktop boots straight into this state (Main.setupGame), so it owns the same
		// prefs bootstrap CopyState performs on mobile before its first frame. The order
		// mirrors CopyState.create() exactly:
		//   1. PlayerSettings.init(), because MusicBeatState.create() dereferences
		//      PlayerSettings.player1.controls through the "controls" property.
		//   2. ClientPrefs.ensureLoaded() before super.create(), so Language.load() and
		//      every ClientPrefs read below see the player's saved language.
		//   3. The storage root, now that the saved storageType is in memory.
		if (PlayerSettings.player1 == null)
			PlayerSettings.init();
		ClientPrefs.ensureLoaded();
		#if sys
		SUtil.applyStorageDirectory();
		#end
		#end

		// No fade substate on the boot path.
		FlxTransitionableState.skipNextTransIn = true;
		FlxTransitionableState.skipNextTransOut = true;

		super.create();

		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end

		add(new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK));

		var font:String = Paths.font('vcrcn.ttf');

		var titleText:FlxText = new FlxText(40, 96, FlxG.width - 80, Language.get('TestBuildNotice.title', 'Test Build'), 46);
		titleText.setFormat(font, 46, 0xFFFFD24A, CENTER);
		add(titleText);

		var bodyText:FlxText = new FlxText(80, 226, FlxG.width - 160, body(), 26);
		bodyText.setFormat(font, 26, FlxColor.WHITE, CENTER);
		bodyText.wordWrap = true;
		add(bodyText);

		// A real button, because a click anywhere is too easy to trigger by accident (the
		// window steals focus on launch and the first click would dismiss the notice).
		continueButton = new FlxSprite().makeGraphic(BUTTON_WIDTH, BUTTON_HEIGHT, 0xFF23262E);
		continueButton.x = Math.round((FlxG.width - BUTTON_WIDTH) / 2);
		continueButton.y = FlxG.height - BUTTON_HEIGHT - 62;
		add(continueButton);

		var continueText:FlxText = new FlxText(continueButton.x, continueButton.y, BUTTON_WIDTH,
			Language.get('TestBuildNotice.continue', 'Continue'), 28);
		continueText.setFormat(font, 28, 0xFFFFD24A, CENTER);
		continueText.y = continueButton.y + Math.round((BUTTON_HEIGHT - continueText.height) / 2);
		add(continueText);

		var hintText:FlxText = new FlxText(0, FlxG.height - 40, FlxG.width,
			Language.get('TestBuildNotice.continueHint', 'Press ENTER / SPACE, or click Continue'), 16);
		hintText.setFormat(font, 16, 0xFF9A9A9A, CENTER);
		add(hintText);

		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(NONE, A_B);
		#end
	}

	override function update(elapsed:Float):Void
	{
		#if LUA_ALLOWED
		callOnLuas('onUpdate', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdate', [elapsed]);
		#end

		age += elapsed;

		if (!leaving && age >= INPUT_GRACE && wantsToLeave())
		{
			leaving = true;
			FlxG.sound.play(Paths.sound('confirmMenu'));
			FlxTransitionableState.skipNextTransIn = true;
			FlxTransitionableState.skipNextTransOut = true;
			FlxG.switchState(buildNextState());
			return;
		}

		super.update(elapsed);

		#if LUA_ALLOWED
		callOnLuas('onUpdatePost', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdatePost', [elapsed]);
		#end
	}

	/** Deliberate input only: confirm keys/pad, or a click on the Continue button. */
	function wantsToLeave():Bool
	{
		if (controls.ACCEPT || controls.BACK)
			return true;
		return FlxG.mouse.justPressed && continueButton != null && FlxG.mouse.overlaps(continueButton);
	}

	/** What comes after the notice: the title screen, honouring mod state replacements. */
	function buildNextState():FlxState
	{
		var next:FlxState = new TitleState();
		#if MODS_ALLOWED
		// The redirect CopyState.handOver() applies; TitleState itself re-checks
		// stateRedirects on its first update as well.
		next = states.ModState.resolveState(next);
		#end
		return next;
	}
}
