package states;

import backend.BootBar;
import backend.boot.BootArt;
import backend.boot.BootChip;
import backend.boot.BootEmblem;
import backend.boot.BootInfo;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.FlxState;
import flixel.addons.transition.FlxTransitionableState;
import flixel.input.gamepad.FlxGamepadInputID;
import flixel.math.FlxMath;
import flixel.system.FlxSound;
import flixel.text.FlxText;
import flixel.text.FlxText.FlxTextAlign;
import flixel.util.FlxColor;
import mohong.TraceManager;
import openfl.display.BlendMode;

using StringTools;

/**
 * The single boot/loading state, shared by every platform.
 *
 * On desktop and web this IS the first state; on mobile CopyState extends it and adds the
 * asset-extraction pass on top, so a cold start shows exactly one loading screen
 * everywhere.
 *
 * ── What is on screen ──
 *
 * A deep violet sky with a drifting star field, a soft nebula bloom, and the SEIUN mark at
 * the centre: a hexagonal core inside two counter-rotating arcs, circumscribed by a
 * segmented gauge that fills as real work completes. Under it the wordmark rises letter by
 * letter, then a hairline, the tagline, and four corner chips that say which build this is,
 * which platform it runs on, which renderer is drawing the frame and which Psych Engine
 * this fork is based on. At the bottom, the loading bar: track with quarter ticks, gradient
 * fill with a glowing head, the localised task line, the percentage, and the asset key
 * currently being decoded.
 *
 * The engine has no icon yet, so the mark is generated geometry rather than someone else's
 * logo — the old splash flew in HaxeFlixel's own artwork, which said "flixel", not "Seiun".
 * Nothing here reads a file: every gradient, ring, star and streak is drawn into a bitmap
 * at create(), which is also what lets the boot look finished on a first Android launch
 * before a single asset exists on disk. The only assets it touches are the two renderer
 * wordmarks (white masks that are tinted), and a missing one simply drops the icon.
 *
 * ── Why it does not feel stiff ──
 *
 * The splash is a parametric timeline, not a tween chain: every transform is a pure
 * function of the local clock, so skipping is just "jump the clock" and a decode hitch can
 * never desync the choreography from the audio. Four light streaks launch from the corners
 * on the jingle's first four notes and converge on the fifth, where the mark ignites with a
 * shock ring; the mark then settles up and out of the way while the wordmark letters arrive
 * in a stagger. After that nothing is static: the arcs counter-rotate, the spark breathes,
 * a comet rides the ring, the gauge head pulses, the stars drift, and every label fades in
 * with its own eased offset instead of appearing at full strength.
 *
 * ── What it actually loads ──
 *
 * The work, per platform:
 *   - Android first boot: the CopyState extraction (native thread) maps onto [0, 0.8],
 *     then the shared precache onto [0.8, 1].
 *   - Desktop / web / up-to-date mobile: the shared precache over the full range —
 *     the title/menu chain graphics decoded into the bitmap cache and the menu music +
 *     navigation sounds warmed, one item per frame. Nothing is faked: the bar only ever
 *     shows work that has actually finished, and the boot lasts exactly as long as that
 *     work (plus the splash the player chose, which any input can cut short).
 *
 * Hand-over mirrors CopyState.handOver(): plain FlxG.switchState, no fade substate, into
 * TestBuildNoticeState on test builds or TitleState (mod state redirect included).
 */
class BootState extends MusicBeatState
{
	// ── Splash timeline, locked to the flixel jingle ──
	// The four launch times are flixel's own FlxSplash piece timings — its sync points for
	// this exact jingle (a fast five-note riff). A streak leaves a corner on each of the
	// first four notes and all four converge on the resolving fifth, where the mark takes
	// over. Everything after that is measured from LAND_TIME, so the splash keeps its beat
	// even if the audio device takes a moment to start.
	static var launchTimes:Array<Float> = [0.041, 0.184, 0.334, 0.495];
	static inline var LAND_TIME:Float = 0.636;
	/** Impact energy decay: the shock ring and the core burst. */
	static inline var FLASH_TIME:Float = 0.40;
	/** Scale punch after the streaks land. */
	static inline var PUNCH_TIME:Float = 0.34;
	/** The mark rises from the assembly point to its resting place. */
	static inline var SETTLE_START:Float = 1.00;
	static inline var SETTLE_TIME:Float = 0.62;
	/** Wordmark letters: first letter, delay between letters, per-letter fade. */
	static inline var WORD_START:Float = 1.10;
	static inline var WORD_STAGGER:Float = 0.030;
	static inline var WORD_TIME:Float = 0.26;
	static inline var DIVIDER_START:Float = 1.50;
	static inline var DIVIDER_TIME:Float = 0.28;
	static inline var SUB_START:Float = 1.62;
	static inline var SUB_TIME:Float = 0.26;
	static inline var CHIP_START:Float = 1.66;
	static inline var CHIP_TIME:Float = 0.34;
	static inline var BAR_START:Float = 1.70;
	static inline var BAR_TIME:Float = 0.30;
	/** Every element above has finished by here; the loading phase takes over. */
	static inline var SPLASH_END:Float = 2.02;
	/** Beat of "Ready" before the screen fades, so the exit reads as deliberate. */
	static inline var FINISH_HOLD:Float = 0.55;
	static inline var FINISH_FADE:Float = 0.50;

	/** Window-activation clicks must not count as a skip (same lesson as TestBuildNoticeState). */
	static inline var SKIP_GRACE:Float = 0.25;
	/** How much of the bar the CopyState extraction pass may claim; precache gets the rest. */
	public static inline var EXTRACT_PORTION:Float = 0.8;

	static inline var PHASE_SPLASH:Int = 0;
	static inline var PHASE_LOADING:Int = 1;
	static inline var PHASE_FINISH:Int = 2;

