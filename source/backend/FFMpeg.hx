#if desktop
package backend;

import lime.math.Rectangle;
import haxe.io.Bytes;
import lime.ui.Window;
import sys.FileSystem;
import sys.thread.Mutex;
import sys.thread.Semaphore;
import sys.thread.Thread;
import flixel.FlxG;

/**
 * 把游戏画面送进 ffmpeg 管道，连歌的音频一起混成视频文件。不是播放器 —— 播放是 hxvlc 的事。
 *
 * 唯一的规矩：1 帧 = 1/fps 秒的歌，歌的时间就是 Conductor.songPosition。
 * 帧数是从这个时钟算出来的，所以暂停 / seek / 变速全都自动对，不用额外写逻辑。
 * 别改成"每绘制帧录一帧"：机器掉帧时一个绘制帧里会塞进好几个逻辑步，
 * 那样录出来会快 2 倍（实测 48.5s 的歌只录出 23.6s 的画面）。
 *
 * 环形缓冲满了要**等**，不能丢帧。丢一帧就是少 1/fps 秒的歌，而编码器被写死了 -r，
 * 少的那帧不会让视频变长，只会把后面全部提前 —— 视频又短又快。离线渲染没有实时要求，等就是了。
 *
 * 三个线程：主线程读画面 → writer 写 ffmpeg 的 stdin → 再单独一个读 stderr。
 * stderr 必须独立线程：hxcpp 的 Process.stderr 是阻塞式 ReadFile，没数据时不返回 0 而是挂住，
 * 早先把它塞在 writer 循环里，writer 直接卡死，一帧都没写出去，每个视频都是 262 字节的空 mp4。
 *
 * 渲染期间还会把 update/draw 帧率钉死、fixedTimestep 打开、autoPause 关掉，stop 时全部还原。
 * 每次渲染在输出旁边写一个 .log：设定、帧数、速度和 ffmpeg 自己的 stderr。
 *
 * 每帧读回画面不分配任何东西（见 readWindowPixels）：关掉 GC 内存也不会涨。
 * 我要泄露你们所有的内存
 */
@:access(lime._internal.backend.native.NativeCFFI)
class FFMpeg
{
	/** Encoder display name -> ffmpeg -c:v value. GPU entries also get -qp. */
	public static var CODECS:Map<String, String> = [
		'H.264 (x264)' => 'libx264',
		'H.264 (NVENC)' => 'h264_nvenc',
		'H.264 (AMF)' => 'h264_amf',
		'H.264 (QSV)' => 'h264_qsv',
		'HEVC (x265)' => 'libx265',
		'HEVC (NVENC)' => 'hevc_nvenc',
		'VP9 (libvpx)' => 'libvpx-vp9',
		'VP8 (libvpx)' => 'libvpx',
	];

	/** Codecs whose quality flag is -qp instead of -crf. */
	static final GPU_CODECS:Array<String> = ['NVENC', 'AMF', 'QSV'];

	/** Output directory, relative to the game's working directory. */
	public var target:String = 'render_video';
	/** Output path WITHOUT extension. */
	public var fileName:String = '';
	/** '.mp4' or '.webm' depending on the codec. */
	public var fileExts:String = '.mp4';
	/** Audio files muxed into the render, in ffmpeg input order (after input 0). */
	public var audioPaths:Array<String> = [];
	/** Conductor.songPosition at the moment the render started (video t = 0). */
	var songStartMs:Float = 0;

	/** Set when ffmpeg could not be used; the reason is shown to the player. */
	public var wentPreview:String = null;

	public static var instance:FFMpeg = null;

	var window:Window;
	var buffer:Rectangle;
	var width:Int = 0;
	var height:Int = 0;
	/**
	 * The one read-back buffer of this render (width*height*4, RGBA, top-down after the flip).
	 * Allocated in start(), reused for every frame, copied into a ring slot by enqueue().
	 */
	var capture:Bytes = null;
	/** Single row, reused by the in-place vertical flip (GL returns the bottom row first). */
	var rowTemp:Bytes = null;
	/** Capture rate == encoder -r == the loop's pinned rate, in frames per second. */
	var fps:Int = 60;
	/** Song time at which the render started, used to seek the audio inputs. */
	var startOffsetMs:Float = 0;

