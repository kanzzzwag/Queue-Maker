// Daily Word: one shared 5-letter word per day, 6 tries.
// The server checks every guess and returns only the colors.
import {
  sb, esc, toast, errMsg, initPage, setupTabs, showBalance, nameLink, avatarHtml,
  fmtDate, fmtStamp,
} from './common.js';

const ROWS = 6;
const LEN = 5;
const KEYS = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
const RANK = { a: 1, p: 2, c: 3 };   // keyboard shows the best color seen for a letter

const ctx = await initPage('game', { balance: true });
if (ctx) init(ctx.profile);

function init(me) {
  const gridEl = document.getElementById('grid');
  const kbEl = document.getElementById('keyboard');
  const msgEl = document.getElementById('game-msg');
  let state = null;       // from game_state()
  let typed = '';
  let sending = false;

  // ---------- Board ----------
  function renderGrid() {
    const guesses = state?.guesses || [];
    let html = '';
    for (let r = 0; r < ROWS; r++) {
      const g = guesses[r];
      const current = !g && r === guesses.length && !state?.finished;
      html += `<div class="word-row${current ? ' current' : ''}">`;
      for (let i = 0; i < LEN; i++) {
        const ch = g ? g.guess[i] : (current ? typed[i] || '' : '');
        const cls = g ? ` t-${g.result[i]}` : (ch ? ' filled' : '');
        html += `<span class="tile${cls}">${esc(ch.toUpperCase())}</span>`;
      }
      html += '</div>';
    }
    gridEl.innerHTML = html;
  }

  function renderKeyboard() {
    const best = {};
    (state?.guesses || []).forEach((g) => {
      [...g.guess].forEach((ch, i) => {
        const r = g.result[i];
        if (!best[ch] || RANK[r] > RANK[best[ch]]) best[ch] = r;
      });
    });
    const key = (k) => `<button type="button" class="key${best[k] ? ` t-${best[k]}` : ''}" data-key="${k}">${k.toUpperCase()}</button>`;
    kbEl.innerHTML = `
      <div class="kb-row">${[...KEYS[0]].map(key).join('')}</div>
      <div class="kb-row">${[...KEYS[1]].map(key).join('')}</div>
      <div class="kb-row">
        <button type="button" class="key key-wide" data-key="enter">Enter</button>
        ${[...KEYS[2]].map(key).join('')}
        <button type="button" class="key key-wide" data-key="back" aria-label="Delete">Del</button>
      </div>`;
    kbEl.toggleAttribute('hidden', !!state?.finished);
  }

  function renderMsg() {
    if (!state?.finished) { msgEl.textContent = ''; return; }
    const word = (state.answer || '').toUpperCase();
    if (state.solved) {
      const extra = state.first_bonus ? ' First today: +20.' : '';
      const pay = state.rewarded ? `+${state.points} points.` : `${state.points} for the week (no rewards without email).`;
      msgEl.textContent = `Solved in ${state.attempts}. ${pay}${extra}`;
    } else {
      msgEl.textContent = `The word was ${word}. Try again tomorrow.`;
    }
  }

  function renderAll() { renderGrid(); renderKeyboard(); renderMsg(); }

  async function loadState() {
    const { data, error } = await sb.rpc('game_state');
    if (error) return toast(errMsg(error));
    if (state && state.day !== data.day) typed = '';   // new day started
    state = data;
    document.getElementById('email-hint').hidden = !!data.eligible;
    renderAll();
  }

  // ---------- Input ----------
  async function submit() {
    if (sending || state?.finished) return;
    if (typed.length < LEN) { toast('Enter 5 letters.'); return; }
    sending = true;
    const { data, error } = await sb.rpc('submit_guess', { p_guess: typed });
    sending = false;
    if (error) {
      toast(errMsg(error));
      if (/already played/i.test(error.message)) loadState();
      return;
    }
    state = data;
    typed = '';
    renderAll();
    if (state.finished) { loadToday(); showBalance(me); }
  }

  function press(k) {
    if (!state || state.finished) return;
    if (k === 'enter') return submit();
    if (k === 'back') typed = typed.slice(0, -1);
    else if (/^[a-z]$/.test(k) && typed.length < LEN) typed += k;
    renderGrid();
  }

  kbEl.addEventListener('click', (ev) => {
    const b = ev.target.closest('button[data-key]');
    if (b) press(b.dataset.key);
  });

  document.addEventListener('keydown', (ev) => {
    if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
    if (ev.target.closest('input, textarea, select')) return;
    if (document.querySelector('[data-panel="play"]').hidden) return;
    const k = ev.key.toLowerCase();
    if (k === 'enter') { ev.preventDefault(); press('enter'); }
    else if (k === 'backspace') { ev.preventDefault(); press('back'); }
    else if (/^[a-z]$/.test(k)) press(k);
  });

  // ---------- Boards ----------
  const noRewards = (row) => (row.no_rewards ? ' <span class="tag">no rewards</span>' : '');

  async function loadToday() {
    const el = document.getElementById('today-board');
    const { data, error } = await sb.rpc('game_today_board');
    if (error) return toast(errMsg(error));
    el.innerHTML = data.length ? data.map((r) => `
      <li class="row-item">
        <div>${avatarHtml(r, 24)} ${nameLink(r)}${noRewards(r)}
          ${r.first_bonus ? '<span class="tag tag-ok">First</span>' : ''}</div>
        <div>
          <strong>${r.solved ? `${r.attempts}/6` : 'X/6'}</strong>
          <span class="muted small-text">${esc(fmtStamp(r.finished_at))}</span>
        </div>
      </li>`).join('') : '<p class="muted">Nobody has finished yet.</p>';
  }

  async function loadWeek() {
    const el = document.getElementById('week-board');
    const { data, error } = await sb.rpc('game_week_board');
    if (error) return toast(errMsg(error));
    el.innerHTML = data.length ? data.map((r) => `
      <li class="row-item">
        <div><span class="rank">${r.rank}</span> ${avatarHtml(r, 24)} ${nameLink(r)}${noRewards(r)}</div>
        <div><strong>${r.score}</strong> <span class="muted small-text">${r.days_played} day${r.days_played === 1 ? '' : 's'}</span></div>
      </li>`).join('') : '<p class="muted">No games this week yet.</p>';
  }

  async function loadPast() {
    const el = document.getElementById('past-weeks');
    const { data, error } = await sb.from('weekly_results')
      .select('*, profiles(username, display_name, avatar_path)')
      .order('week_start', { ascending: false }).order('rank').limit(200);
    if (error) return toast(errMsg(error));
    if (!data.length) { el.innerHTML = '<p class="muted center">No finished weeks yet.</p>'; return; }
    const weeks = [...new Set(data.map((r) => r.week_start))].slice(0, 8);
    el.innerHTML = weeks.map((w) => `
      <div class="card">
        <h2>Week of ${esc(fmtDate(w, { day: 'numeric', month: 'short', year: 'numeric' }))}</h2>
        <ol class="rows board">${data.filter((r) => r.week_start === w).slice(0, 10).map((r) => `
          <li class="row-item">
            <div><span class="rank">${r.rank}</span> ${avatarHtml(r.profiles, 24)} ${nameLink(r.profiles)}${noRewards(r)}
              ${r.prize_place ? `<span class="badge-win place-${r.prize_place}">Weekly #${r.prize_place}</span>` : ''}</div>
            <div><strong>${r.score}</strong>
              ${r.prize ? `<span class="plus small-text">+${r.prize}</span>` : ''}
              <span class="muted small-text">${r.days_played} day${r.days_played === 1 ? '' : 's'}</span></div>
          </li>`).join('')}</ol>
      </div>`).join('');
  }

  setupTabs('game-tabs', 'play', (name) => {
    if (name === 'play') loadToday();
    if (name === 'week') loadWeek();
    if (name === 'past') loadPast();
  });

  // A new day may start while the page is open.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') { loadState(); loadToday(); }
  });

  renderAll();
  loadState();
}
