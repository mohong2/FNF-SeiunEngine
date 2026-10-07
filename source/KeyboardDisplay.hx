package;
//来自于NF引擎的键盘显示
// SE 重构：软编码风格 —— 关键参数全部改为公开实例字段，lua/hscript 可改后调用 rebuild() 生效。
// lua : setProperty('keyboardDisplay.SIZE', 40); ... ; callMethod('keyboardDisplay','rebuild')
// hscript: PlayState.instance.keyboardDisplay.SIZE = 40; PlayState.instance.keyboardDisplay.rebuild();
import flixel.input.keyboard.FlxKey;
import openfl.display.Bitmap;
import openfl.display.BitmapData;
import openfl.display.Shape;
import openfl.utils.Assets;
import flixel.util.FlxSave;
import InputFormatter;
import options.OptionsHelpers;
import states.PlayState;
import EKData.Keybinds;

class KeyboardDisplay extends FlxSpriteGroup
{
	public static var saveBitmap:DisBitmap;
	public static var instance:KeyboardDisplay;

	public var leftArray:Array<TimeDis> = [];
	public var downArray:Array<TimeDis> = [];
	public var upArray:Array<TimeDis> = [];
	public var rightArray:Array<TimeDis> = [];
	/** 多k: 全部轨道 (0~kc-1) 的键雨队列, 4K 以上轨道也走这里, 便于统一回收。 */
	public var laneRain:Array<Array<TimeDis>> = [];
	/** 键雨对象池 (避免每次按键都 new TimeDis + loadGraphic 造成 GC/掉帧)。 */
	public var rainPool:Array<TimeDis> = [];

	public var _x:Float;
	public var _y:Float;
	public var _width:Float;
	public var _height:Float;
	public var kpsText:FlxText;
	public var totalText:FlxText;

	// ================= 软编码参数（lua / hscript 可调） =================
	// Soft-coded params (tweak from lua / hscript, then call rebuild())
	/** 按键边长（像素）。Key size (px). */
	public var SIZE:Int = 50;
	/** 键间距（像素）。Spacing between keys (px). */
	public var SPACING:Int = 4;
	/** 键上按键名 label 的字号。Key-name label font size. */
	public var LABEL_SIZE:Int = 20;
	/** 下方 KPS / total 标题字号。Bottom KPS/total title font size. */
	public var BAR_TITLE_SIZE:Int = 25;
	/** 下方 KPS / total 数值字号。Bottom KPS/total value font size. */
	public var BAR_VALUE_SIZE:Int = 15;
	/** 用于 label / 数值的字体文件。Font used for labels / values. */
	public var FONT:String = 'assets/fonts/montserrat.ttf';
	/** 是否显示键上的按键名 label。Show key-name labels on keys. */
	public var showKeyLabels:Bool = true;
	/** 是否显示下方 KPS 统计区。Show KPS section. */
	public var showKpsBar:Bool = true;
	/** 是否显示下方 total 统计区。Show total section. */
	public var showTotalBar:Bool = true;
	/** 键背景填充透明度系数（相对 overall alpha）。Key fill alpha multiplier (relative to overall alpha). */
	public var bgAlphaMult:Float = 0.3;
	/** 键描边透明度系数（相对 overall alpha）。Key outline alpha multiplier. */
	public var lineAlphaMult:Float = 0.8;
	/** null 时使用 ClientPrefs.keyboardBGColor，否则覆盖背景颜色（lua 传 0xRRGGBB）。Background color override (lua: pass 0xRRGGBB). */
	public var bgColorOverride:Null<FlxColor> = null;
	/** null 时使用 ClientPrefs.keyboardTextColor，否则覆盖文字颜色（lua 传 0xRRGGBB）。Text color override (lua: pass 0xRRGGBB). */
	public var textColorOverride:Null<FlxColor> = null;
	/** <0 时使用 ClientPrefs.keyboardAlpha，否则覆盖整体透明度。Overall alpha override (<0 = use ClientPrefs). */
	public var alphaOverride:Float = -1;

