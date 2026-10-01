package script;


class ScriptErrorGuard
{
	static final LOOP_CALLBACKS:Map<String, Bool> = [
		// (Sub)State.update() / updatePost()：PlayState、GameOverSubstate
		'onUpdate' => true,
		'onUpdatePost' => true,
		'onStepHit' => true,
		'onBeatHit' => true,
		'onSectionHit' => true,
		// CustomSubstate.update()
		'onCustomSubstateUpdate' => true,
		'onCustomSubstateUpdatePost' => true
	];

	public static function isLoopCallback(callback:String):Bool
	{
		return callback != null && LOOP_CALLBACKS.exists(callback);
	}
}
