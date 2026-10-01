package;

import flixel.math.FlxRect;
import flixel.math.FlxMatrix;
import flixel.graphics.frames.FlxFrame;
import flixel.graphics.frames.FlxFrame.FlxFrameAngle;
import flixel.graphics.frames.FlxFrame.FlxFrameType;
import flixel.system.FlxAssets.FlxShader;
import openfl.geom.ColorTransform;
//noinspection HaxeUsingResolverPlaceInvalid
using flixel.util.FlxColorTransformUtil;
import editors.ChartingState;
import openfl.utils.AssetType;
import openfl.display.BlendMode;
import shaders.RGBPalette;
import shaders.RGBPalette.RGBShaderReference;
import mohong.ObjectPool;

using StringTools;

typedef EventNote = {
    strumTime:Float,
    event:String,
    value1:String,
    value2:String
}


@:structInit class PreloadedChartNote {
    public var strumTime:Float = 0;
    public var sustainLength:Float = 0;
    public var parentST:Float = 0;
    public var parentSL:Float = 0;
    /** stepCrochet of the section this note was generated in (BPM-change charts need it for sustain height). */
    public var stepCrochet:Float = 0;
    public var hitHealth:Float = 0.023;
    public var missHealth:Float = 0.0475;
    public var multSpeed:Float = 1;
    public var multAlpha:Float = 1;
    public var noteDensity:Float = 1;
    public var offsetX:Float = 0;
    public var offsetY:Float = 0;

    // ── Null<Float> ──
    public var noteSplashHue:Null<Float> = null;
    public var noteSplashSat:Null<Float> = null;
    public var noteSplashBrt:Null<Float> = null;

    // ── String ──
    public var noteType:String = '';
    public var animSuffix:String = '';
    public var noteskin:String = '';
    public var texture:String = '';
    /** 0.6.3 自定义 Note 兼容: 溅射皮肤/颜色在 PreloadedChartNote 上也可由 Lua 设置。
     * 注意：只有 Lua 显式写过才覆盖（null 表示未设置），避免把普通 Note 的轨道色溅射覆盖成全零。 */
    public var noteSplashTexture:String = null;

    // ── Int ──
    public var noteData:Int = 0;
    /** 多k: 该 Note 所属键数快照 (0 基, -1 = 跟随 PlayState.mania)。 */
    public var mania:Int = -1;

    // ── Bool ──
    public var mustPress:Bool = false;
    public var oppNote:Bool = false;
    public var gfNote:Bool = false;
    public var noAnimation:Bool = false;
    public var noMissAnimation:Bool = false;
    public var isSustainNote:Bool = false;
    public var isSustainEnd:Bool = false;
    public var hitCausesMiss:Bool = false;
    public var ignoreNote:Bool = false;
    public var blockHit:Bool = false;
    public var lowPriority:Bool = false;
    public var wasHit:Bool = false;
    public var noteSplashDisabled:Bool = false;
    public var hitsoundDisabled:Bool = false;
}

/**
 * 用于旧格式谱面 (0.1 – 0.3.2) 的 noteType 数值 → 字符串 转换表。
 * 与 104 新版保持一致的默认列表，加载 ChartingState 前即可安全使用。
 */
final defaultNoteTypes:Array<String> = [
	'', //Always leave this one empty pls
	'Alt Animation',
	'Hey!',
	'Hurt Note',
	'GF Sing',
	'No Animation'
];

class Note extends FlxSprite {
    // ============ 多k 静态数据 (转发到 EKData) ============
    public static var minMania:Int = 0;
    public static var maxMania:Int = 17;
    public static var defaultMania:Int = 3;
    public static var ammo:Array<Int> = EKData.ammo;
    public static var keysShit:Map<Int, Map<String, Dynamic>> = EKData.keysShit;
    public static var scales:Array<Float> = EKData.scales;
    public static var lessX:Array<Int> = EKData.lessX;
    public static var separator:Array<Int> = EKData.noteSep;
    public static var xtra:Array<Float> = EKData.offsetX;
    public static var posRest:Array<Float> = EKData.restPosition;
    public static var gridSizes:Array<Int> = EKData.gridSizes;
    public static var noteSplashScales:Array<Float> = EKData.splashScales;
    public static var pixelScales:Array<Float> = EKData.pixelScales;
    // ======================================================

    /**
     * 动画帧序列缓存：为几十万个同图集 Note 复用 addByPrefix 的帧扫描结果，
     * 每个 Note 仍会独立 add 动画对象（flixel 动画是 per-sprite 的），但省去重复的
     * 帧前缀扫描（对高帧数图集 + 海量 Note 可显著降低加载耗时）。
     * key = 图集路径 + 类型 + 动画名。由 clearNoteAnimCache() 在状态/纹理切换时清空。
     */
    public static var noteAnimFrames:Map<String, Array<Int>> = [];
    public static function clearNoteAnimCache():Void {
        noteAnimFrames = [];
    }

    /** 当前 Note 的动画缓存基键（图集 + 类型），在 reloadNote 中计算。 */
    private var _animCacheKey:String = null;

    public var extraData:Map<String,Dynamic> = [];
    public var strumTime:Float = 0;
    public var mustPress:Bool = false;
    public var doOppStuff:Bool = false;
    public var noteData:Int = 0;
    public var canBeHit:Bool = false;
    public var tooLate:Bool = false;
    public var wasGoodHit:Bool = false;
    public var missed:Bool = false;
    public var ignoreNote:Bool = false;
    public var hitByOpponent:Bool = false;
    public var noteWasHit:Bool = false;
    public var prevNote:Note;
    public var nextNote:Note;

    public var wasHit:Bool = false;
    public var spawned:Bool = false;
    public var tail:Array<Note> = [];
    public var parent:Note;
    public var parentST:Float = 0;
    public var parentSL:Float = 0;
    public var blockHit:Bool = false;

    public var sustainLength:Float = 0;
    public var isSustainNote:Bool = false;
    public var isSustainEnd:Bool = false;
    public var canHold:Bool = false;
    public var noteType(default, set):String = null;

    public var eventName:String = '';
    public var eventLength:Int = 0;
    public var eventVal1:String = '';
    public var eventVal2:String = '';

    /** 多k: 使用原版 ColorSwap (类型化才能触发 setter 写入 shader); Hurt/自定义纹理 Note 为 null。 */
    public var colorSwap:ColorSwap;

    /** 0.7.3/1.0.4 兼容: 三色 Note 着色器引用 (懒挂载, 脚本修改才接管)。 */
    public var rgbShader:RGBShaderReference = null;

    /**
     * 0.7.3/1.0.4 兼容: 每条轨道共享的全局色板。
     * 键 = |noteData| + mania*64, 兼顾多k 与 SPACE→UP 基底映射。
     */
    public static var globalRgbShaders:Array<RGBPalette> = [];

    /** 多k: 是否应用轨道色着色器 (默认 true; Hurt Note / 脚本 setNoteTexture 自定义纹理时 false)。 */
    public var applyLaneColorShader:Bool = true;
    public var inEditor:Bool = false;

    /** Index into PlayState.unspawnNotes (PreloadedChartNote), used for data-based sustain tail lookup. */
    public var sourceIndex:Int = -1;

    /**
     * PlayState.activeNotes (存活音符紧凑列表) 的下标, -1 = 不在列表中。
     * 由 PlayState 在物化/回收时以 O(1) swap-remove 维护,
     * 让每帧更新/预扫只需遍历真正存活的音符而非整个 members 数组。
     */
    public var activeIdx:Int = -1;

