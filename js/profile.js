// Profile page: profile.html?u=username. Anyone in the group can view;
// the owner can edit name, bio, favorite subject, photo, background and email.
import {
  sb, esc, toast, errMsg, busy, initPage, callFn, avatarHtml, mediaUrl, fmtDate, fmtPoints,
} from './common.js';
import { shrinkImage, filePath } from './image.js';

export const BG_PRESETS = ['plain', 'sand', 'sage', 'sky', 'stone', 'lilac', 'clay', 'dots', 'grid', 'lines'];
const BG_LABEL = {
  plain: 'Plain', sand: 'Sand', sage: 'Sage', sky: 'Sky', stone: 'Stone',
  lilac: 'Lilac', clay: 'Clay', dots: 'Dots', grid: 'Grid', lines: 'Lines',
};

const ctx = await initPage('profile');
if (ctx) init(ctx.profile);

async function init(me) {
  const root = document.getElementById('profile');
  const username = (new URLSearchParams(location.search).get('u') || me.username).toLowerCase();
  let p;          // profile being shown
  let subjects = [];

  async function loadProfile() {
    const { data, error } = await sb.from('profiles').select('*').eq('username', username).maybeSingle();
    if (error) { toast(errMsg(error)); return false; }
    if (!data) { root.innerHTML = '<p class="muted center">User not found.</p>'; return false; }
    p = data;
    return true;
  }

  // ---------- View ----------
  async function render() {
    const fav = p.favorite_subject_text
      || subjects.find((s) => s.id === p.favorite_subject_id)?.name || '';
    document.title = `${p.display_name} · Defense Queue`;

    root.innerHTML = `
      <section class="profile card">
        <div class="profile-banner" id="banner"></div>
        <div class="profile-main">
          <div class="profile-avatar">${avatarHtml(p, 96)}</div>
          <div class="profile-id">
            <h1>${esc(p.display_name)}</h1>
            <p class="muted">@${esc(p.username)}${p.is_admin ? ' · Admin' : ''}</p>
          </div>
          ${p.bio ? `<p class="profile-bio">${esc(p.bio)}</p>` : ''}
          <dl class="facts">
            ${fav ? `<div><dt>Favorite subject</dt><dd>${esc(fav)}</dd></div>` : ''}
            <div><dt>Member since</dt><dd>${esc(fmtDate(p.created_at.slice(0, 10), { day: 'numeric', month: 'short', year: 'numeric' }))}</dd></div>
            <div><dt>Points</dt><dd id="f-points">—</dd></div>
            <div><dt>Trades</dt><dd id="f-trades">—</dd></div>
          </dl>
          <div id="badges" class="badges"></div>
        </div>
      </section>`;

    // Background: preset class or uploaded image (set via style, not HTML).
    const banner = document.getElementById('banner');
    if (p.bg_path) {
      banner.style.backgroundImage = `url("${encodeURI(mediaUrl('backgrounds', p.bg_path))}")`;
      banner.classList.add('bg-image');
    } else {
      banner.classList.add(`bg-${BG_PRESETS.includes(p.bg_preset) ? p.bg_preset : 'plain'}`);
    }

    loadStats();
  }

  // Read-only stats. Each part fails quietly if its feature is not installed.
  async function loadStats() {
    const [wallet, trades, badges] = await Promise.all([
      sb.from('wallets').select('balance').eq('user_id', p.id).maybeSingle(),
      sb.from('trades').select('id', { count: 'exact', head: true }).or(`seller_id.eq.${p.id},buyer_id.eq.${p.id}`),
      sb.from('weekly_results').select('week_start, prize_place')
        .eq('user_id', p.id).not('prize_place', 'is', null).order('week_start', { ascending: false }),
    ]);
    if (!wallet.error) document.getElementById('f-points').textContent = fmtPoints(wallet.data?.balance ?? 0);
    if (!trades.error) document.getElementById('f-trades').textContent = String(trades.count ?? 0);
    if (!badges.error && badges.data.length) {
      document.getElementById('badges').innerHTML = badges.data.map((b) => `
        <span class="badge-win place-${b.prize_place}">Weekly #${b.prize_place}
          <span class="muted">${esc(fmtDate(b.week_start))}</span></span>`).join('');
    }
  }

  // ---------- Edit (own profile) ----------
  function setupEdit() {
    document.getElementById('own').hidden = false;
    const form = document.getElementById('edit-form');
    const favText = document.getElementById('fav-text-wrap');
    const bioCount = document.getElementById('bio-count');

    // Favorite subject: unique names from the schedule, or "Other".
    const seen = new Set();
    const unique = subjects.filter((s) => !seen.has(s.name) && seen.add(s.name));
    form.fav.innerHTML = '<option value="">None</option>'
      + unique.map((s) => `<option value="${s.id}">${esc(s.name)}</option>`).join('')
      + '<option value="other">Other...</option>';

    function fill() {
      form.display_name.value = p.display_name;
      form.bio.value = p.bio || '';
      bioCount.textContent = String(form.bio.value.length);
      const favName = subjects.find((s) => s.id === p.favorite_subject_id)?.name;
      const favId = unique.find((s) => s.name === favName)?.id;
      form.fav.value = p.favorite_subject_text ? 'other' : (favId ? String(favId) : '');
      form.fav_text.value = p.favorite_subject_text || '';
      favText.hidden = form.fav.value !== 'other';

      // Name limit hint.
      const hint = document.getElementById('name-hint');
      const last = p.name_changed_at ? new Date(p.name_changed_at) : null;
      const next = last ? new Date(last.getTime() + 7 * 864e5) : null;
      hint.textContent = !me.is_admin && next && next > new Date()
        ? `Next name change: ${next.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })}.`
        : 'You can change your name once every 7 days.';
    }
    fill();

    form.bio.addEventListener('input', () => { bioCount.textContent = String(form.bio.value.length); });
    form.fav.addEventListener('change', () => { favText.hidden = form.fav.value !== 'other'; });

    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const name = form.display_name.value.trim().replace(/\s+/g, ' ');
      if (!name || name.length > 60) return toast('Name must be 1 to 60 characters.');
      const other = form.fav.value === 'other';
      const row = {
        display_name: name,
        bio: form.bio.value.trim() || null,
        favorite_subject_id: !other && form.fav.value ? Number(form.fav.value) : null,
        favorite_subject_text: other ? (form.fav_text.value.trim() || null) : null,
      };
      if (other && !row.favorite_subject_text) return toast('Type your subject.');
      await busy(form.querySelector('button[type=submit]'), async () => {
        const { data, error } = await sb.from('profiles').update(row).eq('id', me.id).select().single();
        if (error) return toast(errMsg(error));
        p = data;
        toast('Saved.', 'ok');
        fill();
        render();
      });
    });

    setupMedia();
    setupBackgroundPresets();
    setupEmail();
  }

  // Upload a shrunk image, save its path, then delete the old file.
  async function replaceFile(bucket, column, blob) {
    const path = filePath(me.id, blob);
    const up = await sb.storage.from(bucket).upload(path, blob, { contentType: blob.type, cacheControl: '31536000' });
    if (up.error) throw up.error;
    const old = p[column];
    const { data, error } = await sb.from('profiles').update({ [column]: path }).eq('id', me.id).select().single();
    if (error) { await sb.storage.from(bucket).remove([path]); throw error; }
    p = data;
    if (old) await sb.storage.from(bucket).remove([old]);
  }

  async function removeFile(bucket, column, extra = {}) {
    const old = p[column];
    const { data, error } = await sb.from('profiles').update({ [column]: null, ...extra }).eq('id', me.id).select().single();
    if (error) throw error;
    p = data;
    if (old) await sb.storage.from(bucket).remove([old]);
  }

  function setupMedia() {
    const avatarFile = document.getElementById('avatar-file');
    const bgFile = document.getElementById('bg-file');

    avatarFile.addEventListener('change', async () => {
      const file = avatarFile.files[0];
      avatarFile.value = '';
      if (!file) return;
      try {
        const blob = await shrinkImage(file, { square: 256, maxBytes: 40 * 1024 });
        await replaceFile('avatars', 'avatar_path', blob);
        toast('Photo saved.', 'ok');
        render();
      } catch (e) { toast(errMsg(e)); }
    });

    document.getElementById('avatar-remove').addEventListener('click', async (ev) => {
      if (!p.avatar_path) return;
      await busy(ev.currentTarget, async () => {
        try { await removeFile('avatars', 'avatar_path'); toast('Photo removed.', 'ok'); render(); } catch (e) { toast(errMsg(e)); }
      });
    });

    bgFile.addEventListener('change', async () => {
      const file = bgFile.files[0];
      bgFile.value = '';
      if (!file) return;
      try {
        const blob = await shrinkImage(file, { maxWidth: 1200, maxHeight: 1200, maxBytes: 300 * 1024 });
        await replaceFile('backgrounds', 'bg_path', blob);
        toast('Background saved.', 'ok');
        render();
        renderPresets();
      } catch (e) { toast(errMsg(e)); }
    });

    document.getElementById('bg-remove').addEventListener('click', async (ev) => {
      if (!p.bg_path) return;
      await busy(ev.currentTarget, async () => {
        try { await removeFile('backgrounds', 'bg_path'); toast('Image removed.', 'ok'); render(); renderPresets(); } catch (e) { toast(errMsg(e)); }
      });
    });
  }

  // Preset backgrounds (calm colors and simple patterns).
  const presetsEl = document.getElementById('bg-presets');
  function renderPresets() {
    const current = p.bg_path ? '' : (p.bg_preset || 'plain');
    presetsEl.innerHTML = BG_PRESETS.map((k) => `
      <button type="button" class="swatch bg-${k}" role="radio" aria-checked="${k === current}"
              data-preset="${k}" title="${BG_LABEL[k]}"><span>${BG_LABEL[k]}</span></button>`).join('');
  }
  function setupBackgroundPresets() {
    renderPresets();
    presetsEl.addEventListener('click', async (ev) => {
      const btn = ev.target.closest('button[data-preset]');
      if (!btn) return;
      try {
        if (p.bg_path) await removeFile('backgrounds', 'bg_path', { bg_preset: btn.dataset.preset });
        else {
          const { data, error } = await sb.from('profiles').update({ bg_preset: btn.dataset.preset }).eq('id', me.id).select().single();
          if (error) throw error;
          p = data;
        }
        render();
        renderPresets();
      } catch (e) { toast(errMsg(e)); }
    });
  }

  // ---------- Email ----------
  function setupEmail() {
    const form = document.getElementById('email-form');
    const status = document.getElementById('email-status');
    const removeBtn = document.getElementById('email-remove');

    async function load() {
      const { data, error } = await sb.rpc('my_email_status');
      if (error) { status.textContent = ''; return; }
      const parts = [];
      if (data.email) parts.push(`Confirmed: ${data.email}`);
      if (data.pending) parts.push(`Waiting for confirmation: ${data.pending}. Check your inbox.`);
      if (!parts.length) parts.push('No email yet.');
      status.textContent = parts.join(' ');
      removeBtn.hidden = !data.email;
    }

    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const email = form.email.value.trim();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return toast('Enter a valid email.');
      await busy(form.querySelector('button[type=submit]'), async () => {
        const { data, error } = await callFn('email', { action: 'start', email });
        if (error) return toast(error.message);
        toast(data.message, 'ok');
        form.email.value = '';
        await load();
      });
    });

    removeBtn.addEventListener('click', async () => {
      if (!confirm('Remove your email? Password reset by email will stop working.')) return;
      await busy(removeBtn, async () => {
        const { data, error } = await callFn('email', { action: 'remove' });
        if (error) return toast(error.message);
        toast(data.message, 'ok');
        await load();
      });
    });

    load();
  }

  // ---------- Start ----------
  const subs = await sb.from('subjects').select('id, name, weekday, start_time').order('name');
  subjects = subs.data || [];
  if (!(await loadProfile())) return;
  render();
  if (p.id === me.id) setupEdit();
}
