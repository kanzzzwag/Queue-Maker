// Admin page: queue, subjects, users, auto-join, points, Daily Word, settings.
// Each tab loads its data the first time it is opened.
import {
  sb, esc, toast, errMsg, busy, initPage, setupTabs, callFn, nameLink,
  WEEKDAYS, fmtTime, fmtDate, fmtStamp, fmtPoints, todayStr, weekStart, addDays,
} from './common.js';
import { mountQueue } from './queue-view.js';

const ctx = await initPage('admin', { admin: true });
if (ctx) init(ctx.profile);

function init(profile) {
  let queue;
  const loaders = {
    queue: () => { queue = mountQueue(document.getElementById('queue'), { profile, adminMode: true }); },
    subjects: () => setupSubjects(() => queue?.reload()),
    users: () => setupUsers(profile),
    autojoin: () => setupAutoJoin(),
    points: () => setupPoints(),
    word: () => setupWord(),
    settings: () => setupSettings(),
  };
  const loaded = new Set();
  setupTabs('admin-tabs', 'queue', (name) => {
    if (loaded.has(name)) return;
    loaded.add(name);
    loaders[name]?.();
  });
}

// ---------- Subjects ----------
// A subject can start next week (valid_from) or end after this week (valid_until),
// so a new trimester's schedule never changes the current week.
function setupSubjects(onChange) {
  const form = document.getElementById('subject-form');
  const list = document.getElementById('subject-list');
  const title = document.getElementById('subject-form-title');
  const cancelBtn = document.getElementById('subject-cancel');
  const startsWrap = document.getElementById('subject-starts');
  const nextWrap = document.getElementById('subject-next-wrap');
  let subjects = [];
  let editId = null;

  form.weekday.innerHTML = WEEKDAYS.map((d, i) => `<option value="${i + 1}">${d}</option>`).join('');
  const thisMonday = () => weekStart(todayStr());
  const nextMonday = () => addDays(thisMonday(), 7);

  function resetForm() {
    editId = null;
    form.reset();
    form.open_days.value = '1';
    form.open_time.value = '00:00';
    title.textContent = 'Add subject';
    cancelBtn.hidden = true;
    startsWrap.hidden = false;
    nextWrap.hidden = true;
  }

  async function load() {
    const { data, error } = await sb.from('subjects').select('*')
      .order('weekday').order('start_time').order('name');
    if (error) return toast(errMsg(error));
    subjects = data;
    render();
  }

  const opensLabel = (s) => {
    const d = s.open_days_before ?? 1;
    const when = d === 0 ? 'same day' : d === 1 ? '1 day before' : `${d} days before`;
    return `opens ${when}, ${fmtTime(s.open_time || '00:00')}`;
  };

  function render() {
    if (!subjects.length) { list.innerHTML = '<p class="muted">No subjects yet.</p>'; return; }
    list.innerHTML = WEEKDAYS.map((day, i) => {
      const items = subjects.filter((s) => s.weekday === i + 1);
      if (!items.length) return '';
      return `
        <section class="card">
          <h3>${day}</h3>
          <ul class="rows">
            ${items.map((s) => {
              const future = s.valid_from && s.valid_from > todayStr();
              const ending = !!s.valid_until;
              return `
              <li class="row-item${ending ? ' closed-row' : ''}">
                <div>
                  <strong>${esc(s.name)}</strong>
                  <span class="muted">${esc(fmtTime(s.start_time))}–${esc(fmtTime(s.end_time))}</span>
                  <span class="muted small-text">${esc(opensLabel(s))}</span>
                  ${future ? `<span class="tag tag-ok">From ${esc(fmtDate(s.valid_from))}</span>` : ''}
                  ${ending ? `<span class="tag tag-bad">Until ${esc(fmtDate(s.valid_until))}</span>` : ''}
                </div>
                <div class="entry-actions">
                  <button type="button" class="btn small" data-action="edit" data-id="${s.id}">Edit</button>
                  ${ending ? '' : `<button type="button" class="btn small" data-action="end" data-id="${s.id}">End after this week</button>`}
                  <button type="button" class="btn small danger" data-action="delete" data-id="${s.id}">Delete now</button>
                </div>
              </li>`;
            }).join('')}
          </ul>
        </section>`;
    }).join('');
  }

  list.addEventListener('click', async (ev) => {
    const btn = ev.target.closest('button[data-action]');
    if (!btn) return;
    const s = subjects.find((x) => x.id === Number(btn.dataset.id));
    if (!s) return;

    if (btn.dataset.action === 'edit') {
      editId = s.id;
      form.name.value = s.name;
      form.weekday.value = String(s.weekday);
      form.start.value = fmtTime(s.start_time);
      form.end.value = fmtTime(s.end_time);
      form.open_days.value = String(s.open_days_before ?? 1);
      form.open_time.value = fmtTime(s.open_time || '00:00');
      form.from_next.checked = false;
      title.textContent = 'Edit subject';
      cancelBtn.hidden = false;
      startsWrap.hidden = true;
      // "Apply from next week" only makes sense for a subject that is already running.
      nextWrap.hidden = !!(s.valid_from && s.valid_from >= nextMonday()) || !!s.valid_until;
      form.scrollIntoView({ behavior: 'smooth', block: 'start' });
      form.name.focus({ preventScroll: true });
    } else if (btn.dataset.action === 'end') {
      if (!confirm(`End "${s.name}" after this week? This week's queue stays; it disappears from next week.`)) return;
      await busy(btn, async () => {
        const { error } = await sb.rpc('admin_end_subject', { p_id: s.id });
        if (error) return toast(errMsg(error));
        toast('Ends after this week.', 'ok');
        await load();
        onChange();
      });
    } else if (btn.dataset.action === 'delete') {
      if (!confirm(`Delete "${s.name}" now? Its queue entries (also this week) will be deleted too.`)) return;
      await busy(btn, async () => {
        const { error } = await sb.from('subjects').delete().eq('id', s.id);
        if (error) return toast(errMsg(error));
        if (editId === s.id) resetForm();
        toast('Deleted.', 'ok');
        await load();
        onChange();
      });
    }
  });

  cancelBtn.addEventListener('click', resetForm);

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const row = {
      name: form.name.value.trim(),
      weekday: Number(form.weekday.value),
      start_time: form.start.value,
      end_time: form.end.value,
      open_days_before: Number(form.open_days.value),
      open_time: form.open_time.value || '00:00',
    };
    if (!row.name) return toast('Enter a name.');
    if (!row.start_time || !row.end_time) return toast('Enter start and end time.');
    if (row.end_time <= row.start_time) return toast('End must be after start.');

    await busy(form.querySelector('button[type=submit]'), async () => {
      let error;
      if (editId && form.from_next.checked && !nextWrap.hidden) {
        ({ error } = await sb.rpc('admin_change_subject_next_week', {
          p_id: editId, p_name: row.name, p_weekday: row.weekday, p_start: row.start_time,
          p_end: row.end_time, p_open_days: row.open_days_before, p_open_time: row.open_time,
        }));
      } else if (editId) {
        ({ error } = await sb.from('subjects').update(row).eq('id', editId));
      } else {
        if (form.starts.value === 'next') row.valid_from = nextMonday();
        ({ error } = await sb.from('subjects').insert(row));
      }
      if (error) return toast(errMsg(error));
      toast(editId ? 'Saved.' : row.valid_from ? 'Added from next week.' : 'Added.', 'ok');
      resetForm();
      await load();
      onChange();
    });
  });

  load();
}

