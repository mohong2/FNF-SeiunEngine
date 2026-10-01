package;

import haxe.Json;
import backend.Mods;
#if !js
import sys.FileSystem;
import sys.io.File;
#end

class Language
{
    private static var strings:Map<String, String> = new Map();
    private static var loadedFiles:Map<String, Bool> = new Map();
    private static var currentLang:String = null;

    public static function load(?lang:String):Void
    {
        if(lang == null)
            lang = ClientPrefs.data.language;

        // 语言切换时清理旧数据，防止内存泄漏
        if(currentLang != null && currentLang != lang) {
            reset();
        }

        currentLang = lang;
        loadDirectory(Paths.locale(lang));
        loadDirectory(Paths.localeMod(lang));

        // ---- Psych Engine 1.0.4 兼容 ----
        // 1.0.4 用的是纯文本 `.lang` 文件 (data/<语言>.lang)，键值行形如
        //   key: "value"
        // 而本引擎原生用 JSON (assets/lang/<语言>/*.json)。1.0.4 模组只会带
        // `.lang`，所以这里额外把 `.lang` 合并进同一张表，供 `getFileTranslation`
        // 与 `getTranslationPhrase` 使用。两条路径互不覆盖 JSON 里已有的键。
        loadLegacy104LangFiles(lang);
    }

    // ==================================================================
    // Psych Engine 1.0.4 兼容层
    // English: Psych Engine 1.0.4 compatibility layer
    // ==================================================================

    /** 1.0.4 `.lang` 词组表 (键已经过 1.0.4 的 lower/formatKey 规范化)。 */
    private static var phrases104:Map<String, String> = new Map();

