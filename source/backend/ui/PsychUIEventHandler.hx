package backend.ui;

import flixel.FlxObject;
import mohong.TraceManager;

/**
 * Mouse dispatch for the Psych UI widgets.
 *
 * Every widget used to do its own 'getScreenPosition + FlxG.mouse' dance, each with a slightly
 * different (and sometimes missing) null check. They all go through {@link overlaps} now, so a
 * control that is hidden, disabled or already destroyed can no longer be clicked - which is what
 * produced most of the "clicked a button on a panel I cannot see" bugs.
 */
class PsychUIEventHandler
{
	public static function event(id:String, sender:Dynamic):Void
	{
		var state:Dynamic = cast FlxG.state;
		if (state == null) return;

		// Walk down to the topmost state/substate (a Prompt above the editor owns the UI then).
		var guard:Int = 0;
		while (state != null && state.subState != null && guard++ < 64)
			state = cast state.subState;

		if (state == null) return;

		try
		{
			if (state.UIEvent != null)
				state.UIEvent(id, sender);
		}
		catch (e:Dynamic)
		{
			// A listener that throws must not take the whole frame (and every other listener) down.
			TraceManager.error('trace.ui.event', 'UI event "{}" handler failed: {}', [id, Std.string(e)]);
		}
	}

	/**
	 * Whether the pointer is over 'obj'.
	 *
	 * Returns false for anything that cannot be interacted with (null / dead / invisible /
	 * inactive), so callers never need their own guard.
	 */
	public static function overlaps(obj:FlxObject, ?camera:FlxCamera):Bool
	{
		if (obj == null || !obj.exists || !obj.visible || !obj.active) return false;
		if (obj.width <= 0 || obj.height <= 0) return false;

		final cam:FlxCamera = (camera != null) ? camera : FlxG.camera;
		if (cam == null) return false;

		final screenPos:FlxPoint = obj.getScreenPosition(null, cam);
		if (screenPos == null) return false;
		final mousePos:FlxPoint = FlxG.mouse.getPositionInCameraView(cam);

		return mousePos.x >= screenPos.x
			&& mousePos.x <= screenPos.x + obj.width
			&& mousePos.y >= screenPos.y
			&& mousePos.y <= screenPos.y + obj.height;
	}

	/** Same as {@link overlaps} but with an explicit world-space rectangle. */
	public static function overlapsRect(x:Float, y:Float, width:Float, height:Float, ?camera:FlxCamera):Bool
	{
		if (width <= 0 || height <= 0) return false;

		final cam:FlxCamera = (camera != null) ? camera : FlxG.camera;
		if (cam == null) return false;

		final mousePos:FlxPoint = FlxG.mouse.getPositionInCameraView(cam);
		return mousePos.x >= x
			&& mousePos.x <= x + width
			&& mousePos.y >= y
			&& mousePos.y <= y + height;
	}
}

interface PsychUIEvent
{
	public function UIEvent(id:String, sender:Dynamic):Void;
}
