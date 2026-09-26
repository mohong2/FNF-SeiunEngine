package online.objects;

import online.network.FunkinNetwork;

class NicommentsView extends FlxTypedGroup<Nicomment> {
	var songComments:Array<SongComment>;

	public var alpha:Float = 1.0;
	public var offsetY:Float = 0;
	var rows:Array<Int> = [for (i in 0...15) i];

    public function new(songId:String) {
		super();

		// Haxe 4.2.5 has no null-coalescing operator; expand it.
		songComments = FunkinNetwork.fetchSongComments(songId);
		if (songComments == null)
			songComments = [];
		FlxG.random.shuffle(rows);
    }

    override function update(elapsed) {
        super.update(elapsed);

		while (songComments.length > 0 && songComments[0].at <= Conductor.songPosition) {
			var comment = songComments.shift();

			if (ClientPrefs.isDebug())
				trace(comment);

			final row = rows.shift();
			rows.insert(FlxG.random.int(rows.length - 3, rows.length - 1), row);

			var text = recycle(Nicomment);
			text.init(comment.content + ' - ' + comment.player, this, row);
			add(text);
		}
    }

	public function timeJump(time:Float) {
		while (songComments.length > 0 && songComments[0].at < time - 3000) {
			songComments.shift();
		}
	}
}

class Nicomment extends FlxText {
	public function new() {
		super(0, 0);
		setFormat(Paths.font("vcr.ttf"), 24, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		scrollFactor.set(0, 0);
	}

	var speed:Float = 1;

	public function init(content:String, nico:NicommentsView, row:Int) {
		setPosition(FlxG.width / nico.camera.zoom, nico.offsetY + row * 25);
		text = content;
		speed = FlxG.random.float(1, 2);
		alpha = nico.alpha;
	}

	override function update(elapsed) {
		super.update(elapsed);

		x -= elapsed * 200 * speed;
		// `FlxCamera.viewX` does not exist in flixel 4.11 (`flixel.FlxCamera has no field viewX`);
		// `scroll.x` holds the same value. `viewX` was added in flixel 5 as a read-only alias of
		// `scroll.x`.
		if (!isOnScreen(camera) && x < camera.scroll.x) {
			kill();
		}
	}
}

typedef SongComment = {
	var player:String;
	var content:String;
	var at:Float;
}