	/** 构建时的键数 (多k: 按当前谱面键数生成)。 */
	var _kc:Int = 4;
	/** label 相对键中心的 Y 偏移。Label Y offset from key center. */
	public var keyTextOffsetY:Float = 0;
	/** KPS / total 数值相对统计区中心偏移。Bar value Y offset. */
	public var barValueOffsetY:Float = 0;
	/** 统计区标题相对中心的 Y 偏移。Bar title Y offset. */
	public var barTitleOffsetY:Float = 0;

	/**
	 * 完全自定义模式 / Fully-custom mode:
	 * 为 true 时 build()/rebuild() 不再生成任何默认 UI，留下一枚空 group，
	 * 由 lua/hscript 自行 add 精灵进来绘制自己的小键盘。
	 * 配合钩子 onKeyboardPress / onKeyboardRelease / onKeyboardUpdate 实现 100% 接管。
	 */
	public var fullyCustom:Bool = false;

	var total:Int = 0;
	var hitArray:Array<Date> = [];

	// ================= 便捷读取（考虑脚本覆盖） =================
	// Convenience getters (respect script overrides)
	public function getBgColor():FlxColor
	{
		return (bgColorOverride != null) ? bgColorOverride : OptionsHelpers.colorArray(ClientPrefs.data.keyboardBGColor);
	}
	public function getTextColor():FlxColor
	{
		return (textColorOverride != null) ? textColorOverride : OptionsHelpers.colorArray(ClientPrefs.data.keyboardTextColor);
	}
	public function getOverallAlpha():Float
	{
		return (alphaOverride >= 0) ? alphaOverride : ClientPrefs.data.keyboardAlpha;
	}

	// ---- 便捷设置，便于 lua（Number）/ hscript（Int）以整型传色 ----
	// Convenience setters: pass color as Int from lua/hscript
	public function setBgColor(col:Int):Void
	{
		bgColorOverride = FlxColor.fromInt(col);
	}
	public function setTextColor(col:Int):Void
	{
		textColorOverride = FlxColor.fromInt(col);
	}
	public function clearColorOverrides():Void
	{
		bgColorOverride = null;
		textColorOverride = null;
	}

	/** 读取累计按键总数（供脚本自绘 total 用）。Read total key presses (for custom UI). */
	public function getTotal():Int
	{
		return total;
	}
	/** 主动增加/减少累计按键总数（amount 可为负），返回新值。Manually change total counter (amount can be negative). */
	public function incrementTotal(amount:Int = 1):Int
	{
		total += amount;
		if (totalText != null)
			totalText.text = Std.string(total);
		return total;
	}

	/** 向 PlayState 的 lua/hscript 触发回调（存在实例才调用）。Fire a lua/hscript callback on PlayState (no-op outside). */
	static function callScript(callback:String, args:Array<Dynamic> = null):Void
	{
		if (PlayState.instance != null)
			PlayState.instance.callOnScripts(callback, args);
	}

	public function new(X:Float, Y:Float)
	{
		super();
		instance = this;
		_x = X;
		_y = Y;
		if (FlxG.save.data.keyboardtotal != null)
			total = FlxG.save.data.keyboardtotal;

		build();

		saveBitmap = new DisBitmap();
		var obj:TimeDis = new TimeDis(0, 0, _x, _y);
		obj.visible = false; // 把纹理保存在运存中,如果你愿意这玩意出bug就试试删了它
	}

	/** 重建静态 UI（键、label、统计区、时间条纹理）。改完软编码参数后调用。
	 *  Rebuild the static UI (keys, labels, stat zone, time-bar texture). Call after tweaking params. */
	public function rebuild():Void
	{
		var i:Int = members.length - 1;
		while (i >= 0)
		{
			var m = members[i];
			if (m != null)
			{
				remove(m, true);
				// 键雨对象由 rainPool 统一销毁, 避免重复 destroy
				if (Std.isOfType(m, TimeDis))
					m.kill();
				else
					m.destroy();
			}
			i--;
		}
		leftArray = [];
		downArray = [];
		upArray = [];
		rightArray = [];
		// 重建时销毁池中对象 (避免复用旧尺寸纹理), 键雨队列一并清空
		for (t in rainPool)
			if (t != null) t.destroy();
		rainPool = [];
		laneRain = [];
		// 同步重建时间条纹理（尺寸随 SIZE 变化）
		if (saveBitmap != null && saveBitmap.bitmapData != null)
		{
			saveBitmap.bitmapData.dispose();
			saveBitmap.bitmapData = null;
		}
		saveBitmap = new DisBitmap();
		build();
	}