    /**
     * 本 Note 在 PlayState.notes.members 中的缓存下标 (脚本回调参数用)。
     * 由 PlayState 在追加/排序/压缩时增量维护, noteIndexFast() 以 O(1) 校验读取,
     * 失效时才回退一次 O(n) indexOf 并自愈 —— 替代每击 notes.members.indexOf 的 O(n) 扫描。
     */
    public var memberIndex:Int = -1;

    /** True while this Note sits in PlayState.notePool (per-state recycling). */
    public var pooled:Bool = false;

    /**
     * H-Slice style off-screen culling: true while PlayState parked this note
     * off-screen (visible forced false) because its scroll distance exceeds the
     * screen range. PlayState restores visible when the note scrolls back into
     * range. Scripts may still freely toggle visible; only engine-managed
     * park/unpark pairs touch it.
     */
    public var culled:Bool = false;

    public var animSuffix:String = '';
    public var gfNote:Bool = false;
    public var earlyHitMult:Float = 0.5;
    public var lateHitMult:Float = 1;
    public var lowPriority:Bool = false;

    public var noteDensity:Float = 1;
    public static var swagWidth:Float = 160 * 0.7;

    /**
     * 默认 Note 皮肤路径, 由"旧版/新版 Note"设置决定 (独立于兼容模式):
     * Old = 0.6.3 flat NOTE_assets (带 frameX/frameY, 定位代码按它校准);
     * New = 0.7.3 noteSkins/NOTE_assets。
     */
    public static var defaultNoteSkin(get, never):String;
    static function get_defaultNoteSkin():String
    {
        return (ClientPrefs.data.noteStyle == 'New') ? 'noteSkins/NOTE_assets' : 'NOTE_assets';
    }

    /** 0.7.3/1.0.4 兼容: 用户切换 Note 皮肤时追加的后缀 (Default 为空)。 */
    public static function getNoteSkinPostfix():String
    {
        var skin:String = '';
        if (ClientPrefs.data.noteSkin != ClientPrefs.defaultData.noteSkin)
            skin = '-' + ClientPrefs.data.noteSkin.trim().toLowerCase().replace(' ', '_');
        return skin;
    }

    // 0.6.3 兼容: colArray 必须是实例字段, 部分模组会通过 Lua getProperty/setProperty
    // 直接读写 note.colArray, 改成 static 会让实例反射取到 null 导致模组崩溃。
    private var colArray:Array<String> = ['purple', 'blue', 'green', 'red'];
    private var pixelInt:Array<Int> = [0, 1, 2, 3];

    public var noteSplashDisabled:Bool = false;
    public var noteSplashTexture:String = null;
    public var noteSplashHue:Float = 0;
    public var noteSplashSat:Float = 0;
    public var noteSplashBrt:Float = 0;

    public var offsetX:Float = 0;
    public var offsetY:Float = 0;
    public var offsetAngle:Float = 0;
    public var multAlpha:Float = 1;
    public var multSpeed(default, set):Float = 1;

    public var copyX:Bool = true;
    public var copyY:Bool = true;
    public var copyAngle:Bool = true;
    public var copyAlpha:Bool = true;
    public var copyScaleX:Bool = false;
    public var copyScaleY:Bool = false;

    public var hitHealth:Float = 0.023;
    public var missHealth:Float = 0.0475;
    public var rating:String = 'unknown';
    /**
     * 原始判定名(引擎内部真实判定, 例如 'marvelous')。
     * `rating` 会按 ClientPrefs.judgementNameCompat 的 1.0.4 口径改写后给脚本读,
     * 这个字段永远是引擎当时判出来的名字, 模组需要超完美档时读它。
     */
    public var ratingRaw:String = 'unknown';
    public var ratingMod:Float = 0;
    public var ratingDisabled:Bool = false;

    public var texture(default, set):String = null;

    public var noAnimation:Bool = false;
    public var noMissAnimation:Bool = false;
    public var hitCausesMiss:Bool = false;
    public var distance:Float = 2000;
    public var hitsoundDisabled:Bool = false;

    public var originalHeightForCalcs:Float = 6;

    /**
     * stepCrochet of the section this note was generated in (updated per changeBPM section).
     * Sustain height must match the same stepCrochet as the spacing, or segments
     * separate/overlap on BPM-change charts.
     */
    public var genStepCrochet:Float = 0;

    /**
     * 多k: 该 Note 生成时的 mania 快照 (0 基)。中途 Change Mania 时已生成的 Note
     * 保持原 k 值渲染/判定，直到被销毁；新生成的 Note 使用新 k 值。
     */
    public var mania:Int = 3;

    /** Lua/HScript: 自定义该 Note 的 ColorSwap 值 [hue, sat, brt] (直接覆盖轨道色)。null 表示按轨道。 */
    public var noteColorOverride:Array<Float> = null;

    /** Lua/HScript: 自定义该 Note 命中时的角色动作 (如 "singLEFT" 或 "singUP-miss")。null 表示按轨道。 */
    public var customCharAnim:String = null;

    /** 多k: 该 Note 在己方一侧的轨道索引 (0 ~ ammo-1)。 */
    inline public function laneData():Int
    {
        return Std.int(Math.abs(noteData) % Note.ammo[mania]);
    }

    /** 多k: 复用的基底纹理索引 (0=left, 1=down, 2=up, 3=right)。 */
    inline public function baseTex():Int
    {
        return EKData.getBaseTexture(mania, laneData());
    }

    /** 多k: 按轨道颜色设置 ColorSwap (基底纹理色 + 目标色差值 + 用户 arrowHSV 偏移)。 */
    public function applyLaneColor():Void
    {
        if (colorSwap == null) return;
        var lane:Int = laneData();
        if (noteColorOverride != null)
        {
            colorSwap.hue = noteColorOverride[0];
            colorSwap.saturation = noteColorOverride[1];
            colorSwap.brightness = noteColorOverride[2];
            return;
        }
        var delta:Array<Float> = EKData.getLaneColorSwap(mania, lane);
        var colorIdx:Int = EKData.letterColorIndex.get(EKData.getLetter(mania, lane));
        if (colorIdx < 0) colorIdx = lane;
        var hsv:Array<Int> = (colorIdx < ClientPrefs.data.arrowHSV.length) ? ClientPrefs.data.arrowHSV[colorIdx] : [0, 0, 0];
        var hue:Float = delta[0] + hsv[0] / 360;
        while (hue < 0) hue += 1;
        while (hue >= 1) hue -= 1;
        colorSwap.hue = hue;
        colorSwap.saturation = delta[1] + hsv[1] / 100;
        colorSwap.brightness = delta[2] + hsv[2] / 100;
    }

    /** 多k: 每 k 值的 Note 缩放倍率 (相对 4K)。 */
    public static function noteScale(mania:Int):Float
    {
        return EKData.scales[EKData.clampMania(mania)] / EKData.scales[3];
    }

    /**
     * Mania scale factor: pixelScales for pixel stages, scales otherwise.
     * Sustain height, movement and pixel centering all use it so they stay
     * proportional to the arrow size of the current stage.
     */
    public static function getManiaScale(mania:Int):Float
    {
        var m:Int = EKData.clampMania(mania);
        if (PlayState.isPixelStage)
            return EKData.pixelScales[m] / EKData.pixelScales[3];
        return EKData.scales[m] / EKData.scales[3];
    }

