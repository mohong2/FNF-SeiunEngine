package;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;

typedef Library = {
	name:String, type:String,
	version:String, dir:String,
	ref:String, url:String
}

typedef LibInfo = {
	root:String,
	version:String
}

class Main {
	public static function main():Void {
		if (!FileSystem.exists(".haxelib") && Sys.getEnv("GITHUB_ACTIONS") == null)
			FileSystem.createDirectory(".haxelib");

		final libs:Array<Library> = Json.parse(File.getContent('./hmm.json')).dependencies;

		for (data in libs) {
			switch (data.type) {
				case "install", "haxelib":
					var version:String = data.version == null ? "" : data.version;
					var extraArgs:String = Sys.getEnv("GITHUB_ACTIONS") == null ? "" : " --never";
					if (Sys.command('haxelib --quiet install ${data.name} ${version}${extraArgs}') != 0) {
						Sys.println('[SEIUN ENGINE SETUP]: Failed to install ${data.name}');
						Sys.exit(1);
					}
				case "git":
					var ref:String = data.ref == null ? "" : data.ref;
					if (Sys.command('haxelib --quiet git ${data.name} ${data.url} ${data.ref}') != 0) {
						Sys.println('[SEIUN ENGINE SETUP]: Failed to install ${data.name} from ${data.url}');
						Sys.exit(1);
					}
				case "dev":
					if (Sys.command('haxelib --quiet dev ${data.name} ${data.url}') != 0) {
						Sys.println('[SEIUN ENGINE SETUP]: Failed to link ${data.name} to ${data.url}');
						Sys.exit(1);
					}
				default:
					Sys.println('[SEIUN ENGINE SETUP]: Unable to resolve library of type "${data.type}" for library "${data.name}"');
			}
		}

		for (data in libs) {
			if ((data.type == "install" || data.type == "haxelib") && data.version != null && data.version != "") {
				Sys.command('haxelib --quiet set ${data.name} ${data.version}');
			}
		}

		applyFlxanimatePatch();
		applyLimeSdlConfigPatch();
		applyLimeAudioPatch();

		Sys.exit(0);
	}

	static function applyFlxanimatePatch():Void
	{
		var patchDir:String = './setup/flxanimate_haxe425_patch';
		if (!FileSystem.exists(patchDir)) return;

		var libPath:String = '';
		try
		{
			var proc = new sys.io.Process('haxelib', ['path', 'flxanimate']);
			libPath = StringTools.trim(proc.stdout.readLine());
			proc.close();
		}
		catch (e:Dynamic)
		{
			Sys.println('[SEIUN ENGINE SETUP]: Cannot resolve flxanimate path, skip patch.');
			return;
		}

		if (libPath.length < 1 || StringTools.startsWith(libPath, '-D')) return;
		libPath = StringTools.replace(libPath, '\\', '/');
		while (StringTools.endsWith(libPath, '/')) libPath = libPath.substr(0, libPath.length - 1);

		var files:Array<Array<String>> = [
			['FlxElement.hx', 'flxanimate/animate/FlxElement.hx'],
			['MacroAnimationData.hx', 'flxanimate/data/MacroAnimationData.hx'],
			['FlxAnimateFrames.hx', 'flxanimate/frames/FlxAnimateFrames.hx']
		];
		for (pair in files)
		{
			var src:String = '$patchDir/${pair[0]}';
			var dst:String = '$libPath/${pair[1]}';
			if (FileSystem.exists(src))
			{
				File.saveContent(dst, File.getContent(src));
				Sys.println('[SEIUN ENGINE SETUP]: Patched $dst');
			}
		}
	}

