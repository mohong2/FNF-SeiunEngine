package options;

import haxe.Json;
#if sys
import sys.io.File;
import sys.FileSystem;
#end
import haxe.io.Path;
import mohong.TraceManager;
import Language;
import ClientPrefs;
import Paths;
import SUtil;
import backend.CompatEngine;
#if (desktop && cpp && windows)
import mohong.Windows;
#end
/** Option category definition */
typedef OptionCategoryDef =
{
	var id:String;
	var nameKey:String;
	var defaultName:String;
	var type:String;
	@:optional var optionsFile:String;
	@:optional var substateClass:String;
	@:optional var stateClass:String;
	@:optional var rpcTitleKey:String;
	@:optional var modSource:String;
	@:optional var platform:String;
}

/** Single option JSON definition */
typedef OptionDef =
{
	var nameKey:String;
	var defaultName:String;
	var descKey:String;
	var defaultDesc:String;
	var variable:String;
	var type:String;
	@:optional var defaultValue:Dynamic;
	@:optional var displayFormat:String;
	@:optional var showBoyfriend:Bool;
	@:optional var minValue:Float;
	@:optional var maxValue:Float;
	@:optional var changeValue:Float;
	@:optional var scrollSpeed:Float;
	@:optional var decimals:Int;
	@:optional var options:Array<String>;
	@:optional var onChange:String;
	@:optional var onChangeLua:String;
	@:optional var onChangeHscript:String;
	@:optional var platform:String;
	@:optional var define:String;
	/** Engine compatibility gate: "0.7.3+" only shows in 0.7.3/1.0.4 modes, "0.6.3" only in 0.6.3 mode. */
	@:optional var compat:String;
	@:optional var modSource:String;
	@:optional var useModSettings:Bool;
}

/**
 * OptionLoader — Load/save options via JSON with mod extension support.
 *
 * Built-in options:    assets/data/options/<cat>.json  →  ClientPrefs.data
 * Mod options:         mods/<mod>/options/<cat>.json   →  modSettings[mod]
 * Global root:         mods/options/<cat>.json          →  modSettings['__GLOBAL__']
 * Callbacks:           onChange / onChangeLua / onChangeHscript
 */
class OptionLoader
{
	static final BUILTIN_OPTIONS_DIR:String = 'assets/data/options/';
	static final MOD_OPTIONS_DIR:String = 'options/';
	static final GLOBAL_ROOT_OPTIONS_PATH:String = 'options/';
	static final GLOBAL_ROOT_SOURCE:String = '__GLOBAL__';
	static var _cachedCategories:Array<OptionCategoryDef> = null;
	static var _callbacks:Map<String, Void->Void> = new Map();
	/** Cache of mergeAllTextsNamed results (languages / hit sounds / skins); cleared by reloadAll() for mod hot-reload. */
	static var _listCache:Map<String, Array<String>> = new Map();

	/** Cached Paths.mergeAllTextNamed: the options menu reads these lists on every visit and mobile disk access is slow. */
	static function mergedListCached(path:String, ?defaultDirectory:String):Array<String>
	{
		var key:String = path + '|' + (defaultDirectory != null ? defaultDirectory : '');
		var cached:Array<String> = _listCache.get(key);
		if (cached == null)
		{
			cached = Paths.mergeAllTextsNamed(path, defaultDirectory);
			if (cached == null) return null;
			_listCache.set(key, cached);
		}
		return cached.copy();
	}

	/** Register a callback for JSON onChange. */
	public static function setCallback(name:String, fn:Void->Void):Void
	{
		_callbacks.set(name, fn);
	}

	/** Batch register callbacks. */
	public static function setCallbacks(map:Map<String, Void->Void>):Void
	{
		for (k => v in map)
			_callbacks.set(k, v);
	}

	/** Clear all callbacks. */
	public static function clearCallbacks():Void
	{
		_callbacks.clear();
	}