    /** 1.0.4 formatKey: 空格转下划线、去掉标点、转小写。 */
    private static var __formatKeyRe = ~/[~&\\\/;:<>#.,'"%?!]/g;

    public static function formatKey104(key:String):String
    {
        if(key == null) return '';
        return __formatKeyRe.replace(key.replace(' ', '_'), '').toLowerCase().trim();
    }

    /**
     * 读取并合并所有模组 / 引擎目录里的 1.0.4 `.lang` 文本文件。
     * English: Merge every 1.0.4-style `.lang` text file from mods and the engine.
     */
    private static function loadLegacy104LangFiles(lang:String):Void
    {
        if(lang == null || lang.length == 0) return;

        var candidates:Array<String> = [];
        // 1.0.4 的 ClientPrefs.data.language 默认值是 'English (US)'，文件名却是
        // `English.lang`，所以要同时尝试完整名与主语言名。
        candidates.push(lang);
        var spaceIdx:Int = lang.indexOf(' ');
        if(spaceIdx > 0) candidates.push(lang.substr(0, spaceIdx));
        var dashIdx:Int = lang.indexOf('-');
        if(dashIdx > 0) candidates.push(lang.substr(0, dashIdx));
        if(!candidates.contains('English')) candidates.push('English');

        var seen:Map<String, Bool> = new Map();
        for(name in candidates)
        {
            if(name == null || name.length == 0 || seen.exists(name)) continue;
            seen.set(name, true);

            var loaded:Array<String> = null;
            try {
                loaded = Mods.mergeAllTextsNamed('data/' + name + '.lang');
            } catch(e:Dynamic) {
                loaded = null;
            }
            if(loaded == null) continue;

            for(text in loaded)
            {
                if(text == null) continue;
                parseLegacyLangText(text);
            }
        }
    }

    /** 解析一份 1.0.4 `.lang` 文本（可含多行），把 key/value 写进 phrases104。 */
    private static function parseLegacyLangText(text:String):Void
    {
        var lines:Array<String> = text.split('\n');
        for(num in 0...lines.length)
        {
            var phrase:String = lines[num];
            if(phrase == null) continue;
            phrase = StringTools.trim(phrase);
            if(phrase.length == 0) continue;

            if(num < 1 && !phrase.contains(':'))
            {
                phrases104.set('language_name', phrase);
                continue;
            }

            if(phrase.length < 4 || phrase.startsWith('//')) continue;

            var n:Int = phrase.indexOf(':');
            if(n < 0) continue;

            var rawKey:String = StringTools.trim(phrase.substr(0, n)).toLowerCase();
            if(rawKey.length == 0) continue;

            var value:String = phrase.substr(n);
            n = value.indexOf('"');
            if(n < 0) continue;
            var lastQuote:Int = value.lastIndexOf('"');
            if(lastQuote <= n) continue;

            var finalValue:String = value.substring(n + 1, lastQuote).split('\\n').join('\n');
            // 同时登记原始小写键与 1.0.4 formatKey，保证两种查法都能命中。
            phrases104.set(rawKey, finalValue);
            phrases104.set(formatKey104(rawKey), finalValue);
        }
    }

    /**
     * 1.0.4 `getFileTranslation`: 把(资源)路径经词组表翻译一次。
     * 未命中时原样返回 —— 与 1.0.4 行为一致。
     */
    public static function getFileTranslation(key:String):String
    {
        if(key == null) return null;
        var lookup:String = StringTools.trim(key).toLowerCase();
        if(phrases104.exists(lookup)) return phrases104.get(lookup);
        var formatted:String = formatKey104(key);
        if(phrases104.exists(formatted)) return phrases104.get(formatted);
        return key;
    }

    /**
     * 1.0.4 `getTranslationPhrase`: 取词组并做 {1} / {2} … 占位替换。
     * 未命中时回落到 defaultPhrase，再回落到 key 本身。
     */
    public static function getTranslationPhrase(key:String, ?defaultPhrase:String, ?values:Array<Dynamic>):String
    {
        var str:String = null;
        if(key != null)
        {
            var formatted:String = formatKey104(key);
            if(phrases104.exists(formatted)) str = phrases104.get(formatted);
            else if(phrases104.exists(key.toLowerCase())) str = phrases104.get(key.toLowerCase());
        }
        if(str == null) str = defaultPhrase;
        if(str == null) str = key;
        if(str == null) return null;

        if(values != null)
        {
            for(num in 0...values.length)
                str = str.split('{' + (num + 1) + '}').join(Std.string(values[num]));
        }
        return str;
    }

    /** 是否加载到过任何 1.0.4 `.lang` 词组。 */
    public static function hasLegacyPhrases():Bool return Lambda.count(phrases104) > 0;

    private static function loadDirectory(path:String):Void
    {
        if(path == null) return;

        var files:Array<String> = [];
        #if js
        var allAssets:Array<String> = lime.utils.Assets.list();
        var prefix:String = path + '/';
        for(asset in allAssets)
        {
            if(asset.startsWith(prefix) && asset.endsWith('.json'))
                files.push(asset.substr(prefix.length));
        }
        if(files.length == 0)
        {
            var known:Array<String> = [
                'English.json', 'Android.json', 'option.json', 'playstate.json', 'pause.json',
                'ResultsScreen.json', 'ScoreHistorySubstate.json',
                'characterEditor.json', 'creditsEditor.json',
                'dialogueCharacterEditor.json', 'dialogueEditor.json',
                'menuCharacterEditor.json', 'newchartEditor.json',
                'script.json', 'weekEditor.json', 'backgroundEditor.json',
                'CrashCatcherState.json', 'GameplayChangersSubstate.json'
            ];
            for(name in known)
            {
                var full:String = path + '/' + name;
                if(lime.utils.Assets.exists(full, TEXT))
                    files.push(name);
            }
        }
        #else
        if(!FileSystem.exists(path) || !FileSystem.isDirectory(path)) return;
        try {
            files = FileSystem.readDirectory(path);
        } catch(e:Dynamic) {
            trace('Failed to read language directory: $path');
            return;
        }
        #end

        for(file in files) {
            if(!file.endsWith(".json")) continue;

            var filePath:String = path + "/" + file;
            // 跳过已加载的文件，避免重复解析
            if(loadedFiles.exists(filePath)) continue;

            try {
                #if js
                var rawJson:String = lime.utils.Assets.getText(filePath);
                if(rawJson == null) continue;
                #else
                var rawJson:String = File.getContent(filePath);
                #end
                var parsedData:Dynamic = Json.parse(rawJson);

                for(field in Reflect.fields(parsedData)) {
                    strings.set(field, Reflect.field(parsedData, field));
                }
                loadedFiles.set(filePath, true);
            } catch(e:Dynamic) {
                trace('Failed to load language file: $filePath');
            }
        }
    }

    public static inline function get(key:String, ?defaultText:String):String
    {
        return strings.exists(key) ? strings.get(key) : (defaultText != null ? defaultText : key);
    }

    public static inline function has(key:String):Bool
    {
        return strings.exists(key);
    }

    /** 重新加载语言（清空缓存后重新加载） */
    public static function reload(?lang:String):Void
    {
        reset();
        load(lang);
    }

    /** 释放所有已加载的语言资源 */
    public static function reset():Void
    {
        strings.clear();
        loadedFiles.clear();
        phrases104.clear();
        currentLang = null;
    }
}
