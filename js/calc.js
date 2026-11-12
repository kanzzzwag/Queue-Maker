// Grade Calculator (Astana IT University rules).
// Everything happens in the browser: no database, grades are saved only in
// localStorage on this device.
import { initPage, esc } from './common.js';

const STORE_KEY = 'gradeCalc.subjects';
const SCHOLARSHIP = 70;   // total needed to keep the scholarship
const PASS = 50;          // total needed to pass, also the minimum for RegMid / RegEnd

// Status name -> text shown to the user (CSS class is "st-<name>").
const STATUS_TEXT = {
  scholarship: 'Scholarship kept',
  passed: 'Passed, no scholarship',
  retake: 'Retake (summer semester)',
  noadmission: 'No admission to the final exam',
};

// ---------- Math (pure functions, easy to test) ----------

// Round to 2 decimals (the small epsilon fixes cases like 1.005).
const round2 = (x) => Math.round((x + Number.EPSILON) * 100) / 100;

// Read one field. Returns { value } or { error } or { empty: true }.
// Accepts "85", "85.5" and "85,5".
function parseGrade(text) {
  const t = String(text).trim().replace(',', '.');
  if (t === '') return { empty: true };
  if (!/^\d+(\.\d+)?$/.test(t)) return { error: 'must be a number' };
  const n = Number(t);
  if (n < 0 || n > 100) return { error: 'must be from 0 to 100' };
  return { value: n };
}

// 60% of the grade that comes from the two regs.
const regPart = (mid, end) => 0.3 * mid + 0.3 * end;

const totalOf = (mid, end, final) => round2(regPart(mid, end) + 0.4 * final);

function statusOf(mid, end, total) {
  if (mid < PASS || end < PASS) return 'noadmission';
  if (total >= SCHOLARSHIP) return 'scholarship';
  if (total >= PASS) return 'passed';
  return 'retake';
}

// Minimum Final to reach a target total. Rounded UP to 0.01, so getting
// exactly this number is always enough.
function neededFinal(mid, end, target) {
  const raw = (target - regPart(mid, end)) / 0.4;
  return Math.ceil(round2(raw * 100)) / 100;
}

function neededText(n) {
  if (n > 100) return '<span class="calc-bad">impossible</span>';
  if (n <= 0) return '<span class="calc-good">already guaranteed</span>';
  return `<strong>${n}</strong>`;
}

// ---------- Saving (localStorage may be blocked: page still works) ----------

function loadSubjects() {
  try {
    const list = JSON.parse(localStorage.getItem(STORE_KEY));
    if (Array.isArray(list) && list.length) return list;
  } catch { /* no storage or broken data: start fresh */ }
  return [emptySubject()];
}

function saveSubjects(list) {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(list)); } catch { /* ignore */ }
}

function emptySubject() {
  return { id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6), name: '', mid: '', end: '', final: '', whatIf: 70 };
}

// ---------- Page ----------

const ctx = await initPage('calc');
if (ctx) init();

function init() {
  const box = document.getElementById('subjects');
  const tpl = document.getElementById('subject-tpl');
  let subjects = loadSubjects();

  const save = () => saveSubjects(subjects);

  // Build one subject card. Inputs are created once; only the result part
  // is redrawn while typing, so the cursor never jumps.
  function addCard(s) {
    const card = tpl.content.firstElementChild.cloneNode(true);
    card.dataset.id = s.id;
    const nameEl = card.querySelector('.calc-name');
    nameEl.value = s.name;
    card.querySelectorAll('[data-field]').forEach((inp) => { inp.value = s[inp.dataset.field]; });

    card.addEventListener('input', (ev) => {
      const el = ev.target;
      if (el === nameEl) s.name = el.value;
      else if (el.dataset.field) s[el.dataset.field] = el.value;
      else if (el.matches('[data-whatif]')) {
        s.whatIf = Number(el.value);
        updateWhatIf(card, s);   // only the "what if" line, keeps the slider smooth
        save();
        return;
      }
      save();
      renderResult(card, s);
    });

    card.querySelector('[data-remove]').addEventListener('click', () => {
      subjects = subjects.filter((x) => x.id !== s.id);
      if (!subjects.length) subjects = [emptySubject()];
      save();
      renderAll();
    });

    box.appendChild(card);
    renderResult(card, s);
  }

  function renderAll() {
    box.innerHTML = '';
    subjects.forEach(addCard);
  }

  document.getElementById('add-subject').addEventListener('click', () => {
    const s = emptySubject();
    subjects.push(s);
    save();
    addCard(s);
    box.lastElementChild.querySelector('.calc-name').focus();
  });

  document.getElementById('clear-all').addEventListener('click', () => {
    if (!confirm('Clear all subjects and grades?')) return;
    subjects = [emptySubject()];
    save();
    renderAll();
  });

  renderAll();
}

