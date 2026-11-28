package options;

import ClientPrefs;
import Language;
import backend.RendererChoice;
import flixel.graphics.FlxGraphic;
import flixel.text.FlxText;
import flixel.text.FlxText.FlxTextAlign;
import flixel.text.FlxText.FlxTextBorderStyle;

using StringTools;

/**
 * Full-page renderer picker, shown while the "Renderer" row of the Graphics page is
 * selected.
 *
 * `OptionsState` pulls every other row out of the way and slides the row itself into the
 * top-left corner; this group fills the space that is left with the two renderer marks, a
 * brand-tinted halo behind the current one, and the notice line that says what this
 * session really draws with.
 *
 * Every frame is driven by a single `reveal` value that is lerped towards 0 or 1, so opening
 * and closing never allocate a tween and can never fight one: the sprites just chase whatever
 * the current state implies. That is the same exponential lerp the menu rows use
 * (`FlxTextMenuItem`), which keeps the motion identical to the rest of the settings screen.
 *
 * The four PNGs in images/options/renderers are baked at their exact display size, so no
 * texture is ever rescaled: at the native 1280x720 the marks stay pixel sharp, and only
 * `alpha` is animated.
 *
 * Marks: the OpenGL and Vulkan wordmarks come from Wikimedia Commons,
 *   https://commons.wikimedia.org/wiki/File:OpenGL_logo.svg
 *   https://commons.wikimedia.org/wiki/File:Vulkan_logo.svg
 * both public domain (the trademarks themselves belong to the Khronos Group). They are
 * redistributed here as white alpha masks, used only on this settings page.
 *
 * 0.2.2 does not build this picker: backend.RendererChoice.IN_GAME_PICKER is false, so
 * the Renderer row is never added and this class is never instantiated by the menu. It
 * stays in the tree for the version that reopens the picker.
 */
class RendererShowcase extends FlxTypedGroup<FlxSprite>
{
	/** Brand accent per slot, index-aligned with the option's `options` array. */
	static final ACCENTS:Array<Int> = [0xFF6FB6E8, 0xFFE8455C];

	/** Tint the marks fall back to while their card is not the current choice. */
	static final IDLE_TINT:Int = 0xFF7C8798;
	static final IDLE_CARD_ALPHA:Float = 0.45;
	static final IDLE_MARK_ALPHA:Float = 0.85;
	static final IDLE_CAPTION_ALPHA:Float = 0.55;

	static final CARD_W:Int = 460;
	static final CARD_H:Int = 300;
	static final GAP:Int = 100;
	static final TOP:Float = 170;
	/** Mark centre, measured from the top of its card. */
	static final MARK_Y:Float = 132;
	/** Caption top, measured from the top of its card. */
	static final CAPTION_Y:Float = 244;
	static final BAR_Y:Float = 488;
	static final BAR_W:Int = 340;
	static final BAR_H:Int = 6;
	static final HINT_Y:Float = 524;
	static final NOTICE_Y:Float = 574;

	/** Enter/leave rise in pixels, and how snappy the reveal lerp is. */
	static final RISE:Float = 34;
	static final REVEAL_SPEED:Float = 10;
	/** How far the second card lags behind the first, as a fraction of the reveal. */
	static final STAGGER:Float = 0.14;

	/** Colour of the "not live yet" notice, before a change flashes it white. */
	static final NOTICE_AMBER:Int = 0xFFFFC45A;

	/** Breathing range of the halo behind the selected card. */
	static final GLOW_MIN:Float = 0.20;
	static final GLOW_MAX:Float = 0.38;

	/** Built for exactly two renderers: OpenGL keeps slot 0, Vulkan slot 1. */
	static final SLOTS:Int = 2;

	var cards:Array<FlxSprite> = [];
	var halos:Array<FlxSprite> = [];
	var marks:Array<FlxSprite> = [];
	var captions:Array<FlxText> = [];
	/** Per-slot halo strength, lerped so a halo fades out instead of snapping off. */
	var haloLevel:Array<Float> = [];

	var bar:FlxSprite;
	var hint:FlxText;
	var notice:FlxText;

	/** 0 = fully hidden, 1 = fully on screen; every sprite is placed from this. */
	var reveal:Float = 0;
	/** Seconds since the picker opened, used for the halo breathing. */
	var clock:Float = 0;
	/** 1 right after the choice changes, decays to 0: flashes the notice. */
	var noticeFlash:Float = 0;
	/** 1 right after a card was refused, decays to 0: lights it without picking it. */
	var denyFlash:Float = 0;
	var denySlot:Int = -1;