// ---------- Users ----------
function setupUsers(profile) {
  const list = document.getElementById('user-list');
  const count = document.getElementById('user-count');
  let users = [];

  async function load() {
    const [{ data, error }, emails] = await Promise.all([
      sb.from('profiles').select('*').order('display_name'),
      sb.from('account_emails').select('user_id, email'),   // admin can read all emails
    ]);
    if (error) return toast(errMsg(error));
    const emailOf = new Map((emails.data || []).map((e) => [e.user_id, e.email]));
    users = data;
    count.textContent = `(${users.length})`;
    list.innerHTML = users.map((u) => `
      <li class="row-item">
        <div>
          ${nameLink(u)}
          <span class="muted">@${esc(u.username)}</span>
          ${u.is_admin ? '<span class="tag">Admin</span>' : ''}
          ${emailOf.has(u.id) ? `<span class="muted small-text">${esc(emailOf.get(u.id))}</span>` : '<span class="tag">No email</span>'}
        </div>
        <div class="entry-actions">
          <button type="button" class="btn small" data-action="reset" data-id="${u.id}">Reset password</button>
          ${u.id === profile.id ? '' : `<button type="button" class="btn small danger" data-action="remove" data-id="${u.id}">Remove</button>`}
        </div>
      </li>`).join('');
  }

  list.addEventListener('click', async (ev) => {
    const btn = ev.target.closest('button[data-action]');
    if (!btn) return;
    const u = users.find((x) => x.id === btn.dataset.id);
    if (!u) return;

    if (btn.dataset.action === 'reset') {
      if (!confirm(`Set a temporary password for ${u.display_name}?`)) return;
      await busy(btn, async () => {
        const { data, error } = await callFn('admin-reset-password', { user_id: u.id });
        if (error) return toast(error.message);
        // Shown once, not stored anywhere.
        prompt(`Temporary password for @${u.username}. Copy it now, it is shown once:`, data.password);
      });
    } else if (btn.dataset.action === 'remove') {
      if (!confirm(`Remove ${u.display_name}? Their account and entries will be deleted.`)) return;
      await busy(btn, async () => {
        const { error } = await sb.rpc('admin_delete_user', { target: u.id });
        if (error) return toast(errMsg(error));
        toast('User removed.', 'ok');
        await load();
      });
    }
  });

  load();
}

