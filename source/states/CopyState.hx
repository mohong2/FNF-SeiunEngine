package states;
#if mobile
import lime.utils.Assets as LimeAssets;
import openfl.utils.Assets as OpenFLAssets;
import flixel.addons.util.FlxAsyncLoop;
import openfl.utils.ByteArray;
import haxe.io.Path;
#if sys
import sys.io.File;
import sys.FileSystem;
#end

using StringTools;
#end

import mohong.TraceManager;
import backend.Dialog;
import flixel.addons.transition.FlxTransitionableState;
import flixel.FlxSprite;
import flixel.FlxState;
import flixel.text.FlxText;
import flixel.FlxG;
import flixel.util.FlxColor;
import haxe.Json;

#if mobile
/**
 * Haxe-side record of the last verified asset extraction.
 *
 * The native library owns `.extract_version` and writes "versionCode|versionName" into
 * it, and .haxelib is read-only for this project, so the manifest the readiness check
 * needs lives in a *sibling* file that Haxe writes and reads itself.
 */
typedef ReadinessManifest = {
	var schema:Int;
	/** Exact content of the native `.extract_version` marker when this pass completed. */
	var marker:String;
	/** lime meta version/build the marker was verified against. */
	var version:String;
	var build:Int;
	var roots:Array<String>;
	/** Boots taken from the cheap path since the last exhaustive native scan. */
	var bootsSinceVerify:Int;
	var verifiedAt:Float;
}

/**
 * First mobile state: confirm that the bundled `assets/` + `mods/` really landed in the
 * storage root, extract them when they have not, and only then hand over to TitleState.
 *
 * This logic used to be a handful of branches inside TitleState.create()/update(). A
 * dedicated blocking state is the fix for the "tapping quickly skips extraction" class of
 * bugs:
 *   - nothing here reacts to input, so no tap can reach Title/MainMenu early;
 *   - a mod `stateRedirects` entry for TitleState can no longer throw away the copy UI,
 *     because TitleState is not the state on screen yet;
 *   - readiness is *verified* (native marker + this manifest + probes on critical paths)
 *     instead of trusting that a marker file merely exists;
 *   - a failed or partial pass is visible (dialog + logs/CopyState-*.txt) and can be
 *     retried, instead of silently dropping into the game with missing assets.
 */
class CopyState extends MusicBeatState
{
	public static var instance:CopyState;

	public static var locatedFiles:Array<String> = [];
	public static var maxLoopTimes:Int = 0;
	public static final IGNORE_FOLDER_FILE_NAME:String = "ignore.txt";
	public static final EXTRACTION_ASSET_ROOTS:Array<String> = ['assets', 'mods'];

	/** Sibling of the native `.extract_version` marker. */
	public static final READINESS_MANIFEST:String = '.extract_manifest.json';
	/** Manifest schema: bump when the recorded fields change meaning. */
	static final MANIFEST_SCHEMA:Int = 1;
	/**
	 * Re-run the exhaustive native scan at least this often. The cheap path cannot see
	 * everything (an Android versionCode bump with an unchanged versionName is invisible to
	 * lime meta), so a bounded interval keeps that from hiding behind a matching manifest
	 * forever, at the cost of one APK walk every FULL_VERIFY_INTERVAL boots.
	 */
	static final FULL_VERIFY_INTERVAL:Int = 20;
	/** Warn (and stop calling the pass healthy) after this many seconds without progress. */
	static final STALL_TIMEOUT:Float = 600;
	/** Retry attempts before the player is allowed to continue with missing assets. */
	static final MAX_RETRIES:Int = 2;

	/** Relative files that must exist and be non-empty for the build to be usable. */
	static final CRITICAL_PROBES:Array<String> = [
		'assets/data/options/categories.json',
		'assets/lang/English/Online.json'
	];
	/** Relative directories that must exist. */
	static final CRITICAL_PROBE_DIRS:Array<String> = ['assets/images'];

	public var loadingImage:FlxSprite;
	public var bottomBG:FlxSprite;
	public var loadedText:FlxText;
	public var copyLoop:FlxAsyncLoop;

	var loopTimes:Int = 0;
	var failedFiles:Array<String> = [];
	var failedFilesStack:Array<String> = [];
	var canUpdate:Bool = true;
	var shouldCopy:Bool = false;

