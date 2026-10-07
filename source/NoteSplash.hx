package;

import flixel.FlxG;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.graphics.frames.FlxFrame;
import flixel.system.FlxAssets.FlxShader;
import haxe.Json;
import shaders.RGBPalette;
import backend.CompatEngine;
import Note.NoteSplashData;

using StringTools;

/** 1.0.4 JSON 溅射配置中的单个动画定义。 */
typedef NoteSplashAnimDef = {
	?name:String,
	?prefix:String,
	?noteData:Int,
	?offsets:Array<Float>,
	?fps:Array<Int>,
	?indices:Array<Int>
}

/**
 * 溅射图集配置 —— 0.7.3 txt 与 1.0.4 json 的公共子集
 * (allowRGB / allowPixel 已接入; 1.0.4 的 rgb 覆写表与 scale 仍未接入)。
 */
typedef NoteSplashConfig = {
	/** txt: 动画前缀, 如 "note splash"。 */
	?anim:String,
	?minFps:Int,
	?maxFps:Int,
	/** txt: 按 animID (direction + (animNum-1)*4) 排列的偏移。 */
	?offsets:Array<Array<Float>>,
	/** json: 动画名 → 定义。 */
	?anims:Map<String, NoteSplashAnimDef>,
	/**
	 * 1.0.4 json: 图集是否需要 RGB 染色。
	 * false = 图集自带颜色(不要染色); true = 白底图集, 按色板染色。
	 * 未声明 (null) 时沿用本引擎原有的路径判断 (noteSplashes/* = 白底现代材质),
	 * 所以既有模组的观感不变。
	 */
	?allowRGB:Null<Bool>,
	/** 1.0.4 json: 像素舞台是否按块取样 (false = 始终 1:1)。 */
	?allowPixel:Null<Bool>
}

/**
 * NoteSplash — 0.6.3 基础实现 + 0.7.3/1.0.4 完整兼容 (含 RGB 着色器染色)。
 *
 * 0.7.3 兼容:
 *  - 默认图集路径改为 `noteSplashes/noteSplashes`, 支持 `getSplashSkinPostfix()`
 *    (用户切换溅射皮肤时追加 `-diamond` 等后缀)。
 *  - 读取 images/<skin>.txt 配置 (动画前缀 / fps 区间 / 每动画偏移)。
 *  - 逐组探测动画是否存在 (addAnimAndCheck), maxAnims 按实际可用组数计算,
 *    兼容 "note splash blue 1" 与 "note splash blue 10000" 两种帧命名。
 *  - 坏动画超时强制回收 (buggedKillTime), 防止对象池/分组被卡死的溅射撑爆。
 *
 * 1.0.4 兼容:
 *  - 读取 images/<skin>.json 配置 (animations / offsets / fps)。
 *  - 白底溅射材质 (noteSplashes/*) 用 PixelSplashShaderRef 按 Note 轨道色板染色,
 *    与 0.7.3 一致; flat 图集继续走 ColorSwap (arrowHSV)。
 *  - 配置与图集在 PlayState.create 阶段预加载 (配合 alpha=0.000001 的预缓存技巧),
 *    避免第一次击键时才加载贴图/配置文件造成卡顿。
 *  - configs 静态缓存按谱面清理, 防止跨 mod 串配置。
 *
 * 0.6.3 模式保持原生行为 (flat noteSplashes 图集 + 无额外偏移)。
 *
 * noteSplashData / allowRGB:
 *  - `note.noteSplashData` (0.7.3/1.0.4) 见 Note.hx 的 NoteSplashData; 本类读取它的
 *    a / antialiasing / useRGBShader / useGlobalShader / r / g / b。
 *  - json 配置里的 allowRGB 显式决定"要不要染色"(false = 图集自带颜色), 未声明时
 *    沿用 noteSplashes/* 的路径判断; allowPixel 决定像素舞台的块取样。
 *  - 所有默认值都跟随本引擎的设置 (splashAlpha / globalAntialiasing / noteRGBMode /
 *    像素舞台), 所以不带这些字段的模组观感与改动前一致。
 */
class NoteSplash extends FlxSprite
{
	public var colorSwap:ColorSwap = null;
	/** 0.7.3/1.0.4 兼容: 白底溅射材质 (noteSplashes/*) 的 RGB 染色引用。 */
	public var rgbShader:PixelSplashShaderRef = null;
	private var textureLoaded:String = null;

