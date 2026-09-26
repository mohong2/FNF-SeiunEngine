package online_server;

import haxe.crypto.Base64;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Thread;

/**
 * SMTP config (--smtp-* flags or the [smtp] section of <data-dir>/config.toml; .env is not
 * read). `ssl` means implicit TLS (smtps, port 465): the whole connection is TLS from the
 * first byte. STARTTLS on 587 would need to upgrade an already-connected plaintext socket,
 * which Haxe 4.2.5's sys.ssl.Socket cannot do, so only 465 is supported.
 */
typedef SmtpConfig = {
	var host:String;
	var port:Int;
	var user:String;
	var pass:String;
	var from:String;
	var ?ssl:Bool;
}

/**
 * Verification codes live in an in-memory map for 10 minutes and are always appended to
 * <data-dir>/mail.log; with --smtp-* or [smtp] they are also sent on a background thread.
 * Implicit TLS on 465 works via sys.ssl.Socket; STARTTLS on 587/25 is unsupported (std cannot
 * upgrade a plaintext socket).
 */
class ServerMail {
	static var codes:Map<String, { code:String, expires:Float }> = new Map();
	static var smtp:SmtpConfig = null;
	static var outboxPath:String = null;
	static var outboxLock:sys.thread.Mutex = null;

	public static function init(dataDir:String, ?cfg:SmtpConfig):Void {
		smtp = cfg;
		outboxPath = dataDir + "/mail.log";
		outboxLock = new sys.thread.Mutex();
	}

	public static function smtpConfigured():Bool return smtp != null;

	public static function outbox():String return outboxPath;

	/** Six uppercase hex characters (3 random bytes). */
	public static function generateCode():String {
		return JsonStore.randomHex(6).toUpperCase();
	}

	/** Stores a code for 10 minutes with lazy expiry (no timer). */
	public static function tempSetCode(email:String, code:String):Void {
		if (email == null) return;
		codes.set(email.toLowerCase(), { code: code, expires: haxe.Timer.stamp() + 600 });
	}

	/** Current valid code; an expired one is removed on lookup. */
	public static function codeOf(email:String):String {
		if (email == null) return null;
		var key = email.toLowerCase();
		var e = codes.get(key);
		if (e == null) return null;
		if (haxe.Timer.stamp() > e.expires) {
			codes.remove(key);
			return null;
		}
		return e.code;
	}

	public static function clearCode(email:String):Void {
		if (email != null) codes.remove(email.toLowerCase());
	}

	/** Compares the code and consumes it in one step. */
	public static function verifyAndConsume(email:String, code:String):Bool {
		var want = codeOf(email);
		clearCode(email);
		if (want == null || code == null) return false;
		return want == code;
	}

	/**
	 * Appends to the outbox (always), then sends the mail asynchronously when SMTP is
	 * configured. Send failures are swallowed.
	 */
	public static function sendCodeMail(email:String, code:String):Void {
		if (email == null) return;
		appendOutbox(JsonStore.isoNow() + '\t' + email + '\t' + code);
		if (smtp == null) {
			trace('[mail] code for ' + email + ' = ' + code + ' (no --smtp-*; see ' + Std.string(outboxPath) + ')');
			return;
		}
		var cfg = smtp;
		trace('[mail] sending code to ' + email + ' via ' + cfg.host + ':' + cfg.port);
		Thread.create(function() sendViaSmtp(cfg, email, code));
	}