	/** Get all categories (with optional Android filter). */
	public static function getCategories(?includeAndroid:Bool = false):Array<OptionCategoryDef>
	{
		if (_cachedCategories == null)
			reloadCategories();

		var result = _cachedCategories.copy();
		#if mobile
		if (!includeAndroid)
			result = result.filter(function(c) return c.id != 'android_settings');
		#end
		result = result.filter(function(c) return categoryAllowedOnPlatform(c));

		return result;
	}

	/** Filters categories by platform (same as an option's platform field). */
	static function categoryAllowedOnPlatform(cat:OptionCategoryDef):Bool
	{
		if (cat.platform == null)
			return true;

		return switch (cat.platform.toLowerCase())
		{
			case 'desktop': #if (desktop && !html5) true #else false #end;
			case 'mobile': #if mobile true #else false #end;
			case 'html5': #if html5 true #else false #end;
			default: true;
		};
	}

	/**
	 * Base directories that may hold the built-in option files, most preferred first.
	 * Sys.getCwd() is only ever set once at startup, so it can disagree with the resolved
	 * storage root; probing every candidate keeps a readable copy from being ignored.
	 */
	static function builtinBaseDirs():Array<String>
	{
		var dirs:Array<String> = [];
		#if sys
		var cwdDir:String = Sys.getCwd() + BUILTIN_OPTIONS_DIR;
		dirs.push(cwdDir);
		#if android
		for (root in SUtil.getStorageCandidateRoots())
		{
			var dir:String = root + BUILTIN_OPTIONS_DIR;
			if (dirs.indexOf(dir) < 0) dirs.push(dir);
		}
		#end
		#end
		return dirs;
	}

	/** Read a built-in option JSON from the first candidate root that has it. */
	static function readBuiltinJson(fileName:String):String
	{
		#if sys
		var cwdDir:String = Sys.getCwd() + BUILTIN_OPTIONS_DIR;
		for (baseDir in builtinBaseDirs())
		{
			var path:String = baseDir + fileName;
			try
			{
				if (!FileSystem.exists(path)) continue;
				var text:String = File.getContent(path);
				if (text == null || text.length == 0) continue;

				if (baseDir != cwdDir)
					TraceManager.warn('trace.options.builtinFallbackRoot',
						'Built-in options read from a fallback storage root: {}', [path]);
				return text;
			}
			catch (e:Dynamic)
			{
				TraceManager.warn('trace.options.builtinReadError', 'Could not read {}: {}', [path, e]);
			}
		}
		#end
		return null;
	}

	/** The APK-embedded copy of a built-in option JSON (readable before any extraction). */
	static function embeddedBuiltinJson(fileName:String):String
	{
		try
		{
			var assetPath:String = BUILTIN_OPTIONS_DIR + fileName;
			if (lime.utils.Assets.exists(assetPath, TEXT))
				return lime.utils.Assets.getText(assetPath);
		}
		catch (e:Dynamic) {}
		return null;
	}

	/** Parse an option JSON out of the embedded assets. */
	static function loadEmbeddedOptions(fileName:String, target:Array<Option>, ?extraCallbacks:Map<String, Void->Void>):Bool
	{
		var json:String = embeddedBuiltinJson(fileName);
		if (json == null)
			return false;

		try
		{
			var defs:Array<OptionDef> = Json.parse(json);
			for (def in defs)
			{
				def.modSource = null;
				var opt:Option = createOptionFromDef(def, extraCallbacks);
				if (opt != null) target.push(opt);
			}
			TraceManager.warn('trace.options.builtinEmbedded',
				'Options for {} came from the APK assets: no extracted copy was readable.', [fileName]);
			return true;
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.options.builtinEmbeddedError', 'Could not parse embedded {}: {}', [fileName, e]);
			return false;
		}
	}

