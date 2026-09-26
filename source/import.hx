#if sys
import sys.FileSystem;
import sys.io.File;
#end

using StringTools;

// Why the imports below are wrapped in `&& !macro`:
// Without the guard, every module under `source/` inherits flixel/Paths imports *into the macro
// context*, and expanding any macro declared under `source/` aborts the build with
// "You cannot access the flash package while in a macro (for flash.Lib)".
// Measured (reversible experiment): with the guard the error occurs 0 times; without it, it
// aborts the `-DONLINE_ALLOWED` type-check of the online slice. Target-side typing is
// unaffected — `macro` is only ever defined while typing macro code.
// unaffected — `macro` is only ever defined while typing macro code.
#if (!server_build && !macro)
import Paths;

import flixel.system.FlxSound;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.FlxCamera;
import flixel.math.FlxMath;
import flixel.math.FlxPoint;
import flixel.util.FlxColor;
import flixel.util.FlxTimer;
import flixel.text.FlxText;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import flixel.group.FlxSpriteGroup;
import flixel.group.FlxGroup.FlxTypedGroup;

import backend.MusicBeatSubstate;
import states.PlayState;
import states.LoadingState;
import states.TitleState;
import backend.MusicBeatSubstate;
#if HSCRIPT_ALLOWED
import script.hscript.*;
#end
#end
