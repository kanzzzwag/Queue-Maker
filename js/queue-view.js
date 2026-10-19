// Two-week queue view. Used on index.html (users) and admin.html (adminMode).
import {
  sb, esc, toast, errMsg, busy,
  todayStr, addDays, weekStart, fmtDate, fmtTime, WEEKDAYS,
} from './common.js';

export function mountQueue(root, { profile, adminMode = false }) {
  const state = {
    today: todayStr(),
    week: 0,            // 0 = this week, 1 = next week
    subjects: [],
    entries: [],
    editing: null,      // id of own entry whose comment is being edited
    loaded: false,
  };

  root.innerHTML = `
    <div class="tabs" role="tablist">
      <button type="button" role="tab" data-week="0"></button>
      <button type="button" role="tab" data-week="1"></button>
    </div>
    <div class="days" aria-live="polite"><p class="muted center">Loading...</p></div>`;
  const tabs = root.querySelector('.tabs');
  const days = root.querySelector('.days');

  // ---------- Data ----------
  const firstDay = () => weekStart(state.today);

  async function loadSubjects() {
    const { data, error } = await sb.from('subjects').select('*')
      .order('weekday').order('start_time').order('name');
    if (error) throw error;
    state.subjects = data;
  }

  async function loadEntries() {
    const from = firstDay();
    const { data, error } = await sb.from('entries')
      .select('id, subject_id, slot_date, user_id, comment, done, created_at, profiles(display_name, username)')
      .gte('slot_date', from)
      .lte('slot_date', addDays(from, 13))
      .order('created_at').order('id');
    if (error) throw error;
    state.entries = data;
  }

  async function reloadAll() {
    state.today = todayStr();
    try {
      await Promise.all([loadSubjects(), loadEntries()]);
      state.loaded = true;
      render();
    } catch (e) { toast(errMsg(e)); }
  }

  async function reloadEntries() {
    try { await loadEntries(); render(); } catch (e) { toast(errMsg(e)); }
  }

  // ---------- Rendering ----------
  function renderTabs() {
    tabs.querySelectorAll('button').forEach((b) => {
      const w = Number(b.dataset.week);
      const start = addDays(firstDay(), w * 7);
      const end = addDays(start, 6);
      b.innerHTML = `${w === 0 ? 'This week' : 'Next week'}
        <span class="tab-sub">${esc(fmtDate(start))} – ${esc(fmtDate(end))}</span>`;
      b.setAttribute('aria-selected', String(w === state.week));
    });
  }

  function entryHtml(e, pos, open) {
    const mine = e.user_id === profile.id;
    const name = e.profiles?.display_name ?? 'Unknown';
    const editing = mine && open && state.editing === e.id;

    let actions = '';
    if (mine && open && !editing) {
      actions += `<button type="button" class="btn small" data-action="edit" data-id="${e.id}">Edit</button>
                  <button type="button" class="btn small" data-action="leave" data-id="${e.id}">Cancel</button>`;
    }
    if (adminMode) {
      actions += `<button type="button" class="btn small" data-action="done" data-id="${e.id}" data-done="${e.done}">${e.done ? 'Undo' : 'Done'}</button>
                  <button type="button" class="btn small danger" data-action="remove" data-id="${e.id}">Remove</button>`;
    }

    const comment = editing
      ? `<form class="inline-form" data-form="edit" data-id="${e.id}">
           <input name="comment" maxlength="200" value="${esc(e.comment)}" placeholder="Comment" data-key="edit:${e.id}" aria-label="Comment">
           <button class="btn small primary">Save</button>
           <button type="button" class="btn small" data-action="cancel-edit">Back</button>
         </form>`
      : (e.comment ? `<p class="comment">${esc(e.comment)}</p>` : '');

    return `
      <li class="entry${mine ? ' mine' : ''}${e.done ? ' done' : ''}">
        <span class="pos">${pos}</span>
        <div class="entry-body">
          <div class="entry-name">
            <span class="name">${esc(name)}</span>
            ${mine ? '<span class="tag tag-you">You</span>' : ''}
            ${e.done ? '<span class="tag">Done</span>' : ''}
          </div>
          ${comment}
        </div>
        ${actions ? `<div class="entry-actions">${actions}</div>` : ''}
      </li>`;
  }

  function slotHtml(s, date, open) {
    const list = state.entries.filter((e) => e.subject_id === s.id && e.slot_date === date);
    const myIndex = list.findIndex((e) => e.user_id === profile.id);

    let footer = '';
    if (open && myIndex === -1) {
      footer = `<form class="inline-form join" data-form="join" data-subject="${s.id}" data-date="${date}">
          <input name="comment" maxlength="200" placeholder="Comment (optional)" data-key="join:${s.id}:${date}" aria-label="Comment">
          <button class="btn primary">Join</button>
        </form>`;
    }

    return `
      <article class="slot">
        <header class="slot-head">
          <div>
            <h3>${esc(s.name)}</h3>
            <span class="muted">${esc(fmtTime(s.start_time))}–${esc(fmtTime(s.end_time))}</span>
          </div>
          <div class="slot-meta">
            ${myIndex >= 0 ? `<span class="tag tag-you">You: #${myIndex + 1}</span>` : ''}
            <span class="muted">${list.length} in queue</span>
          </div>
        </header>
        ${list.length
          ? `<ol class="queue">${list.map((e, i) => entryHtml(e, i + 1, open)).join('')}</ol>`
          : '<p class="empty">No one yet.</p>'}
        ${footer}
      </article>`;
  }

  function render() {
    renderTabs();
    if (!state.loaded) return;

    // Keep typed text and focus across re-renders (realtime updates).
    const saved = {};
    days.querySelectorAll('input[data-key]').forEach((i) => { saved[i.dataset.key] = i.value; });
    const focusKey = document.activeElement?.dataset?.key;

    const start = addDays(firstDay(), state.week * 7);
    let html = '';
    for (let i = 0; i < 7; i++) {
      const date = addDays(start, i);
      const subjects = state.subjects.filter((s) => s.weekday === i + 1);
      if (!subjects.length) continue;
      const isToday = date === state.today;
      const closed = date < state.today;
      html += `
        <section class="day${isToday ? ' today' : ''}${closed ? ' closed' : ''}">
          <h2 class="day-head">
            <span>${WEEKDAYS[i]}</span>
            <span class="muted">${esc(fmtDate(date))}</span>
            ${isToday ? '<span class="badge badge-today">Today</span>' : ''}
            ${closed ? '<span class="badge">Closed</span>' : ''}
          </h2>
          ${subjects.map((s) => slotHtml(s, date, !closed)).join('')}
        </section>`;
    }
    days.innerHTML = html || '<p class="muted center">No subjects yet.</p>';

    days.querySelectorAll('input[data-key]').forEach((i) => {
      if (saved[i.dataset.key] !== undefined) i.value = saved[i.dataset.key];
      if (i.dataset.key === focusKey) i.focus();
    });
  }

  // ---------- Actions ----------
  tabs.addEventListener('click', (ev) => {
    const b = ev.target.closest('button[data-week]');
    if (!b) return;
    state.week = Number(b.dataset.week);
    state.editing = null;
    render();
  });

  days.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const form = ev.target;
    const btn = form.querySelector('button:not([type=button])');
    const comment = form.comment.value.trim() || null;

    if (form.dataset.form === 'join') {
      await busy(btn, async () => {
        const { error } = await sb.from('entries').insert({
          subject_id: Number(form.dataset.subject),
          slot_date: form.dataset.date,
          user_id: profile.id,
          comment,
        });
        if (error) return toast(errMsg(error));
        form.comment.value = '';
        toast('Joined.', 'ok');
        await reloadEntries();
      });
    } else if (form.dataset.form === 'edit') {
      await busy(btn, async () => {
        const { error } = await sb.from('entries').update({ comment }).eq('id', form.dataset.id);
        if (error) return toast(errMsg(error));
        state.editing = null;
        toast('Saved.', 'ok');
        await reloadEntries();
      });
    }
  });

  days.addEventListener('click', async (ev) => {
    const btn = ev.target.closest('button[data-action]');
    if (!btn) return;
    const id = Number(btn.dataset.id);

    switch (btn.dataset.action) {
      case 'edit':
        state.editing = id;
        render();
        days.querySelector(`input[data-key="edit:${id}"]`)?.focus();
        break;
      case 'cancel-edit':
        state.editing = null;
        render();
        break;
      case 'leave':
        if (!confirm('Leave this queue?')) return;
        await busy(btn, async () => {
          const { error } = await sb.from('entries').delete().eq('id', id);
          if (error) return toast(errMsg(error));
          toast('Removed.', 'ok');
          await reloadEntries();
        });
        break;
      case 'done':
        await busy(btn, async () => {
          const done = btn.dataset.done !== 'true';
          const { error } = await sb.from('entries').update({ done }).eq('id', id);
          if (error) return toast(errMsg(error));
          await reloadEntries();
        });
        break;
      case 'remove':
        if (!confirm('Remove this entry?')) return;
        await busy(btn, async () => {
          const { error } = await sb.from('entries').delete().eq('id', id);
          if (error) return toast(errMsg(error));
          toast('Removed.', 'ok');
          await reloadEntries();
        });
        break;
    }
  });

  // ---------- Live updates ----------
  let timer;
  const scheduleReload = () => { clearTimeout(timer); timer = setTimeout(reloadEntries, 250); };

  sb.channel('entries-live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'entries' }, scheduleReload)
    .subscribe();

  // Refresh when the tab becomes visible again (also handles the day changing at midnight).
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') reloadAll();
  });

  render();
  reloadAll();
  return { reload: reloadAll };
}