	/**
	 * Code-built minimum category list, used when neither the disk copy nor the embedded
	 * copy is readable. The player must always be able to reach the language and storage
	 * settings, because those are what repairs a broken extraction.
	 */
	static function builtinFallbackCategories():Array<OptionCategoryDef>
	{
		var list:Array<OptionCategoryDef> = [];

		var add = function(id:String, nameKey:String, defaultName:String, optionsFile:String, ?platform:String)
		{
			list.push({
				id: id,
				nameKey: nameKey,
				defaultName: defaultName,
				type: 'settings',
				optionsFile: optionsFile,
				modSource: null,
				platform: platform
			});
		};

		add('general', 'option.general', 'General', 'general');
		add('gameplay', 'option.gameplay', 'Gameplay', 'gameplay');
		add('visuals', 'option.visuals', 'Visuals and UI', 'visuals');
		add('graphics', 'option.graphics', 'Graphics', 'graphics');
		add('extra_settings', 'option.advanced', 'Advanced', 'extra_settings');
		#if mobile
		add('android_settings', 'option.android_settings', 'Android Settings', 'android_settings', 'mobile');
		#end

		TraceManager.warn('trace.options.categoriesFallback',
			'Category list was empty; using the built-in minimum of {} categories.', [list.length]);
		return list;
	}

	/**
	 * Code-built minimum content for the pages that must never be empty: the language picker
	 * and the storage / auto-extract pair are exactly what a player needs to repair a bad
	 * extraction, so they are always offered.
	 */
	static function builtinFallbackOptions(fileName:String, target:Array<Option>, ?extraCallbacks:Map<String, Void->Void>):Void
	{
		var defs:Array<OptionDef> = [];

		switch (fileName)
		{
			case 'general':
				defs.push({
					nameKey: 'option.language',
					defaultName: 'Language',
					descKey: 'option.language.desc',
					defaultDesc: 'Change the language of the game.',
					variable: 'language',
					type: 'string',
					defaultValue: 'English',
					options: ['English'],
					onChange: 'onChangeLanguage'
				});
			#if mobile
			case 'android_settings':
				defs.push({
					nameKey: 'option.autoExtractAssets',
					defaultName: 'Auto-Extract Assets',
					descKey: 'option.autoExtractAssets.desc',
					defaultDesc: 'If enabled, the game extracts the necessary assets from the APK on first launch.',
					variable: 'autoExtractAssets',
					type: 'bool',
					defaultValue: true,
					platform: 'mobile',
					onChange: 'onChangeAutoExtractAssets'
				});
				defs.push({
					nameKey: 'option.storageType',
					defaultName: 'Storage Type',
					descKey: 'option.storageType.desc',
					defaultDesc: 'Choose how the game accesses storage.',
					variable: 'storageType',
					type: 'string',
					defaultValue: 'EXTERNAL_DATA',
					options: ['EXTERNAL_DATA', 'EXTERNAL', 'EXTERNAL_OBB', 'EXTERNAL_MEDIA'],
					platform: 'mobile',
					onChange: 'onChangeStorageType'
				});
			#end
		}

		if (defs.length == 0)
			return;

		for (def in defs)
		{
			var opt:Option = createOptionFromDef(def, extraCallbacks);
			if (opt != null) target.push(opt);
		}
		TraceManager.warn('trace.options.builtinFallbackOptions',
			'Page {} had no readable definition; using the built-in minimum.', [fileName]);
	}

	/** Reload categories from all sources. */
	public static function reloadCategories():Void
	{
		_cachedCategories = [];

		// Read the definitions from disk first (so an extracted copy or a mod edit wins),
		// then from the APK-embedded copy, then from a code-built minimum. Reading only
		// Sys.getCwd() left the entire settings menu empty whenever the process cwd and the
		// asset extraction root disagreed -- the "not a single option" bug.
		var json:String = readBuiltinJson('categories.json');
		if (json == null)
			json = embeddedBuiltinJson('categories.json');

		if (json != null)
		{
			try
			{
				var parsed:Array<OptionCategoryDef> = Json.parse(json);
				for (cat in parsed)
				{
					cat.modSource = null;
					_cachedCategories.push(cat);
				}
			}
			catch (e:Dynamic)
			{
				TraceManager.error('trace.options.categoriesLoadError', 'Failed to load builtin categories: {}', [e]);
			}
		}
		else
		{
			TraceManager.warn('trace.options.categoriesUnreadable',
				'categories.json is readable neither on disk nor in the APK; using the built-in minimum.');
		}

		#if MODS_ALLOWED
		var globalMods = Paths.getGlobalMods();
		for (mod in globalMods)
		{
			loadModCategories(mod, false);
		}

		loadGlobalRootCategories();

		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
		{
			loadModCategories(Paths.currentModDirectory, false);
		}

		for (cat in _cachedCategories)
		{
			if (cat.type != 'settings') continue;
			if (cat.optionsFile == null) continue;

			for (mod in globalMods)
			{
				checkModOptionsPatch(mod, cat.optionsFile);
			}
			if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			{
				checkModOptionsPatch(Paths.currentModDirectory, cat.optionsFile);
			}
		}
		#end

		// Never hand an empty list to the UI: a player whose resources are unreadable must
		// still reach the language and storage pages that repair the situation.
		if (_cachedCategories.length == 0)
			_cachedCategories = builtinFallbackCategories();
	}

