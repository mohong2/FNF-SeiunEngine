/* SeiunEngine server console - zero dependency frontend. */
'use strict';

const $ = (sel, root) => (root || document).querySelector(sel);
const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
const esc = (v) => String(v == null ? '' : v).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const num = (v) => (v == null ? '-' : Number(v).toLocaleString('en-US'));
const fixed = (v, n) => (v == null ? '-' : Number(v).toFixed(n == null ? 2 : n));
const int = (v) => (v == null || v === '' ? '-' : String(Math.round(Number(v))));
const pill = (text, kind) => '<span class="pill ' + (kind || '') + '">' + esc(text) + '</span>';

const state = { sess: null, route: 'overview', config: null, tick: null, errors: [], search: '', localReadOnly: false, logs: { source: 'actions', lines: 200, auto: false } };

/* ---------------- transport ---------------- */

function basic(id, token) { return 'Basic ' + btoa(id + ':' + token); }

async function api(path, opts) {
  opts = opts || {};
  const method = opts.method || 'GET';
  // Local read-only mode (server ruling D-R3-5): the server refuses these anyway, but the page
  // must say so visibly instead of quietly failing the write.
  if (state.localReadOnly && (method !== 'GET' || path.indexOf('/api/admin/') === 0)) {
    const msg = '本机只读模式：' + method + ' ' + path + ' 已拒绝（只能查看） Local read-only mode refuses ' + method + ' ' + path;
    note(msg, 'bad');
    toast(msg, 'bad');
    throw { status: 0, data: { error: msg } };
  }
  const headers = { 'Content-Type': 'application/json' };
  if (state.sess) headers['Authorization'] = basic(state.sess.id, state.sess.token);
  let res, text = '';
  try {
    res = await fetch(path, { method: method, headers, body: opts.body === undefined ? undefined : JSON.stringify(opts.body) });
    text = await res.text();
  } catch (e) {
    note('网络错误 ' + path + ': ' + e.message, 'bad');
    throw { status: 0, data: { error: String(e) } };
  }
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { data = text; }
  if (!res.ok) {
    const msg = (data && data.error) ? data.error : text;
    note(res.status + ' ' + path + ' -- ' + msg, 'bad');
    throw { status: res.status, data: data };
  }
  return data;
}

function note(message, kind) {
  state.errors.unshift({ at: new Date().toLocaleTimeString(), message: String(message), kind: kind || '' });
  if (state.errors.length > 40) state.errors.pop();
  const el = document.getElementById('bell-count');
  if (el) { el.textContent = String(state.errors.length); el.classList.toggle('hidden', state.errors.length === 0); }
}

function toast(message, kind) {
  const box = $('#toasts');
  const el = document.createElement('div');
  el.className = 'toast ' + (kind || '');
  el.textContent = message;
  box.appendChild(el);
  setTimeout(() => {
    el.classList.add('leaving');
    setTimeout(() => el.remove(), 230);
  }, 6000);
}

/* ---------------- auth ---------------- */

function saveSession(s) { state.sess = s; localStorage.setItem('seiun.console', JSON.stringify(s)); }
function loadSession() { try { return JSON.parse(localStorage.getItem('seiun.console') || 'null'); } catch (e) { return null; } }
function logout() { localStorage.removeItem('seiun.console'); state.sess = null; location.reload(); }

async function verifySession() {
  const data = await api('/api/console/status');
  state.sess.name = data.me.name;
  state.sess.role = data.me.role;
  saveSession(state.sess);
  return data;
}

async function boot() {
  bindLogin();
  bindChrome();
  const initial = (location.hash || '').replace('#/', '');
  if (PAGES[initial]) state.route = initial;

  // Always probe WITHOUT the stored credential before trusting a session (D-R3-5). The loopback
  // read-only bypass ignores the Authorization header, so with a stale "seiun.console" entry for
  // this origin verifySession() would answer 200 with the synthetic account and the page would
  // render as signed in, hiding read-only mode. The probe decides on its own when nothing is stored.
  const probe = await probeStatus();
  const sess = loadSession();

  if (!sess || !sess.id) {
    if (probe.ok && isLocalReadOnly(probe.data)) { enterLocalReadOnly(probe.data); return; }
    showLogin(probe.error ? '网络错误 Network error: ' + probe.error : '');
    return;
  }

  // A stored session only counts if the server answers with a REAL account. A read-only answer means
  // the server ignored the credential (loopback bypass), so the stored session is stale or belongs to
  // another server on this origin: read-only mode wins and the credential is not used.
  state.sess = sess;
  state.localReadOnly = false;
  $('#local-ro').classList.add('hidden');
  let data = null;
  try {
    data = await api('/api/console/status');
  } catch (e) { showLogin('登录已失效：' + (e.data && e.data.error ? e.data.error : e.status)); return; }
  if (isLocalReadOnly(data)) {
    // Stop sending the stale credential; localStorage is deliberately left untouched so a later
    // visit to a server that does recognise it still works.
    state.sess = null;
    enterLocalReadOnly(data);
    return;
  }
  state.sess.name = data.me.name;
  state.sess.role = data.me.role;
  saveSession(state.sess);
  $('#login').classList.add('hidden');
  $('#app').classList.remove('hidden');
  $('#app').classList.add('app-in');
  $('#me-name').textContent = state.sess.name || state.sess.id;
  $('#me-avatar').textContent = (state.sess.name || '?').slice(0, 1).toUpperCase();
  renderSidebar();
  route();
}

function showLogin(msg) {
  state.localReadOnly = false;
  $('#local-ro').classList.add('hidden');
  $('#app').classList.add('hidden');
  $('#login').classList.remove('hidden');
  if (msg) $('#login-msg').textContent = msg;
}

/*
 * Local read-only mode (user ruling D-R3-5). The embedded LAN host has no admin account, so its
 * server answers GET /api/console/* from 127.0.0.1 without a credential: the status probe returns
 * 200 with localReadOnly = true. A dedicated server (or any other peer) returns 401 here, and the
 * normal login wall stays.
 *
 * probeStatus() sends no Authorization header on purpose and always runs before the stored session
 * is trusted, see boot().
 */
async function probeStatus() {
  try {
    const res = await fetch('/api/console/status', { method: 'GET' });
    if (res.status !== 200) return { ok: false, status: res.status };
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    return { ok: true, status: 200, data: data };
  } catch (e) {
    return { ok: false, status: 0, error: e.message };
  }
}

/** True when a status payload is the synthetic loopback read-only session, never a real account. */
function isLocalReadOnly(data) {
  return !!data && (data.localReadOnly === true || (data.me && data.me.id === 'local-console'));
}

function enterLocalReadOnly(data) {
  state.localReadOnly = true;
  state.sess = null;
  state.me = data.me || null;
  $('#local-ro').classList.remove('hidden');
  $('#login').classList.add('hidden');
  $('#app').classList.remove('hidden');
  $('#app').classList.add('app-in');
  $('#me-name').textContent = '本机只读 local read-only';
  $('#me-avatar').textContent = 'R';
  renderSidebar();
  route();
}

