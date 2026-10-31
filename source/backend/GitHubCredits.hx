package backend;

import haxe.Json;
import haxe.io.Bytes;
import lime.utils.AssetType;
import lime.utils.Assets as LimeAssets;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Contributor list + avatar cache for the credits screen.
 *
 * Order of preference:
 *   1. the on-disk API cache (instant, works offline),
 *   2. the live /repos/{owner}/{repo}/contributors call (desktop/mobile only),
 *   3. the snapshot shipped in assets/data/github_contributors.json.
 *
 * The screen therefore renders immediately even when GitHub is unreachable, and gets a
 * second update as soon as the network answers. Avatars follow the same rule: a fresh
 * disk copy is used first, a stale one is re-downloaded and kept as the fallback if the
 * download fails. Nothing here throws into the UI.
 */
class GitHubCredits
{
	static inline var API_CACHE_FILE:String = 'contributors.json';
	static inline var AVATAR_SIZE:Int = 150;
	static inline var MAX_CONTRIBUTORS:Int = 30;
	static inline var AVATAR_TTL_MS:Float = 6 * 60 * 60 * 1000.0;
	static inline var OFFLINE_ASSET:String = 'assets/data/github_contributors.json';

	static var resolvedCacheDir:String = null;
	static var offlineList:Array<GitHubContributor> = null;
	static var memoryAvatars:Map<String, Bytes> = new Map();

	/** Link to the repository's contributor graph, for the section header entry. */
	public static function repositoryUrl():String
	{
		return 'https://github.com/' + GitHubAPI.OWNER + '/' + GitHubAPI.REPO;
	}

	public static function contributorsUrl():String
	{
		return repositoryUrl() + '/graphs/contributors';
	}

	/**
	 * Load the contributor list. `onUpdate` can run twice: once with cached/offline data
	 * so the screen can draw something immediately, and again with live data. Callers
	 * must therefore tolerate repeated calls and keep their own "is this still me?" guard.
	 */
	public static function load(onUpdate:GitHubCreditsResult->Void, ?forceRefresh:Bool = false):Void
	{
		if (onUpdate == null) return;

		var cached:Array<GitHubContributor> = forceRefresh ? null : readApiCache();
		if (cached != null && cached.length > 0)
			onUpdate({contributors: cached, online: false, fromCache: true, error: null});

		#if CHECK_FOR_UPDATES
		GitHubAPI.getContributors(GitHubAPI.OWNER, GitHubAPI.REPO, 100, 1, function(data:Dynamic)
		{
			var fresh:Array<GitHubContributor> = normalize(data);
			if (fresh.length == 0)
			{
				if (cached == null || cached.length == 0)
					offlineUpdate(onUpdate, 'GitHub returned no contributors');
				return;
			}

			writeApiCache(fresh);
			onUpdate({contributors: fresh, online: true, fromCache: false, error: null});
		}, function(error:String)
		{
			if (cached == null || cached.length == 0)
				offlineUpdate(onUpdate, error);
			else
				onUpdate({contributors: cached, online: false, fromCache: true, error: error});
		});
		#else
		if (cached == null || cached.length == 0)
			offlineUpdate(onUpdate, 'online features are disabled in this build');
		#end
	}

	static function offlineUpdate(onUpdate:GitHubCreditsResult->Void, error:String):Void
	{
		var list:Array<GitHubContributor> = offline();
		onUpdate({contributors: list, online: false, fromCache: false, error: error});
	}

	/**
	 * Fetch one avatar. Calls `onBytes` with cached data immediately when it is fresh;
	 * otherwise downloads, and on failure falls back to stale cached bytes, then to
	 * `onFail` (the caller keeps the bundled/generic icon).
	 */
	public static function loadAvatar(contributor:GitHubContributor, onBytes:Bytes->Void, ?onFail:Void->Void):Void
	{
		if (contributor == null || onBytes == null) return;

		var key:String = avatarKey(contributor);
		var memory:Bytes = memoryAvatars.get(key);
		if (memory != null && memory.length > 0)
		{
			onBytes(memory);
			return;
		}

		var cached:Bytes = readAvatarCache(contributor);
		if (cached != null && avatarCacheFresh(contributor))
		{
			memoryAvatars.set(key, cached);
			onBytes(cached);
			return;
		}

		#if CHECK_FOR_UPDATES
		var url:String = sizedAvatarUrl(contributor.avatarUrl);
		if (url.length == 0)
		{
			useFallbackAvatar(contributor, cached, onBytes, onFail);
			return;
		}

		GitHubAPI.downloadBytes(url, function(bytes:Bytes)
		{
			if (bytes == null || bytes.length == 0)
			{
				useFallbackAvatar(contributor, cached, onBytes, onFail);
				return;
			}
			memoryAvatars.set(key, bytes);
			writeAvatarCache(contributor, bytes);
			onBytes(bytes);
		}, function(error:String)
		{
			useFallbackAvatar(contributor, cached, onBytes, onFail);
		});
		#else
		useFallbackAvatar(contributor, cached, onBytes, onFail);
		#end
	}

