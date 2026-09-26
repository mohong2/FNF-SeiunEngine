package online_server;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/**
 * Binary storage for avatars and backgrounds: one file per image under <data-dir>/images/,
 * keeping large images out of the fully-rewritten account JSON. Reads and writes go through
 * JsonStore.lock; never call from inside a lock callback.
 */
class ImageStore {
	static var dir:String = "server/data/images";

	public static function init(dataDir:String):Void {
		dir = dataDir + "/images";
		try {
			if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		} catch (e:Dynamic) {
			trace('[images] could not create ' + dir + ': ' + Std.string(e));
		}
	}

	public static function storageDir():String return dir;

	/** Whitelist-sanitizes the id so a path can never escape the image directory. */
	static function safeId(id:String):String {
		if (id == null) return "_";
		var out = new StringBuf();
		for (i in 0...id.length) {
			var c = id.charAt(i);
			if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
				out.add(c);
			}
		}
		var s = out.toString();
		return s == "" ? "_" : s;
	}

	static function pathOf(id:String, kind:String):String {
		return dir + "/" + safeId(id) + "." + kind;
	}

	/** Stores an image, overwriting any previous one of the same kind. */
	public static function put(id:String, kind:String, data:Bytes):Bool {
		if (id == null || kind == null || data == null) return false;
		return JsonStore.lock(function() {
			try {
				if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
				File.saveBytes(pathOf(id, kind), data);
				return true;
			} catch (e:Dynamic) {
				trace('[images] write failed: ' + Std.string(e));
				return false;
			}
		});
	}

	/** Reads an image; null makes the endpoint answer 404. */
	public static function get(id:String, kind:String):Null<Bytes> {
		if (id == null || kind == null) return null;
		return JsonStore.lock(function() {
			var p = pathOf(id, kind);
			if (!FileSystem.exists(p)) return null;
			try return File.getBytes(p) catch (e:Dynamic) {
				trace('[images] read failed: ' + Std.string(e));
				return null;
			}
		});
	}

	public static function has(id:String, kind:String):Bool return get(id, kind) != null;

	/** Deletes both images; false makes the endpoint answer 500. */
	public static function remove(id:String):Bool {
		if (id == null) return false;
		return JsonStore.lock(function() {
			var ok = true;
			for (kind in ["avatar", "background"]) {
				var p = pathOf(id, kind);
				try {
					if (FileSystem.exists(p)) FileSystem.deleteFile(p);
				} catch (e:Dynamic) {
					trace('[images] delete failed: ' + Std.string(e));
					ok = false;
				}
			}
			return ok;
		});
	}
}