function bindLogin() {
  $$('#login .tab').forEach((tab) => tab.addEventListener('click', () => {
    $$('#login .tab').forEach((t) => t.classList.toggle('active', t === tab));
    $('#tab-email').classList.toggle('hidden', tab.dataset.tab !== 'email');
    $('#tab-token').classList.toggle('hidden', tab.dataset.tab !== 'token');
  }));
  $('#btn-send-code').addEventListener('click', async () => {
    const email = $('#login-email').value.trim();
    if (!email) { $('#login-msg').textContent = '先填邮箱 Enter an email first'; return; }
    try {
      const r = await api('/api/auth/login', { method: 'POST', body: { email: email } });
      $('#login-msg').textContent = r && r.known === false ? '该邮箱没有账号（注册请用游戏内或 POST /api/auth/register）' : '验证码已发送（无 SMTP 时见 <data-dir>/mail.log）';
    } catch (e) { $('#login-msg').textContent = '发送失败：' + (e.data && e.data.error ? e.data.error : e.status); }
  });
  $('#btn-login-code').addEventListener('click', async () => {
    const email = $('#login-email').value.trim();
    const code = $('#login-code').value.trim();
    if (!email || !code) { $('#login-msg').textContent = '邮箱和验证码都要填 Email and code are both required'; return; }
    await loginWith({ email: email, code: code });
  });
  $('#btn-login-token').addEventListener('click', async () => {
    const id = $('#login-id').value.trim();
    const token = $('#login-token').value.trim();
    if (!id || !token) { $('#login-msg').textContent = 'id 和 token 都要填 id and token are both required'; return; }
    state.sess = { id: id, token: token, name: id };
    await loginCheck();
  });
  $('#login-email').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#btn-send-code').click(); });
  $('#login-code').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#btn-login-code').click(); });
}

async function loginWith(body) {
  try {
    const r = await api('/api/auth/login', { method: 'POST', body: body });
    if (!r || !r.id) { $('#login-msg').textContent = '登录响应异常 Unexpected login response'; return; }
    state.sess = { id: r.id, token: r.token, name: r.id };
    await loginCheck();
  } catch (e) { $('#login-msg').textContent = '登录失败：' + (e.data && e.data.error ? e.data.error : e.status); }
}

async function loginCheck() {
  try {
    await verifySession();
    location.hash = '#/overview';
    boot();
  } catch (e) {
    state.sess = null;
    localStorage.removeItem('seiun.console');
    $('#login-msg').textContent = (e.status === 401) ? '该账号没有控制台权限（服务端要用 --admin-email 指定它）' : ('校验失败：' + (e.data && e.data.error ? e.data.error : e.status));
  }
}

/* ---------------- chrome ---------------- */

/* Third item = needs /api/admin/*: hidden in local read-only mode, where those routes stay 401. */
const NAV = [
  { group: '运行 Runtime', items: [['overview', '概览 Overview'], ['rooms', '房间 Rooms'], ['players', '玩家 Players'], ['connections', '连接 Connections']] },
  { group: '数据 Data', items: [['accounts', '账号 Accounts'], ['leaderboard', '排行榜 Leaderboard'], ['clubs', '俱乐部 Clubs'], ['mods', 'mod 仓库 Mod repo'], ['comments', '评论 Comments']] },
  { group: '运维 Operations', items: [['config', '配置 Config'], ['iplock', 'IP 锁与重连 IP lock & reconnect'], ['cooldown', '冷却 Cooldowns'], ['logs', '日志 Logs'], ['tasks', '任务 Tasks', true]] },
  { group: '个人 Personal', items: [['admin', 'admin 账号 Admin accounts', true], ['about', '关于 About']] }
];

function renderSidebar(counts) {
  counts = counts || {};
  let html = '';
  for (const g of NAV) {
    html += '<h4>' + esc(g.group) + '</h4>';
    for (const [route, label, needsAdmin] of g.items) {
      if (state.localReadOnly && needsAdmin) continue;
      const c = counts[route] != null ? '<span class="cnt">' + esc(counts[route]) + '</span>' : '';
      html += '<a data-route="' + route + '" class="' + (state.route === route ? 'active' : '') + '"><span>' + esc(label) + '</span>' + c + '</a>';
    }
  }
  $('#sidebar').innerHTML = html;
}

function highlight() {
  $$('#sidebar a[data-route]').forEach((a) => a.classList.toggle('active', a.dataset.route === state.route));
  $$('.topnav a').forEach((a) => a.classList.toggle('active', a.dataset.route === state.route));
}

function bindChrome() {
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-route]');
    if (el) { e.preventDefault(); go(el.dataset.route); return; }
    if (!e.target.closest('#bell-panel') && !e.target.closest('#btn-bell')) $('#bell-panel').classList.add('hidden');
  });
  $('#btn-bell').addEventListener('click', renderBell);
  $('#me-chip').addEventListener('click', () => go('admin'));
  $('#global-search').addEventListener('input', (e) => { state.search = e.target.value.toLowerCase(); filterRows(); });
  document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); $('#global-search').focus(); }
  });
}

function filterRows() {
  $$('#content tr[data-search]').forEach((tr) => {
    tr.style.display = (state.search === '' || tr.dataset.search.indexOf(state.search) >= 0) ? '' : 'none';
  });
}

function go(routeName) {
  state.route = routeName;
  if (location.hash !== '#/' + routeName) location.hash = '#/' + routeName;
  renderSidebar();
  route();
}

function renderBell() {
  const panel = $('#bell-panel');
  if (!panel.classList.contains('hidden')) { panel.classList.add('hidden'); return; }
  let html = '<h4>通知（最近 ' + state.errors.length + ' 条失败/提示）</h4>';
  if (state.errors.length === 0) html += '<div class="item">没有异常请求。</div>';
  for (const e of state.errors) html += '<div class="item">' + esc(e.message) + '<small>' + esc(e.at) + '</small></div>';
  panel.innerHTML = html;
  panel.classList.remove('hidden');
}

/* ---------------- router ---------------- */

/** Placeholder that keeps the layout stable while a route loads. */
function skeletonHtml() {
  let h = '<div class="page-title"><div><div class="skeleton big" style="width:190px"></div>' +
    '<div class="skeleton" style="width:330px;margin-top:10px"></div></div></div><div class="grid c4">';
  for (let i = 0; i < 4; i++) h += '<div class="stat"><div class="skeleton" style="width:62%"></div>' +
    '<div class="skeleton big" style="width:44%;margin-top:12px"></div></div>';
  h += '</div><div class="card loading-card"><div class="skeleton" style="width:26%"></div>' +
    '<div class="skeleton"></div><div class="skeleton" style="width:78%"></div>' +
    '<div class="skeleton" style="width:52%"></div></div>';
  return h;
}

let animTimer = null;

/**
 * Render the current route.
 * opts.silent = background refresh (auto-poll): keep the old DOM until the new one is
 * ready, keep the scroll offset, skip the entrance animation and leave the rail alone.
 */
async function route(opts) {
  opts = opts || {};
  const silent = !!opts.silent;
  const page = PAGES[state.route] || PAGES.overview;
  if (state.tick) { clearInterval(state.tick); state.tick = null; }
  const content = $('#content');
  const keptScroll = content.scrollTop;
  if (!silent) content.innerHTML = skeletonHtml();
  let failed = false;
  try {
    const html = await page.render();
    content.innerHTML = html;
    if (page.after) page.after();
    filterRows();
  } catch (e) {
    failed = true;
    content.innerHTML = '<div class="card"><h3>加载失败 Load failed</h3><pre class="log">' + esc(e && e.data ? JSON.stringify(e.data, null, 2) : String(e)) + '</pre></div>';
  }
  if (silent && !failed) {
    content.scrollTop = keptScroll;
  } else {
    // Restart the entrance animation on every real navigation.
    content.classList.remove('anim');
    void content.offsetWidth;
    content.classList.add('anim');
    clearTimeout(animTimer);
    animTimer = setTimeout(() => content.classList.remove('anim'), 1000);
  }
  if (!silent) renderRail();
  highlight();
}