	var process:sys.io.Process = null;
	var active:Bool = false;

	// ── writer thread ────────────────────────────────────────────────────────
	var writer:Thread = null;
	/** Dedicated stderr reader; see the class doc for why it is not the writer. */
	var errPump:Thread = null;
	/** Ring of reusable frame buffers. Its length is the memory bound. */
	var frames:Array<Bytes> = null;
	/** Number of ring slots currently holding an unwritten frame. */
	var queued:Int = 0;
	/** Index of the next ring slot to fill. */
	var writePos:Int = 0;
	/** True while the writer is inside a blocking stdin write. */
	var writerBusy:Bool = false;
	/** True once the writer thread has left its loop. */
	var writerDone:Bool = false;
	/** Semaphore counting free ring slots. */
	var slots:Semaphore = null;
	var mutex:Mutex = null;
	var errMutex:Mutex = null;

	/** Frames produced so far, i.e. how much of the song timeline is on tape. */
	var framesProduced:Int = 0;
	/** Frames a backwards seek or an over-long stall asked for beyond the cap. */
	public var framesSkipped:Int = 0;

	// ── counters (main thread owns these) ────────────────────────────────────
	/** Video frames produced, i.e. song-time slices recorded. */
	public var framesCaptured:Int = 0;
	/** Slices that could not be written at all (should stay 0). */
	public var framesDropped:Int = 0;

	/** Frames that actually reached the encoder. */
	public var framesWritten(get, never):Int;

	inline function get_framesWritten():Int
		return framesCaptured - framesDropped;

	/** How fast song time is advancing versus the wall clock; 1.0 means realtime. */
	public var renderSpeed(get, never):Float;

	function get_renderSpeed():Float
	{
		final wall:Float = haxe.Timer.stamp() - startedAt;
		if (wall <= 0.001 || fps <= 0)
			return 0;
		return (framesWritten / fps) / wall;
	}

	/** ffmpeg's stderr, accumulated by the pump thread so a failing encode is visible. */
	public var stderrLog:StringBuf = new StringBuf();

	var startedAt:Float = 0;

	// ── state captured on start, restored on stop ─────────────────────────────
	var savedFixedTimestep:Bool = false;
	var savedSkipIdle:Bool = false;
	var savedAutoPause:Bool = false;
	var savedUpdateFramerate:Int = 0;
	var savedDrawFramerate:Int = 0;

	public function new() {}

	public static function init():Void
	{
		if (instance == null)
			instance = new FFMpeg();
	}

	/** True while a render (or a preview render) is running. */
	public static inline function isRendering():Bool
	{
		return instance != null && instance.active;
	}

	/** The framerate this render captures and encodes at, straight from the option. */
	public static function resolveFps():Int
	{
		return Std.int(Math.min(480, Math.max(15, ClientPrefs.data.renderFps)));
	}

