package states;

import flixel.FlxState;
import flixel.addons.transition.FlxTransitionableState;

/**
 * The single cold-start notice: the test-build warning (only when the version string
 * carries "pre"/"beta") followed by the note-optimisation disclaimer (every launch).
 *
 * It sits in the boot chain rather than in the options menu, because the user asked for
 * "once per cold start" rather than "once per visit to the note-optimisation page":
 * desktop boots straight into it (Main.setupGame replaces initialState) and mobile reaches
 * it from CopyState.handOver() once the assets are verified. It is un-skippable but never
 * dead-ends: ENTER / SPACE / BACK, a click or the virtual pad's A button hands over to the
 * title state.
 *
 * "Every cold start" is a process-local decision on purpose. Persisting it would turn it
 * into FlashingState's show-once behaviour, which is explicitly not what was asked for.
 *
 * The hand-over uses plain FlxG.switchState: the boot path must not create a
 * CustomFadeTransition substate (see the long comment in CopyState.handOver()).
 */
class TestBuildNoticeState extends MusicBeatState
{
	/** False until this process showed the notice; deliberately never written to disk. */
	public static var shownThisSession:Bool = false;

	/** Input is ignored for a moment so the click that launched the game cannot dismiss it. */
	static inline var INPUT_GRACE:Float = 0.2;

	var leaving:Bool = false;
	var age:Float = 0;

	public function new()
	{
		super();
	}

	/** Whether this process still owes the player the cold-start notice. */
	public static function shouldShow():Bool
	{
		return !shownThisSession;
	}

	/**
	 * Body of the merged notice, shared by the blocking page and the "show the notice
	 * again" action row in the note-optimisation page. English defaults are inlined so a
	 * missing language file can never show an empty page (same style as FlashingState).
	 */
	public static function noticeBody():String
	{
		var body:String = '';

		if (BuildInfo.isTestBuild())
		{
			body += Language.get('TestBuildNotice.testBuild',
				'Test build - {version} ({build}).\n'
				+ 'This version is still in development: features may be incomplete, may change at any time, '
				+ 'and save data may change format between builds.')
				.replace('{version}', BuildInfo.appVersion())
				.replace('{build}', BuildInfo.buildId())
				+ '\n\n';
		}

		body += Language.get('TestBuildNotice.noteOptimization',
			'Note optimisation - read this first\n'
			+ 'The note optimisation in this engine is a side feature, not a product. It exists so that '
			+ 'enormous charts (tens of millions of notes) can at least be played; it was not written by a '
			+ 'dedicated note-optimisation project and does not try to match one.\n'
			+ 'If it is slower or rougher than such an engine, that is expected. Please use that engine '
			+ 'instead of filing a complaint here.\n'
			+ '(Shown once on every launch.)');

		return body;
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

		var titleText:FlxText = new FlxText(40, 52, FlxG.width - 80, Language.get('TestBuildNotice.title', 'Before You Play'), 40);
		titleText.setFormat(font, 40, FlxColor.WHITE, CENTER);
		add(titleText);

		var bodyText:FlxText = new FlxText(60, 128, FlxG.width - 120, noticeBody(), 22);
		bodyText.setFormat(font, 22, FlxColor.WHITE, CENTER);
		bodyText.wordWrap = true;
		add(bodyText);

		var continueText:FlxText = new FlxText(0, FlxG.height - 88, FlxG.width, Language.get('TestBuildNotice.continue', 'Continue'), 28);
		continueText.setFormat(font, 28, 0xFFFFD24A, CENTER);
		add(continueText);

		var hintText:FlxText = new FlxText(0, FlxG.height - 48, FlxG.width,
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

		if (!leaving && age >= INPUT_GRACE && (controls.ACCEPT || controls.BACK || FlxG.mouse.justPressed))
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