function title(text, desc, right) {
  return '<div class="page-title"><div><h2>' + esc(text) + '</h2>' + (desc ? '<div class="desc">' + esc(desc) + '</div>' : '') + '</div><div>' + (right || '') + '</div></div>';
}

function table(cols, rows, actions) {
  if (!rows || rows.length === 0) return '<div class="empty">没有数据。</div>';
  let html = '<div class="tablewrap"><table><thead><tr>';
  for (const c of cols) html += '<th' + (c.mono ? ' class="mono"' : '') + '>' + esc(c.label) + '</th>';
  if (actions) html += '<th class="act"></th>';
  html += '</tr></thead><tbody>';
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    const search = cols.map((c) => String(c.get(r) == null ? '' : c.get(r))).join(' ').toLowerCase();
    html += '<tr data-search="' + esc(search) + '">';
    for (const c of cols) html += '<td' + (c.mono ? ' class="mono"' : '') + '>' + c.render(r, i) + '</td>';
    if (actions) html += '<td class="act" style="text-align:right;white-space:nowrap">' + actions(r) + '</td>';
    html += '</tr>';
  }
  return html + '</tbody></table></div>';
}

function pager(page, total, size, routeName) {
  const pages = Math.max(1, Math.ceil(total / size));
  return '<div class="pager"><button data-page="' + (page - 1) + '" ' + (page <= 0 ? 'disabled' : '') + '>上一页 Prev</button>' +
    '<span>第 ' + (page + 1) + ' / ' + pages + ' 页 · 共 ' + total + ' 条</span>' +
    '<button data-page="' + (page + 1) + '" ' + (page + 1 >= pages ? 'disabled' : '') + '>下一页 Next</button></div>';
}

/* ---------------- pages ---------------- */

function statCard(label, value, foot, kind) {
  return '<div class="stat"><div class="label">' + esc(label) + '</div><div class="value">' + (kind || esc(value)) + '</div><div class="foot">' + esc(foot || '') + '</div></div>';
}

