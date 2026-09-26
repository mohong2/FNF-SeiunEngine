package backend;

/**
 * The note-optimisation disclaimer.
 *
 * It is raised when the player opens the note_optimization settings page - not at launch,
 * because it is about one page, and not every time the page is opened, because re-reading
 * the same paragraph on every visit is nagging. So: at most once per cold start, on the
 * first visit (process-local flag, never persisted).
 *
 * A Dialog rather than a full state: the disclaimer must not cost an extra state
 * transition on top of the page slide, and Dialog already covers both platforms in this
 * engine (in-game popup on desktop/Linux/macOS, native alert on Windows/Android; the
 * Android path is non-blocking, so nothing here may depend on its return value).
 *
 * The "show the notice again" action row on the same page calls showAgain(), which reuses
 * body() so the two texts can never drift apart.
 */
class NoteOptimisationNotice
{
	/** False until this process raised the disclaimer; deliberately never persisted. */
	public static var shownThisSession:Bool = false;

	public static function shouldShow():Bool
	{
		return !shownThisSession;
	}

	/** Raise the disclaimer once per cold start. */
	public static function show():Void
	{
		shownThisSession = true;
		showAgain();
	}

	/** Re-display the disclaimer without touching the once-per-launch flag. */
	public static function showAgain():Void
	{
		Dialog.showCustom(
			Language.get('NoteOptimisationNotice.title', 'Note Optimisation'),
			body(),
			[{name: Language.get('NoteOptimisationNotice.gotIt', 'Got it'), callback: function() {}}],
			false);
	}

	/** The disclaimer text. English default inlined, same style as FlashingState. */
	public static function body():String
	{
		return Language.get('NoteOptimisationNotice.body',
			'Note optimisation - read this first\n'
			+ 'The note optimisation in this engine is a side feature, not a product. It exists so that '
			+ 'enormous charts (tens of millions of notes) can at least be played; it was not written by a '
			+ 'dedicated note-optimisation project and does not try to match one.\n'
			+ 'If it is slower or rougher than such an engine, that is expected. Please use that engine '
			+ 'instead of filing a complaint here.\n'
			+ '(Shown once per launch, when this page is opened.)');
	}
}