	/** Load options for a category (supports dir/file/.patch). */
	public static function loadOptionsForCategory(category:OptionCategoryDef, ?extraCallbacks:Map<String, Void->Void>):Array<Option>
	{
		if (category.type != 'settings' || category.optionsFile == null)
			return [];

		var optionsArray:Array<Option> = [];
		var fileName = category.optionsFile;

		var isModCategory = (category.modSource != null && category.modSource.length > 0);

		if (isModCategory)
		{
			#if MODS_ALLOWED
			if (category.modSource == GLOBAL_ROOT_SOURCE)
				loadGlobalRootOptions(fileName, optionsArray, extraCallbacks);
			else
				loadModOptions(category.modSource, fileName, optionsArray, extraCallbacks, true);
			#end
		}
		else
		{
			#if sys
			// Probe every candidate root: the cwd is only set once at startup while the
			// resolved storage root can differ from it, so a readable copy must not be missed.
			for (baseDir in builtinBaseDirs())
			{
				loadOptionsFromBase(baseDir, fileName, optionsArray, extraCallbacks, null, true);
				if (optionsArray.length > 0)
					break;
			}
			#else
			loadOptionsFromBase(BUILTIN_OPTIONS_DIR, fileName, optionsArray, extraCallbacks, null, true);
			#end

			if (optionsArray.length == 0)
				loadEmbeddedOptions(fileName, optionsArray, extraCallbacks);

			if (optionsArray.length == 0)
				builtinFallbackOptions(fileName, optionsArray, extraCallbacks);

			postProcessOptions(optionsArray, fileName);

			#if MODS_ALLOWED
			var globalMods = Paths.getGlobalMods();
			for (mod in globalMods)
				loadModOptions(mod, fileName, optionsArray, extraCallbacks);

			loadGlobalRootOptions(fileName, optionsArray, extraCallbacks);

			if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
				loadModOptions(Paths.currentModDirectory, fileName, optionsArray, extraCallbacks);
			#end
		}

		return optionsArray;
	}