	/**
	 * Starts a render. Returns false when the window cannot be captured. When
	 * ffmpeg is missing, preview mode is turned on and wentPreview explains why.
	 */
	public function start(songName:String, ?preview:Bool):Bool
	{
		if (active)
			return true;

		final wantsPreview:Bool = (preview != null) ? preview : ClientPrefs.data.previewRender;
		wentPreview = null;

		window = (FlxG.stage != null && FlxG.stage.window != null) ? FlxG.stage.window : null;
		if (window == null)
			return false;

		width = window.width;
		height = window.height;
		if (width <= 0 || height <= 0)
			return false;

		// Capture size must match the encoded size exactly.
		buffer = new Rectangle(0, 0, width, height);
		// The read-back scratch, twice per render and never per frame: one full frame buffer and
		// one row for the vertical flip. See the class doc (zero allocation per captured frame).
		capture = Bytes.alloc(width * height * 4);
		rowTemp = Bytes.alloc(width * 4);
		fps = resolveFps();
		// The song clock is the origin of the video timeline (see captureFrame),
		// and the audio is seeked to the same instant so a render started in the
		// middle of a song still lines up.
		songStartMs = Conductor.songPosition;
		startOffsetMs = (FlxG.sound.music != null) ? FlxG.sound.music.time : songStartMs;

		if (!wantsPreview)
		{
			final exe:String = #if windows 'ffmpeg.exe' #else 'ffmpeg' #end;
			if (!resolveFFmpeg(exe))
			{
				trace('"$exe" was not found, turning on preview mode...');
				ClientPrefs.data.previewRender = true;
				wentPreview = exe + ' was not found';
				// Fall through: still run the frame loop so a preview render is
				// a faithful rehearsal, just without writing anything.
			}
		}

		final writing:Bool = !ClientPrefs.data.previewRender;
		prepareOutputPath(songName, writing);

		if (writing)
		{
			try
			{
				process = new sys.io.Process('ffmpeg', buildArguments(songName));
			}
			catch (e:Dynamic)
			{
				trace('FFMpeg: failed to start ffmpeg: ' + Std.string(e));
				ClientPrefs.data.previewRender = true;
				wentPreview = 'ffmpeg failed to start: ' + Std.string(e);
				process = null;
			}
		}

		framesCaptured = 0;
		framesDropped = 0;
		framesProduced = 0;
		framesSkipped = 0;
		queued = 0;
		writePos = 0;
		writerBusy = false;
		writerDone = false;
		stderrLog = new StringBuf();
		mutex = new Mutex();
		errMutex = new Mutex();

		applyRenderLoopState();

		// "active" must be true BEFORE the writer starts. The writer treats
		// !active as "the render is over, stop", so starting it while active is
		// still false lets it exit on its very first pass - before a single
		// frame is queued - and then nothing is ever written.
		active = true;
		startedAt = haxe.Timer.stamp();
		startWriter();

		return true;
	}

	/**
	 * Captures the frames that the song clock has moved past since the last call.
	 * Call this once per drawn frame (FlxG.signals.postDraw). Never blocks the
	 * loop on the encoder except through enqueue()'s bounded backpressure.
	 */
	public function captureFrame():Void
	{
		if (!active || window == null || buffer == null)
			return;

		// The video timeline IS the song timeline. Deriving the frame count from
		// the song clock rather than from a step counter is what makes pausing
		// work: while paused, PlayState.update() does not run, songPosition is
		// frozen, and this writes nothing - the video skips the pause instead of
		// growing a frozen segment that would leave everything after it out of
		// sync with the muxed soundtrack.
		final target:Int = Std.int((Conductor.songPosition - songStartMs) / 1000.0 * fps);
		var need:Int = target - framesProduced;
		if (need <= 0)
			return; // paused, or a present-only tick

		// A seek or a very long stall must not turn one draw into a burst that
		// takes minutes to write; cap it and account for the rest.
		final burstCap:Int = fps * 10;
		if (need > burstCap)
		{
			framesSkipped += need - burstCap;
			need = burstCap;
		}

		if (!readWindowPixels())
			return; // no pixels this time; the next draw catches up

		// One frame per 1/fps slice: pixel data repeated when nothing was
		// redrawn in between (flixel ran several steps inside this draw).
		for (i in 0...need)
		{
			framesCaptured++;
			framesProduced++;
			if (process != null)
				enqueue(capture);
		}
	}

	/**
	 * Reads the colour buffer of the window into the reusable capture buffer (top-down RGBA).
	 *
	 * The fast path is the very same call lime's Window.readPixels makes on native targets -
	 * glReadPixels into a caller-owned pointer - but with the pointer supplied by us, so a
	 * captured frame allocates nothing: no Image, no ImageBuffer, no per-frame Bytes and no
	 * per-pixel conversion loop. GL hands back the bottom row first, so the rows are flipped in
	 * place afterwards, which is also what lime did (only into a buffer it had just allocated).
	 *
	 * Returns false when the framebuffer could not be read; the next drawn frame catches up.
	 */
	function readWindowPixels():Bool
	{
		if (capture == null || rowTemp == null)
			return false;

		#if (lime_cffi && (lime_opengl || lime_opengles) && !disable_cffi)
		try
		{
			// Constants come from the context of the window itself: GL_RGBA / GL_UNSIGNED_BYTE, the
			// exact pair lime uses, and the byte order the encoder is told to expect (-pix_fmt rgba).
			final gl = window.context.webgl;
			lime._internal.backend.native.NativeCFFI.lime_gl_read_pixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, capture);
		}
		catch (e:Dynamic)
		{
			return false;
		}
		flipRowsInPlace();
		return true;
		#else
		// Targets without CFFI: the old lime path. It allocates per frame (which is exactly what the
		// fast path avoids), so it stays only as a fallback for builds where CFFI is unavailable.
		var image:lime.graphics.Image = null;
		try
		{
			image = window.readPixels(buffer);
		}
		catch (e:Dynamic)
		{
			image = null;
		}
		if (image == null)
			return false;

