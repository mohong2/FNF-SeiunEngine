package editors;

import backend.MusicBeatState;
import backend.ui.PsychUIButton;
import backend.ui.PsychUIInputText;
import backend.ui.PsychUINumericStepper;
import backend.ui.PsychUIRadioGroup;
import editors.content.EditorsText;
import editors.content.FileDialogHandler;
import editors.content.OsuMalodyConvert;
import flash.net.FileFilter;
import flixel.FlxG;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import haxe.Exception;
import haxe.io.Bytes;
import mohong.TraceManager;
import Section.SwagSection;
import Song.SwagSong;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * 独立转谱器: osu!mania <-> Malody 双向转换。
 * 难度、音乐、背景图全部跟随转换。
 *
 * 流程: 选输入 -> 自动转换并保存到默认输出目录 (converted/),
 * 输出目录可在输入框修改。全程 try/catch, 不会卡死。
 */
class ChartConverterState extends MusicBeatState
{
	var fileDialog:FileDialogHandler;
	var statusTxt:FlxText;
	var folderInput:PsychUIInputText;
	var authorInput:PsychUIInputText;
	var offsetStepper:PsychUINumericStepper;
	var outputModeGrp:PsychUIRadioGroup;
	var _direction:Int = 0; // 0 = osu! -> Malody, 1 = Malody -> osu!

	override function create()
	{
		FlxG.camera.bgColor = FlxColor.BLACK;
		FlxG.mouse.visible = true;
		fileDialog = new FileDialogHandler();

		var titleTxt:FlxText = new FlxText(0, 50, FlxG.width,
			Language.get('chartConverter_title', 'Chart Converter (osu! <-> Malody)'), 30);
		titleTxt.setFormat(Paths.font('vcr.ttf'), 30, FlxColor.WHITE, CENTER);
		titleTxt.scrollFactor.set();
		add(titleTxt);

		var hintTxt:FlxText = new FlxText(0, 105, FlxG.width - 200,
			Language.get('chartConverter_hint2', 'Pick an osu!/Malody chart and it is converted and saved automatically.\nDifficulty, music and background are all carried over.'),
			14);
		hintTxt.setFormat(Paths.font('vcr.ttf'), 14, FlxColor.fromRGB(180, 190, 220), CENTER);
		hintTxt.screenCenter(X);
		hintTxt.scrollFactor.set();
		add(hintTxt);

		var btn1:PsychUIButton = new PsychUIButton(FlxG.width / 2 - 300, 200,
			Language.get('chartConverter_osu2malody', 'osu! -> Malody'),
			function() { _direction = 0; pickInput(); }, 280, 42);
		btn1.cameras = cameras;
		add(btn1);

		var btn2:PsychUIButton = new PsychUIButton(FlxG.width / 2 + 20, 270,
			Language.get('chartConverter_malody2osu', 'Malody -> osu!'),
			function() { _direction = 1; pickInput(); }, 280, 42);
		btn2.cameras = cameras;
		add(btn2);

		var extractBtn:PsychUIButton = new PsychUIButton(FlxG.width / 2 - 300, 340,
			Language.get('chartConverter_extract', 'Extract package only'),
			function() { _direction = 2; pickInput(); }, 280, 36);
		extractBtn.cameras = cameras;
		add(extractBtn);

		var folderTxt:EditorsText = new EditorsText(FlxG.width / 2 - 260, 410, 300,
			Language.get('chartConverter_output_dir', 'Output folder:'));
		folderTxt.cameras = cameras;
		add(folderTxt);

		folderInput = new PsychUIInputText(FlxG.width / 2 - 130, 408, 300, 'converted', 8);
		folderInput.cameras = cameras;
		add(folderInput);

		var authorTxt:EditorsText = new EditorsText(FlxG.width / 2 - 260, 450, 300,
			Language.get('chartConverter_author', 'Author/Creator (optional):'));
		authorTxt.cameras = cameras;
		add(authorTxt);

		authorInput = new PsychUIInputText(FlxG.width / 2 - 130, 448, 300, '', 8);
		authorInput.cameras = cameras;
		add(authorInput);

		var offsetTxt:EditorsText = new EditorsText(FlxG.width / 2 - 260, 490, 200,
			Language.get('chartConverter_offset', 'Global offset (ms):'));
		offsetTxt.cameras = cameras;
		add(offsetTxt);

		offsetStepper = new PsychUINumericStepper(FlxG.width / 2 - 100, 488, 1, 0, -1000, 1000, 0, 80);
		offsetStepper.cameras = cameras;
		add(offsetStepper);

		var modeTxt:EditorsText = new EditorsText(FlxG.width / 2 - 260, 540, 200,
			Language.get('chartConverter_output_mode', 'Output mode:'));
		modeTxt.cameras = cameras;
		add(modeTxt);

		outputModeGrp = new PsychUIRadioGroup(FlxG.width / 2 - 60, 538,
			[
				Language.get('chartConverter_mode_pack', 'Package (.mcz/.osz)'),
				Language.get('chartConverter_mode_loose', 'Loose files'),
				Language.get('chartConverter_mode_both', 'Both')
			], 22, 5, true, 130);
		outputModeGrp.checked = 0;
		outputModeGrp.cameras = cameras;
		add(outputModeGrp);

		statusTxt = new FlxText(0, 585, FlxG.width - 100, '', 14);
		statusTxt.setFormat(Paths.font('vcr.ttf'), 14, FlxColor.WHITE, CENTER);
		statusTxt.screenCenter(X);
		statusTxt.scrollFactor.set();
		add(statusTxt);

		var backBtn:PsychUIButton = new PsychUIButton(0, FlxG.height - 90,
			Language.get('chartConverter_back', 'Back'),
			function()
			{
				MusicBeatState.switchState(new MasterEditorMenu());
			}, 160, 40);
		backBtn.screenCenter(X);
		backBtn.cameras = cameras;
		add(backBtn);

		super.create();
	}

