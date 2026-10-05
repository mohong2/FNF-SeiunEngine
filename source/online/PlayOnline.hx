package online;

#if ONLINE_ALLOWED

import Section.SwagSection;
import android.flixel.FlxVirtualPad.FlxActionMode;
import android.flixel.FlxVirtualPad.FlxDPadMode;
import substates.OldPauseSubState;
import substates.PauseSubState;
import Song.SwagSong;
import backend.Scripts;
import flixel.util.FlxStringUtil;
import popup.RatingPopup;
import script.lua.FunkinLua;
import states.PlayState;
import states.PlayState.PlayStatePlayer;

@:access(states.PlayState)
@:allow(states.PlayState)
class PlayOnline {
	/** 本对象所属的状态 (每个 PlayState 一个)。 */
	public var ps(default, null):states.PlayState;

	public function new(ps:states.PlayState) {
		this.ps = ps;
	}

		public static function loadSong(jsonInput:String, ?folder:String):SwagSong {
			// Large charts go through Song.loadFromJson's byte-stream path (same route as FreeplayState).
			// RAW_SONG stays empty for them: this is the only writer in the tree and nothing reads it
			// for streamed charts.
			var loaded:SwagSong = Song.loadFromJson(jsonInput, folder);
			PlayState.RAW_SONG = (loaded != null && Reflect.field(loaded, '__seiunStream') != null)
				? '' : Song.loadRawSong(jsonInput, folder);
			return PlayState.SONG = loaded;
		}


		/**
			 * Tells whether the chart's player side is BF. Who needs it:
			 * online.ChartAnalyzer.calc(songData, mustPress) is always called with
			 * playsAsBF() as the second argument, so the analyzer can tell "this chart's player side is
			 * the dad side" (online room / opponent mode) from "player side is BF".
			 *
			 * This engine has no `opponentMode` member; its equivalent switch is `playOpponent` (this
			 * file, instance field, filled from the 'playOpponent' gameplay setting) -- it drives the
			 * very same note-side flip in its own note loader. `instance` is null outside a song
			 * (main menu, chart editor, results), where "the player is BF" is the correct answer anyway.
			 *
			 * GameClient.room.state.{royalMode,royalModeDadSide} and GameClient.getPlayerSelf().bfSide are
			 * the online schema fields (online/backend/schema/{Room,Player}.hx), so the online
			 * branch keeps the online behavior.
		 *
		 * `GameClient.room.state.{royalMode,royalModeDadSide}` and `GameClient.getPlayerSelf().bfSide` are
		 * the online schema fields (online/backend/schema/{Room,Player}.hx), so the online
		 * branch keeps the online behavior.
		 */
		public static function playsAsBF():Bool {
			if (online.GameClient.isConnected()) {
				if (online.GameClient.room.state.royalMode) {
					return !online.GameClient.room.state.royalModeDadSide;
				}

				var playerSelf = online.GameClient.getPlayerSelf();
				if (playerSelf != null) {
					return playerSelf.bfSide;
				}
			}
			if (PlayState.instance != null) return !PlayState.instance.playOpponent;
			return true;
		}


		/**
			 * Resolves whether a raw note belongs to the player side, using the chart convention
			 * described below.
		 *
		 * The chart convention is chosen from `PlayState.SONG.format`
		 * (`rawNote[1] < Note.maniaKeys`) and the legacy convention
		 * (`rawNote[1] > Note.maniaKeys - 1` -> flip against `section.mustHitSection`).
		 *
		 * Decisive difference in THIS engine: `Song.loadFromJson()` normalises every chart through
		 * `Song.convert()`, which already rewrites every raw note index into the psych_v1 convention --
		 * for ALL formats, unconditionally:
		 *     var gottaHitNote:Bool = (rawData < ammo) ? section.mustHitSection : !section.mustHitSection;
		 *     note[1] = (rawData % ammo) + (gottaHitNote ? 0 : ammo);
		 * (source/Song.hx, `convert()`, lines ~444-465). The engine's own note loader then decides sides
		 * two-branch `isPsychRelease` test here is just the psych_v1 branch -- keeping the `format`
		 * branch would make the analyzer disagree with the engine's own loader for the legacy charts
		 * that convert() has already re-encoded.
		 *
		 * It is also per-note mania aware (`EKData.maniaAtTimeCached`), mirroring generateSong, so a
		 * "Change Mania" event mid-chart is interpreted with the same key count in both places.
		 * This per-mania model difference also applies to the analyzer.
		 */
		public static function getMustPressFromRaw(section:SwagSection, rawNote:Array<Dynamic>):Bool {
			var rawData:Int = Std.int(rawNote[1]);
			var noteMania:Int = EKData.maniaAtTimeCached(rawNote[0]);
			var noteAmmo:Int = Note.ammo[noteMania];
			return rawData < noteAmmo;
		}


		/**
			 * Formats the FP readout from `songPoints`; called from `buildScoreText()`'s FP
			 * readout. Lives in the same ONLINE_ALLOWED class-level block as `difficultyInfo`.
		 * readout. Lives in the same ONLINE_ALLOWED class-level block as `difficultyInfo`.
		 */
		function getPresencePoints():String {
			if (ps.songPoints == 0)
				return "";

			if (ps.songPoints < 0) {
				var aasss = '${ps.songPoints}'.split('');
				aasss.insert(1, ' ');
				return ' - ${aasss.join('')}FP';
			}

			return ' - ${ps.songPoints}FP';
		}


		/** Per-player score text update. */
		public function updateScoreSelf(?miss:Bool = false):Void {
			ps.RecalculateRating(miss);
			if (online.GameClient.isConnected()) {
				ps.updateScoreSID(online.GameClient.room.sessionId);
			}
		}


