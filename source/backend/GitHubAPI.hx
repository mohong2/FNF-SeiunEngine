package backend;

import haxe.Json;
import haxe.io.Bytes;
import lime.net.HTTPRequest;
import lime.net.HTTPRequestHeader;

/**
 * Thin GitHub REST v3 client.
 *
 * Kept deliberately boring: one `call` for JSON, one `downloadBytes` for avatars and
 * release assets, and one place that records the X-RateLimit-* headers. Callers decide
 * what to do with a failure; this class never retries, caches or logs a token.
 *
 * The repository constants are the project's own; anything that needs another repo
 * passes owner/repo explicitly. Unauthenticated GitHub allows 60 requests per hour per
 * IP, so callers that run on a menu open should cache (see backend.GitHubCredits) and
 * check `rateLimitRemaining` before assuming a 403 is a real error.
 */
class GitHubAPI
{
	public static inline var API_URL:String = "https://api.github.com";
	public static inline var OWNER:String = "mohong2";
	public static inline var REPO:String = "FNF-SeiunEngine";
	public static inline var USER_AGENT:String = "SeiunEngine";
	public static inline var API_VERSION:String = "2022-11-28";

	/** Optional personal access token; also picked up from SEIUN_GITHUB_TOKEN / GITHUB_TOKEN. */
	public static var token:String = "";

	/** X-RateLimit-Limit from the last response, -1 until one arrives. */
	public static var rateLimitLimit:Int = -1;
	/** X-RateLimit-Remaining from the last response, -1 until one arrives. */
	public static var rateLimitRemaining:Int = -1;
	/** X-RateLimit-Reset (epoch seconds) from the last response, -1 until one arrives. */
	public static var rateLimitReset:Int = -1;
	/** HTTP status of the last call/download, 0 before the first response. */
	public static var lastStatus:Int = 0;

	static var tokenChecked:Bool = false;

	/**
	 * One JSON request. `onData` receives the parsed body (null for 204/304 or an empty
	 * body); `onError` receives a human-readable "HTTP 403: ..." string.
	 */
	public static function call(method:String, path:String, ?query:Map<String, String>, ?body:Dynamic, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		var req:HTTPRequest<String> = new HTTPRequest<String>(buildUrl(path, query));
		req.method = method;
		req.timeout = 15000;
		req.userAgent = USER_AGENT;
		req.contentType = "application/json";
		req.enableResponseHeaders = true;
		req.headers.push(new HTTPRequestHeader("Accept", "application/vnd.github+json"));
		req.headers.push(new HTTPRequestHeader("X-GitHub-Api-Version", API_VERSION));

		ensureToken();
		if (token != null && token.length > 0)
			req.headers.push(new HTTPRequestHeader("Authorization", "Bearer " + token));

		if (body != null)
			req.data = Bytes.ofString(Json.stringify(body));

		req.load().onComplete(function(text:String)
		{
			lastStatus = req.responseStatus;
			readHeaders(req.responseHeaders);

			if (lastStatus >= 200 && lastStatus < 300)
			{
				var data:Dynamic = null;
				if (text != null && text.length > 0)
				{
					try
					{
						data = Json.parse(text);
					}
					catch (e:Dynamic)
					{
						if (onError != null) onError("Invalid JSON response");
						return;
					}
				}
				if (onData != null) onData(data);
			}
			else if (lastStatus == 304)
			{
				// Conditional request: not modified, the cached body is still current.
				if (onData != null) onData(null);
			}
			else
			{
				if (onError != null) onError(errorText(lastStatus, text));
			}
		}).onError(function(error:Dynamic)
		{
			if (onError != null) onError(Std.string(error));
		});
	}

	/**
	 * Fetch raw bytes (GitHub avatars, release assets, README images). No Authorization
	 * header: the usual target is avatars.githubusercontent.com, and a token must never
	 * be forwarded there.
	 */
	public static function downloadBytes(url:String, ?onData:Bytes->Void, ?onError:String->Void, ?timeout:Int = 20000):Void
	{
		if (url == null || url.length == 0)
		{
			if (onError != null) onError("Empty URL");
			return;
		}

		var req:HTTPRequest<Bytes> = new HTTPRequest<Bytes>(url);
		req.timeout = timeout;
		req.userAgent = USER_AGENT;
		req.enableResponseHeaders = true;
		req.headers.push(new HTTPRequestHeader("Accept", "image/*,*/*;q=0.8"));

		req.load().onComplete(function(bytes:Bytes)
		{
			lastStatus = req.responseStatus;
			readHeaders(req.responseHeaders);

			if (lastStatus >= 200 && lastStatus < 300 && bytes != null && bytes.length > 0)
			{
				if (onData != null) onData(bytes);
			}
			else if (onError != null)
			{
				onError("HTTP " + lastStatus + " (" + (bytes == null ? 0 : bytes.length) + " bytes)");
			}
		}).onError(function(error:Dynamic)
		{
			if (onError != null) onError(Std.string(error));
		});
	}