	function pickInput():Void
	{
		if(!fileDialog.completed) return;
		var title:String = (_direction == 0)
			? Language.get('chartConverter_pick_osu', 'Select an osu! chart (.osz / .osu)')
			: ((_direction == 1)
				? Language.get('chartConverter_pick_malody', 'Select a Malody chart (.mcz / .mc)')
				: Language.get('chartConverter_pick_package', 'Select a package (.osz / .mcz)'));
		var filter:Array<FileFilter> = (_direction == 2)
			? [new FileFilter('Packages', '*.osz;*.mcz'), new FileFilter('All Files', '*.*')]
			: ((_direction == 0)
				? [new FileFilter('osu! Charts', '*.osz;*.osu'), new FileFilter('All Files', '*.*')]
				: [new FileFilter('Malody Charts', '*.mcz;*.mc'), new FileFilter('All Files', '*.*')]);

		try
		{
			fileDialog.open(null, title, filter, function()
			{
				try
				{
					var path:String = fileDialog.path.split('\\').join('/');
					if (path == null || path.length == 0) return;

					parseAndConvert(path);
				}
				catch(e:Exception) showError(e.message);
			});
		}
		catch(e:Exception)
		{
			showError(e.message);
		}
	}

	function parseAndConvert(srcPath:String):Void
	{
		#if sys
		if (_direction == 2)
		{
			extractOnly(srcPath);
			return;
		}

		var isPackage:Bool = OsuMalodyConvert.isPackageFile(srcPath);
		var entries:Array<Dynamic> = null;
		var chartList:Array<Dynamic> = [];

		if (isPackage)
		{
			entries = OsuMalodyConvert.readPackageEntries(srcPath);
			chartList = OsuMalodyConvert.packageChartList(entries);
		}
		else
		{
			var content:String = File.getContent(srcPath);
			var lower:String = srcPath.toLowerCase();
			var format:Int = -1;
			if (lower.endsWith('.osu')) format = 0;
			else if (lower.endsWith('.mc')) format = 1;
			if (format < 0) throw 'Unsupported file type. Use .osz/.osu or .mcz/.mc';

			chartList.push({
				format: format,
				content: content,
				audioName: OsuMalodyConvert.chartAudioName(content, format),
				title: OsuMalodyConvert.chartTitle(content, format),
				version: OsuMalodyConvert.chartDifficultyName(content, format)
			});
		}

		if (chartList.length < 1) throw 'No charts found in the selected file.';

		var outDir:String = StringTools.trim(folderInput.text);
		if (outDir.length < 1) outDir = 'converted';
		if (!FileSystem.exists(outDir)) FileSystem.createDirectory(outDir);

		var result:Dynamic = writeCharts(srcPath, isPackage, entries, chartList, outDir);
		writeDebugLog(outDir, chartList, result.count);
		var mode:Int = (outputModeGrp != null) ? outputModeGrp.checked : 0;
		if (mode == 1)
			showStatus(Language.get('chartConverter_done_loose', 'Done! Converted %s chart(s) to: %s'),
				[Std.string(result.count), outDir]);
		else
			showStatus(Language.get('chartConverter_done_pack', 'Done! Converted %s chart(s), package: %s'),
				[Std.string(result.count), result.archive]);

		#else
		showError(Language.get('chartConverter_html5_unsupported', 'Chart conversion requires a desktop build.'));
		#end
	}

