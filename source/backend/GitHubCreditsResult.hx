package backend;

/** Result of one contributor load attempt; the callback may fire twice (cache, then live). */
typedef GitHubCreditsResult = {
	var contributors:Array<GitHubContributor>;
	var online:Bool;
	var fromCache:Bool;
	var error:String;
}