    /**
     * 多k: 中途切换 k 值时, 实时重置该 Note 的缩放大小以匹配新的 k 值布局。
     * 保留该 Note 生成时的 mania 快照 (判定/轨道不变), 仅重算视觉缩放,
     * 避免 >9K 时已生成 Note 与新的 strum 大小不一致。
     * 使用 frameWidth/frameHeight (原始帧尺寸) 计算, 避免已缩放后二次缩放累积。
     */
    public function resetNoteScaleForMania(newMania:Int):Void
    {
        if (noteData < 0 || frames == null) return;
        var lastScaleY:Float = scale.y;
        var rawW:Int = Math.round(frameWidth);
        if (PlayState.isPixelStage)
        {
            setGraphicSize(Std.int(rawW * PlayState.daPixelZoom * (EKData.pixelScales[EKData.clampMania(newMania)] / EKData.pixelScales[3])));
            antialiasing = false;
        }
        else
        {
            setGraphicSize(Std.int(rawW * 0.7 * Note.noteScale(newMania)));
        }
        if (isSustainNote)
        {
            // Recompute sustain height from the step formula and the new mania scale.
            if (!isSustainEnd)
            {
                var stepCrochet:Float = (genStepCrochet > 0) ? genStepCrochet : Conductor.stepCrochet;
                var songSpeedVal:Float = (PlayState.instance != null) ? PlayState.instance.songSpeed : 1;
                scale.y = (stepCrochet / 100) * 1.05 * songSpeedVal * multSpeed * Note.getManiaScale(newMania);
                if (PlayState.isPixelStage)
                {
                    scale.y *= 1.19;
                    scale.y *= (6 / frameHeight);
                    scale.y *= PlayState.daPixelZoom;
                }
            }
            else
            {
                scale.y = Note.getManiaScale(newMania);
            }
        }
        updateHitbox();
        // 换 k 后轨道颜色/基底纹理可能变化, 重新应用颜色
        if (applyLaneColorShader && colorSwap != null && noteData > -1)
            applyLaneColor();
    }

    private function set_multSpeed(value:Float):Float {
        if(!isSustainNote || isSustainEnd) {
            multSpeed = value;
            return value;
        }
        var ratio:Float = value / multSpeed;
        if(ratio != 1) {
            scale.y *= ratio;
            updateHitbox();
        }
        multSpeed = value;
        return value;
    }

    public function resizeByRatio(ratio:Float) {
        if(isSustainNote && !isSustainEnd && scale != null) {
            scale.y *= ratio;
            updateHitbox();
        }
    }

    /**
     * 根据当前 songSpeed 重新计算长条 body 的 scale.y，
     * 避免 `resizeByRatio` 乘法累积带来的浮点精度问题和极端值渲染异常。
     * @param newSongSpeed 当前新的 songSpeed 值（即 set_songSpeed 传入的 value）
     */
    public function recalcSustainScale(newSongSpeed:Float):Void {
        if(!isSustainNote || isSustainEnd || scale == null) return;
        if(PlayState.instance == null) return;

        // 用生成时所在小节的 stepCrochet 计算高度，与长条间距保持一致
        // （BPM 变化谱面里 Conductor.stepCrochet 会变，不能直接用）。
        var stepCrochet:Float = (genStepCrochet > 0) ? genStepCrochet : Conductor.stepCrochet;
        // Scale sustain height by mania (4K = 1.0, unchanged; high-K stays proportional to arrows).
        scale.y = (stepCrochet / 100) * 1.05 * newSongSpeed * multSpeed * Note.getManiaScale(mania);
        // 皮肤自适应: 非默认帧高时按 (44/frameHeight) 归一化 (默认皮肤行为不变)
        if(!PlayState.isPixelStage) scale.y *= (44.0 / frameHeight);
        if(!PlayState.isPixelStage) scale.y += (2.0 / frameHeight);
        if(PlayState.isPixelStage) {
            scale.y *= 1.19;
            scale.y *= (6 / frameHeight);
        }
        updateHitbox();
    }

    private function set_texture(value:String):String {
        if(texture != value) {
            reloadNote('', value);
        }
        texture = value;
        return value;
    }

    private function set_noteType(value:String):String {
        if(noteData > -1 && noteType != value) {
            switch(value) {
                case 'Hurt Note':
                    ignoreNote = mustPress;
                    applyLaneColorShader = false; // Hurt Note 不应用多k 调色
                    reloadNote('HURT');
                    noteSplashTexture = 'HURTnoteSplashes';
                    lowPriority = true;
                    if(isSustainNote) missHealth = 0.1;
                    else missHealth = 0.3;
                    hitCausesMiss = true;
                case 'Alt Animation':
                    animSuffix = '-alt';
                case 'No Animation':
                    noAnimation = true;
                    noMissAnimation = true;
                case 'GF Sing':
                    gfNote = true;
            }
            noteType = value;
        }
        if (colorSwap != null)
        {
            if(noteData > -1) applyLaneColor();
            noteSplashHue = colorSwap.hue;
            noteSplashSat = colorSwap.saturation;
            noteSplashBrt = colorSwap.brightness;
        }
        else
        {
            noteSplashHue = 0;
            noteSplashSat = 0;
            noteSplashBrt = 0;
        }
        return value;
    }

    /** 多k: 创建原版 ColorSwap (与 vanilla 相同, 多k 仅设置轨道色差值)。 */
    static inline function makeColorSwap():ColorSwap
    {
        return new ColorSwap();
    }

    /** 绑定值变化回调并按当前颜色决定是否挂载 GLSL 程序 (中性色不挂 → 引擎默认管线完全合批)。 */
    function wireColorSwap():Void
    {
        if (colorSwap == null) return;
        colorSwap.onChange = refreshSwapShader;
        refreshSwapShader();
    }

    function refreshSwapShader():Void
    {
        if (colorSwap == null) return;
        // 0.7.3 白底材质 (noteSkins/*) 由 rgbShader 负责染色。applyLaneColor 刷新
        // colorSwap 本身会走进这里, 不能让它把已经挂载的 RGB 着色器覆盖成 ColorSwap——
        // 否则 Note 会退回白底未着色状态。
        if (rgbShader != null && rgbShader.enabled && !rgbShader.forceDisabled && ClientPrefs.data.shaders)
            return;
        // perfMode 关闭时保持提交前行为：始终挂 colorSwap.shader，
        // 不因“中性色”而省略着色器，脚本/渲染路径与旧逻辑一致。
        var target:FlxShader = (ClientPrefs.data.perfMode && colorSwap.isNeutral()) ? null : colorSwap.shader;
        if (shader != target)
            shader = target;
    }

    /** 万级 Note 合批: 与引擎快速路径同条件, 但支持等比缩放 (0.7/mania 缩放的音符)。 */
    static var _fastDrawMatrix:FlxMatrix = new FlxMatrix();