	/** 直接把 .osz/.mcz 里的所有文件解压到输出目录 (不转换格式)。 */
	function extractOnly(srcPath:String):Void
	{
		#if sys
		if (!OsuMalodyConvert.isPackageFile(srcPath))
			throw 'Extract only works on packages (.osz / .mcz)';

		var entries:Array<Dynamic> = OsuMalodyConvert.readPackageEntries(srcPath);
		if (entries.length < 1) throw 'Package is empty.';

		var outDir:String = StringTools.trim(folderInput.text);
		if (outDir.length < 1) outDir = 'converted';
		if (!FileSystem.exists(outDir)) FileSystem.createDirectory(outDir);

		var count:Int = 0;
		for (e in entries)
		{
			var bytes:Bytes = haxe.zip.Reader.unzip(e.entry);
			File.saveBytes('$outDir/${e.fileName}', bytes);
			count++;
		}
		showStatus(Language.get('chartConverter_extracted', 'Extracted %s file(s) to: %s'),
			[Std.string(count), outDir]);
		#else
		showError(Language.get('chartConverter_html5_unsupported', 'Chart conversion requires a desktop build.'));
		#end
	}

	/** 调试日志: 记录源键数/mania/输出键数, 便于定位 "7K 变 4K"。 */
	function writeDebugLog(outDir:String, chartList:Array<Dynamic>, done:Int):Void
	{
		#if sys
		try
		{
			var sb:StringBuf = new StringBuf();
			sb.add('SeiunEngine Chart Converter debug log\n');
			sb.add('charts converted: ' + done + '\n');
			for (chart in chartList)
			{
				if (chart == null) continue;
				var format:Int = chart.format;
				var content:String = chart.content;
				sb.add('--- ' + chart.title + ' [' + chart.version + '] (format ' + format + ') ---\n');
				var srcKeys:Int = (format == 0)
					? OsuMalodyConvert.osuKeyCount(content)
					: OsuMalodyConvert.malodyKeyCount(content);
				sb.add('source keys: ' + srcKeys + '\n');
			var song:SwagSong = (format == 0)
				? OsuMalodyConvert.osuToPsych(content, 0)
				: OsuMalodyConvert.malodyToPsych(content, 0);
			sb.add('converted song.mania: ' + song.mania + '\n');
			sb.add('source first/last note (ms): ' + noteTimeRange(song) + '\n');
			if (format == 0)
			{
				var osuOut:String = OsuMalodyConvert.psychToOsu(song, 0, chart.audioName, '');
				var cs:Int = OsuMalodyConvert.osuKeyCount(osuOut);
				sb.add('osu output CircleSize: ' + cs + '\n');
				var back:SwagSong = OsuMalodyConvert.osuToPsych(osuOut, 0);
				sb.add('osu output first/last note (re-imported): ' + noteTimeRange(back) + '\n');
			}
			else
			{
				var mcOut:String = OsuMalodyConvert.psychToMalody(song, 0, chart.audioName, '');
				var mcKeys:Int = OsuMalodyConvert.malodyKeyCount(mcOut);
				sb.add('malody output mode_ext.column: ' + mcKeys + '\n');
				var back:SwagSong = OsuMalodyConvert.malodyToPsych(mcOut, 0);
				sb.add('malody output first/last note (re-imported): ' + noteTimeRange(back) + '\n');
			}
		}
		if (!FileSystem.exists(outDir)) FileSystem.createDirectory(outDir);
		File.saveContent('$outDir/converter_debug.log', sb.toString());
		}
		catch (e:Dynamic)
		{
			trace('debug log write failed: ' + e);
		}
		#end
	}