		/** Team-wide score text update (isRight, miss). */
		public function updateTeamSide(isRight:Bool, miss:Bool):Void {
			var sideNames:Array<String> = [];
			var sideScores:Array<Float> = [];
			var sideMisses:Array<Float> = [];
			var sideAccuracy:Array<Float> = [];
			var sidePing:Array<Float> = [];
			var sideFP:Array<Float> = [];

			for (sid => player in online.GameClient.room.state.players) {
				if (player.bfSide == isRight) {
					var stats = ps.getPlayerStats(sid);

					var ret:Dynamic = ps.callOnScripts('onRecalculateRatingPlayer', Scripts.fill1(Scripts.get(1), sid), true);
					if (ret != FunkinLua.Function_Stop) {
						stats.recalculateRating();
					}

					sideNames.push(player.name);
					sideScores.push(player.score);
					sideMisses.push(player.misses);
					sideAccuracy.push(stats.ratingPercent * 100);
					sidePing.push(player.ping);
					if (ClientPrefs.data.showFP) {
						sideFP.push(player.songPoints);
					}
				}
			}

			if (sideNames.length == 0)
				return;

			var daText = ps.scoreTxtOthers.get(isRight ? 'RIGHTSIDE' : 'LEFTSIDE');

			var pingText = ps.onlinePingList(sidePing);

			if (ClientPrefs.data.onlineScoreDetails) {
				daText.text = ps.onlineDetailScore(sideNames.join(' & '), [
					['scorelangtxt', 'Score', FlxStringUtil.formatMoney(ps.averageOf(sideScores), false)],
					['missesText', 'Misses', Std.string(ps.averageOf(sideMisses))],
					['acclangtxt', 'Accuracy', CoolUtil.floorDecimal(ps.averageOf(sideAccuracy), 2) + '%']
				], ClientPrefs.data.showFP ? ps.averageOf(sideFP) : null, pingText);
			}
			else {
				daText.text = ps.onlineCompactScore(sideNames.join(' & '), ps.averageOf(sideScores), ps.averageOf(sideMisses),
					Std.string(CoolUtil.floorDecimal(ps.averageOf(sideAccuracy), 2)), null,
					ClientPrefs.data.showFP ? ps.averageOf(sideFP) : null, pingText);
			}

			daText.y = ps.scoreTxtOriginY - daText.height;

			if (!miss) {
				ps.doTweenScore(isRight ? 'RIGHTSIDE' : 'LEFTSIDE', isRight);
			}

			ps.callOnScripts('onUpdateScoreTeam', Scripts.fill2(Scripts.get(2), isRight, miss));
		}


		function averageOf(arr:Array<Float>):Float {
			if (arr.length == 0)
				return 0;
			var sum = 0.0;
			for (item in arr)
				sum += item;
			if (sum == 0)
				return 0;
			return sum / arr.length;
		}


		/*
		 * The online score HUD is localised and Ping is rounded. Labels reuse the engine's
		 * own keys where they exist (scorelangtxt / missesText / acclangtxt); only Rating
		 * (ScoreHistorySubstate.rating) and Ping (Online.room.ping) come from shared keys.
		 * The compact one-liner is the default form; ClientPrefs.onlineScoreDetails restores the
		 * multi-line block. Text only -- no layout math changes.
		 */
		function onlineScoreLabel(key:String, fallback:String):String {
			var s = StringTools.trim(Language.get(key, fallback));
			if (StringTools.endsWith(s, ':') || StringTools.endsWith(s, '：'))
				s = StringTools.trim(s.substr(0, s.length - 1));
			return s;
		}


		function onlinePingMs(ping:Null<Float>):String {
			if (ping == null || ping != ping)
				return '?ms';
			return Math.round(ping) + 'ms';
		}


		function onlinePingList(pings:Array<Float>):String {
			var out:Array<String> = [];
			for (p in pings)
				out.push(ps.onlinePingMs(p));
			return out.join(' & ');
		}


		function onlineCompactScore(name:String, score:Float, misses:Float, percent:String, ratingFC:String, fp:Null<Float>, pingText:String):String {
			var out = name + ': ' + FlxStringUtil.formatMoney(score, false)
				+ ' | ' + ps.onlineScoreLabel('missesText', 'Misses') + ': ' + misses
				+ ' | ' + percent + '%';
			if (ratingFC != null && ratingFC != '')
				out += ' - ' + ratingFC;
			if (ClientPrefs.data.showFP && fp != null)
				out += ' | ' + Math.round(fp) + 'FP';
			return out + ' | ' + ps.onlineScoreLabel('Online.room.ping', 'Ping') + ': ' + pingText;
		}


		function onlineDetailScore(name:String, lines:Array<Array<String>>, fp:Null<Float>, pingText:String):String {
			var out = name;
			for (line in lines)
				out += '\n' + ps.onlineScoreLabel(line[0], line[1]) + ': ' + line[2];
			if (ClientPrefs.data.showFP && fp != null)
				out += '\nFP: ' + Math.round(fp);
			return out + '\n' + ps.onlineScoreLabel('Online.room.ping', 'Ping') + ': ' + pingText;
		}


		/** Per-sid score text update. */
		public function updateScoreSID(sid:String, ?miss:Bool = false):Void {
			var op = ps.getPlayerStats(sid);

			if (online.GameClient.room.state.teamMode) {
				ps.updateTeamSide(op.player.bfSide, miss);
				return;
			}

			ps.setOnScripts('scoreOP', op.player.score);
			ps.setOnScripts('missesOP', op.player.misses);
			ps.setOnScripts('hitsOP', op.calcHits()); // may be inaccurate to hits
			ps.setOnScripts('comboOP', op.combo);

			var ret:Dynamic = ps.callOnScripts('onRecalculateRatingPlayer', Scripts.fill1(Scripts.get(1), sid), true);
			if (ret != FunkinLua.Function_Stop) {
				op.recalculateRating();
			}

			var str:String = op.ratingName != null ? op.ratingName : '?';
			var percent:Float = 0;
			if (op.calcTotalPlayed() != 0) {
				percent = CoolUtil.floorDecimal(op.ratingPercent * 100, 2);
				str += ' ($percent%) - ${op.ratingFC}';
			}

			var countSide = 0;
			for (otherSid => otherPlayer in online.GameClient.room.state.players) {
				if (otherPlayer.bfSide == op.player.bfSide) {
					countSide++;
				}
			}

			var daText = ps.scoreTxtOthers.get(sid);

			var pingText = ps.onlinePingMs(op.player.ping);

			if (ClientPrefs.data.onlineScoreDetails && countSide <= 1) {
				daText.text = ps.onlineDetailScore(op.player.name, [
					['scorelangtxt', 'Score', FlxStringUtil.formatMoney(op.player.score, false)],
					['missesText', 'Misses', Std.string(op.player.misses)],
					['ScoreHistorySubstate.rating', 'Rating', str]
				], ClientPrefs.data.showFP ? op.player.songPoints : null, pingText);
			}
			else {
				daText.text = ps.onlineCompactScore(op.player.name, op.player.score, op.player.misses, Std.string(percent), op.ratingFC,
					ClientPrefs.data.showFP ? op.player.songPoints : null, pingText);
			}

			daText.y = ps.scoreTxtOriginY - (ps.effectiveOx(sid) * 20) - daText.height;

			if (!miss) {
				ps.doTweenScore(sid);
			}

			ps.setOnScripts('ratingOP', op.ratingPercent);
			ps.setOnScripts('ratingNameOP', op.ratingName);
			ps.setOnScripts('ratingFCOP', op.ratingFC);

			ps.callOnScripts('onUpdateScorePlayer', Scripts.fill2(Scripts.get(2), sid, miss));
		}


