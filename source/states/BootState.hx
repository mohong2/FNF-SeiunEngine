package states;

import flash.display.BitmapData;
import flash.display.GradientType;
import flash.display.Shape;
import flash.geom.Matrix;
import flash.geom.Point;
import flash.geom.Rectangle;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.FlxState;
import flixel.addons.transition.FlxTransitionableState;
import flixel.graphics.FlxGraphic;
import flixel.input.gamepad.FlxGamepadInputID;
import flixel.math.FlxMath;
import flixel.system.FlxAssets;
import flixel.system.FlxAssets.GraphicLogo;
import flixel.system.FlxSound;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import backend.BootBar;
import mohong.TraceManager;

using StringTools;

/**
 * The single boot/loading state, shared by every platform.
 *
 * On desktop and web this IS the first state; on mobile `CopyState` extends it and adds
 * the asset-extraction pass on top, so a cold start shows exactly one loading screen
 * everywhere: pure black, the classic HaxeFlixel logo (flixel's own embedded `GraphicLogo`
 * artwork, untouched) whose four quadrants fly in from beyond the screen edges — launched
 * on the jingle's first four notes and snapping into formation together on its resolving
 * fifth note — then settle up above the SEIUN ENGINE wordmark, with a violet→cyan progress
 * bar at the bottom driven by REAL work.
 *
 * That real work, per platform:
 *   - Android first boot: the CopyState extraction (native thread) maps onto [0, 0.8],
 *     then the shared precache onto [0.8, 1].
 *   - Desktop / web / up-to-date mobile: the shared precache over the full range —
 *     the title/menu chain graphics decoded into the bitmap cache and the menu music +
 *     navigation sounds warmed, one item per frame. Nothing is faked: the bar only ever
 *     shows work that has actually finished, and the boot lasts exactly as long as that
 *     work (plus the ≈2.5s splash the player chose).
 *
 * The splash is a parametric timeline (no tweens): every transform is a pure function of
 * the local clock, so skipping is simply "jump the clock" and a decode hitch can never
 * desync the choreography from the audio. Any input during the splash skips it; the
 * loading itself stays input-free, exactly like CopyState's extraction.
 *
 * Hand-over mirrors CopyState.handOver(): plain FlxG.switchState, no fade substate, into
 * TestBuildNoticeState on test builds or TitleState (mod state redirect included).
 */
class BootState extends MusicBeatState
{
	// ── Splash timeline, locked to the flixel jingle ──
	// The five timestamps are flixel's own FlxSplash piece timings — flixel's own sync
	// points for this exact jingle (a fast five-note riff). The four quadrants LAUNCH
	// from beyond the screen edges on notes 1-4 and snap into formation together on the
	// resolving fifth note, where the intact logo takes over with an impact punch.
	static var launchTimes:Array<Float> = [0.041, 0.184, 0.334, 0.495];
	static inline var LAND_TIME:Float = 0.636;
	static inline var PUNCH_TIME:Float = 0.25;
	static inline var SETTLE_START:Float = 1.45;
	static inline var SETTLE_TIME:Float = 0.65;
	static inline var SPLASH_END:Float = SETTLE_START + SETTLE_TIME; // 2.1

	/** Full spin per piece during the flight, alternating diagonal directions. */
	static var pieceSpin:Array<Float> = [-270, 270, 270, -270];

	/** How far beyond the screen edge each flying piece waits before its launch note. */
	static inline var OFFSCREEN:Float = 90;

	/** Window-activation clicks must not count as a skip (same lesson as TestBuildNoticeState). */
	static inline var SKIP_GRACE:Float = 0.25;
	/** How much of the bar the CopyState extraction pass may claim; precache gets the rest. */
	public static inline var EXTRACT_PORTION:Float = 0.8;

	static inline var PHASE_SPLASH:Int = 0;
	static inline var PHASE_LOADING:Int = 1;
	static inline var PHASE_FINISH:Int = 2;

	var phase:Int = PHASE_SPLASH;
	var clock:Float = 0;
	var finishClock:Float = 0;
	var handedOver:Bool = false;