	var phase:Int = PHASE_SPLASH;
	/** Real time since create(); drives the idle motions once the splash is over. */
	var clock:Float = 0;
	/** Splash timeline clock; follows the jingle's playhead while it plays. */
	var splashClock:Float = 0;
	/** Animation clock handed to the mark after the splash: continuous across the seam. */
	var sceneClock:Float = 0;
	var finishClock:Float = 0;
	var handedOver:Bool = false;
	/** 0..1 fade-out progress; scales the whole scene down as the state leaves. */
	var outro:Float = 0;

	// ── Backdrop ──
	var sky:FlxSprite;
	var starsA:FlxSprite;
	var starsB:FlxSprite;
	var nebulaWide:FlxSprite;
	var nebulaCore:FlxSprite;
	var vignette:FlxSprite;
	var starDrift:Float = 0;

	// ── Cast ──
	var emblem:BootEmblem;
	var shards:Array<FlxSprite> = [];
	var shardHeads:Array<FlxSprite> = [];
	/** Start and target of each streak, in stage units (targets are the mark's centre). */
	var shardFrom:Array<flixel.math.FlxPoint> = [];
	var wordmark:Array<FlxText> = [];
	var divider:FlxSprite;
	var subline:FlxText;
	var tagVersion:FlxText;
	var chipPlatform:BootChip;
	var chipRenderer:BootChip;
	/** Container for the corner chips, so a rebuild cannot reorder the whole scene. */
	var chipLayer:flixel.group.FlxGroup;
	var chipFont:String;
	var chipSize:Int;
	/** Last fade value the chips were given, re-applied when a chip is rebuilt. */
	var chipPresence:Float = 0;
	// Public for CopyState, which drives these during its extraction pass.
	public var bar:BootBar;
	var fade:FlxSprite;
	var jingle:FlxSound;

	// ── Layout (computed once, from the real stage size) ──
	var u:Float = 1;
	var cx:Float;
	var margin:Float;
	var emblemRestY:Float;
	var emblemAssemblyY:Float;
	var wordY:Float;
	var dividerY:Float;
	var subY:Float;
	var barY:Float;
	var chipTopY:Float;
	var chipBottomY:Float;
	var wordSize:Int;

	// ── Telemetry refresh (renderer flip, GL version) ──
	var telemetryClock:Float = 0;
	var shownRenderer:String = '';
	var rendererIconHeight:Float;

	// ── Real work queue ──
	var workQueue:Array<Void->Void> = [];
	/** One short label per queue entry, shown under the bar while it loads. */
	var workLabels:Array<String> = [];
	var workIndex:Int = 0;
	var graphicsWorkCount:Int = 0;
	/** Only true once beginPrecache() ran — keeps the queue idle during CopyState extraction. */
	var workActive:Bool = false;
	var workFinished:Bool = false;
	/** True once the splash has handed over to the loading phase. */
	public var introFinished(get, never):Bool;

	inline function get_introFinished():Bool
	{
		return phase != PHASE_SPLASH;
	}

	// CopyState maps its extraction onto a sub-range of the bar before precaching.
	public var rangeStart:Float = 0;
	public var rangeEnd:Float = 1;

	var cachedTimestep:Bool = false;

	// ── Timeline clock ──
	/**
	 * Frames presented before the timeline starts.
	 *
	 * The first frame after create() is by far the most expensive one in the whole engine:
	 * shader compilation, the first texture uploads, the first present. If the splash clock
	 * started at create(), that single frame would eat the entire intro and the player would
	 * see the finished scene instead of the animation. Two frames of warm-up buy the intro
	 * back, and the backlog (sky, stars, nebula) is already drawn during them.
	 */
	static inline var WARMUP_FRAMES:Int = 2;
	/**
	 * Alpha used to keep everything on screen during the warm-up frames.
	 *
	 * FlxSprite skips drawing at alpha 0, and a skipped sprite never uploads its texture —
	 * so twelve wordmark letters, the four chips and the whole emblem would each pay their
	 * upload on the frame they first become visible. That is exactly the 100 ms hitch that
	 * used to land on the mark's ignition. Drawing them once at a barely-there alpha
	 * spends the upload before the clock starts.
	 */
	static inline var PREWARM_ALPHA:Float = 0.012;
	/**
	 * A single frame slower than this pauses the timeline rather than skipping it.
	 *
	 * Real time keeps the choreography honest through ordinary jank, but a 400 ms stall
	 * (alt-tab, disk hiccup, GC) would otherwise fast-forward past the whole arrival. Pausing
	 * keeps the moment readable; the only cost is a short drift against the jingle, which is
	 * corrected as soon as the two are close again.
	 */
	static inline var HITCH_TOLERANCE:Float = 0.30;

	var frameIndex:Int = 0;
	var timelineStarted:Bool = false;
	var timelineFirstTick:Bool = true;
	/** haxe.Timer.stamp() of the moment the timeline started. */
	var wallStart:Float = 0;
	var lastWall:Float = 0;
	/** Time swallowed by stalls, added back so the clock does not skip. */
	var pausedTime:Float = 0;
	/** Frames to leave alone after an expensive decode, so stalls do not pile up. */
	var workCooldown:Int = 0;
	/** Worst frame time seen during the splash: the one number that says how smooth it was. */
	var splashWorstFrame:Float = 0;

	/** True once the openfl-stage watermark was pushed out of the way for the boot. */
	var watermarkHidden:Bool = false;

	#if sys
	/** Design-review probes; unset in every normal run. See parseDevProbes(). */
	var devHold:Float = -1;
	var devProgress:Float = -1;
	/** SEIUN_BOOT_STATS=1 prints the boot timeline and its worst frame to stdout. */
	var devStats:Bool = false;
	#end