		function doTweenScore(sid:String, ?isRight:Null<Bool> = null):Void {
			if (isRight != null) {
				sid = isRight ? 'RIGHTSIDE' : 'LEFTSIDE';
			}

			if (ClientPrefs.data.scoreZoom) {
				if (ps.scoreTxtOthersTween.exists(sid)) {
					ps.scoreTxtOthersTween.get(sid).cancel();
				}

				var text = ps.scoreTxtOthers.get(sid);
				text.scale.x = 1.025;
				text.scale.y = 1.025;

				ps.scoreTxtOthersTween.set(sid, FlxTween.tween(text.scale, {x: 1, y: 1}, 0.2, {
					onComplete: function(twn:FlxTween) {
						ps.scoreTxtOthersTween.remove(sid);
					}
				}));
			}
		}


		/**
		 * Vertical row number for per-sid texts (two clients' F7 FP texts overlapped).
		 *
		 * The position should come from the server's `Player.ox`, but the server does not always
		 * provide a usable ox, and then the two same-side rows both landed on the same y. This adds
		 * a client-side fallback: use the server value when ox > 0, otherwise give a stable row
		 * number from the player's insertion order on that side (MapSchema preserves it).
		 */
		function effectiveOx(sid:String):Int {
			if (!online.GameClient.isConnected() || online.GameClient.room == null)
				return 0;

			var player = online.GameClient.room.state.players.get(sid);
			if (player == null)
				return 0;
			if (player.ox > 0)
				return Std.int(player.ox);

			var index:Int = 0;
			for (otherSid => other in online.GameClient.room.state.players) {
				if (other == null)
					continue;
				if (other.bfSide == player.bfSide) {
					if (otherSid == sid)
						return index;
					index++;
				}
			}
			return 0;
		}


		function getPlayerStats(sid:String):PlayStatePlayer {
			if (!ps.playersStats.exists(sid))
				ps.playersStats.set(sid, new PlayStatePlayer(online.GameClient.room.state.players.get(sid)));

			return ps.playersStats.get(sid);
		}


		/** Player strum group. */
		public function getPlayerStrums():FlxTypedGroup<StrumNote> {
			// Online returns this engine's own mustPress meaning: the note update uses
			// strumGroup = daNote.mustPress ? playerStrums : opponentStrums, so mustPress notes always
			// live in playerStrums. The playsAsBF() meaning matches only while mustPress is
			// BF-relative; online, a dad-side player (bfSide=false) is misread as opponentStrums, so its strumPlay animation plays on the wrong side.
			if (online.GameClient.isConnected())
				return ps.playerStrums;

			if (PlayState.playsAsBF())
				return ps.playerStrums;
			return ps.opponentStrums;
		}


		/** Opponent strum group. */
		public function getOpponentStrums():FlxTypedGroup<StrumNote> {
			if (online.GameClient.isConnected())
				return ps.opponentStrums;

			if (PlayState.playsAsBF())
				return ps.opponentStrums;
			return ps.playerStrums;
		}


		/** Strum group of the given sid, or null when the sid has no character. */
		public function getStrumsFromSID(sid:String):FlxTypedGroup<StrumNote> {
			if (online.GameClient.isConnected() && online.GameClient.room.state.royalMode) {
				return online.GameClient.room.state.royalModeDadSide ? ps.opponentStrums : ps.playerStrums;
			}

			var char = ps.characters.get(sid);
			if (char != null && char.isPlayer == PlayState.playsAsBF())
				return ps.playerStrums;

			return ps.opponentStrums;
		}


		/** Vocals of the given sid. */
		public function getVocalsFromSID(sid:String):FlxSound {
			if (online.GameClient.isConnected() && online.GameClient.room.state.royalMode) {
				return null;
			}

			var char = ps.characters.get(sid);
			if (char == null || ps.opponentVocals == null || ps.opponentVocals.length <= 0 || char.isPlayer == PlayState.playsAsBF()) {
				return ps.vocals;
			}
			return ps.opponentVocals;
		}


		/** Sets the vocals volume of the given sid. */
		public function getVocalsFromSIDVolume(sid:String, v:Float):Void {
			var sidVocals = ps.getVocalsFromSID(sid);
			if (sidVocals != null)
				sidVocals.volume = v;
		}


		/**
		 * Keep characters consistent with room.state.players, with exactly one Character per player.
		 * Every player must have exactly one Character.
		 *
		 * Rules (idempotent; safe to repeat from create(), onAdd/onRemove("players") and bfSide changes):
		 *   1. the first sid on the BF side (bfSide=true) takes the existing boyfriend, and the first sid on the dad side takes the existing dad;
		 *   2. the second and later players on a side each get a new Character (using the song's player1/player2);
		 *   3. a sid that leaves the room returns its canonical (not destroyed); an independently created one is destroyed and removed from the group;
		 *   4. hide an unoccupied side's canonical -- this is the fix for the "two opponent sprites" bug: while both clients defaulted to
		 *      bfSide=false, the local dad canonical and the remote shadow character showed at once.
		 *      The server now assigns sides in onPlayerJoined (one left, one right) and the client falls back to the character table.
		 */
		function syncOnlineCharacters():Void {
			var room = online.GameClient.room;
			if (room == null || room.state == null || room.state.players == null)
				return;

			// 1) Which side's canonical slot each sid occupies
			var bfOwner:String = null;
			var dadOwner:String = null;
			for (sid => player in room.state.players) {
				if (player == null)
					continue;
				if (player.bfSide) {
					if (bfOwner == null)
						bfOwner = sid;
				}
				else if (dadOwner == null)
					dadOwner = sid;
			}

			// 2) Drop the sids that have left the room
			var gone:Array<String> = [];
			for (sid in ps.characters.keys()) {
				if (room.state.players.get(sid) == null)
					gone.push(sid);
			}
			for (sid in gone) {
				var indep = ps.onlineIndepChars.get(sid);
				ps.onlineIndepChars.remove(sid);
				ps.characters.remove(sid);
				if (indep != null) {
					(indep.isPlayer ? ps.boyfriendGroup : ps.dadGroup).remove(indep, true);
					indep.destroy();
				}
			}

			// 3) Assign / reuse per room member
			for (sid => player in room.state.players) {
				if (player == null)
					continue;

				var isBF:Bool = player.bfSide;
				var canonical:Character = isBF ? ps.boyfriend : ps.dad;
				var ownsCanonical:Bool = (isBF ? bfOwner : dadOwner) == sid;
				var indep = ps.onlineIndepChars.get(sid);
				var current = ps.characters.get(sid);

				if (ownsCanonical) {
					if (indep != null) {
						// This player went from an independent character to the canonical owner (e.g. the other side freed it)
						ps.onlineIndepChars.remove(sid);
						(indep.isPlayer ? ps.boyfriendGroup : ps.dadGroup).remove(indep, true);
						indep.destroy();
						if (current == indep)
							current = null;
					}
					canonical.ox = Std.int(player.ox);
					ps.characters.set(sid, canonical);
				}
				else {
					if (current == null || indep == null) {
						// Needs a (new) independent character: either none yet, or it currently owns the canonical slot
						var charName:String = isBF ? PlayState.SONG.player1 : PlayState.SONG.player2;
						var nc:Character = new Character(0, 0, charName, isBF);
						ps.startCharacterPos(nc, !isBF);
						(isBF ? ps.boyfriendGroup : ps.dadGroup).add(nc);
						ps.onlineIndepChars.set(sid, nc);
						ps.characters.set(sid, nc);
						current = nc;
					}
					if (current != null)
						current.ox = Std.int(player.ox);
				}
			}

			// 4) Hide the canonical character of an unclaimed side (avoids ghost characters)
			if (ps.boyfriend != null)
				ps.boyfriend.visible = bfOwner != null;
			if (ps.dad != null)
				ps.dad.visible = dadOwner != null;
		}


