// ── Toolchain gate ────────────────────────────────────────────────────────────
// import.hx is implicitly referenced by every module under source/, which makes it the
// earliest point the compiler visits. A compiler older than 4.3 prints this one message
// and stops, instead of cascading hundreds of type errors.
//
// #error accepts a string literal only (an expression fails with "Not implemented for
// current platform"), so the text is fixed; run haxe --version to see what is installed.
//
// Haxe 4.3.x also needs an hxcpp built against the 4.3 API (mohong2/hxcpp, branch
// haxe-4.3); the older 4.2.1 fork is refused with "Hxcpp is out of date - please update".
// Install it with:    haxe -cp ./setup -main Main --interp
// See USE HAXE 4.3.7.txt and the comment at the top of Project.xml.
#if (haxe_ver < 4.3)
#error "SeiunEngine requires Haxe 4.3.7 (minimum 4.3.0); this compiler is older. Run 'haxe --version' to confirm, install Haxe 4.3.7 (https://haxe.org/download/), then install the matching hxcpp 4.3 API with 'haxe -cp ./setup -main Main --interp' and rebuild. See USE HAXE 4.3.7.txt / Project.xml. | SeiunEngine 需要 Haxe 4.3.7(最低 4.3.0), 当前编译器更旧: 先 haxe --version 确认, 装好 4.3.7 后执行 haxe -cp ./setup -main Main --interp 安装配套 hxcpp 4.3 API 再构建, 详见 USE HAXE 4.3.7.txt 与 Project.xml。"
#end

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