	static function buildUrl(path:String, ?query:Map<String, String>):String
	{
		var url:String = API_URL + (path.length > 0 && path.charAt(0) != "/" ? "/" : "") + path;
		if (query != null && query.keys().hasNext())
		{
			var parts:Array<String> = [];
			for (key in query.keys())
			{
				var value:String = query.get(key);
				if (value != null)
					parts.push(StringTools.urlEncode(key) + "=" + StringTools.urlEncode(value));
			}
			if (parts.length > 0)
				url += "?" + parts.join("&");
		}
		return url;
	}

	/** Prefer an explicit token, then the usual environment variables (desktop only). */
	static function ensureToken():Void
	{
		if (tokenChecked) return;
		tokenChecked = true;
		if (token != null && token.length > 0) return;

		#if sys
		var value:String = Sys.getEnv("SEIUN_GITHUB_TOKEN");
		if (value == null || StringTools.trim(value).length == 0)
			value = Sys.getEnv("GITHUB_TOKEN");
		if (value != null)
		{
			value = StringTools.trim(value);
			if (value.length > 0) token = value;
		}
		#end
	}

	static function readHeaders(headers:Array<HTTPRequestHeader>):Void
	{
		if (headers == null) return;
		for (header in headers)
		{
			if (header == null || header.name == null) continue;
			switch (header.name.toLowerCase())
			{
				case "x-ratelimit-limit":
					rateLimitLimit = parseInt(header.value, rateLimitLimit);
				case "x-ratelimit-remaining":
					rateLimitRemaining = parseInt(header.value, rateLimitRemaining);
				case "x-ratelimit-reset":
					rateLimitReset = parseInt(header.value, rateLimitReset);
				default:
			}
		}
	}

	static function parseInt(value:String, fallback:Int):Int
	{
		var parsed:Null<Int> = Std.parseInt(value);
		return parsed == null ? fallback : parsed;
	}

	static function errorText(status:Int, text:String):String
	{
		var message:String = "";
		if (text != null && text.length > 0)
		{
			try
			{
				var parsed:Dynamic = Json.parse(text);
				var detail:Dynamic = Reflect.field(parsed, "message");
				if (detail != null) message = Std.string(detail);
			}
			catch (e:Dynamic) {}

			if (message.length == 0)
				message = text.length > 240 ? text.substr(0, 240) + "..." : text;
		}

		if ((status == 403 || status == 429) && rateLimitRemaining == 0)
		{
			message += " (rate limit exhausted";
			if (rateLimitReset > 0)
				message += "; resets at " + Date.fromTime(rateLimitReset * 1000.0).toString();
			message += ")";
		}
		return "HTTP " + status + (message.length > 0 ? ": " + message : "");
	}

	// ------------------------------------------------------------------ repository

