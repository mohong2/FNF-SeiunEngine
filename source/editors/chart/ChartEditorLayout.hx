package editors.chart;

/**
 * 图表编辑器 UI 布局。
 *
 * 编辑器只有一套逻辑 / 一套控件（NewChartingState），这里只描述两套"排版"：
 *
 *  - MODERN : 新版排版 —— 浮动的 3 个面板盒（主面板 / 信息盒 / 工具盒），网格居中。
 *  - CLASSIC: 旧版排版 —— 与 Psych 0.6.3 的 ChartingState 一致：网格贴左侧，
 *             右侧固定一块 300px 宽、5 个标签页的面板（x=660, y=25）。
 *
 * CLASSIC 里并不是另写一套控件：把新版面板的控件原样搬到旧版标签页里（同一批对象），
 * 因此两套 UI 的功能必然完全一致，不存在"切过去少东西"的情况。
 */
class ChartEditorLayout
{
	public static inline final MODERN:String = 'modern';
	public static inline final CLASSIC:String = 'classic';

	// ── 旧版排版尺寸（数值取自 ChartingState.hx） ──
	/** 旧版面板盒 x：640 + GRID_SIZE/2（GRID_SIZE = 40）。 */
	public static inline final CLASSIC_X:Int = 660;
	public static inline final CLASSIC_Y:Int = 25;
	/** 面板宽度: 0.6.3 是 300, 现在要装 0.7/1.0 那批控件, 放宽到 340 (右边距屏幕还有 280px)。 */
	public static inline final CLASSIC_WIDTH:Int = 340;
	public static inline final CLASSIC_TAB_HEIGHT:Int = 20;
	/** 旧版网格左边缘（世界原点 0 + 相机偏移 -279.5）。 */
	public static inline final CLASSIC_GRID_X:Int = 280;
	/** 网格与面板之间的最小空隙。 */
	public static inline final CLASSIC_GRID_GAP:Int = 20;
	/** 面板内容与面板左右边缘的间距。 */
	public static inline final CLASSIC_PAD:Int = 10;
	/** 面板盒最小高度 (每页按自己内容伸缩, 只保证不矮于这个值)。 */
	public static inline final CLASSIC_MIN_HEIGHT:Int = 200;
	/**
	 * 旧版的时间/段落/拍/步文本位置 (0.6.3 的 bpmTxt 在 (1000, 50), 文本自己带 15px 左边距,
	 * 所以盒子摆到 (985, 30) 时文字正好落在旧版位置上)。
	 */
	public static inline final CLASSIC_INFO_X:Int = 1010;
	public static inline final CLASSIC_INFO_Y:Int = 30;
	/** 同一个标签页里两块面板的垂直间距。 */
	public static inline final PANEL_GAP:Int = 12;

	/** 旧版"歌曲"页里文件按钮的排布 (新版是一竖列, 旧版排成 3 列填满面板)。 */
	public static inline final CLASSIC_FILE_COLUMNS:Int = 3;
	public static inline final CLASSIC_FILE_BTN_W:Int = 110;
	public static inline final CLASSIC_FILE_ROW_H:Int = 21;

	/** 切换排版时控件飞行过渡的时长 (秒)。 */
	public static inline final LAYOUT_ANIM_DUR:Float = 0.26;

	/** 旧版标签页（顺序 / 文本 key 与 ChartingState 完全一致）。 */
	public static final CLASSIC_TABS:Array<String> = [
		'newchartEditor_charting',
		'newchartEditor_section',
		'newchartEditor_note',
		'newchartEditor_events',
		'newchartEditor_song'
	];

	/**
	 * 旧版标签页 -> 复用的新版面板 id（按数组顺序竖排）。
	 *
	 * 旧版就这 5 个标签：图表 / 板块 / 音符 / 事件 / 歌曲。
	 *  - "数据"（Note 贴图 / 失败角色）在旧版里属于歌曲/贴图设置，接在"歌曲"页下面；
	 *  - "歌曲信息"不占标签页：旧版里它本来就是屏幕上的一行文本 (1000, 50)，旧版排版把它摆回去。
	 *
	 * 文件 / 编辑 / 视图 不是旧版的标签页，旧版排版里不出现（旧版本来就是快捷键: Ctrl+S 保存、
	 * Ctrl+R 重载、Ctrl+Z/Y 撤销重做）。旧版排版除了这 5 个标签，不额外放任何按钮。
	 */
	public static final CLASSIC_PANELS:Array<Array<String>> = [
		['charting', 'data'],                         // 图表 (数据: Note 贴图 / 失败角色)
		['section'],                                  // 板块
		['note'],                                     // 音符
		['events'],                                   // 事件
		['file', 'song']                              // 歌曲 (旧版这里就是 保存/打开/… + 歌曲设置)
	];

	public static function isValid(id:String):Bool
	{
		return id == MODERN || id == CLASSIC;
	}

	public static function opposite(id:String):String
	{
		return (id == CLASSIC) ? MODERN : CLASSIC;
	}

	/** 面板所在的旧版标签页下标; -1 = 不进标签页 (例如屏幕上的信息文字)。 */
	public static function tabIndexFor(panelId:String):Int
	{
		for (i in 0...CLASSIC_PANELS.length)
			if (CLASSIC_PANELS[i].indexOf(panelId) > -1) return i;
		return -1;
	}
}