	// ── Splash actors ──
	var quadrants:Array<FlxSprite> = [];
	/** Flight path per piece, in CENTRES: start sits beyond the screen edge. */
	var pieceStart:Array<Point> = [];
	/** Formation slot centre — this piece's quadrant of the assembled logo. */
	var pieceEnd:Array<Point> = [];
	var logo:FlxSprite;
	var glow:FlxSprite;
	var wordmark:FlxText;
	var accentLine:FlxSprite;
	// Public for CopyState, which drives these during its extraction pass.
	public var bar:BootBar;
	var fade:FlxSprite;
	var jingle:FlxSound;

	// ── Geometry (computed once) ──
	var logoScaleAssembled:Float;
	var logoScaleRest:Float;
	var assemblyCX:Float;
	var assemblyCY:Float;
	var restCX:Float;
	var restCY:Float;
	var wordmarkRestY:Float;

	// ── Real work queue ──
	var workQueue:Array<Void->Void> = [];
	var workIndex:Int = 0;
	var graphicsWorkCount:Int = 0;
	/** Only true once beginPrecache() ran — keeps the queue idle during CopyState extraction. */
	var workActive:Bool = false;
	var workFinished:Bool = false;
	// CopyState maps its extraction onto a sub-range of the bar before precaching.
	public var rangeStart:Float = 0;
	public var rangeEnd:Float = 1;

	var cachedTimestep:Bool = false;

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

		// Fixed timestep off while the jingle and the corner choreography need to stay
		// locked together (same reasoning as flixel's own FlxSplash).
		cachedTimestep = FlxG.fixedTimestep;
		FlxG.fixedTimestep = false;

		FlxTransitionableState.skipNextTransIn = true;
		FlxTransitionableState.skipNextTransOut = true;

		super.create();

		FlxG.cameras.bgColor = FlxColor.BLACK;
		FlxG.mouse.visible = false; // TestBuildNoticeState turns the cursor back on.

		buildBootScene();
		startJingle();
		startBootFlow();

		TraceManager.info('trace.boot.start', 'Boot screen up (platform splash + real preload)');
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
		// The choreography clock follows the jingle's playhead while it plays, so decode
		// hitches can never desync the flight from the notes; otherwise it accumulates
		// clamped frame time. Any input skips the SPLASH only — loading stays input-free.
		if (phase == PHASE_SPLASH)
		{
			#if (FLX_SOUND_SYSTEM && !web)
			if (jingle != null && jingle.playing)
				clock = jingle.time / 1000;
			else
				clock += sanitizeElapsed(elapsed);
			#else
			clock += sanitizeElapsed(elapsed);
			#end

			if (clock > SKIP_GRACE && anyInputPressed())
				skipSplash();
		}
		else
		{
			clock += sanitizeElapsed(elapsed);
		}

		switch (phase)
		{
			case PHASE_SPLASH:
				applySplash(clock);
				if (clock >= SPLASH_END)
					phase = PHASE_LOADING;
				processWork();
			case PHASE_LOADING:
				applyIdle();
				processWork();
			case PHASE_FINISH:
				applyIdle();
				finishClock += elapsed;
				fade.alpha = easeInQuad(Math.min(1, finishClock / 0.45));
				if (finishClock >= 0.5 && !handedOver)
				{
					handedOver = true;
					handOver();
				}
		}