	/** 该溅射实例存活时间 (秒), 用于坏动画超时回收。 */
	private var aliveTime:Float = 0;

	/** 当前图集可用的动画组数 (每组 4 个方向)。 */
	private var maxAnims:Int = 1;

	/** 多k: 溅射位置缩放 (noteScale, 与 strum/Note 同比例)。 */
	private var _posScale:Float = 1;
	/** 多k: 溅射尺寸缩放 (splashScales, 0.6.3 多k 的溅射大小设计)。 */
	private var _sizeScale:Float = 1;

	// ── 当前图集生效的配置 (来自 txt / json) ──
	private var _animPrefix:String = 'note splash';
	private var _minFps:Int = 22;
	private var _maxFps:Int = 26;
	private var _txtOffsets:Array<Array<Float>> = null;
	/** json 动画: slot (direction + (animNum-1)*4) → 前缀 / 偏移 / fps。 */
	private var _slotPrefix:Map<Int, String> = null;
	private var _slotOffsets:Map<Int, Array<Float>> = null;
	private var _slotFps:Map<Int, Array<Int>> = null;
	/** 当前图集配置声明的 allowRGB / allowPixel (null = 没声明)。 */
	private var _allowRGB:Null<Bool> = null;
	private var _allowPixel:Null<Bool> = null;
	/** r/g/b 覆盖用的临时色板: 只在脚本真的覆盖颜色时才创建。 */
	private var _tintScratch:RGBPalette = null;

	/** 损坏溅射的强制回收时间 (0.7.3 同款保护)。 */
	static var buggedKillTime:Float = 0.5;

	/** 总存活上限, 兜底防止任何异常动画长期驻留。 */
	static var maxAliveTime:Float = 2.0;

	/** 无配置时 (现代图集) 的默认偏移, 与 0.7.3 一致。 */
	static final DEFAULT_MODERN_OFFSET_X:Float = -58;
	static final DEFAULT_MODERN_OFFSET_Y:Float = -55;

	/** 配置缓存: skin → 解析结果。跨谱面/换模组时由 PlayState.destroy 清理。 */
	public static var configs:Map<String, NoteSplashConfig> = [];

	/**
	 * 当前"存活"(动画播放中)的溅射总数。
	 * 高 NPS 手动谱面下每击一个溅射、动画 ~0.5s, 无上限时对象池会膨胀到数千个
	 * (每个自带 ColorSwap/PixelSplashShaderRef, 且 FlxTypedGroup.add/recycle 都是 O(n)),
	 * PlayState.spawnNoteSplash 用它做硬上限兜底。
	 */
	public static var liveCount:Int = 0;

	/** 本实例是否已计入 liveCount (kill/destroy 幂等去重)。 */
	var _liveTracked:Bool = false;

	/**
	 * 默认溅射路径:
	 * 0.7.3/1.0.4 → noteSplashes/noteSplashes (带 txt/json 配置);
	 * 0.6.3       → noteSplashes (flat, 引擎原生行为)。
	 */
	public static var defaultNoteSplash(get, never):String;
	static function get_defaultNoteSplash():String
	{
		return CompatEngine.isModern() ? 'noteSplashes/noteSplashes' : 'noteSplashes';
	}

	/** 0.7.3/1.0.4: 用户切换过溅射皮肤时追加后缀 (如 -diamond)。 */
	public static function getSplashSkinPostfix():String
	{
		var skin:String = '';
		if (ClientPrefs.data.splashSkin != ClientPrefs.defaultData.splashSkin)
			skin = '-' + ClientPrefs.data.splashSkin.trim().toLowerCase().replace(' ', '_');
		return skin;
	}

	public function new(x:Float = 0, y:Float = 0, ?note:Int = 0) {
		super(x, y);

		var skin:String = defaultNoteSplash;
		if(PlayState.SONG != null && PlayState.SONG.splashSkin != null && PlayState.SONG.splashSkin.length > 0) skin = PlayState.SONG.splashSkin;

		// 多k: flat 图集用原版 ColorSwap; 0.7.3 白底溅射在 setupNoteSplash 里按材质切换
		colorSwap = new ColorSwap();
		rgbShader = new PixelSplashShaderRef();
		shader = colorSwap.shader;

		setupNoteSplash(x, y, note, skin);
		antialiasing = ClientPrefs.data.globalAntialiasing;
		if (PlayState.isPixelStage || !ClientPrefs.data.globalAntialiasing)
			antialiasing = false;
	}

