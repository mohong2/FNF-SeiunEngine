package;

import lime.system.System as LimeSystem;
#if android
import android.content.Context as AndroidContext;
import android.os.Environment as AndroidEnvironment;
import android.os.Build;
import android.Permissions as AndroidPermissions;
import android.Settings as AndroidSettings;
import android.Tools as AndroidTools;
#end
#if sys
import sys.FileSystem;
import sys.io.File;
#end

using StringTools;

/**
 * A storage class for mobile.
 * @author Mihai Alexandru (M.A. Jigsaw)
 */
class SUtil
{
	#if android
	static var cachedStorageType:String = null;
	static var cachedStoragePath:String = '';
	static var allFilesDialogShown:Bool = false;
	static var overlayDialogShown:Bool = false;
	static var languageLoadTried:Bool = false;

	/** Try to load the user's saved language before early Android popups. */
	static function ensureAndroidLanguageLoaded():Void
	{
		if (languageLoadTried) return;
		languageLoadTried = true;

		try
		{
			flixel.FlxG.save.bind('funkin', 'ninjamuffin99');
			var savedLang:String = 'English';
			if (flixel.FlxG.save.data != null && Reflect.hasField(flixel.FlxG.save.data, 'language'))
			{
				var langVal:Dynamic = Reflect.field(flixel.FlxG.save.data, 'language');
				if (langVal != null)
					savedLang = Std.string(langVal);
			}
			if (savedLang == null || savedLang.length == 0)
				savedLang = 'English';
			Language.load(savedLang);
		}
		catch (e:Dynamic) {}
	}