    override function draw():Void
    {
        if (ClientPrefs.data.perfMode
            && FlxG.renderTile && !pixelPerfectPosition && cameras != null && cameras.length == 1
            && alpha > 0 && angle == 0 && scale.x == scale.y && scale.x != 0
            && !isSustainNote && sustainLength <= 0 && clipRect == null
            && !flipX && !flipY && blend == null && shader == null)
        {
            @:privateAccess
            {
                checkEmptyFrame();
                if (alpha > 0 && _frame != null && _frame.type != FlxFrameType.EMPTY && frames != null
                    && _frame.angle == FlxFrameAngle.ANGLE_0 && !_frame.flipX && !_frame.flipY
                    && (animation.curAnim == null || (!animation.curAnim.flipX && !animation.curAnim.flipY)))
                {
                    if (dirty)
                        calcFrame(useFramePixels);

                    final cam:FlxCamera = cameras[0];
                    if (cam.visible && cam.exists && !isPixelPerfectRender(cam))
                    {
                        final s:Float = scale.x;
                        final sx:Float = x - cam.scroll.x * scrollFactor.x - offset.x;
                        final sy:Float = y - cam.scroll.y * scrollFactor.y - offset.y;
                        // 与 drawComplex(angle=0 无翻转) 矩阵结果一致:
                        // destTL = screenPos - offset + origin*(1-scale)   (centerOrigin + updateHitbox 时化简为 screenPos)
                        final dx:Float = sx + origin.x * (1 - s);
                        final dy:Float = sy + origin.y * (1 - s);
                        if (dx + width > cam.viewOffsetX && dx < cam.viewOffsetWidth
                            && dy + height > cam.viewOffsetY && dy < cam.viewOffsetHeight)
                        {
                            _fastDrawMatrix.identity();
                            _fastDrawMatrix.scale(s, s);
                            _fastDrawMatrix.translate(dx + _frame.offset.x * s, dy + _frame.offset.y * s);

                            final ct:ColorTransform = colorTransform;
                            final isColored:Bool = (ct != null && ct.hasRGBMultipliers());
                            final hasOffsets:Bool = (ct != null && ct.hasRGBAOffsets());
                            final item = cam.startQuadBatch(_frame.parent, isColored, hasOffsets, blend, antialiasing, null);
                            item.addQuad(_frame, _fastDrawMatrix, ct);
                        }
                    }
                    return;
                }
            }
        }
        super.draw();
    }

    /**
     * 0.7.3/1.0.4 兼容: 获取某条轨道的共享 RGB 色板 (按 noteData+mania 缓存)。
     * 多k: 轨道颜色用基底纹理色 (SPACE 轨道映射为 UP, 保证只用原版资源)。
     */
    public static function initializeGlobalRGBShader(noteData:Int, ?mania:Int):RGBPalette
    {
        var m:Int = EKData.clampMania(mania != null ? mania : PlayState.mania);
        var lane:Int = Std.int(Math.abs(noteData));
        var key:Int = lane + m * 64;
        if (globalRgbShaders[key] == null)
        {
            var newRGB:RGBPalette = new RGBPalette();
            globalRgbShaders[key] = newRGB;
            // 0.7.3 多k 着色: 颜色槽按轨道字母映射 (A~I → 0~8, J~R 循环回 A~I),
            // 与 EKData.getLaneColorSwap 的 flat 路径 (letterColorIndex) 完全一致。
            // 不能用 noteData 线性取模: 5K/6K/7K/8K 等非 9 键布局里 E/F/G/H/I
            // 的排位不同 (如 8K 第 5 轨是 F/left1, 取模会落到 SPACE 槽), 会错色。
            var arrLen:Int = (ClientPrefs.data.arrowRGB != null) ? ClientPrefs.data.arrowRGB.length : 4;
            if (arrLen < 1) arrLen = 4;
            var colorIdx:Int = lane % arrLen;
            var mapped:Null<Int> = EKData.letterColorIndex.get(EKData.getLetter(m, lane));
            if (mapped != null && mapped >= 0 && mapped < arrLen)
                colorIdx = mapped;
            var arr:Array<FlxColor> = (!PlayState.isPixelStage) ? ClientPrefs.data.arrowRGB[colorIdx] : ClientPrefs.data.arrowRGBPixel[colorIdx];
            if (arr != null && arr.length >= 3)
            {
                newRGB.r = arr[0];
                newRGB.g = arr[1];
                newRGB.b = arr[2];
            }
        }
        return globalRgbShaders[key];
    }

    public function new(?strumTime:Float = 0, ?noteData:Int = 0, ?prevNote:Note, ?sustainNote:Bool = false, ?inEditor:Bool = false, ?skipTexture:Bool = false) {
        super();
        initNote(strumTime, noteData, prevNote, sustainNote, inEditor, skipTexture);
    }

    /**
     * Constructor body, shared by new and fromPool so the two paths
     * can't drift apart.
     */
    function initNote(strumTime:Float, noteData:Int, prevNote:Note, sustainNote:Bool, inEditor:Bool, skipTexture:Bool):Void {
        mania = PlayState.mania;
        // 不再让 prevNote 自指成环（prevNote=this）。首段 sustain 的 prevNote 保持 null，
        // 逻辑上与原自引用完全等价（见 EditorPlayState，其 prevNote 判空后结果一致），
        // 但避免构造阶段对自身执行无谓的动画/缩放操作，以及 nextNote 自环。
        this.prevNote = prevNote;
        isSustainNote = sustainNote;
        this.inEditor = inEditor;

        x += (ClientPrefs.data.middleScroll ? PlayState.STRUM_X_MIDDLESCROLL : PlayState.STRUM_X) + 50;
        y -= 2000;
        this.strumTime = strumTime;
        if(!inEditor) this.strumTime += ClientPrefs.data.noteOffset;
        this.noteData = noteData;

        if(noteData > -1) {
            // 先创建着色器容器, 再触发纹理加载 (reloadNote 内部会 applyLaneColor 设置轨道色)。
            // 中性色不挂 GLSL 程序: 万级 Note 时按 shader 实例分批会把同贴图拆成数千 draw call。
            colorSwap = makeColorSwap();
            wireColorSwap();
            // 0.7.3/1.0.4 兼容: 懒挂载的 RGB 引用, 默认回退到 colorSwap;
            // 脚本修改 rgbShader.r/g/b/mult 时才克隆并接管精灵着色器。
            rgbShader = new RGBShaderReference(this, initializeGlobalRGBShader(noteData));
            rgbShader.fallbackColorSwap = colorSwap;
            // 编辑器/预览环境 (PlayState.instance == null) 始终跟随谱面 disableNoteRGB,
            // 玩家 noteRGBMode 只在真实游玩时生效。
            if (PlayState.SONG != null && (PlayState.instance == null ? PlayState.SONG.disableNoteRGB
                    : ClientPrefs.noteRGBDisabled(PlayState.SONG.disableNoteRGB)))
                rgbShader.forceDisabled = true;
            if(!skipTexture) texture = '';
            x += swagWidth * noteData;
            if(!skipTexture && !isSustainNote && noteData > -1) {
                animation.play(colArray[baseTex()] + 'Scroll');
            }
        }

        if(prevNote != null) prevNote.nextNote = this;

        if(isSustainNote && prevNote != null) {
            alpha = 0.6;
            multAlpha = 0.6;
            hitsoundDisabled = true;
            isSustainEnd = true;
            if(ClientPrefs.data.downScroll) flipY = true;

            offsetX += width / 2;
            copyAngle = false;
            animation.play(colArray[baseTex()] + 'holdend');
            updateHitbox();
            offsetX -= width / 2;
            if(PlayState.isPixelStage) offsetX += 30 * Note.getManiaScale(mania);

            if(prevNote.isSustainNote) {
                isSustainEnd = false;
                prevNote.animation.play(colArray[prevNote.baseTex()] + 'hold');
                prevNote.scale.y *= Conductor.stepCrochet / 100 * 1.05;
                if(!PlayState.isPixelStage) prevNote.scale.y *= (44.0 / prevNote.frameHeight);
                if(PlayState.instance != null) prevNote.scale.y *= PlayState.instance.songSpeed;
                if(PlayState.isPixelStage) {
                    prevNote.scale.y *= 1.19;
                    prevNote.scale.y *= (6 / prevNote.frameHeight);
                } else {
                    prevNote.scale.y += (2.0 / prevNote.frameHeight);
                }
                prevNote.updateHitbox();
            }
            if(PlayState.isPixelStage) {
                scale.y *= PlayState.daPixelZoom;
                updateHitbox();
            }
        } else if(!isSustainNote) {
            earlyHitMult = 1;
        }
        x += offsetX;
    }