	public static function getRepository(owner:String = OWNER, repo:String = REPO, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo, null, null, onData, onError);
	}

	public static function getRepoReadme(owner:String = OWNER, repo:String = REPO, ?ref:String = null, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		var query:Map<String, String> = null;
		if (ref != null && ref.length > 0) query = ["ref" => ref];
		call("GET", "/repos/" + owner + "/" + repo + "/readme", query, null, onData, onError);
	}

	public static function getRepoTopics(owner:String = OWNER, repo:String = REPO, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/topics", null, null, onData, onError);
	}

	public static function getRepoLicense(owner:String = OWNER, repo:String = REPO, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/license", null, null, onData, onError);
	}

	public static function getRepoForks(owner:String = OWNER, repo:String = REPO, ?perPage:Int = 30, ?page:Int = 1, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/forks", ["per_page" => Std.string(perPage), "page" => Std.string(page), "sort" => "newest"], null,
			onData, onError);
	}

	public static function getRepoLanguages(owner:String = OWNER, repo:String = REPO, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/languages", null, null, onData, onError);
	}

	public static function getRepoEvents(owner:String = OWNER, repo:String = REPO, ?perPage:Int = 30, ?page:Int = 1, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/events", ["per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	// ------------------------------------------------------------------ contributors / users

	public static function getContributors(owner:String = OWNER, repo:String = REPO, ?perPage:Int = 30, ?page:Int = 1, ?onData:Dynamic->Void,
			?onError:String->Void, ?anon:Bool = false):Void
	{
		var query:Map<String, String> = ["per_page" => Std.string(perPage), "page" => Std.string(page)];
		if (anon) query.set("anon", "1");
		call("GET", "/repos/" + owner + "/" + repo + "/contributors", query, null, onData, onError);
	}

	/**
	 * /stats/contributors. GitHub computes this lazily: the first request can answer 202
	 * with an empty body and the caller should retry later (the cached disk copy exists
	 * for exactly that case).
	 */
	public static function getContributorStats(owner:String = OWNER, repo:String = REPO, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/stats/contributors", null, null, onData, onError);
	}

	public static function getUser(username:String, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/users/" + username, null, null, onData, onError);
	}

	/** The token's own account; requires a token, answers 401 otherwise. */
	public static function getAuthenticatedUser(?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/user", null, null, onData, onError);
	}

	public static function getUserRepos(username:String, ?perPage:Int = 30, ?page:Int = 1, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/users/" + username + "/repos", ["per_page" => Std.string(perPage), "page" => Std.string(page), "sort" => "updated"], null, onData,
			onError);
	}

	public static function getUserOrgs(username:String, ?perPage:Int = 30, ?page:Int = 1, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/users/" + username + "/orgs", ["per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	// ------------------------------------------------------------------ releases / tags

	public static function getLatestRelease(owner:String = OWNER, repo:String = REPO, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/releases/latest", null, null, onData, onError);
	}

	public static function getReleases(owner:String = OWNER, repo:String = REPO, ?perPage:Int = 100, ?page:Int = 1, ?onData:Dynamic->Void,
			?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/releases", ["per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	public static function getReleaseByTag(owner:String = OWNER, repo:String = REPO, tag:String, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/releases/tags/" + tag, null, null, onData, onError);
	}

	/** Assets attached to one release (id is the numeric release id, not the tag). */
	public static function getReleaseAssets(owner:String = OWNER, repo:String = REPO, releaseId:Int, ?perPage:Int = 100, ?page:Int = 1,
			?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/releases/" + releaseId + "/assets",
			["per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	public static function getReleaseAsset(owner:String = OWNER, repo:String = REPO, assetId:Int, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/releases/assets/" + assetId, null, null, onData, onError);
	}

	public static function getTags(owner:String = OWNER, repo:String = REPO, ?perPage:Int = 100, ?page:Int = 1, ?onData:Dynamic->Void,
			?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/tags", ["per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	public static function getBranches(owner:String = OWNER, repo:String = REPO, ?perPage:Int = 100, ?page:Int = 1, ?onData:Dynamic->Void,
			?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/branches", ["per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	// ------------------------------------------------------------------ commits / contents

	public static function getCommits(owner:String = OWNER, repo:String = REPO, ?branch:String = null, ?perPage:Int = 30, ?page:Int = 1,
			?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		var query:Map<String, String> = ["per_page" => Std.string(perPage), "page" => Std.string(page)];
		if (branch != null && branch.length > 0) query.set("sha", branch);
		call("GET", "/repos/" + owner + "/" + repo + "/commits", query, null, onData, onError);
	}

	public static function getCommit(owner:String = OWNER, repo:String = REPO, ref:String, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/commits/" + ref, null, null, onData, onError);
	}

	public static function compareCommits(owner:String = OWNER, repo:String = REPO, base:String, head:String, ?onData:Dynamic->Void,
			?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/compare/" + base + "..." + head, null, null, onData, onError);
	}

	public static function getContents(owner:String = OWNER, repo:String = REPO, path:String = "", ?ref:String = null, ?onData:Dynamic->Void,
			?onError:String->Void):Void
	{
		var query:Map<String, String> = null;
		if (ref != null && ref.length > 0) query = ["ref" => ref];
		call("GET", "/repos/" + owner + "/" + repo + "/contents/" + path, query, null, onData, onError);
	}

	// ------------------------------------------------------------------ issues / pull requests

	public static function getIssues(owner:String = OWNER, repo:String = REPO, ?state:String = "open", ?perPage:Int = 30, ?page:Int = 1,
			?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/issues",
			["state" => state, "per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	public static function getIssue(owner:String = OWNER, repo:String = REPO, number:Int, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/issues/" + number, null, null, onData, onError);
	}

	public static function getPullRequests(owner:String = OWNER, repo:String = REPO, ?state:String = "open", ?perPage:Int = 30, ?page:Int = 1,
			?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/pulls",
			["state" => state, "per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	public static function getIssueComments(owner:String = OWNER, repo:String = REPO, number:Int, ?perPage:Int = 30, ?page:Int = 1,
			?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/repos/" + owner + "/" + repo + "/issues/" + number + "/comments",
			["per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	public static function createIssue(owner:String = OWNER, repo:String = REPO, title:String, body:String = "", ?labels:Array<String> = null,
			?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		var payload:Dynamic = {title: title, body: body};
		if (labels != null && labels.length > 0) payload.labels = labels;
		call("POST", "/repos/" + owner + "/" + repo + "/issues", null, payload, onData, onError);
	}

	public static function createIssueComment(owner:String = OWNER, repo:String = REPO, number:Int, body:String, ?onData:Dynamic->Void,
			?onError:String->Void):Void
	{
		call("POST", "/repos/" + owner + "/" + repo + "/issues/" + number + "/comments", null, {body: body}, onData, onError);
	}

	public static function updateIssue(owner:String = OWNER, repo:String = REPO, number:Int, ?title:String = null, ?body:String = null,
			?state:String = null, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		var payload:Dynamic = {};
		if (title != null) payload.title = title;
		if (body != null) payload.body = body;
		if (state != null) payload.state = state;
		call("PATCH", "/repos/" + owner + "/" + repo + "/issues/" + number, null, payload, onData, onError);
	}

	// ------------------------------------------------------------------ search / rate limit

	public static function getRateLimit(?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/rate_limit", null, null, onData, onError);
	}

	public static function searchRepositories(query:String, ?perPage:Int = 30, ?page:Int = 1, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/search/repositories", ["q" => query, "per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	public static function searchUsers(query:String, ?perPage:Int = 30, ?page:Int = 1, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/search/users", ["q" => query, "per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	public static function searchIssues(query:String, ?perPage:Int = 30, ?page:Int = 1, ?onData:Dynamic->Void, ?onError:String->Void):Void
	{
		call("GET", "/search/issues", ["q" => query, "per_page" => Std.string(perPage), "page" => Std.string(page)], null, onData, onError);
	}

	// ------------------------------------------------------------------ version helpers

	public static function normalizeVersion(version:String):String
	{
		var v:String = StringTools.trim(version);
		if (v.length > 0 && (v.charAt(0) == "v" || v.charAt(0) == "V"))
			v = v.substr(1);
		return v;
	}

	public static function compareVersions(a:String, b:String):Int
	{
		var pa = parseVersion(a);
		var pb = parseVersion(b);

		if (pa.major != pb.major) return pa.major < pb.major ? -1 : 1;
		if (pa.minor != pb.minor) return pa.minor < pb.minor ? -1 : 1;
		if (pa.patch != pb.patch) return pa.patch < pb.patch ? -1 : 1;

		if (pa.pre.length == 0 && pb.pre.length == 0) return 0;
		if (pa.pre.length == 0) return 1;
		if (pb.pre.length == 0) return -1;
		return comparePre(pa.pre, pb.pre);
	}

	static function parseVersion(version:String):{major:Int, minor:Int, patch:Int, pre:Array<String>}
	{
		var v:String = normalizeVersion(version);
		var plus:Int = v.indexOf("+");
		if (plus >= 0) v = v.substr(0, plus);

		var pre:Array<String> = [];
		var dash:Int = v.indexOf("-");
		if (dash >= 0)
		{
			pre = v.substr(dash + 1).split(".");
			v = v.substr(0, dash);
		}

		var parts:Array<String> = v.split(".");
		return {
			major: parts.length > 0 ? parseNum(parts[0]) : 0,
			minor: parts.length > 1 ? parseNum(parts[1]) : 0,
			patch: parts.length > 2 ? parseNum(parts[2]) : 0,
			pre: pre
		};
	}

	static function parseNum(s:String):Int
	{
		var n:Null<Int> = Std.parseInt(s);
		return n == null ? 0 : n;
	}

	static function comparePre(a:Array<String>, b:Array<String>):Int
	{
		var len:Int = a.length > b.length ? a.length : b.length;
		for (i in 0...len)
		{
			if (i >= a.length) return -1;
			if (i >= b.length) return 1;

			var an:Bool = isNumeric(a[i]);
			var bn:Bool = isNumeric(b[i]);

			if (an && bn)
			{
				var d:Int = parseNum(a[i]) - parseNum(b[i]);
				if (d != 0) return d < 0 ? -1 : 1;
			}
			else if (an)
				return -1;
			else if (bn)
				return 1;
			else
			{
				if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
			}
		}
		return 0;
	}

	static function isNumeric(s:String):Bool
	{
		return ~/^[0-9]+$/.match(s);
	}
}