	/** Slot currently picked (0 = OpenGL, 1 = Vulkan). */
	public var selected(default, null):Int = 0;
	/** True from enter() until leave() has faded the picker out. */
	public var opened(default, null):Bool = false;

	public function new(labels:Array<String>)
	{
		super();
		// Never drawn until the row is selected; this also gates the whole group's draw.
		visible = false;
		build(labels);
	}

	// ═══════════════════════════════════════════════════════════════════════════
	//  Build
	// ═══════════════════════════════════════════════════════════════════════════

	/**
	 * Left edge of a card. The pair is centred on whatever the game's native width is, so the
	 * picker stays centred on a non-1280 layout instead of hanging off one side.
	 */
	static function slotLeft(index:Int):Float
	{
		var total:Float = SLOTS * CARD_W + (SLOTS - 1) * GAP;
		return (FlxG.width - total) * 0.5 + index * (CARD_W + GAP);
	}

	function build(labels:Array<String>):Void
	{
		var cardGraphic:FlxGraphic = Paths.image('options/renderers/card');
		var haloGraphic:FlxGraphic = Paths.image('options/renderers/glow');
		var markGraphics:Array<FlxGraphic> = [
			Paths.image('options/renderers/opengl'),
			Paths.image('options/renderers/vulkan'),
		];

		// Added in layers rather than per slot: a halo is wide enough to reach under its
		// neighbour, so every halo has to be behind every card.
		for (i in 0...SLOTS)
		{
			var centerX:Float = slotLeft(i) + CARD_W * 0.5;
			var halo = new FlxSprite(centerX - haloGraphic.width * 0.5, TOP + CARD_H * 0.5 - haloGraphic.height * 0.5,
				haloGraphic);
			halo.color = ACCENTS[i];
			halo.alpha = 0;
			halo.visible = false;
			add(halo);
			halos.push(halo);
			haloLevel.push(0);
		}

		for (i in 0...SLOTS)
		{
			var card = new FlxSprite(slotLeft(i), TOP, cardGraphic);
			card.alpha = 0;
			add(card);
			cards.push(card);
		}

		for (i in 0...SLOTS)
		{
			var graphic:FlxGraphic = markGraphics[i];
			var centerX:Float = slotLeft(i) + CARD_W * 0.5;
			var mark = new FlxSprite(centerX - graphic.width * 0.5, TOP + MARK_Y - graphic.height * 0.5, graphic);
			mark.alpha = 0;
			add(mark);
			marks.push(mark);
		}

		for (i in 0...SLOTS)
		{
			var label:String = (labels != null && i < labels.length) ? labels[i] : '';
			var caption = new FlxText(slotLeft(i), TOP + CAPTION_Y, CARD_W, label, 32);
			caption.setFormat(Paths.languageFont(), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE_FAST,
				FlxColor.BLACK);
			caption.borderSize = 3;
			caption.alpha = 0;
			add(caption);
			captions.push(caption);
		}

		// White graphic: the bar is tinted through sprite.color each frame, and color
		// multiplies the texture, so baking the brand colour in would tint it twice.
		bar = new FlxSprite(slotLeft(0) + (CARD_W - BAR_W) * 0.5, BAR_Y).makeGraphic(BAR_W, BAR_H, FlxColor.WHITE);
		bar.color = ACCENTS[0];
		bar.alpha = 0;
		add(bar);

		hint = new FlxText(0, HINT_Y, FlxG.width,
			Language.get('option.renderer.hint', 'Press Left / Right to look at the renderers'), 26);
		hint.setFormat(Paths.optionsfont(), 26, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
		hint.borderSize = 2.4;
		hint.alpha = 0;
		add(hint);

		notice = new FlxText(0, NOTICE_Y, FlxG.width, noticeFor(), 26);
		// White here as well: the amber (and the white flash on a change) comes from
		// sprite.color in update(), which multiplies the rasterized text.
		notice.setFormat(Paths.optionsfont(), 26, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
		notice.color = NOTICE_AMBER;
		notice.borderSize = 2.4;
		notice.alpha = 0;
		// The line explains state now instead of promising a future switch, and the English
		// sentences are long enough to need a second line on a 1280-wide layout.
		notice.wordWrap = true;
		add(notice);
	}

	// ═══════════════════════════════════════════════════════════════════════════
	//  Notice line
	// ═══════════════════════════════════════════════════════════════════════════

	/**
	 * What the line under the cards says right now.
	 *
	 * The row is the only place that can explain the difference between a choice that is
	 * *saved* and a backend that is *running*: the picker shows the saved one, the notice
	 * says which one is drawing this frame, and whether the last launch had to fall back.
	 */
	public function noticeFor():String
	{
		if (!RendererChoice.available())
			return Language.get('option.renderer.notice.unavailable',
				'This build has no Vulkan backend, so OpenGL is the only renderer here.');

		var savedVulkan:Bool = (ClientPrefs.data != null && ClientPrefs.data.renderer == RendererChoice.VULKAN);

		if (RendererChoice.recoveredFromCrash)
		{
			// No reason to show: a launch that dies cannot report one. The log keeps the
			// marker file it left behind (logs/vulkan-last-failure.txt).
			return Language.get('option.renderer.notice.recovered',
				'The last launch stopped while Vulkan was starting, so OpenGL is back and the saved choice was reset to it.');
		}

		if (RendererChoice.fellBackThisBoot && RendererChoice.failureReason != null)
		{
			return StringTools.replace(Language.get('option.renderer.notice.fallback',
				'The last Vulkan launch did not work out, so this session is on OpenGL. Reason: %s'),
				'%s', shortReason(RendererChoice.failureReason));
		}

		if (RendererChoice.active)
		{
			return savedVulkan
				? Language.get('option.renderer.notice.vulkanActive', 'This session is drawing through Vulkan.')
				: Language.get('option.renderer.notice.vulkanRunning',
					'Vulkan is drawing this session. OpenGL is the saved choice and takes over on the next launch.');
		}

		if (savedVulkan)
		{
			return Language.get('option.renderer.notice.vulkanPending',
				'Vulkan is saved and is tried on the next launch. If it cannot start, the engine goes back to OpenGL by itself.');
		}

		return Language.get('option.renderer.notice.opengl',
			'This session is drawing through OpenGL. Vulkan is still experimental - the switch asks first and falls back on its own.');
	}

	/**
	 * Re-reads the notice line after the saved choice changed.
	 *
	 * The text is re-rasterized only when it actually differs: assigning the same string to
	 * a FlxText still pays for a full text field rebuild.
	 */
	public function refreshNotice():Void
	{
		if (notice == null) return;

		var text:String = noticeFor();
		if (notice.text != text) notice.text = text;
	}

	/**
	 * Puts a one-off reason in the notice line - a refused card, for instance - and leaves
	 * it there until the line is refreshed, which the caller does once the reason no longer
	 * applies.
	 */
	public function showReason(text:String):Void
	{
		if (notice == null || text == null) return;
		if (notice.text != text) notice.text = text;
		flashNotice();
	}

	/** Fits a runtime message into the notice line; the log keeps the whole thing. */
	static function shortReason(reason:String):String
	{
		var text:String = reason.split('\n')[0].trim();
		if (text.length > 150) text = text.substr(0, 147) + '...';
		return text;
	}

	// ═══════════════════════════════════════════════════════════════════════════
	//  State
	// ═══════════════════════════════════════════════════════════════════════════

	/** Starts the fade/slide in. Safe to call again after leave(). */
	public function enter(index:Int):Void
	{
		opened = true;
		reveal = 0;
		clock = 0;
		noticeFlash = 0;
		denyFlash = 0;
		denySlot = -1;
		selected = clampSlot(index);
		for (i in 0...SLOTS)
			haloLevel[i] = 0;
		visible = true;
	}

	/** Fades the picker out; the sprites hide themselves once the reveal reaches 0. */
	public function leave():Void
	{
		opened = false;
	}

	/** Picks a slot without flashing the notice (that is the caller's call). */
	public function select(index:Int):Void
	{
		selected = clampSlot(index);
	}

	/** Highlights the notice: called when the player actually changes the value. */
	public function flashNotice():Void
	{
		noticeFlash = 1;
	}

	/**
	 * Refuses a slot: the card lights up in its own brand colours for a moment - so the player
	 * does get to see what the choice will look like - while the notice flashes to say why it
	 * cannot be taken. Nothing is selected by this.
	 *
	 * @param reason shown in the notice line; the caller passes the localized sentence, so the
	 *               picker itself never has to know why a platform or a build cannot honour a card
	 */
	public function deny(index:Int, ?reason:String):Void
	{
		denySlot = clampSlot(index);
		denyFlash = 1;

		if (reason != null) showReason(reason);
		else flashNotice();
	}

	/**
	 * Slot under the pointer, or -1. Lets a click/touch on a card do exactly what pressing
	 * Left/Right onto it does.
	 */
	public function hoveredCard(camera:FlxCamera):Int
	{
		for (i in 0...SLOTS)
			if (FlxG.mouse.overlaps(cards[i], camera))
				return i;
		return -1;
	}

	/** Drops the picker without the fade, for page changes and teardown. */
	public function hideNow():Void
	{
		opened = false;
		reveal = 0;
		visible = false;
		for (i in 0...SLOTS)
		{
			haloLevel[i] = 0;
			halos[i].visible = false;
		}
	}

	static inline function clampSlot(index:Int):Int
	{
		if (index < 0) return 0;
		if (index > SLOTS - 1) return SLOTS - 1;
		return index;
	}

	// ═══════════════════════════════════════════════════════════════════════════
	//  Frame
	// ═══════════════════════════════════════════════════════════════════════════

	override function update(elapsed:Float):Void
	{
		var k:Float = 1 - Math.exp(-elapsed * REVEAL_SPEED);

		var goal:Float = opened ? 1 : 0;
		reveal = FlxMath.lerp(reveal, goal, k);
		if (Math.abs(reveal - goal) < 0.002)
			reveal = goal;

		// Fully closed: stop drawing and stop paying for the per-sprite maths, but keep
		// updating so a later enter() picks straight back up.
		if (!opened && reveal <= 0)
		{
			visible = false;
			super.update(elapsed);
			return;
		}
		visible = true;

		clock += elapsed;
		if (noticeFlash > 0)
			noticeFlash = Math.max(0, noticeFlash - elapsed * 1.8);
		if (denyFlash > 0)
			denyFlash = Math.max(0, denyFlash - elapsed * 2.2);

		var breathe:Float = 0.5 + 0.5 * Math.sin(clock * 2.4);

		for (i in 0...SLOTS)
		{
			// The second card starts once the reveal has passed STAGGER, which turns a single
			// driving value into a cascade without a timeline of its own.
			var local:Float = FlxMath.bound((reveal - i * STAGGER) / (1 - i * STAGGER), 0, 1);
			var current:Bool = (i == selected);
			// 1 for the picked card, and briefly for a card that was just refused: a locked
			// preview only earns its place if the player gets to see its colours.
			var lift:Float = current ? 1 : ((i == denySlot) ? denyFlash : 0);

			var card = cards[i];
			card.alpha = FlxMath.lerp(IDLE_CARD_ALPHA, 1, lift) * local;
			card.y = TOP + (1 - local) * RISE;

			var mark = marks[i];
			mark.alpha = FlxMath.lerp(IDLE_MARK_ALPHA, 1, lift) * local;
			mark.y = TOP + MARK_Y - mark.frameHeight * 0.5 + (1 - local) * RISE;
			mark.color = FlxColor.interpolate(mark.color, FlxColor.interpolate(IDLE_TINT, ACCENTS[i], lift), k);

			var caption = captions[i];
			caption.alpha = FlxMath.lerp(IDLE_CAPTION_ALPHA, 1, lift) * local;
			caption.y = TOP + CAPTION_Y + (1 - local) * RISE;

			// Halo: chases the breathing target while selected, a short pulse when refused, 0 otherwise.
			var target:Float = current ? (GLOW_MIN + (GLOW_MAX - GLOW_MIN) * breathe) : 0.26 * lift;
			haloLevel[i] = FlxMath.lerp(haloLevel[i], target, k);
			var halo = halos[i];
			halo.alpha = haloLevel[i] * local;
			halo.visible = halo.alpha > 0.002;
		}

		// Selector bar: slides across the gap and takes the accent of whatever it points at.
		bar.x = FlxMath.lerp(bar.x, slotLeft(selected) + (CARD_W - BAR_W) * 0.5, k);
		bar.color = FlxColor.interpolate(bar.color, ACCENTS[selected], k);
		bar.alpha = reveal;

		hint.y = HINT_Y + (1 - reveal) * 16;
		hint.alpha = reveal * 0.85;

		// The notice is the whole point of this row, so it never fully fades while the picker
		// is open; changing the value pushes it white for a moment instead of replacing it.
		notice.y = NOTICE_Y + (1 - reveal) * 16 - noticeFlash * 6;
		notice.alpha = reveal * (0.85 + 0.15 * noticeFlash);
		notice.color = FlxColor.interpolate(NOTICE_AMBER, FlxColor.WHITE, noticeFlash);

		super.update(elapsed);
	}
}
