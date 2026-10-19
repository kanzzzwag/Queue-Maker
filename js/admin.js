// Admin page: queue management, subjects, users, group code.
import {
  sb, esc, toast, errMsg, busy, requireProfile, setupHeader, initThemeToggle,
  WEEKDAYS, fmtTime,
} from './common.js';
import { mountQueue } from './queue-view.js';

initThemeToggle(document.getElementById('theme'));

const profile = await requireProfile({ admin: true });
if (profile) init();

function init() {
  setupHeader(profile);
  setupTabs();
  const queue = mountQueue(document.getElementById('queue'), { profile, adminMode: true });
  setupSubjects(() => queue.reload());
  setupUsers();
  setupSettings();
}

// ---------- Section tabs (remembered in URL hash) ----------
function setupTabs() {
  const tabs = document.querySelectorAll('#admin-tabs button');
  const show = (name) => {
    tabs.forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === name)));
    document.querySelectorAll('[data-panel]').forEach((p) => { p.hidden = p.dataset.panel !== name; });
  };
  tabs.forEach((b) => b.addEventListener('click', () => {
    history.replaceState(null, '', `#${b.dataset.tab}`);
    show(b.dataset.tab);
  }));
  const fromHash = location.hash.slice(1);
  show([...tabs].some((b) => b.dataset.tab === fromHash) ? fromHash : 'queue');
}

// ---------- Subjects ----------
function setupSubjects(onChange) {
  const form = document.getElementById('subject-form');
  const list = document.getElementById('subject-list');
  const title = document.getElementById('subject-form-title');
  const cancelBtn = document.getElementById('subject-cancel');
  let subjects = [];
  let editId = null;

  form.weekday.innerHTML = WEEKDAYS.map((d, i) => `<option value="${i + 1}">${d}</option>`).join('');

  function resetForm() {
    editId = null;
    form.reset();
    title.textContent = 'Add subject';
    cancelBtn.hidden = true;
  }

  async function load() {
    const { data, error } = await sb.from('subjects').select('*')
      .order('weekday').order('start_time').order('name');
    if (error) return toast(errMsg(error));
    subjects = data;
    render();
  }

  function render() {
    if (!subjects.length) { list.innerHTML = '<p class="muted">No subjects yet.</p>'; return; }
    list.innerHTML = WEEKDAYS.map((day, i) => {
      const items = subjects.filter((s) => s.weekday === i + 1);
      if (!items.length) return '';
      return `
        <section class="card">
          <h3>${day}</h3>
          <ul class="rows">
            ${items.map((s) => `
              <li class="row-item">
                <div>
                  <strong>${esc(s.name)}</strong>
                  <span class="muted">${esc(fmtTime(s.start_time))}–${esc(fmtTime(s.end_time))}</span>
                </div>
                <div class="entry-actions">
                  <button type="button" class="btn small" data-action="edit" data-id="${s.id}">Edit</button>
                  <button type="button" class="btn small danger" data-action="delete" data-id="${s.id}">Delete</button>
                </div>
              </li>`).join('')}
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
      title.textContent = 'Edit subject';
      cancelBtn.hidden = false;
      form.scrollIntoView({ behavior: 'smooth', block: 'start' });
      form.name.focus({ preventScroll: true });
    } else if (btn.dataset.action === 'delete') {
      if (!confirm(`Delete "${s.name}"? Its queue entries will be deleted too.`)) return;
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
    };
    if (!row.name) return toast('Enter a name.');
    if (!row.start_time || !row.end_time) return toast('Enter start and end time.');
    if (row.end_time <= row.start_time) return toast('End must be after start.');

    await busy(form.querySelector('button[type=submit]'), async () => {
      const { error } = editId
        ? await sb.from('subjects').update(row).eq('id', editId)
        : await sb.from('subjects').insert(row);
      if (error) return toast(errMsg(error));
      toast(editId ? 'Saved.' : 'Added.', 'ok');
      resetForm();
      await load();
      onChange();
    });
  });

  load();
}

// ---------- Users ----------
function setupUsers() {
  const list = document.getElementById('user-list');
  const count = document.getElementById('user-count');
  let users = [];

  async function load() {
    const { data, error } = await sb.from('profiles').select('*').order('display_name');
    if (error) return toast(errMsg(error));
    users = data;
    count.textContent = `(${users.length})`;
    list.innerHTML = users.map((u) => `
      <li class="row-item">
        <div>
          <strong>${esc(u.display_name)}</strong>
          <span class="muted">@${esc(u.username)}</span>
          ${u.is_admin ? '<span class="tag">Admin</span>' : ''}
        </div>
        ${u.id === profile.id ? '' : `
          <div class="entry-actions">
            <button type="button" class="btn small danger" data-id="${u.id}">Remove</button>
          </div>`}
      </li>`).join('');
  }

  list.addEventListener('click', async (ev) => {
    const btn = ev.target.closest('button[data-id]');
    if (!btn) return;
    const u = users.find((x) => x.id === btn.dataset.id);
    if (!u || !confirm(`Remove ${u.display_name}? Their account and entries will be deleted.`)) return;
    await busy(btn, async () => {
      const { error } = await sb.rpc('admin_delete_user', { target: u.id });
      if (error) return toast(errMsg(error));
      toast('User removed.', 'ok');
      await load();
    });
  });

  load();
}

// ---------- Group code ----------
function setupSettings() {
  const form = document.getElementById('code-form');

  sb.from('settings').select('group_code').eq('id', 1).maybeSingle().then(({ data, error }) => {
    if (error) return toast(errMsg(error));
    if (data) form.code.value = data.group_code;
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
}