	/**
	 * 修复在 Linux 主机上交叉编译 Android 时，Lime 的 SDL/SDL3 构建配置
	 * 误用 Linux 的 SDL_config（定义 SDL_VIDEO_DRIVER_X11）导致
	 * X11/Xlib.h 缺失的问题。Android 目标应使用 Android 专用配置。
	 *
	 * 注：早期实现把 `haxelib path lime` 的**第一条非 "-" 行**当库根，但那是 `.../lime/<ver>/src/`，
	 * 于是拼出的 `.../src/project/...` 并不存在，本补丁从未真正生效；现已改用
	 * `resolveHaxelibLib('lime').root` 拿到真实库根（不含 /src）。
	 */
	static function applyLimeSdlConfigPatch():Void
	{
		var info:LibInfo = resolveHaxelibLib('lime');
		if (info == null) return;

		var libPath:String = info.root;

		var files:Array<String> = [
			'$libPath/project/lib/sdl3-files.xml',
			'$libPath/project/lib/sdl/files.xml',
			'$libPath/project/Build.xml'
		];

		var anyPatched:Bool = false;
		var anyFound:Bool = false;
		for (file in files)
		{
			if (!FileSystem.exists(file)) continue;
			anyFound = true;
			var content:String = File.getContent(file);
			var original:String = content;

			// SDL3: Android 使用通用 build_config（内部按 SDL_PLATFORM_ANDROID 选 android 配置），
			// Linux 配置仅用于真正的 Linux 目标。
			content = StringTools.replace(content,
				'value="${"$"}{NATIVE_TOOLKIT_PATH}/custom/sdl3/linux" if="linux" unless="rpi"/>',
				'value="${"$"}{NATIVE_TOOLKIT_PATH}/sdl3/include/build_config" if="android" />\n       <set name="SDL_CONFIG_PATH" value="${"$"}{NATIVE_TOOLKIT_PATH}/custom/sdl3/linux" if="linux" unless="rpi || android"/>');

			// SDL2: Android 使用 default 配置（内部按 __ANDROID__ 选 android 配置）。
			content = StringTools.replace(content,
				'value="${"$"}{NATIVE_TOOLKIT_PATH}/sdl/include/configs/linux/" if="linux" unless="rpi"/>',
				'value="${"$"}{NATIVE_TOOLKIT_PATH}/sdl/include/configs/default/" if="android" />\n       <set name="SDL_CONFIG_PATH" value="${"$"}{NATIVE_TOOLKIT_PATH}/sdl/include/configs/linux/" if="linux" unless="rpi || android"/>');

			// Build.xml 中 SDL2 的 include 路径同样要避免在 Android 交叉编译时使用 Linux config。
			content = StringTools.replace(content,
				'<compilerflag value="-I${"$"}{NATIVE_TOOLKIT_PATH}/sdl/include/configs/linux/" if="linux" unless="rpi" />',
				'<compilerflag value="-I${"$"}{NATIVE_TOOLKIT_PATH}/sdl/include/configs/default/" if="android" />\n\t\t\t\t<compilerflag value="-I${"$"}{NATIVE_TOOLKIT_PATH}/sdl/include/configs/linux/" if="linux" unless="rpi || android" />');

			if (content != original)
			{
				File.saveContent(file, content);
				Sys.println('[SEIUN ENGINE SETUP]: Patched $file');
				anyPatched = true;
			}
		}

		if (!anyFound)
		{
			Sys.println('[SEIUN ENGINE SETUP]: Lime SDL config patch targets not found, skip. (lime root: $libPath)');
		}
		else if (!anyPatched)
		{
			Sys.println('[SEIUN ENGINE SETUP]: Lime SDL config already patched or not needed. (lime root: $libPath)');
		}
	}

	/**
	 * 解析 haxelib 库的安装根目录与版本号。
	 *
	 * 不能假设 `haxelib path` 的输出是干净的路径列表：extraParams.hxml 的内容会被直接拼进来
	 * （本仓库 hscript-seiun 的第一行还是带 BOM 的 `--macro ...`，BOM 让「是否以 - 开头」判断失效），
	 * 而且 lime 给出的第一条真实路径是 `.../src/` 而不是库根。所以这里：
	 *   1) 只接受「真实存在的目录」行，并从它逐级向上找到含 haxelib.json 的库根；
	 *   2) 版本优先取 `-D <name>=<ver>` 行，取不到再读库根的 haxelib.json。
	 * 解析失败只打印可读信息并返回 null，由调用方跳过补丁，不中断 setup。
	 */
	static function resolveHaxelibLib(name:String):LibInfo
	{
		var root:String = null;
		var version:String = null;

		try
		{
			var proc = new sys.io.Process('haxelib', ['path', name]);
			var output:String = proc.stdout.readAll().toString();
			proc.close();

			var definePrefix:String = '-D $name=';
			for (line in output.split('\n'))
			{
				var l:String = StringTools.trim(line);
				if (l.length < 1) continue;

				// 去掉 BOM：haxelib 会把 extraParams.hxml 的内容原样拼进输出，本仓库
				// hscript-seiun 的第一行就是带 BOM 的 `--macro ...`，BOM 会让「是否以 - 开头」失效。
				if (l.charCodeAt(0) == 0xFEFF) l = l.substr(1);
				if (l.length < 1) continue;

				if (version == null && StringTools.startsWith(l, definePrefix))
				{
					version = l.substr(definePrefix.length);
					continue;
				}

				if (root == null && !StringTools.startsWith(l, '-'))
				{
					// 统一分隔符并去尾部斜杠：haxelib 在 Windows 上可能给全反斜杠路径，
					// 混用会让 lastIndexOf('/') 失效。
					// 另外 haxelib 打印的目录**不一定存在**（lime 会打印 `.../<lib>/src`，
					// 而 `src` 可以不存在），所以不能先要求它存在，直接向上逐级找库根。
					var dir:String = StringTools.replace(l, '\\', '/');
					while (StringTools.endsWith(dir, '/')) dir = dir.substr(0, dir.length - 1);
					for (_ in 0...5)
					{
						if (FileSystem.exists('$dir/haxelib.json'))
						{
							root = dir;
							break;
						}
						var cut:Int = dir.lastIndexOf('/');
						if (cut < 0) break;
						dir = dir.substr(0, cut);
					}
				}
			}
		}
		catch (e:Dynamic)
		{
			Sys.println('[SEIUN ENGINE SETUP]: Cannot resolve $name path, skip its patch.');
			return null;
		}

		if (root == null)
		{
			Sys.println('[SEIUN ENGINE SETUP]: Cannot locate $name library root, skip its patch.');
			return null;
		}

		root = StringTools.replace(root, '\\', '/');
		while (StringTools.endsWith(root, '/')) root = root.substr(0, root.length - 1);

		if (version == null)
		{
			var jsonPath:String = '$root/haxelib.json';
			if (FileSystem.exists(jsonPath))
			{
				try
				{
					version = Json.parse(File.getContent(jsonPath)).version;
				}
				catch (e:Dynamic)
				{
					version = null;
				}
			}
		}

		return {root: root, version: version};
	}