	/** Post-process special options (language list, console state). */
	static function postProcessOptions(options:Array<Option>, fileName:String):Void
	{
		for (opt in options)
		{
			switch (opt.variable)
			{
				case 'language':
					var langs:Array<String> = mergedListCached('lang/list.txt', 'assets');
					if (langs != null && langs.length > 0)
					{
						// Filter languages if the active mod has disableLanguages=true
						#if MODS_ALLOWED
						if (states.MainMenuState.selectedModFolder != null && states.MainMenuState.selectedModFolder.length > 0) {
							var cfg = backend.ModConfig.load(states.MainMenuState.selectedModFolder);
							if (cfg.disableLanguages) {
								// Only keep the current language so the option shows as read-only
								var curLang = opt.getValue();
								langs = [for (l in langs) if (l == curLang) l];
							}
						}
						#end
						opt.options = langs;
						var num:Int = langs.indexOf(opt.getValue());
						if (num > -1) opt.curOption = num;
					}

				case 'hitsound':
					// Hit sound list from data/hitsoundList.txt; players and mods can add names
					// and drop the files into sounds/hitsounds/ for custom hit sounds
					var hs:Array<String> = mergedListCached('data/hitsoundList.txt', 'assets');
					if (hs != null && hs.length > 0)
					{
						opt.options = hs;
						var num:Int = hs.indexOf(opt.getValue());
						if (num > -1) opt.curOption = num;
					}

				case 'judgementPreset':
					// Judgement preset list from data/timingPresets.txt
					backend.Ratings.loadPresets();
					var presets:Array<String> = backend.Ratings.presets.copy();
					if (presets.indexOf('Custom') < 0) presets.push('Custom');
					opt.options = presets;

					// Automatically labelled Custom when the current value does not match judgementTimings
					var curPreset:String = opt.getValue();
					var timings:Array<Int> = ClientPrefs.data.judgementTimings;
					var matchesPreset:Bool = false;
					if (curPreset != null && curPreset != 'Custom' && timings != null && timings.length == 4)
					{
						var presetTimings:Array<Int> = backend.Ratings.returnPreset(curPreset);
						matchesPreset = (presetTimings != null && presetTimings.length == 4
							&& presetTimings[0] == timings[0] && presetTimings[1] == timings[1]
							&& presetTimings[2] == timings[2] && presetTimings[3] == timings[3]);
					}
					if (!matchesPreset && curPreset != 'Custom')
					{
						ClientPrefs.data.judgementPreset = 'Custom';
						curPreset = 'Custom';
					}
					var num:Int = presets.indexOf(curPreset);
					if (num > -1) opt.curOption = num;

				case 'noteSkin':
					// Free note-skin switching: the list comes from images/noteSkins/list.txt (mods may append)
					var skins:Array<String> = mergedListCached('images/noteSkins/list.txt');
					if (skins != null && skins.length > 0)
					{
						if (skins.indexOf(ClientPrefs.defaultData.noteSkin) < 0)
							skins.insert(0, ClientPrefs.defaultData.noteSkin);
						opt.options = skins;
						var num:Int = skins.indexOf(opt.getValue());
						if (num > -1) opt.curOption = num;
					}

				case 'splashSkin':
					// Free splash-skin switching: the list comes from images/noteSplashes/list.txt
					var skins:Array<String> = mergedListCached('images/noteSplashes/list.txt');
					if (skins != null && skins.length > 0)
					{
						if (skins.indexOf(ClientPrefs.defaultData.splashSkin) < 0)
							skins.insert(0, ClientPrefs.defaultData.splashSkin);
						opt.options = skins;
						var num:Int = skins.indexOf(opt.getValue());
						if (num > -1) opt.curOption = num;
					}

				case 'traceConsoleEnabled':
					#if (desktop && cpp && windows)
					opt.getValue = function() {
						return mohong.Windows.hasConsole();
					};
					#end
			}
		}
	}

	/** Clear caches. Call after language switch or hot-reload. */
	public static function reloadAll():Void
	{
		_cachedCategories = null;
		_listCache = new Map();
	}

	#if MODS_ALLOWED
	static function loadModCategories(mod:String, isPatch:Bool):Void
	{
		var modPath = Paths.mods(mod + '/' + MOD_OPTIONS_DIR + 'categories.json');
		if (!FileSystem.exists(modPath)) return;

		try
		{
			var json = File.getContent(modPath);
			var parsed:Array<OptionCategoryDef> = Json.parse(json);
			for (cat in parsed)
			{
				cat.modSource = mod;
				var existingIdx = -1;
				for (i in 0..._cachedCategories.length)
				{
					if (_cachedCategories[i].id == cat.id)
					{
						existingIdx = i;
						break;
					}
				}
				if (existingIdx >= 0)
					_cachedCategories[existingIdx] = cat;
				else
					_cachedCategories.push(cat);
			}
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.options.modCategoriesError', 'Failed to load mod categories from {}: {}', [modPath, e]);
		}
	}

	static function checkModOptionsPatch(mod:String, optionsFile:String):Void
	{
		var patchPath = Paths.mods(mod + '/' + MOD_OPTIONS_DIR + optionsFile + '.json');
		if (FileSystem.exists(patchPath))
		{
			TraceManager.info('trace.options.modPatch', 'Found option patch for {} from mod {}', [optionsFile, mod]);
		}
	}