// ---------- Auto-join ----------
const AJ_STATUS = { joined: 'Joined', place_taken: 'Place taken', already_in: 'Already in', error: 'Error' };

function setupAutoJoin() {
  const list = document.getElementById('aj-list');
  const logEl = document.getElementById('aj-log');
  let subjects = [];

  async function load() {
    const [subs, rules] = await Promise.all([
      sb.from('subjects').select('*').order('weekday').order('start_time').order('name'),
      sb.from('auto_join_rules').select('*'),
    ]);
    if (subs.error || rules.error) return toast(errMsg(subs.error || rules.error));
    subjects = subs.data;
    const rule = new Map(rules.data.map((r) => [r.subject_id, r]));
    list.innerHTML = subjects.length ? subjects.map((s) => {
      const r = rule.get(s.id);
      return `
        <li class="row-item" data-subject="${s.id}">
          <label class="check">
            <input type="checkbox" name="enabled"${r?.enabled ? ' checked' : ''}>
            <span><strong>${esc(s.name)}</strong>
              <span class="muted">${WEEKDAYS[s.weekday - 1].slice(0, 3)} ${esc(fmtTime(s.start_time))}</span></span>
          </label>
          <label class="place-pick">Place
            <input name="place" type="number" min="1" step="1" inputmode="numeric" value="${r ? r.place : 3}">
          </label>
        </li>`;
    }).join('') : '<p class="muted">No subjects yet.</p>';
  }

  async function loadLog() {
    const { data, error } = await sb.from('auto_join_log').select('*')
      .order('created_at', { ascending: false }).limit(30);
    if (error) return toast(errMsg(error));
    logEl.innerHTML = data.length ? data.map((l) => `
      <li class="row-item">
        <div>
          <strong>${esc(l.subject_name || 'Deleted subject')}</strong>
          <span class="muted">${esc(fmtDate(l.slot_date))} · place ${l.place ?? '—'}</span>
        </div>
        <div>
          <span class="tag${l.status === 'joined' ? ' tag-ok' : l.status === 'already_in' ? '' : ' tag-bad'}">${AJ_STATUS[l.status]}</span>
          <span class="muted small-text">${esc(fmtStamp(l.created_at, { alwaysDate: true }))}</span>
        </div>
        ${l.error ? `<p class="comment">${esc(l.error)}</p>` : ''}
      </li>`).join('') : '<p class="muted">No runs yet.</p>';
  }

  document.getElementById('aj-save').addEventListener('click', async (ev) => {
    const rows = [...list.querySelectorAll('li[data-subject]')].map((li) => ({
      subject_id: Number(li.dataset.subject),
      enabled: li.querySelector('[name=enabled]').checked,
      place: Math.max(1, Math.floor(Number(li.querySelector('[name=place]').value) || 3)),
    }));
    if (!rows.length) return;
    await busy(ev.currentTarget, async () => {
      const { data: { user } } = await sb.auth.getUser();
      const { error } = await sb.from('auto_join_rules')
        .upsert(rows.map((r) => ({ ...r, user_id: user.id })), { onConflict: 'user_id,subject_id' });
      if (error) return toast(errMsg(error));
      toast('Saved.', 'ok');
    });
  });

  document.getElementById('aj-run').addEventListener('click', async (ev) => {
    await busy(ev.currentTarget, async () => {
      const { data, error } = await sb.rpc('run_auto_join', { p_force: true });
      if (error) return toast(errMsg(error));
      toast(data.length ? `Done: ${data.map((l) => AJ_STATUS[l.status]).join(', ')}.` : 'No open queue to join.', 'ok');
      await loadLog();
    });
  });

  load();
  loadLog();
}