		/**
		 * Per-sid sync for the Change Character event.
		 *
		 * This engine drives remote-player animations (charPlay, opponentNoteHitSID,
		 * noteMiss / noteHold) through characters:Map<sid, Character>. The event
		 * walks [canonical].concat([for (v in characters) v]) in the event and builds one
		 * `<value2>__<sid>` instance per same-side sid, then characters.set(daSID, char). This engine's
		 * onEvent used to swap only the canonical, so after a character change characters[sid] still
		 * pointed at the old, replaced-out instance (alpha 0.00001): to the other player the new character just stands still.
		 *
		 * This function follows the same rules as syncOnlineCharacters():
		 *   * the first sid on a side owns the canonical -> characters[sid] is re-pointed to the swapped canonical;
		 *   * the other same-side sids are independent instances -> build one `<value2>__<sid>` (the
		 *     resource name stays value2 without the suffix; only the Map key carries it) and replace onlineIndepChars[sid],
		 *     otherwise the next onAdd/onRemove triggers syncOnlineCharacters() and rebuilds the song default character.
		 * Old instances are only hidden, not destroyed, which keeps them in their groups.
		 *
		 * Online only; charType == 2 (gf) never enters the characters map, so callers skip it.
		 */
		function onlineRebindCharacters(charType:Int, newChar:String):Void {
			if (!online.GameClient.isConnected()) return;

			var room = online.GameClient.room;
			if (room == null || room.state == null || room.state.players == null) return;

			var isBF:Bool = (charType == 0);

			// Canonical owner = the first sid on that side (same rule as syncOnlineCharacters)
			var owner:String = null;
			for (sid => player in room.state.players) {
				if (player != null && player.bfSide == isBF) {
					owner = sid;
					break;
				}
			}

			var holder:Character = isBF ? ps.boyfriend : ps.dad;

			for (sid in ps.characters.keys()) {
				var old:Character = ps.characters.get(sid);
				if (old == null || old.isPlayer != isBF) continue;   // the other side, or already gone
				if (old.curCharacter == newChar) continue;           // already the new character

				if (sid == owner) {
					if (holder != null) ps.characters.set(sid, holder);
					continue;
				}

				var target:Character = null;
				var indepID:String = newChar + '__' + sid;
				if (isBF) {
					if (!ps.boyfriendMap.exists(indepID)) {
						var nb:Boyfriend = new Boyfriend(0, 0, newChar);
						ps.boyfriendMap.set(indepID, nb);
						ps.boyfriendGroup.add(nb);
						ps.startCharacterPos(nb);
						nb.alpha = 0.00001;
						ps.startCharacterLua(nb.curCharacter);
					}
					target = ps.boyfriendMap.get(indepID);
				} else {
					if (!ps.dadMap.exists(indepID)) {
						var nd:Character = new Character(0, 0, newChar);
						ps.dadMap.set(indepID, nd);
						ps.dadGroup.add(nd);
						ps.startCharacterPos(nd, true);
						nd.alpha = 0.00001;
						ps.startCharacterLua(nd.curCharacter);
					}
					target = ps.dadMap.get(indepID);
				}
				if (target == null) continue;

				var keepAlpha:Float = old.alpha;
				old.alpha = 0.00001;
				target.alpha = keepAlpha;
				ps.characters.set(sid, target);
				ps.onlineIndepChars.set(sid, target);
			}
		}


		/** Get (or lazily create) the rating popup owned by a remote sid. */
		function getOnlineRatingPopup(sid:String):RatingPopup {
			var popup = ps.onlineRatingPopups.get(sid);
			if (popup != null) return popup;

			popup = new RatingPopup();
			popup.targetCameras = [ps.camHUD];
			popup.antialiasing = PlayState.isPixelStage ? false : ClientPrefs.data.globalAntialiasing;
			popup.isPixel = PlayState.isPixelStage;
			popup.daPixelZoom = PlayState.daPixelZoom;

			// Every popup needs its own FlxSpriteGroup: RatingPopup.clearAll() clears `container.members`,
			// so sharing comboGroup across sids would share one pool. Cameras must be assigned
			// explicitly or the children fall back to the default game camera (see create()).
			//
			// The group is inserted as a *sibling* of the local popup's container, never as a child of it:
			// in modern mode comboGroup IS the local container, and `comboStacking` is off by default, so
			// the local popup calls clearAll() on every hit. A nested remote group was unlisted and killed
			// by the first local hit (so the opponent's popup never drew again) and was then pushed into
			// the local sprite pool, where a FlxSpriteGroup -- which has no graphic of its own and whose
			// loadGraphic() is a no-op -- got handed out as a rating/digit sprite (that is the intermittent
			// blank / jumping combo number). Sibling containers keep both pools independent.
			var grp:FlxSpriteGroup = new FlxSpriteGroup();
			grp.cameras = [ps.camHUD];
			var anchor:Int = ps.members.indexOf(ps.ratingPopup != null ? ps.ratingPopup.container : null);
			ps.insert(anchor >= 0 ? anchor + 1 : ps.members.length, grp);
			popup.container = grp;

			ps.onlineRatingPopups.set(sid, popup);
			return popup;
		}


