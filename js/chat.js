// Group chat: latest 50 messages, "Load older", live inserts/deletes.
import {
  sb, esc, toast, errMsg, busy, initPage, nameLink, avatarHtml, fmtStamp, fmtDate, TZ,
} from './common.js';

const PAGE = 50;
const ctx = await initPage('chat');
if (ctx) init(ctx.profile);

function init(me) {
  const log = document.getElementById('chat-log');
  const list = document.getElementById('messages');
  const olderBtn = document.getElementById('older');
  const empty = document.getElementById('chat-empty');
  const form = document.getElementById('chat-form');

  let messages = [];               // sorted by id, oldest first
  const people = new Map();        // user_id -> profile
  let hasOlder = false;

  const atBottom = () => log.scrollHeight - log.scrollTop - log.clientHeight < 60;
  const toBottom = () => { log.scrollTop = log.scrollHeight; };
  const dayOf = (iso) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date(iso));

  function rowHtml(m, prev) {
    const p = people.get(m.user_id);
    const mine = m.user_id === me.id;
    const canDelete = mine || me.is_admin;
    const day = dayOf(m.created_at);
    const sep = !prev || dayOf(prev.created_at) !== day
      ? `<li class="msg-day">${esc(fmtDate(day, { weekday: 'short', day: 'numeric', month: 'short' }))}</li>` : '';
    return `${sep}
      <li class="msg${mine ? ' mine' : ''}">
        <a href="profile.html?u=${encodeURIComponent(p?.username || '')}" class="msg-avatar" tabindex="-1">${avatarHtml(p, 32)}</a>
        <div class="msg-main">
          <div class="msg-head">
            ${nameLink(p)}
            <span class="muted small-text">${esc(fmtStamp(m.created_at, { alwaysDate: false }).split(', ').pop())}</span>
            ${canDelete ? `<button type="button" class="link-btn" data-del="${m.id}">Delete</button>` : ''}
          </div>
          <p class="msg-body">${esc(m.body)}</p>
        </div>
      </li>`;
  }

  function render() {
    list.innerHTML = messages.map((m, i) => rowHtml(m, messages[i - 1])).join('');
    empty.hidden = messages.length > 0;
    olderBtn.hidden = !hasOlder;
  }

  function remember(rows) {
    rows.forEach((m) => { if (m.profiles) people.set(m.user_id, m.profiles); delete m.profiles; });
  }

  async function loadLatest() {
    const { data, error } = await sb.from('messages').select('*, profiles(*)')
      .order('id', { ascending: false }).limit(PAGE);
    if (error) return toast(errMsg(error));
    remember(data);
    messages = data.reverse();
    hasOlder = data.length === PAGE;
    render();
    toBottom();
  }

  olderBtn.addEventListener('click', () => busy(olderBtn, async () => {
    if (!messages.length) return;
    const { data, error } = await sb.from('messages').select('*, profiles(*)')
      .lt('id', messages[0].id).order('id', { ascending: false }).limit(PAGE);
    if (error) return toast(errMsg(error));
    remember(data);
    const before = log.scrollHeight;
    messages = data.reverse().concat(messages);
    hasOlder = data.length === PAGE;
    render();
    log.scrollTop += log.scrollHeight - before;   // keep the view where it was
  }));

  // Delete own message (or any, for admin).
  list.addEventListener('click', async (ev) => {
    const btn = ev.target.closest('button[data-del]');
    if (!btn || !confirm('Delete this message?')) return;
    await busy(btn, async () => {
      const id = Number(btn.dataset.del);
      const { error } = await sb.from('messages').delete().eq('id', id);
      if (error) return toast(errMsg(error));
      messages = messages.filter((m) => m.id !== id);
      render();
    });
  });

  // Send. Enter sends, Shift+Enter makes a new line.
  const input = form.body;
  const grow = () => { input.style.height = 'auto'; input.style.height = `${Math.min(input.scrollHeight, 140)}px`; };
  input.addEventListener('input', grow);
  input.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter' && !ev.shiftKey && !ev.isComposing) { ev.preventDefault(); form.requestSubmit(); }
  });
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const body = input.value.trim();
    if (!body) return;
    if (body.length > 500) return toast('Message is too long (max 500).');
    await busy(form.querySelector('button[type=submit]'), async () => {
      const { data, error } = await sb.from('messages').insert({ body }).select().single();
      if (error) return toast(errMsg(error));
      input.value = '';
      grow();
      addMessage(data, true);
    });
    input.focus();
  });

  async function addMessage(m, scroll = false) {
    if (messages.some((x) => x.id === m.id)) return;
    if (!people.has(m.user_id)) {
      const { data } = await sb.from('profiles').select('*').eq('id', m.user_id).maybeSingle();
      if (data) people.set(m.user_id, data);
    }
    const stick = scroll || atBottom();
    messages.push(m);
    messages.sort((a, b) => a.id - b.id);
    render();
    if (stick) toBottom();   // only auto-scroll if the user was already at the bottom
  }

  sb.channel('chat-live')
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages' }, (p) => addMessage(p.new))
    .on('postgres_changes', { event: 'DELETE', schema: 'public', table: 'messages' }, (p) => {
      const id = p.old?.id;
      if (!id || !messages.some((m) => m.id === id)) return;
      messages = messages.filter((m) => m.id !== id);
      render();
    })
    .subscribe();

  loadLatest();
}