		var data:Bytes = null;
		try
		{
			data = image.getPixels(buffer, lime.graphics.PixelFormat.RGBA32);
		}
		catch (e:Dynamic)
		{
			data = null;
		}

		try
		{
			image.dispose();
		}
		catch (e:Dynamic) {}

		if (data == null || data.length != capture.length)
			return false;
		// lime flips the rows for us on this path, so this is a plain copy.
		capture.blit(0, data, 0, capture.length);
		return true;
		#end
	}

	/**
	 * Vertical flip, in place: glReadPixels fills the buffer bottom row first. One row is moved
	 * through rowTemp at a time, exactly like the flip lime's own readPixels performs, but
	 * without allocating the temporary row per call.
	 */
	function flipRowsInPlace():Void
	{
		final rowLength:Int = width * 4;
		var destPosition:Int = 0;
		var srcPosition:Int = (height - 1) * rowLength;
		var rows:Int = Std.int(height / 2);
		while (rows-- > 0)
		{
			rowTemp.blit(0, capture, destPosition, rowLength);
			capture.blit(destPosition, capture, srcPosition, rowLength);
			capture.blit(srcPosition, rowTemp, 0, rowLength);
			destPosition += rowLength;
			srcPosition -= rowLength;
		}
	}

	/** Stops the render, drains the writer thread and closes ffmpeg. */
	public function stop():Void
	{
		if (!active)
			return;
		active = false;

		stopWriter();

		// Drop the read-back scratch: nothing reads it after this, and it is one full frame
		// buffer (8 MB at 1080p) that a GC-enabled session should be free to reclaim.
		capture = null;
		rowTemp = null;

		if (process != null)
		{
			try
			{
				process.stdin.close();
			}
			catch (e:Dynamic) {}

			try
			{
				// Give ffmpeg a bounded moment to finish muxing the trailer.
				process.exitCode(true);
			}
			catch (e:Dynamic)
			{
				try
				{
					process.kill();
				}
				catch (e2:Dynamic) {}
			}

			try
			{
				process.close();
			}
			catch (e:Dynamic) {}
			process = null;
		}

		restoreRenderLoopState();

		final wall:Float = Math.max(0.0001, haxe.Timer.stamp() - startedAt);
		writeLogFile(wall);

		trace('FFMpeg: finished. frames=' + framesWritten + ' (' + (Math.round(framesWritten / fps * 100) / 100) + 's of song) dropped=' + framesDropped + ' wall='
			+ (Math.round(wall * 100) / 100) + 's -> ' + fileName + fileExts);

		if (framesDropped > 0)
		{
			trace('FFMpeg: WARNING ' + framesDropped + ' frame(s) were never written; the video will be short.');
		}

		frames = null;
		slots = null;
		queued = 0;
		writePos = 0;
		writer = null;
		errPump = null;
	}

	// ── internals ────────────────────────────────────────────────────────────

	function resolveFFmpeg(exe:String):Bool
	{
		// An explicit path next to the executable always wins; otherwise rely on
		// PATH. Note: FileSystem.exists() is relative to the working directory,
		// while Process() resolves through PATH - these are deliberately
		// different lookups and only the PATH one is authoritative.
		if (FileSystem.exists(exe))
			return true;

		try
		{
			final probe = new sys.io.Process(#if windows 'where' #else 'which' #end, [exe]);
			//我们发现了一大堆棍母
			final out:String = probe.stdout.readAll().toString();
			probe.close();
			return out != null && out.length > 0;
		}
		catch (e:Dynamic)
		{
			// No 'where'/'which' (or it failed): assume ffmpeg is reachable via PATH.
			return true;
		}
	}

	function prepareOutputPath(songName:String, writing:Bool):Void
	{
		fileExts = (resolveVCodec().indexOf('vpx') >= 0) ? '.webm' : '.mp4';

		if (!writing)
		{
			fileName = target + '/preview';
			return;
		}

		try
		{
			if (!FileSystem.exists(target))
				FileSystem.createDirectory(target);
		}
		catch (e:Dynamic)
		{
			trace('FFMpeg: could not create "$target": ' + Std.string(e));
		}

		final safe:String = (songName == null || songName.length == 0) ? 'render' : sanitize(songName);
		fileName = target + '/' + safe;

		// Never overwrite: keep the first name clean, stamp later collisions.
		if (FileSystem.exists(fileName + fileExts))
			fileName += '-' + DateTools.format(Date.now(), '%Y-%m-%d_%H-%M-%S') + '-' + pad(Std.int(haxe.Timer.stamp() * 1000.0) % 1000, 3);
	}

	function resolveVCodec():String
	{
		final codec:String = ClientPrefs.data.renderCodec;
		return (codec != null && CODECS.exists(codec)) ? CODECS.get(codec) : 'libx264';
	}

	/**
	 * The song's audio files, as real paths ffmpeg can open. Mirrors how
	 * PlayState picks its tracks: the split Voices-Player / Voices-Opponent pair
	 * wins, otherwise the combined Voices. Empty when nothing is on disk (for
	 * example an embedded-only song), in which case the render is video-only.
	 */
	function collectAudioInputs(songName:String):Array<String>
	{
		final out:Array<String> = [];
		if (songName == null || songName.length == 0 || !ClientPrefs.data.renderAudio)
			return out;

		final key:String = Paths.formatToSongPath(songName);

		final inst:String = findAudioFile(key + '/Inst');
		if (inst != null)
			out.push(inst);

		final player:String = findAudioFile(key + '/Voices-Player');
		final opponent:String = findAudioFile(key + '/Voices-Opponent');
		if (player != null || opponent != null)
		{
			if (player != null)
				out.push(player);
			if (opponent != null)
				out.push(opponent);
		}
		else
		{
			final voices:String = findAudioFile(key + '/Voices');
			if (voices != null)
				out.push(voices);
		}

		return out;
	}

	/** First existing songs/<key>.<ext>, in the mod folders or next to the game. */
	function findAudioFile(key:String):String
	{
		for (ext in ['ogg', 'mp3', 'wav', 'm4a'])
		{
			#if MODS_ALLOWED
			final modPath:String = Paths.modFolders('songs/' + key + '.' + ext);
			if (modPath != null && FileSystem.exists(modPath))
				return modPath;
			#end

			final assetsPath:String = Sys.getCwd() + 'assets/songs/' + key + '.' + ext;
			if (FileSystem.exists(assetsPath))
				return assetsPath;
		}
		return null;
	}

	function buildArguments(songName:String):Array<String>
	{
		final vcodec:String = resolveVCodec();
		final isGPU:Bool = isGPUCodec(ClientPrefs.data.renderCodec);
		final isWebm:Bool = vcodec.indexOf('vpx') >= 0;

		// Input 0: raw frames over stdin. -r fps is the contract the whole class
		// is built on, so it must stay equal to the loop's pinned rate.
		final args:Array<String> = [
			'-v', 'error',
			'-y',
			'-f', 'rawvideo',
			'-pix_fmt', 'rgba',
			'-s', width + 'x' + height,
			'-r', Std.string(fps),
			'-i', '-',
		];

		audioPaths = collectAudioInputs(songName);

		// The song files' timeline IS the Conductor timeline, so the audio is
		// seeked to the song time the render started at. When that time is
		// negative (a render started during a countdown) there is nothing in the
		// file to seek to, so the whole track is delayed instead.
		final since:Float = startOffsetMs / 1000;
		final seek:Float = Math.max(0, since);
		final delay:Float = Math.max(0, -since);
		for (path in audioPaths)
		{
			if (delay > 0.001)
			{
				args.push('-itsoffset');
				args.push(fmt(delay));
			}
			if (seek > 0.001)
			{
				args.push('-ss');
				args.push(fmt(seek));
			}
			args.push('-i');
			args.push(path);
		}

		args.push('-c:v');
		args.push(vcodec);
		args.push('-pix_fmt');
		args.push('yuv420p');

		switch (ClientPrefs.data.renderMode)
		{
			case 'VBR', 'CBR':
				final bps:Int = Std.int(Math.max(1, ClientPrefs.data.renderBitrate) * 1000000);
				args.push('-b:v');
				args.push(Std.string(bps));
				if (ClientPrefs.data.renderMode == 'CBR')
				{
					args.push('-maxrate');
					args.push(Std.string(bps));
					args.push('-minrate');
					args.push(Std.string(bps));
					args.push('-bufsize');
					args.push(Std.string(bps * 2));
				}
			default: // CRF/CQP
				if (!isGPU)
				{
					// libx264/libx265/libvpx only do constant quality when the
					// target bitrate is explicitly zeroed.
					args.push('-b:v');
					args.push('0');
				}
				args.push(isGPU ? '-qp' : '-crf');
				args.push(Std.string(Std.int(Math.min(51, Math.max(0, ClientPrefs.data.renderQuality)))));
		}

		if (audioPaths.length > 0)
		{
			// The tracks are muxed at their own level and at 1x, and nothing else
			// belongs here: the engine seeks each file to Conductor.songPosition, so
			// the file timeline IS the song timeline captureFrame follows, and it
			// plays these tracks at volume 1 (see collectAudioInputs).
			// amix gets normalize=0, otherwise two inputs would halve each other.
			// apad makes the audio endless so the -shortest below ends the FILE with
			// the picture instead of with the soundtrack - without it a render whose
			// music ends before the picture does (the engine keeps songPosition
			// running for a while after the song) was cut short: measured, a 317 s
			// render came out 306 s long.
			var graph:String;
			if (audioPaths.length == 1)
			{
				graph = '[1:a]apad[aout]';
			}
			else
			{
				graph = '';
				for (i in 0...audioPaths.length)
					graph += '[' + (i + 1) + ':a]';
				graph += 'amix=inputs=' + audioPaths.length + ':duration=longest:normalize=0[amixed];[amixed]apad[aout]';
			}

			args.push('-map');
			args.push('0:v');
			args.push('-filter_complex');
			args.push(graph);
			args.push('-map');
			args.push('[aout]');

			args.push('-c:a');
			args.push(isWebm ? 'libopus' : 'aac');
			args.push('-b:a');
			args.push('320k');
			// Safe now that the audio is apad'ed to infinity: this ends the file
			// when the PICTURE ends, and can never cut the picture short.
			args.push('-shortest');
		}

		args.push(fileName + fileExts);
		return args;
	}

	function isGPUCodec(codec:String):Bool
	{
		if (codec == null)
			return false;
		for (tag in GPU_CODECS)
			if (codec.indexOf(tag) >= 0)
				return true;
		return false;
	}

	/** Locale-independent fixed-point formatting for ffmpeg number arguments. */
	inline function fmt(v:Float):String
		return Std.string(Math.round(v * 10000) / 10000);

	/** Left-pads value with zeros to width digits. */
	function pad(value:Int, width:Int):String
	{
		var s:String = Std.string(value);
		while (s.length < width)
			s = '0' + s;
		return s;
	}

	function sanitize(name:String):String
	{
		final out = new StringBuf();
		for (i in 0...name.length)
		{
			final c = name.charCodeAt(i);
			final valid = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 95;
			out.addChar(valid ? c : 95);
		}
		return out.toString();
	}

	/**
	 * Pins the loop to fps and forces a real draw every tick, for the duration of
	 * the render. Everything is restored in restoreRenderLoopState().
	 */
	function applyRenderLoopState():Void
	{
		savedFixedTimestep = FlxG.fixedTimestep;
		savedSkipIdle = FlxG.separateDrawSkipIdleFrames;
		savedAutoPause = FlxG.autoPause;
		savedUpdateFramerate = FlxG.updateFramerate;
		savedDrawFramerate = FlxG.drawFramerate;

		// One logic step must be exactly 1/fps of song time: this is what makes
		// frames / fps equal song time. Never speed up and never drift.
		FlxG.updateFramerate = fps;
		FlxG.drawFramerate = fps;
		FlxG.fixedTimestep = true;
		// Force a real draw every presented tick so every step has new pixels.
		FlxG.separateDrawSkipIdleFrames = false;
		FlxG.autoPause = false;
	}

	function restoreRenderLoopState():Void
	{
		FlxG.updateFramerate = savedUpdateFramerate;
		FlxG.drawFramerate = savedDrawFramerate;
		FlxG.fixedTimestep = savedFixedTimestep;
		FlxG.separateDrawSkipIdleFrames = savedSkipIdle;
		FlxG.autoPause = savedAutoPause;
	}

	function enqueue(frame:Bytes):Void
	{
		if (frames == null || slots == null || mutex == null)
			return;

		// Backpressure, NOT drop-on-full; see the class doc. Waiting is what
		// keeps frames / fps equal to song time.
		var waited:Int = 0;
		while (!slots.tryAcquire())
		{
			// Never deadlock if the encoder died under us.
			if (writerDone || process == null)
			{
				framesDropped++;
				return;
			}
			Sys.sleep(0.001);
			waited++;
			if (waited > 60000) // ~60 s with no free slot: give up on this frame
			{
				framesDropped++;
				return;
			}
		}

		mutex.acquire();
		final slot:Bytes = frames[writePos];
		// Copy into the ring slot: lime hands us a fresh Bytes per capture, and
		// the writer may still be reading the slot we are about to retire.
		if (slot.length == frame.length)
			slot.blit(0, frame, 0, frame.length);
		writePos = (writePos + 1) % frames.length;
		queued++;
		mutex.release();
	}

	function startWriter():Void
	{
		if (process == null)
			return;

		final ringSize:Int = Std.int(Math.max(2, ClientPrefs.data.renderBufferFrames));
		frames = [];
		for (i in 0...ringSize)
			frames.push(Bytes.alloc(width * height * 4));
		slots = new Semaphore(ringSize);

		final proc = process;
		writerDone = false;

		writer = Thread.create(function()
		{
			while (true)
			{
				mutex.acquire();
				var frame:Bytes = null;
				if (queued > 0)
				{
					frame = frames[(writePos - queued + frames.length * 2) % frames.length];
					queued--;
					writerBusy = true;
				}
				mutex.release();

				if (frame == null)
				{
					if (!active)
						break;
					Sys.sleep(0.001);
					continue;
				}

				var failed:Bool = false;
				try
				{
					proc.stdin.write(frame);
					proc.stdin.flush();
				}
				catch (e:Dynamic)
				{
					failed = true; // pipe closed / ffmpeg died
				}

				mutex.acquire();
				writerBusy = false;
				mutex.release();
				slots.release();

				if (failed)
					break;
			}

			mutex.acquire();
			writerDone = true;
			mutex.release();
		});

		startStderrPump(proc);
	}

	/**
	 * Reads ffmpeg's stderr on its own thread. The read BLOCKS on hxcpp (see the
	 * class doc), which is exactly why it must not share the writer thread.
	 */
	function startStderrPump(proc:sys.io.Process):Void
	{
		final err = proc.stderr;
		if (err == null)
			return;

		errPump = Thread.create(function()
		{
			final scratch:Bytes = Bytes.alloc(4096);
			while (true)
			{
				var got:Int = 0;
				try
				{
					got = err.readBytes(scratch, 0, scratch.length);
				}
				catch (e:Dynamic)
				{
					break;
				}

				if (got <= 0)
					break;

				errMutex.acquire();
				stderrLog.add(scratch.sub(0, got).toString());
				errMutex.release();
			}
		});
	}

	/**
	 * Waits (bounded) until the writer has drained the ring AND is not inside a
	 * write, so the tail of the video is not cut off by closing stdin too early.
	 * 不不不，为什么要停止,我要给你们的内存泄露到100G
	 */
	function stopWriter():Void
	{
		if (writer == null || mutex == null)
			return;

		var waited:Int = 0;
		var pending:Int = 0;

		while (waited < 500)
		{
			mutex.acquire();
			pending = queued;
			final busy:Bool = writerBusy;
			final done:Bool = writerDone;
			mutex.release();

			if (done || (pending <= 0 && !busy))
				break;

			Sys.sleep(0.01);
			waited++;
		}

		if (pending > 0)
			trace('FFMpeg: writer still had ' + pending + ' frame(s) queued; the video tail may be short.');

		mutex.acquire();
		queued = 0;
		mutex.release();
	}

	/**
	 * Writes <output>.log next to the video: the exact settings used, the frame
	 * counts, the song-time to wall-clock ratio, the audio tracks and ffmpeg's
	 * own stderr. This is the only reliable way to see why an encode went wrong.
	 */
	function writeLogFile(wall:Float):Void
	{
		if (fileName == null || fileName.length == 0)
			return;

		final ringCount:Int = (frames == null) ? 0 : frames.length;
		final songSeconds:Float = framesWritten / fps;
		final sb = new StringBuf();

		sb.add('ffmpeg render report\n');
		sb.add('output       : ' + fileName + fileExts + '\n');
		sb.add('codec        : ' + ClientPrefs.data.renderCodec + ' -> ' + resolveVCodec() + '\n');
		sb.add('rate control : ' + ClientPrefs.data.renderMode + '\n');
		if (ClientPrefs.data.renderMode == 'VBR' || ClientPrefs.data.renderMode == 'CBR')
			sb.add('bitrate      : ' + ClientPrefs.data.renderBitrate + ' Mbit/s\n')
		else
			sb.add('quality      : ' + ClientPrefs.data.renderQuality + '\n');
		sb.add('size / fps   : ' + width + 'x' + height + ' @ ' + fps + ' fps\n');
		sb.add('ring buffer  : ' + ringCount + ' frames (~' + Math.round(ringCount * width * height * 4 / 1048576.0) + ' MB)\n');
		sb.add('frames       : written=' + framesWritten + ' dropped=' + framesDropped + ' skipped=' + framesSkipped + '\n');
		sb.add('song time    : ' + (Math.round(songSeconds * 100) / 100) + ' s   (frames / fps - this is the video length)\n');
		sb.add('wall time    : ' + (Math.round(wall * 100) / 100) + ' s\n');
		sb.add('render speed : ' + (Math.round(songSeconds / wall * 100) / 100) + 'x realtime\n');
		if (audioPaths.length == 0)
			sb.add('audio        : (no track found - video only)\n')
		else
			for (path in audioPaths)
				sb.add('audio        : ' + path + '\n');
		sb.add('audio level  : nominal (the game plays these tracks at volume 1)\n');
		sb.add('audio offset : ' + fmt(startOffsetMs / 1000) + ' s of song time at video t=0\n');

		if (framesDropped > 0)
			sb.add('\nWARNING: ' + framesDropped + ' frame(s) were never written.\n'
				+ 'A missing frame is a missing slice of song time, so the video is short and plays too fast.\n'
				+ 'Raise Render Buffer or pick a faster codec.\n');

		if (audioPaths.length == 0)
			sb.add('\nNOTE: no audio file was found for this song, so the video has no sound.\n');

		errMutex.acquire();
		final err:String = stderrLog.toString();
		errMutex.release();
		if (err != null && StringTools.trim(err).length > 0)
			sb.add('\nffmpeg stderr:\n' + err);

		final path:String = fileName + '.log';
		try
		{
			sys.io.File.saveContent(path, sb.toString());
		}
		catch (e:Dynamic)
		{
			trace('FFMpeg: could not write "' + path + '": ' + Std.string(e));
		}
	}
}
#end
//这个mohong魔了