	function build():Void
	{
		var kc:Int = keyCount();
		_kc = kc;
		laneRain = [for (i in 0...kc) []];
		// 多k: 按键行总宽, 超出屏幕时整体向左收, 避免卡出屏幕
		_width = (SIZE + SPACING) * kc;
		var dispX:Float = _x;
		if (dispX + _width > FlxG.width) dispX = FlxG.width - _width - 4;
		if (dispX < 0) dispX = 0;
		_height = (SIZE + SPACING) * 2;

		// 完全自定义模式：不生成任何默认 UI，由脚本自行 add。
		if (fullyCustom)
		{
			kpsText = null;
			totalText = null;
			return;
		}

		var keyOffset:Int = SIZE + SPACING;
		// 顶行按键 (多k: 按当前谱面键数)
		for (i in 0...kc)
		{
			var obj:KeyButton = new KeyButton(dispX + keyOffset * i, _y, SIZE, SIZE);
			add(obj);
		}
		// 顶行按压覆盖
		for (i in 0...kc)
		{
			var obj:KeyButtonAlpha = new KeyButtonAlpha(dispX + keyOffset * i, _y);
			add(obj);
		}
		// 顶行键名 label
		if (showKeyLabels)
		{
			var textArray:Array<String> = createArray();
			for (i in 0...kc)
			{
				var obj:FlxText = new FlxText(dispX + keyOffset * i + members[kc + i].width / 2, _y + members[kc + i].height / 2,
					50, textArray[i], 10, false);
				obj.setFormat(Assets.getFont(FONT).fontName, LABEL_SIZE, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, 0x00);
				obj.x -= obj.width / 2;
				obj.y -= obj.height / 2;
				obj.y += keyTextOffsetY;
				obj.color = getTextColor();
				obj.alpha = getOverallAlpha();
				add(obj);
			}
		}
		// 底行 2 个统计大键
		if (showKpsBar || showTotalBar)
		{
			// 多k: 两个统计条横向拉伸覆盖整行键宽
			var barW:Int = Std.int((_width - SPACING) / 2);
			var statIdx:Int = kc * 3;
			for (i in 0...2)
			{
				var obj:KeyButton = new KeyButton(dispX + (barW + SPACING) * i, _y + keyOffset, barW, SIZE);
				add(obj);
			}
			var textArray:Array<String> = ['KPS', 'total'];
			for (i in 0...2)
			{
				var obj:FlxText = new FlxText(members[statIdx + i].x + members[statIdx + i].width / 2,
					members[statIdx + i].y + members[statIdx + i].height / 4,
					barW, textArray[i], 20, false);
				obj.setFormat(Assets.getFont(FONT).fontName, BAR_TITLE_SIZE, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, 0x00);
				obj.x -= obj.width / 2;
				obj.y -= obj.height / 2;
				obj.y += barTitleOffsetY;
				obj.color = getTextColor();
				obj.alpha = getOverallAlpha();
				obj.antialiasing = ClientPrefs.data.globalAntialiasing;
				add(obj);
			}
			kpsText = new FlxText(members[statIdx].x + members[statIdx].width / 2, members[statIdx].y + members[statIdx].height / 5 * 3.5,
				barW, '0', 15, false);
			kpsText.setFormat(Assets.getFont(FONT).fontName, BAR_VALUE_SIZE, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, 0x00);
			kpsText.x -= kpsText.width / 2;
			kpsText.y -= kpsText.height / 2;
			kpsText.y += barValueOffsetY;
			kpsText.color = getTextColor();
			kpsText.alpha = getOverallAlpha();

			totalText = new FlxText(members[statIdx + 1].x + members[statIdx + 1].width / 2, members[statIdx + 1].y + members[statIdx + 1].height / 5 * 3.5,
				barW, Std.string(total), 15, false);
			totalText.setFormat(Assets.getFont(FONT).fontName, BAR_VALUE_SIZE, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, 0x00);
			totalText.x -= totalText.width / 2;
			totalText.y -= totalText.height / 2;
			totalText.y += barValueOffsetY;
			totalText.color = getTextColor();
			totalText.alpha = getOverallAlpha();
			add(kpsText);
			add(totalText);
		}
		else
		{
			kpsText = null;
			totalText = null;
		}
	}