	override public function create():Void
	{
		// The boot-path prefs bootstrap, in the same order CopyState/TestBuildNoticeState
		// established: controls first, saved prefs before super.create() (Language.load),
		// then the storage root resolved against the saved storageType.
		if (PlayerSettings.player1 == null)
			PlayerSettings.init();
		ClientPrefs.ensureLoaded();
		#if sys
		SUtil.applyStorageDirectory();
		#end

		// Fixed timestep off while the jingle and the choreography need to stay locked
		// together (same reasoning as flixel's own FlxSplash).
		cachedTimestep = FlxG.fixedTimestep;
		FlxG.fixedTimestep = false;

		FlxTransitionableState.skipNextTransIn = true;
		FlxTransitionableState.skipNextTransOut = true;

		showMouseCursor = false;
		super.create();

		#if sys
		if (Sys.getEnv('FNF_GFX_CAPS') == '1') backend.gfx.GfxCaps.logOnce();
		var paletteProbe:String = Sys.getEnv('FNF_GFX_PALETTE_TEST');
		if (paletteProbe != null && paletteProbe.length > 0)
		{
			FlxG.switchState(new states.GfxPaletteProbeState(paletteProbe));
			return;
		}
		#end
		FlxG.cameras.bgColor = FlxColor.BLACK;
		FlxG.mouse.visible = false; // TestBuildNoticeState turns the cursor back on.

		computeLayout();
		buildBackdrop();
		buildEmblem();
		buildSplashPieces();
		buildType();
		buildChips();
		buildBar();
		buildFade();

		// Frame zero: every element in its "not yet" pose. Without this the first drawn
		// frame would show everything at full strength for one frame before the timeline
		// starts, which is exactly the kind of pop this screen is supposed to avoid.
		applyScene(0, false);

		#if sys
		parseDevProbes();
		#end

		// Queues the work; nothing is decoded until the splash is over (see processWork).
		startBootFlow();

		TraceManager.info('trace.boot.start', 'Boot screen up (procedural splash + real preload)');
	}

	/**
	 * What the boot actually does after the scene is up. BootState's default is the shared
	 * precache; CopyState overrides this to run the extraction pass first and hand the
	 * remainder of the bar to beginPrecache() when it finishes.
	 */
	function startBootFlow():Void
	{
		beginPrecache();
	}

	override public function update(elapsed:Float):Void
	{
		var dt:Float = sanitizeElapsed(elapsed);
		clock += dt;
		frameIndex++;

		// The stage watermark prints the same version line the boot screen already shows,
		// and it is installed after create() (Main adds it once the FlxGame child exists),
		// so it is tucked away on the first frame instead of competing with the composition.
		if (!watermarkHidden)
		{
			watermarkHidden = true;
			backend.Watermark.setVisible(false);
		}

		// Warm-up: hold the timeline at zero until the renderer has drawn its first frames.
		if (!timelineStarted)
		{
			if (frameIndex >= WARMUP_FRAMES)
				beginTimeline();
			applyScene(0, false, true);
			driftStars(dt);
			super.update(elapsed);
			return;
		}

		refreshTelemetry(dt);

		#if sys
		// Design review: freeze one moment of the boot so a screenshot is reproducible.
		if (devHold >= 0 || devProgress >= 0)
		{
			if (devProgress >= 0)
			{
				phase = PHASE_LOADING;
				sceneClock = SPLASH_END;
				bar.target = devProgress;
				bar.displayed = devProgress;
				applyScene(sceneClock, true);
			}
			else
			{
				phase = PHASE_SPLASH;
				applyScene(devHold, false);
			}
			driftStars(dt);
			super.update(elapsed);
			return;
		}
		#end

		if (phase == PHASE_SPLASH)
		{
			// Real time, with the jingle as the audio truth while the two are in step. Any
			// input skips the SPLASH only — loading itself stays input-free.
			splashClock = advanceTimeline();
			// Measured from the second splash frame: the first one carries the warm-up frame
			// that preceded it, and that cost is not part of the intro any more.
			if (splashClock > 0 && elapsed > splashWorstFrame) splashWorstFrame = elapsed;
			#if sys
			if (devStats && elapsed > 0.05)
				Sys.println('[boot] slow frame ' + Math.round(elapsed * 1000) + 'ms at t=' + splashClock + ' frame=' + frameIndex);
			#end

			if (splashClock > SKIP_GRACE && anyInputPressed())
				skipSplash();
		}

		switch (phase)
		{
			case PHASE_SPLASH:
				applyScene(splashClock, false);
				if (splashClock >= SPLASH_END)
				{
					phase = PHASE_LOADING;
					sceneClock = SPLASH_END;
					applyScene(sceneClock, true);
					var worst:Int = Math.round(splashWorstFrame * 1000);
					TraceManager.info('trace.boot.splashEnd', 'Splash finished at {}s (worst frame {} ms)', [splashClock, worst]);
					#if sys
					if (devStats) Sys.println('[boot] splash end t=' + splashClock + ' worstFrame=' + worst + 'ms');
					#end
				}
				processWork();
			case PHASE_LOADING:
				sceneClock += dt;
				applyScene(sceneClock, true);
				processWork();
			case PHASE_FINISH:
				sceneClock += dt;
				applyScene(sceneClock, true);
				finishClock += dt;
				var fadeP:Float = clamp01((finishClock - FINISH_HOLD) / FINISH_FADE);
				outro = fadeP;
				fade.alpha = easeInQuad(fadeP);
				if (finishClock >= FINISH_HOLD + FINISH_FADE && !handedOver)
				{
					handedOver = true;
					handOver();
				}
		}

		driftStars(dt);

		super.update(elapsed);
	}

	override public function destroy():Void
	{
		FlxG.fixedTimestep = cachedTimestep;
		super.destroy();
	}

	// ═══════════════════════════════════════════════════════════ Timeline clock

	/**
	 * Starts the splash: the clock origin and the jingle are armed together, after the
	 * warm-up frames, so the riff and the streaks begin on the same frame.
	 */
	function beginTimeline():Void
	{
		timelineStarted = true;
		wallStart = haxe.Timer.stamp();
		lastWall = wallStart;
		pausedTime = 0;
		startJingle();
	}

