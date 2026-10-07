package backend;

/**
 * 兼容 Psych Engine 1.0.4 的 JSON 解析。
 * English: Psych Engine 1.0.4-compatible JSON parsing.
 *
 * Psych Engine 1.0.4 对「模组数据」统一使用 `tjson.TJSON.parse`（pack.json、关卡
 * JSON、角色/标题数据、`data/settings.json` 等），而 tjson 是一个**宽容解析器**：
 *
 *   - 允许对象 / 数组内的尾随逗号:  `{ "a": 1, }`  和  `[1, 2, ]`
 *   - 允许 `//` 行注释与 `/* ... *\/` 块注释
 *   - 允许 JSON 之后存在多余文本
 *
 * 本引擎原本在这些位置使用严格的 `haxe.Json.parse`，于是非常常见的 1.0.4 模组
 * （pack.json / stage JSON 结尾带一个逗号）会直接解析失败 —— 实测日志里就是
 * `加载 pack.json 失败: Invalid char 125 at position 147`（125 即 `}`）。
 *
 * 这里统一优先走 tjson（与 1.0.4 完全一致），失败再回退到标准解析器，这样既能读
 * 1.0.4 模组、又不会改变原本就合法文件的解析结果。
 *
 * 注意：只应用在 Psych 1.0.4 同样使用 tjson 的位置。1.0.4 自己用严格
 * `Json.parse` 的地方（Song / Character / Dialogue 等）保持不变，以免引入
 * 与 1.0.4 不一致的解析行为。
 */
class JsonUtil
{
	/**
	 * 解析 JSON 文本，兼容 1.0.4 的 tjson 宽容语义。
	 * 空输入返回 null；两次解析都失败时抛出最后一次的异常（调用方各自处理）。
	 */
	public static function parseTolerant(text:String):Dynamic
	{
		if (text == null) return null;
		var clean:String = removeBom(text);
		if (StringTools.trim(clean).length == 0) return null;

		try
		{
			return tjson.TJSON.parse(clean);
		}
		catch (e:Dynamic)
		{
			// tjson 在个别输入上比标准解析器更严格（例如未加引号的键、
			// 非法数字字面量）。回退到标准解析器，保持对已有合法文件的兼容。
		}
		return haxe.Json.parse(clean);
	}

	/** 去掉 UTF-8 BOM（模组作者用记事本另存时很常见）。 */
	public static function removeBom(s:String):String
	{
		if (s == null) return null;
		if (s.length > 0 && s.charCodeAt(0) == 0xFEFF) return s.substr(1);
		return s;
	}
}