	static function appendOutbox(line:String):Void {
		if (outboxPath == null) return;
		outboxLock.acquire();
		try {
			var dir = Path.directory(outboxPath);
			if (dir != "" && !FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			var f = File.append(outboxPath, false);
			f.writeString(line + "\n");
			f.close();
		} catch (e:Dynamic) {
			trace('[mail] outbox write failed: ' + Std.string(e));
		}
		outboxLock.release();
	}

	// ------------------------------------------------------------------
	// plaintext SMTP (best effort; failures only affect real delivery, the outbox is written)
	// ------------------------------------------------------------------

	static function sendViaSmtp(cfg:SmtpConfig, to:String, code:String):Void {
		var sock:Socket = null;
		try {
			// 587/25 speak plaintext first and expect STARTTLS, which std cannot upgrade mid-session.
			if (cfg.ssl == true && cfg.port != 465) {
				trace('[mail] note: implicit TLS is normally port 465; ' + cfg.port + ' usually wants STARTTLS (unsupported)');
			}
			// sys.ssl.Socket extends sys.net.Socket, so the session code below is shared.
			sock = (cfg.ssl == true) ? new sys.ssl.Socket() : new Socket();
			sock.connect(new Host(cfg.host), cfg.port);
			if (cfg.ssl == true) trace('[mail] TLS handshake ok with ' + cfg.host + ':' + cfg.port);
			readReply(sock); // 220 greeting
			sendLine(sock, "EHLO seiunengine.local");
			readReply(sock);

			if (cfg.user != null && cfg.user != "") {
				sendLine(sock, "AUTH LOGIN");
				readReply(sock);
				sendLine(sock, Base64.encode(Bytes.ofString(cfg.user)));
				readReply(sock);
				sendLine(sock, Base64.encode(Bytes.ofString(cfg.pass == null ? "" : cfg.pass)));
				var auth = readReply(sock);
				if (auth >= 400) throw 'SMTP auth failed: ' + auth;
			}

			sendLine(sock, 'MAIL FROM:<' + cfg.from + '>');
			readReply(sock);
			sendLine(sock, 'RCPT TO:<' + to + '>');
			var rcpt = readReply(sock);
			if (rcpt >= 400) throw 'SMTP rcpt failed: ' + rcpt;

			sendLine(sock, "DATA");
			var data = readReply(sock);
			if (data >= 400) throw 'SMTP data failed: ' + data;

			// RFC 5322 message built by buildCodeMail(); base64 keeps DATA free of bare "." lines.
			var body = buildCodeMail(cfg, to, code);
			sock.output.writeString(body + "\r\n.\r\n");
			sock.output.flush();
			readReply(sock);

			sendLine(sock, "QUIT");
			trace('[mail] sent code to ' + to + ' via ' + cfg.host + ':' + cfg.port + (cfg.ssl == true ? ' (TLS)' : ' (plain)'));
		} catch (e:Dynamic) {
			trace('[mail] SMTP send failed: ' + Std.string(e)
				+ (cfg.ssl == true ? '' : '  (plain SMTP only: for QQ/163/Gmail set port 465 and turn SSL on)'));
		}
		if (sock != null) {
			try sock.close() catch (e:Dynamic) {}
		}
	}

	// ------------------------------------------------------------------
	// Mail body (multipart/alternative with fully inline-styled HTML)
	// ------------------------------------------------------------------

	static inline var B64_LINE_CHARS = 76;
	/** Must match the 600 s lifetime in tempSetCode(). */
	public static inline var CODE_TTL_MINUTES = 10;

	/**
	 * Build the raw RFC 5322 message for a verification code. Pure (no socket, no global
	 * state) so MailProbe can assert on the string without sending anything.
	 *
	 * multipart/alternative: a text/plain fallback plus an HTML part whose styling is
	 * entirely inline -- mail clients strip <style>, block external CSS/fonts/images and
	 * often force a light background, so the layout must survive on its own.
	 */
	public static function buildCodeMail(cfg:SmtpConfig, to:String, code:String):String {
		var nl = "\r\n";
		// 12 hex chars keep the Content-Type header short (<= 76 columns).
		var boundary = "seiun-code-" + JsonStore.randomHex(12);
		var from = (cfg == null || cfg.from == null) ? "no-reply@localhost" : cfg.from;
		var out = new StringBuf();
		out.add('From: SeiunEngine <' + from + '>' + nl);
		out.add('To: <' + to + '>' + nl);
		out.add('Subject: ' + rfc2047('SeiunEngine Verification Code / 验证码') + nl);
		out.add('MIME-Version: 1.0' + nl);
		out.add('Content-Type: multipart/alternative; boundary="' + boundary + '"' + nl);
		out.add(nl);
		out.add('--' + boundary + nl);
		out.add('Content-Type: text/plain; charset=utf-8' + nl);
		out.add('Content-Transfer-Encoding: base64' + nl);
		out.add(nl);
		out.add(base64Body(codeMailText(code)));
		out.add('--' + boundary + nl);
		out.add('Content-Type: text/html; charset=utf-8' + nl);
		out.add('Content-Transfer-Encoding: base64' + nl);
		out.add(nl);
		out.add(base64Body(codeMailHtml(code)));
		out.add('--' + boundary + '--');
		return out.toString();
	}

	/** RFC 2047 encoded-word; non-ASCII headers must not go out raw. */
	public static function rfc2047(value:String):String {
		return '=?UTF-8?B?' + Base64.encode(Bytes.ofString(value)) + '?=';
	}

	/** base64 the UTF-8 body and wrap it to 76-char CRLF lines (RFC 2045). */
	static function base64Body(text:String):String {
		var b64 = Base64.encode(Bytes.ofString(text));
		var out = new StringBuf();
		var i = 0;
		while (i < b64.length) {
			var end = i + B64_LINE_CHARS;
			if (end > b64.length) end = b64.length;
			out.add(b64.substr(i, end - i) + "\r\n");
			i = end;
		}
		return out.toString();
	}

	static function codeMailText(code:String):String {
		var nl = "\r\n";
		return 'SeiunEngine 验证码 / Verification Code' + nl + nl
			+ '你的验证码是 / Your verification code is:' + nl + nl
			+ '    ' + code + nl + nl
			+ '验证码 ' + CODE_TTL_MINUTES + ' 分钟内有效，请勿转发给他人。' + nl
			+ 'This code expires in ' + CODE_TTL_MINUTES + ' minutes. Do not share it with anyone.' + nl + nl
			+ '若非本人操作，请直接忽略本邮件。' + nl
			+ 'If you did not request this code, you can safely ignore this email.' + nl + nl
			+ '--' + nl
			+ 'SeiunEngine · by mo_hong' + nl
			+ 'https://github.com/mohong2/FNF-SeiunEngine' + nl;
	}

	/**
	 * Light-background HTML for the code. Table layout + style="" only: no <style>,
	 * no external CSS/font/image, no @import, no url(). Violet is accent only.
	 */
	static function codeMailHtml(code:String):String {
		var font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,'PingFang SC','Microsoft YaHei',sans-serif";
		var mono = "Consolas,'SFMono-Regular',Menlo,Monaco,'Courier New',monospace";
		var safe = escapeHtml(code);
		var h = new StringBuf();
		h.add('<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>SeiunEngine</title></head>');
		h.add('<body style="margin:0;padding:0;background:#f4f5f8;">');
		h.add('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f4f5f8;padding:28px 12px;"><tr><td align="center">');
		h.add('<table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0" style="width:520px;max-width:520px;background:#ffffff;border:1px solid #e3e5ec;border-radius:12px;font-family:' + font + ';">');
		h.add('<tr><td style="height:4px;line-height:4px;font-size:0;background:#7c5cff;">&nbsp;</td></tr>');
		h.add('<tr><td style="padding:26px 32px 0 32px;"><div style="font-size:13px;letter-spacing:2px;color:#7c5cff;font-weight:bold;">SEIUNENGINE</div>');
		h.add('<div style="font-size:20px;line-height:28px;color:#1b1e26;font-weight:bold;padding-top:6px;">验证码 / Verification Code</div></td></tr>');
		h.add('<tr><td style="padding:20px 32px 0 32px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f5f2ff;border:1px solid #7c5cff;border-radius:10px;"><tr><td align="center" style="padding:18px 12px;">');
		h.add('<div style="font-family:' + mono + ';font-size:34px;line-height:40px;font-weight:bold;letter-spacing:8px;color:#4a2fd0;">' + safe + '</div>');
		h.add('</td></tr></table></td></tr>');
		h.add('<tr><td style="padding:20px 32px 0 32px;font-size:14px;line-height:22px;color:#3c4048;">');
		h.add('请在页面中原样填写上面的验证码。<br>Enter the code above exactly as shown.');
		h.add('<div style="height:10px;line-height:10px;font-size:0;">&nbsp;</div>');
		h.add('<span style="color:#6b7280;">验证码 <b style="color:#3c4048;">' + CODE_TTL_MINUTES + ' 分钟</b>内有效，请勿转发给他人。<br>This code expires in ' + CODE_TTL_MINUTES + ' minutes. Do not share it with anyone.</span>');
		h.add('</td></tr>');
		h.add('<tr><td style="padding:16px 32px 0 32px;font-size:13px;line-height:20px;color:#6b7280;">若非本人操作，请直接忽略本邮件。<br>If you did not request this code, you can safely ignore this email.</td></tr>');
		h.add('<tr><td style="padding:24px 32px 26px 32px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-top:1px solid #e8eaf0;"><tr><td style="padding-top:16px;font-size:12px;line-height:18px;color:#8a90a0;">');
		h.add('SeiunEngine · by <b style="color:#5b6070;">mo_hong</b><br>');
		h.add('<a href="https://github.com/mohong2/FNF-SeiunEngine" style="color:#7c5cff;text-decoration:none;">github.com/mohong2/FNF-SeiunEngine</a>');
		h.add('</td></tr></table></td></tr>');
		h.add('</table></td></tr></table></body></html>');
		return h.toString();
	}

	static function escapeHtml(s:String):String {
		return s.split('&').join('&amp;').split('<').join('&lt;').split('>').join('&gt;').split('"').join('&quot;');
	}

	static function sendLine(sock:Socket, line:String):Void {
		sock.output.writeString(line + "\r\n");
		sock.output.flush();
	}

	/** Reads one (possibly multi-line) SMTP reply and returns its status code. */
	static function readReply(sock:Socket):Int {
		var code = 0;
		while (true) {
			var line = sock.input.readLine();
			if (line == null) break;
			if (line.length < 4) continue;
			var parsed = Std.parseInt(line.substr(0, 3));
			if (parsed != null) code = parsed;
			// "250-..." means more lines follow; "250 ..." ends the reply.
			if (line.charAt(3) == ' ') break;
		}
		return code;
	}
}