	/**
	 * Real elapsed time since the timeline started, minus the time lost to stalls.
	 *
	 * Real time is what keeps the choreography from turning into slow motion when frames
	 * are uneven — the old accumulate-and-clamp clock ran the whole intro at half speed on a
	 * loaded machine and made the splash feel like a frozen game rather than an animation.
	 * The two escape hatches:
	 *
	 *   - a frame slower than HITCH_TOLERANCE is treated as "about one frame", so a stall
	 *     pauses the intro instead of fast-forwarding past it;
	 *   - while the jingle plays it wins, but only while the two clocks are already close,
	 *     so the audio never snaps the picture forward by more than a beat.
	 */
	function advanceTimeline():Float
	{
		var now:Float = haxe.Timer.stamp();

		// The very first tick defines the origin: the frame that started the jingle is not
		// part of the intro, and counting its cost would skip the first beat.
		if (timelineFirstTick)
		{
			timelineFirstTick = false;
			lastWall = now;
			return 0;
		}

		var step:Float = now - lastWall;
		lastWall = now;

		if (step < 0)
		{
			// The platform clock went backwards (sleep/resume): rebase instead of freezing.
			wallStart += step;
			step = 0;
		}
		if (step > HITCH_TOLERANCE)
			pausedTime += step - (1 / 60);

		var t:Float = now - wallStart - pausedTime;

		#if (FLX_SOUND_SYSTEM && !web)
		if (jingle != null && jingle.playing)
		{
			var audio:Float = jingle.time / 1000;
			// Small backward pull is allowed (the audio device may start a beat late);
			// a large one would rewind the streaks, so it is ignored.
			if (audio >= t - 0.12 && audio <= t + 0.45)
				t = audio;
		}
		#end

		return t;
	}

	/**
	 * SEIUN_BOOT_HOLD / SEIUN_BOOT_PROGRESS: freeze one frame of the boot for design review.
	 *
	 * Unset in every normal run. Both are development aids only — the splash pose at
	 * SEIUN_BOOT_HOLD=<seconds> or the loading screen at SEIUN_BOOT_PROGRESS=<0..1> can be
	 * screenshotted exactly, which is the only way to compare a change to the previous
	 * layout without trying to catch a two-second animation with a stopwatch.
	 */
	#if sys
	function parseDevProbes():Void
	{
		var hold:String = Sys.getEnv('SEIUN_BOOT_HOLD');
		if (hold != null && hold.length > 0)
		{
			var value:Null<Float> = Std.parseFloat(hold);
			if (value != null && value >= 0) devHold = value;
		}

		devStats = (Sys.getEnv('SEIUN_BOOT_STATS') == '1');

		var progress:String = Sys.getEnv('SEIUN_BOOT_PROGRESS');
		if (progress != null && progress.length > 0)
		{
			var value:Null<Float> = Std.parseFloat(progress);
			if (value != null && value >= 0) devProgress = value < 0 ? 0 : (value > 1 ? 1 : value);
		}

		if (devHold >= 0 || devProgress >= 0)
			TraceManager.info('trace.boot.devFrozen', 'Boot frozen for review (hold {}, progress {})', [devHold, devProgress]);
	}
	#end

	// ════════════════════════════════════════════════════════════════ Layout

	/**
	 * All placement derives from one unit and one centre line, so a 4:3 stage, an ultra-wide
	 * stage and a phone stage all get the same composition instead of something pinned to
	 * 1280x720 breaking apart.
	 */
	function computeLayout():Void
	{
		u = Math.min(FlxG.width / 1280.0, FlxG.height / 720.0);
		if (u < 0.68) u = 0.68;
		if (u > 1.75) u = 1.75;

		cx = FlxG.width / 2;
		margin = 40 * u;
		emblemRestY = FlxG.height * 0.33;
		emblemAssemblyY = FlxG.height * 0.44;
		wordY = FlxG.height * 0.555;
		dividerY = wordY + 46 * u;
		subY = dividerY + 9 * u;
		barY = FlxG.height - 132 * u;
		chipTopY = 42 * u;
		chipBottomY = FlxG.height - 44 * u;
		wordSize = Std.int(32 * u);
		if (wordSize < 14) wordSize = 14;
		rendererIconHeight = 26 * u;

		TraceManager.info('trace.boot.layout', 'Boot layout on a {}x{} stage (unit {})', [FlxG.width, FlxG.height, u]);
	}

	// ════════════════════════════════════════════════════════════ Backdrop

	function buildBackdrop():Void
	{
		sky = new FlxSprite(0, 0, BootArt.verticalGradient(8, Std.int(FlxG.height), BootArt.VOID, BootArt.DEEP));
		sky.setGraphicSize(FlxG.width, FlxG.height);
		sky.updateHitbox();
		add(sky);

		// Two copies of one half-resolution star tile, drifting sideways and wrapping:
		// the seams fall exactly one tile-width apart, so the wrap is invisible.
		var starTile = BootArt.starTile(Std.int(FlxG.width / 2) + 2, Std.int(FlxG.height / 2) + 2, 80, 7, 0.85);
		starsA = new FlxSprite(0, 0, starTile);
		starsA.antialiasing = true;
		starsA.scale.set(2, 2);
		starsA.updateHitbox();
		starsA.alpha = 0.8;
		add(starsA);

		starsB = new FlxSprite(-FlxG.width, 0, starTile);
		starsB.antialiasing = true;
		starsB.scale.set(2, 2);
		starsB.updateHitbox();
		starsB.alpha = 0.8;
		add(starsB);

		nebulaWide = new FlxSprite(0, 0, BootArt.radialGlow(Std.int(1150 * u), BootArt.ACCENT_LEFT, 0.22, 2.1));
		centerOn(nebulaWide, cx, emblemRestY + 46 * u);
		nebulaWide.blend = BlendMode.SCREEN;
		add(nebulaWide);

		nebulaCore = new FlxSprite(0, 0, BootArt.radialGlow(Std.int(620 * u), BootArt.ACCENT_RIGHT, 0.10, 2.4));
		centerOn(nebulaCore, cx, emblemRestY + 10 * u);
		nebulaCore.blend = BlendMode.SCREEN;
		add(nebulaCore);

		vignette = new FlxSprite(0, 0, BootArt.vignette(FlxG.width, FlxG.height, 0.85));
		vignette.scale.set(2, 2);
		vignette.updateHitbox();
		add(vignette);
	}