	static function useFallbackAvatar(contributor:GitHubContributor, cached:Bytes, onBytes:Bytes->Void, onFail:Void->Void):Void
	{
		if (cached != null && cached.length > 0)
		{
			memoryAvatars.set(avatarKey(contributor), cached);
			onBytes(cached);
			return;
		}
		if (onFail != null) onFail();
	}

	/** Bundled icon key under assets/preload/images/credits/, or "none". */
	public static function bundledAvatarKey(login:String):String
	{
		if (login == null || login.length == 0) return 'none';
		var id:String = 'assets/images/credits/github/' + login + '.png';
		try
		{
			if (LimeAssets.exists(id, AssetType.IMAGE)) return 'github/' + login;
		}
		catch (e:Dynamic) {}
		return 'none';
	}

	// ------------------------------------------------------------------ normalization

	/**
	 * Turn a REST payload (array of contributors) or the offline snapshot object into a
	 * clean, sorted list. Accepts both snake_case (API) and camelCase (our cache/asset).
	 */
	public static function normalize(data:Dynamic):Array<GitHubContributor>
	{
		var raw:Array<Dynamic> = null;
		if (Std.isOfType(data, Array))
		{
			raw = cast data;
		}
		else if (data != null)
		{
			var list:Dynamic = Reflect.field(data, 'contributors');
			if (Std.isOfType(list, Array)) raw = cast list;
		}
		if (raw == null) return [];

		var out:Array<GitHubContributor> = [];
		var seen:Map<String, Bool> = new Map();
		for (item in raw)
		{
			if (item == null) continue;

			var login:String = str(field(item, ['login', 'username']));
			if (login.length == 0) continue;
			var key:String = login.toLowerCase();
			if (seen.exists(key)) continue;
			seen.set(key, true);

			var type:String = str(field(item, ['type']));
			var bot:Bool = type.toLowerCase() == 'bot';
			if (bot) continue;

			var id:Int = intVal(field(item, ['id']), 0);
			var profile:String = str(field(item, ['html_url', 'htmlUrl', 'profileUrl', 'url']));
			if (profile.indexOf('api.github.com') >= 0) profile = 'https://github.com/' + login;
			if (profile.length == 0) profile = 'https://github.com/' + login;

			out.push({
				login: login,
				name: str(field(item, ['name', 'displayName'])),
				id: id,
				avatarUrl: str(field(item, ['avatar_url', 'avatarUrl'])),
				profileUrl: profile,
				contributions: intVal(field(item, ['contributions']), 0),
				bot: false
			});
		}

		out.sort(function(a:GitHubContributor, b:GitHubContributor):Int
		{
			if (a.contributions != b.contributions) return a.contributions > b.contributions ? -1 : 1;
			return a.login.toLowerCase() < b.login.toLowerCase() ? -1 : 1;
		});

		if (out.length > MAX_CONTRIBUTORS) out = out.slice(0, MAX_CONTRIBUTORS);
		return out;
	}

	static function field(data:Dynamic, names:Array<String>):Dynamic
	{
		for (name in names)
		{
			var value:Dynamic = Reflect.field(data, name);
			if (value != null) return value;
		}
		return null;
	}

	static function str(value:Dynamic):String
	{
		if (value == null) return '';
		var text:String = Std.string(value);
		return text == 'null' ? '' : text;
	}

	static function intVal(value:Dynamic, fallback:Int):Int
	{
		if (value == null) return fallback;
		var parsed:Null<Int> = Std.parseInt(Std.string(value));
		return parsed == null ? fallback : parsed;
	}

	// ------------------------------------------------------------------ offline snapshot

	static function offline():Array<GitHubContributor>
	{
		if (offlineList != null) return offlineList;

		var list:Array<GitHubContributor> = [];
		try
		{
			var text:String = LimeAssets.getText(OFFLINE_ASSET);
			if (text != null && text.length > 0) list = normalize(Json.parse(text));
		}
		catch (e:Dynamic) {}

		if (list.length == 0) list = minimalOffline();
		offlineList = list;
		return offlineList;
	}