		/**
		 * Rating placement offset (horizontal / vertical) for the given sid.
		 *
		 * A remote player's popup is anchored to that player's own character. The upstream formula
		 * (`FlxG.width * (0.4 + (isPlayer == playsAsBF() ? 0.15 : -0.1)) + ox * 250`) evaluates to
		 * ~0.3 * width for the player on the other side -- in a 1v1 that is every remote player -- which
		 * is only ~0.05 * width away from the local popup (always `FlxG.width * 0.35` in this engine).
		 * Both popups therefore landed on top of each other: the remote's icon was invisible (it sat on
		 * the local one) and the interleaved combo digits made it look like one player's number jumped
		 * whenever the other player hit a note. Anchoring to the character is also side-correct under
		 * `swapSides`, because `syncOnlineCharacters()` moves that character with `player.bfSide`.
		 * Same-side players (coop / 2v2) share a character position here, so `ox` fans their popups out.
		 */
		function getRatingOffset(?forSID:String):Array<Float> {
			var placementX:Float = FlxG.width * 0.35;
			var placementY:Float = 0;
			if (online.GameClient.isConnected() && forSID != null) {
				var char = ps.characters.get(forSID);
				if (char != null) {
					var localX:Float = FlxG.width * 0.35;
					placementX = char.x + char.width * 0.5 + char.ox * 90;
					// A remote popup must never land on the local one (their digits interleave and read as
					// one player's number jumping): keep it a full popup width to one side of the local x.
					if (Math.abs(placementX - localX) < 200)
						placementX = localX + (placementX >= localX ? 200 : -200);
					// Clamped so a mod character parked at the screen edge still gets its popup on screen.
					placementX = Math.max(FlxG.width * 0.05, Math.min(FlxG.width * 0.95, placementX));
				}
				else {
					// No character is bound to that sid: fall back to the remote player's own half of the
					// screen (BF is on the right in this engine) instead of collapsing onto the local popup.
					var player = online.GameClient.room.state.players.get(forSID);
					placementX = FlxG.width * ((player != null && player.bfSide) ? 0.65 : 0.2);
				}
			}
			return [placementX, placementY];
		}


		/** Rating popup for the given sid, drawn through this engine's RatingPopup. */
		function popUpScoreOP(ratingImage:String, ?forSID:String):Void {
			// A remote player uses its own popup; the local player still goes through ratingPopup / popUpScore()
			// (the server broadcasts noteHit with `except: client`, so the local client never receives its own hits).
			var popup:RatingPopup = ps.ratingPopup;
			if (forSID != null)
				popup = ps.getOnlineRatingPopup(forSID);

			if (popup == null)
				return;

			var stats:PlayStatePlayer = (forSID != null) ? ps.getPlayerStats(forSID) : null;
			var comboValue:Int = (stats != null) ? stats.combo : 0;
			var placement = ps.getRatingOffset(forSID);

			ps.showRatingPopup(popup, ratingImage, comboValue, placement[0], ps.showRating, comboValue >= 10);
		}


		/** Character animation tag for the given side / sid. */
		function getCharPlayTag(isBF:Null<Bool>, ?sid:String):String {
			if (sid != null)
				return 'characters[${sid}]';

			if (isBF == null)
				return 'gf';

			return isBF ? 'boyfriend' : 'dad';
		}


		/** Shows the BOTPLAY label. */
		function showBotplay():Void {
			if (ps.botplayTxt == null)
				return;

			// There is an online branch that shows the BOTPLAY label when any player in the room
			// has botplay on, but it reads the long-gone `state.player1/player2` fields, so the whole
			// block is commented out there. This engine's schema is a `players` map, so the same intent is
			// restored: show the label when the local or any room player has botplay on (still centred).
			// showBotplay is only called from the online listener, so the single-player path is unaffected.
			ps.botplayVisibility = ps.cpuControlled;
			if (online.GameClient.isConnected() && online.GameClient.room != null) {
				for (sid => player in online.GameClient.room.state.players) {
					if (player != null && player.botplay) {
						ps.botplayVisibility = true;
						break;
					}
				}
			}

			ps.botplayTxt.x = FlxG.width / 2 - ps.botplayTxt.width / 2;
			ps.botplayTxt.visible = ps.botplayVisibility;
		}


		/** The room's pause policy; legacy whenever this client is not in a room. */
		function onlinePauseMode():Int {
			if (!online.GameClient.isConnected() || online.GameClient.room == null || online.GameClient.room.state == null) {
				return PlayState.ONLINE_PAUSE_LEGACY;
			}
			return Std.int(online.GameClient.room.state.pauseMode);
		}


		/** Whether the local player may freeze the room (a host-only room answers false for a guest). */
		function onlinePauseAllowed():Bool {
			if (ps.onlinePauseMode() == PlayState.ONLINE_PAUSE_HOST_ONLY) {
				return online.GameClient.isOwner;
			}
			return true;
		}


		/**
		 * Whether the local pause menu may resume the room: the owner of the pause may, and in host-only
		 * rooms the host may as well. A client that knows of no pause is allowed, so an out-of-sync
		 * client can never be trapped behind a pause nobody owns.
		 */
		public function onlineResumeAllowed():Bool {
			var mode:Int = ps.onlinePauseMode();
			if (mode == PlayState.ONLINE_PAUSE_LEGACY || ps.onlinePausedBy == "") {
				return true;
			}
			if (mode == PlayState.ONLINE_PAUSE_HOST_ONLY) {
				return online.GameClient.isOwner;
			}
			return online.GameClient.room != null && ps.onlinePausedBy == online.GameClient.room.sessionId;
		}


		/** Tells the player that this client may not lift the room's pause (someone else owns it). */
		public function onlineResumeNotice():Void {
			var hostOnly:Bool = (ps.onlinePauseMode() == PlayState.ONLINE_PAUSE_HOST_ONLY);
			ps.onlineAlert(online.util.OnlineLang.L('pause.title', 'Paused'),
				hostOnly
					? online.util.OnlineLang.L('pause.resumeHostOnly', 'Only the host can resume the game!')
					: online.util.OnlineLang.L('pause.waitResume', 'Wait for the player who paused the game to resume!'));
		}