    /** Note pool singleton; 16384 covers basically any chart. */
    public static var pool:ObjectPool<Note> = null;

    static function ensurePool():ObjectPool<Note>
    {
        if (pool == null)
        {
            pool = new ObjectPool<Note>(
                // noteData = -1：池中空闲 Note 不创建 ColorSwap/RGBShader，真正借出时 reinitForPool 会按实际 noteData 创建。
                function() return new Note(0, -1, null, false, false, true),
                null, // release-side cleanup lives in releaseToPool
                null,
                16384
            );
        }
        return pool;
    }

    /** Borrow + fully rebuild (same as new Note(...)). */
    public static function fromPool(?strumTime:Float = 0, ?noteData:Int = 0, ?prevNote:Note, ?sustainNote:Bool = false, ?inEditor:Bool = false, ?skipTexture:Bool = false):Note
    {
        var note:Note = ensurePool().borrow();
        note.reinitForPool(strumTime, noteData, prevNote, sustainNote, inEditor, skipTexture);
        return note;
    }

    /**
     * Rebuild a pooled instance: reset FlxSprite state -> revive -> run the
     * constructor body again. render resources were freed on release, but the
     * FlxSprite structure (scale/offset/origin/animation) is still valid.
     */
    function reinitForPool(strumTime:Float, noteData:Int, prevNote:Note, sustainNote:Bool, inEditor:Bool, skipTexture:Bool):Void
    {
        revive();
        sourceIndex = -1;
        pooled = false;

        x = 0;
        y = 0;
        scale.set(1, 1);
        offset.set(0, 0);
        origin.set(0, 0);
        flipX = false;
        flipY = false;
        angle = 0;
        alpha = 1;
        visible = true;
        color = 0xFFFFFFFF;
        velocity.set(0, 0);
        acceleration.set(0, 0);
        drag.set(0, 0);
        angularVelocity = 0;
        angularDrag = 0;
        scrollFactor.set(1, 1);
        bakedRotationAngle = 0;
        blend = BlendMode.NORMAL;

        initNote(strumTime, noteData, prevNote, sustainNote, inEditor, skipTexture);
    }

    /**
     * Return to the pool, called from the song teardown (scripts stopped).
     *
     * Not a full destroy(): that nulls scale/offset/origin and the revive
     * path derefs them. Instead we release just the render resources
     * (graphic=null drops useCount, same accounting as the zombie guard)
     * and keep the FlxSprite structure intact.
     */
    /**
     * Reset a Note for reuse without returning it to the static pool.
     * Used by PlayState's per-state notePool (H-Slice style recycling).
     * @return false if the Note was already fully destroyed and cannot be reused.
     */
    public function resetForReuse():Bool
    {
        // A fully-destroyed instance can't revive (scale/offset/origin are
        // null and updateHitbox/loadGraphic would crash). Notes killed
        // mid-song fall here; just drop them for GC.
        if (scale == null)
            return false;

        // ── reset FlxSprite transform state (same as reinitForPool) ──
        x = 0;
        y = 0;
        scale.set(1, 1);
        offset.set(0, 0);
        origin.set(0, 0);
        flipX = false;
        flipY = false;
        angle = 0;
        alpha = 1;
        visible = true;
        color = 0xFFFFFFFF;
        velocity.set(0, 0);
        acceleration.set(0, 0);
        drag.set(0, 0);
        angularVelocity = 0;
        angularDrag = 0;
        scrollFactor.set(1, 1);
        bakedRotationAngle = 0;
        blend = BlendMode.NORMAL;

        // ── clear Note-level state (setupNoteData redoes most of it) ──
        extraData.clear();
        tail = [];
        prevNote = null;
        nextNote = null;
        noteColorOverride = null;
        customCharAnim = null;
        noteSplashTexture = null;
        noteSplashDisabled = false;
        noteSplashHue = 0;
        noteSplashSat = 0;
        noteSplashBrt = 0;
        noteType = null;
        // 保留 texture 输入值 (不再强制置 null): setupNoteData 的 texture setter
        // 按值比较, 相同材质直接跳过 reloadNote —— 原先每次池复用都会整趟重取图集 +
        // 重建动画 (万级 NPS 下每帧上千次复用, 是持续段的主要 CPU 开销之一)。
        // 材质真正变化时 setter 照常触发 reload, Lua setNoteTexture 兼容性不变。
        eventName = '';
        eventVal1 = '';
        eventVal2 = '';
        eventLength = 0;
        rating = 'unknown';
        ratingRaw = 'unknown';
        ratingMod = 0;
        ratingDisabled = false;
        sourceIndex = -1;
        pooled = false;
        culled = false;
        visible = true;
        spawned = false;
        wasGoodHit = false;
        hitByOpponent = false;
        missed = false;
        noteWasHit = false;
        wasHit = false;
        tooLate = false;
        canBeHit = false;
        active = false;
        canHold = false;
        sustainLength = 0;
        parentST = 0;
        parentSL = 0;
        ignoreNote = false;
        blockHit = false;
        lowPriority = false;
        hitCausesMiss = false;
        hitsoundDisabled = false;
        earlyHitMult = 0.5;
        lateHitMult = 1;
        distance = 2000;
        animSuffix = '';
        noAnimation = false;
        noMissAnimation = false;
        gfNote = false;
        doOppStuff = false;
        lastNoteOffsetXForPixelAutoAdjusting = 0;
        _animCacheKey = null;

        // ── release render resources (keep the FlxSprite structure) ──
        if (animation != null)
        {
            animation.curAnim = null;
            animation.destroyAnimations();
        }
        frames = null;
        graphic = null;      // set_graphic: oldGraphic.useCount--
        _frame = null;
        _frameGraphic = null;
        clipRect = null;
        shader = null;
        colorSwap = null;
        rgbShader = null;
        // colorTransform/useColorTransform are managed by FlxSprite.set_color;
        // the color reset in reinitForPool restores the default.

        kill();
        return true;
    }

    public function releaseToPool():Void
    {
        if (!resetForReuse())
            return;
        ensurePool().release(this);
    }

    var lastNoteOffsetXForPixelAutoAdjusting:Float = 0;

    /**
     * 计算并保存当前 (图集, 类型) 的动画缓存基键到 this._animCacheKey。
     * 供 loadNoteAnims / loadPixelNoteAnims 中的 addCachedAnim 复用帧序列。
     */
    inline function setAnimCacheKey(blahblah:String):Void
    {
        _animCacheKey = blahblah + (isSustainNote ? '::s' : '::n');
    }

