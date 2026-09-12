#if seiun_turbo_harness
// Standalone benchmark harness (tools/turboharness) compiles this same file
// against a flixel-free stub of source/Note.hx. Engine builds take the normal path.
import PreloadedChartNote;
#else
import Note.PreloadedChartNote;
#end

/**
 * Turbo 模式的谱面预处理。
 *
 * 引擎只有一条渲染路径：真实 Note 精灵。所以"性能不够"永远等价于
 * "同时存活的精灵太多了"。低流速下这个问题最严重 —— 屏幕像素带 ±700px
 * 对应的可视频段是 1400 / (0.45 * songSpeed) 毫秒，speed=1 时约 3.1 秒，
 * speed=0.5 时约 6.2 秒；几千万 Note 的谱面在这个窗口里能塞进六位数条 Note，
 * 全部物化就是纯粹的浪费。
 *
 * 关键观察：同一轨道上两条 Note 如果屏幕间距小于一个像素级阈值，它们在玩家
 * 眼里、以及在实际绘制结果里就是同一条（Note 是不透明精灵，互相覆盖）。
 * 因此按"屏幕像素间距"而不是"时间间距"来合并，才是与流速自洽的口径：
 * 流速越低 -> 像素间距越小 -> 合并得越多 -> 物化量恒定，不随谱面密度爆炸。
 *
 * 本类只做无副作用的纯数据变换，不落盘、不缓存、不改谱面文件。
 */
typedef TurboGhostScratch = {
	var lastTime:Array<Float>;
	var lastRate:Array<Float>;
	var lastSlowRate:Array<Float>;
}

class TurboDensity
{
	/** 低于该屏幕间距的同轨同向 tap 视为同一条 Note（像素）。 */
	public static inline final DEFAULT_MIN_GAP_PX:Float = 4.0;

	/** 单条 Note 最多代表多少条原始 tap —— 为极端鬼谱面兜底，避免密度值失真。 */
	public static inline final MAX_REPRESENTED:Int = 512;

	/**
	 * 谱面内容指纹。
	 *
	 * 只包含"谱面自身"的字段：时间、轨道、判定归属、长度。刻意排除
	 * noteDensity —— 它是 collapseGhostNotes 的输出（被折叠的数量），
	 * 任何对同一数组重复调用都会改变它，导致指纹不稳定、任何由指纹派生的
	 * 持久化状态随之漂移。本类不再有缓存，指纹仅用于日志与诊断。
	 */
	public static function chartFingerprint(notes:Array<PreloadedChartNote>):Int
	{
		var h:Int = 0x811C9DC5;
		if (notes == null)
			return h;
		for (pn in notes)
		{
			if (pn == null)
			{
				h = (h * 31 + 0xFFFF) & 0x7FFFFFFF;
				continue;
			}
			h = (h * 31 + Std.int(pn.strumTime * 1000)) & 0x7FFFFFFF;
			h = (h * 31 + pn.noteData + pn.mania * 7) & 0x7FFFFFFF;
			h = (h * 31 + (pn.mustPress ? 2 : 0) + (pn.isSustainNote ? 4 : 0) + (pn.isSustainEnd ? 8 : 0) + (pn.gfNote ? 16 : 0)) & 0x7FFFFFFF;
			h = (h * 31 + Std.int(pn.sustainLength * 1000)) & 0x7FFFFFFF;
			h = (h * 31 + Std.int(pn.parentST * 1000)) & 0x7FFFFFFF;
		}
		return h;
	}