const PAGES = {
  overview: {
    render: async () => {
      const s = await api('/api/console/status');
      const logs = await api('/api/console/logs?lines=10');
      const up = s.process.uptime;
      const mem = s.process.memory;
      const mb = (v) => (Number(v) / 1048576).toFixed(1) + ' MB';
      const memText = mem ? (mem.heap != null ? mb(mem.heap) : (mem.heapSize != null ? mb(mem.heapSize) : 'n/a')) : 'n/a';
      let html = title('概览 Overview', '进程 ' + (s.version || '') + ' · 协议 v' + s.protocol + ' · data-dir ' + s.process.dataDir);
      html += '<div class="grid c4">';
      html += statCard('运行时长', (up / 3600).toFixed(2) + ' h', '≈ ' + Math.round(up / 60) + ' 分钟');
      html += statCard('在线玩家', s.rooms.players, '房间 ' + s.rooms.total + ' 个 · network ' + s.rooms.network + ' 人');
      html += statCard('HTTP 请求', num(s.process.httpRequests), '错误 ' + num(s.process.httpErrors) + ' 次');
      html += statCard('WS 连接 / 累计', num(s.process.wsConnections), '累计 attach ' + num(s.process.wsAccepted));
      html += '</div><div class="grid c4" style="margin-top:14px">';
      html += statCard('账号 Accounts', num(s.stores.accounts), '成绩 Scores ' + num(s.stores.scores) + ' 条');
      html += statCard('俱乐部 Clubs', num(s.stores.clubs), 'mod ' + num(s.stores.mods) + ' 个');
      html += statCard('举报 / 警告', num(s.stores.reports) + ' / ' + num(s.stores.warns), '操作日志 ' + num(s.stores.actionLog) + ' 条');
      html += statCard('内存 Memory', memText, 'neko GC 统计（不还给 OS） neko GC stats (never returned to the OS)');
      html += '</div>';
      html += '<div class="grid c2" style="margin-top:14px">' +
        '<div class="card"><h3>生效配置 Effective config</h3><div class="sub">' + esc(s.process.configPath) + (s.configFile ? '（文件存在） (file exists)' : '（还没落盘，显示默认值） (not on disk yet; showing defaults)') + '</div>' +
        '<div class="kv">' +
        kv('IP 锁 IP lock', s.config.ipLock ? '开启，上限 ' + s.config.ipLockLimit : '关闭') +
        kv('重连保护 Reconnect guard', s.config.reconnectGuard ? '开启，上限 ' + s.config.reconnectLimit : '关闭') +
        kv('房间上限 Max rooms', s.config.maxClients) +
        kv('公告 Announcement', s.announcement || '（空） (empty)') +
        '</div></div>' +
        '<div class="card"><h3>最近操作日志 Recent action log</h3><div class="sub">' + esc(logs.path || '') + '</div><pre class="log">' +
        esc((logs.lines || []).join('\n') || '（空） (empty)') + '</pre></div></div>';
      if (s.configWarnings && s.configWarnings.length) html += '<div class="card"><h3>配置告警 Config warnings</h3><pre class="log">' + esc(s.configWarnings.join('\n')) + '</pre></div>';
      return html;
    },
    after: () => { state.tick = setInterval(() => { if (state.route === 'overview') route({ silent: true }); }, 5000); }
  },

  rooms: {
    render: async () => {
      const d = await api('/api/console/rooms');
      let html = title('房间 Rooms', '共 ' + d.rooms.length + ' 个游戏房（network 常驻房不在列表里）');
      html += '<div class="card"><h3>游戏房 Game rooms</h3>' + table([
        { label: '房间 Rooms', get: (r) => r.roomId, render: (r) => '<b>' + esc(r.roomId) + '</b>' },
        { label: '玩家 Players', get: (r) => r.players.length, render: (r) => r.players.length + ' / ' + r.maxClients },
        { label: '歌曲 Song', get: (r) => r.song, render: (r) => esc(r.song || '-') + (r.diff ? ' <span class="pill">' + esc(r.diff) + '</span>' : '') },
        { label: '舞台 / mod Stage / mod', get: (r) => (r.stageName || '') + (r.modDir || ''), render: (r) => esc((r.stageName || '-') + (r.modDir ? ' · ' + r.modDir : '')) },
        { label: '状态 Status', get: (r) => String(r.isStarted) + r.isPrivate + r.networkOnly, render: (r) => (r.isStarted ? pill('开局 Started', 'acc') : pill('等待 Waiting')) + ' ' + (r.isPrivate ? pill('私有 Private') : '') + ' ' + (r.networkOnly ? pill('仅联机 Online only') : '') },
        { label: '血量 Health', get: (r) => r.health, mono: true, render: (r) => fixed(r.health, 3) },
        { label: '房主 Host', get: (r) => (r.hostName || r.host || ''), render: (r) => (r.hostName ? esc(r.hostName) : (r.host ? '<span class="pill">stale</span> ' + esc(r.host) : '-')) },
        { label: '待重连 Pending reconnect', get: (r) => r.pendingReconnect, render: (r) => String(r.pendingReconnect) },
        { label: '会话 Sessions', get: (r) => r.sessions, render: (r) => String(r.sessions) }
      ], d.rooms, (r) => '<button class="btn danger sm" data-close="' + esc(r.roomId) + '">关闭房间 Close room</button>') + '</div>';
      html += '<div class="card"><h3>network 房（房间号 0） network room (id 0)</h3><div class="sub">聊天 / 邀请 / 公告推送用的常驻房间 the persistent room used for chat / invites / announcements</div>' +
        table([
          { label: 'sid', get: (m) => m.sid, mono: true, render: (m) => esc(m.sid) },
          { label: '昵称 Nickname', get: (m) => m.name, render: (m) => esc(m.name || '-') },
          { label: 'networkName', get: (m) => m.networkName, render: (m) => esc(m.networkName || '-') }
        ], d.network.members) + '</div>';
      return html;
    },
    after: () => {
      $$('[data-close]').forEach((b) => b.addEventListener('click', async () => {
        const roomId = b.dataset.close;
        if (!confirm('确定强制关闭房间 ' + roomId + '？房间里的连接会被踢出且不能重连。')) return;
        await api('/api/console/room/close', { method: 'POST', body: { roomId: roomId } });
        toast('房间 ' + roomId + ' 已关闭', 'ok');
        route();
      }));
    }
  },

  players: {
    render: async () => {
      const d = await api('/api/console/players');
      return title('玩家 Players', '当前共有 ' + d.total + ' 个已 ack 的连接（含 network 房）') + '<div class="card">' + table([
        { label: '房间 Rooms', get: (p) => p.roomId, render: (p) => '<b>' + esc(p.roomId) + '</b>' },
        { label: 'sid', get: (p) => p.sid, mono: true, render: (p) => esc(p.sid) },
        { label: '名字 Name', get: (p) => p.name, render: (p) => esc(p.name || '-') + (p.isHost ? ' ' + pill('房主 Host', 'acc') : '') },
        { label: 'ping', get: (p) => p.ping, mono: true, render: (p) => int(p.ping) },
        { label: '分数 Score', get: (p) => p.score, mono: true, render: (p) => num(p.score) },
        { label: 'miss', get: (p) => p.misses, mono: true, render: (p) => int(p.misses) },
        { label: 'combo', get: (p) => p.maxCombo, mono: true, render: (p) => int(p.maxCombo) },
        { label: 'botplay', get: (p) => String(p.botplay), render: (p) => (p.botplay ? pill('ON', 'warn') : '-') },
        { label: '准备 / 结束 Ready / Ended', get: (p) => String(p.isReady) + p.hasEnded, render: (p) => (p.isReady ? pill('ready', 'ok') : pill('wait')) + ' ' + (p.hasEnded ? pill('ended') : '') },
        { label: '状态 Status', get: (p) => p.status, render: (p) => esc(p.status || '-') }
      ], d.rows, (p) => '<button class="btn danger sm" data-kick="' + esc(p.name || '') + '">踢出 Kick</button>') + '</div>';
    },
    after: () => bindKickButtons()
  },

  connections: {
    render: async () => {
      const d = await api('/api/console/rooms');
      let rows = [];
      for (const r of d.rooms) {
        rows.push({ kind: '游戏房 ' + r.roomId, sid: '-', name: r.hostName || r.host || '-', extra: '会话 ' + r.sessions + ' · 连接 ' + r.players.length + ' · 待重连 ' + r.pendingReconnect });
        for (const p of r.players) rows.push({ kind: '游戏房 ' + r.roomId, sid: p.sid, name: p.name || '-', extra: p.acked ? 'acked' : '未 ack Unacked' });
      }
      for (const m of d.network.members) rows.push({ kind: 'network', sid: m.sid, name: m.name || '-', extra: m.networkName || '' });
      return title('连接 Connections', 'WS 连接快照（attach 计数见概览）') + '<div class="card">' + table([
        { label: '位置 Position', get: (r) => r.kind, render: (r) => esc(r.kind) },
        { label: 'sid', get: (r) => r.sid, mono: true, render: (r) => esc(r.sid) },
        { label: '名字 Name', get: (r) => r.name, render: (r) => esc(r.name) },
        { label: '备注 Note', get: (r) => r.extra, render: (r) => esc(r.extra) }
      ], rows) + '</div>';
    }
  },

  accounts: {
    render: async () => {
      const page = state.data.page || 0;
      const q = encodeURIComponent($('#global-search') ? $('#global-search').value : '');
      const d = await api('/api/console/accounts?page=' + page + '&size=25&q=' + q);
      state.data.page = page;
      const rows = d.rows;
      return title('账号 Accounts', '共 ' + d.total + ' 个账号（token 不下发）', '<button class="btn sm" data-refresh="1">刷新 Refresh</button>') + '<div class="card">' + table([
        { label: '名字 Name', get: (a) => a.name, render: (a) => '<b>' + esc(a.name) + '</b>' },
        { label: 'id', get: (a) => a.id, mono: true, render: (a) => esc(a.id) },
        { label: '邮箱 Email', get: (a) => a.email, render: (a) => esc(a.email || '-') },
        { label: '角色 Role', get: (a) => a.role, render: (a) => a.role === 'Admin' ? pill('Admin', 'acc') : (a.banned ? pill('Banned', 'bad') : pill(a.role)) },
        { label: '积分 Points', get: (a) => a.points, mono: true, render: (a) => fixed(a.points, 1) },
        { label: '平均准度 Avg. accuracy', get: (a) => a.avgAccuracy, mono: true, render: (a) => fixed(a.avgAccuracy, 3) },
        { label: '俱乐部 / IP', get: (a) => (a.club || '') + (a.ips || []).join(','), render: (a) => esc(a.club || (a.ips || [])[0] || '-') }
      ], rows, (a) => {
        let act = '<button class="btn sm" data-grant="' + esc(a.name) + '">角色 Role</button> ';
        act += a.banned ? '<button class="btn sm" data-unban="' + esc(a.name) + '">解禁 Unban</button>'
          : '<button class="btn danger sm" data-ban="' + esc(a.name) + '">封禁 Ban</button>';
        act += ' <button class="btn sm" data-revoke="' + esc(a.name) + '">吊销凭据 Revoke</button>';
        return act;
      }) + pager(page, d.total, d.size) + '</div>';
    },
    after: () => {
      bindPager('accounts');
      $$('[data-ban]').forEach((b) => b.addEventListener('click', async () => {
        const name = b.dataset.ban;
        const reason = prompt('封禁 ' + name + ' 的理由（至少 5 个字符）');
        if (!reason || reason.trim().length < 5) return;
        if (!confirm('封禁 ' + name + '？会清空其成绩并从 network 房移出。')) return;
        await api('/api/admin/user/ban?username=' + encodeURIComponent(name) + '&to=true&reason=' + encodeURIComponent(reason));
        toast(name + ' 已封禁', 'ok'); route();
      }));
      $$('[data-unban]').forEach((b) => b.addEventListener('click', async () => {
        await api('/api/admin/user/ban?username=' + encodeURIComponent(b.dataset.unban) + '&to=false');
        toast(b.dataset.unban + ' 已解禁', 'ok'); route();
      }));
      $$('[data-grant]').forEach((b) => b.addEventListener('click', async () => {
        const role = prompt('给 ' + b.dataset.grant + ' 的角色（Member / Helper / Moderator）', 'Helper');
        if (!role) return;
        await api('/api/admin/user/grant?username=' + encodeURIComponent(b.dataset.grant) + '&role=' + encodeURIComponent(role));
        toast('角色已改为 ' + role, 'ok'); route();
      }));
      $$('[data-revoke]').forEach((b) => b.addEventListener('click', async () => {
        const name = b.dataset.revoke;
        if (!confirm('吊销 ' + name + ' 的凭据？该账号所有设备都要重新登录，在线连接会被断开。')) return;
        const r = await api('/api/console/account/revoke?name=' + encodeURIComponent(name), { method: 'POST' });
        toast(name + ' 凭据已吊销（断开 ' + ((r && r.kicked) || 0) + ' 条连接）', 'ok'); route();
      }));
    }
  },

  leaderboard: {
    render: async () => {
      const page = state.data.page || 0;
      const d = await api('/api/console/leaderboard?page=' + page + '&size=25');
      return title('排行榜 Leaderboard', '按账号 points 排序（共 ' + d.total + ' 个）') + '<div class="card">' + table([
        { label: '#', get: (r, i) => i, mono: true, render: (r, i) => String(page * 25 + i + 1) },
        { label: '玩家 Players', get: (a) => a.name, render: (a) => '<b>' + esc(a.name) + '</b>' },
        { label: '角色 Role', get: (a) => a.role, render: (a) => esc(a.role) },
        { label: '积分 Points', get: (a) => a.points, mono: true, render: (a) => fixed(a.points, 1) },
        { label: '平均准度 Avg. accuracy', get: (a) => a.avgAccuracy, mono: true, render: (a) => fixed(a.avgAccuracy, 3) },
        { label: '局数 Rounds', get: (a) => a.games, render: (a) => int(a.games) },
        { label: '俱乐部 Clubs', get: (a) => a.club, render: (a) => esc(a.club || '-') }
      ], d.rows) + pager(page, d.total, d.size) + '</div>';
    },
    after: () => bindPager('leaderboard')
  },

  clubs: {
    render: async () => {
      const page = state.data.page || 0;
      const d = await api('/api/console/clubs?page=' + page);
      return title('俱乐部 Clubs', '共 ' + d.total + ' 个（每页 ' + d.size + '）') + '<div class="card">' + table([
        { label: 'TAG', get: (c) => c.tag, render: (c) => '<b>' + esc(c.tag) + '</b>' },
        { label: '名字 Name', get: (c) => c.name, render: (c) => esc(c.name) },
        { label: '积分 Points', get: (c) => c.points, mono: true, render: (c) => fixed(c.points, 1) },
        { label: '成员 Members', get: (c) => c.members, render: (c) => String(c.members) },
        { label: '申请中 Pending', get: (c) => c.pending, render: (c) => String(c.pending) },
        { label: '旗帜 Flag', get: (c) => String(c.banner), render: (c) => (c.banner ? pill('有 Yes', 'ok') : '-') }
      ], d.rows) + pager(page, d.total, d.size) + '</div>';
    },
    after: () => bindPager('clubs')
  },

  mods: {
    render: async () => {
      const page = state.data.page || 0;
      const q = encodeURIComponent($('#global-search') ? $('#global-search').value : '');
      const sort = state.data.modSort || 'submitted:desc';
      const d = await api('/api/console/mods?page=' + page + '&q=' + q + '&sort=' + encodeURIComponent(sort));
      const opts = ['submitted:desc', 'downloadHits:desc', 'favoritedCount:desc', 'title:asc'];
      let sel = '<select id="mod-sort" style="width:180px">' + opts.map((o) => '<option value="' + o + '"' + (o === sort ? ' selected' : '') + '>' + o + '</option>').join('') + '</select>';
      return title('mod 仓库 Mod repo', '共 ' + d.total + ' 个 mod', sel) + '<div class="card">' + table([
        { label: 'id', get: (m) => m.id, mono: true, render: (m) => esc(m.id) },
        { label: '标题 Title', get: (m) => m.title, render: (m) => '<b>' + esc(m.title) + '</b>' },
        { label: '下载命中 Download hits', get: (m) => m.downloadHits, mono: true, render: (m) => num(m.downloadHits) },
        { label: '收藏 Favorites', get: (m) => m.favoritedCount, mono: true, render: (m) => num(m.favoritedCount) },
        { label: '下载项 Downloads', get: (m) => m.downloads, render: (m) => String(m.downloads == null ? 0 : m.downloads) },
        { label: '提交时间 Submitted', get: (m) => m.submitted, render: (m) => esc(m.submitted || '-') }
      ], d.rows, (m) => '<button class="btn danger sm" data-mod-del="' + esc(m.id) + '">删除 Delete</button>') + pager(page, d.total, d.size) + '</div>';
    },
    after: () => {
      bindPager('mods');
      if ($('#mod-sort')) $('#mod-sort').addEventListener('change', (e) => { state.data.modSort = e.target.value; route(); });
      $$('[data-mod-del]').forEach((b) => b.addEventListener('click', async () => {
        const id = b.dataset.modDel;
        if (!confirm('删除 mod ' + id + '？它的全部下载项会一起消失，不可恢复。')) return;
        b.classList.add('busy');
        const r = await api('/api/console/mod/delete', { method: 'POST', body: { id: id } });
        toast('已删除 ' + (r.title || id), 'ok');
        route();
      }));
    }
  },

  comments: {
    render: async () => {
      const page = state.data.page || 0;
      const d = await api('/api/console/comments?page=' + page + '&size=25');
      return title('评论 Comments', '共 ' + d.total + ' 条歌曲评论（最新在前）') + '<div class="card">' + table([
        { label: 'id', get: (c) => c.id, mono: true, render: (c) => esc(c.id) },
        { label: '玩家 Players', get: (c) => c.player, render: (c) => esc(c.player) },
        { label: '歌曲 id Song id', get: (c) => c.songId, mono: true, render: (c) => esc(c.songId) },
        { label: '内容 Content', get: (c) => c.content, render: (c) => esc(String(c.content).slice(0, 120)) },
        { label: '时间 Time', get: (c) => c.at, render: (c) => (c.at ? new Date(Number(c.at)).toLocaleString() : '-') }
      ], d.rows) + pager(page, d.total, d.size) + '</div>';
    },
    after: () => bindPager('comments')
  },

  config: {
    render: async () => {
      state.config = await api('/api/console/config');
      return configHtml(state.config, false);
    },
    after: () => bindConfig()
  },

  iplock: {
    render: async () => {
      state.config = await api('/api/console/config');
      return configHtml(state.config, true);
    },
    after: () => bindConfig()
  },

  cooldown: {
    render: async () => {
      const d = await api('/api/console/config');
      return title('冷却 Cooldowns', 'requireAccess 的冷却注册表（同一账号 × 同一路径）', '<button class="btn danger sm" id="btn-clear-cd">清空冷却表 Clear cooldowns</button>') +
        '<div class="card"><div class="sub">写操作被拒（401/429/403）也会消耗冷却。 rejected writes (401/429/403) still consume the cooldown</div>' + table([
          { label: '路径 Path', get: (c) => c.path, mono: true, render: (c) => esc(c.path) },
          { label: '秒', get: (c) => c.seconds, mono: true, render: (c) => String(c.seconds) }
        ], d.cooldowns) + '</div>';
    },
    after: () => {
      $('#btn-clear-cd').addEventListener('click', async () => {
        await api('/api/admin/cooldown/clear');
        toast('冷却表已清空 Cooldown table cleared', 'ok');
      });
    }
  },

  logs: {
    render: async () => {
      const d = await api('/api/console/logs?source=' + state.logs.source + '&lines=' + state.logs.lines);
      const tabs = '<div class="tabs2"><button class="' + (state.logs.source === 'actions' ? 'active' : '') + '" data-src="actions">操作日志</button>' +
        '<button class="' + (state.logs.source === 'server' ? 'active' : '') + '" data-src="server">服务端日志</button>' +
        '<button class="' + (state.logs.auto ? 'active' : '') + '" data-auto="1">自动刷新 ' + (state.logs.auto ? '开 On' : '关 Off') + '</button>' +
        '<button data-refresh="1">刷新 Refresh</button></div>';
      const where = (d.path || '') + (d.encoding && d.encoding !== 'missing' ? ' · ' + d.encoding : '');
      return title('日志 Logs', where, '') + '<div class="card">' + tabs + '<pre class="log">' + esc((d.lines || []).join('\n') || '（空） (empty)') + '</pre></div>';
    },
    after: () => {
      $$('[data-src]').forEach((b) => b.addEventListener('click', () => { state.logs.source = b.dataset.src; route(); }));
      const auto = $('[data-auto]');
      if (auto) auto.addEventListener('click', () => { state.logs.auto = !state.logs.auto; route(); });
      if (state.logs.auto) state.tick = setInterval(() => { if (state.route === 'logs') route({ silent: true }); }, 5000);
    }
  },

  tasks: {
    render: async () => {
      const d = await api('/api/console/config');
      let backups = table([
        { label: '文件 Files', get: (b) => b.name, mono: true, render: (b) => esc(b.name) },
        { label: '大小 Size', get: (b) => b.size, render: (b) => num(b.size) + ' B' },
        { label: '时间 Time', get: (b) => b.mtime, render: (b) => esc(b.mtime) }
      ], d.backups);
      return title('任务 Tasks', '维护动作与 config 备份') +
        '<div class="card"><h3>公告 Announcement</h3><div class="sub">写入 config.toml 并作为 <code>notification</code> 推给 network 房的所有连接 · writes to config.toml and pushes a <code>notification</code> to every network-room connection</div>' +
        '<div class="row"><input id="ann-text" placeholder="公告内容 Announcement text" value="' + esc(d.limits.announcement || '') + '"><button class="btn primary" id="btn-ann">发布 Publish</button></div></div>' +
        '<div class="card"><h3>存储维护 Store maintenance</h3><div class="sub">等同既有 /api/admin/* 端点，不直接改 JSON 文件 same as the existing /api/admin/* endpoints; JSON files are not edited directly</div><div class="row">' +
        '<button class="btn" data-task="reloadconfig">重载 JSON 存储 Reload JSON stores</button>' +
        '<button class="btn" data-task="endweekly">结束本周 End week</button>' +
        '<button class="btn" data-task="updateweekly">重算周统计 Recompute weekly stats</button>' +
        '</div></div>' +
        '<div class="card"><h3>config.toml 备份 config.toml backups</h3><div class="sub">' + esc(d.path) + '/../backups</div>' + backups + '</div>';
    },
    after: () => {
      $$('[data-task]').forEach((b) => b.addEventListener('click', async () => {
        await api('/api/admin/' + b.dataset.task);
        toast('已执行 ' + b.dataset.task, 'ok');
      }));
      $('#btn-ann').addEventListener('click', async () => {
        const text = $('#ann-text').value;
        const r = await api('/api/console/announce', { method: 'POST', body: { text: text, broadcast: true } });
        toast('公告已保存，推送 ' + r.sent + ' 个连接', 'ok');
      });
    }
  },

  admin: {
    render: async () => {
      const s = await api('/api/console/status');
      return title('admin 账号 Admin accounts', '控制台身份完全由服务端判定（--admin-email / access 含 *）') +
        '<div class="card"><h3>' + esc(s.me.name) + '</h3><div class="sub">' + esc(s.me.id) + '</div>' +
        '<div class="kv">' + kv('角色 Role', s.me.role) + kv('access', (s.me.access || []).join(', ')) + kv('data-dir', s.process.dataDir) + kv('config.toml', s.process.configPath) + '</div>' +
        '<div class="row">' + (state.localReadOnly
          ? '<button class="btn" id="btn-reverify">刷新 Refresh</button>'
          : '<button class="btn danger" id="btn-logout">退出登录 Sign out</button><button class="btn" id="btn-reverify">重新校验 Re-verify</button>') + '</div></div>' +
        '<div class="card"><h3>启动参数 Launch args</h3><pre class="log">' + esc((s.process.args || []).join(' ') || '(none)') + '</pre></div>';
    },
    after: () => {
      if (state.localReadOnly) {
        // No credential to re-verify in local read-only mode; a reload re-probes the server.
        $('#btn-reverify').addEventListener('click', () => location.reload());
        return;
      }
      $('#btn-logout').addEventListener('click', logout);
      $('#btn-reverify').addEventListener('click', async () => { await verifySession(); toast('凭据有效 Credentials valid', 'ok'); });
    }
  },

  about: {
    render: async () => {
      const s = await api('/api/console/status');
      const rows = [
        ['作者 Author', 'mo_hong'],
        ['联机界面参考 / Online UI ref.', 'Funkin-Psych-Online (Snirozu, Apache-2.0)'],
        ['版本 Version', s.version], ['协议 Protocol', 'CLIENT_PROTOCOL ' + s.protocol], ['data-dir', s.process.dataDir],
        ['config.toml', s.process.configPath], ['日志文件', s.process.logFile], ['静态目录', s.process.webRoot],
        ['HTTP 请求', String(s.process.httpRequests)], ['WS attach', String(s.process.wsAccepted)],
        ['内存 Memory', s.process.memory ? Object.keys(s.process.memory).map((k) => k + '=' + Math.round(Number(s.process.memory[k]) / 1024) + ' KB').join(', ') : 'n/a']
      ];
      return title('关于 About', 'SeiunEngine 自带网页控制台（原生 HTML/CSS/JS，无 CDN、无 npm、离线可用）') +
        '<div class="card"><h3>服务端 Server</h3><div class="kv">' + rows.map((r) => kv(r[0], r[1])).join('') + '</div></div>' +
        '<div class="card"><h3>端点 Endpoints</h3><pre class="log">' + esc([
          'GET  /console                     本页面',
          'GET  /api/console/status          进程 / 计数 / 生效配置',
          'GET  /api/console/rooms           房间 + 玩家快照',
          'GET  /api/console/players         玩家平铺列表',
          'GET  /api/console/accounts        账号分页',
          'GET  /api/console/leaderboard     积分排行',
          'GET  /api/console/clubs          俱乐部',
          'GET  /api/console/mods           mod 仓库',
          'GET  /api/console/comments        评论',
          'GET  /api/console/logs            操作日志 / 服务端日志尾部',
          'GET  /api/console/config          生效配置 + 备份',
          'POST /api/console/config          保存 config.toml（原子写 + 备份，立即生效）',
          'POST /api/console/reload          重新读盘',
          'POST /api/console/announce        公告（存盘 + 推送）',
          'POST /api/console/kick            踢人',
          'POST /api/console/room/close      强制关房',
          'POST /api/console/mod/delete      删除 mod（含其下载项）',
          '—— 账号 / 封禁 / 警告 / 清冷却等复用既有 /api/admin/* ——'
        ].join('\n')) + '</pre></div>';
    }
  }
};