    /**
     * 复用已缓存的帧序列添加动画；未缓存则先 addByPrefix 并缓存其帧序列。
     * 这样每个 Note 仍独立拥有动画对象（flixel 动画 per-sprite），但避免重复扫描帧前缀。
     */
    inline function addCachedAnim(name:String, prefix:String):Void
    {
        var key:String = (_animCacheKey != null ? _animCacheKey : '') + '::' + name;
        var cached:Array<Int> = noteAnimFrames.get(key);
        if (cached == null)
        {
            animation.addByPrefix(name, prefix);
            var anim = animation.getByName(name);
            if (anim != null)
            {
                cached = anim.frames;
                noteAnimFrames.set(key, cached);
            }
        }
        else
        {
            animation.add(name, cached, 30, true);
        }
    }

    public function reloadNote(?prefix:String = '', ?texture:String = '', ?suffix:String = '') {
        if(prefix == null) prefix = '';
        if(texture == null) texture = '';
        if(suffix == null) suffix = '';

          var skin:String = texture;
          if(texture.length < 1) {
              // 空安全: 选项菜单/编辑器里 PlayState.SONG 可能为 null
              skin = (PlayState.SONG != null) ? PlayState.SONG.arrowSkin : null;
              if(skin == null || skin.length < 1) skin = defaultNoteSkin;
          }

        var animName:String = (animation.curAnim != null) ? animation.curAnim.name : null;
        var arraySkin:Array<String> = skin.split('/');
        arraySkin[arraySkin.length-1] = prefix + arraySkin[arraySkin.length-1] + suffix;
        var lastScaleY:Float = scale.y;
        var blahblah:String = arraySkin.join('/');

        // 0.7.3+ 自由换皮肤: 用户选择的 noteSkin 追加到材质名末尾 (仅当文件存在时)。
        // 优先直接匹配: 新版材质是 noteSkins/NOTE_assets-<skin>,
        // 旧版材质是 NOTE_assets-<skin> (模组可以提供旧版皮肤文件)。
        // 旧版材质 (noteStyle=Old) 绝不回退到 noteSkins/* —— 那会把旧版强行切回新版材质;
        // 旧版皮肤文件不存在时保持旧版默认材质。
        var skinPostfix:String = Note.getNoteSkinPostfix();
        if (skinPostfix.length > 0)
        {
            var direct:String = blahblah + skinPostfix;
            if (Paths.fileExists('images/' + direct + '.png', IMAGE))
                blahblah = direct;
            else if (ClientPrefs.data.noteStyle == 'New' && !blahblah.startsWith('noteSkins/'))
            {
                var prefixed:String = 'noteSkins/' + blahblah + skinPostfix;
                if (Paths.fileExists('images/' + prefixed + '.png', IMAGE))
                    blahblah = prefixed;
            }
        }
        // 像素长条的材质名约定是 "基底+ENDS+皮肤后缀" (pixelUI/noteSkins/NOTE_assetsENDS-chip),
        // 而不是 "基底+皮肤后缀+ENDS" (NOTE_assets-chipENDS)。引擎自带资源与导出包都按前者命名,
        // 这里按正确顺序构造; 找不到时回退原拼接, 兼容旧资源/模组沿用后者命名的文件。
        var pixelEndsSkin:String = blahblah + 'ENDS';
        if (skinPostfix.length > 0 && blahblah.endsWith(skinPostfix))
        {
            var baseWithoutPostfix:String = blahblah.substr(0, blahblah.length - skinPostfix.length);
            var corrected:String = baseWithoutPostfix + 'ENDS' + skinPostfix;
            if (corrected != pixelEndsSkin && Paths.fileExists('images/pixelUI/' + corrected + '.png', IMAGE))
                pixelEndsSkin = corrected;
        }
        setAnimCacheKey(blahblah);

        if(PlayState.isPixelStage) {
            if(isSustainNote) {
                loadGraphic(Paths.image('pixelUI/' + pixelEndsSkin));
                width = width / 4;
                height = height / 2;
                originalHeightForCalcs = height;
                loadGraphic(Paths.image('pixelUI/' + pixelEndsSkin), true, Math.floor(width), Math.floor(height));
            } else {
                loadGraphic(Paths.image('pixelUI/' + blahblah));
                width = width / 4;
                height = height / 5;
                loadGraphic(Paths.image('pixelUI/' + blahblah), true, Math.floor(width), Math.floor(height));
            }
            setGraphicSize(Std.int(width * PlayState.daPixelZoom * (PlayState.isPixelStage ? EKData.pixelScales[mania] / EKData.pixelScales[3] : 1)));
            loadPixelNoteAnims();
            antialiasing = false;
            if(isSustainNote) {
                offsetX += lastNoteOffsetXForPixelAutoAdjusting;
                lastNoteOffsetXForPixelAutoAdjusting = (width - 7) * (PlayState.daPixelZoom / 2) * Note.getManiaScale(mania);
                offsetX -= lastNoteOffsetXForPixelAutoAdjusting;
            }
		} else {
			frames = Paths.getSparrowAtlas(blahblah);
			if (frames != null)
			{
				loadNoteAnims();
				antialiasing = ClientPrefs.data.globalAntialiasing;
			}
		}
        if(isSustainNote) scale.y = lastScaleY;
        updateHitbox();

        // 材质溯源同步: 让 texture 字段始终反映"当前 frames 由哪种输入加载而来",
        // 池化复用时 setupNoteData 的按值比较才能安全跳过重载。
        // - 空 prefix/suffix (含 PlayState/Lua 的直接调用): 输入本身可复现 → 存原输入;
        // - 带 prefix/suffix (如 'HURT' 变体): 不可由输入复现 → 存哨兵值,
        //   下一次复用比较必然不等, 强制走一次正常重载恢复基础材质。
        var directVariant:Bool = ((prefix != null && prefix.length > 0) || (suffix != null && suffix.length > 0));
        // 注意: 本函数的参数名 texture 遮蔽了属性本身, 必须用 this.texture + bypass
        // 直接写底层字段, 否则会再次触发 set_texture 造成递归重载。
        var provenance:String = directVariant ? ('__direct__' + blahblah) : texture;
        @:bypassAccessor this.texture = provenance;
        if(animName != null) animation.play(animName, true);
        if(inEditor) {
            setGraphicSize(ChartingState.GRID_SIZE, ChartingState.GRID_SIZE);
            updateHitbox();
        }
        // 脚本显式传入非默认纹理 -> 关闭多k 调色 (模组自定义 Note 不着色)
        if (texture.length > 0 && texture != 'NOTE_assets')
            applyLaneColorShader = false;

        // 0.7.3 材质兼容: noteSkins/* 是白底图集, 必须用 RGB 着色器 (rgbShader) 染色;
        // 0.6.3 flat 图集自带箭头颜色, 继续用 ColorSwap (arrowHSV)。
        var usesPsych073Skin:Bool = (blahblah != null && blahblah.startsWith('noteSkins/'));
        if (usesPsych073Skin)
        {
            // 保留 colorSwap 对象作为 rgbShader 的回退, 默认染色交给 RGB 色板 (arrowRGB)
            if (rgbShader != null)
            {
                rgbShader.fallbackColorSwap = colorSwap;
                rgbShader.enabled = true;
            }
        }
        else if (applyLaneColorShader)
        {
            if (rgbShader != null) rgbShader.enabled = false;
            // 需要染色时确保着色器存在 (含从 Hurt/自定义纹理恢复的情况)
            if (colorSwap == null && noteData > -1 && noteType != 'Hurt Note')
            {
                colorSwap = makeColorSwap();
                wireColorSwap();
            }
            if (colorSwap != null && noteData > -1)
                applyLaneColor();
        }
        else
        {
            if (rgbShader != null) rgbShader.enabled = false;
            if (colorSwap != null)
            {
                colorSwap = null;
                shader = null;
            }
        }
        // 非 0.7.3 材质时, rgbShader 的回退指向 colorSwap / 原始材质 (无着色器)
        if (rgbShader != null && !usesPsych073Skin)
            rgbShader.fallbackShader = (colorSwap != null) ? colorSwap.shader : null;
    }