	/** Load categories from mods/options/categories.json (global root). */
	static function loadGlobalRootCategories():Void
	{
		var path = Paths.mods(GLOBAL_ROOT_OPTIONS_PATH + 'categories.json');
		if (!FileSystem.exists(path)) return;

		try
		{
			var json = File.getContent(path);
			var parsed:Array<OptionCategoryDef> = Json.parse(json);
			for (cat in parsed)
			{
				cat.modSource = GLOBAL_ROOT_SOURCE;
				var existingIdx = -1;
				for (i in 0..._cachedCategories.length)
				{
					if (_cachedCategories[i].id == cat.id)
					{
						existingIdx = i;
						break;
					}
				}
				if (existingIdx >= 0)
					_cachedCategories[existingIdx] = cat;
				else
					_cachedCategories.push(cat);
			}
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.options.modCategoriesError', 'Failed to load global root categories: {}', [e]);
		}
	}

	/** Load options from a mod's options/ dir (supports dir/file/.patch). */
	static function loadModOptions(mod:String, fileName:String, target:Array<Option>,
			?extraCallbacks:Map<String, Void->Void>, primaryOnly:Bool = false):Void
	{
		var baseDir = Paths.mods(mod + '/' + MOD_OPTIONS_DIR);
		loadOptionsFromBase(baseDir, fileName, target, extraCallbacks, mod, primaryOnly);
	}

	/** Load options from global root (mods/options/). */
	static function loadGlobalRootOptions(fileName:String, target:Array<Option>,
			?extraCallbacks:Map<String, Void->Void>):Void
	{
		var baseDir = Paths.mods(GLOBAL_ROOT_OPTIONS_PATH);
		loadOptionsFromBase(baseDir, fileName, target, extraCallbacks, GLOBAL_ROOT_SOURCE, true);
	}
	#end

	/** Load: dir/*.json → file.json → file.patch.json */
	static function loadOptionsFromBase(baseDir:String, fileName:String, target:Array<Option>,
			?extraCallbacks:Map<String, Void->Void>, modSource:String, primaryOnly:Bool = false):Void
	{
		var dirPath = baseDir + fileName + '/';
		var singlePath = baseDir + fileName + '.json';
		var patchPath = baseDir + fileName + '.patch.json';

		#if sys
			if (FileSystem.exists(dirPath) && FileSystem.isDirectory(dirPath))
		{
			var files = FileSystem.readDirectory(dirPath);
			files.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
			var loadedCount = 0;
			for (file in files)
			{
				if (!file.endsWith('.json')) continue;
				var fullPath = dirPath + file;
				if (loadSingleJsonFile(fullPath, target, extraCallbacks, modSource))
					loadedCount++;
			}
			if (loadedCount > 0)
				TraceManager.info('trace.options.modLoaded', 'Loaded {} option files from {} for mod {}', [loadedCount, fileName, modSource]);
			return;
		}

		if (FileSystem.exists(singlePath))
		{
			if (loadSingleJsonFile(singlePath, target, extraCallbacks, modSource))
				TraceManager.info('trace.options.modLoaded', 'Loaded options from {} (mod {})', [fileName, modSource]);
			return;
		}

		if (!primaryOnly && FileSystem.exists(patchPath))
		{
			if (loadSingleJsonFile(patchPath, target, extraCallbacks, modSource))
				TraceManager.info('trace.options.modLoaded', 'Loaded patch options from {} (mod {})', [fileName, modSource]);
		}
		#else
		if (loadSingleJsonFile(singlePath, target, extraCallbacks, modSource))
			TraceManager.info('trace.options.modLoaded', 'Loaded options from {} (mod {})', [fileName, modSource]);
		#end
	}

	/** Parse a single JSON file into Options and append to target. */
	static function loadSingleJsonFile(path:String, target:Array<Option>,
			?extraCallbacks:Map<String, Void->Void>, modSource:String):Bool
	{
		try
		{
			#if sys
			if (!FileSystem.exists(path)) return false;
			var json = File.getContent(path);
			#else
			if (!lime.utils.Assets.exists(path, TEXT)) return false;
			var json = lime.utils.Assets.getText(path);
			#end
			var defs:Array<OptionDef> = Json.parse(json);
			for (def in defs)
			{
				def.modSource = modSource;
				var opt = createOptionFromDef(def, extraCallbacks);
				if (opt != null) target.push(opt);
			}
			return true;
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.options.modOptionsError', 'Failed to load options from {}: {}', [path, e]);
			return false;
		}
	}