	public function setupNoteSplash(x:Float, y:Float, note:Int = 0, texture:String = null, hueColor:Float = 0, satColor:Float = 0, brtColor:Float = 0, ?noteObj:Note = null) {
		// 多k: 位置/offset 按 noteScale 缩放 (与 strum/Note 完全同比例, 保证
		// 溅射中心相对 strum 的位置在所有 k 值下都和 4K 一致); 尺寸按 splashScales
		// (0.6.3 多k 的溅射大小设计)。两者比例不同 (9K: 0.6 vs 0.657) 正是
		// 之前"偏下/偏右"的根源——只缩尺寸不缩位置, 溅射就偏离缩小的 strum。
		var posScale:Float = Note.noteScale(PlayState.mania);
		var sizeScale:Float = EKData.splashScales[PlayState.mania];
		setPosition(x - Note.swagWidth * 0.95 * posScale, y - Note.swagWidth * posScale);
		alpha = ClientPrefs.data.splashAlpha;
		aliveTime = 0;
		if (!_liveTracked) { _liveTracked = true; liveCount++; }
		// 池化复用: 清掉上一次的溅射缩放 (setGraphicSize 只改 scale, 不碰 offset/origin)
		scale.set(1, 1);
		width = frameWidth;
		height = frameHeight;

		if(texture == null)
		{
			// 用户选择的溅射皮肤后缀作为主路径 (与原版一致), 任意兼容模式都生效;
			// 图集缺失时再由 loadAnims 回退链兜底。
			var postfix:String = getSplashSkinPostfix();
			if (postfix.length > 0)
				texture = 'noteSplashes/noteSplashes' + postfix;
			else if (CompatEngine.isModern())
				texture = defaultNoteSplash;
			else
				texture = 'noteSplashes';
		}

		if(textureLoaded != texture) {
			textureLoaded = loadAnims(texture);
		}

		// 0.7.3/1.0.4: 白底溅射 (noteSplashes/*) 走 RGB 色板染色, 颜色与 Note 一致。
		// 1.0.4 的图集配置可以显式声明 allowRGB —— false 表示图集自带颜色、不要染色
		// (SonicTheFunkChinese 的 noteSplashes-sonic.json 就是这种), true 表示白底图集。
		// 配置没声明时保留本引擎原有的路径判断, 既有模组的观感不变。
		var nsData:NoteSplashData = (noteObj != null) ? noteObj.noteSplashData : null;
		var isModernSplash:Bool = (textureLoaded != null && textureLoaded.startsWith('noteSplashes/'));
		var useRGBPath:Bool = isModernSplash || (_allowRGB != null);
		// 像素舞台按块取样; 配置 allowPixel:false 时强制 1:1。
		var pixelBlocks:Bool = PlayState.isPixelStage && (_allowPixel != false);

		if (useRGBPath)
		{
			// allowRGB:false 时传 null -> mult=0, 图集原样输出 (与 1.0.4 一致)。
			var palette:RGBPalette = (_allowRGB == false) ? null : buildTintPalette(nsData, noteObj, note);
			rgbShader.copyValues(palette);
			rgbShader.setPixelSize(pixelBlocks ? PlayState.daPixelZoom : 1);
			shader = rgbShader.shader;
		}
		else
		{
			colorSwap.hue = hueColor;
			colorSwap.saturation = satColor;
			colorSwap.brightness = brtColor;
			shader = colorSwap.shader;
		}

		// 0.7.3/1.0.4: noteSplashData.a / .antialiasing 覆盖。它们的默认值就等于本引擎
		// 的设置 (splashAlpha / globalAntialiasing), 所以脚本不写时行为完全不变。
		alpha = ClientPrefs.data.splashAlpha;
		if (nsData != null) alpha = nsData.a;
		antialiasing = ClientPrefs.data.globalAntialiasing;
		if (nsData != null) antialiasing = nsData.antialiasing;
		// 引擎设置优先: 用户在设置里关掉抗锯齿、或当前是像素舞台时, 脚本不能强行打开。
		if (PlayState.isPixelStage || !ClientPrefs.data.globalAntialiasing)
			antialiasing = false;

		offset.set(10 * posScale, 10 * posScale);

		var animNum:Int = FlxG.random.int(1, maxAnims);
		// 多k: 溅射动画复用 0.6.3 的 4 个方向, 颜色由 RGB 色板 / ColorSwap 决定
		var splashData:Int = note;
		if (PlayState.mania > 3)
			splashData = EKData.getBaseTexture(PlayState.mania, Std.int(Math.abs(note)) % Note.ammo[PlayState.mania]);
		else
			splashData = Std.int(Math.abs(note)) % 4;

		animation.play('note' + splashData + '-' + animNum, true);
		if(animation.curAnim != null)
		{
			var animOff:Array<Float> = offsetFor(splashData, animNum);
			if (animOff != null)
			{
				offset.x += animOff[0] * posScale;
				offset.y += animOff[1] * posScale;
			}
			var fpsRange:Array<Int> = fpsFor(splashData, animNum);
			var lo:Int = (fpsRange != null) ? fpsRange[0] : _minFps;
			var hi:Int = (fpsRange != null) ? fpsRange[1] : _maxFps;
			animation.curAnim.frameRate = FlxG.random.int(lo, hi);
		}

		// 多k: 溅射尺寸按 splashScales 缩放 (位置已按 noteScale, 两者解耦)。
		if (sizeScale != 1)
		{
			setGraphicSize(Std.int(frameWidth * sizeScale));
		}

		// 多k: 记录缩放, 逐帧把溅射中心对齐到 strum 中心。位置按 posScale
		// 缩放、尺寸按 sizeScale 缩放, 而图集帧自带的 frameX/frameY
		// (新旧材质的 trim 数值不同) 只随尺寸缩放, 两者不一致时溅射会
		// 整体偏左/偏上, k 越大越明显。
		_posScale = posScale;
		_sizeScale = sizeScale;
		applyManiaOffsetCompensation();
	}