		/** Display name of a room player, falling back to the sid. */
		function onlinePlayerName(sid:String):String {
			if (online.GameClient.room == null || online.GameClient.room.state == null) {
				return sid;
			}
			var player:Dynamic = online.GameClient.room.state.players.get(sid);
			if (player != null && player.name != null && player.name != "") {
				return player.name;
			}
			return sid;
		}


		/** Room-message notice; a no-op when the online Alert overlay was never created. */
		inline function onlineAlert(title:String, message:String):Void {
			if (Reflect.field(online.gui.Alert, "instance") == null) {
				return;
			}
			online.gui.Alert.alert(title, message);
		}


		/** Re-centres the prompt; a FlxText only re-measures its own width when asked to. */
		function layoutWaitReadyOverlay():Void {
			if (ps.waitReadySpr == null)
				return;

			ps.waitReadySpr.updateHitbox();
			ps.waitReadySpr.x = (ps.camOther.width - ps.waitReadySpr.width) / 2;
			ps.waitReadySpr.y = (ps.camOther.height - ps.waitReadySpr.height) / 2;
		}


		/**
		 * Creates the wait-ready overlay.
		 *
		 * A FlxTextMenuItem rather than an Alphabet: it goes through Paths.languageFont() with the same
		 * outline as the rest of the UI, so the localized string renders in the selected language
		 * instead of the bitmap font's fixed ASCII glyphs. `isMenuItem = false` keeps the menu lerp
		 * from dragging it back to its start position.
		 *
		 * Android note: this engine binds PlayState's own pad with Action = NONE
		 * (MusicBeatState.addAndroidControls -> setVirtualPadNOTES(..., RIGHT_FULL, NONE)), so the
		 * touch build has no button wired to `controls.ACCEPT` at all -- the gate in update() could
		 * never open and the song could never start. When addVirtualPad() really created a pad
		 * (TOUCH_CONTROLS, or the desktop touch setting), one A button is added for the wait and the
		 * prompt names that button instead of a key this device does not have.
		 */
		function spawnWaitReadyOverlay():Void {
			if (ps.waitReadySpr != null)
				return;

			ps.addVirtualPad(FlxDPadMode.NONE, FlxActionMode.A);
			ps.waitReadyPad = (ps.virtualPad != null);
			if (ps.waitReadyPad)
			{
				// camGame follows the camera mid-song; camOther is the overlay camera the prompt is on.
				ps.virtualPad.cameras = [ps.camOther];
			}

			ps.waitReadySpr = new FlxTextMenuItem(0, 0, ps.waitReadyPad
				? online.util.OnlineLang.L('game.readyTouch', 'Tap A to Start')
				: online.util.OnlineLang.L('game.ready', 'Press ACCEPT to Start'), 48);
			ps.waitReadySpr.isMenuItem = false;
			ps.waitReadySpr.cameras = [ps.camOther];
			ps.waitReadySpr.alpha = 0;
			ps.add(ps.waitReadySpr);
			ps.layoutWaitReadyOverlay();
			ps.waitReady = true;
		}


		/** startCountdown()'s `canStart` check. */
		function onlineCheckCanStart():Bool {
			if (!online.GameClient.isConnected())
				return true;

			if (!ps.canStart)
			{
				ps.canStart = true;
				if (ps.waitReadySpr != null)
					ps.waitReadySpr.alpha = 1;
				return false;
			}
			return true;
		}


		/** May this client auto-hit opponent notes locally? */
		function opponentAutoHitAllowed():Bool {
			if (!online.GameClient.isConnected())
				return true;

			return ps.playOtherSide || online.GameClient.room.state.royalMode;
		}


		/** Number of opponents in the room. */
		function countOpponents():Int {
			if (!online.GameClient.isConnected() || ps.playOtherSide || online.GameClient.room.state.royalMode)
				return 1;

			var count:Int = 0;
			for (sid => character in ps.characters)
			{
				if (character != null && !character.isPlayer)
					count++;
			}
			return count;
		}


		/**
			 * The isPlayerNote() predicate, using this engine's mustPress convention (see the
		 * block header). Used by the "noteHit"/"noteMiss" listeners to find the note a remote player
		 * just drove.
		 */
		public static function isPlayerNote(note:Note):Bool {
			return note.mustPress;
		}


		/**
		 * Per-sid opponent note hit for a remote player. See the block header for
		 * why this wraps the engine's 1-parameter opponentNoteHit instead of extending it.
		 */
		function opponentNoteHitSID(note:Note, sid:String):Void {
			note.hits++;
			if (note.hits - ps.countOpponents() > 0)
				return;

			var opChar:Character = ps.characters.get(sid);

			var altAnim:String = note.animSuffix;
			var useGF:Bool = note.gfNote;
			var isHey:Bool = (note.noteType == 'Hey!');
			var doSing:Bool = !note.noAnimation && !isHey && opChar != null;
			var animToPlay:String = null;

			if (doSing)
			{
				if (PlayState.playsAsBF() && PlayState.SONG.notes[ps.curSection] != null && PlayState.SONG.notes[ps.curSection].altAnim && !PlayState.SONG.notes[ps.curSection].gfSection)
					altAnim = '-alt';
				animToPlay = ps.getSingAnim(note) + altAnim;
			}

			// The engine's opponent path also animates dad/boyfriend and switches the opponent vocals;
			// suppress only the animation so the remote character is the one that sings (the split happens
			// exactly at the opChar selection).
			var wasNoAnim:Bool = note.noAnimation;
			note.noAnimation = true;
			ps.opponentNoteHit(note);
			note.noAnimation = wasNoAnim;

			if (isHey && opChar != null && opChar.animOffsets.exists('hey'))
			{
				opChar.playAnim('hey', true);
				opChar.specialAnim = true;
				opChar.heyTimer = 0.6;
			}
			else if (doSing)
			{
				var target:Character = (useGF && ps.gf != null) ? ps.gf : opChar;
				if (target != null)
				{
					target.playAnim(animToPlay, true);
					target.holdTimer = 0;
				}
			}

			if (PlayState.SONG.needsVoices)
				ps.getVocalsFromSIDVolume(sid, 1);
		}