	static function createOptionFromDef(def:OptionDef, ?extraCallbacks:Map<String, Void->Void>):Option
	{
		// Compatibility gate: 0.7.3+ only options such as skin switching only show in the matching mode
		if (def.compat != null && def.compat.length > 0)
		{
			var show:Bool = switch (def.compat.toLowerCase())
			{
				case '0.7.3+' | 'modern': CompatEngine.isModern();
				case '0.6.3' | '063': CompatEngine.is063();
				default: true;
			}
			if (!show) return null;
		}

		if (def.platform != null)
		{
			var shouldInclude = switch (def.platform.toLowerCase())
			{
				case 'desktop': #if (desktop && !html5) true #else false #end;
				case 'mobile':  #if mobile true #else false #end;
				case 'html5':   #if html5 true #else false #end;
				default: true;
			}
			if (!shouldInclude) return null;
		}

		#if !CHECK_FOR_UPDATES
		if (def.define == 'CHECK_FOR_UPDATES') return null;
		#end

		var displayName = Language.get(def.nameKey, def.defaultName);
		var description = Language.get(def.descKey, def.defaultDesc);

		var opt = new Option(displayName, description, def.variable, def.type, def.defaultValue,
			def.options != null ? def.options : null);

		if (def.showBoyfriend != null) opt.showBoyfriend = def.showBoyfriend;
		if (def.displayFormat != null) opt.displayFormat = def.displayFormat;
		if (def.scrollSpeed != null) opt.scrollSpeed = def.scrollSpeed;
		if (def.changeValue != null) opt.changeValue = def.changeValue;
		if (def.decimals != null) opt.decimals = def.decimals;
		if (def.minValue != null) opt.minValue = def.minValue;
		if (def.maxValue != null) opt.maxValue = def.maxValue;

		var useMod = (def.modSource != null && def.modSource.length > 0) || (def.useModSettings == true);
		if (useMod)
		{
			var storageKey = def.modSource != null ? def.modSource : '__custom__';
			bindToModSettings(opt, storageKey, def.variable);
		}

		var callbacks:Array<Void->Void> = [];

		if (def.onChange != null && def.onChange.length > 0)
		{
			var fn = null;
			if (extraCallbacks != null && extraCallbacks.exists(def.onChange))
				fn = extraCallbacks.get(def.onChange);
			else if (_callbacks.exists(def.onChange))
				fn = _callbacks.get(def.onChange);

			if (fn != null)
				callbacks.push(fn);
			else
				TraceManager.warn('trace.options.unknownCallback',
					'Unknown callback "{}". Register it via OptionLoader.setCallback().', [def.onChange]);
		}

		if (def.onChangeLua != null && def.onChangeLua.length > 0)
		{
			callbacks.push(function() {
				executeLuaScript(def.onChangeLua, def.modSource, def.variable, opt.getValue());
			});
		}

		if (def.onChangeHscript != null && def.onChangeHscript.length > 0)
		{
			callbacks.push(function() {
				executeHscript(def.onChangeHscript, def.modSource, def.variable, opt.getValue());
			});
		}

		if (callbacks.length > 0)
		{
			opt.onChange = function() {
				for (cb in callbacks) cb();
			};
		}

		return opt;
	}

	/** Resolve script path: mod dir → modFolders → raw path */
	static function resolveScriptPath(path:String, ?modSource:String):String
	{
		#if sys
		if (modSource != null && modSource.length > 0 && path.charAt(0) != '/' && path.indexOf(':') == -1)
		{
			var modPath = Paths.modFolders(modSource + '/' + path);
			if (FileSystem.exists(modPath))
				return modPath;
		}
		var modPath = Paths.modFolders(path);
		if (FileSystem.exists(modPath))
			return modPath;
		if (FileSystem.exists(path))
			return path;
		#end
		return path;
	}