// ---------- Points ----------
function setupPoints() {
  const form = document.getElementById('points-form');
  const usersEl = document.getElementById('points-users');
  const ledgerEl = document.getElementById('points-ledger');
  const KIND = { welcome_bonus: 'Welcome', trade: 'Trade', game_reward: 'Daily Word', weekly_prize: 'Weekly prize', admin_adjust: 'Admin' };

  async function load() {
    const [profiles, wallets, ledger] = await Promise.all([
      sb.from('profiles').select('id, username, display_name').order('display_name'),
      sb.from('wallets').select('user_id, balance'),
      sb.from('point_ledger')
        .select('*, user:profiles!point_ledger_user_id_fkey(username, display_name)')
        .order('id', { ascending: false }).limit(50),
    ]);
    const err = profiles.error || wallets.error || ledger.error;
    if (err) return toast(errMsg(err));
    const bal = new Map(wallets.data.map((w) => [w.user_id, w.balance]));

    const selected = form.user.value;
    form.user.innerHTML = profiles.data.map((p) =>
      `<option value="${p.id}">${esc(p.display_name)} (@${esc(p.username)})</option>`).join('');
    if (selected) form.user.value = selected;

    usersEl.innerHTML = profiles.data.map((p) => `
      <li class="row-item">
        <div>${nameLink(p)} <span class="muted">@${esc(p.username)}</span></div>
        <strong>${esc(fmtPoints(bal.get(p.id) ?? 0))}</strong>
      </li>`).join('');

    ledgerEl.innerHTML = ledger.data.length ? ledger.data.map((l) => `
      <li class="row-item">
        <div>
          ${nameLink(l.user)}
          <span class="tag">${KIND[l.kind] || esc(l.kind)}</span>
          ${l.reason ? `<span class="muted small-text">${esc(l.reason)}</span>` : ''}
        </div>
        <div>
          <strong class="${l.amount > 0 ? 'plus' : 'minus'}">${l.amount > 0 ? '+' : ''}${l.amount}</strong>
          <span class="muted small-text">${esc(fmtStamp(l.created_at, { alwaysDate: true }))}</span>
        </div>
      </li>`).join('') : '<p class="muted">No movements yet.</p>';
  }

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const amount = Math.trunc(Number(form.amount.value));
    const reason = form.reason.value.trim();
    if (!amount) return toast('Enter an amount (not 0).');
    if (!reason) return toast('Enter a reason.');
    await busy(form.querySelector('button[type=submit]'), async () => {
      const { error } = await sb.rpc('admin_adjust_points', { target: form.user.value, amount, reason });
      if (error) return toast(errMsg(error));
      toast('Done.', 'ok');
      form.amount.value = '';
      form.reason.value = '';
      await load();
    });
  });

  load();
}

