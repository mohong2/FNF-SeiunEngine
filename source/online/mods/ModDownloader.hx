package online.mods;

import haxe.Exception;
import sys.FileSystem;
import online.mods.GameBanana;
import online.http.HTTPClient;
import sys.io.File;
import online.util.OnlineLang;

class ModDownloader {
	public static var downloaders:Array<ModDownloader> = [];
	public static var failed:Array<String> = [];

	public var client:HTTPClient;
	public var alert:DownloadAlert;

	/**
	 * `HTTPClient` follows 3xx redirects by itself (absolute and relative `Location`) but has no
	 * redirect limit: a loop recurses until Stack Overflow, a native crash on
	 * cpp. Every followed redirect re-enters `CONNECTING`, so that is the counter here — the first
	 * is the original request, and the request is canceled once MAX_REDIRECTS is exceeded.
	 */
	static inline var MAX_REDIRECTS:Int = 3;
	var redirectCount:Int = 0;
	var tooManyRedirects:Bool = false;

	public var status(default, set):Null<DownloaderStatus>;
	function set_status(v) {
		if (onStatus != null)
			onStatus(v);
		return status = v;
	}
	public var onStatus:DownloaderStatus->Void;

	// Both directories are resolved on first use: touching `File.applicationDirectory` from a class
	// static initializer runs during hxcpp boot, where lime's Android directory lookup hands a null
	// JNI string to its string conversion and dereferences it (strlen(NULL), SIGSEGV). Android also
	// has to write somewhere writable, so it uses the engine's storage directory.
	static var downloadDir(get, never):String;
	static function get_downloadDir():String return modDir() + "/downloads/";

	static function modDir():String
	{
		#if android
		return SUtil.getStorageDirectory();
		#else
		return openfl.filesystem.File.applicationDirectory.nativePath;
		#end
	}
	var downloadPath:String;
	var id:String;
	public var url:String;

	public function new(fileName:String, modURL:String, ?gbMod:GBMod, ?onSuccess:String->Void, ?headers:Map<String, String>, ?ogURL:String) {
		// Haxe 4.2.5 has no null-coalescing operator; expand it.
		url = ogURL != null ? ogURL : modURL;
		id = FileUtils.formatFile(url);
		downloadPath = downloadDir + id + ".dwl";
		fileName = FileUtils.formatFile(fileName);

		for (down in downloaders) {
			if (down.id == id)
				return;
		}

		if (downloaders.length >= 6) {
			Waiter.putPersist(() -> {
				Alert.alert(OnlineLang.L('dl.failed', 'Downloading failed!'), OnlineLang.L('dl.tooMany', 'Too many files are downloading right now! (Max 6)'));
			});
			return;
		}

		if (!FileSystem.exists(downloadDir)) {
			FileSystem.createDirectory(downloadDir);
		}

		client = new HTTPClient(modURL);
		alert = new DownloadAlert(url);

		client.onStatus = v -> {
			switch (v) {
				case CONNECTING:
					if (redirectCount > MAX_REDIRECTS) {
						tooManyRedirects = true;
						client.cancel();
						return;
					}
					redirectCount++;
					status = CONNECTING;
				case READING_HEADERS:
					status = READING_HEADERS;
				case READING_BODY:
					status = READING_BODY;
					if (!isMediaTypeAllowed(client.response.headers.get("content-type"))) {
						client.cancel();
						Waiter.putPersist(() -> {
							Alert.alert(OnlineLang.L('dl.failed', 'Downloading failed!'), client.response.headers.get("content-type") + OnlineLang.L('dl.badFileType', ' may be invalid or unsupported file type!'));
							RequestSubstate.requestURL(url, "The following mod needs to be installed from this source", true);
						});
					}
				case COMPLETED:
					status = DOWNLOADED;
				case FAILED(exc):
					status = FAILED(exc);
					failed.push(modURL);
			}
		};

		downloaders.push(this);
		
		Thread.run(() -> {
			try {
				// The engine's `HTTPRequest` typedef (source/online/http/HTTPClient.hx) has an
				// `@:optional var headers` field and no `header` field, so `header:` would fail to
				// type ("has no field header", "field headers has different property access").
				client.request({
					output: File.append(downloadPath, true),
					headers: headers
				});
			} 
			catch (exc) {
				if (!client.cancelRequested) {
					Waiter.putPersist(() -> {
						Alert.alert(OnlineLang.L('dl.errorTitle', 'Error!'), id + ': ' + ShitUtil.prettyError(exc));
					});
				}
			}

			client.close();

			// Haxe 4.2.5 has no safe-navigation (`?.`); the checks below are the explicit expansion
			// of `client.response?.isFailed()` / `client?.response?.exception`.
			if (client.response != null && client.response.isFailed()) {
				// A redirect-limit cancel is self-initiated (so `cancelRequested` is also true) and
				// must be detected first, otherwise the generic "Download canceled!" below would
				// swallow it even though the user never clicked cancel.
				if (tooManyRedirects) {
					Waiter.putPersist(() -> {
						Alert.alert(OnlineLang.L('dl.failed', 'Downloading failed!'), OnlineLang.L('dl.tooManyRedirects', 'Too many redirects (more than ') + '$MAX_REDIRECTS' + OnlineLang.L('dl.tooManyRedirectsTail', ') for:') + '\n' + url);
					});
				}
				else if (client.cancelRequested) {
					Waiter.putPersist(() -> {
						Alert.alert(OnlineLang.L('dl.canceled', 'Download canceled!'));
					});
				}
				else {
					Waiter.putPersist(() -> {
						Alert.alert(OnlineLang.L('dl.failed', 'Downloading failed!'), 
							ShitUtil.prettyStatus(client.response.status) + "\n" +
							(client != null && client.response != null && client.response.exception != null ? ShitUtil.prettyError(client.response.exception) : '')
						);
					});
				}
				delete();
			}
			else {
				status = INSTALLING;
				// After download the mod is no longer installed automatically: a confirmation is
				// shown first. The temp file must survive until the user answers, so keepFile = true;
				// the synchronous installMod() call in this download thread is gone.
				var pendingPath = downloadPath;
				var pendingURL = url;
				var pendingGB = gbMod;
				var pendingSuccess = onSuccess;
				Waiter.putPersist(() -> {
					OnlineMods.askInstallMod(pendingPath, pendingURL, pendingGB, pendingSuccess);
				});
				delete(true);
			}
		});
    }

