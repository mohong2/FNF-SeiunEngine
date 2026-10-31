package backend;

/**
 * One GitHub contributor, normalized across the REST payload and the offline snapshot.
 * Optional profile fields are plain strings (empty instead of null) so callers never
 * have to nil-check every column.
 */
typedef GitHubContributor = {
	var login:String;
	var name:String;
	var id:Int;
	var avatarUrl:String;
	var profileUrl:String;
	var contributions:Int;
	var bot:Bool;
}