	/**
	 * 多k: 补偿当前动画帧的 frameX/frameY 缩放偏差。
	 * 溅射位置按 posScale 缩放、尺寸按 sizeScale 缩放, 而图集帧自带的
	 * frameX/frameY (trim) 渲染时跟随尺寸缩放, 且 FlxSprite 在加载图集时
	 * 会 centerOrigin (origin = 首帧中心)。实际渲染:
	 * 可见区左上角 = (x - offset) + origin*(1-sizeScale) + frame.offset*sizeScale,
	 * 其中 origin*(1-sizeScale) 项在缩放 ≠ 1 时会把整张贴图往右下推,
	 * 这正是之前"越修越偏"的原因。
	 * 这里按当前帧的可见矩形把溅射中心对齐到 strum 中心
	 * (strum.x + swagWidth/2*posScale), 与 4K 原版"溅射中心≈strum 中心"
	 * 的观感一致, 新旧材质通用。
	 * 4K 下 sizeScale == posScale, 保持原版行为; 每帧 trim/尺寸不同,
	 * 动画推进后要重新计算。
	 */
	/**
	 * 决定这块溅射要不要染色、染成什么色 (null = 不染色, 图集原样输出)。
	 * 与 0.7.3/1.0.4 同口径, 但 r/g/b 覆盖使用一块复用的临时色板, 不去改 Note 自己的
	 * 色板 (上游 0.7.3 直接写 note.rgbShader, 会连带把 Note 本身的颜色一起改掉)。
	 * @param data 当前 Note 的 noteSplashData (null = 没有 Note, 例如预载实例)
	 */
	function buildTintPalette(data:NoteSplashData, noteObj:Note, direction:Int):RGBPalette
	{
		if (data != null)
		{
			// 引擎设置/脚本关掉了染色 (useRGBShader 默认来自 noteRGBMode)
			if (!data.useRGBShader) return null;
		}
		else if (ClientPrefs.noteRGBDisabled(PlayState.SONG != null && PlayState.SONG.disableNoteRGB))
			return null;

		var pal:RGBPalette = null;
		if (data != null && !data.useGlobalShader && noteObj != null && noteObj.rgbShader != null)
			pal = noteObj.rgbShader.parent;
		else
			pal = Note.initializeGlobalRGBShader(Std.int(Math.abs(direction)));

		if (data != null && pal != null && (data.r != -1 || data.g != -1 || data.b != -1))
		{
			var scratch:RGBPalette = _tintScratch;
			if (scratch == null) scratch = _tintScratch = new RGBPalette();
			scratch.r = pal.r;
			scratch.g = pal.g;
			scratch.b = pal.b;
			scratch.mult = pal.mult;
			if (data.r != -1) scratch.r = data.r;
			if (data.g != -1) scratch.g = data.g;
			if (data.b != -1) scratch.b = data.b;
			pal = scratch;
		}
		return pal;
	}