	/** Why the copy pass started (log line + failure dialog). */
	var copyReason:String = 'unknown';
	var retryCount:Int = 0;
	/** Path of the most recent failure log, so the dialog can point at it. */
	var lastFailureLog:String = '';

	#if android
	var extractionDone:Bool = false;
	var extractionResult:Dynamic = null;
	var extractionStarted:Bool = false;
	var lastProgressAt:Float = 0;
	var stallWarned:Bool = false;
	#end

	private static final textFilesExtensions:Array<String> = ['ini', 'txt', 'xml', 'hxs', 'hx', 'lua', 'json', 'frag', 'vert'];

	override function create():Void
	{
		instance = this;

		// PlayerSettings.player1 is null until init() runs, and BOTH of the things below need
		// it: ClientPrefs.loadPrefs() ends in reloadControls() (PlayerSettings.player1.controls),
		// and MusicBeatState.controls is the property PlayerSettings.player1.controls, which
		// MusicBeatState.create() dereferences via setOnHscript. TitleState used to call init()
		// before loadPrefs() and before super.create(); the boot state has to do the same or the
		// process dies with SIGSEGV at a null + small offset during startup.
		if (PlayerSettings.player1 == null)
			PlayerSettings.init();

		// The boot states own the prefs bootstrap: autoExtractAssets, storageType and the
		// saved language all come from here, and MusicBeatState.create() loads the language.
		ClientPrefs.ensureLoaded();
		// Prefs are in memory now, so the storage root can be resolved for real. Main.new()
		// had to use the version-aware default because prefs were not loaded yet.
		SUtil.applyStorageDirectory();

		var problem:String = readinessProblem();
		TraceManager.info('trace.copy.readiness', 'Asset readiness: {}', [problem == null ? 'ready' : problem]);

		var needsCopy:Bool = (problem != null);

		#if android
		if (needsCopy)
		{
			// The cheap checks failed, so pay for the authoritative answer now: the native
			// scan walks the APK once, reports the real missing count and refreshes the
			// version marker. This is the only synchronous full walk in the boot path.
			var root:String = SUtil.getStorageDirectory();
			var missing:Int = nativeMissingCount(root);
			if (missing == 0)
			{
				writeManifest(root, readMarker(root));
				needsCopy = false;
				problem = null;
			}
			else if (missing > 0)
			{
				problem = 'native-missing:' + missing;
			}
		}
		#end

		if (!needsCopy)
		{
			#if android
			bumpVerifyCounter(SUtil.getStorageDirectory());
			#end
			// No extra fade: an up-to-date boot has to look exactly like it did before.
			FlxTransitionableState.skipNextTransIn = true;
			FlxTransitionableState.skipNextTransOut = true;
			super.create();
			handOver();
			return;
		}

		if (!ClientPrefs.data.autoExtractAssets)
		{
			FlxTransitionableState.skipNextTransIn = true;
			FlxTransitionableState.skipNextTransOut = true;
			super.create();
			warnMissingAssets(problem);
			return;
		}

		copyReason = problem;
		super.create();
		beginCopy();
	}

	override function update(elapsed:Float):Void
	{
		// Deliberately input-free: no key, pad or touch branch may switch the state from
		// here, which is what makes the copy pass impossible to skip.
		if (shouldCopy)
		{
			#if android
			if (extractionDone && canUpdate)
			{
				canUpdate = false;
				finishNativeExtraction();
			}
			else if (extractionStarted && !stallWarned && haxe.Timer.stamp() - lastProgressAt > STALL_TIMEOUT)
			{
				stallWarned = true;
				TraceManager.warn('trace.copy.stalled', 'No extraction progress for {}s', [STALL_TIMEOUT]);
				if (loadedText != null)
					loadedText.text = Language.get('CopyState.stalled', 'Still extracting, please wait...');
			}
			#else
			if (copyLoop != null && copyLoop.finished && canUpdate)
			{
				canUpdate = false;
				finishLegacyCopy();
			}
			#end
		}

		super.update(elapsed);
	}

	override function destroy():Void
	{
		instance = null;
		super.destroy();
	}

	// ---------------------------------------------------------------- Readiness