	/** Horizontal parallax for the star layers; the wrap is one tile width exactly. */
	function driftStars(dt:Float):Void
	{
		starDrift += dt * 5.0;
		if (starDrift >= FlxG.width) starDrift -= FlxG.width;

		if (starsA != null)
		{
			starsA.x = starDrift;
			starsB.x = starDrift - FlxG.width;
			// A slow twinkle across the whole field, so the sky is never completely still.
			var twinkle:Float = 0.72 + 0.10 * Math.sin(clock * 0.7);
			starsA.alpha = twinkle;
			starsB.alpha = twinkle;
		}
	}

	// ════════════════════════════════════════════════════════════════ Cast

	function buildEmblem():Void
	{
		emblem = new BootEmblem(u);
		add(emblem);
	}

	function buildSplashPieces():Void
	{
		var shardW:Int = Std.int(160 * u);
		var shardH:Int = Std.int(10 * u);
		var shardBd = BootArt.shard(shardW, shardH, 0xC8DEFF, 0.95);
		var headBd = BootArt.dot(Std.int(30 * u), 0xE8F2FF, 0.95);

		for (i in 0...4)
		{
			var streak = new FlxSprite(0, 0, shardBd);
			// The head of the streak is its right end, so the pivot sits there and the tail
			// trails behind the direction of travel.
			streak.origin.set(shardW, shardH / 2);
			streak.blend = BlendMode.ADD;
			streak.visible = false;
			add(streak);
			shards.push(streak);

			var head = new FlxSprite(0, 0, headBd);
			head.blend = BlendMode.SCREEN;
			head.visible = false;
			add(head);
			shardHeads.push(head);

			var qx:Float = (i % 2 == 0) ? -1 : 1;
			var qy:Float = (i < 2) ? -1 : 1;
			shardFrom.push(flixel.math.FlxPoint.get(cx + qx * (FlxG.width * 0.62), emblemAssemblyY + qy * (FlxG.height * 0.62)));
		}
	}

	/**
	 * The type stack: wordmark letters (one text object each, so they can arrive in a
	 * stagger), a fading hairline, the tagline.
	 */
	function buildType():Void
	{
		var font:String = Paths.font('montserrat.ttf');
		var text:String = 'SEIUN ENGINE';
		var tracking:Float = 9 * u;

		var widths:Array<Float> = [];
		var total:Float = 0;
		for (i in 0...text.length)
		{
			var ch:String = text.charAt(i);
			var glyph = new FlxText(0, 0, 0, ch, wordSize);
			glyph.setFormat(font, wordSize, BootArt.INK, FlxTextAlign.LEFT);
			// Auto-sized text only knows its width after it has rasterised once, and the
			// letter positions are built from exactly that width.
			glyph.updateHitbox();
			glyph.alpha = 0;
			add(glyph);
			wordmark.push(glyph);

			var wdt:Float = (ch == ' ') ? wordSize * 0.36 : glyph.width;
			widths.push(wdt);
			total += wdt;
		}
		total += tracking * (text.length - 1);

		var x:Float = cx - total / 2;
		for (i in 0...wordmark.length)
		{
			var glyph = wordmark[i];
			glyph.x = x;
			glyph.y = wordY;
			x += widths[i] + tracking;
		}

		divider = new FlxSprite(0, 0, BootArt.fadingLine(Std.int(230 * u), Std.int(2 * u), BootArt.ACCENT_LEFT, BootArt.ACCENT_RIGHT, 0.9));
		divider.x = cx - divider.width / 2;
		divider.y = dividerY;
		divider.alpha = 0;
		add(divider);

		subline = new FlxText(0, subY, FlxG.width, 'RHYTHM ENGINE', Std.int(15 * u));
		subline.setFormat(Paths.font('vcr.ttf'), Std.int(15 * u), BootArt.MUTED, FlxTextAlign.CENTER);
		subline.alpha = 0;
		add(subline);

		// Version and build sit under the tagline: the version belongs with the name, and
		// the top-left corner of a running engine already carries the FPS panel.
		tagVersion = new FlxText(0, subY + 24 * u, FlxG.width, BootInfo.versionLine(), Std.int(13 * u));
		tagVersion.setFormat(Paths.font('vcr.ttf'), Std.int(13 * u), BootArt.INK_FAINT, FlxTextAlign.CENTER);
		tagVersion.alpha = 0;
		add(tagVersion);
	}

	function buildChips():Void
	{
		chipFont = Paths.font('vcr.ttf');
		chipSize = Std.int(16 * u);
		if (chipSize < 11) chipSize = 11;

		// One layer for all three: the renderer chip is rebuilt when the backend changes,
		// and a chip added straight to the state would end up drawn above the fade.
		chipLayer = new flixel.group.FlxGroup();
		add(chipLayer);

		chipPlatform = new BootChip(BootInfo.platformLine(), chipFont, chipSize, BootArt.MUTED);
		chipLayer.add(chipPlatform);
		chipPlatform.place(FlxG.width - margin, chipTopY, true);

		shownRenderer = BootInfo.rendererName();
		buildRendererChip();
	}

	/**
	 * (Re)creates the renderer chip.
	 *
	 * Rebuilt rather than mutated: the mark, the caption and the tint all change together
	 * when a Vulkan session takes the window over after the first frame, and building a
	 * fresh chip keeps the layout arithmetic in exactly one place — the constructor — which
	 * is the only version of it that has a chance of staying correct.
	 */
	function buildRendererChip():Void
	{
		if (chipRenderer != null)
		{
			chipLayer.remove(chipRenderer, true);
			chipRenderer.destroy();
		}

		// The mark already says "OpenGL" / "Vulkan", so the caption is only the fallback for
		// the case where the wordmarks could not be loaded yet (first mobile boot).
		var mark = BootInfo.rendererMark();
		var caption:String = (mark == null) ? BootInfo.rendererName() : '';
		chipRenderer = new BootChip(caption, chipFont, chipSize, BootInfo.rendererColor(), mark, rendererIconHeight);
		chipLayer.add(chipRenderer);
		chipRenderer.place(margin, chipBottomY);
		chipRenderer.fade(chipPresence);
	}

