package backend;

import ClientPrefs;

/**
 * 三引擎兼容层 (Psych Engine 0.6.3 / 0.7.3 / 1.0.4)。
 *
 * 玩家可在 设置 → Gameplay 里通过 `compatEngine` 选择要模拟的引擎版本:
 *   - "Auto"  : 沿用旧行为 —— 若旧版 `compatibility_mode` 开关为 true 则模拟 0.7.3,
 *               否则保持本引擎原生 0.6.3 行为 (向后兼容老存档)。
 *   - "0.6.3" : 强制 0.6.3 API / UI。
 *   - "0.7.3" : 强制 0.7.3 API / UI (等价于旧 compatibility_mode = true)。
 *   - "1.0.4" : 强制 1.0.4 API / UI (在 0.7.3 基础上补充 1.0.4 专属回调等)。
 *
 * 由于 Note 相关逻辑已改为缓存池/预加载实现, 所有版本差异都应通过这里的
 * 语义化判断来取 (is063 / is073 / is104 / isModern), 而不是散落各处判断
 * ClientPrefs 原始字段。
 */
class CompatEngine
{
	public static final AUTO:String = 'Auto';
	public static final PE_063:String = '0.6.3';
	public static final PE_073:String = '0.7.3';
	public static final PE_104:String = '1.0.4';

	/** 合法取值, 供设置项 / 校验使用。 */
	public static final VALUES:Array<String> = [AUTO, PE_063, PE_073, PE_104];

	/**
	 * 返回当前生效的引擎标识 ("Auto" 已被解析为具体版本)。
	 * Auto 语义: 旧 `compatibility_mode` 开 = 0.7.3, 关 = 0.6.3。
	 */
	public static function current():String
	{
		var sel:String = ClientPrefs.data.compatEngine;
		if (sel == null || sel.length == 0 || !VALUES.contains(sel))
			sel = AUTO;

		if (sel == AUTO)
			return ClientPrefs.data.compatibility_mode ? PE_073 : PE_063;
		return sel;
	}

	/** 当前是否模拟 Psych Engine 0.6.3。 */
	public static function is063():Bool
	{
		return current() == PE_063;
	}

	/** 当前是否模拟 Psych Engine 0.7.3。 */
	public static function is073():Bool
	{
		return current() == PE_073;
	}

	/** 当前是否模拟 Psych Engine 1.0.4。 */
	public static function is104():Bool
	{
		return current() == PE_104;
	}

	/**
	 * 现代引擎 (0.7.3 / 1.0.4) 共有的行为:
	 *  - noteGroup/uiGroup/comboGroup + Bar 类 UI 结构
	 *  - onSpawnNote / onEvent 带 strumTime 参数
	 *  - goodNoteHit / opponentNoteHit 使用 Math.round(Math.abs(noteData))
	 *  - goodNoteHitPre / opponentNoteHitPre 回调
	 */
	public static function isModern():Bool
	{
		return is073() || is104();
	}

	/**
	 * 旧版 `compatibility_mode` 布尔语义 (供 Lua/HScript 全局变量与
	 * 错误信息风格等沿用): 非 0.6.3 即为 true。
	 */
	public static function compatMode():Bool
	{
		return !is063();
	}

	/** 1.0.4 专属: 命中回调的 Pre 阶段是否在返回 Function_Stop 时提前中止。 */
	public static function stopOnPreHitStop():Bool
	{
		return is104();
	}

	// ======================================================================
	// 1.0.4 兼容: 可选参数的"版本相关默认值"
	//
	// Psych 1.0.4 把一批 Lua 回调的可选参数从"必填"放宽为"有默认值", 并且部分
	// 默认值与 0.6.3/0.7.3 不同。直接照抄 1.0.4 会改变本引擎原生 (0.6.3) 与
	// 0.7.3 模拟模式下的既有行为, 所以这里按当前 CompatEngine 版本取默认值:
	//   - 0.6.3 / 0.7.3: 保持各自原生默认值;
	//   - 1.0.4        : 采用 1.0.4 的默认值。
	//
	// 注意: 这些函数只用于"调用方省略参数"的情形; 显式传参永远优先。
	// ======================================================================

	/** setHealth() 省略参数时的血量默认值 (0.6.3/0.7.3 = 0, 1.0.4 = 1)。 */
	public static function defaultHealth():Float
	{
		return is104() ? 1 : 0;
	}

	/** loadFrames / makeAnimatedLuaSprite 省略 spriteType 时的默认值。 */
	public static function defaultSpriteType():String
	{
		return is104() ? 'auto' : 'sparrow';
	}

	/** setObjectCamera 省略 camera 时的默认值 (0.6.3/0.7.3 = '', 1.0.4 = 'game')。 */
	public static function defaultCamera():String
	{
		return is104() ? 'game' : '';
	}

	/** getMouseX/Y 与 getScreenPositionX/Y 省略 camera 时的默认值。 */
	public static function defaultMouseCamera():String
	{
		return is104() ? 'game' : '';
	}

	/**
	 * keyJustPressed / keyPressed / keyReleased 省略 name 时的默认值。
	 * 1.0.4 把 name 变为可选并默认 ''(空串 = 任意键); 0.6.3/0.7.3 下省略同样
	 * 落到空串分支, 因此三个版本语义一致。
	 */
	public static function defaultKeyName():String
	{
		return '';
	}

	/** mouseClicked / mousePressed / mouseReleased 省略 button 时的默认值 (三个版本都是 'left')。 */
	public static function defaultMouseButton():String
	{
		return 'left';
	}

	/** setAchievementScore 省略 value 时的默认值 (0.7.3 = 1, 1.0.4 = 0)。 */
	public static function defaultAchievementScore():Float
	{
		return is104() ? 0 : 1;
	}
}
