package backend;

/**
 * 判定钟：把「按键事件自己的时间戳」换算成歌曲时间。
 *
 * 普通判定读 `Conductor.songPosition`，也就是这一帧的时间；按键却发生在帧之前
 * （最多一个逻辑步 16.7 ms），所以同一次物理按键的判定值会随手感帧率抖动。异步判定
 * 用 `KeyboardEvent.inputTimestampNs`（SDL 事件时间戳，和 `lime.system.System.getTimer`
 * 同一个钟）把「按下那一刻」还原出来，再换算到歌曲时间。
 *
 * 换算不能只做一次线性外推：音频钟（`FlxSound.time` → `AL_SAMPLE_OFFSET`）本身按混音
 * 周期量化，实测残差 p99 ≈ 17 ms（见 docs/audio-streaming.md §6）。直接拿它当锚点会把
 * 混音周期的锯齿原样搬进判定。这里做的是一个一阶锁相环：
 *
 *   - 每帧采一次 (nowTick, 音频位置)，算出预测残差；
 *   - 残差按比例并回锚点，单次修正上限 {@link MAX_CORRECTION_MS}（默认 0.5 ms），
 *     所以公布出去的钟没有跳变，只有 0.5 ms 以内的缓慢漂移；
 *   - 残差超过 {@link HARD_RELINK_MS}（默认 100 ms）说明位置被整体挪动过
 *     （seek / 变速 / 暂停恢复 / 重开），直接重锚，不做平滑。
 *
 * 稳态下锚点收敛到音频钟读数的平均值，也就是**保留**今天 `FlxG.sound.music.time`
 * 那份混音周期滞后（平均半个周期），只去掉「事件到逻辑步」那 0~16.7 ms。换句话说：
 * 打开异步判定后判定值平均前移约半个逻辑步，不会再多移半个混音周期，ratingOffset
 * 的既有校准继续成立。实测（30/60/144 逻辑帧，按 1024 帧混音周期模拟）残差 p99
 * 分别 ≈ 2.4 / 1.0 / 0.9 ms。
 */
class JudgeClock
{
	/** 残差超过这么多毫秒就认为位置被挪动过，直接重锚（不做平滑）。 */
	public static inline var HARD_RELINK_MS:Float = 100;
	/** 每次采样的修正上限（ms）。0.5 在 60 帧下等于 30 ms/s 的追平速度。 */
	public static inline var MAX_CORRECTION_MS:Float = 0.5;
	/** 残差并回锚点的比例（每采样一次）。0.05 在 60 帧下时间常数约 0.33 s。 */
	public static inline var RESIDUAL_GAIN:Float = 0.05;
	/** 两次采样间隔超过这么多毫秒视为停顿（暂停、卡顿、后台），重锚。 */
	public static inline var MAX_SAMPLE_GAP_MS:Float = 250;

	var _linked:Bool = false;
	var _anchorTick:Float = 0;
	var _anchorSong:Float = 0;
	var _rate:Float = 1;

	/** 重锚次数（诊断用：一首歌里正常只有 1 次，除非反复暂停/seek）。 */
	public var relinks:Int = 0;
	/** 最近一次采样算出的残差（ms，诊断用）。 */
	public var lastResidual:Float = 0;
	/** 最近一次残差绝对值的历史峰值（ms，诊断用）。 */
	public var maxAbsResidual:Float = 0;
	/** 采样次数（诊断用）。 */
	public var samples:Int = 0;

	public function new() {}

	public inline function linked():Bool
		return _linked;

	public inline function rate():Float
		return _rate;

	/** 丢掉锚点：之后的第一帧会重新锚定。 */
	public function reset():Void
	{
		_linked = false;
	}

	/**
	 * 采样一次。`nowTick` 与按键时间戳必须同域（`lime.system.System.getTimer` 毫秒），
	 * `audioPos` 是当前音乐播放位置（`FlxG.sound.music.time`）。
	 */
	public function sample(nowTick:Float, audioPos:Float, rate:Float):Void
	{
		var gap:Float = nowTick - _anchorTick;
		if (!_linked || gap < 0 || gap > MAX_SAMPLE_GAP_MS || rate != _rate)
		{
			link(nowTick, audioPos, rate);
			return;
		}

		var predicted:Float = songAt(nowTick);
		var residual:Float = audioPos - predicted;
		lastResidual = residual;

		var magnitude:Float = residual < 0 ? -residual : residual;
		if (magnitude > maxAbsResidual) maxAbsResidual = magnitude;

		if (magnitude > HARD_RELINK_MS)
		{
			link(nowTick, audioPos, rate);
			return;
		}

		var correction:Float = residual * RESIDUAL_GAIN;
		if (correction > MAX_CORRECTION_MS) correction = MAX_CORRECTION_MS;
		else if (correction < -MAX_CORRECTION_MS) correction = -MAX_CORRECTION_MS;

		_anchorSong = predicted + correction;
		_anchorTick = nowTick;
		samples++;
	}

	/** 把事件时间戳（`System.getTimer` 毫秒域）换算成歌曲时间。 */
	public inline function songAt(tick:Float):Float
	{
		return _anchorSong + (tick - _anchorTick) * _rate;
	}

	inline function link(nowTick:Float, audioPos:Float, rate:Float):Void
	{
		_linked = true;
		_anchorTick = nowTick;
		_anchorSong = audioPos;
		_rate = rate;
		relinks++;
	}
}