	/**
	 * 谱面加载期的 Turbo 预处理：把"屏幕上分不开"的 tap 折叠成一条代表 Note。
	 *
	 * 纯函数：不改写入参数组里的任何对象，也不依赖调用次数，重复调用结果完全一致
	 * （旧实现直接 `prev.noteDensity += 1` 改写共享对象，第二次调用结果不同，
	 * 指纹与由此派生的任何索引都会漂移）。
	 *
	 * 合并判据（同一 lane + 同一侧 mustPress + 同一 multSpeed，按时间相邻）：
	 *   屏幕间距 = Δt * 0.45 * songSpeed * multSpeed * maniaScale < minGapPx
	 * 间距取两条 Note 各自可见期内的较小值（以较慢的那条为准），因此对缓动/变速
	 * （songSpeedTween）也是保守安全的：只有当它们在任何时刻都不可能分开到
	 * minGapPx 以上时才合并。
	 *
	 * 代表 Note 保留折叠组里最早的一条（最先到判定线的那条，视觉上填补该像素带），
	 * 折叠数量累加到它的 noteDensity 上 —— 与既有判定加权口径一致
	 * （PlayState 结算时按 noteDensity 计 combo/判定数）。
	 *
	 * @param songSpeed  本局实际流速（PlayState.songSpeed）
	 * @param mania      本局 k 值（决定 maniaScale）
	 * @param rangeMs    额外的时间硬下限（鬼 Note 合并），默认 1.0ms
	 * @param minGapPx   屏幕像素间距阈值
	 */
	public static function collapseGhostNotes(notes:Array<PreloadedChartNote>, laneCount:Int,
		rangeMs:Float = 1.0, songSpeed:Float = 1.0, mania:Int = -1, minGapPx:Float = DEFAULT_MIN_GAP_PX):Array<PreloadedChartNote>
	{
		if (notes == null || notes.length == 0)
			return notes != null ? notes : [];
		if (laneCount <= 0)
			laneCount = 4;
		if (!Math.isFinite(songSpeed) || songSpeed <= 0)
			songSpeed = 1.0;
		if (!Math.isFinite(minGapPx) || minGapPx < 0)
			minGapPx = 0;
		if (!Math.isFinite(rangeMs) || rangeMs < 0)
			rangeMs = 0;

		var maniaScale:Float = 1.0;
		#if !seiun_turbo_harness
		maniaScale = Note.getManiaScale(mania);
		#end
		if (!Math.isFinite(maniaScale) || maniaScale <= 0)
			maniaScale = 1.0;

		// 像素/毫秒 -> 毫秒阈值 的换算系数（与 Note 位置公式同源）：
		// 两条 Note 的屏幕间距 = Δt * 0.45 * songSpeed * multSpeed * maniaScale
		var pxPerMs:Float = 0.45 * songSpeed * maniaScale;

		var slots:Int = laneCount * 2;
		var scratch:TurboGhostScratch = {
			lastTime: [for (i in 0...slots) -1e30],
			lastRate: [for (i in 0...slots) 0.0],
			lastSlowRate: [for (i in 0...slots) 0.0]
		};

		// 每条 lane/side 当前"可继续吸收折叠"的代表下标。
		// 必须按 lane 记录而不是直接看 out 的尾部: 长条/尾段会插在代表之间,
		// 而代表 Note 是唯一允许承载 noteDensity 的对象。
		var anchor:Array<Int> = [for (i in 0...slots) -1];

		var out:Array<PreloadedChartNote> = [];

		for (pn in notes)
		{
			if (pn == null)
				continue;

			// 长条/尾段/长条头不参与合并：尾段的裁剪与 prev/next 链语义必须保持原样。
			if (pn.isSustainNote || pn.sustainLength > 0)
			{
				out.push(pn);
				continue;
			}

			var lane:Int = Std.int(Math.abs(pn.noteData));
			if (lane >= laneCount)
				lane = lane % laneCount;
			var idx:Int = (pn.mustPress ? 1 : 0) * laneCount + lane;

			var rate:Float = pxPerMs * (pn.multSpeed > 0 ? pn.multSpeed : 1.0);

			var mergeable:Bool = false;
			if (anchor[idx] >= 0 && scratch.lastRate[idx] == rate && scratch.lastSlowRate[idx] > 0)
			{
				var dt:Float = pn.strumTime - scratch.lastTime[idx];
				if (dt <= rangeMs)
				{
					// 时间上重叠的鬼 Note：无条件合并（等价旧行为）。
					mergeable = true;
				}
				else if (minGapPx > 0 && dt * scratch.lastSlowRate[idx] < minGapPx)
				{
					// 较慢的那条决定了"最小可见间距"：只要它都不足 minGapPx，
					// 两条 Note 在任何时刻都不会分开到可分辨的程度。
					mergeable = true;
				}
			}

			var prev:Null<PreloadedChartNote> = (anchor[idx] >= 0) ? out[anchor[idx]] : null;

			if (mergeable && prev != null && prev.noteDensity < MAX_REPRESENTED)
			{
				prev.noteDensity += 1;
				continue;
			}

			// 新的一条代表：复制一份再入列，调用方数组里的对象保持原样。
			// noteDensity 归一为 1：折叠数量是本次预处理的结果，不是谱面属性。
			var rep:PreloadedChartNote = cloneNote(pn);
			rep.noteDensity = 1;
			out.push(rep);
			anchor[idx] = out.length - 1;

			// 无论是因为"分得开"还是因为"组已封顶"，这条代表都是该轨接下来的锚点。
			scratch.lastTime[idx] = rep.strumTime;
			scratch.lastRate[idx] = rate;
			scratch.lastSlowRate[idx] = rate;
		}

		return out;
	}

	/**
	 * 浅拷贝一条 PreloadedChartNote。
	 * 只在 Turbo 预处理阶段使用：调用方数组里的对象保持原样，
	 * 折叠结果才有资格做到幂等、可重复、可指纹化。
	 */
	static function cloneNote(src:PreloadedChartNote):PreloadedChartNote
	{
		return {
			strumTime: src.strumTime,
			sustainLength: src.sustainLength,
			parentST: src.parentST,
			parentSL: src.parentSL,
			stepCrochet: src.stepCrochet,
			hitHealth: src.hitHealth,
			missHealth: src.missHealth,
			multSpeed: src.multSpeed,
			multAlpha: src.multAlpha,
			noteDensity: src.noteDensity,
			offsetX: src.offsetX,
			offsetY: src.offsetY,
			noteSplashHue: src.noteSplashHue,
			noteSplashSat: src.noteSplashSat,
			noteSplashBrt: src.noteSplashBrt,
			noteType: src.noteType,
			animSuffix: src.animSuffix,
			noteskin: src.noteskin,
			texture: src.texture,
			noteSplashTexture: src.noteSplashTexture,
			noteData: src.noteData,
			mania: src.mania,
			mustPress: src.mustPress,
			oppNote: src.oppNote,
			gfNote: src.gfNote,
			noAnimation: src.noAnimation,
			noMissAnimation: src.noMissAnimation,
			isSustainNote: src.isSustainNote,
			isSustainEnd: src.isSustainEnd,
			hitCausesMiss: src.hitCausesMiss,
			ignoreNote: src.ignoreNote,
			blockHit: src.blockHit,
			lowPriority: src.lowPriority,
			wasHit: src.wasHit,
			noteSplashDisabled: src.noteSplashDisabled,
			hitsoundDisabled: src.hitsoundDisabled
		};
	}

	/**
	 * 把已经合并长条/尾段逻辑排除在外的 tap 序列，转换为"每条代表 Note 代表多少条"。
	 * 只用于诊断/测试。
	 */
	public static function representedTotal(notes:Array<PreloadedChartNote>):Int
	{
		var t:Int = 0;
		if (notes == null) return 0;
		for (pn in notes)
			if (pn != null) t += Std.int(Math.max(1, Math.round(pn.noteDensity)));
		return t;
	}
}