	function buildBar():Void
	{
		var barWidth:Float = Math.min(FlxG.width * 0.46, 620 * u);
		bar = new BootBar(barWidth, barY);
		add(bar);
		bar.setTask(Language.get('BootState.task.prepare', 'Preparing…'));
		bar.appear(0);
	}

	function buildFade():Void
	{
		fade = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		fade.alpha = 0;
		add(fade);
	}

	function startJingle():Void
	{
		// The classic flixel jingle, embedded by flixel itself on every target. Web keeps
		// FlxSplash's historic muted behaviour: browsers block autoplay before the first
		// user gesture, so trying to play there would only swallow the sound.
		#if (FLX_SOUND_SYSTEM && !web)
		jingle = FlxG.sound.load(flixel.system.FlxAssets.getSound("flixel/sounds/flixel"));
		if (jingle != null)
			jingle.play();
		#end
	}

	// ════════════════════════════════════════════════════════════ Timeline

	/**
	 * Poses the whole scene for one moment.
	 *
	 * @param t        animation clock (seconds)
	 * @param settled  true once the splash is over: every arriving element is at full
	 *                 strength, and only the idle motions keep running
	 */
	function applyScene(t:Float, settled:Bool, ?prewarm:Bool = false):Void
	{
		// Warm-up pass: everything stays on screen at a hair of an alpha so its texture is
		// uploaded before the intro needs it (see PREWARM_ALPHA).
		var floor:Float = prewarm ? PREWARM_ALPHA : 0;

		var sp:Float = settled ? 1 : easeInOutCubic(clamp01((t - SETTLE_START) / SETTLE_TIME));

		var presence:Float = settled ? 1 : clamp01((t - LAND_TIME) / 0.12);
		var flash:Float = settled ? 0 : Math.max(0, 1 - easeOutQuad(clamp01((t - LAND_TIME) / FLASH_TIME)));

		var punch:Float = 1;
		if (!settled && t >= LAND_TIME)
			punch = 1 + 0.26 * (1 - easeOutQuad(clamp01((t - LAND_TIME) / PUNCH_TIME)));

		// The mark: rises to its resting place while the type arrives under it.
		var emblemY:Float = FlxMath.lerp(emblemAssemblyY, emblemRestY, sp);
		var emblemScale:Float = FlxMath.lerp(0.84, 1.0, sp) * punch * (1 - 0.05 * outro);
		emblem.pose(cx, emblemY, t, Math.max(presence * (1 - 0.45 * outro), floor), emblemScale, bar.displayed, flash);

		applyShards(t, settled, prewarm);

		// Wordmark: one letter per slot, each with its own fade and rise.
		var wordFade:Float = 1 - 0.35 * outro;
		for (i in 0...wordmark.length)
		{
			var lp:Float = settled ? 1 : clamp01((t - (WORD_START + i * WORD_STAGGER)) / WORD_TIME);
			var glyph = wordmark[i];
			glyph.alpha = Math.max(lp * wordFade, floor);
			glyph.y = wordY + (1 - lp) * 14 * u - 6 * u * outro;
		}

		var divP:Float = settled ? 1 : clamp01((t - DIVIDER_START) / DIVIDER_TIME);
		divider.alpha = Math.max(divP * 0.9 * wordFade, floor);
		divider.y = dividerY + (1 - divP) * 8 * u;

		var subP:Float = settled ? 1 : clamp01((t - SUB_START) / SUB_TIME);
		subline.alpha = Math.max(subP * 0.95 * wordFade, floor);

		tagVersion.alpha = Math.max(subP * 0.85 * wordFade, floor);
		tagVersion.y = subY + 24 * u + (1 - subP) * 6 * u;

		var chipP:Float = Math.max(settled ? 1 : clamp01((t - CHIP_START) / CHIP_TIME), floor);
		chipPresence = chipP;
		chipPlatform.fade(chipP);
		chipRenderer.fade(chipP);

		var barP:Float = Math.max(settled ? 1 : clamp01((t - BAR_START) / BAR_TIME), floor);
		bar.appear(barP);
	}

	/** Four streaks from the corners, each on its own note of the jingle. */
	function applyShards(t:Float, settled:Bool, ?prewarm:Bool = false):Void
	{
		for (i in 0...shards.length)
		{
			var streak = shards[i];
			var head = shardHeads[i];

			if (prewarm)
			{
				// Parked on the mark, at a hair of an alpha: off-screen sprites are culled
				// before their texture is ever requested, so the warming copy has to sit
				// somewhere the camera actually draws.
				streak.visible = true;
				streak.angle = 0;
				streak.x = cx - streak.width;
				streak.y = emblemAssemblyY - streak.height / 2;
				streak.alpha = PREWARM_ALPHA;
				head.visible = true;
				head.x = cx - head.width / 2;
				head.y = emblemAssemblyY - head.height / 2;
				head.alpha = PREWARM_ALPHA;
				continue;
			}

			var p:Float = (t - launchTimes[i]) / (LAND_TIME - launchTimes[i]);
			if (settled || p <= 0 || p >= 1)
			{
				streak.visible = false;
				head.visible = false;
				continue;
			}

			var flight:Float = easeOutQuint(p);
			var from = shardFrom[i];
			var x:Float = FlxMath.lerp(from.x, cx, flight);
			var y:Float = FlxMath.lerp(from.y, emblemAssemblyY, flight);
			var dx:Float = cx - from.x;
			var dy:Float = emblemAssemblyY - from.y;
			var angle:Float = Math.atan2(dy, dx) * 180 / Math.PI;

			// Fade in fast, hold, then vanish into the impact instead of sliding under it.
			var alpha:Float = clamp01(p * 6) * (1 - clamp01((p - 0.82) / 0.18));

			streak.visible = true;
			streak.angle = angle;
			streak.x = x - streak.width;
			streak.y = y - streak.height / 2;
			streak.alpha = alpha;
			streak.scale.set(1 + 0.6 * (1 - flight), 0.55 + 0.45 * (1 - flight));

			head.visible = true;
			head.x = x - head.width / 2;
			head.y = y - head.height / 2;
			head.alpha = alpha * 0.9;
		}
	}