		super.update(elapsed);
	}

	override public function destroy():Void
	{
		FlxG.fixedTimestep = cachedTimestep;
		super.destroy();
	}

	// ──────────────────────────────────────────────────────────── Scene

	function buildBootScene():Void
	{
		var logoBD:BitmapData = resolveClassicLogoBitmap();

		// Assembled size ≈22% of the screen height, resting (post-settle) ≈62% of that.
		logoScaleAssembled = FlxG.height * 0.22 / 100;
		logoScaleRest = logoScaleAssembled * 0.62;
		assemblyCX = FlxG.width / 2;
		assemblyCY = FlxG.height * 0.42;
		restCX = FlxG.width / 2;
		restCY = FlxG.height * 0.24;

		// Soft white halo behind the mark — generated, so the classic artwork stays untouched.
		glow = new FlxSprite(0, 0, glowBitmap(256));
		glow.blend = openfl.display.BlendMode.SCREEN;
		glow.visible = false;
		add(glow);

		// Slice the authentic logo into four quadrants. The artwork's baked-in black
		// background makes each flying piece melt into the boot screen; the intact logo
		// takes over the instant the pieces land, so the resting state is pixel-perfect.
		var half:Int = 50;
		for (i in 0...4)
		{
			var qx:Int = i % 2;
			var qy:Int = Std.int(i / 2);

			var pieceBD = new BitmapData(half, half, true, 0x00000000);
			pieceBD.copyPixels(logoBD, new Rectangle(qx * half, qy * half, half, half), new Point(0, 0));

			var piece = new FlxSprite(0, 0, pieceBD);
			piece.antialiasing = ClientPrefs.data.globalAntialiasing;
			piece.origin.set(half / 2, half / 2);
			piece.visible = false; // applySplash flies it in from beyond the screen edge
			quadrants.push(piece);
			add(piece);

			// All path points are CENTRES: flixel sprites pivot on their centre and that
			// pivot lands exactly at (x + origin) independent of scale, so flying the
			// centre is the whole story — no per-scale offset maths in the flight.
			pieceStart.push(new Point(
				qx == 0 ? -OFFSCREEN : FlxG.width + OFFSCREEN,
				qy == 0 ? -OFFSCREEN : FlxG.height + OFFSCREEN));
			pieceEnd.push(new Point(
				assemblyCX + (qx * 50 - 25) * logoScaleAssembled,
				assemblyCY + (qy * 50 - 25) * logoScaleAssembled));
		}

		logo = new FlxSprite(0, 0, logoBD);
		logo.antialiasing = ClientPrefs.data.globalAntialiasing;
		logo.origin.set(50, 50);
		logo.visible = false;
		add(logo);

		wordmark = new FlxText(0, 0, FlxG.width, 'SEIUN ENGINE', 30);
		wordmark.setFormat(Paths.font('montserrat.ttf'), 30, 0xFFE8E8F2, CENTER);
		wordmark.alpha = 0;
		wordmarkRestY = restCY + 50 * logoScaleRest + 24;
		wordmark.visible = false;
		add(wordmark);

		accentLine = new FlxSprite(0, 0, gradientRoundedRectBitmap(120, 2, 1, BootBar.ACCENT_LEFT, BootBar.ACCENT_RIGHT));
		accentLine.visible = false;
		add(accentLine);

		var barWidth:Float = Math.min(FlxG.width * 0.42, 560);
		bar = new BootBar(barWidth);
		add(bar);
		bar.setTask(Language.get('BootState.task.prepare', 'Preparing…'));
		bar.appear(0);

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
		jingle = FlxG.sound.load(FlxAssets.getSound("flixel/sounds/flixel"));
		if (jingle != null)
			jingle.play();
		#end
	}

	// ─────────────────────────────────────────────────── Splash timeline

	function applySplash(t:Float):Void
	{
		// Four pieces fly in from beyond the screen edges — launched on the jingle's first
		// four notes, all snapping into formation together on its resolving fifth note.
		for (i in 0...quadrants.length)
		{
			var piece = quadrants[i];
			var p:Float = (t - launchTimes[i]) / (LAND_TIME - launchTimes[i]);

			if (p >= 1)
			{
				piece.visible = false; // landed — the intact logo takes over below
				continue;
			}

			piece.visible = true;
			var flightP:Float = easeOutQuint(clamp01(p));

			piece.x = FlxMath.lerp(pieceStart[i].x, pieceEnd[i].x, flightP) - 25;
			piece.y = FlxMath.lerp(pieceStart[i].y, pieceEnd[i].y, flightP) - 25;
			piece.angle = pieceSpin[i] * (1 - flightP);
			var scale:Float = logoScaleAssembled * FlxMath.lerp(1.5, 1.0, flightP);
			piece.scale.set(scale, scale);
		}

		if (t < LAND_TIME)
			return;

		// The pieces have landed on the final note: the intact logo takes over and punches
		// once on impact, then the whole mark settles up and out of the way of the wordmark.
		logo.visible = true;
		glow.visible = true;

		var punchP:Float = clamp01((t - LAND_TIME) / PUNCH_TIME);
		var settleP:Float = easeInOutCubic(clamp01((t - SETTLE_START) / SETTLE_TIME));

		var scale:Float = logoScaleAssembled * (1 + 0.09 * (1 - easeOutQuad(punchP))) * (1 - 0.38 * settleP);
		var cx:Float = FlxMath.lerp(assemblyCX, restCX, settleP);
		var cy:Float = FlxMath.lerp(assemblyCY, restCY, settleP);

		// x/y pin the centre pivot, so the mark stays centred no matter how the punch
		// and settle animates the scale.
		logo.scale.set(scale, scale);
		logo.x = cx - 50;
		logo.y = cy - 50;

		var glowScale:Float = (100 * scale * 2.3) / 256;
		glow.scale.set(glowScale, glowScale);
		glow.x = cx - 128;
		glow.y = cy - 128;
		glow.alpha = (0.14 + 0.12 * easeOutQuad(clamp01((t - LAND_TIME) / 0.5))) * (1 - 0.25 * settleP);

		wordmark.visible = settleP > 0;
		wordmark.alpha = settleP;
		wordmark.y = wordmarkRestY + 16 * (1 - settleP);

		accentLine.visible = settleP > 0;
		accentLine.alpha = settleP * 0.9;
		accentLine.x = (FlxG.width - accentLine.width) / 2;
		accentLine.y = wordmark.y + wordmark.height + 10;

		bar.appear(settleP);
	}

	// ─────────────────────────────────────────────────────────────────── Idle

	/** Resting transforms plus the slow breathing pulse, used once the splash is over. */
	function applyIdle():Void
	{
		// Input can skip the splash mid-flight: make sure no quadrant is left on screen.
		for (piece in quadrants)
			piece.visible = false;

		var breathe:Float = Math.sin(clock * 2.0);

		var scale:Float = logoScaleRest * (1 + 0.012 * breathe);
		logo.visible = true;
		logo.scale.set(scale, scale);
		logo.x = restCX - 50;
		logo.y = restCY - 50;

		var glowScale:Float = (100 * scale * 2.3) / 256;
		glow.visible = true;
		glow.scale.set(glowScale, glowScale);
		glow.x = restCX - 128;
		glow.y = restCY - 128;
		glow.alpha = 0.18 + 0.05 * breathe;

		wordmark.visible = true;
		wordmark.alpha = 1;
		wordmark.y = wordmarkRestY;

		accentLine.visible = true;
		accentLine.alpha = 0.9;
		accentLine.x = (FlxG.width - accentLine.width) / 2;
		accentLine.y = wordmark.y + wordmark.height + 10;

		bar.appear(1);
	}

	function skipSplash():Void
	{
		TraceManager.info('trace.boot.skip', 'Splash skipped by input');
		stopJingle();
		clock = SPLASH_END;
		phase = PHASE_LOADING;
		applyIdle();
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

	// ──────────────────────────────────────────────────── Real work

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
	}

	function queueAtlas(key:String):Void
	{
		workQueue.push(function() {
			Paths.getSparrowAtlas(key);
		});
	}

	function queueMusic(key:String):Void
	{
		workQueue.push(function() {
			Paths.music(key);
		});
	}

	function queueSound(key:String):Void
	{
		workQueue.push(function() {
			Paths.sound(key);
			Paths.excludeAsset('assets/sounds/' + key + '.' + Paths.SOUND_EXT);
		});
	}

	/** Runs one queued item per frame while the splash/loading plays. */
	function processWork():Void
	{
		if (!workActive)
			return;

		if (workIndex >= workQueue.length)
		{
			if (!workFinished)
			{
				workFinished = true;
				TraceManager.info('trace.boot.preloaded', 'Precache finished ({} items)', [workQueue.length]);
			}
			// Idempotent: while the splash is still on stage this returns early and is
			// retried every frame. The queue usually drains BEFORE the splash ends (a warm
			// cache finishes in a few frames), so the finish MUST also fire on the
			// SPLASH→LOADING transition — a once-only guard here stranded the boot at 100%.
			onWorkFinished();
			return;
		}

		var job:Void->Void = workQueue[workIndex];
		workIndex++;
		try
		{
			job();
		}
		catch (e:Dynamic)
		{
			// A missing item must never stop the boot; Paths already logged the key.
			TraceManager.warn('trace.boot.preloadFailed', 'Precache item failed: {}', [e]);
		}

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
		bar.setTask(Language.get('BootState.task.ready', 'Ready'));

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

	// ─────────────────────────────────────────────────────── Hand-over

	/**
	 * Leave through plain flixel rather than MusicBeatState.switchState: the boot path must
	 * not create a CustomFadeTransition substate (see CopyState.handOver for the full
	 * machinery reasons). Shared with CopyState, which reaches it through inheritance.
	 */
	public function handOver():Void
	{
		stopJingle();
		FlxG.fixedTimestep = cachedTimestep;

		FlxTransitionableState.skipNextTransIn = true;
		FlxTransitionableState.skipNextTransOut = true;

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

	// ─────────────────────────────────────────────────────────── Helpers

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

	/**
	 * The classic flixel artwork for the boot mark. Primary source is flixel's own
	 * embedded GraphicLogo through FlxGraphic.fromClass — flixel's proven path for
	 * @:bitmap classes on cpp (the virtual pad loads its graphics the same way; a raw
	 * Type.createInstance decoded to a blank bitmap on the player's desktop build). If
	 * the embedded decode ever comes back empty, fall back to flixel's vector drawLogo
	 * so the boot can never run without the mark. Traced either way, so a silent
	 * fallback is visible in the log.
	 */
	static function resolveClassicLogoBitmap():BitmapData
	{
		var bd:BitmapData = null;
		try
		{
			var graphic:FlxGraphic = FlxGraphic.fromClass(GraphicLogo);
			if (graphic != null)
				bd = graphic.bitmap;
		}
		catch (e:Dynamic) {}

		if (hasClassicLogoPixels(bd))
		{
			TraceManager.info('trace.boot.logoSource', 'Boot logo: embedded GraphicLogo artwork');
			return bd;
		}

		TraceManager.warn('trace.boot.logoFallback', 'Embedded flixel logo decoded empty; using the vector drawLogo fallback');
		return vectorLogoBitmap();
	}

	/** The artwork's centre is the green diamond — an all-black decode means it failed. */
	static function hasClassicLogoPixels(bd:BitmapData):Bool
	{
		if (bd == null || bd.width < 100 || bd.height < 100)
			return false;
		return bd.getPixel(50, 50) != 0x000000;
	}

	/** flixel's own vector logo (the same classic mark) rendered into a bitmap. */
	static function vectorLogoBitmap():BitmapData
	{
		var bd = new BitmapData(100, 100, true, 0x00000000);
		var shape = new Shape();
		FlxAssets.drawLogo(shape.graphics);
		bd.draw(shape);
		return bd;
	}

	static function glowBitmap(size:Int):BitmapData
	{
		var shape = new Shape();
		var matrix = new Matrix();
		matrix.createGradientBox(size, size, 0, 0, 0);
		shape.graphics.beginGradientFill(GradientType.RADIAL, [0xFFFFFF, 0xFFFFFF], [0.55, 0.0], [0, 255], matrix);
		shape.graphics.drawCircle(size / 2, size / 2, size / 2);
		shape.graphics.endFill();
		var bd = new BitmapData(size, size, true, 0x00000000);
		bd.draw(shape);
		return bd;
	}

	static function gradientRoundedRectBitmap(width:Int, height:Int, radius:Int, left:FlxColor, right:FlxColor):BitmapData
	{
		var shape = new Shape();
		var matrix = new Matrix();
		matrix.createGradientBox(width, height, 0, 0, 0);
		shape.graphics.beginGradientFill(GradientType.LINEAR, [left, right], [1, 1], [0, 255], matrix);
		shape.graphics.drawRoundRect(0, 0, width, height, radius * 2, radius * 2);
		shape.graphics.endFill();
		var bd = new BitmapData(width, height, true, 0x00000000);
		bd.draw(shape);
		return bd;
	}
}