	function applyManiaOffsetCompensation():Void
	{
		if (_sizeScale == _posScale) return;
		var cur:FlxFrame = frame;
		if (cur == null) return;

		var fOff = cur.offset;
		var fRect = cur.frame;
		offset.x = origin.x * (1 - _sizeScale) + fOff.x * _sizeScale + (fRect.width / 2) * _sizeScale
			- (Note.swagWidth * 0.95 + Note.swagWidth / 2) * _posScale;
		offset.y = origin.y * (1 - _sizeScale) + fOff.y * _sizeScale + (fRect.height / 2) * _sizeScale
			- (Note.swagWidth + Note.swagWidth / 2) * _posScale;
	}

	/**
	 * 加载溅射图集 + 配置, 返回实际使用的 skin (可能因缺失回退)。
	 * 回退链与 0.7.3/1.0.4 一致: 请求值 → 默认路径+后缀 → 默认路径 → flat noteSplashes。
	 */
	function loadAnims(skin:String):String
	{
		var actual:String = skin;
		// 换图集时先清掉上一张的渲染声明, 免得图集缺失时沿用旧值。
		_allowRGB = null;
		_allowPixel = null;
		frames = Paths.getSparrowAtlas(actual);

		if (frames == null && CompatEngine.isModern())
		{
			var fallback:String = defaultNoteSplash + getSplashSkinPostfix();
			if (fallback != actual)
			{
				actual = fallback;
				frames = Paths.getSparrowAtlas(actual);
			}
			if (frames == null)
			{
				actual = defaultNoteSplash;
				frames = Paths.getSparrowAtlas(actual);
			}
		}
		if (frames == null)
		{
			actual = 'noteSplashes';
			frames = Paths.getSparrowAtlas(actual);
		}
		if (frames == null)
		{
			// 图集不存在: 保留 1 组, 交给 update 的超时回收兜底。
			maxAnims = 1;
			_animPrefix = 'note splash';
			_slotPrefix = null;
			_slotOffsets = null;
			_slotFps = null;
			return actual;
		}

		applyConfig(actual);

		// 按 0.7.3 的方式逐组探测: 只有 4 个方向都存在的组才计入 maxAnims。
		maxAnims = 0;
		while (true)
		{
			var animID:Int = maxAnims + 1;
			var allExist:Bool = true;
			for (i in 0...4)
			{
				var prefix:String = prefixFor(i, animID);
				if (prefix == null || !addAnimAndCheck('note$i-$animID', prefix, 24, false))
				{
					allExist = false;
					break;
				}
			}
			if (!allExist) break;
			maxAnims++;
		}
		if (maxAnims < 1)
			maxAnims = 1;

		return actual;
	}