	/**
	 * Version-aware default storage type:
	 * - Android 11+ (API 30+) without "All files access" cannot write to public
	 *   external storage, so we default to the app-specific directory which
	 *   never requires permissions.
	 * - Older Android (or when All-files access is granted) keeps the classic
	 *   public `.funkin` folder.
	 */
	public static function getDefaultStorageType():String
	{
		if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R && !AndroidEnvironment.isExternalStorageManager())
			return "EXTERNAL_DATA";
		return "EXTERNAL";
	}
	#end

	#if sys
	public static function getStorageDirectory(?force:Bool = false):String
	{
		var daPath:String = '';
		#if android
		// Priority: 1) ClientPrefs.storageType (user choice)  2) version-aware default  3) fallback chain
		var preferredType:String = ClientPrefs.data.storageType;
		if (preferredType == null || preferredType.length == 0)
			preferredType = getDefaultStorageType();

		// Cache the resolved path so Main.new() and TitleState agree on the same
		// location even before ClientPrefs is fully loaded.
		if (!force && cachedStorageType != null && cachedStorageType == preferredType && cachedStoragePath.length > 0)
			return cachedStoragePath;

		// Try preferred type first, then fallback chain
		var fallbackOrder:Array<String> = [preferredType, "EXTERNAL_DATA", "EXTERNAL", "INTERNAL", "EXTERNAL_OBB", "EXTERNAL_MEDIA"];
		// Deduplicate while preserving order
		var seen:Map<String, Bool> = [];
		var uniqueFallback:Array<String> = [];
		for (t in fallbackOrder) {
			if (!seen.exists(t)) { seen.set(t, true); uniqueFallback.push(t); }
		}

		var lastError:String = '';
		for (stType in uniqueFallback)
		{
			try {
				daPath = force ? StorageType.fromStrForce(stType) : StorageType.fromStr(stType);
				daPath = haxe.io.Path.addTrailingSlash(daPath);
				if (!FileSystem.exists(daPath))
					FileSystem.createDirectory(daPath);
				// Verify the directory is actually writable before committing to
				// it — public external storage silently fails on many Android
				// 11+ devices when "All files access" is missing, which used to
				// make asset extraction fail on some versions and work on others.
				if (!AndroidTools.isDirectoryWritable(daPath))
					throw 'Storage directory is not writable: $daPath';

				cachedStorageType = stType;
				cachedStoragePath = daPath;
				// 只更新内存值。开机走到这里时存档尚未加载 (loadPrefs 还没运行,
				// storageType 恒为 ""), 之前在这里调用 ClientPrefs.saveSettings()
				// 会把默认键位写进 controls_v3, 覆盖玩家已保存的按键绑定 ——
				// 安卓每次冷启动按键被重置的根因。落盘交给后续正常保存流程。
				ClientPrefs.data.storageType = stType;
				lastError = '';
				break;
			} catch (e:Dynamic) {
				lastError = Std.string(e);
				continue;
			}
		}

		// All fallbacks failed — last resort
		if (lastError.length > 0)
		{
			daPath = LimeSystem.applicationStorageDirectory;
			try {
				if (!FileSystem.exists(daPath))
					FileSystem.createDirectory(daPath);
			} catch (_:Dynamic) {}
		}
		#elseif mac
		// macOS: .app 的资源全部位于 bundle 的 Contents/Resources 里
		// （assets/、mods/、lang/ 等），而代码里大量磁盘读取是相对路径。
		// 因此把工作/存储目录直接指向 Resources，行为与 Windows 一致。
		// 注意：应用若被放到系统保护目录（如 /Applications），bundle 内
		// 可能不可写；届时再改回 LimeSystem.applicationStorageDirectory。
		daPath = haxe.io.Path.directory(Sys.programPath()) + "/../Resources/";
		try {
			if (daPath == null || daPath.length == 0)
				daPath = LimeSystem.applicationDirectory;
			if (!FileSystem.exists(daPath))
				FileSystem.createDirectory(daPath);
		} catch (e:Dynamic) {}
		#elseif ios
		daPath = LimeSystem.documentsDirectory;
		#else
		daPath = Sys.getCwd();
		#end

		return daPath;
	}

	public static function mkDirs(directory:String):Void
	{
		try {
			if (FileSystem.exists(directory) && FileSystem.isDirectory(directory))
				return;
		} catch (e:haxe.Exception) {
			CoolUtil.traceMsg('trace.folderError', 'Something went wrong while looking at folder. ({})', [e.message]);
		}

		var total:String = '';
		if (directory.substr(0, 1) == '/')
			total = '/';

		var parts:Array<String> = directory.split('/');
		if (parts.length > 0 && parts[0].indexOf(':') > -1)
			parts.shift();

		for (part in parts)
		{
			if (part != '.' && part != '')
			{
				if (total != '' && total != '/')
					total += '/';

				total += part;

				try
				{
					if (!FileSystem.exists(total))
						FileSystem.createDirectory(total);
				}
				catch (e:haxe.Exception)
					CoolUtil.traceMsg('trace.folderCreateError', 'Error while creating folder. ({})', [e.message]);
			}
		}
	}

	public static function saveContent(fileName:String = 'file', fileExtension:String = '.json',
			fileData:String = 'You forgor to add somethin\' in yo code :3'):Void
	{
		try
		{
			if (!FileSystem.exists('saves'))
				FileSystem.createDirectory('saves');

			File.saveContent('saves/' + fileName + fileExtension, fileData);
			showPopUp(
				Language.get('SUtil.save.success.message', '{file} file has been saved.').replace('{file}', fileName),
				Language.get('SUtil.save.success.title', 'Success!'));
		}
		catch (e:haxe.Exception)
			CoolUtil.traceMsg('trace.fileSaveError', 'File couldn\'t be saved. ({})', [e.message]);
	}

	#if android
	public static function doPermissionsShit():Void
	{
		ensureAndroidLanguageLoaded();
		try {
			var sdkInt = android.os.Build.VERSION.SDK_INT;

			var granted = AndroidPermissions.getGrantedPermissions();

			// Android 10 (API 29) and below: with requestLegacyExternalStorage
			// in the manifest, READ/WRITE_EXTERNAL_STORAGE grant full access to
			// the public /storage/emulated/0 root (no root needed).
			if (sdkInt <= android.os.Build.VERSION_CODES.Q)
			{
				if (!granted.contains('android.permission.WRITE_EXTERNAL_STORAGE'))
					AndroidPermissions.requestPermission('WRITE_EXTERNAL_STORAGE');
				if (!granted.contains('android.permission.READ_EXTERNAL_STORAGE'))
					AndroidPermissions.requestPermission('READ_EXTERNAL_STORAGE');
			}
			// Android 11+ (API 30+): MANAGE_EXTERNAL_STORAGE (All files access)
			// is a special permission - the normal request dialog cannot grant
			// it, so it is prompted later (after Language.load) by
			// maybeRequestAllFilesAccess(), which uses the engine's localized
			// dialogs instead of hardcoded Chinese/English strings.

			// Android 13+ notification permission
			if (sdkInt >= android.os.Build.VERSION_CODES.TIRAMISU && !granted.contains('android.permission.POST_NOTIFICATIONS'))
				AndroidPermissions.requestPermission('POST_NOTIFICATIONS');

			try {
				var finalPath = SUtil.getStorageDirectory();
				if (!FileSystem.exists(finalPath))
					FileSystem.createDirectory(finalPath);
			} catch (e:Dynamic) {
				try {
					var fallbackPath = StorageType.fromStr("EXTERNAL_DATA");
					if (!FileSystem.exists(fallbackPath))
						FileSystem.createDirectory(fallbackPath);
				} catch (e2:Dynamic) {
					var folderMsg:String = Language.get('SUtil.error.createFolderMessage',
						'Please create folder to\n{path}\nPress OK to close the game')
						.replace('{path}', SUtil.getStorageDirectory(true));
					showPopUp(folderMsg, Language.get('SUtil.error.createFolderTitle', 'Error!'));
					LimeSystem.exit(1);
				}
			}
		} catch (e:Dynamic) {
			CoolUtil.traceMsg('trace.permissionsError', 'Permissions error: {}', [Std.string(e)]);
			showPopUp(
				Language.get('SUtil.error.permissionMessage', 'Permission error occurred. Please grant storage permissions manually.'),
				Language.get('SUtil.error.permissionTitle', 'Error'));
		}
	}

	/**
	 * Android 11+ "All files access" prompt.
	 * Called after Language.load so the dialog is properly localized, and uses
	 * backend.Dialog (Material-styled native dialog) instead of hardcoded text.
	 */
	public static function maybeRequestAllFilesAccess():Void
	{
		try
		{
			if (allFilesDialogShown) return;
			if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) return;
			if (AndroidEnvironment.isExternalStorageManager()) return;

			allFilesDialogShown = true;
			backend.Dialog.showCustom(
				Language.get('SUtil.allFiles.title', 'All files access required'),
				Language.get('SUtil.allFiles.message',
					'To let every Android user put mods/saves in the public folder '
					+ '(no root, file manager can access directly), please grant '
					+ '"All files access".\n\nIf you decline, the game will use the '
					+ 'app-specific directory instead, and mod installation will be '
					+ 'more troublesome.'),
				[
					{name: Language.get('SUtil.allFiles.open', 'Open Settings'), callback: function() AndroidSettings.requestSetting('MANAGE_APP_ALL_FILES_ACCESS_PERMISSION')},
					{name: Language.get('SUtil.allFiles.notNow', 'Not Now'), callback: function() {}}
				],
				false);
		}
		catch (e:Dynamic)
		{
			try { AndroidSettings.requestSetting('MANAGE_APP_ALL_FILES_ACCESS_PERMISSION'); }
			catch (_:Dynamic) {}
		}
	}

	/**
	 * Android "Display over other apps" (floating keyboard) prompt.
	 * Called after Language.load so the dialog follows the engine language, and
	 * uses the modern Material dialog via backend.Dialog instead of the old
	 * hardcoded Java AlertDialog.
	 */
	public static function maybeRequestOverlayPermission():Void
	{
		try
		{
			if (overlayDialogShown) return;
			if (!backend.SeiunOverlay.getEnabled() || !backend.SeiunOverlay.getAutoShow()) return;
			if (backend.SeiunOverlay.isOverlayPermissionGranted()) return;
			if (flixel.FlxG.save.data != null && flixel.FlxG.save.data.overlayPermissionPromptedV2 == true) return;

			overlayDialogShown = true;
			if (flixel.FlxG.save.data != null)
			{
				flixel.FlxG.save.data.overlayPermissionPromptedV2 = true;
				try { flixel.FlxG.save.flush(); } catch (_:Dynamic) {}
			}
			backend.Dialog.showCustom(
				Language.get('SUtil.overlay.title', 'Floating keyboard'),
				Language.get('SUtil.overlay.message',
					'SeiunEngine wants to show a floating keyboard button over other apps.\n\n'
					+ 'Please allow "Display over other apps" in the next screen.'),
				[
					{name: Language.get('SUtil.overlay.open', 'Open Settings'), callback: function() backend.SeiunOverlay.requestOverlayPermission()},
					{name: Language.get('SUtil.overlay.notNow', 'Not Now'), callback: function() {}}
				],
				false);
		}
		catch (e:Dynamic)
		{
			try { backend.SeiunOverlay.requestOverlayPermission(); }
			catch (_:Dynamic) {}
		}
	}

	public static function checkExternalPaths(?splitStorage = false):Array<String> {
		var paths:Array<String> = [];
		#if android
		try {
			// Read /proc/mounts directly instead of shelling out to `grep`/`paste`
			// — those binaries are missing or sandboxed on several devices/ROMs.
			var mounts:String = File.getContent('/proc/mounts');
			for (line in mounts.split('\n'))
			{
				var idx = line.indexOf('/storage/');
				if (idx < 0) continue;
				var after = line.substr(idx);
				var end = after.indexOf(' ');
				var path:String = (end > 0) ? after.substr(0, end) : after;
				path = path.trim();
				if (path.length > 0 && !paths.contains(path))
					paths.push(path);
			}
		} catch (e:Dynamic) {}

		if (paths.length == 0)
		{
			var primary = AndroidEnvironment.getExternalStorageDirectory();
			if (primary != null && primary.length > 0)
				paths.push(primary);
		}
		#end

		if (splitStorage)
			for (i in 0...paths.length)
				paths[i] = paths[i].replace('/storage/', '');

		return paths;
	}

	public static function getExternalDirectory(external:String):String {
		var daPath:String = '';
		for (path in checkExternalPaths())
			if (path.contains(external)) daPath = path;

		daPath = haxe.io.Path.addTrailingSlash(daPath.endsWith("\n") ? daPath.substr(0, daPath.length - 1) : daPath);
		return daPath;
	}
	#end
	#end
	public static function showPopUp(message:String, title:String):Void
	{
		backend.Dialog.show(title, message);
	}
}