function kv(k, v) { return '<div class="k">' + esc(k) + '</div><div class="v">' + esc(v == null ? '-' : v) + '</div>'; }

function bindKickButtons() {
  $$('[data-kick]').forEach((b) => b.addEventListener('click', async () => {
    const name = b.dataset.kick;
    if (!name) { toast('该连接没有可用的昵称 This connection has no nickname', 'bad'); return; }
    if (!confirm('把 ' + name + ' 踢出房间？（不可重连）')) return;
    const r = await api('/api/console/kick', { method: 'POST', body: { name: name } });
    toast('已踢出 ' + r.kicked + ' 个连接', 'ok');
    route();
  }));
}

function bindPager(routeName) {
  $$('#content [data-page]').forEach((b) => b.addEventListener('click', () => {
    const p = parseInt(b.dataset.page, 10);
    if (p < 0) return;
    state.data.page = p;
    route();
  }));
  const r = $('#content [data-refresh]');
  if (r) r.addEventListener('click', () => route());
}

/* ---------------- config form ---------------- */

function configHtml(cfg, onlyLimits) {
  const l = cfg.limits;
  const def = cfg.codeDefaults.limits;
  let html = title(onlyLimits ? 'IP 锁与重连 IP lock & reconnect' : '配置 Config', (cfg.exists ? '' : '还没有 config.toml（当前显示代码默认值，保存后创建） ') + cfg.path,
    '<button class="btn sm" data-download="1">下载 config.toml Download config.toml</button>');

  html += '<div class="card"><h3>服务器 Server settings</h3><div class="sub">保存后立即生效；启动时命令行参数优先于本文件。 applies immediately; CLI args win over this file at startup</div>';
  html += field('announcement', '公告 Announcement', '保存后由「任务」页发布，或直接在这里改文本。 publish later from the Tasks page, or edit the text here', '<input data-lim="announcement" type="text" value="' + esc(l.announcement || '') + '">', l.announcement !== def.announcement);
  html += field('ipLock', 'IP 锁 IP lock', '同一 IP 最多 N 个 session（关闭 = 允许同机多开）。', switchHtml('ipLock', l.ipLock), l.ipLock !== def.ipLock);
  html += field('ipLockLimit', 'IP 锁上限 IP lock limit', '--ip-lock-limit 的运行时版本，默认 ' + def.ipLockLimit + '。', '<input data-lim="ipLockLimit" type="number" min="1" max="1024" value="' + l.ipLockLimit + '">', l.ipLockLimit !== def.ipLockLimit);
  html += field('reconnectGuard', '重连风暴保护 Reconnect storm guard', '同一 session 5 秒内 attach 超限即判定为风暴并移出。', switchHtml('reconnectGuard', l.reconnectGuard), l.reconnectGuard !== def.reconnectGuard);
  html += field('reconnectLimit', '重连上限 Reconnect limit', '风暴窗口内的 attach 次数上限，默认 ' + def.reconnectLimit + '。', '<input data-lim="reconnectLimit" type="number" min="1" max="10000" value="' + l.reconnectLimit + '">', l.reconnectLimit !== def.reconnectLimit);
  html += field('maxClients', '房间人数上限 Max players per room', '每个游戏房最多几个玩家，默认 ' + def.maxClients + '。', '<input data-lim="maxClients" type="number" min="1" max="64" value="' + l.maxClients + '">', l.maxClients !== def.maxClients);
  html += '</div>';

  if (!onlyLimits) {
    const sm = cfg.smtp || { host: '', port: 25, user: '', pass: '', from: '', ssl: false };
    const smDef = cfg.smtpDefined ? '（文件里已有 [smtp] 段） ([smtp] already in the file)' : '（还没配置 = 验证码只落 mail.log） (not configured; codes go to mail.log only)';
    html += '<div class="card"><h3>邮件 (SMTP)</h3><div class="sub">支持 <b>明文 SMTP</b>（内网 relay）与 <b>隐式 TLS / SMTPS</b>（QQ、163、Gmail 的 <b>465</b> 端口，把下面的 SSL 开关打开）。' +
      '⚠ 587 的 STARTTLS 不支持（Haxe 标准库没有把已连接的明文 socket 升级成 TLS 的 API），请改用 465。' +
      'host 或 from 留空 = 不发信，验证码只写 <code>&lt;data-dir&gt;/mail.log</code>。' + esc(smDef) + '</div>';
    html += field('smtpHost', 'SMTP 主机 SMTP host', 'QQ 邮箱填 smtp.qq.com；本机 relay 填 127.0.0.1。', '<input data-smtp="host" type="text" value="' + esc(sm.host || '') + '">', sm.host !== '');
    html += field('smtpSsl', '隐式 TLS (SSL) Implicit TLS (SSL)', 'QQ / 163 / Gmail 必须打开，端口用 465。没开 = 明文（只适合内网 relay）。', '<label class="switch"><input type="checkbox" data-smtp="ssl"' + (sm.ssl ? ' checked' : '') + '><i></i></label>', !!sm.ssl);
    html += field('smtpPort', '端口 Port', 'SSL 用 465；明文 relay 常见 25 / 1025 / 2525。', '<input data-smtp="port" type="number" min="1" max="65535" value="' + (sm.port || 25) + '">', (sm.port || 25) !== 25);
    html += field('smtpUser', '用户名 Username', '匿名中继留空。', '<input data-smtp="user" type="text" value="' + esc(sm.user || '') + '">', sm.user !== '');
    html += field('smtpPass', '密码 Password', '明文保存在 config.toml 里（本机文件，注意别外传）。', '<input data-smtp="pass" type="password" value="' + esc(sm.pass || '') + '">', sm.pass !== '');
    html += field('smtpFrom', '发件人 From', 'SMTP 信封 / From 头，例如 seiun@localhost。', '<input data-smtp="from" type="text" value="' + esc(sm.from || '') + '">', sm.from !== '');
    html += '</div>';
    html += '<div class="card"><h3>权限表 Permission table</h3><div class="sub">每行一个路径通配（<code>*</code> = 任意串，<code>?</code> = 单字符）。保存后按角色重新写回每个账号的 access；带 <code>*</code> 的账号（--admin-email）不动。Banned 恒为空表。</div>';
    const perms = cfg.permissions;
    for (const key of ['member', 'helper', 'moderator', 'admin', 'banned']) {
      const list = perms[key] || [];
      html += '<div class="perm-row"><div><b>' + key + '</b><div class="hintline">' + list.length + ' 条</div></div>' +
        '<textarea data-perm="' + key + '" spellcheck="false">' + esc(list.join('\n')) + '</textarea></div>';
    }
    html += '<div class="hintline">危险：把 <code>admin</code> 里的 <code>*</code> 删掉会让新登录的管理员失去 root；已带 <code>*</code> 的账号不受影响。</div></div>';
  }

  html += '<div class="card"><h3>文件 Files</h3><div class="kv">' +
    kv('路径 Path', cfg.path) + kv('存在 Exists', cfg.exists ? '是 Yes' : '否 No') + kv('备份数 Backups', (cfg.backups || []).length) +
    kv('启动参数 Launch args', (cfg.args || []).join(' ')) + '</div>' +
    (cfg.warnings && cfg.warnings.length ? '<pre class="log" style="margin-top:10px">' + esc(cfg.warnings.join('\n')) + '</pre>' : '') +
    (cfg.restartOnly ? '<div class="hintline">' + esc(cfg.restartOnly.join(' · ')) + '</div>' : '') + '</div>';

  html += '<div class="savebar"><span class="meta" id="cfg-meta">未改动 Unchanged</span>' +
    '<button class="btn" id="btn-config-reset">还原为代码默认 Reset to defaults</button>' +
    '<button class="btn" id="btn-config-reload">重新读盘 Reload from disk</button>' +
    '<button class="btn primary" id="btn-config-save">保存 Save</button></div>';
  return html;
}