	/** 多k: 当前谱面键数 (1K~18K), 无谱面时默认 4。 */
	function keyCount():Int
	{
		// 跟随 PlayState.mania (游戏中 "Change Mania" 事件也会实时生效)
		return Note.ammo[EKData.clampMania(PlayState.mania)];
	}

	public function pressed(key:Int)
	{
		// 先通知脚本（fullyCustom 模式下脚本用它自己重绘）
		callScript('onKeyboardPress', [key]);

		if (!PlayState.replayMode)
			total++;
		if (totalText != null)
			totalText.text = Std.string(total);
		hitArray.unshift(Date.now());

		if (!visible) return;

		var kc:Int = _kc;
		if (members[kc + key] != null)
			members[kc + key].alpha = 1 * getOverallAlpha();
		if (showKeyLabels && members[kc * 2 + key] != null)
			members[kc * 2 + key].color = FlxColor.BLACK;

		if (!ClientPrefs.data.keyboardTimeDisplay || saveBitmap == null || saveBitmap.bitmapData == null || fullyCustom)
			return;
		if (key < 0 || key >= _kc) return;

		var obj:TimeDis = acquireRain(key);

		// 同一轨道上一段未释放的键雨先收尾
		if (laneRain[key].length > 0 && laneRain[key][laneRain[key].length - 1].endTime == -999999)
			laneRain[key][laneRain[key].length - 1].endTime = Conductor.songPosition;
		laneRain[key].push(obj);

		// 兼容脚本访问的 0-3 轨道数组
		switch (key)
		{
			case 0: leftArray.push(obj);
			case 1: downArray.push(obj);
			case 2: upArray.push(obj);
			case 3: rightArray.push(obj);
		}
	}

	public function released(key:Int)
	{
		// 先通知脚本（fullyCustom 模式下脚本用它自己重绘）
		callScript('onKeyboardRelease', [key]);

		// 不可见时 pressed() 就没建过键雨, 这里无事可做 (见 pressed 的说明)。
		if (!visible) return;

		var kc:Int = _kc;
		if (members[kc + key] != null)
			members[kc + key].alpha = 0;
		if (showKeyLabels && members[kc * 2 + key] != null)
			members[kc * 2 + key].color = getTextColor();

		if (key >= 0 && key < laneRain.length && laneRain[key] != null
			&& laneRain[key].length > 0 && laneRain[key][laneRain[key].length - 1].endTime == -999999)
			laneRain[key][laneRain[key].length - 1].endTime = Conductor.songPosition;

		switch (key)
		{
			case 0:
				if (leftArray.length > 0 && leftArray[leftArray.length - 1].endTime == -999999)
					leftArray[leftArray.length - 1].endTime = Conductor.songPosition;
			case 1:
				if (downArray.length > 0 && downArray[downArray.length - 1].endTime == -999999)
					downArray[downArray.length - 1].endTime = Conductor.songPosition;
			case 2:
				if (upArray.length > 0 && upArray[upArray.length - 1].endTime == -999999)
					upArray[upArray.length - 1].endTime = Conductor.songPosition;
			case 3:
				if (rightArray.length > 0 && rightArray[rightArray.length - 1].endTime == -999999)
					rightArray[rightArray.length - 1].endTime = Conductor.songPosition;
		}
	}

	public function save()
	{
		FlxG.save.data.keyboardtotal = total;
		FlxG.save.flush();
	}

	public static function getKeyBinds():Map<String, Array<FlxKey>>
	{
		return ClientPrefs.keyBinds;
	}

	public function createArray():Array<String>
	{
		var array:Array<String> = [];
		var keyBinds = getKeyBinds();
		if (PlayState.mania != Note.defaultMania)
		{
			// 多k: 显示当前谱面各轨道的键位
			var binds:Array<Array<Dynamic>> = Keybinds.fill();
			var m:Int = EKData.clampMania(PlayState.mania);
			if (m >= 0 && m < binds.length)
			{
				for (i in 0...binds[m].length)
				{
					var keys:Array<FlxKey> = binds[m][i];
					if (keys != null && keys.length > 0)
						array.push(InputFormatter.getKeyName(keys[0]));
					else
						array.push('---');
				}
				return array;
			}
		}
		array.push(InputFormatter.getKeyName(keyBinds.get('note_left')[0]));
		array.push(InputFormatter.getKeyName(keyBinds.get('note_down')[0]));
		array.push(InputFormatter.getKeyName(keyBinds.get('note_up')[0]));
		array.push(InputFormatter.getKeyName(keyBinds.get('note_right')[0]));
		return array;
	}