	/** 解析并应用 0.7.3 txt / 1.0.4 json 配置。 */
	function applyConfig(skin:String):Void
	{
		_animPrefix = 'note splash';
		_minFps = 22;
		_maxFps = 26;
		_txtOffsets = null;
		_slotPrefix = null;
		_slotOffsets = null;
		_slotFps = null;

		var cfg:NoteSplashConfig = precacheConfig(skin);
		if (cfg == null) return;

		// 1.0.4 json 的渲染开关 (0.7.3 的 txt 没有这两个字段, 保持 null = 沿用路径判断)
		_allowRGB = cfg.allowRGB;
		_allowPixel = cfg.allowPixel;

		var anims:Map<String, NoteSplashAnimDef> = cfg.anims;
		if (anims != null && anims.keys().hasNext())
		{
			// ── 1.0.4 json: 每个动画自带前缀 / 偏移 / fps ──
			_slotPrefix = new Map<Int, String>();
			_slotOffsets = new Map<Int, Array<Float>>();
			_slotFps = new Map<Int, Array<Int>>();
			for (key in anims.keys())
			{
				var def:NoteSplashAnimDef = anims.get(key);
				var data:Int = (def.noteData != null) ? def.noteData : 0;
				var slot:Int = Std.int(Math.abs(data)) % 8; // direction + (animNum-1)*4
				var prefix:String = (def.prefix != null && def.prefix.length > 0)
					? def.prefix : ((def.name != null && def.name.length > 0) ? def.name : null);
				if (prefix != null) _slotPrefix.set(slot, prefix);
				if (def.offsets != null && def.offsets.length >= 2) _slotOffsets.set(slot, [def.offsets[0], def.offsets[1]]);
				if (def.fps != null && def.fps.length >= 2) _slotFps.set(slot, [def.fps[0], def.fps[1]]);
			}
		}
		else
		{
			// ── 0.7.3 txt: 全局动画前缀 / fps 区间 / 按 animID 的偏移表 ──
			if (cfg.anim != null && cfg.anim.length > 0) _animPrefix = cfg.anim;
			if (cfg.minFps != null && cfg.minFps > 0) _minFps = cfg.minFps;
			if (cfg.maxFps != null && cfg.maxFps > 0) _maxFps = cfg.maxFps;
			if (cfg.offsets != null && cfg.offsets.length > 0) _txtOffsets = cfg.offsets;
		}
	}

	/** 获取 slot 对应的动画前缀 (json 优先, 否则标准/txt 命名)。 */
	function prefixFor(direction:Int, animNum:Int):String
	{
		if (_slotPrefix != null)
		{
			var slotPrefix:String = _slotPrefix.get(direction + (animNum - 1) * 4);
			if (slotPrefix != null) return slotPrefix;
		}
		return '$_animPrefix ' + colorName(direction) + ' $animNum';
	}

	/** slot 对应的额外偏移 (json / txt / 现代默认)。 */
	function offsetFor(direction:Int, animNum:Int):Array<Float>
	{
		var slot:Int = direction + (animNum - 1) * 4;
		if (_slotOffsets != null)
		{
			var offs:Array<Float> = _slotOffsets.get(slot);
			if (offs != null) return offs;
		}
		if (_txtOffsets != null && _txtOffsets.length > 0)
			return _txtOffsets[slot % _txtOffsets.length];
		// 现代图集无配置时使用 0.7.3 默认偏移; 0.6.3 flat 图集帧自带 frameX/frameY, 不再额外偏移。
		if (CompatEngine.isModern() && textureLoaded != null && textureLoaded.startsWith('noteSplashes/'))
			return [DEFAULT_MODERN_OFFSET_X, DEFAULT_MODERN_OFFSET_Y];
		return null;
	}

	/** slot 对应的 fps 区间 (json 优先)。 */
	function fpsFor(direction:Int, animNum:Int):Array<Int>
	{
		if (_slotFps != null)
		{
			var fps:Array<Int> = _slotFps.get(direction + (animNum - 1) * 4);
			if (fps != null) return fps;
		}
		return null;
	}

	/** 方向 → 颜色名 (与 0.6.3 一致: 0=purple, 1=blue, 2=green, 3=red)。 */
	inline function colorName(direction:Int):String
	{
		return switch(direction)
		{
			case 0: 'purple';
			case 1: 'blue';
			case 2: 'green';
			default: 'red';
		}
	}

	/** 只有前缀确实匹配到帧时才注册动画, 避免注册空动画导致 play 后无法结束。 */
	function addAnimAndCheck(name:String, prefix:String, framerate:Int = 24, loop:Bool = false):Bool
	{
		var animFrames:Array<FlxFrame> = [];
		@:privateAccess animation.findByPrefix(animFrames, prefix); // adds valid frames to animFrames
		if (animFrames.length < 1) return false;

		animation.addByPrefix(name, prefix, framerate, loop);
		return true;
	}