	/**
	 * Cheap, local readiness check. Returns null when the build looks ready, otherwise a
	 * short reason string naming what is missing or stale.
	 */
	static function readinessProblem():String
	{
		var root:String = SUtil.getStorageDirectory();

		if (!FileSystem.exists(root + 'assets') || !FileSystem.isDirectory(root + 'assets'))
			return 'assets-missing';
		if (FileSystem.exists(root + 'assets/assets') || FileSystem.exists(root + 'assets/mods'))
			return 'nested-layout';

		#if android
		var marker:String = readMarker(root);
		if (marker == null)
			return 'marker-missing';

		var manifest:ReadinessManifest = readManifest(root);
		if (manifest == null)
			return 'manifest-missing';
		if (manifest.marker != marker)
			return 'marker-changed';
		if (manifest.version != currentVersion())
			return 'app-version-changed';
		if (manifest.build != currentBuild())
			return 'app-build-changed';
		if (manifest.bootsSinceVerify >= FULL_VERIFY_INTERVAL)
			return 'verify-interval';
		#end

		for (probe in CRITICAL_PROBES)
		{
			var path:String = root + probe;
			if (!FileSystem.exists(path))
				return 'probe-missing:' + probe;
			try
			{
				if (FileSystem.stat(path).size <= 0)
					return 'probe-empty:' + probe;
			}
			catch (e:Dynamic) {}
		}

		for (probe in CRITICAL_PROBE_DIRS)
		{
			if (!FileSystem.exists(root + probe) || !FileSystem.isDirectory(root + probe))
				return 'probe-dir-missing:' + probe;
		}

		return null;
	}

	static function markerFile(root:String):String
	{
		return root + '.extract_version';
	}

	static function manifestFile(root:String):String
	{
		return root + READINESS_MANIFEST;
	}