		/**
			 * Room message registration, as described in the block header.
			 * Called once from create() while connected, and re-invoked
			 * through `GameClient.initStateListeners` after a reconnect.
		 */
		function registerMessages():Void {
			online.GameClient.initStateListeners(ps, ps.registerMessages);

			if (!online.GameClient.isConnected())
				return;

			// Players can join or leave mid-song, so listeners and characters must hang off the state-level
			// onAdd/onRemove rather than being installed once for the players present when the room was
			// created. onAdd's immediate flag defaults to true, so registration already fires once for
			// every player in the room; a for loop here would double the listeners.
			online.GameClient.registerStateDisposer(ps, online.GameClient.callbacks.onAdd("players", (player, sid) -> {
				online.backend.Waiter.put(() -> {
					if (ps.destroyed)
						return;
					ps.listenPlayerSID(sid, player);
					ps.syncOnlineCharacters();
				});
			}));

			online.GameClient.registerStateDisposer(ps, online.GameClient.callbacks.onRemove("players", (player, sid) -> {
				online.backend.Waiter.put(() -> {
					if (ps.destroyed)
						return;
					ps.onlineListenedSIDs.remove(sid);
					ps.syncOnlineCharacters();
					ps.showBotplay();
				});
			}));

			ps.syncOnlineCharacters();
			ps.initOnlineHealthSync();

			online.GameClient.registerStateMessage(ps, "custom", function(message:Array<Dynamic>) {
				if (message.length != 2)
					return;

				online.backend.Waiter.put(() -> {
					ps.callOnScripts('onCustomMessage', message);
				});
			});

			online.GameClient.registerStateMessage(ps, "log", function(message) {
				online.backend.Waiter.putPersist(() -> {
					online.gui.Alert.alert(online.util.OnlineLang.L('game.newMessage', 'New message'), online.util.ShitUtil.parseLog(message).content);
				});
			});

			online.GameClient.registerStateMessage(ps, "strumPlay", function(_message:Array<Dynamic>) {
				var sid:String = _message[0];
				var message:Array<Dynamic> = _message[1];

				online.backend.Waiter.put(() -> {
					if (message == null || message[0] == null || message[1] == null || message[2] == null)
						return;

					if (ps.callOnScripts('onMessageStrumPlay', Scripts.fill2(Scripts.get(2), sid, message), true) == FunkinLua.Function_Stop)
						return;

					var strums = ps.getStrumsFromSID(sid);
					if (strums == ps.getPlayerStrums())
						return;

					var spr:StrumNote = strums.members[Std.int(message[1])];
					if (spr != null)
					{
						spr.playAnim(message[0] + "", true);
						spr.resetAnim = message[2];
					}
				});
			});

			online.GameClient.registerStateMessage(ps, "charPlay", function(_message:Array<Dynamic>) {
				var sid:String = _message[0];
				var message:Array<Dynamic> = _message[1];

				online.backend.Waiter.put(() -> {
					if (message == null || message[0] == null)
						return;

					if (ps.callOnScripts('onMessageCharPlay', Scripts.fill2(Scripts.get(2), sid, message), true) == FunkinLua.Function_Stop)
						return;

					var isGF:Bool = (message[1] == true);
					var special:Bool = (message[2] == true);
					if (isGF && ps.gf != null)
					{
						ps.gf.playAnim(message[0], true);
						if (special)
							ps.gf.specialAnim = true;
					}
					else if (!isGF)
					{
						var char = ps.characters.get(sid);
						if (char == null)
							return;

						char.playAnim(message[0], true);
						if (special)
							char.specialAnim = true;
					}
				});
			});

			online.GameClient.registerStateMessage(ps, "noteHit", function(_message:Array<Dynamic>) {
				var sid:String = _message[0];
				var message:Array<Dynamic> = _message[1];

				online.backend.Waiter.put(() -> {
					if (message == null || message[0] == null || message[1] == null || message[2] == null)
						return;

					if (ps.callOnScripts('onMessageNoteHit', Scripts.fill2(Scripts.get(2), sid, message), true) == FunkinLua.Function_Stop)
						return;

					ps.notes.forEachAlive(function(note:Note) {
						if (!PlayState.isPlayerNote(note)
							&& note.noteData == message[1]
							&& note.isSustainNote == message[2]
							&& Math.abs(note.strumTime - (message[0] : Float)) < 1)
						{
							ps.opponentNoteHitSID(note, sid);
						}
					});

					if (!(message[2] == true) && message[3] != null)
					{
						ps.getPlayerStats(sid).combo++;
						ps.popUpScoreOP(message[3], sid);
					}

					var isSelf:Bool = (message[6] == true);
					// 参数复用: 见 backend.Scripts。远端每个音符也会走这里, 同样是按音符计的分配。
					var netCharTag:String = ps.getCharPlayTag(isSelf, sid);
					// 分发前整组写入, 避免上一次分发 (可能执行过脚本) 留下的值。
					ps.callOnLuas(isSelf ? 'goodNoteHit' : 'opponentNoteHit',
						Scripts.fill5(Scripts.get(5), message[5], message[1], message[4], message[2], netCharTag));
					// HScript 侧要的是 note 对象 + 同一个 tag 串。netArgs5 上次分发可能触发过脚本,
					// 所以这里在分发前重新写入 (fill2), 不依赖上层缓存。
					ps.callOnHScript(isSelf ? 'goodNoteHit' : 'opponentNoteHit',
						Scripts.fill2(Scripts.get(2), ps.notes.members[Std.int(message[5])], netCharTag));

					ps.updateScoreSID(sid, false);
					ps.getVocalsFromSIDVolume(sid, 1);
				});
			});

			online.GameClient.registerStateMessage(ps, "noteMiss", function(_message:Array<Dynamic>) {
				var sid:String = _message[0];
				var message:Array<Dynamic> = _message[1];

				online.backend.Waiter.put(() -> {
					if (message == null || message[0] == null || message[1] == null || message[2] == null)
						return;

					if (ps.callOnScripts('onMessageNoteMiss', Scripts.fill2(Scripts.get(2), sid, message), true) == FunkinLua.Function_Stop)
						return;

					// The remote sends a noteMiss for *every* sustain segment, and this used to recycle the local
					// counterpart, so an unplayed opponent sustain disappeared segment by segment. Unplayed opponent
					// notes must keep travelling past the judgement line, so the local visual note is no longer
					// destroyed here -- updateNote's "recycle only once off screen" branch handles it. Score / combo / vocals still settle normally.

					ps.updateScoreSID(sid, true);
					ps.getVocalsFromSIDVolume(sid, 0);
					ps.getPlayerStats(sid).combo = 0;
				});
			});

			online.GameClient.registerStateMessage(ps, "startSong", function(_) {
				online.backend.Waiter.put(() -> {
					if (ps.callOnScripts('onMessageStartSong', null, true) == FunkinLua.Function_Stop)
						return;

					ps.isReady = true;
					ps.waitReady = false;
					ps.startCountdown();
				});
			});

			online.GameClient.registerStateMessage(ps, "endSong", function(_) {
				online.backend.Waiter.put(() -> {
					if (ps.callOnScripts('onMessageEndSong', null, true) == FunkinLua.Function_Stop)
						return;

					ps.canEndSongOnline = true;
					ps.endSong();
				});
			});

			// Room-wide pause (room settings' "Pause Policy"). The server echoes the request to everyone,
			// sender included: an echo carrying our own sid means this client owns the pause, an echo
			// carrying someone else's hands the ownership over (so two players pressing ESC in the same
			// tick settle instead of both believing they may resume).
			online.GameClient.registerStateMessage(ps, "pauseGame", function(message) {
				online.backend.Waiter.put(() -> {
					if (ps.destroyed || message == null) {
						return;
					}
					if (ps.onlinePauseMode() == PlayState.ONLINE_PAUSE_LEGACY) {
						return; // the policy changed since the request; keep pausing locally
					}

					var sid:String = Std.string(message);
					var selfSid:String = (online.GameClient.room != null) ? online.GameClient.room.sessionId : null;
					ps.onlinePausedBy = sid;
					ps.onlinePauseLocal = (selfSid != null && sid == selfSid);

					if (ps.paused || ps.boyfriend == null) {
						return; // already frozen (own menu, or a forced pause that is still opening)
					}
					if (!ps.onlinePauseLocal) {
						ps.onlineAlert(online.util.OnlineLang.L('pause.title', 'Paused'),
							online.util.OnlineLang.L('pause.by', 'Paused by ') + ps.onlinePlayerName(sid));
					}
					ps.openPauseMenu(false);
				});
			});

			// The room is running again: every client leaves the forced pause together.
			online.GameClient.registerStateMessage(ps, "resumeGame", function(_) {
				online.backend.Waiter.put(() -> {
					if (ps.destroyed) {
						return;
					}
					ps.onlinePausedBy = "";
					ps.onlinePauseLocal = false;
					if (!ps.paused) {
						return;
					}
					var sub = ps.subState;
					if (sub != null && Std.isOfType(sub, PauseSubState)) {
						(cast sub : PauseSubState).onlineResume();
					}
					else if (sub != null && Std.isOfType(sub, OldPauseSubState)) {
						(cast sub : OldPauseSubState).onlineResume();
					}
					else {
						ps.closeSubState();
					}
				});
			});

			online.objects.ChatBox.tryRegisterLogs();
		}