	// ════════════════════════════════════════════════════════════ Telemetry

	/**
	 * Keeps the corner chips honest.
	 *
	 * Two values can change while the boot is on screen: the GL version becomes readable
	 * once the renderer has created its context, and the active renderer itself flips when
	 * a Vulkan session hands the window over after the first frame. Both are polled at a
	 * low rate — this is a label, not a per-frame counter.
	 */
	function refreshTelemetry(dt:Float):Void
	{
		telemetryClock += dt;
		if (telemetryClock < 0.4) return;
		telemetryClock = 0;

		var name:String = BootInfo.rendererName();
		if (name != shownRenderer)
		{
			// A Vulkan session starts on OpenGL and takes the window over after the first
			// presented frame, so the chip really does have to change under the player.
			shownRenderer = name;
			buildRendererChip();
			TraceManager.info('trace.boot.rendererChip', 'Renderer chip switched to {}', [name]);
		}
	}

	// ════════════════════════════════════════════════════════════════ Skip

	function skipSplash():Void
	{
		TraceManager.info('trace.boot.skip', 'Splash skipped by input');
		stopJingle();
		splashClock = SPLASH_END;
		sceneClock = SPLASH_END;
		phase = PHASE_LOADING;
		applyScene(sceneClock, true);
	}

	function anyInputPressed():Bool
	{
		if (FlxG.keys.justPressed.ANY)
			return true;
		if (FlxG.mouse.justPressed)
			return true;
		#if mobile
		for (touch in FlxG.touches.list)
			if (touch.justPressed)
				return true;
		#end
		if (FlxG.gamepads.anyJustPressed(FlxGamepadInputID.ANY))
			return true;
		return false;
	}

	function stopJingle():Void
	{
		if (jingle != null && jingle.playing)
			jingle.stop();
	}

	// ════════════════════════════════════════════════════════════════ Real work

	/**
	 * Queue the shared precache over the remaining bar range. One item per frame: on cpp
	 * this is real disk IO + PNG decode + GPU upload for every title/menu graphic, and
	 * file opens for the menu audio — the exact cost the old boot paid as a hitch on the
	 * first screens.
	 */
	public function beginPrecache():Void
	{
		if (workActive)
			return;
		workActive = true;
		workFinished = false;
		workQueue = [];
		workLabels = [];
		workIndex = 0;

		// Title screen chain.
		queueAtlas('logoBumpin');
		queueAtlas('gfDanceTitle');
		queueAtlas('titleEnter');
		queueImage('logo');
		queueImage('newgrounds_logo');
		// Main menu chain.
		queueImage('alphabet');
		queueImage('menuBG');
		queueImage('menuDesat');
		queueAtlas('mainmenu/menu_story_mode');
		queueAtlas('mainmenu/menu_freeplay');
		#if ONLINE_ALLOWED
		queueAtlas('mainmenu/menu_online');
		#end
		#if MODS_ALLOWED
		queueAtlas('mainmenu/menu_mods');
		#end
		#if ACHIEVEMENTS_ALLOWED
		queueAtlas('mainmenu/menu_awards');
		#end
		queueAtlas('mainmenu/menu_credits');
		#if !switch
		queueAtlas('mainmenu/menu_donate');
		#end
		queueAtlas('mainmenu/menu_options');
		#if sys
		// Dedicated L2b acceptance probe: load one real atlas through the normal
		// Paths pipeline. Unset in every normal run, so boot work is unchanged.
		var repackProbe:String = Sys.getEnv('FNF_GFX_ATLAS_REPACK_TEST');
		if (repackProbe != null && repackProbe.length > 0) queueAtlas(repackProbe);
		#end
		graphicsWorkCount = workQueue.length;

		// Menu music + the three navigation blips (kept out of the purge, they are
		// needed on every single menu screen).
		queueMusic('freakyMenu');
		queueSound('scrollMenu');
		queueSound('confirmMenu');
		queueSound('cancelMenu');
	}

	function queueImage(key:String):Void
	{
		workQueue.push(function() {
			Paths.image(key);
		});
		workLabels.push('image / ' + key);
	}

	function queueAtlas(key:String):Void
	{
		workQueue.push(function() {
			Paths.getSparrowAtlas(key);
		});
		workLabels.push('atlas / ' + key);
	}

	function queueMusic(key:String):Void
	{
		workQueue.push(function() {
			Paths.music(key);
		});
		workLabels.push('music / ' + key);
	}

	function queueSound(key:String):Void
	{
		workQueue.push(function() {
			Paths.sound(key);
			Paths.excludeAsset('assets/sounds/' + key + '.' + Paths.SOUND_EXT);
		});
		workLabels.push('sound / ' + key);
	}