function field(name, label, desc, control, changed) {
  return '<div class="field' + (changed ? ' changed' : '') + '" data-field="' + name + '"><div>' +
    (changed ? '<span class="changeddot"></span>' : '') + '<span class="fname">' + esc(label) + '</span><div class="fdesc">' + esc(desc) + '</div></div>' +
    '<div class="fctrl">' + control + '</div></div>';
}

function switchHtml(name, on) {
  return '<label class="switch"><input type="checkbox" data-lim="' + name + '"' + (on ? ' checked' : '') + '><i></i></label>';
}

function bindConfig() {
  const cfg = state.config;
  const mark = () => {
    let n = 0;
    $$('#content .field[data-field]').forEach((f) => {
      const key = f.dataset.field;
      const def = cfg.codeDefaults.limits[key];
      let val;
      if (key === 'announcement') val = $('#content [data-lim=announcement]').value;
      else if (key === 'ipLock' || key === 'reconnectGuard') val = $('#content [data-lim=' + key + ']').checked;
      else val = Number($('#content [data-lim=' + key + ']').value);
      const changed = (key === 'announcement') ? (val !== (cfg.limits[key] || '')) : (val !== cfg.limits[key]);
      f.classList.toggle('changed', changed);
      if (changed) n++;
    });
    $('#cfg-meta').textContent = n === 0 ? '未改动 Unchanged' : (n + ' 项待保存');
  };
  $$('#content [data-lim]').forEach((el) => el.addEventListener('input', mark));
  $$('#content [data-lim]').forEach((el) => el.addEventListener('change', mark));
  $$('#content [data-smtp]').forEach((el) => el.addEventListener('input', mark));
  $$('#content [data-smtp]').forEach((el) => el.addEventListener('change', mark));

  $('#btn-config-save').addEventListener('click', async () => {
    const body = {
      announcement: $('#content [data-lim=announcement]').value,
      ipLock: $('#content [data-lim=ipLock]').checked,
      ipLockLimit: Number($('#content [data-lim=ipLockLimit]').value),
      reconnectGuard: $('#content [data-lim=reconnectGuard]').checked,
      reconnectLimit: Number($('#content [data-lim=reconnectLimit]').value),
      maxClients: Number($('#content [data-lim=maxClients]').value)
    };
    if ($('#content [data-smtp=host]')) {
      body.smtp = {
        host: $('#content [data-smtp=host]').value.trim(),
        port: Number($('#content [data-smtp=port]').value),
        user: $('#content [data-smtp=user]').value,
        pass: $('#content [data-smtp=pass]').value,
        from: $('#content [data-smtp=from]').value.trim(),
        ssl: $('#content [data-smtp=ssl]').checked
      };
    }
    const permEls = $$('#content [data-perm]');
    if (permEls.length) {
      const perms = {};
      for (const el of permEls) perms[el.dataset.perm] = el.value.split('\n').map((s) => s.trim()).filter((s) => s !== '');
      body.permissions = perms;
    }
    const r = await api('/api/console/config', { method: 'POST', body: body });
    toast('已保存并立即生效（' + (r.changed || []).join(', ') + '）' + (r.backup ? ' · 备份 ' + r.backup : ''), 'ok');
    state.config = await api('/api/console/config');
    $('#content').innerHTML = configHtml(state.config, state.route === 'iplock');
    bindConfig();
  });

  $('#btn-config-reset').addEventListener('click', () => {
    const l = cfg.codeDefaults.limits;
    $('#content [data-lim=announcement]').value = l.announcement;
    $('#content [data-lim=ipLock]').checked = l.ipLock;
    $('#content [data-lim=ipLockLimit]').value = l.ipLockLimit;
    $('#content [data-lim=reconnectGuard]').checked = l.reconnectGuard;
    $('#content [data-lim=reconnectLimit]').value = l.reconnectLimit;
    $('#content [data-lim=maxClients]').value = l.maxClients;
    const sm = cfg.codeDefaults.smtp || { host: '', port: 25, user: '', pass: '', from: '', ssl: false };
    for (const el of $$('#content [data-smtp]')) {
      const v = sm[el.dataset.smtp];
      if (el.type === 'checkbox') el.checked = !!v; else el.value = v == null ? '' : v;
    }
    for (const el of $$('#content [data-perm]')) el.value = (cfg.codeDefaults.permissions[el.dataset.perm] || []).join('\n');
    mark();
    toast('已还原为代码默认值（还没保存） Reset to code defaults (not saved yet)');
  });

  $('#btn-config-reload').addEventListener('click', async () => {
    await api('/api/console/reload', { method: 'POST' });
    state.config = await api('/api/console/config');
    $('#content').innerHTML = configHtml(state.config, state.route === 'iplock');
    bindConfig();
    toast('已重新读盘并应用 Reloaded from disk and applied', 'ok');
  });

  const dl = $('#content [data-download]');
  if (dl) dl.addEventListener('click', async () => {
    const c = await api('/api/console/config');
    const blob = new Blob([c.raw], { type: 'text/plain' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'config.toml';
    a.click();
    URL.revokeObjectURL(a.href);
  });
}

/* ---------------- rail (danger zone) ---------------- */

function renderRail() {
  $('#rail').innerHTML =
    '<div class="card"><div class="danger-title">危险操作 Danger zone</div>' +
    '<div class="field"><div><span class="fname">踢出玩家 Kick player</span><div class="fdesc">按昵称，游戏房 + network 房 by nickname, game rooms + network room</div></div>' +
    '<div class="fctrl"><input id="rail-kick" placeholder="昵称 Nickname"></div></div>' +
    '<div class="row"><button class="btn danger" id="rail-kick-btn" style="width:100%">踢出 Kick</button></div>' +
    '<div class="field" style="margin-top:8px"><div><span class="fname">关闭房间 Close room</span><div class="fdesc">房间号（4 位字母） room id (4 letters)</div></div>' +
    '<div class="fctrl"><input id="rail-room" placeholder="ABCD"></div></div>' +
    '<div class="row"><button class="btn danger" id="rail-room-btn" style="width:100%">强制关房 Force close</button></div>' +
    '<div class="field" style="margin-top:8px"><div><span class="fname">清空冷却表 Clear cooldowns</span><div class="fdesc">立刻允许重复写请求 allow repeated writes immediately</div></div>' +
    '<div class="fctrl"><button class="btn sm" id="rail-cd">清空 Clear</button></div></div>' +
    '</div>' +
    '<div class="card"><div class="sub" style="margin:0">服务端自身判定身份；页面不持有也不放宽 checkAccess。 the server decides identity; the page never holds or loosens checkAccess</div></div>';

  $('#rail-kick-btn').addEventListener('click', async () => {
    const name = $('#rail-kick').value.trim();
    if (!name) return;
    const r = await api('/api/console/kick', { method: 'POST', body: { name: name } });
    toast('已踢出 ' + r.kicked + ' 个连接', 'ok');
    if (state.route === 'players' || state.route === 'rooms' || state.route === 'connections') route();
  });
  $('#rail-room-btn').addEventListener('click', async () => {
    const roomId = $('#rail-room').value.trim().toUpperCase();
    if (!roomId) return;
    if (!confirm('强制关闭房间 ' + roomId + '？')) return;
    await api('/api/console/room/close', { method: 'POST', body: { roomId: roomId } });
    toast('房间 ' + roomId + ' 已关闭', 'ok');
    if (state.route === 'rooms') route();
  });
  $('#rail-cd').addEventListener('click', async () => {
    await api('/api/admin/cooldown/clear');
    toast('冷却表已清空 Cooldown table cleared', 'ok');
  });
}

/* ---------------- start ---------------- */

window.addEventListener('hashchange', () => {
  const r = (location.hash || '').replace('#/', '');
  if (r && r !== state.route && PAGES[r]) { state.route = r; state.data.page = 0; route(); }
});
state.data = { page: 0 };
boot();