    function loadNoteAnims() {
        var b:Int = (noteData >= 0) ? baseTex() : 0;
        addCachedAnim(colArray[b] + 'Scroll', colArray[b] + '0');
        if(isSustainNote) {
            addCachedAnim('purpleholdend', 'pruple end hold');
            addCachedAnim(colArray[b] + 'holdend', colArray[b] + ' hold end');
            addCachedAnim(colArray[b] + 'hold', colArray[b] + ' hold piece');
        }
        setGraphicSize(Std.int(width * 0.7 * Note.noteScale(mania)));
        updateHitbox();
    }

    function loadPixelNoteAnims() {
        var b:Int = (noteData >= 0) ? baseTex() : 0;
        if(isSustainNote) {
            pixAddAnim(colArray[b] + 'holdend', [pixelInt[b] + 4]);
            pixAddAnim(colArray[b] + 'hold', [pixelInt[b]]);
        } else {
            pixAddAnim(colArray[b] + 'Scroll', [pixelInt[b] + 4]);
        }
    }

    /** 像素音符动画以显式帧数组注册，同样走帧序列缓存避免重复分配。 */
    inline function pixAddAnim(name:String, frames:Array<Int>):Void
    {
        var key:String = (_animCacheKey != null ? _animCacheKey : '') + '::pix::' + name;
        if (!noteAnimFrames.exists(key))
            noteAnimFrames.set(key, frames);
        // 像素动画始终以显式帧数组 add，按 sprite 独立注册（缓存仅用于去重复创建无谓对象）
        animation.add(name, frames, 30, true);
    }

    public function setupNoteData(chartNoteData:PreloadedChartNote):Void {
        // 自愈: 池化复用/异常路径下 frames 缺失时强制重载一次, 避免空帧参与渲染。
        if (frames == null || this.frame == null) {
            @:bypassAccessor texture = null;
        }
        wasGoodHit = false;
        hitByOpponent = false;
        tooLate = false;
        canBeHit = false;
        // 多k: 优先使用谱面解析时按 Change Mania 事件算出的 k 快照
        mania = (chartNoteData.mania >= 0) ? EKData.clampMania(chartNoteData.mania) : PlayState.mania;

        strumTime = chartNoteData.strumTime;
        noteData = chartNoteData.noteData;
        isSustainNote = chartNoteData.isSustainNote;
        isSustainEnd = chartNoteData.isSustainEnd;
        sustainLength = chartNoteData.sustainLength;
        genStepCrochet = chartNoteData.stepCrochet;

        multSpeed = chartNoteData.multSpeed;
        multAlpha = chartNoteData.multAlpha;
        noteDensity = chartNoteData.noteDensity;
        if(!inEditor) strumTime += ClientPrefs.data.noteOffset;

        active = true;
        offsetX = chartNoteData.offsetX;
        offsetY = chartNoteData.offsetY;
        lastNoteOffsetXForPixelAutoAdjusting = 0; // Reset on reuse so pixel sustain X never accumulates.
        offsetAngle = 0;
        copyX = true;
        copyY = true;
        copyAngle = true;
        copyAlpha = true;
        flipY = false;
        angle = 0;
        alpha = 1;
        clipRect = null;
        distance = 2000;
        earlyHitMult = 0.5;
        lateHitMult = 1;
        hitsoundDisabled = chartNoteData.hitsoundDisabled;
        lowPriority = false;
        blockHit = false;
        ignoreNote = false;
        hitCausesMiss = false;
        noAnimation = chartNoteData.noAnimation;
        noMissAnimation = chartNoteData.noMissAnimation;
        gfNote = false;
        animSuffix = '';

        x = (ClientPrefs.data.middleScroll ? PlayState.STRUM_X_MIDDLESCROLL : PlayState.STRUM_X) + 50 + Note.swagWidth * noteData;
        y = -2000;

        // 多k: 池化复用 Note 时确保着色器存在
        applyLaneColorShader = true; // 复用后恢复默认 (Hurt/自定义纹理由后续 noteType/texture 重新决定)
        if(colorSwap == null) {
            colorSwap = makeColorSwap();
            wireColorSwap();
        }
        // 0.7.3/1.0.4 兼容: 重新绑定轨道色板 (池化复用/换 k 值后轨道色可能变化)。
        // 先确保 rgbShader 存在，再设 fallback/rebind，避免池化复用 releaseToPool 置空后空引用。
        if (rgbShader == null)
            rgbShader = new RGBShaderReference(this, initializeGlobalRGBShader(chartNoteData.noteData, mania));
        else
            rgbShader.rebind(initializeGlobalRGBShader(chartNoteData.noteData, mania));
        rgbShader.fallbackColorSwap = colorSwap;
        rgbShader.forceDisabled = ClientPrefs.noteRGBDisabled(PlayState.SONG != null && PlayState.SONG.disableNoteRGB);
        noteColorOverride = null;
        customCharAnim = null;

        var ns:String = chartNoteData.noteskin;
        var tx:String = chartNoteData.texture;
        var targetTexture:String = '';
        if(ns.length > 0) targetTexture = ns;
        else if(tx.length > 0) targetTexture = tx;

        animation.curAnim = null;
        this.texture = targetTexture;

        noteType = chartNoteData.noteType;
        animSuffix = chartNoteData.animSuffix;
        noAnimation = chartNoteData.noAnimation;
        noMissAnimation = chartNoteData.noMissAnimation;
        mustPress = chartNoteData.mustPress;
        doOppStuff = chartNoteData.oppNote;
        gfNote = chartNoteData.gfNote;
        lowPriority = chartNoteData.lowPriority;
        noteSplashDisabled = chartNoteData.noteSplashDisabled;
        // 必须在 noteType setter 之后写入，避免 setter 用轨道色覆盖自定义溅射颜色。
        // 只有 Lua 显式设置过才覆盖；未设置保持 noteType setter 算出的轨道色溅射。
        if (chartNoteData.noteSplashTexture != null)
            noteSplashTexture = chartNoteData.noteSplashTexture;
        if (chartNoteData.noteSplashHue != null)
            noteSplashHue = chartNoteData.noteSplashHue;
        if (chartNoteData.noteSplashSat != null)
            noteSplashSat = chartNoteData.noteSplashSat;
        if (chartNoteData.noteSplashBrt != null)
            noteSplashBrt = chartNoteData.noteSplashBrt;

        if(isSustainNote) {
            parentST = chartNoteData.parentST;
            parentSL = chartNoteData.parentSL;
        }

        hitHealth = chartNoteData.hitHealth;
        missHealth = chartNoteData.missHealth;
        hitCausesMiss = chartNoteData.hitCausesMiss;
        ignoreNote = chartNoteData.ignoreNote;
        blockHit = chartNoteData.blockHit;

        applyLaneColor();

        var b:Int = (noteData >= 0) ? baseTex() : 0;

        if(isSustainNote) {
            alpha = 0.6;
            multAlpha = 0.6;
            if(!chartNoteData.hitsoundDisabled) hitsoundDisabled = true;
            if(ClientPrefs.data.downScroll) flipY = true;
            offsetX += width / 2;
            copyAngle = false;

            var animToPlay:String = colArray[b] + (chartNoteData.isSustainEnd ? 'holdend' : 'hold');
            animation.play(animToPlay);
            updateHitbox();
            offsetX -= width / 2;

            if(!chartNoteData.isSustainEnd) {
                if(PlayState.instance != null) {
                    var stepCrochet:Float = (genStepCrochet > 0) ? genStepCrochet : Conductor.stepCrochet;
                    var songSpeedVal:Float = PlayState.instance.songSpeed;
                    scale.y = (stepCrochet / 100) * 1.05 * songSpeedVal * multSpeed * Note.getManiaScale(mania);
                    // 皮肤自适应: 非默认帧高时按 (44/frameHeight) 归一化 (默认皮肤行为不变)
                    if(!PlayState.isPixelStage) scale.y *= (44.0 / frameHeight);
                    if(!PlayState.isPixelStage) scale.y += (2.0 / frameHeight);
                    if(PlayState.isPixelStage) {
                        scale.y *= 1.19;
                        scale.y *= (6 / frameHeight);
                    }
                    updateHitbox();
                }
            } else {
                scale.y = Note.getManiaScale(mania);
                updateHitbox();
            }
        } else {
            earlyHitMult = 1;
            animation.play(colArray[b] + 'Scroll');
            if(!copyAngle) copyAngle = true;
        }
         // Visibility (don't override alpha set above)

        if(PlayState.isPixelStage && isSustainNote) {
                scale.y *= PlayState.daPixelZoom;
                updateHitbox();
        }

        if (isSustainNote && PlayState.isPixelStage)
        {
            // Scale the pixel sustain centering by mania (4K = 1.0; smaller arrows in high-K).
            offsetX += 30 * Note.getManiaScale(mania);
        }

        if(!mustPress) visible = ClientPrefs.data.opponentStrums;
        else if(!visible) visible = true;
    }