	/** 首/尾音符时间 (ms), 用于校验转换前后时间线是否一致。 */
	function noteTimeRange(song:SwagSong):String
	{
		var first:Float = -1;
		var last:Float = -1;
		if (song != null && song.notes != null)
		{
			for (sec in song.notes)
			{
				if (sec == null || sec.sectionNotes == null) continue;
				for (n in sec.sectionNotes)
				{
					if (n == null || n.length < 1) continue;
					var t:Float = Std.parseFloat(Std.string(n[0]));
					if (Math.isNaN(t)) continue;
					if (first < 0 || t < first) first = t;
					if (t > last) last = t;
				}
			}
		}
		if (first < 0) return 'n/a';
		return Std.int(first) + 'ms ~ ' + Std.int(last) + 'ms';
	}

	function writeCharts(srcPath:String, isPackage:Bool, entries:Array<Dynamic>, chartList:Array<Dynamic>, outDir:String):Dynamic
	{
		#if sys
		var count:Int = 0;
		var mode:Int = (outputModeGrp != null) ? outputModeGrp.checked : 0; // 0=打包 1=散文件 2=两者
		var writeLoose:Bool = (mode != 0);
		var doPack:Bool = (mode != 1);
		var packEntries:Array<Dynamic> = []; // {fileName, data} 用于打包 .mcz/.osz
		for (chart in chartList)
		{
			if (chart == null) continue;
			var format:Int = chart.format;
			var content:String = chart.content;
			var audioName:String = chart.audioName;
			var title:String = chart.title;
			var version:String = chart.version;

			var song:SwagSong = (format == 0)
				? OsuMalodyConvert.osuToPsych(content, 0)
				: OsuMalodyConvert.malodyToPsych(content, 0);
			song.format = 'psych_v1_convert';

			// 强制键数与源谱面一致 (双保险: 转换器不依赖任何中间状态)
			var srcKeys:Int = (format == 0)
				? OsuMalodyConvert.osuKeyCount(content)
				: OsuMalodyConvert.malodyKeyCount(content);
			if (srcKeys > 0)
			{
				var srcMania:Int = Std.int(Math.max(0, Math.min(17, srcKeys - 1)));
				song.mania = srcMania;
			}

			// 全局偏移修正 (ms): 正值 = 音符延后, 负值 = 音符提前
			var offMs:Float = (offsetStepper != null) ? offsetStepper.value : 0;
			if (offMs != 0 && song.notes != null)
			{
				var songSecs:Array<SwagSection> = song.notes;
				for (sec in songSecs)
					if (sec != null && sec.sectionNotes != null)
						for (n in sec.sectionNotes)
							if (n != null && n.length > 0) n[0] = n[0] + offMs;
			}

			// 作者/谱师手动覆盖: 留空则沿用原谱 Creator / meta.creator。
			if (authorInput != null)
			{
				var customAuthor:String = (authorInput.text != null) ? StringTools.trim(authorInput.text) : '';
				if (customAuthor.length > 0)
					song.chartCreator = customAuthor;
			}

			// ---- audio ----
			var audioBytes:Bytes = null;
			var audioOutName:String = audioName;
			if (isPackage)
			{
				var foundAudio:Dynamic = OsuMalodyConvert.findPackageAudio(entries, audioName);
				if (foundAudio != null)
				{
					audioBytes = foundAudio.data;
					audioOutName = foundAudio.name;
				}
			}
			else if (audioOutName != null && audioOutName.length > 0)
			{
				var adj:String = OsuMalodyConvert.findAdjacentAudio(srcPath, audioName);
				if (adj != null) audioOutName = adj.substr(adj.lastIndexOf('/') + 1);
			}
			// Keep chart-internal audio references in sync with the final package entry name.
			if (audioOutName != null && audioOutName.length > 0)
				audioOutName = OsuMalodyConvert.sanitizePackageFileName(audioOutName);

			// ---- background ----
			var bgName:String = (format == 0)
				? OsuMalodyConvert.osuBackgroundName(content)
				: OsuMalodyConvert.malodyBackgroundName(content);
			var bgBytes:Bytes = null;
			var bgOutName:String = bgName;
			if (bgName != null && bgName.length > 0)
			{
				if (isPackage)
				{
					var foundBg:Dynamic = OsuMalodyConvert.findPackageBackground(entries, bgName);
					if (foundBg != null)
					{
						bgBytes = foundBg.data;
						bgOutName = foundBg.name;
					}
				}
				else
				{
					var bgAdj:String = OsuMalodyConvert.findAdjacentFile(srcPath, bgName);
					if (bgAdj != null) bgOutName = bgAdj.substr(bgAdj.lastIndexOf('/') + 1);
				}
			}
			if (bgOutName != null && bgOutName.length > 0)
				bgOutName = OsuMalodyConvert.sanitizePackageFileName(bgOutName);

			var safeTitle:String = sanitizeFileName(title != null && title.length > 0 ? title : (song.song != null ? song.song : 'chart'));
			var safeVersion:String = sanitizeFileName(version != null && version.length > 0 ? version : (song.difficultyName != null ? song.difficultyName : 'FNF'));
			var baseName:String = safeTitle + ' [' + safeVersion + ']';
			var safeBaseName:String = OsuMalodyConvert.sanitizePackageFileName(baseName);

			var chartText:String;
			var chartExt:String;
			if (format == 0) { chartText = OsuMalodyConvert.psychToMalody(song, 0, audioOutName, bgOutName); chartExt = '.mc'; }
			else { chartText = OsuMalodyConvert.psychToOsu(song, 0, audioOutName, bgOutName); chartExt = '.osu'; }
			if (writeLoose) File.saveContent('$outDir/$safeBaseName$chartExt', chartText);
			packEntries.push({fileName: safeBaseName + chartExt, data: Bytes.ofString(chartText)});

			// write audio + background next to the chart
			if (audioBytes != null && audioOutName != null && audioOutName.length > 0)
			{
				if (writeLoose) File.saveBytes('$outDir/$audioOutName', audioBytes);
				packEntries.push({fileName: audioOutName, data: audioBytes});
			}
			else if (audioOutName != null && audioOutName.length > 0 && !isPackage)
			{
				var adj:String = OsuMalodyConvert.findAdjacentAudio(srcPath, audioName);
				if (adj != null)
				{
					if (writeLoose) File.copy(adj, '$outDir/$audioOutName');
					packEntries.push({fileName: audioOutName, data: File.getBytes(adj)});
				}
			}

			if (bgBytes != null && bgOutName != null && bgOutName.length > 0)
			{
				if (writeLoose) File.saveBytes('$outDir/$bgOutName', bgBytes);
				packEntries.push({fileName: bgOutName, data: bgBytes});
			}
			else if (bgOutName != null && bgOutName.length > 0 && !isPackage)
			{
				var bgAdj:String = OsuMalodyConvert.findAdjacentFile(srcPath, bgName);
				if (bgAdj != null)
				{
					if (writeLoose) File.copy(bgAdj, '$outDir/$bgOutName');
					packEntries.push({fileName: bgOutName, data: File.getBytes(bgAdj)});
				}
			}

			count++;
		}
		// 自动打包: osu! -> Malody 输出 .mcz, Malody -> osu! 输出 .osz
		var archivePath:String = '';
		var firstFormat:Int = (chartList.length > 0 && chartList[0] != null) ? chartList[0].format : 0;
		var pkgName:String = OsuMalodyConvert.sanitizePackageFileName(
			sanitizeFileName(chartList[0] != null && chartList[0].title != null ? chartList[0].title : 'chart'));
		archivePath = '$outDir/$pkgName.' + ((firstFormat == 0) ? 'mcz' : 'osz');
		if (doPack)
		{
			if (!OsuMalodyConvert.packZip(packEntries, archivePath))
				throw new Exception('Failed to write chart package: ' + archivePath);
		}
		else
			archivePath = outDir;
		return {count: count, archive: archivePath};
		#else
		return null;
		#end
	}

	function sanitizeFileName(name:String):String
	{
		var out:String = name;
		for (c in ['\\', '/', ':', '*', '?', '"', '<', '>', '|', '\n', '\r'])
			out = out.split(c).join('');
		out = StringTools.trim(out);
		return (out.length > 0) ? out : 'chart';
	}

	function showStatus(msg:String, ?params:Array<Dynamic>):Void
	{
		if (params != null)
		{
			var i:Int = 0;
			while (msg.indexOf('%s') != -1 && i < params.length)
			{
				msg = StringTools.replace(msg, '%s', Std.string(params[i]));
				i++;
			}
		}
		if (statusTxt != null) statusTxt.text = msg;
		trace(msg);
	}

	function showError(msg:String):Void
	{
		showStatus(Language.get('chartConverter_error', 'Error: %s'), [msg]);
		TraceManager.error('trace.editor.exception', 'Exception: {}', [msg]);
	}

	override function destroy()
	{
		if (fileDialog != null) fileDialog.destroy();
		super.destroy();
	}
}