		/** Installs the state-level schema listeners (ping / botplay / noteHold) for one sid. Idempotent. */
		function listenPlayerSID(sid:String, player:online.backend.schema.Player):Void {
			if (player == null || sid == null)
				return;
			if (ps.onlineListenedSIDs.exists(sid))
				return;
			ps.onlineListenedSIDs.set(sid, true);

			online.GameClient.registerStateDisposer(ps, online.GameClient.callbacks.listen(player, "ping", (value, prev) -> {
				online.backend.Waiter.put(() -> {
					if (ps.destroyed)
						return;
					if (ps.callOnScripts('onPlayerPing', Scripts.fill2(Scripts.get(2), sid, player.ping), true) == FunkinLua.Function_Stop)
						return;

					ps.updateScoreSID(sid, true);
				});
			}));

			online.GameClient.registerStateDisposer(ps, online.GameClient.callbacks.listen(player, "botplay", (value, prev) -> {
				online.backend.Waiter.put(() -> {
					if (ps.destroyed)
						return;
					if (ps.callOnScripts('onPlayerBotplay', Scripts.fill2(Scripts.get(2), sid, value), true) == FunkinLua.Function_Stop)
						return;

					ps.showBotplay();
				});
			}));

			online.GameClient.registerStateDisposer(ps, online.GameClient.callbacks.listen(player, "noteHold", (value, prev) -> {
				online.backend.Waiter.put(() -> {
					if (ps.destroyed)
						return;
					if (ps.callOnScripts('onPlayerNoteHold', Scripts.fill2(Scripts.get(2), sid, value), true) == FunkinLua.Function_Stop)
						return;

					if (ps.characters.exists(sid))
						ps.characters.get(sid).noteHold = value;
				});
			}));
		}


		/** Is `character` this client's own player character? */
		public static function isCharacterPlayer(character:Character):Bool {
			if (PlayState.instance == null)
				return character != null && character.isPlayer;

			return character == (PlayState.playsAsBF() ? PlayState.instance.boyfriend : PlayState.instance.dad);
		}


		/**
		 * Online health is *room-shared* (the schema's Room.health; PlayState.get_health/set_health
		 * PlayState.get_health/set_health also proxy room.state.health while connected). This engine's
		 * health is a plain field (no get/set proxy), so it uses an equivalent report + adopt scheme:
		 *   1. on song start, initialise onlineSyncedHealth to the current local health;
		 *   2. listen to room.state.health -- the server value is authoritative and is adopted directly
		 *      (also updating onlineSyncedHealth so the next update() does not re-send it as a local change);
		 *   3. update() calls syncOnlineHealth() every frame, reporting the local health delta for the server to accumulate.
		 * Result: both clients see the same health value/progress instead of each its own.
		 *
		 * Deliberate difference: set_health is a no-op online (only the
		 * server-simulated value counts); with no server-side simulation here the delta comes from the real client's local judging -- equivalent in effect.
		 */
		function initOnlineHealthSync():Void {
			var room = online.GameClient.room;
			if (room == null || room.state == null)
				return;

			ps.onlineSyncedHealth = ps.health;
			ps.onlineHealthReady = true;

			online.GameClient.registerStateDisposer(ps, online.GameClient.callbacks.listen(room.state, "health", (value, prev) -> {
				online.backend.Waiter.put(() -> {
					if (ps.destroyed || !ps.onlineHealthReady)
						return;
					var v:Float = (value == null) ? 1 : (cast value);
					ps.health = v;
					ps.onlineSyncedHealth = v;
				});
			}));
		}


		function syncOnlineHealth():Void {
			if (!ps.onlineHealthReady || !online.GameClient.isConnected())
				return;

			var delta:Float = ps.health - ps.onlineSyncedHealth;
			if (delta == 0)
				return;

			ps.onlineSyncedHealth = ps.health;
			online.GameClient.send("updateHealth", delta);
		}

}

#end
