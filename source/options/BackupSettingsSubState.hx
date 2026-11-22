package options;

import backend.BackupFormat.BackupError;
import backend.BackupData;
import backend.BackupUtil;
import backend.MusicBeatSubstate;
import backend.BackupUtil.BackupApplyResult;
import backend.BackupUtil.BackupWriteStats;
import editors.content.FileDialogHandler;
import flixel.addons.transition.FlxTransitionableState;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.text.FlxText;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import flixel.util.FlxColor;
import flixel.util.FlxSpriteUtil;
import flixel.util.FlxTimer;
import flash.net.FileFilter;
import Language;
import Paths;

/**
 * Options -> Backup & Restore.
 *
 * Two actions: write every piece of game data into one .SEB file, or put a .SEB file back.
 * Both are driven from the same card row so the screen works with a mouse, a keyboard, a
 * gamepad and the on-screen pad on Android (which is why it adds a virtual pad - the old
 * version of this screen had none, so on a phone there was literally no way to press
 * anything).
 *
 * The heavy lifting lives in backend.BackupUtil; this class owns the UI and the one rule
 * that matters for a destructive action: nothing is written until the chosen file has been
 * fully decoded and validated, and the player has answered the confirmation dialog that
 * shows what the file actually contains.
 */
class BackupSettingsSubState extends MusicBeatSubstate
{
	// ------------------------------------------------------------------ palette

	// final, not inline: FlxColor is an abstract over Int, and an inline constant has to be
	// a compiler constant rather than a conversion.
	static final ACCENT:FlxColor = 0xFF00C8DC;
	static final ACCENT_DIM:FlxColor = 0xFF0A7A88;
	static final BG_COLOR:FlxColor = 0x0F1220;
	static final CARD_COLOR:FlxColor = 0x1A1E30;
	static final TEXT_SECONDARY:FlxColor = 0xFFB0B8D0;
	static final TEXT_WARN:FlxColor = 0xFFFFC83C;
	static final TEXT_ERROR:FlxColor = 0xFFFF5252;
	static final TEXT_OK:FlxColor = 0xFF4CD964;

	static inline var MARGIN:Float = 56;
	static inline var CARD_GAP:Float = 28;
	static inline var CARD_HEIGHT:Float = 196;
	static inline var CARD_Y:Float = 224;

	static final FILE_FILTER:Array<FileFilter> = [new FileFilter('SeiunEngine Backup', '*.SEB')];

	// ------------------------------------------------------------------ ui

	var bg:FlxSprite;
	var titleTxt:FlxText;
	var subtitleTxt:FlxText;
	var infoPanel:FlxSprite;
	var infoTxt:FlxText;
	var cardExport:FlxSprite;
	var cardImport:FlxSprite;
	var cardExportTitle:FlxText;
	var cardExportDesc:FlxText;
	var cardImportTitle:FlxText;
	var cardImportDesc:FlxText;
	var exportHint:FlxText;
	var importHint:FlxText;
	var selector:FlxSprite;
	var statusTxt:FlxText;
	var hintTxt:FlxText;
	var closeBtn:FlxSprite;
	var closeBtnLabel:FlxText;

	// ------------------------------------------------------------------ state

	var fileDialog:FileDialogHandler;
	var isProcessing:Bool = false;
	var selected:Int = 0;
	var firstUpdate:Bool = true;
	var closing:Bool = false;

	static var androidWarningShown:Bool = false;

	// ══════════════════════════════════════════════════════════════════════ create

	override function create()
	{
		super.create();

		buildBackground();
		buildHeader();
		buildInfoPanel();
		buildCards();
		buildFooter();
		playIntro();

		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(LEFT_RIGHT, A_B);
		addPadCamera();
		#end

		refreshSelection();
		setStatus(Language.get('DataBackup.ready', 'Choose what to do.'), TEXT_SECONDARY);

		#if android
		if (!androidWarningShown)
		{
			androidWarningShown = true;
			new FlxTimer().start(0.6, function(_) showAndroidWarning());
		}
		#end
	}