	/** json 里的开关可能是 bool / "true" / 1, 统一读成 Null<Bool> (null = 没写)。 */
	static function readBool(obj:Dynamic, field:String):Null<Bool>
	{
		var v:Dynamic = Reflect.field(obj, field);
		if (v == null) return null;
		if (Std.isOfType(v, Bool)) return cast v;
		if (Std.isOfType(v, String)) return (cast v : String).toLowerCase() == 'true';
		if (Std.isOfType(v, Float) || Std.isOfType(v, Int)) return (cast v : Float) != 0;
		return null;
	}

	/**
	 * 解析并缓存溅射配置 (txt 为 0.7.3 格式, json 为 1.0.4 格式; json 优先)。
	 * 文件在 create 阶段就随 splash 预加载, 避免第一次击键时卡顿。
	 */
	public static function precacheConfig(skin:String):NoteSplashConfig
	{
		if (skin == null || skin.length == 0) return null;
		if (configs.exists(skin)) return configs.get(skin);

		var cfg:NoteSplashConfig = null;
		#if sys
		// 1.0.4: images/<skin>.json
		var jsonText:String = null;
		try { jsonText = Paths.getTextFromFile('images/$skin.json'); } catch (e:Dynamic) {}
		if (jsonText != null && jsonText.length > 0)
		{
			var parsed:Dynamic = null;
			try { parsed = Json.parse(jsonText.replace("\uFEFF", "")); } catch (e:Dynamic) {}
			if (parsed != null)
			{
				var allowRGB:Null<Bool> = readBool(parsed, 'allowRGB');
				var allowPixel:Null<Bool> = readBool(parsed, 'allowPixel');
				var animsField:Dynamic = Reflect.field(parsed, 'animations');
				if (animsField != null)
				{
					var anims:Map<String, NoteSplashAnimDef> = [];
					for (field in Reflect.fields(animsField))
					{
						var raw:Dynamic = Reflect.field(animsField, field);
						if (raw == null) continue;
						var def:NoteSplashAnimDef = { name: field };
						if (Reflect.field(raw, 'name') != null) def.name = Std.string(Reflect.field(raw, 'name'));
						if (Reflect.field(raw, 'prefix') != null) def.prefix = Std.string(Reflect.field(raw, 'prefix'));
						if (Reflect.field(raw, 'noteData') != null) def.noteData = Std.int(Reflect.field(raw, 'noteData'));
						if (Reflect.field(raw, 'indices') != null && Std.isOfType(Reflect.field(raw, 'indices'), Array))
						{
							var idx:Array<Int> = [];
							for (v in (cast Reflect.field(raw, 'indices') : Array<Dynamic>))
								if (v != null) idx.push(Std.int(v));
							def.indices = idx;
						}
						if (Reflect.field(raw, 'offsets') != null && Std.isOfType(Reflect.field(raw, 'offsets'), Array))
						{
							var offs:Array<Float> = [];
							for (v in (cast Reflect.field(raw, 'offsets') : Array<Dynamic>))
								if (v != null) offs.push(Std.parseFloat(Std.string(v)));
							def.offsets = offs;
						}
						if (Reflect.field(raw, 'fps') != null && Std.isOfType(Reflect.field(raw, 'fps'), Array))
						{
							var fps:Array<Int> = [];
							for (v in (cast Reflect.field(raw, 'fps') : Array<Dynamic>))
								if (v != null) fps.push(Std.int(v));
							def.fps = fps;
						}
						anims.set(field, def);
					}
					cfg = { anims: anims, allowRGB: allowRGB, allowPixel: allowPixel };
				}
				else if (allowRGB != null || allowPixel != null)
					cfg = { allowRGB: allowRGB, allowPixel: allowPixel };
			}
		}

		// 0.7.3: images/<skin>.txt
		if (cfg == null)
		{
			var txtText:String = null;
			try { txtText = Paths.getTextFromFile('images/$skin.txt'); } catch (e:Dynamic) {}
			if (txtText != null && txtText.length > 0)
			{
				var lines:Array<String> = txtText.split('\n');
				if (lines.length > 0)
				{
					var out:NoteSplashConfig = { anim: lines[0].trim() };
					if (lines.length > 1)
					{
						var fpsParts:Array<String> = lines[1].trim().split(' ');
						out.minFps = Std.parseInt(fpsParts[0]);
						out.maxFps = Std.parseInt(fpsParts[1]);
						if (out.minFps == null) out.minFps = 22;
						if (out.maxFps == null) out.maxFps = 26;
					}
					var offs:Array<Array<Float>> = [];
					for (i in 2...lines.length)
					{
						var lineTrimmed:String = lines[i].trim();
						if (lineTrimmed == '') continue;
						var parts:Array<String> = lineTrimmed.split(' ');
						var x:Float = Std.parseFloat(parts[0]);
						var y:Float = Std.parseFloat(parts[1]);
						if (Math.isNaN(x)) x = 0;
						if (Math.isNaN(y)) y = 0;
						offs.push([x, y]);
					}
					if (offs.length > 0) out.offsets = offs;
					cfg = out;
				}
			}
		}
		#end

		configs.set(skin, cfg);
		return cfg;
	}