	/** Execute a Lua script (one-shot). Injects optionVariable/optionValue. */
	static function executeLuaScript(path:String, ?modSource:String, ?variable:String, ?value:Dynamic):Void
	{
		#if LUA_ALLOWED
		var resolved = resolveScriptPath(path, modSource);
		if (!FileSystem.exists(resolved))
		{
			TraceManager.error('trace.options.scriptNotFound', 'Lua script not found: {}', [resolved]);
			return;
		}
		try
		{
			var luaInstance = new script.lua.FunkinLua(resolved);
			if (variable != null) luaInstance.set('optionVariable', variable);
			if (value != null) luaInstance.set('optionValue', value);
			luaInstance.call('onOptionChange', [variable, value]);
			TraceManager.info('trace.options.luaExecuted', 'Executed Lua callback: {}', [resolved]);
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.options.luaError', 'Lua callback error ({}): {}', [path, e]);
		}
		#else
		TraceManager.warn('trace.options.luaNotAllowed', 'Lua is not enabled. Cannot execute: {}', [path]);
		#end
	}

	/** Execute an HScript (one-shot). Injects optionVariable/optionValue. */
	static function executeHscript(path:String, ?modSource:String, ?variable:String, ?value:Dynamic):Void
	{
		#if HSCRIPT_ALLOWED
		var resolved = resolveScriptPath(path, modSource);
		if (!FileSystem.exists(resolved))
		{
			TraceManager.error('trace.options.scriptNotFound', 'HScript not found: {}', [resolved]);
			return;
		}
		try
		{
			var hscriptInstance = new script.hscript.HScript(resolved);
			if (variable != null) hscriptInstance.variables.set('optionVariable', variable);
			if (value != null) hscriptInstance.variables.set('optionValue', value);
			hscriptInstance.call('onOptionChange', [variable, value]);
			TraceManager.info('trace.options.hscriptExecuted', 'Executed HScript callback: {}', [resolved]);
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.options.hscriptError', 'HScript callback error ({}): {}', [path, e]);
		}
		#else
		TraceManager.warn('trace.options.hscriptNotAllowed', 'HScript is not enabled. Cannot execute: {}', [path]);
		#end
	}

	/** Bind getValue/setValue to modSettings[storageKey][variable]. */
	static function bindToModSettings(opt:Option, storageKey:String, variable:String):Void
	{
		if (ClientPrefs.data.modSettings == null)
			ClientPrefs.data.modSettings = new Map();

		if (!ClientPrefs.data.modSettings.exists(storageKey))
			ClientPrefs.data.modSettings.set(storageKey, new Map());

		var staleValue:Dynamic = null;
		try {
			staleValue = Reflect.getProperty(ClientPrefs.data, variable);
		} catch(_) {}

		var modMap = ClientPrefs.data.modSettings.get(storageKey);

		if (staleValue != null && !modMap.exists(variable))
			modMap.set(variable, staleValue);

		try {
			Reflect.setProperty(ClientPrefs.data, variable, null);
		} catch(_) {}

		if (!modMap.exists(variable) && opt.defaultValue != null)
			modMap.set(variable, opt.defaultValue);

		opt.getValue = function() {
			if (ClientPrefs.data.modSettings == null) return null;
			var map = ClientPrefs.data.modSettings.get(storageKey);
			if (map == null) return null;
			return map.get(variable);
		};

		opt.setValue = function(value:Dynamic) {
			if (ClientPrefs.data.modSettings == null)
				ClientPrefs.data.modSettings = new Map();
			if (!ClientPrefs.data.modSettings.exists(storageKey))
				ClientPrefs.data.modSettings.set(storageKey, new Map());
			ClientPrefs.data.modSettings.get(storageKey).set(variable, value);
			return value;
		};
	}

	static function resolveDynamicCallback(name:String):Void->Void
	{
		TraceManager.warn('trace.options.unknownCallback', 'Unknown callback "{}". Register it via OptionLoader.setCallback().', [name]);
		return null;
	}

	public static function getCategoryName(cat:OptionCategoryDef):String
	{
		return Language.get(cat.nameKey, cat.defaultName);
	}
}