	/** Runs one queued item per frame, once the splash is over. */
	function processWork():Void
	{
		if (!workActive)
			return;

		// The splash never shares its frames with decoding.
		//
		// This is the whole difference between an intro and a slideshow: a single atlas
		// decode can cost 100-300 ms, and landing that on the frame where the mark ignites
		// makes the arrival look broken no matter how good the easing is. The work is still
		// honest and still one item per frame, it simply starts after the intro instead of
		// underneath it — the bar is already on screen by then, and a hitch behind a filled
		// bar reads as "loading", which is what it is.
		if (phase == PHASE_SPLASH)
			return;

		// One clean frame after an expensive item: stalls that stack on stalls are what turn
		// an uneven boot into a frozen one.
		if (workCooldown > 0)
		{
			workCooldown--;
			return;
		}

		if (workIndex >= workQueue.length)
		{
			if (!workFinished)
			{
				workFinished = true;
				bar.setDetail('');
				TraceManager.info('trace.boot.preloaded', 'Precache finished ({} items)', [workQueue.length]);
			}
			// Idempotent: while the splash is still on stage this returns early and is
			// retried every frame. The queue usually drains BEFORE the splash ends (a warm
			// cache finishes in a few frames), so the finish MUST also fire on the
			// SPLASH→LOADING transition — a once-only guard here stranded the boot at 100%.
			onWorkFinished();
			return;
		}

		if (workIndex < workLabels.length)
			bar.setDetail(workLabels[workIndex]);

		var job:Void->Void = workQueue[workIndex];
		workIndex++;
		var jobStart:Float = haxe.Timer.stamp();
		try
		{
			job();
		}
		catch (e:Dynamic)
		{
			// A missing item must never stop the boot; Paths already logged the key.
			TraceManager.warn('trace.boot.preloadFailed', 'Precache item failed: {}', [e]);
		}

		if (haxe.Timer.stamp() - jobStart > 0.040)
			workCooldown = 1;

		// The item just loaded is complete (atlas crop/repack/palette included), so
		// this is the first safe point to settle it: palette decision, GPU upload and
		// CPU release happen now, while the loading screen owns the frame. Without
		// this, every preloaded graphic stays CPU-resident until it is first drawn
		// on the title/menu, and the heap visibly drains there instead.
		//
		// Android keeps the single end-of-boot commit below: per-asset uploads right
		// after decode are the shape that black-screened some Android drivers in the
		// old backend, while one batched commit at the loading screen's end is the
		// path the old preload warm-up used everywhere.
		#if !android
		backend.gfx.GfxMemory.commitPending('boot');
		#end

		var p:Float = workQueue.length > 0 ? workIndex / workQueue.length : 1;
		bar.setProgress(rangeStart + (rangeEnd - rangeStart) * p);
		bar.setTask(workIndex <= graphicsWorkCount
			? Language.get('BootState.task.graphics', 'Loading graphics…')
			: Language.get('BootState.task.audio', 'Caching sounds…'));
	}

	function onWorkFinished():Void
	{
		if (phase != PHASE_LOADING)
			return; // splash still on stage (or already finishing) — retried next frame
		enterFinish();
	}

	function enterFinish():Void
	{
		if (phase == PHASE_FINISH)
			return;
		phase = PHASE_FINISH;
		finishClock = 0;
		#if sys
		if (devStats) Sys.println('[boot] work finished at t=' + clock);
		#end
		// Safety net for graphics that were cached before the preload queue started
		// (or joined it after the last item). The loading screen still owns the frame.
		backend.gfx.GfxMemory.commitAll('boot-finish');
		bar.setTask(Language.get('BootState.task.ready', 'Ready'));
		bar.pulse();

		// Start the menu music now so it fades in under the flourish and keeps playing
		// straight through the title screen. TitleState.startIntro only starts music when
		// none is playing, so this hands over seamlessly; web stays with the old flow
		// because browsers would block the sound before the first gesture anyway.
		try
		{
			#if !web
			if (FlxG.sound.music == null)
			{
				FlxG.sound.playMusic(Paths.music('freakyMenu'), 0);
				FlxG.sound.music.fadeIn(2, 0, 0.7);
			}
			#end
			FlxG.sound.play(Paths.sound('confirmMenu'), 0.5);
		}
		catch (e:Dynamic)
		{
			// Audio trouble must never block the hand-over.
			TraceManager.warn('trace.boot.finishAudioFailed', '{}', [e]);
		}
	}

	// ════════════════════════════════════════════════════════════ Hand-over

	/**
	 * Leave through plain flixel rather than MusicBeatState.switchState: the boot path must
	 * not create a CustomFadeTransition substate (see CopyState.handOver for the full
	 * machinery reasons). Shared with CopyState, which reaches it through inheritance.
	 */
	public function handOver():Void
	{
		stopJingle();
		FlxG.fixedTimestep = cachedTimestep;

		// Give the menu its watermark back (it obeys the player's setting, not ours).
		if (watermarkHidden) backend.Watermark.setVisible(true);

		#if sys
		if (devStats) Sys.println('[boot] hand over at t=' + clock);
		#end

		FlxTransitionableState.skipNextTransIn = true;
		FlxTransitionableState.skipNextTransOut = true;

		// Dev-only chart-load probe (see ChartLoadProbe): when SEIUN_CHART_PROBE is set, boot
		// straight into a PlayState for that chart instead of the title screen.
		if (ChartLoadProbe.tryAutoStart()) return;

		if (TestBuildNoticeState.shouldShow())
		{
			FlxG.switchState(new TestBuildNoticeState());
			return;
		}

		var next:FlxState = new TitleState();
		#if MODS_ALLOWED
		next = states.ModState.resolveState(next);
		#end
		FlxG.switchState(next);
	}

	// ════════════════════════════════════════════════════════════════ Helpers

	/** Centres a sprite on a point, honouring its current scale. */
	static function centerOn(sprite:FlxSprite, x:Float, y:Float):Void
	{
		sprite.x = x - sprite.width * sprite.scale.x / 2;
		sprite.y = y - sprite.height * sprite.scale.y / 2;
	}

	static function clamp01(x:Float):Float
	{
		return x < 0 ? 0 : (x > 1 ? 1 : x);
	}

	static function easeOutQuint(x:Float):Float
	{
		return 1 - Math.pow(1 - x, 5);
	}

	static function easeInOutCubic(x:Float):Float
	{
		return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
	}

	static function easeOutQuad(x:Float):Float
	{
		return 1 - (1 - x) * (1 - x);
	}

	static function easeInQuad(x:Float):Float
	{
		return x * x;
	}

	/**
	 * Long IO stalls and the very first frame can hand us absurd dt; clamping keeps the
	 * accumulated clock (web, and the tail after the jingle ends) from jumping or going
	 * invalid — an NaN clock once froze the choreography at its first frame forever.
	 */
	static inline function sanitizeElapsed(elapsed:Float):Float
	{
		if (!(elapsed > 0) || elapsed > 0.1)
			return 1 / 60;
		return elapsed;
	}
}