#if android
enum abstract StorageType(String) from String to String
{
	final forcedPath = '/storage/emulated/0/';

	public static function fromStr(str:String):StorageType
	{
		final packageName = lime.app.Application.current.meta.get('packageName');
		final file = lime.app.Application.current.meta.get('file');

		// Only the selected branch runs, and no JNI string argument is null: a null Haxe String
		// crashes inside lime's JNI marshalling (NewStringUTF on a null C string), while Java's
		// getExternalFilesDir("") resolves to the same directory as getExternalFilesDir(null).
		return switch (str)
		{
			case "EXTERNAL_DATA": AndroidContext.getExternalFilesDir('');
			case "EXTERNAL_OBB": AndroidContext.getObbDir();
			case "EXTERNAL_MEDIA": AndroidEnvironment.getExternalStorageDirectory() + '/Android/media/' + packageName;
			case "EXTERNAL": AndroidEnvironment.getExternalStorageDirectory() + '/.' + file;
			case "INTERNAL": AndroidContext.getFilesDir();
			default: SUtil.getExternalDirectory(str) + '.' + file;
		}
	}

	public static function fromStrForce(str:String):StorageType
	{
		final packageName = lime.app.Application.current.meta.get('packageName');
		final file = lime.app.Application.current.meta.get('file');

		return switch (str)
		{
			case "EXTERNAL_DATA": forcedPath + 'Android/data/' + packageName + '/files';
			case "EXTERNAL_OBB": forcedPath + 'Android/obb/' + packageName;
			case "EXTERNAL_MEDIA": forcedPath + 'Android/media/' + packageName;
			case "EXTERNAL": forcedPath + '.' + file;
			case "INTERNAL": AndroidContext.getFilesDir();
			default: SUtil.getExternalDirectory(str) + '.' + file;
		}
	}
}
#end
