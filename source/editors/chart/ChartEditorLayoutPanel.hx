package editors.chart;

import backend.ui.PsychUIButton;
import backend.ui.PsychUIHelper;
import flixel.tweens.FlxTween;
import flixel.tweens.FlxEase;
import flixel.util.FlxColor;

/**
 * 布局切换面板：顶部右侧的浮动按钮点开后出现的小窗。
 *
 * 两个大按钮（旧版 / 现代），选中项底下有一块白色高光方块，切换时用 0.18s 的
 * quartOut 滑到新位置；面板本身淡入，移动端也能整块点按。
 */
class ChartEditorLayoutPanel extends FlxSpriteGroup
{
	public static final WIDTH:Int = 320;
	public static final HEIGHT:Int = 160;
	public static final ROW_HEIGHT:Int = 34;
	public static final ROW_WIDTH:Int = WIDTH - 24;

	public var onPick:String->Void;
	public var currentId:String;

	var rows:Array<{id:String, btn:PsychUIButton}> = [];
	var highlight:FlxSprite;
	var _started:Bool = false;

	public function new(x:Float, y:Float, currentId:String, onPick:String->Void)
	{
		super(x, y);
		this.currentId = currentId;
		this.onPick = onPick;

		var bg:FlxSprite = PsychUIHelper.createRoundedRectSprite(WIDTH, HEIGHT, 12);
		bg.color = FlxColor.BLACK;
		bg.alpha = 0.88;
		add(bg);

		highlight = PsychUIHelper.createRoundedRectSprite(ROW_WIDTH, ROW_HEIGHT, 8);
		highlight.color = FlxColor.WHITE;
		highlight.alpha = 0.16;
		add(highlight);

		var title:FlxText = new FlxText(14, 10, WIDTH - 28, Language.get('newchartEditor_layout_title', 'Chart Editor Layout'));
		title.setFormat(Paths.font('editors.ttf'), 14, FlxColor.WHITE, LEFT);
		add(title);

		addRow(ChartEditorLayout.CLASSIC, 44, Language.get('newchartEditor_layout_classic', 'Classic UI'));
		addRow(ChartEditorLayout.MODERN, 44 + ROW_HEIGHT + 10, Language.get('newchartEditor_layout_modern', 'Modern UI'));

		var hint:FlxText = new FlxText(14, HEIGHT - 24, WIDTH - 28, Language.get('newchartEditor_layout_hint', 'The choice is remembered.'));
		hint.setFormat(Paths.font('editors.ttf'), 11, 0xFFB0B0B0, LEFT);
		add(hint);

		refresh(currentId, false);
	}

	function addRow(id:String, yy:Float, label:String)
	{
		var row:PsychUIButton = new PsychUIButton(12, yy, label, function() pick(id), ROW_WIDTH, ROW_HEIGHT);
		// text.x is baked into state space (FlxSpriteGroup offsets its children on add()), so it
		// must be derived from the box's real position - a literal 14 put the label off-panel.
		row.text.alignment = LEFT;
		row.text.x = row.bg.x + 12;
		row.normalStyle = {bgColor: FlxColor.BLACK, textColor: FlxColor.WHITE, bgAlpha: 0};
		row.hoverStyle = {bgColor: FlxColor.WHITE, textColor: FlxColor.WHITE, bgAlpha: 0.10};
		row.clickStyle = {bgColor: FlxColor.WHITE, textColor: FlxColor.WHITE, bgAlpha: 0.20};
		row.smoothAnimations = false;
		add(row);
		rows.push({id: id, btn: row});
	}

	public function pick(id:String):Void
	{
		if (id == currentId) return;
		currentId = id;
		refresh(id, true);
		if (onPick != null) onPick(id);
	}

	public function refresh(id:String, animate:Bool = true):Void
	{
		currentId = id;
		var targetY:Float = 44;
		for (row in rows)
		{
			var selected:Bool = (row.id == id);
			row.btn.text.alpha = selected ? 1 : 0.7;
			if (selected) targetY = row.btn.y;
		}

		FlxTween.cancelTweensOf(highlight);
		if (animate && _started) FlxTween.tween(highlight, {y: targetY}, 0.18, {ease: FlxEase.quartOut});
		else highlight.y = targetY;
		_started = true;
	}

	/**
	 * 淡入会踩到 FlxSpriteGroup.set_alpha 的坑 (alpha 从 0 起时子对象的 alpha 不会被恢复),
	 * 所以改成纵向滑入: 移动组本身会同步位移子对象, 最终位置就是构造时的位置。
	 */
	public function fadeIn():Void
	{
		var targetY:Float = y;
		y = targetY + 10;
		FlxTween.tween(this, {y: targetY}, 0.16, {ease: FlxEase.quartOut});
	}
}