// Result block of one card: status, total, bar, needed Final, "what if" slider.
function renderResult(card, s) {
  const out = card.querySelector('.calc-result');
  const errEl = card.querySelector('.calc-error');

  // 1. Validate the three fields.
  const labels = { mid: 'RegMid', end: 'RegEnd', final: 'Final' };
  const g = {};
  const errors = [];
  for (const f of ['mid', 'end', 'final']) {
    g[f] = parseGrade(s[f]);
    const inp = card.querySelector(`[data-field="${f}"]`);
    inp.toggleAttribute('aria-invalid', !!g[f].error);
    if (g[f].error) errors.push(`${labels[f]} ${g[f].error}.`);
  }
  errEl.hidden = !errors.length;
  errEl.textContent = errors.join(' ');

  if (errors.length || g.mid.empty || g.end.empty) {
    out.innerHTML = errors.length ? '' : '<p class="muted small-text">Enter RegMid and RegEnd.</p>';
    return;
  }

  const mid = g.mid.value;
  const end = g.end.value;
  const base = round2(regPart(mid, end));
  const hasFinal = !g.final.empty;

  // 2. No admission: nothing else matters.
  if (mid < PASS || end < PASS) {
    out.innerHTML = `
      ${statusHtml('noadmission')}
      <p class="small-text muted">RegMid and RegEnd must both be 50 or more. Regs give ${base} of 60.</p>`;
    return;
  }

  // 3. Final filled: real total. Empty: minimum Final needed.
  let html;
  if (hasFinal) {
    const total = totalOf(mid, end, g.final.value);
    html = `
      ${statusHtml(statusOf(mid, end, total))}
      <p class="calc-total">Total <strong>${total}</strong></p>
      ${barHtml(base, total)}`;
  } else {
    html = `
      <p class="small-text muted">Regs give ${base} of 60. Minimum Final:</p>
      <ul class="calc-needed">
        <li><span>for scholarship (70)</span> ${neededText(neededFinal(mid, end, SCHOLARSHIP))}</li>
        <li><span>to pass (50)</span> ${neededText(neededFinal(mid, end, PASS))}</li>
      </ul>
      ${barHtml(base, base)}`;
  }

  // 4. "What if" slider for the Final.
  html += `
    <div class="calc-whatif">
      <label class="small-text">What if (move to try a Final)
        <input type="range" min="0" max="100" step="1" data-whatif value="${esc(String(s.whatIf ?? 70))}">
      </label>
      <p class="small-text" data-whatif-out></p>
    </div>`;
  out.innerHTML = html;
  updateWhatIf(card, s);
}

// Updates only the "what if" text (called on every slider move).
function updateWhatIf(card, s) {
  const outEl = card.querySelector('[data-whatif-out]');
  if (!outEl) return;
  const mid = parseGrade(s.mid).value;
  const end = parseGrade(s.end).value;
  const f = Number(s.whatIf ?? 70);
  const total = totalOf(mid, end, f);
  const st = statusOf(mid, end, total);
  outEl.innerHTML = `Final <strong>${f}</strong> gives total <strong>${total}</strong>: <span class="calc-st-text st-${st}">${STATUS_TEXT[st]}</span>`;
}

function statusHtml(st) {
  return `<p class="calc-status st-${st}">${STATUS_TEXT[st]}</p>`;
}

// Bar from 0 to 100: solid part = regs, light part = Final, marks at 50 and 70.
function barHtml(base, total) {
  const finalPart = Math.max(0, total - base);
  return `
    <div class="calc-bar" role="img" aria-label="Total ${total} of 100">
      <span class="calc-bar-base" style="width:${base}%"></span>
      <span class="calc-bar-final" style="left:${base}%;width:${finalPart}%"></span>
      <span class="calc-mark" style="left:50%"><i>50</i></span>
      <span class="calc-mark" style="left:70%"><i>70</i></span>
    </div>`;
}