	override public function kill():Void
	{
		// 池化复用 + 自杀式回收 (update 里动画结束即 kill), 这里同步递减存活计数
		if (_liveTracked) { _liveTracked = false; if (liveCount > 0) liveCount--; }
		super.kill();
	}

	override public function destroy():Void
	{
		if (_liveTracked) { _liveTracked = false; if (liveCount > 0) liveCount--; }
		super.destroy();
	}

	override function update(elapsed:Float) {
		aliveTime += elapsed;
		if((animation.curAnim != null && animation.curAnim.finished)
			|| (animation.curAnim == null && aliveTime >= buggedKillTime)
			|| aliveTime >= maxAliveTime)
			kill();

		super.update(elapsed);

		// 动画推进后当前帧的 frameX/frameY 变了, 重新补偿 trim 缩放偏差
		if (alive)
			applyManiaOffsetCompensation();
	}
}

/**
 * 0.7.3/1.0.4 兼容: 溅射 RGB 着色器引用。
 * 从 Note 的共享色板 (RGBPalette) 拷贝 r/g/b/mult 到本溅射独立的 shader,
 * 保证溅射颜色与同轨道 Note 完全一致, 且不互相污染。
 */
class PixelSplashShaderRef
{
	public var shader:PixelSplashShader = new PixelSplashShader();

	public function copyValues(tempShader:RGBPalette)
	{
		var enabled:Bool = (tempShader != null);
		if (enabled)
		{
			for (i in 0...3)
			{
				shader.r.value[i] = tempShader.shader.r.value[i];
				shader.g.value[i] = tempShader.shader.g.value[i];
				shader.b.value[i] = tempShader.shader.b.value[i];
			}
			shader.mult.value[0] = tempShader.shader.mult.value[0];
		}
		else
			shader.mult.value[0] = 0.0;
	}

	/** 像素舞台: 按 daPixelZoom 逐块取样 (0.7.3 同款)。 */
	public function setPixelSize(pixel:Float)
	{
		shader.uBlocksize.value = [pixel, pixel];
	}

	public function new()
	{
		shader.r.value = [0, 0, 0];
		shader.g.value = [0, 0, 0];
		shader.b.value = [0, 0, 0];
		shader.mult.value = [1];
		setPixelSize(1);
	}
}

/** 0.7.3 同款溅射 GLSL: 白底材质按 r/g/b 三色通道染色。 */
class PixelSplashShader extends FlxShader
{
	@:glFragmentHeader('
		#pragma header

		uniform vec3 r;
		uniform vec3 g;
		uniform vec3 b;
		uniform float mult;
		uniform vec2 uBlocksize;

		vec4 flixel_texture2DCustom(sampler2D bitmap, vec2 coord) {
			vec2 blocks = openfl_TextureSize / uBlocksize;
			vec4 color = flixel_texture2D(bitmap, floor(coord * blocks) / blocks);
			if (!hasTransform) {
				return color;
			}

			if(color.a == 0.0 || mult == 0.0) {
				return color * openfl_Alphav;
			}

			vec4 newColor = color;
			newColor.rgb = min(color.r * r + color.g * g + color.b * b, vec3(1.0));
			newColor.a = color.a;

			color = mix(color, newColor, mult);

			if(color.a > 0.0) {
				return vec4(color.rgb, color.a);
			}
			return vec4(0.0, 0.0, 0.0, 0.0);
		}')

	@:glFragmentSource('
		#pragma header

		void main() {
			gl_FragColor = flixel_texture2DCustom(bitmap, openfl_TextureCoordv);
		}')

	public function new()
	{
		super();
	}
}