	/**
	 * Last-resort list if the JSON asset is missing (e.g. someone pruned assets). The real
	 * fallback is the asset; this only keeps the screen from showing an empty section.
	 */
	static function minimalOffline():Array<GitHubContributor>
	{
		return [
			{
				login: 'mohong2',
				name: 'mo_hong',
				id: 150683765,
				avatarUrl: 'https://avatars.githubusercontent.com/u/150683765?v=4',
				profileUrl: 'https://github.com/mohong2',
				contributions: 276,
				bot: false
			},
			{
				login: 'azmlpoh',
				name: 'azmlpoh',
				id: 178987150,
				avatarUrl: 'https://avatars.githubusercontent.com/u/178987150?v=4',
				profileUrl: 'https://github.com/azmlpoh',
				contributions: 2,
				bot: false
			}
		];
	}

	// ------------------------------------------------------------------ disk cache

	#if sys
	static function cacheDir():String
	{
		if (resolvedCacheDir != null) return resolvedCacheDir;

		var dir:String = 'credits/';
		try
		{
			var root:String = SUtil.getStorageDirectory();
			if (root != null && root.length > 0)
				dir = haxe.io.Path.addTrailingSlash(root) + 'credits/';
			if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		}
		catch (e:Dynamic) {}
		resolvedCacheDir = dir;
		return resolvedCacheDir;
	}

	static function readApiCache():Array<GitHubContributor>
	{
		try
		{
			var path:String = cacheDir() + API_CACHE_FILE;
			if (!FileSystem.exists(path)) return null;
			var raw:Dynamic = Json.parse(File.getContent(path));
			var list:Array<GitHubContributor> = normalize(raw);
			return list.length > 0 ? list : null;
		}
		catch (e:Dynamic) {}
		return null;
	}

	static function writeApiCache(list:Array<GitHubContributor>):Void
	{
		try
		{
			var path:String = cacheDir() + API_CACHE_FILE;
			var payload:Dynamic = {
				fetchedAt: Date.now().getTime(),
				repository: GitHubAPI.OWNER + '/' + GitHubAPI.REPO,
				contributors: [for (c in list) {
					login: c.login,
					name: c.name,
					id: c.id,
					avatarUrl: c.avatarUrl,
					profileUrl: c.profileUrl,
					contributions: c.contributions
				}]
			};
			File.saveContent(path, Json.stringify(payload));
		}
		catch (e:Dynamic) {}
	}

	static function avatarKey(contributor:GitHubContributor):String
	{
		if (contributor.id > 0) return Std.string(contributor.id);
		return sanitize(contributor.login);
	}

	static function sanitize(value:String):String
	{
		if (value == null) return 'unknown';
		var out:String = '';
		for (i in 0...value.length)
		{
			var code:Int = value.charCodeAt(i);
			var ok:Bool = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 45 || code == 95;
			out += ok ? value.charAt(i) : '_';
		}
		return out.length > 0 ? out : 'unknown';
	}

	static function avatarPath(contributor:GitHubContributor):String
	{
		return cacheDir() + 'avatars/' + avatarKey(contributor) + '.png';
	}

	static function ensureAvatarDir():Void
	{
		var dir:String = cacheDir() + 'avatars/';
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
	}

	static function readAvatarCache(contributor:GitHubContributor):Bytes
	{
		try
		{
			var path:String = avatarPath(contributor);
			if (!FileSystem.exists(path)) return null;
			return File.getBytes(path);
		}
		catch (e:Dynamic) {}
		return null;
	}

	static function avatarCacheFresh(contributor:GitHubContributor):Bool
	{
		try
		{
			var path:String = avatarPath(contributor);
			if (!FileSystem.exists(path)) return false;
			var age:Float = Date.now().getTime() - FileSystem.stat(path).mtime.getTime();
			return age >= 0 && age < AVATAR_TTL_MS;
		}
		catch (e:Dynamic) {}
		return false;
	}

	static function writeAvatarCache(contributor:GitHubContributor, bytes:Bytes):Void
	{
		try
		{
			ensureAvatarDir();
			File.saveBytes(avatarPath(contributor), bytes);
		}
		catch (e:Dynamic) {}
	}
	#else
	static function readApiCache():Array<GitHubContributor> return null;
	static function writeApiCache(list:Array<GitHubContributor>):Void {}
	static function avatarCacheFresh(contributor:GitHubContributor):Bool return false;
	static function readAvatarCache(contributor:GitHubContributor):Bytes return null;
	static function writeAvatarCache(contributor:GitHubContributor, bytes:Bytes):Void {}
	#end

	static function sizedAvatarUrl(url:String):String
	{
		if (url == null || url.length == 0) return '';
		if (url.indexOf('s=') >= 0) return url;
		var separator:String = url.indexOf('?') >= 0 ? '&' : '?';
		return url + separator + 's=' + AVATAR_SIZE;
	}
}