	/** 按点号分段比较版本号，a >= b 返回 >= 0；非数字段按 0 处理。 */
	static function compareVersion(a:String, b:String):Int
	{
		var pa:Array<String> = a.split('.');
		var pb:Array<String> = b.split('.');
		var n:Int = pa.length > pb.length ? pa.length : pb.length;
		for (i in 0...n)
		{
			var na:Null<Int> = i < pa.length ? Std.parseInt(pa[i]) : 0;
			var nb:Null<Int> = i < pb.length ? Std.parseInt(pb[i]) : 0;
			var va:Int = na == null ? 0 : na;
			var vb:Int = nb == null ? 0 : nb;
			if (va != vb) return va > vb ? 1 : -1;
		}
		return 0;
	}

	/**
	 * E3（lime NativeAudioSource 音频跳转修复）在 lime >= 8.4.0 上不需要库侧补丁：
	 * 上游重写的实现已天然包含本地那两处修复——
	 *   stop() 直接调 setCurrentTime(0)，不再多发一次 AL.sourcePlay；
	 *   setCurrentTime() 先 AL.sourcei(handle, AL.BYTE_OFFSET, ...) 再 if (playing) AL.sourcePlay(handle)。
	 * 依据：lime 8.4.0 的 NativeAudioSource.hx 里 stop() 与 setCurrentTime() 的实现本身。
	 *
	 * 真正会让 target 栈编译失败的，是仓库里残留的旧版整份覆盖文件
	 * source/lime/_internal/backend/native/NativeAudioSource.hx：Haxe 的类路径是
	 * 「后写的 -cp 优先」，而 `-cp source` 排在 lime 之后，会把上游实现整个遮蔽掉，
	 * 于是 lime 8.4.0 的 AudioManager 找不到 prepareAudioContextRecovery / restoreAudioContextRecovery。
	 *
	 * 本函数只做检测与提示，不写任何文件、不中断 setup：删除 source/ 下的覆盖文件属于源码改动，
	 * 必须由「切换到 lime >= 8.4.0」这一步显式执行，不能在 setup 里偷偷删。
	 */
	static function applyLimeAudioPatch():Void
	{
		var overrideFile:String = 'source/lime/_internal/backend/native/NativeAudioSource.hx';
		if (!FileSystem.exists(overrideFile))
		{
			Sys.println('[SEIUN ENGINE SETUP]: No lime audio override in source/, E3 patch not needed.');
			return;
		}

		var info:LibInfo = resolveHaxelibLib('lime');
		if (info == null) return;

		if (info.version == null)
		{
			Sys.println('[SEIUN ENGINE SETUP]: Cannot determine lime version, E3 override check skipped.');
			return;
		}

		if (compareVersion(info.version, '8.4.0') >= 0)
		{
			Sys.println('[SEIUN ENGINE SETUP]: WARNING: lime ${info.version} already contains the E3 audio fixes, but $overrideFile still shadows it.');
			Sys.println('[SEIUN ENGINE SETUP]: WARNING: delete that override file, or lime AudioManager will not find prepareAudioContextRecovery / restoreAudioContextRecovery.');
		}
		else
		{
			Sys.println('[SEIUN ENGINE SETUP]: lime ${info.version} < 8.4.0, keeping the E3 audio override in source/ as-is.');
		}
	}

}