	/** keepFile = true keeps the .dwl (download succeeded, waiting for install confirmation); failed / canceled downloads delete it. */
	function delete(?keepFile:Bool = false) {
		downloaders.remove(this);
		if (alert != null)
			alert.destroy();
		alert = null;
		if (!keepFile)
			deleteTempFile();
	}

	/**
	 * Canceling the install does not delete the downloaded file; it is moved to keptDir.
	 * The extension changes from .dwl to .zip (same archive, a suffix a user can double-click
	 * or drag). Returns the new path, or null if the source is missing or the move failed.
	 * Existing names are not overwritten; _1 / _2 ... is appended.
	 */
	// See `modDir`: resolved on first use so hxcpp boot never touches the asset directory.
	public static var keptDir(get, never):String;
	static function get_keptDir():String return modDir() + '/downloaded_mods/';

	public static function keepPendingFile(path:String):String {
		try {
			if (path == null || !FileSystem.exists(path)) return null;
			if (!FileSystem.exists(keptDir)) FileSystem.createDirectory(keptDir);

			var name = path.split('/').pop();
			if (StringTools.endsWith(name, '.dwl'))
				name = name.substr(0, name.length - 4) + '.zip';
			var dest = keptDir + name;
			var i = 1;
			while (FileSystem.exists(dest)) {
				dest = keptDir + name.substr(0, name.length - 4) + '_' + i + '.zip';
				i++;
			}

			try FileSystem.rename(path, dest)
			catch (e:Dynamic) {
				File.copy(path, dest); // Haxe 4.2.5's sys.io.File.copy takes only 2 args (dest is guaranteed absent)
				FileSystem.deleteFile(path);
			}
			return dest;
		} catch (e:Dynamic) {
			trace('[ModDownloader] keepPendingFile failed: ' + Std.string(e));
			return null;
		}
	}

	/** Deletes the pending-install temp file (failure branch / after install completes). */
	public static function deletePendingFile(path:String):Void {
		try {
			if (path != null && FileSystem.exists(path)) {
				FileSystem.deleteFile(path);
			}
		} catch (_:Dynamic) {}
	}

	function deleteTempFile() {
		try {
			if (FileSystem.exists(downloadPath)) {
				FileSystem.deleteFile(downloadPath);
			}
		} catch (_) {}
	}

    static var allowedMediaTypes:Array<String> = [
		"application/zip",
		"application/zip-compressed",
		"application/x-zip-compressed",
		"application/x-zip",
		"application/x-tar",
		"application/gzip",
		"application/x-gtar",
		"application/octet-stream", // unknown files
		#if RAR_SUPPORTED
		"application/vnd.rar",
		"application/x-rar-compressed",
		"application/x-rar",
		#end
	];

	public static function isMediaTypeAllowed(file:String) {
		file = file.trim();
		for (item in allowedMediaTypes) {
			if (file == item)
				return true;
		}
		return false;
	}

	public static function cancelAll() {
		Sys.println("Cancelling " + downloaders.length + " downloads...");
		for (downloader in downloaders) {
			if (downloader != null)
				downloader.client.cancel();
		}
	}

	public static function checkDeleteDlDir() {
		if (FileSystem.exists(downloadDir)) {
			FileUtils.removeFiles(downloadDir);
		}
	}
}

enum DownloaderStatus {
	CONNECTING;
	READING_HEADERS;
	READING_BODY;
	FAILED(exc:Exception);
	DOWNLOADED;
	INSTALLING;
	FINISHED;
}