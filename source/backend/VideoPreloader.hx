package backend;

#if VIDEOS_ALLOWED
#if hxvlc
import hxvlc.util.Handle;
import hxvlc.openfl.Video;
#end

/**
 * Warms up LibVLC (hxvlc) off the main thread and lets video code wait for it
 * without blocking/freezing the game loop.
 *
 * Root cause this solves:
 * hxvlc's `Video` constructor synchronously calls `Handle.init()` on the first
 * video object. On a cold start LibVLC may have to scan/reset its plugin cache,
 * which can stall the main thread for a noticeable amount of time (the "first
 * video freezes, later videos are fine" symptom). By starting that init during
 * boot and by deferring `startVideo` until `Handle.sharedInstance` is ready, the
 * freeze is moved out of gameplay.
 */
class VideoPreloader
{
	static var pendingCallbacks:Array<Void->Void> = [];
	static var polling:Bool = false;
	static var warmingUp:Bool = false;
	static var warmupFailed:Bool = false;
	static var warmupStartedAt:Float = -1;
	static var warmupRetries:Int = 0;
	static var mediaPrewarmed:Bool = false;
	static inline var WARMUP_TIMEOUT:Float = 15.0;
	static inline var MAX_WARMUP_RETRIES:Int = 3;

	/** Start LibVLC initialization as early as possible (non-blocking). */
	public static function warmup():Void
	{
		#if hxvlc
		if (Handle.sharedInstance == null && !Handle.loading && !warmingUp && !warmupFailed)
		{
			warmingUp = true;
			warmupStartedAt = haxe.Timer.stamp();

			try
			{
				Handle.initAsync(null, function(success:Bool):Void
				{
					warmingUp = false;
					warmupStartedAt = -1;
					if (success)
					{
						warmupRetries = 0;
						// Warm the media player pipeline as early as possible so
						// the first real video doesn't pay one-time setup cost.
						prewarmMedia();
					}
					warmupFailed = !success;
					flushPending();
				});
			}
			catch (e:Dynamic)
			{
				// The background thread could not be started yet (e.g. very early
				// boot). Do NOT mark this as a permanent failure; a later
				// `whenReady()` will retry asynchronously.
				warmingUp = false;
				warmupStartedAt = -1;
				trace('VideoPreloader: async LibVLC warmup failed to start: $e');
			}
		}
		#end
	}

	/** True once LibVLC is usable. */
	public static function isReady():Bool
	{
		#if hxvlc
		return Handle.sharedInstance != null;
		#else
		return true;
		#end
	}

	/** True if a previous LibVLC init attempt already failed. */
	public static function isFailed():Bool
	{
		#if hxvlc
		return warmupFailed;
		#else
		return false;
		#end
	}

	/**
	 * Warms up the one-time media player pipeline (libVLC player, OpenAL
	 * sources/buffers, event hooks) with a dummy media. Call this during a
	 * loading screen so the first real cutscene video starts immediately.
	 */
	public static function prewarmMedia():Void
	{
		#if hxvlc
		if (Handle.sharedInstance == null || mediaPrewarmed)
			return;

		mediaPrewarmed = true;

		// hxvlc 2.3.x builds the libVLC media player, the vmem/vdummy outputs and
		// the OpenAL source inside the `Video` constructor, so constructing one
		// instance and disposing it right away *is* the pipeline pre-warm.
		var dummy:Video = new Video();

		try
		{
			dummy.dispose();
		}
		catch (e:Dynamic)
		{
			trace('VideoPreloader: media pipeline prewarm failed: $e');
		}
		#end
	}

	/**
	 * Runs `callback` as soon as LibVLC is ready.
	 * If it is already ready, the callback runs synchronously.
	 */
	public static function whenReady(callback:Void->Void):Void
	{
		#if hxvlc
		if (Handle.sharedInstance != null)
		{
			callback();
			return;
		}

		// If an init is genuinely still running, always wait for it instead of
		// falling back to a (possibly stale) failure path.
		if (Handle.loading)
		{
			pendingCallbacks.push(callback);

			if (!polling)
			{
				polling = true;
				poll();
			}
			return;
		}

		if (warmupFailed)
		{
			// Do NOT fall back to a synchronous `Handle.init()` here: that would
			// block the main thread during the first video and cause the window
			// to look inactive/delayed. Instead retry asynchronously a few times.
			if (warmupRetries >= MAX_WARMUP_RETRIES)
			{
				callback();
				return;
			}

			warmupRetries++;
			warmupFailed = false;
		}

		pendingCallbacks.push(callback);
		warmup();

		if (!polling)
		{
			polling = true;
			poll();
		}
		#else
		callback();
		#end
	}

	static function poll():Void
	{
		#if hxvlc
		if (Handle.sharedInstance != null)
		{
			polling = false;
			flushPending();
			return;
		}

		// If initialization failed (nothing is loading anymore), retry a few
		// times asynchronously before giving up. Do NOT flush callbacks on the
		// first failure, otherwise LoadingState would proceed without LibVLC.
		if (!Handle.loading && !warmingUp)
		{
			if (warmupRetries < MAX_WARMUP_RETRIES)
			{
				warmupRetries++;
				warmupFailed = false;
				warmup();
				haxe.Timer.delay(poll, 50);
				return;
			}

			warmupFailed = true;
			polling = false;
			flushPending();
			return;
		}

		// Safety timeout for the rare case where the async init thread never
		// starts or never calls back.
		if (warmingUp && warmupStartedAt >= 0 && haxe.Timer.stamp() - warmupStartedAt > WARMUP_TIMEOUT)
		{
			warmingUp = false;
			warmupStartedAt = -1;

			if (warmupRetries < MAX_WARMUP_RETRIES)
			{
				warmupRetries++;
				warmupFailed = false;
				warmup();
				haxe.Timer.delay(poll, 50);
				return;
			}

			warmupFailed = true;
			polling = false;
			flushPending();
			return;
		}

		haxe.Timer.delay(poll, 50);
		#end
	}

	static function flushPending():Void
	{
		var callbacks:Array<Void->Void> = pendingCallbacks;
		pendingCallbacks = [];
		for (callback in callbacks)
		{
			if (callback != null)
				callback();
		}
	}
}
#end