	function buildBackground():Void
	{
		bg = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.fromRGBFloat(0.035, 0.05, 0.1, 0.96));
		bg.alpha = 0;
		bg.scrollFactor.set();
		add(bg);
	}

	function buildHeader():Void
	{
		titleTxt = new FlxText(0, 26, FlxG.width,
			Language.get('option.backup.settingsTitle', 'Backup & Restore'), 38);
		titleTxt.setFormat(Paths.languageFont(), 38, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		titleTxt.borderSize = 2;
		titleTxt.scrollFactor.set();
		titleTxt.alpha = 0;
		add(titleTxt);

		subtitleTxt = new FlxText(0, 72, FlxG.width,
			Language.get('option.backup.subtitle', 'Save everything to one file, or put a file back'), 15);
		subtitleTxt.setFormat(Paths.languageFont(), 15, TEXT_SECONDARY, CENTER);
		subtitleTxt.scrollFactor.set();
		subtitleTxt.alpha = 0;
		add(subtitleTxt);
	}

	function buildInfoPanel():Void
	{
		var width:Int = Std.int(FlxG.width - MARGIN * 2);
		var height:Int = 96;
		var y:Float = 108;

		infoPanel = new FlxSprite(MARGIN, y).makeGraphic(width, height, FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(infoPanel, 0, 0, width, height, 12, 12, BG_COLOR, {thickness: 0});
		FlxSpriteUtil.drawRoundRect(infoPanel, 0, 0, width, height, 12, 12, FlxColor.TRANSPARENT,
			{thickness: 1.5, color: 0xFF2A3050});
		infoPanel.scrollFactor.set();
		infoPanel.alpha = 0;
		add(infoPanel);

		infoTxt = new FlxText(MARGIN + 18, y + 12, width - 36,
			Language.get('DataBackup.info',
				'Backups contain: every setting, key binds, high scores, score history and replays, '
				+ 'achievements and week progress - the whole save.\n'
				+ 'One .SEB file. Restoring asks first and always writes a safety copy of your current data.'), 14);
		infoTxt.setFormat(Paths.languageFont(), 14, TEXT_SECONDARY, LEFT);
		infoTxt.wordWrap = true;
		infoTxt.scrollFactor.set();
		infoTxt.alpha = 0;
		add(infoTxt);
	}

	function buildCards():Void
	{
		var totalWidth:Float = FlxG.width - MARGIN * 2;
		var cardWidth:Int = Std.int((totalWidth - CARD_GAP) / 2);
		var leftX:Float = MARGIN;
		var rightX:Float = MARGIN + cardWidth + CARD_GAP;

		cardExport = makeCard(leftX, CARD_Y, cardWidth, Std.int(CARD_HEIGHT));
		add(cardExport);

		cardExportTitle = new FlxText(leftX + 22, CARD_Y + 18, cardWidth - 44,
			Language.get('option.backup.export', 'Backup Data'), 26);
		cardExportTitle.setFormat(Paths.languageFont(), 26, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		cardExportTitle.borderSize = 1.5;
		cardExportTitle.scrollFactor.set();
		add(cardExportTitle);

		cardExportDesc = new FlxText(leftX + 22, CARD_Y + 58, cardWidth - 44,
			Language.get('option.backup.export.desc',
				'Write all game data (settings, key binds, scores, history and replays) to one .SEB file.\n'
				+ 'You pick where it goes.'), 14);
		cardExportDesc.setFormat(Paths.languageFont(), 14, TEXT_SECONDARY, LEFT);
		cardExportDesc.wordWrap = true;
		cardExportDesc.scrollFactor.set();
		add(cardExportDesc);

		exportHint = new FlxText(leftX + 22, CARD_Y + CARD_HEIGHT - 40, cardWidth - 44,
			Language.get('DataBackup.export.hint', 'ENTER / A  ->  choose this'), 13);
		exportHint.setFormat(Paths.languageFont(), 13, ACCENT_DIM, LEFT);
		exportHint.scrollFactor.set();
		add(exportHint);

		cardImport = makeCard(rightX, CARD_Y, cardWidth, Std.int(CARD_HEIGHT));
		add(cardImport);

		cardImportTitle = new FlxText(rightX + 22, CARD_Y + 18, cardWidth - 44,
			Language.get('option.backup.import', 'Restore Data'), 26);
		cardImportTitle.setFormat(Paths.languageFont(), 26, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		cardImportTitle.borderSize = 1.5;
		cardImportTitle.scrollFactor.set();
		add(cardImportTitle);

		cardImportDesc = new FlxText(rightX + 22, CARD_Y + 58, cardWidth - 44,
			Language.get('option.backup.import.desc',
				'Load a previously created .SEB file and replace the current game data with it.\n'
				+ 'The file is checked completely before anything is touched.'), 14);
		cardImportDesc.setFormat(Paths.languageFont(), 14, TEXT_SECONDARY, LEFT);
		cardImportDesc.wordWrap = true;
		cardImportDesc.scrollFactor.set();
		add(cardImportDesc);

		importHint = new FlxText(rightX + 22, CARD_Y + CARD_HEIGHT - 40, cardWidth - 44,
			Language.get('DataBackup.import.hint', 'ENTER / A  ->  choose this'), 13);
		importHint.setFormat(Paths.languageFont(), 13, ACCENT_DIM, LEFT);
		importHint.scrollFactor.set();
		add(importHint);

		// After the cards: a border drawn underneath them would never be seen.
		selector = new FlxSprite(leftX, CARD_Y).makeGraphic(cardWidth, Std.int(CARD_HEIGHT), FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(selector, 0, 0, cardWidth, CARD_HEIGHT, 14, 14, FlxColor.TRANSPARENT,
			{thickness: 3, color: ACCENT});
		selector.scrollFactor.set();
		add(selector);
	}

	function buildFooter():Void
	{
		statusTxt = new FlxText(MARGIN, CARD_Y + CARD_HEIGHT + 22, FlxG.width - MARGIN * 2, '', 16);
		statusTxt.setFormat(Paths.languageFont(), 16, TEXT_SECONDARY, CENTER);
		statusTxt.wordWrap = true;
		statusTxt.scrollFactor.set();
		statusTxt.alpha = 0;
		add(statusTxt);

		hintTxt = new FlxText(MARGIN, CARD_Y + CARD_HEIGHT + 56, FlxG.width - MARGIN * 2, '', 12);
		hintTxt.setFormat(Paths.languageFont(), 12, 0xFF6D7896, CENTER);
		hintTxt.wordWrap = true;
		hintTxt.scrollFactor.set();
		hintTxt.alpha = 0;
		add(hintTxt);
		refreshHint();

		var closeWidth:Int = 170;
		var closeHeight:Int = 38;
		var closeX:Float = (FlxG.width - closeWidth) / 2;
		var closeY:Float = FlxG.height - 54;

		closeBtn = new FlxSprite(closeX, closeY).makeGraphic(closeWidth, closeHeight, FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(closeBtn, 0, 0, closeWidth, closeHeight, 8, 8, 0xFF2E3444, {thickness: 0});
		FlxSpriteUtil.drawRoundRect(closeBtn, 0, 0, closeWidth, closeHeight, 8, 8, FlxColor.TRANSPARENT,
			{thickness: 1.5, color: 0xFF3E465C});
		closeBtn.scrollFactor.set();
		closeBtn.alpha = 0;
		add(closeBtn);

		closeBtnLabel = new FlxText(closeX, closeY + 9, closeWidth,
			Language.get('DataBackup.close', 'CLOSE'), 17);
		closeBtnLabel.setFormat(Paths.languageFont(), 17, FlxColor.WHITE, CENTER);
		closeBtnLabel.scrollFactor.set();
		closeBtnLabel.alpha = 0;
		add(closeBtnLabel);
	}

	function playIntro():Void
	{
		FlxTween.tween(bg, {alpha: 1}, 0.3, {ease: FlxEase.quartOut});
		FlxTween.tween(titleTxt, {alpha: 1}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.05});
		FlxTween.tween(subtitleTxt, {alpha: 1}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.08});
		FlxTween.tween(infoPanel, {alpha: 0.55}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.1});
		FlxTween.tween(infoTxt, {alpha: 1}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.12});
		FlxTween.tween(selector, {alpha: 1}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.15});

		for (target in [cardExport, cardImport])
			FlxTween.tween(target, {alpha: 1}, 0.3, {ease: FlxEase.quartOut, startDelay: 0.16});
		for (target in [cardExportTitle, cardExportDesc, exportHint, cardImportTitle, cardImportDesc, importHint])
			FlxTween.tween(target, {alpha: 1}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.18});

		FlxTween.tween(statusTxt, {alpha: 1}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.2});
		FlxTween.tween(hintTxt, {alpha: 1}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.22});
		FlxTween.tween(closeBtn, {alpha: 0.9}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.24});
		FlxTween.tween(closeBtnLabel, {alpha: 1}, 0.25, {ease: FlxEase.quartOut, startDelay: 0.24});

		// The intro tweens end at alpha 1 for every card; re-apply the dimmed non-selection
		// once they are done instead of racing them.
		new FlxTimer().start(0.45, function(_) refreshSelection());
	}

	// ══════════════════════════════════════════════════════════════════════ update

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (closing) return;

		if (firstUpdate)
		{
			// Opened on the same frame as the Accept that selected this page: that press
			// must not immediately run the action the page is about.
			firstUpdate = false;
			return;
		}

		if (isProcessing)
		{
			// A restore in flight must not be interrupted, and the file dialog owns input.
			return;
		}

		if (controls.BACK)
		{
			closeScreen();
			return;
		}

		if (controls.UI_LEFT_P || controls.UI_UP_P)
		{
			changeSelection(-1);
			return;
		}

		if (controls.UI_RIGHT_P || controls.UI_DOWN_P)
		{
			changeSelection(1);
			return;
		}

		if (controls.ACCEPT)
		{
			activate(selected);
			return;
		}

		if (FlxG.mouse.justPressed && !(virtualPad != null && virtualPad.isMouseOverAnyButton()))
		{
			if (FlxG.mouse.overlaps(cardExport, FlxG.camera))
			{
				if (selected != 0) changeSelectionTo(0);
				activate(0);
				return;
			}
			if (FlxG.mouse.overlaps(cardImport, FlxG.camera))
			{
				if (selected != 1) changeSelectionTo(1);
				activate(1);
				return;
			}
			if (FlxG.mouse.overlaps(closeBtn, FlxG.camera))
			{
				closeScreen();
				return;
			}
		}
		else if (FlxG.mouse.justMoved)
		{
			if (FlxG.mouse.overlaps(cardExport, FlxG.camera) && selected != 0) changeSelectionTo(0);
			else if (FlxG.mouse.overlaps(cardImport, FlxG.camera) && selected != 1) changeSelectionTo(1);
		}
	}

	function changeSelection(direction:Int):Void
	{
		changeSelectionTo(selected + direction < 0 ? 1 : (selected + direction) % 2);
	}

	function changeSelectionTo(which:Int):Void
	{
		if (selected == which) return;
		selected = which;
		FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		refreshSelection();
	}

	function refreshSelection():Void
	{
		if (selector == null) return;

		selector.x = (selected == 0) ? cardExport.x : cardImport.x;
		selector.y = cardExport.y;

		cardExport.alpha = (selected == 0) ? 1 : 0.72;
		cardImport.alpha = (selected == 1) ? 1 : 0.72;
		cardExportTitle.alpha = (selected == 0) ? 1 : 0.72;
		cardImportTitle.alpha = (selected == 1) ? 1 : 0.72;
		exportHint.color = (selected == 0) ? ACCENT : ACCENT_DIM;
		importHint.color = (selected == 1) ? ACCENT : ACCENT_DIM;
	}

	function activate(which:Int):Void
	{
		if (isProcessing) return;
		FlxG.sound.play(Paths.sound('confirmMenu'), 0.7);
		if (which == 0) doExport(); else doImport();
	}

	// ══════════════════════════════════════════════════════════════════════ export

	function doExport():Void
	{
		if (isProcessing) return;
		isProcessing = true;

		ensureFileDialog();
		var name:String = 'SeiunEngine_Backup_' + fileStamp() + '.SEB';

		#if (android || !sys)
		// Android's save dialog (SAF) is handed the finished text, it cannot be streamed
		// into, so the backup has to exist in memory first on this target (and in a
		// browser there is no file to stream into at all).
		captureThenSave(name);
		#else
		// Ask for the destination first and stream into it. The file never exists as a
		// string, which is what made a big score history expensive to back up.
		var dialog:FileDialogHandler = fileDialog;
		dialog.savePath(name, function(path:String) {
			if (path == null || path.length == 0)
			{
				isProcessing = false;
				setStatus(Language.get('DataBackup.cancelled', 'Cancelled.'), TEXT_SECONDARY);
				return;
			}
			streamBackup(path);
		}, function() {
			isProcessing = false;
			setStatus(Language.get('DataBackup.cancelled', 'Cancelled.'), TEXT_SECONDARY);
		}, function() {
			finishWithError(Language.get('DataBackup.error.write', 'The backup file could not be written.'), null);
		});
		#end
	}

	#if (!android && sys)
	/** Writes the backup straight into the file the player picked. */
	function streamBackup(path:String):Void
	{
		setStatus(Language.get('DataBackup.collecting', 'Collecting game data...'), TEXT_WARN);

		// One frame so the status line is actually on screen before the work starts.
		new FlxTimer().start(0.05, function(_) {
			var stats:BackupWriteStats = null;
			try
			{
				stats = BackupUtil.writeBackupToFile(path);
			}
			catch (e:Dynamic)
			{
				finishWithError(Language.get('DataBackup.error.write', 'The backup file could not be written.'), e);
				return;
			}

			onExportDone(stats.path, stats.size);
		});
	}
	#end

	#if (android || !sys)
	/** Text fallback: build the whole text, then let the system dialog write it. */
	function captureThenSave(name:String):Void
	{
		setStatus(Language.get('DataBackup.collecting', 'Collecting game data...'), TEXT_WARN);

		new FlxTimer().start(0.05, function(_) {
			var text:String = null;
			try
			{
				text = BackupUtil.createBackupText();
			}
			catch (e:Dynamic)
			{
				finishWithError(Language.get('DataBackup.error.message', 'Failed to save backup!'), e);
				return;
			}

			if (text == null || text.length == 0)
			{
				finishWithError(Language.get('DataBackup.error.message', 'Failed to save backup!'),
					'the captured backup is empty');
				return;
			}

			var dialog:FileDialogHandler = fileDialog;
			dialog.save(name, text, function() {
				onExportDone(dialog.path, text.length);
			}, function() {
				isProcessing = false;
				setStatus(Language.get('DataBackup.cancelled', 'Cancelled.'), TEXT_SECONDARY);
			}, function() {
				finishWithError(Language.get('DataBackup.error.write', 'The backup file could not be written.'), null);
			});
		});
	}
	#end

	function onExportDone(path:String, size:Int):Void
	{
		isProcessing = false;

		if (path == null || path.length == 0) path = '?';
		setStatus(Language.get('DataBackup.exported', 'Backup saved.') + '  ' + path, TEXT_OK);

		var message:String = Language.get('DataBackup.success.message',
			'Game data has been backed up.\n\nFile:\n{path}\n\nSize: {size}')
			.replace('{path}', path)
			.replace('{size}', formatSize(size));
		backend.Dialog.show(Language.get('DataBackup.success.title', 'Backup Successful'), message, 'Info');
	}

	// ══════════════════════════════════════════════════════════════════════ import

	function doImport():Void
	{
		if (isProcessing) return;
		isProcessing = true;
		setStatus(Language.get('DataBackup.selectFile', 'Select a backup file...'), ACCENT);

		ensureFileDialog();
		// skipData: the file is decoded from disk in chunks, so the picker must not read
		// the whole thing into a string first (a .SEB is bigger than the data it carries).
		fileDialog.open(null, Language.get('DataBackup.selectFile', 'Select a backup file...'), FILE_FILTER,
			function() onFileSelected(),
			function() {
				isProcessing = false;
				setStatus(Language.get('DataBackup.cancelled', 'Cancelled.'), TEXT_SECONDARY);
			},
			function() finishWithError(Language.get('DataBackup.error.fileError', 'An error occurred while reading the file.'), null),
			true);
	}

	function onFileSelected():Void
	{
		#if sys
		var path:String = (fileDialog != null) ? fileDialog.path : null;
		if (path == null || path.length == 0)
		{
			finishWithError(Language.get('DataBackup.error.empty', 'The selected file is empty or invalid.'), null);
			return;
		}
		#else
		var raw:String = (fileDialog != null) ? fileDialog.data : null;
		if (raw == null || raw.length == 0)
		{
			finishWithError(Language.get('DataBackup.error.empty', 'The selected file is empty or invalid.'), null);
			return;
		}
		#end

		setStatus(Language.get('DataBackup.scanning', 'Checking the backup file...'), TEXT_WARN);

		new FlxTimer().start(0.05, function(_) {
			var data:BackupData = null;
			var size:Int = 0;
			try
			{
				#if sys
				size = BackupUtil.backupFileSize(path);
				data = BackupUtil.parseBackupFile(path);
				#else
				size = raw.length;
				data = BackupUtil.parseBackupText(raw);
				#end
			}
			catch (e:Dynamic)
			{
				finishWithError(Language.get('DataBackup.error.invalidFile',
					'The selected file is not a valid backup file or has been corrupted.'), e);
				return;
			}

			setStatus('', TEXT_SECONDARY);
			showRestoreConfirm(data, size);
		});
	}

	function showRestoreConfirm(data:BackupData, fileSize:Int):Void
	{
		var date:String = (data.createdAt != null && data.createdAt.length > 0)
			? data.createdAt : Language.get('DataBackup.unknown', 'unknown');
		var engine:String = (data.engineVersion != null && data.engineVersion.length > 0)
			? data.engineVersion : Language.get('DataBackup.unknown', 'unknown');
		if (data.buildVersion != null && data.buildVersion.length > 0 && data.buildVersion != 'unknown')
			engine += ' (' + data.buildVersion + ')';
		if (data.legacy)
			engine += ' - ' + Language.get('DataBackup.legacy', 'old backup format');

		var message:String = Language.get('DataBackup.confirm.message',
			'This will overwrite ALL current game data (settings, key binds, scores, history and replays) '
			+ 'with the backup.\n\nDate: {date}\nEngine: {engine}\nContains: {fields} save entries, '
			+ '{scores} score files ({size})\n\nA safety copy of your current data is written to:\n{safety}\n\nContinue?')
			.replace('{date}', date)
			.replace('{engine}', engine)
			.replace('{fields}', Std.string(data.saveFieldCount()))
			.replace('{scores}', Std.string(data.scoreCount()))
			.replace('{size}', formatSize(fileSize))
			.replace('{safety}', BackupUtil.autoBackupDirectory());

		backend.Dialog.showYesNo(Language.get('DataBackup.confirm.title', 'Restore Data?'), message,
			function() doRestore(data),
			function() {
				isProcessing = false;
				setStatus(Language.get('DataBackup.cancelled', 'Cancelled.'), TEXT_SECONDARY);
			});
	}

	function doRestore(data:BackupData):Void
	{
		setStatus(Language.get('DataBackup.restoring', 'Restoring data...')
			+ '  (' + Language.get('DataBackup.safetyCopy', 'a safety copy is written first') + ')', TEXT_WARN);

		new FlxTimer().start(0.05, function(_) {
			var result:BackupApplyResult = null;
			try
			{
				result = BackupUtil.applyBackup(data);
			}
			catch (e:Dynamic)
			{
				finishWithError(Language.get('DataBackup.error.restoreFailed', 'Failed to restore data.'), e);
				return;
			}

			setStatus(Language.get('DataBackup.reloading', 'Restored. Reloading the game...'), TEXT_OK);

			new FlxTimer().start(0.05, function(_) {
				var reloadError:String = null;
				try
				{
					BackupUtil.reloadAfterRestore();
				}
				catch (e:Dynamic)
				{
					reloadError = describe(e);
				}

				if (reloadError != null)
				{
					isProcessing = false;
					setStatus(Language.get('DataBackup.restored.status', 'Data restored.'), TEXT_WARN);
					backend.Dialog.show(Language.get('DataBackup.restored.title', 'Restore Successful'),
						Language.get('DataBackup.reloadFailed',
							'Data was restored, but the running game could not reload it:\n{error}\n\nRestart the game to use the restored data.')
							.replace('{error}', reloadError), 'Warning');
					return;
				}

				isProcessing = true;
				var detail:String = Language.get('DataBackup.restore.detail',
					'{fields} save entries and {scores} score files restored; {removed} old score files removed.')
					.replace('{fields}', Std.string(result.fields))
					.replace('{scores}', Std.string(result.scores))
					.replace('{removed}', Std.string(result.scoresRemoved));
				setStatus(Language.get('DataBackup.restored.status', 'Data restored.') + '  ' + detail, TEXT_OK);

				// Rebuild OptionsState (and this screen with it) so the restored language and
				// settings are what is actually on screen.
				new FlxTimer().start(0.5, function(_) {
					closing = true;
					FlxTransitionableState.skipNextTransOut = true;
					FlxG.resetState();
				});
			});
		});
	}

	// ══════════════════════════════════════════════════════════════════════ close

	function closeScreen():Void
	{
		if (isProcessing || closing) return;
		closing = true;
		FlxG.sound.play(Paths.sound('cancelMenu'), 0.8);

		for (target in [bg, titleTxt, subtitleTxt, infoPanel, infoTxt, cardExport, cardImport,
			cardExportTitle, cardExportDesc, cardImportTitle, cardImportDesc, exportHint,
			importHint, selector, statusTxt, hintTxt, closeBtn, closeBtnLabel])
			if (target != null) FlxTween.tween(target, {alpha: 0}, 0.14);

		new FlxTimer().start(0.18, function(_) close());
	}

	override function destroy()
	{
		if (fileDialog != null)
		{
			fileDialog.destroy();
			fileDialog = null;
		}
		super.destroy();
	}

	// ══════════════════════════════════════════════════════════════════════ android

	#if android
	function showAndroidWarning():Void
	{
		if (closing) return;
		var title:String = Language.get('DataBackup.androidWarning.title', 'Important: Data Backup Recommended');
		var message:String = Language.get('DataBackup.androidWarning.message',
			'Your game data is stored in internal storage. If you uninstall the game, ALL data will be lost!\n\n'
			+ 'Create a backup now to save your progress.');

		backend.Dialog.showCustom(title, message,
			[
				{name: Language.get('DataBackup.backupNow', 'Backup Now'), callback: function() {
					if (!isProcessing) doExport();
				}},
				{name: Language.get('DataBackup.later', 'Later'), callback: function() {}}
			], false);
	}
	#end

	// ══════════════════════════════════════════════════════════════════════ helpers

	function ensureFileDialog():Void
	{
		if (fileDialog == null)
		{
			fileDialog = new FileDialogHandler();
			return;
		}
		if (!fileDialog.completed)
		{
			fileDialog.destroy();
			fileDialog = new FileDialogHandler();
		}
	}

	function setStatus(message:String, color:FlxColor):Void
	{
		if (statusTxt == null) return;
		statusTxt.text = message;
		statusTxt.color = color;
		statusTxt.alpha = 1;
	}

	function refreshHint():Void
	{
		if (hintTxt == null) return;
		var hint:String = Language.get('DataBackup.hint',
			'Left / Right: choose   ENTER: confirm   ESC: back');
		var auto:String = BackupUtil.autoBackupDirectory();
		var count:Int = BackupUtil.countSafetyCopies();
		if (count > 0)
			hint += '\n' + Language.get('DataBackup.autoHint', 'Automatic safety copies: {dir} ({count})')
				.replace('{dir}', auto).replace('{count}', Std.string(count));
		else
			hint += '\n' + Language.get('DataBackup.autoHint.empty', 'Automatic safety copies are kept in {dir}')
				.replace('{dir}', auto);
		hintTxt.text = hint;
	}

	/** Shows an error dialog, unlocks the screen and puts the reason on the status line. */
	function finishWithError(title:String, e:Dynamic):Void
	{
		isProcessing = false;
		var reason:String = describe(e);
		setStatus(title + (reason.length > 0 ? '  ' + reason : ''), TEXT_ERROR);
		var message:String = title;
		if (reason.length > 0)
			message = Language.get('DataBackup.error.detail', '{title}\n\n{error}')
				.replace('{title}', title)
				.replace('{error}', reason);
		backend.Dialog.show(Language.get('DataBackup.error.title', 'Backup Failed'), message, 'Error');
	}

	static function describe(e:Dynamic):String
	{
		if (e == null) return '';
		if (Std.isOfType(e, BackupError)) return (cast e:BackupError).message;
		return Std.string(e);
	}

	static function makeCard(x:Float, y:Float, w:Int, h:Int):FlxSprite
	{
		var card = new FlxSprite(x, y).makeGraphic(w, h, FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(card, 0, 0, w, h, 14, 14, CARD_COLOR, {thickness: 0});
		FlxSpriteUtil.drawRoundRect(card, 0, 0, w, h, 14, 14, FlxColor.TRANSPARENT,
			{thickness: 2, color: 0xFF2A3050});
		card.scrollFactor.set();
		card.alpha = 0;
		return card;
	}

	/** 2026-11-22_11-11-20, the same shape the old exporter used. */
	static function fileStamp():String
	{
		var now:Date = Date.now();
		return now.getFullYear() + '-' + pad2(now.getMonth() + 1) + '-' + pad2(now.getDate())
			+ '_' + pad2(now.getHours()) + '-' + pad2(now.getMinutes()) + '-' + pad2(now.getSeconds());
	}

	static function pad2(value:Int):String
		return value < 10 ? '0' + value : Std.string(value);

	static function formatSize(bytes:Int):String
	{
		if (bytes >= 1024 * 1024) return Std.string(Math.round(bytes / (1024 * 1024) * 10) / 10) + ' MB';
		if (bytes >= 1024) return Std.string(Math.round(bytes / 1024)) + ' KB';
		return Std.string(bytes) + ' B';
	}
}
