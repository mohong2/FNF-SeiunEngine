package backend;

#if js
import js.Syntax;
#end

/**
 * HTML5 fallback of the crash architecture (see native_crash.inc / FatalReport.cpp
 * for the native funnels).
 *
 * A browser has no ndll, no MessageBoxW and no writable crash/ directory, so the
 * degraded path is:
 *
 *   1. window.onerror + unhandledrejection are installed before the game boots,
 *   2. the error goes to console.error, to localStorage (so it survives the
 *      reload the player will inevitably do) and to an overlay that covers the
 *      canvas - the only surface a browser gives us,
 *   3. the overlay carries the stack and a "copy" button, because the report
 *      cannot be written to disk from a web page.
 *
 * Deliberately an HTML overlay rather than something painted into the game's
 * canvas: text stays selectable/copyable, it still works after the WebGL context
 * is lost (exactly when a canvas overlay would be blank), and it needs no font
 * or sprite machinery that may itself be what crashed.
 */
class Html5Fatal
{
	public static var installed:Bool = false;

	/** Install the handlers. Safe to call more than once; no-op off HTML5. */
	public static function install():Void
	{
		#if js
		if (installed) return;
		installed = true;
		try
		{
			Syntax.code("
				(function () {
					if (window.__seiunFatalInstalled) return;
					window.__seiunFatalInstalled = true;

					function seiunText(v) {
						try {
							if (v === null || v === undefined) return '(none)';
							if (typeof v === 'string') return v;
							if (v.stack) return String(v.stack);
							if (v.message) return String(v.message);
							return String(v);
						} catch (e) { return '(unprintable value)'; }
					}

					function seiunOverlay(title, body) {
						try {
							var doc = document;
							var old = doc.getElementById('seiun-fatal-overlay');
							if (old && old.parentNode) old.parentNode.removeChild(old);

							var box = doc.createElement('div');
							box.id = 'seiun-fatal-overlay';
							box.setAttribute('style', 'position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483647;' +
								'background:rgba(6,6,10,0.95);color:#eeeeee;padding:24px 28px;overflow:auto;' +
								'font:13px/1.55 Consolas,\"Courier New\",monospace;white-space:pre-wrap;word-break:break-word;');

							var head = doc.createElement('div');
							head.textContent = title;
							head.setAttribute('style', 'font:600 19px/1.4 \"Segoe UI\",system-ui,sans-serif;color:#ff8a8a;margin-bottom:14px;');

							var text = doc.createElement('div');
							// textContent, never innerHTML: the exception text may contain markup.
							text.textContent = body;

							var bar = doc.createElement('div');
							bar.setAttribute('style', 'margin-top:18px;font-family:\"Segoe UI\",system-ui,sans-serif;');

							var copy = doc.createElement('button');
							copy.textContent = '复制报告 / Copy report';
							copy.setAttribute('style', 'margin-right:10px;padding:7px 14px;cursor:pointer;border:1px solid #666;' +
								'border-radius:4px;background:#22222a;color:#eee;font-size:13px;');
							copy.onclick = function () {
								try {
									var report = title + '\n\n' + body;
									if (navigator.clipboard && navigator.clipboard.writeText) {
										navigator.clipboard.writeText(report);
									} else {
										var ta = document.createElement('textarea');
										ta.value = report;
										document.body.appendChild(ta);
										ta.select();
										document.execCommand('copy');
										document.body.removeChild(ta);
									}
									copy.textContent = '已复制 / Copied';
								} catch (e) { copy.textContent = '复制失败 / Copy failed (select the text)'; }
							};

							var hint = doc.createElement('div');
							hint.setAttribute('style', 'margin-top:12px;color:#9a9aa2;font-size:12px;');
							hint.textContent = '浏览器里无法写文件：请把这个框里的内容（或控制台里的同一份内容）发给开发者。' +
								' / A web page cannot write files: send this text to the developers.';

							bar.appendChild(copy);
							box.appendChild(head);
							box.appendChild(text);
							box.appendChild(bar);
							box.appendChild(hint);
							(doc.body || doc.documentElement).appendChild(box);
						} catch (e) {
							// Last resort: the console entry below already happened.
						}
					}

					window.__seiunFatalReport = function (kind, message, stack) {
						var text = 'Kind: ' + kind + '\nMessage: ' + seiunText(message) +
							'\nStack:\n' + seiunText(stack);
						try { console.error('[SeiunEngine] fatal (' + kind + '):\n' + text); } catch (e) {}
						try { window.localStorage.setItem('seiun_last_crash', text); } catch (e) {}
						seiunOverlay('SeiunEngine 崩溃 / Crashed', text);
					};

					window.addEventListener('error', function (ev) {
						if (!ev) return;
						var where = ev.filename ? (' at ' + ev.filename + ':' + ev.lineno + ':' + ev.colno) : '';
						window.__seiunFatalReport('js_error', seiunText(ev.message) + where, ev.error);
					});

					window.addEventListener('unhandledrejection', function (ev) {
						var reason = ev ? ev.reason : null;
						window.__seiunFatalReport('js_rejection', seiunText(reason), reason);
					});
				})();
			");
		}
		catch (e:Dynamic) {}
		#end
	}

	/**
	 * Hand one failure to the page: console + localStorage + overlay.
	 * Called from Main.reportCrash(); a no-op off HTML5.
	 */
	public static function report(kind:String, message:String, stack:String):Void
	{
		#if js
		try
		{
			Syntax.code("window.__seiunFatalReport && window.__seiunFatalReport({0}, {1}, {2})", kind, message, stack);
		}
		catch (e:Dynamic) {}
		#end
	}
}