	public function removeObj(obj:TimeDis)
	{
		if (obj.line >= 0 && obj.line < laneRain.length && laneRain[obj.line] != null)
			laneRain[obj.line].remove(obj);
		switch (obj.line)
		{
			case 0:
				leftArray.remove(obj);
			case 1:
				downArray.remove(obj);
			case 2:
				upArray.remove(obj);
			case 3:
				rightArray.remove(obj);
		}
		remove(obj, true);
		obj.kill(); // 回池复用, 不销毁
	}

	/** 从池中获取键雨对象 (不足时新建并载入纹理)。 */
	function acquireRain(key:Int):TimeDis
	{
		var obj:TimeDis = null;
		for (t in rainPool)
		{
			if (t != null && !t.alive)
			{
				obj = t;
				break;
			}
		}
		if (obj == null)
		{
			obj = new TimeDis(key, Conductor.songPosition, _x, _y);
			obj.visible = false;
			rainPool.push(obj);
		}
		obj.setup(key, Conductor.songPosition, _x, _y);
		obj.exists = true;
		obj.active = true;
		obj.visible = true;
		obj.alive = true;
		add(obj);
		return obj;
	}

	public var kps:Int = 0;
	public var kpsCheck:Int = 0;

	public function dataUpdate(elapsed:Float)
	{
		if (hitArray.length > 0)
		{
			var nowMs:Float = Date.now().getTime();
			var cut:Int = hitArray.length;
			while (cut > 0)
			{
				var d:Date = hitArray[cut - 1];
				if (d == null || d.getTime() + 1000 >= nowMs) break;
				cut--;
			}
			if (cut < hitArray.length) hitArray.resize(cut);
		}
		kps = hitArray.length;

		if (kpsCheck != kps)
		{
			kpsCheck = kps;
			if (kpsText != null)
				kpsText.text = Std.string(kps);
		}
		// fullyCustom 模式下每帧通知脚本（脚本据此驱动自身动画）。
		// 默认模式不触发，避免无谓的脚本遍历开销。
		if (fullyCustom)
			callScript('onKeyboardUpdate', [elapsed, kps, total]);
	}
}

class KeyButton extends FlxSprite
{
	public function new(X:Float, Y:Float, Width:Int, Height:Int)
	{
		super(X, Y);

		var kb:KeyboardDisplay = KeyboardDisplay.instance;
		var overall:Float = kb.getOverallAlpha();
		var bgAlpha:Float = kb.bgAlphaMult * overall;
		var lineAlpha:Float = kb.lineAlphaMult * overall;
		var radius:Int = Std.int(kb.SIZE / 3);

		var shape:Shape = new Shape();
		shape.graphics.lineStyle(2, FlxColor.WHITE, lineAlpha);
		shape.graphics.drawRoundRect(0, 0, Width, Height, radius, radius);
		shape.graphics.lineStyle();
		shape.graphics.beginFill(FlxColor.WHITE, bgAlpha);
		shape.graphics.drawRoundRect(0, 0, Width, Height, radius, radius);
		shape.graphics.endFill();

		var BitmapData:BitmapData = new BitmapData(Width, Height, 0x00FFFFFF);
		BitmapData.draw(shape);

		loadGraphic(BitmapData);
		antialiasing = ClientPrefs.data.globalAntialiasing;
		color = kb.getBgColor();
	}
}

class KeyButtonAlpha extends FlxSprite
{
	public function new(X:Float, Y:Float)
	{
		super(X, Y);

		var kb:KeyboardDisplay = KeyboardDisplay.instance;
		var size:Int = kb.SIZE;

		var shape:Shape = new Shape();
		shape.graphics.beginFill(FlxColor.WHITE, 1);
		shape.graphics.drawRoundRect(0, 0, size, size, Std.int(size / 3), Std.int(size / 3));
		shape.graphics.endFill();

		var BitmapData:BitmapData = new BitmapData(size, size, 0x00FFFFFF);
		BitmapData.draw(shape);

		loadGraphic(BitmapData);
		antialiasing = ClientPrefs.data.globalAntialiasing;
		alpha = 0;
	}
}

