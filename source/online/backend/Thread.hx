package online.backend;

import haxe.Exception;

class Thread {
	/**
	 * One-off tasks share a FIXED worker pool instead of "Thread.create per task". The engine runs
	 * with HXCPP_GC_GENERATIONAL, and under hxcpp every HaxeThread carries a per-thread mark chunk
	 * (mOldReferrers) whose lifecycle races with rapid thread create/destroy -- in online mode each
	 * menu fired a fresh thread per HTTP request, and mashing the back button crashed the process
	 * inside a GC write barrier (StackContext::pushReferrer dereferencing a garbage chunk). Workers
	 * are created once and stay parked on the queue, so thread count no longer follows input
	 * speed. Thread.repeat stays on Thread.create on purpose: those are few, long-lived loops.
	 *
	 * Sized for the worst realistic mix: a couple of long downloads (ModDownloader / GameBanana)
	 * must not starve the small UI requests (announcements, leaderboards) that menus fire.
	 */
	static inline var POOL_SIZE:Int = 8;
	static var pool:sys.thread.FixedThreadPool;

	static function getPool():sys.thread.FixedThreadPool {
		if (pool == null)
			pool = new sys.thread.FixedThreadPool(POOL_SIZE);
		return pool;
	}

    public static function run(func:Void->Void, ?onException:Exception->Void) {
        getPool().run(() -> {
            try {
                func();
            }
            catch (exc) {
				Waiter.putPersist(() -> { // waiter more errors please!
					if (onException != null)
                        onException(exc);
                    else
                        throw exc;
                });
            }
        });
    }

	public static function repeat(func:Void->Void, everySeconds:Float, ?onException:Exception->Void) {
		sys.thread.Thread.create(() -> {
            var running = true;
			try {
				while (running) {
					func();
					Sys.sleep(everySeconds);
                }
			}
			catch (exc) {
				running = false;
				Waiter.putPersist(() -> { // waiter more errors please!
					if (onException != null)
						onException(exc);
					else
						throw exc;
				});
			}
		});
    }

	public static function safeCatch(task:Void->Void, ?onException:Exception->Void) {
		try {
			task();
		}
		catch (exc:Dynamic) {
			Waiter.putPersist(() -> {
				if (onException != null)
					onException(exc);
				else
					throw exc;
			});
		}
	}
}