	static function readMarker(root:String):String
	{
		try
		{
			var path:String = markerFile(root);
			if (!FileSystem.exists(path))
				return null;
			var text:String = File.getContent(path);
			return (text == null) ? null : text.trim();
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	static function readManifest(root:String):ReadinessManifest
	{
		try
		{
			var path:String = manifestFile(root);
			if (!FileSystem.exists(path))
				return null;
			var parsed:ReadinessManifest = cast Json.parse(File.getContent(path));
			if (parsed == null || parsed.schema != MANIFEST_SCHEMA || parsed.marker == null)
				return null;
			return parsed;
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	/** Record the marker the extraction was verified against, atomically. */
	static function writeManifest(root:String, marker:String):Void
	{
		if (marker == null || marker.length == 0)
			return;

		try
		{
			var manifest:ReadinessManifest = {
				schema: MANIFEST_SCHEMA,
				marker: marker,
				version: currentVersion(),
				build: currentBuild(),
				roots: EXTRACTION_ASSET_ROOTS.copy(),
				bootsSinceVerify: 0,
				verifiedAt: haxe.Timer.stamp()
			};

			var finalPath:String = manifestFile(root);
			var tmpPath:String = finalPath + '.tmp';
			File.saveContent(tmpPath, Json.stringify(manifest));
			if (FileSystem.exists(finalPath))
				FileSystem.deleteFile(finalPath);
			FileSystem.rename(tmpPath, finalPath);

			TraceManager.info('trace.copy.manifestWritten', 'Readiness manifest recorded for marker {}', [marker]);
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.copy.manifestWriteFailed', 'Could not record the readiness manifest: {}', [e]);
		}
	}

	/**
	 * Count this boot against the interval that forces an exhaustive native scan. A missing
	 * or unparsable manifest is left alone: the next start re-verifies from scratch.
	 */
	static function bumpVerifyCounter(root:String):Void
	{
		var manifest:ReadinessManifest = readManifest(root);
		if (manifest == null)
			return;

		try
		{
			manifest.bootsSinceVerify++;
			File.saveContent(manifestFile(root), Json.stringify(manifest));
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.copy.manifestUpdateFailed', 'Could not update the readiness manifest: {}', [e]);
		}
	}

	static function currentVersion():String
	{
		try
		{
			var meta:Dynamic = lime.app.Application.current.meta;
			if (meta != null)
			{
				var value:Dynamic = meta.get('version');
				if (value != null)
					return Std.string(value);
			}
		}
		catch (e:Dynamic) {}
		return '';
	}

	static function currentBuild():Int
	{
		try
		{
			var meta:Dynamic = lime.app.Application.current.meta;
			if (meta != null)
			{
				var value:Dynamic = meta.get('build');
				if (value != null)
				{
					var parsed:Null<Int> = Std.parseInt(Std.string(value));
					return (parsed == null) ? 0 : parsed;
				}
			}
		}
		catch (e:Dynamic) {}
		return 0;
	}

	#if android
	/**
	 * Authoritative missing-file count. Synchronous and expensive (it walks the whole APK),
	 * so it only runs once the cheap checks already failed.
	 */
	static function nativeMissingCount(root:String):Int
	{
		try
		{
			return android.Tools.countMissingAssets(EXTRACTION_ASSET_ROOTS, root);
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.copy.countFailed', 'countMissingAssets failed ({}); running a copy pass', [e]);
			return -1;
		}
	}
	#end

	// -------------------------------------------------- Hand-over / warnings

	/**
	 * Leave the copy state through plain flixel rather than MusicBeatState.switchState.
	 *
	 * switchState() opens a CustomFadeTransition substate and installs its *static*
	 * finishCallback; CustomFadeTransition.destroy() then calls that callback a second time
	 * while FlxGame is already inside switchState(), and the fade-out substate is left open
	 * until then. This hand-over is the only transition the engine performs while assets are
	 * still warm from extraction, so the machinery is skipped here: the mod state redirect is
	 * applied explicitly (TitleState also re-checks stateRedirects on its first update), and
	 * no transition substate is created. The up-to-date path already skipped the fade for the
	 * same reason.
	 */
	function handOver():Void
	{
		// The cold-start storage-location warning is raised by TitleState's normal flow, next
		// to the engine's other boot dialogs: showing a native dialog from the very first
		// state is one unknown too many for a startup path.
		TraceManager.info('trace.copy.handOver', 'Assets ready; entering TitleState');

		FlxTransitionableState.skipNextTransIn = true;
		FlxTransitionableState.skipNextTransOut = true;

		// Once per cold start, after the assets are verified (so fonts and language exist)
		// and before the title: the test-build notice (shouldShow() is false on release
		// builds, so those hand over directly). The notice hands over to TitleState itself,
		// mod state redirect included. Deliberately not persisted, because it is wanted on
		// every launch rather than once per install. The note-optimisation disclaimer is a
		// different thing and is raised when that settings page is opened.
		if (TestBuildNoticeState.shouldShow())
		{
			FlxG.switchState(new TestBuildNoticeState());
			return;
		}

		var next:FlxState = new TitleState();
		#if MODS_ALLOWED
		next = states.ModState.resolveState(next);
		#end
		FlxG.switchState(next);
	}

	/** Auto-extraction is off but the assets are not usable: say so instead of hiding it. */
	function warnMissingAssets(problem:String):Void
	{
		TraceManager.warn('trace.copy.autoExtractOff', 'Auto-extract is off but assets are not ready: {}', [problem]);
		writeFailureLog(SUtil.getStorageDirectory(), problem, ['auto-extract assets is disabled']);

		Dialog.showCustom(
			Language.get('CopyState.missingTitle', 'Assets Not Extracted'),
			Language.get('CopyState.missingBody',
				'The game files have not been extracted yet, but "Auto-Extract Assets" is turned off.\n\n'
				+ 'Settings, language and image files will be missing or broken.\n\n'
				+ 'Extract now, or enable the option in Android Settings.'),
			[
				{name: Language.get('CopyState.extractNow', 'Extract now'), callback: extractNow},
				{name: Language.get('CopyState.continueAnyway', 'Continue anyway'), callback: handOver}
			],
			false);
	}

	/** The player asked for the extraction anyway: honour it and persist the opt-in. */
	function extractNow():Void
	{
		ClientPrefs.data.autoExtractAssets = true;
		ClientPrefs.saveSettings();
		copyReason = 'manual';
		retryCount = 0;
		beginCopy();
	}

	// ------------------------------------------------------- Copy pass

	function beginCopy():Void
	{
		shouldCopy = true;
		canUpdate = true;
		loopTimes = 0;
		maxLoopTimes = 0;
		locatedFiles = [];
		failedFiles = [];
		failedFilesStack = [];

		TraceManager.info('trace.copy.start', 'Copy pass started (reason {}, attempt {})', [copyReason, retryCount + 1]);

		buildCopyUi();

		#if android
		startNativeExtraction();
		#else
		checkExistingFiles();
		startLegacyLoop();
		#end
	}

	function buildCopyUi():Void
	{
		if (loadingImage != null)
			return;

		add(new FlxSprite(0, 0).makeGraphic(FlxG.width, FlxG.height, 0xffcaff4d));

		loadingImage = new FlxSprite(0, 0, Paths.image('funkay'));
		loadingImage.setGraphicSize(0, FlxG.height);
		loadingImage.updateHitbox();
		loadingImage.screenCenter();
		add(loadingImage);

		bottomBG = new FlxSprite(0, FlxG.height - 26).makeGraphic(FlxG.width, 26, 0xFF000000);
		bottomBG.alpha = 0.6;
		add(bottomBG);

		loadedText = new FlxText(bottomBG.x, bottomBG.y + 4, FlxG.width, '', 16);
		loadedText.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, CENTER);
		loadedText.text = Language.get('CopyState.copying', 'Extracting game files...');
		add(loadedText);
	}

	#if android
	/**
	 * Stream the bundled roots out of the APK on a background thread (no OOM, atomic
	 * writes, resumable after a crash, progress via listener). Target and marker are the
	 * same root: SUtil.getStorageDirectory().
	 */
	function startNativeExtraction():Void
	{
		extractionDone = false;
		extractionResult = null;
		extractionStarted = true;
		stallWarned = false;
		lastProgressAt = haxe.Timer.stamp();

		var listener = new android.Tools.ExtractionListener();
		listener.progressHandler = function(file:String, done:Int, total:Int)
		{
			lastProgressAt = haxe.Timer.stamp();
			loopTimes = done;
			maxLoopTimes = total;
			if (loadedText != null)
				loadedText.text = (total > 0) ? '$done/$total' : Language.get('CopyState.copying', 'Extracting game files...');
		};
		listener.completeHandler = function(resultJson:String)
		{
			extractionResult = null;
			try
			{
				if (resultJson != null && resultJson.length > 0)
					extractionResult = Json.parse(resultJson);
			}
			catch (e:Dynamic)
			{
				TraceManager.warn('trace.copy.resultParseFailed', 'Could not parse the extraction result: {}', [e]);
			}
			extractionDone = true;
		};

		android.Tools.extractAssets(EXTRACTION_ASSET_ROOTS, SUtil.getStorageDirectory(), listener);
	}

	function finishNativeExtraction():Void
	{
		if (extractionResult != null)
		{
			var failures:Array<Dynamic> = Reflect.field(extractionResult, 'failures');
			if (failures != null)
			{
				for (f in failures)
				{
					var file:String = Reflect.field(f, 'file');
					var error:String = Reflect.field(f, 'error');
					failedFiles.push('$file ($error)');
					failedFilesStack.push('$file -> $error');
				}
			}
		}

		var root:String = SUtil.getStorageDirectory();

		if (failedFiles.length > 0)
		{
			TraceManager.warn('trace.copy.failed', '{} file(s) could not be extracted', [failedFiles.length]);
			FlxG.sound.play(Paths.sound('cancelMenu'));
			handleFailure('${failedFiles.length} file(s) could not be extracted', failedFilesStack);
			return;
		}

		// The native writer only records the version marker after a clean pass; mirror it
		// into the Haxe manifest so the next boot can take the cheap path again.
		writeManifest(root, readMarker(root));

		var problem:String = readinessProblem();
		if (problem != null && (problem.indexOf('probe') >= 0 || problem.indexOf('nested') >= 0))
		{
			TraceManager.warn('trace.copy.stillNotReady', 'Extraction finished but the build is still not ready: {}', [problem]);
			handleFailure(problem, [problem]);
			return;
		}

		FlxG.sound.play(Paths.sound('confirmMenu'));
		shouldCopy = false;
		TraceManager.info('trace.copy.complete', 'Extraction complete');
		handOver();
	}

	function handleFailure(reason:String, details:Array<String>):Void
	{
		shouldCopy = false;
		retryCount++;

		lastFailureLog = writeFailureLog(SUtil.getStorageDirectory(), reason, details);

		var title:String = Language.get('CopyState.failTitle', 'Extraction Failed');
		var body:String = Language.get('CopyState.failBody',
			'Some game files could not be extracted.\n\n{reason}\n\nLog: {path}')
			.replace('{reason}', reason)
			.replace('{path}', lastFailureLog);

		if (retryCount <= MAX_RETRIES)
		{
			Dialog.showYesNo(title, body + '\n\n' + Language.get('CopyState.retryQuestion', 'Retry now?'),
				retryCopy,
				function() warnAndContinue(reason));
		}
		else
		{
			Dialog.show(title, body + '\n\n' + Language.get('CopyState.continueWarning',
				'The game will continue with missing files; some content may be broken.'), 'Warning');
			warnAndContinue(reason);
		}
	}

	function retryCopy():Void
	{
		failedFiles = [];
		failedFilesStack = [];
		shouldCopy = true;
		canUpdate = true;
		copyReason = 'retry';
		if (loadedText != null)
			loadedText.text = Language.get('CopyState.copying', 'Extracting game files...');

		startNativeExtraction();
	}

	function warnAndContinue(reason:String):Void
	{
		TraceManager.warn('trace.copy.continueWithMissing', 'Continuing with missing assets: {}', [reason]);
		handOver();
	}
	#end

	// ------------------------------------ Legacy (non-Android mobile) copy loop

	#if !android
	function startLegacyLoop():Void
	{
		if (maxLoopTimes <= 0)
		{
			// Readiness flagged something, but the asset list has nothing left to copy (the
			// platform paths can disagree). Never wait on an empty async loop.
			shouldCopy = false;
			TraceManager.info('trace.copy.noop', 'No files to copy; continuing.');
			handOver();
			return;
		}

		var ticks:Int = 15;
		if (maxLoopTimes <= 15)
			ticks = 1;

		if (copyLoop != null)
			remove(copyLoop, true);

		copyLoop = new FlxAsyncLoop(maxLoopTimes, copyAsset, ticks);
		add(copyLoop);
		copyLoop.start();
	}

	function finishLegacyCopy():Void
	{
		if (failedFiles.length > 0)
		{
			TraceManager.warn('trace.copy.copyFailed', '{} file(s) could not be copied', [failedFiles.length]);
			FlxG.sound.play(Paths.sound('cancelMenu'));
			handleLegacyFailure('${failedFiles.length} file(s) could not be copied');
			return;
		}

		FlxG.sound.play(Paths.sound('confirmMenu'));
		shouldCopy = false;
		TraceManager.info('trace.copy.copyComplete', 'Copy pass complete');
		handOver();
	}

	function handleLegacyFailure(reason:String):Void
	{
		shouldCopy = false;
		retryCount++;
		lastFailureLog = writeFailureLog(SUtil.getStorageDirectory(), reason, failedFilesStack);

		var title:String = Language.get('CopyState.failTitle', 'Extraction Failed');
		var body:String = Language.get('CopyState.failBody',
			'Some game files could not be extracted.\n\n{reason}\n\nLog: {path}')
			.replace('{reason}', reason)
			.replace('{path}', lastFailureLog);

		if (retryCount <= MAX_RETRIES)
		{
			Dialog.showYesNo(title, body + '\n\n' + Language.get('CopyState.retryQuestion', 'Retry now?'),
				function()
				{
					failedFiles = [];
					failedFilesStack = [];
					shouldCopy = true;
					canUpdate = true;
					loopTimes = 0;
					checkExistingFiles();
					startLegacyLoop();
				},
				function() warnAndContinue(reason));
		}
		else
		{
			Dialog.show(title, body + '\n\n' + Language.get('CopyState.continueWarning',
				'The game will continue with missing files; some content may be broken.'), 'Warning');
			warnAndContinue(reason);
		}
	}

	function warnAndContinue(reason:String):Void
	{
		TraceManager.warn('trace.copy.continueWithMissing', 'Continuing with missing assets: {}', [reason]);
		handOver();
	}

	function checkExistingFiles():Void
	{
		locatedFiles = OpenFLAssets.list();

		// Normalize paths: strip library prefixes (e.g. "extension-androidtools:assets/..." -> "assets/...")
		var normalized:Array<String> = [];
		for (file in locatedFiles)
		{
			var idx = file.indexOf(':');
			var cleanPath:String = (idx >= 0) ? file.substr(idx + 1) : file;
			if (cleanPath.startsWith('assets/') || cleanPath.startsWith('mods/'))
			{
				for (rootName in ['assets', 'mods'])
				{
					var doubled:String = rootName + '/' + rootName + '/';
					if (cleanPath.startsWith(doubled))
					{
						cleanPath = cleanPath.substr(rootName.length + 1);
						break;
					}
				}
				if (!normalized.contains(cleanPath))
					normalized.push(cleanPath);
			}
		}
		locatedFiles = normalized;

		var filesToRemove:Array<String> = [];
		for (file in locatedFiles)
		{
			// Embedded assets do not need filesystem extraction
			if (file.startsWith("assets/embed/"))
			{
				filesToRemove.push(file);
				continue;
			}

			var ignoreFile:String = Path.join([Path.directory(file), IGNORE_FOLDER_FILE_NAME]);
			if (FileSystem.exists(file) || OpenFLAssets.exists(ignoreFile))
				filesToRemove.push(file);
		}

		for (file in filesToRemove)
			locatedFiles.remove(file);

		maxLoopTimes = locatedFiles.length;
	}

	function copyAsset():Void
	{
		if (loopTimes >= locatedFiles.length) return;
		var file:String = locatedFiles[loopTimes];
		loopTimes++;
		if (file.startsWith("assets/embed/"))
			return;

		if (!FileSystem.exists(file))
		{
			var directory:String = Path.directory(file);
			if (!FileSystem.exists(directory))
				SUtil.mkDirs(directory);
			try
			{
				var resolved:String = getCopyFile(file);
				if (OpenFLAssets.exists(resolved))
				{
					if (textFilesExtensions.contains(Path.extension(file)))
						createContentFromInternal(file);
					else
						File.saveBytes(file, getFileBytes(resolved));
				}
				else
				{
					failedFiles.push(file + " (File Doesn't Exist)");
					failedFilesStack.push('Asset $file does not exist.');
				}
			}
			catch (e:haxe.Exception)
			{
				failedFiles.push('$file (${e.message})');
				failedFilesStack.push('$file (${e.stack})');
			}
		}
	}

	function createContentFromInternal(file:String):Void
	{
		var fileName:String = Path.withoutDirectory(file);
		var directory:String = Path.directory(file);
		try
		{
			var fileData:String = OpenFLAssets.getText(getCopyFile(file));
			if (fileData == null)
				fileData = '';
			if (!FileSystem.exists(directory))
				SUtil.mkDirs(directory);
			File.saveContent(Path.join([directory, fileName]), fileData);
		}
		catch (e:haxe.Exception)
		{
			failedFiles.push('${getCopyFile(file)} (${e.message})');
			failedFilesStack.push('${getCopyFile(file)} (${e.stack})');
		}
	}

	function getFileBytes(file:String):ByteArray
	{
		switch (Path.extension(file).toLowerCase())
		{
			case 'otf' | 'ttf':
				return ByteArray.fromFile(file);
			default:
				try
				{
					return OpenFLAssets.getBytes(file);
				}
				catch (e:Dynamic)
				{
					try
					{
						return LimeAssets.getBytes(file);
					}
					catch (e2:Dynamic)
					{
						return OpenFLAssets.getBytes(getCopyFile(file));
					}
				}
		}
	}

	static function getCopyFile(file:String):String
	{
		if (OpenFLAssets.exists(file)) return file;

		@:privateAccess
		for (library in LimeAssets.libraries.keys())
		{
			if (OpenFLAssets.exists('$library:$file') && library != 'default')
				return '$library:$file';
		}

		if (LimeAssets.exists(file))
			return file;

		return file;
	}
	#end

	// ------------------------------------------------------------ Failure log

	function writeFailureLog(root:String, reason:String, lines:Array<String>):String
	{
		var path:String = 'logs/' + Date.now().toString().replace(' ', '-').replace(':', "'") + '-CopyState.txt';
		try
		{
			if (!FileSystem.exists('logs'))
				FileSystem.createDirectory('logs');
			var head:Array<String> = [
				'CopyState failure log',
				'root    : ' + root,
				'reason  : ' + reason,
				'attempt : ' + (retryCount + 1),
				'---'
			];
			File.saveContent(path, head.concat(lines).join('\n'));
			TraceManager.info('trace.copy.failureLog', 'Wrote {}', [path]);
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.copy.failureLogFailed', 'Could not write the failure log: {}', [e]);
			return '(could not write log)';
		}
		return path;
	}
}
#end