class TimeDis extends FlxSprite
{
	public var startTime:Float;
	public var endTime:Float = -999999;
	public var line:Int;

	var saveTime:Float;
	var durationTime:Float = -1;

	public function new(Line:Int, Time:Float, X:Float, Y:Float)
	{
		this.line = Line;
		super(0, 0);
		// Unique=true: 每个键雨对象独立帧, 避免共享图集帧被互相改写
		loadGraphic(KeyboardDisplay.saveBitmap.bitmapData, true);
		setup(Line, Time, X, Y);
	}

	/** (重)初始化键雨对象; 池化复用时会再次调用以重置所有状态。 */
	public function setup(Line:Int, Time:Float, X:Float, Y:Float):Void
	{
		this.line = Line;
		var kb:KeyboardDisplay = KeyboardDisplay.instance;
		// 与 build() 一致的屏幕夹取偏移, 保证键雨与按键对齐
		var effX:Float = X;
		if (effX + kb._width > FlxG.width) effX = FlxG.width - kb._width - 4;
		if (effX < 0) effX = 0;
		x = effX + Line * (kb.SIZE + kb.SPACING);
		y = Y - 4 - KeyboardDisplay.saveBitmap.bitmapData.height;
		this.startTime = Time;
		endTime = -999999;
		durationTime = -1;
		saveTime = 0;
		offset.y = 0;
		_frame.frame.y = 0;
		_frame.frame.height = 1;
		this.color = kb.getBgColor();
		alpha = kb.getOverallAlpha();
		visible = true;
		active = true;
		exists = true;
		alive = true;
	}

	override function update(elapsed:Float)
	{
		if (durationTime < 0)
			durationTime = ClientPrefs.data.keyboardTime;

		var h:Float = KeyboardDisplay.saveBitmap.bitmapData.height;
		if (endTime == -999999)
		{
			_frame.frame.y = (1 - ((Conductor.songPosition - startTime) / durationTime)) * h;
			_frame.frame.height = ((Conductor.songPosition - startTime) / durationTime) * h;
			offset.y = -(1 - ((Conductor.songPosition - startTime) / durationTime)) * h;
			if (_frame.frame.y < 0)
				_frame.frame.y = 0;
			if (Conductor.songPosition - startTime > durationTime)
				offset.y = 0;
			saveTime = Conductor.songPosition;
		}
		else
		{
			if (endTime - startTime < durationTime)
				_frame.frame.y = (1 - ((Conductor.songPosition - startTime) / durationTime)) * h;
			else
				_frame.frame.y = (1 - ((Conductor.songPosition - (endTime - durationTime)) / durationTime)) * h;
			offset.y -= -((Conductor.songPosition - saveTime) / durationTime) * h;
			saveTime = Conductor.songPosition;
		}
		if (_frame.frame.height > h)
			_frame.frame.height = h;
		if (_frame.frame.height <= 0)
			_frame.frame.height = 1; // fix bug

		if (endTime != -999999 && Conductor.songPosition - endTime > durationTime)
			KeyboardDisplay.instance.removeObj(this);
	}
}

class DisBitmap extends Bitmap
{
	public function new()
	{
		super();

		var kb:KeyboardDisplay = KeyboardDisplay.instance;
		var width:Int = kb.SIZE;
		var height:Int = Std.int(kb.SIZE * 3);

		var BitmapData:BitmapData = new BitmapData(width, height, true, 0);
		var shape:Shape = new Shape();

		for (i in 0...width + 1)
		{
			shape.graphics.beginFill(FlxColor.WHITE, i / width);
			shape.graphics.drawRect(0, i, width, 1);
			shape.graphics.endFill();
		}
		shape.graphics.beginFill(FlxColor.WHITE);
		shape.graphics.drawRect(0, width, width, height - width);
		shape.graphics.endFill();
		BitmapData.draw(shape);

		this.bitmapData = BitmapData;
	}
}