    inline public function followStrum(strum:StrumNote, songSpeed:Float):Void {
        distance = (0.45 * (Conductor.songPosition - strumTime) * songSpeed * multSpeed) * Note.getManiaScale(mania);
        if(!strum.downScroll) distance *= -1;

        if(copyAngle) angle = strum.direction - 90 + strum.angle + offsetAngle;
        if(copyAlpha) alpha = strum.alpha * multAlpha;

        if(copyX) x = strum.x + offsetX + Math.cos(strum.direction * Math.PI / 180) * distance;

        if(copyY) {
			y = strum.y + offsetY + Math.sin(strum.direction * Math.PI / 180) * distance;

			if(isSustainNote) {
                //傻逼吧
			}
		}
    }

    public function clipToStrumNote(myStrum:StrumNote):Void {
        if(!isSustainNote || (!mustPress && ignoreNote) || (mustPress && !wasGoodHit && canBeHit)) return;

        final center:Float = myStrum.y + offsetY + (swagWidth / 2) * Note.getManiaScale(mania);
        if(clipRect == null) clipRect = FlxRect.get(0, 0, frameWidth, frameHeight);
        final swagRect = clipRect;

        if(myStrum.downScroll) {
            if(y - offset.y * scale.y + height >= center) {
                swagRect.height = (center - y) / scale.y;
                swagRect.y = frameHeight - swagRect.height;
                swagRect.width = frameWidth;
            }
        } else {
            if(y + offset.y * scale.y <= center) {
                swagRect.y = (center - y) / scale.y;
                swagRect.height = (height / scale.y) - swagRect.y;
                swagRect.width = width / scale.x;
            }
        }

        @:bypassAccessor clipRect = swagRect;
        @:privateAccess if(frame != null && _frame != null)
            _frame = frame.clipTo(swagRect, _frame);
        dirty = true;
    }

    override function update(elapsed:Float) {
        super.update(elapsed);
        if(isSustainNote && animation.curAnim != null) {
            isSustainEnd = animation.curAnim.name.endsWith('end') || animation.curAnim.name.endsWith('holdend');
        }
        if(mustPress) {
            canBeHit = (strumTime > Conductor.songPosition - (Conductor.safeZoneOffset * lateHitMult)
                && strumTime < Conductor.songPosition + (Conductor.safeZoneOffset * earlyHitMult));
            if(strumTime < Conductor.songPosition - Conductor.safeZoneOffset && !wasGoodHit)
                tooLate = true;
        } else {
            canBeHit = false;
            if(strumTime < Conductor.songPosition + (Conductor.safeZoneOffset * earlyHitMult)) {
                if((isSustainNote && prevNote.wasGoodHit) || strumTime <= Conductor.songPosition)
                    wasGoodHit = true;
            }
        }
        if(tooLate && !inEditor && alpha > 0.3) alpha = 0.3;
    }

    // ==================== Online additions (appended at the end of the class) ====================
    #if ONLINE_ALLOWED
    /**
     * `Note.maniaKeys` is "how many keys does the *current chart* use".
     * This engine models multi-key differently: `PlayState.mania` is a 0-based index into
     * `Note.ammo`, `Note.ammo[mania]` is the key count (ammo[3] == 4), and each Note carries its
     * own `mania` snapshot so "Change Mania" events can mix key counts inside one chart.
     *
     * `maniaKeys` is therefore exposed as a READ-ONLY property derived from `PlayState.mania`,
     * which keeps one source of truth and is exactly what the single consumer needs:
     *   * online/ChartAnalyzer.hx uses `Note.maniaKeys` to split raw chart notes into lanes
     *     (`note[1] % Note.maniaKeys`) and to interpret the opponent/player side offset.
     * No setter side effects are needed: lane colours here come from
     * `EKData.letterColorIndex` / `EKData.getLaneColorSwap`.
     *
     *
     * Deliberately appended at the END of the class: every line inserted above an existing member
     * shifts the source line numbers Haxe embeds in HXDLIN()/HX_LOCAL_STACK_FRAME(), which would
     * change the generated C++ even with the macro off. Keeping this block line-for-line stable
     * has the same reason.
     */
    public static var maniaKeys(get, never):Int;
    static function get_maniaKeys():Int {
        return ammo[EKData.clampMania(PlayState.mania)];
    }

    /**
     * Building a `new Note(0, 0)` just to read `hitCausesMiss` is far too heavy in this
     * engine: `Note` construction builds ColorSwap + RGBShaderReference + an animation, and the
     * setter's 'Hurt Note' branch calls `reloadNote('HURT')`, i.e. it would decode note textures
     * just to answer one boolean.
     * boolean.
     *
     * The engine decides `hitCausesMiss` in exactly one place -- its own chart parser:
     *   PlayState.generateSong(): `var isHurt:Bool = (noteType == 'Hurt Note');`
     * so this helper is the same predicate without the allocation. Keep the two in sync if the
     * engine ever grows more miss-causing note types.
     */
    public static function chartNoteTypeCausesMiss(noteType:String):Bool {
        return noteType == 'Hurt Note';
    }

    /**
     * Counts how many remote opponents have driven this note and gates the per-session
     * `opponentNoteHitSID` path through `countOpponents()`.
     * Appended inside the existing ONLINE_ALLOWED block at the end of the class so the macro-off
     * translation unit is unchanged.
     * The value stays 0 in a single-player run, where no remote opponent drives notes.
     */
    public var hits:Int = 0;
    #end
    // ====================================================================================================
}