// ---------- Daily Word answers ----------
function setupWord() {
  const form = document.getElementById('word-form');
  const list = document.getElementById('word-list');
  const count = document.getElementById('word-count');
  const warning = document.getElementById('word-warning');
  const today = document.getElementById('word-today');

  async function load() {
    const { data, error } = await sb.rpc('admin_answer_queue');
    if (error) return toast(errMsg(error));
    count.textContent = `(${data.length})`;
    warning.hidden = data.length >= 7;
    warning.textContent = data.length
      ? `Only ${data.length} word${data.length === 1 ? '' : 's'} left. Add more.`
      : 'No words left. Random words from the dictionary will be used.';
    list.innerHTML = data.length ? data.map((w, i) => `
      <li class="row-item">
        <div><span class="muted">${i + 1}.</span> <strong class="mono">${esc(w.word.toUpperCase())}</strong></div>
        <button type="button" class="btn small danger" data-id="${w.id}">Delete</button>
      </li>`).join('') : '<p class="muted">Empty.</p>';
  }

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const words = form.words.value.toLowerCase().split(/[\s,;]+/).filter(Boolean);
    if (!words.length) return toast('Enter some words.');
    await busy(form.querySelector('button[type=submit]'), async () => {
      const { data, error } = await sb.rpc('admin_add_answers', { p_words: words });
      if (error) return toast(errMsg(error));
      const bad = data.rejected || [];
      toast(`Added ${data.added}.${bad.length ? ` Rejected: ${bad.join(', ')}` : ''}`, bad.length ? 'error' : 'ok');
      form.words.value = bad.join('\n');
      await load();
    });
  });

  list.addEventListener('click', async (ev) => {
    const btn = ev.target.closest('button[data-id]');
    if (!btn) return;
    await busy(btn, async () => {
      const { error } = await sb.rpc('admin_remove_answer', { p_id: Number(btn.dataset.id) });
      if (error) return toast(errMsg(error));
      await load();
    });
  });

  document.getElementById('word-reveal').addEventListener('click', async (ev) => {
    if (!today.textContent && !confirm('Show today\'s answer?')) return;
    if (today.textContent) { today.textContent = ''; return; }
    await busy(ev.currentTarget, async () => {
      const { data, error } = await sb.rpc('admin_reveal_today');
      if (error) return toast(errMsg(error));
      today.textContent = String(data).toUpperCase();
    });
  });

  load();
}

// ---------- Settings: group code + trading ----------
function setupSettings() {
  const form = document.getElementById('code-form');
  const trade = document.getElementById('trade-enabled');

  sb.from('settings').select('*').eq('id', 1).maybeSingle().then(({ data, error }) => {
    if (error) return toast(errMsg(error));
    if (!data) return;
    form.code.value = data.group_code;
    trade.checked = !!data.trade_enabled;
    trade.disabled = !('trade_enabled' in data);
  });

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const code = form.code.value.trim();
    if (!code) return toast('Code cannot be empty.');
    await busy(form.querySelector('button[type=submit]'), async () => {
      const { error } = await sb.from('settings').update({ group_code: code }).eq('id', 1);
      if (error) return toast(errMsg(error));
      toast('Code saved.', 'ok');
    });
  });

  trade.addEventListener('change', async () => {
    const value = trade.checked;
    await busy(trade, async () => {
      const { error } = await sb.from('settings').update({ trade_enabled: value }).eq('id', 1);
      if (error) { trade.checked = !value; return toast(errMsg(error)); }
      document.querySelector('[data-nav="trade"]')?.toggleAttribute('hidden', !value);
      toast(value ? 'Trading is on.' : 'Trading is off.', 'ok');
    });
  });
}
