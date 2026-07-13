// windows-iso-maker showcase + config builder.
//
// Vanilla ES-module, no framework, no runtime dependencies. It reads the catalog manifest
// (data/catalog.json, produced by Export-CatalogManifest) and drives two views:
//   1. Change overview  — browse/search/filter every catalog entry with full rationale + citation.
//   2. Config builder   — pick a profile + options and tick individual changes to deviate from the
//                         profile default; a valid build.config.psd1 is generated live.
//
// The profile membership in the manifest is computed by the SAME logic the build uses
// (Test-CatalogEntryInProfile), so the site can never drift from the tool's real behaviour.

const MANIFEST_URL = './data/catalog.json';
const THEME_KEY = 'wim-theme';

const state = {
  view: 'overview',
  manifest: null,
  entries: [],
  options: {
    Edition: 'Pro',
    Architecture: 'amd64',
    Language: 'en-US',
    Release: 'latest',
    Profile: 'default',
    AccountMode: 'local',
    ProductKey: '',
    LocalAccountName: 'Admin',
    BootTest: false,
  },
  // id -> desired boolean, only present when it differs from the current profile default.
  deviations: {},
};

// ---------- tiny DOM helpers ----------
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const el = (tag, attrs = {}, children = []) => {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k === 'html') node.innerHTML = v;
    else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined && v !== false) node.setAttribute(k, v);
  }
  for (const c of [].concat(children)) {
    if (c === null || c === undefined) continue;
    node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
};
const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

let toastTimer = null;
function toast(message) {
  const t = $('#toast');
  if (!t) return;
  t.textContent = message;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 2200);
}

// ---------- profile helpers ----------
const isDefaultFor = (entry, profile) => (entry.profiles || []).includes(profile);
const currentEnabled = (entry) =>
  Object.prototype.hasOwnProperty.call(state.deviations, entry.id)
    ? state.deviations[entry.id]
    : isDefaultFor(entry, state.options.Profile);
const profileMeta = (name) => (state.manifest?.profiles || []).find((p) => p.name === name) || null;
const describeProfile = (name) => profileMeta(name)?.description || '';
const profileChangeCount = (name) => state.entries.filter((e) => isDefaultFor(e, name)).length;

// The inclusive profile chain (minimal ⊂ default ⊂ aggressive ⊂ opinionated). An entry's "scope
// tier" is the earliest link in this chain that enables it; 'gaming' is a variant of 'default'
// (same debloat minus the Xbox stack), not an extra tier, so it is not part of the ranking.
const PROFILE_TIERS = [
  { key: 'minimal', label: 'Minimal', note: 'registry policy defaults' },
  { key: 'default', label: 'Default', note: 'the balanced baseline' },
  { key: 'aggressive', label: 'Aggressive', note: 'extra grade 1-2 removals' },
  { key: 'opinionated', label: 'Opinionated', note: 'personal-taste extras' },
];
const OPTIN_TIER = { key: '', label: 'Opt-in only', note: 'in no baseline profile — enable explicitly' };
const entryProfileRank = (entry) => {
  const profs = entry.profiles || [];
  for (let i = 0; i < PROFILE_TIERS.length; i++) {
    if (profs.includes(PROFILE_TIERS[i].key)) return i;
  }
  return PROFILE_TIERS.length; // opt-in only (no baseline)
};
const entryProfileTier = (entry) => PROFILE_TIERS[entryProfileRank(entry)] || OPTIN_TIER;

// ============================================================================
// Boot
// ============================================================================
init();

async function init() {
  applyStoredTheme();
  wireChrome();
  try {
    const res = await fetch(MANIFEST_URL, { cache: 'no-cache' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    state.manifest = await res.json();
    state.entries = state.manifest.entries || [];
  } catch (err) {
    $('#entry-list').innerHTML = `<div class="empty">Could not load the change catalog (${escapeHtml(err.message)}).<br>Serve this folder over HTTP and try again.</div>`;
    return;
  }
  buildOverview();
  buildConfigurator();
  renderFooter();
}

// ============================================================================
// Chrome: tabs, theme, cross-links
// ============================================================================
function wireChrome() {
  $$('.tab').forEach((tab) => tab.addEventListener('click', () => switchView(tab.dataset.view)));
  document.body.addEventListener('click', (e) => {
    const goto = e.target.closest('[data-goto]');
    if (goto) switchView(goto.dataset.goto);
  });
  $('#theme-toggle')?.addEventListener('click', toggleTheme);
}

function switchView(view) {
  if (!view || view === state.view) return;
  state.view = view;
  $$('.tab').forEach((t) => {
    const active = t.dataset.view === view;
    t.classList.toggle('is-active', active);
    t.setAttribute('aria-selected', active ? 'true' : 'false');
  });
  $$('.view').forEach((v) => v.classList.toggle('is-active', v.id === `view-${view}`));
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function applyStoredTheme() {
  const saved = localStorage.getItem(THEME_KEY);
  if (saved === 'light' || saved === 'dark') {
    document.documentElement.setAttribute('data-theme', saved);
  }
}
function toggleTheme() {
  const current = document.documentElement.getAttribute('data-theme') || 'dark';
  const next = current === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', next);
  localStorage.setItem(THEME_KEY, next);
}

function renderFooter() {
  const m = state.manifest;
  const parts = [];
  if (m.moduleVersion) parts.push(`module v${m.moduleVersion}`);
  if (m.entryCount != null) parts.push(`${m.entryCount} entries`);
  if (m.generatedUtc) parts.push(`generated ${m.generatedUtc.replace('T', ' ').replace('Z', ' UTC')}`);
  $('#footer-meta').textContent = parts.join(' · ');
}

// ============================================================================
// Overview
// ============================================================================
function buildOverview() {
  renderStatCards();

  const profileSel = $('#filter-profile');
  for (const p of state.manifest.profiles || []) {
    profileSel.appendChild(el('option', { value: p.name, text: `${p.name} profile`, title: p.description || '' }));
  }
  const typeSel = $('#filter-type');
  for (const t of state.manifest.types || []) {
    typeSel.appendChild(el('option', { value: t, text: t }));
  }

  ['#search', '#filter-profile', '#filter-type', '#filter-grade', '#sort-by'].forEach((s) =>
    $(s).addEventListener('input', renderEntries)
  );
  $('#filter-reversible').addEventListener('change', renderEntries);

  renderEntries();
}

function renderStatCards() {
  const e = state.entries;
  const removals = e.filter((x) => x.action === 'RemoveAppx' || x.action === 'RemoveCapability').length;
  const registry = e.filter((x) => x.type === 'Registry').length;
  const reversible = e.filter((x) => x.reversible).length;
  const cards = [
    { num: e.length, lbl: 'Catalog changes' },
    { num: removals, lbl: 'App / capability removals' },
    { num: registry, lbl: 'Registry tweaks' },
    { num: reversible, lbl: 'Reversible' },
  ];
  $('#stat-cards').replaceChildren(
    ...cards.map((c) => el('div', { class: 'stat-card' }, [el('div', { class: 'num', text: String(c.num) }), el('div', { class: 'lbl', text: c.lbl })]))
  );
}

function currentFilters() {
  return {
    q: $('#search').value.trim().toLowerCase(),
    profile: $('#filter-profile').value,
    type: $('#filter-type').value,
    grade: $('#filter-grade').value,
    sort: $('#sort-by')?.value || '',
    reversible: $('#filter-reversible').checked,
  };
}

// Stable comparison helpers for the Sort control.
function sortEntries(list, sort) {
  const byId = (a, b) => String(a.id).localeCompare(String(b.id));
  const arr = list.slice();
  if (sort === 'profile') {
    arr.sort((a, b) => entryProfileRank(a) - entryProfileRank(b) || String(a.type).localeCompare(String(b.type)) || byId(a, b));
  } else if (sort === 'type') {
    arr.sort((a, b) => String(a.type).localeCompare(String(b.type)) || byId(a, b));
  } else if (sort === 'grade') {
    arr.sort((a, b) => (a.evidenceGrade || 0) - (b.evidenceGrade || 0) || byId(a, b));
  }
  return arr;
}

// Explain the selected profile inline so users don't have to reverse-engineer it from the rows.
function renderProfileSummary() {
  const box = $('#profile-summary');
  if (!box) return;
  const name = $('#filter-profile').value;
  if (!name) {
    box.hidden = true;
    box.replaceChildren();
    return;
  }
  const count = profileChangeCount(name);
  box.hidden = false;
  box.replaceChildren(
    el('span', { class: 'profile-pill', text: name }),
    el('span', { class: 'profile-desc', text: describeProfile(name) }),
    el('span', { class: 'profile-count', text: `${count} change${count === 1 ? '' : 's'}` })
  );
}

function renderEntries() {
  renderProfileSummary();
  const f = currentFilters();
  const list = state.entries.filter((entry) => {
    if (f.profile && !isDefaultFor(entry, f.profile)) return false;
    if (f.type && entry.type !== f.type) return false;
    if (f.grade && String(entry.evidenceGrade) !== f.grade) return false;
    if (f.reversible && !entry.reversible) return false;
    if (f.q) {
      const hay = `${entry.id} ${entry.description} ${entry.rationale} ${entry.target} ${entry.type} ${entry.action}`.toLowerCase();
      if (!hay.includes(f.q)) return false;
    }
    return true;
  });

  $('#result-count').textContent = `${list.length} of ${state.entries.length} change${state.entries.length === 1 ? '' : 's'}`;

  const container = $('#entry-list');
  if (!list.length) {
    container.replaceChildren(el('div', { class: 'empty', text: 'No changes match your filters.' }));
    return;
  }

  const sorted = sortEntries(list, f.sort);
  if (f.sort === 'profile') {
    // Group under tier headers so the minimal → default → aggressive → opinionated progression
    // (and the pure opt-in tail) is visible at a glance.
    const nodes = [];
    let lastRank = -1;
    for (const entry of sorted) {
      const rank = entryProfileRank(entry);
      if (rank !== lastRank) {
        nodes.push(renderTierHeader(entry));
        lastRank = rank;
      }
      nodes.push(renderEntryCard(entry));
    }
    container.replaceChildren(...nodes);
    return;
  }
  container.replaceChildren(...sorted.map(renderEntryCard));
}

function renderTierHeader(entry) {
  const tier = entryProfileTier(entry);
  return el('div', { class: 'tier-header' }, [
    el('span', { class: 'tier-label', text: tier.label }),
    el('span', { class: 'tier-note', text: tier.note }),
  ]);
}

function gradeLabel(g) {
  return { 1: 'Grade 1 · Microsoft', 2: 'Grade 2 · 3rd-party', 3: 'Grade 3 · Community' }[g] || `Grade ${g}`;
}

function renderEntryCard(entry) {
  const badges = [el('span', { class: 'badge type', text: entry.type })];
  if (entry.category) badges.push(el('span', { class: 'badge cat', text: entry.category }));
  if (entry.evidenceGrade) badges.push(el('span', { class: `badge g${entry.evidenceGrade}`, text: gradeLabel(entry.evidenceGrade) }));
  if (entry.reversible) badges.push(el('span', { class: 'badge rev', text: 'Reversible' }));

  const head = el('div', { class: 'entry-head' }, [
    el('span', { class: 'chev', text: '▸' }),
    el('div', { class: 'entry-title' }, [
      el('span', { class: 'desc', text: entry.description || entry.id }),
      el('span', { class: 'id', text: entry.id }),
    ]),
    el('div', { class: 'entry-badges' }, badges),
  ]);

  const dl = el('dl');
  const addRow = (dt, ddNode, strong = false) => {
    dl.appendChild(el('dt', { text: dt }));
    dl.appendChild(strong ? ddNode : ddNode);
  };
  if (entry.rationale) addRow('Why', el('dd', { class: 'strong', text: entry.rationale }));
  if (entry.target) addRow('Target', el('dd', {}, [el('span', { class: 'pill', text: entry.target })]));
  if (entry.action) addRow('Action', el('dd', { text: entry.action }));
  addRow('Profiles', el('dd', {}, [el('div', { class: 'pill-row' }, (entry.profiles || []).map((p) => el('span', { class: 'pill', text: p })) || [])]));
  addRow('Arch', el('dd', {}, [el('div', { class: 'pill-row' }, (entry.arch || []).map((a) => el('span', { class: 'pill', text: a })))]));
  if (entry.reversible && entry.reversal) addRow('How to reverse', el('dd', { text: entry.reversal }));
  if (entry.citation) addRow('Citation', el('dd', {}, [el('a', { href: entry.citation, target: '_blank', rel: 'noopener', text: entry.citation })]));

  const body = el('div', { class: 'entry-body' }, [dl]);
  const card = el('div', { class: 'entry' }, [head, body]);
  head.addEventListener('click', () => card.classList.toggle('is-open'));
  return card;
}

// ============================================================================
// Configurator
// ============================================================================
function buildConfigurator() {
  renderOptionFields();
  $('#config-search').addEventListener('input', renderConfigEntries);
  $('#reset-deviations').addEventListener('click', () => {
    state.deviations = {};
    renderConfigEntries();
    updateConfigOutput();
    toast('Reset to profile defaults');
  });
  $('#copy-config').addEventListener('click', copyConfig);
  $('#download-config').addEventListener('click', downloadConfig);
  renderConfigProfileSummary();
  renderConfigEntries();
  updateConfigOutput();
}

// Show the active baseline profile's description under the Profile selector.
function renderConfigProfileSummary() {
  const box = $('#config-profile-summary');
  if (!box) return;
  const desc = describeProfile(state.options.Profile);
  const count = profileChangeCount(state.options.Profile);
  box.replaceChildren(
    el('span', { class: 'profile-pill', text: state.options.Profile }),
    el('span', { class: 'profile-desc', text: desc }),
    el('span', { class: 'profile-count', text: `${count} default change${count === 1 ? '' : 's'}` })
  );
}

function renderOptionFields() {
  const wrap = $('#option-fields');
  const o = state.options;

  const textField = (key, label, hint) =>
    el('label', { class: 'opt' }, [
      el('span', { html: `${escapeHtml(label)}${hint ? ` <small>${escapeHtml(hint)}</small>` : ''}` }),
      el('input', {
        type: 'text',
        value: o[key],
        oninput: (e) => {
          o[key] = e.target.value;
          updateConfigOutput();
        },
      }),
    ]);

  const selectField = (key, label, options, onChange) =>
    el('label', { class: 'opt' }, [
      el('span', { text: label }),
      el(
        'select',
        {
          onchange: (e) => {
            o[key] = e.target.value;
            if (onChange) onChange(e.target.value);
            updateConfigOutput();
          },
        },
        options.map((opt) => el('option', { value: opt, text: opt, ...(o[key] === opt ? { selected: 'selected' } : {}) }))
      ),
    ]);

  const toggleField = (key, label) =>
    el('label', { class: 'opt toggle' }, [
      el('input', {
        type: 'checkbox',
        ...(o[key] ? { checked: 'checked' } : {}),
        onchange: (e) => {
          o[key] = e.target.checked;
          updateConfigOutput();
        },
      }),
      el('span', { text: label }),
    ]);

  wrap.replaceChildren(
    selectField('Profile', 'Profile', (state.manifest.profiles || []).map((p) => p.name), () => {
      // Changing the baseline changes every default, so drop deviations to avoid confusion.
      state.deviations = {};
      renderConfigProfileSummary();
      renderConfigEntries();
    }),
    textField('Edition', 'Edition'),
    selectField('Architecture', 'Architecture', ['amd64', 'arm64'], renderConfigEntries),
    textField('Language', 'Language'),
    textField('Release', 'Release'),
    selectField('AccountMode', 'Account mode', ['local', 'entra']),
    textField('ProductKey', 'Product key', 'required for non-Home'),
    textField('LocalAccountName', 'Local account'),
    toggleField('BootTest', 'Boot test (Hyper-V VM)')
  );
}

function renderConfigEntries() {
  const q = $('#config-search').value.trim().toLowerCase();
  const arch = state.options.Architecture;
  const container = $('#config-entry-list');
  const groups = {};
  for (const entry of state.entries) {
    if (!(entry.arch || []).includes(arch)) continue;
    if (q) {
      const hay = `${entry.id} ${entry.description} ${entry.target}`.toLowerCase();
      if (!hay.includes(q)) continue;
    }
    (groups[entry.type] ||= []).push(entry);
  }

  const nodes = [];
  const deviationCount = Object.keys(state.deviations).length;
  $('#deviation-note').textContent = deviationCount ? `— ${deviationCount} deviation${deviationCount === 1 ? '' : 's'} from ${state.options.Profile}` : '';

  const orderedTypes = Object.keys(groups).sort();
  if (!orderedTypes.length) {
    container.replaceChildren(el('div', { class: 'empty', text: 'No changes match.' }));
    return;
  }
  for (const type of orderedTypes) {
    nodes.push(el('div', { class: 'cfg-group-label', text: type }));
    for (const entry of groups[type]) nodes.push(renderConfigEntry(entry));
  }
  container.replaceChildren(...nodes);
}

function renderConfigEntry(entry) {
  const enabled = currentEnabled(entry);
  const deviated = Object.prototype.hasOwnProperty.call(state.deviations, entry.id);

  const input = el('input', {
    type: 'checkbox',
    ...(enabled ? { checked: 'checked' } : {}),
  });
  input.addEventListener('change', (e) => {
    const want = e.target.checked;
    if (want === isDefaultFor(entry, state.options.Profile)) {
      delete state.deviations[entry.id]; // back to default -> not a deviation
    } else {
      state.deviations[entry.id] = want;
    }
    renderConfigEntries();
    updateConfigOutput();
  });

  const sw = el('label', { class: 'switch' }, [input, el('span', { class: 'track' })]);
  const desc = el('div', { class: 'cfg-desc' }, [
    el('div', { class: 'd', text: entry.description || entry.id }),
    el('div', { class: 'i', text: entry.id }),
  ]);
  const badge = entry.category
    ? el('span', { class: 'badge cat', text: entry.category })
    : el('span', { class: `badge g${entry.evidenceGrade}`, text: `G${entry.evidenceGrade}` });

  return el('div', { class: `cfg-entry${deviated ? ' deviated' : ''}` }, [sw, desc, badge]);
}

// ---------- build.config.psd1 generation ----------
function computeCatalogDeltas() {
  const enable = [];
  const disable = [];
  for (const entry of state.entries) {
    if (!(entry.arch || []).includes(state.options.Architecture)) continue;
    const def = isDefaultFor(entry, state.options.Profile);
    const now = currentEnabled(entry);
    if (now && !def) enable.push(entry.id);
    else if (!now && def) disable.push(entry.id);
  }
  return { enable: enable.sort(), disable: disable.sort() };
}

const q = (s) => `'${String(s).replace(/'/g, "''")}'`; // single-quoted psd1 string
const psdArray = (arr) => (arr.length ? `@(${arr.map(q).join(', ')})` : '@()');

function generateConfigText() {
  const o = state.options;
  const { enable, disable } = computeCatalogDeltas();
  const isHome = /home/i.test(o.Edition);
  const lines = [];
  lines.push('# build.config.psd1 — generated by the windows-iso-maker config builder.');
  lines.push('# Drop this into config/ (or pass it via -ConfigPath / WIM_CONFIG_PATH).');
  lines.push('@{');
  lines.push(`    Edition      = ${q(o.Edition)}`);
  lines.push(`    Language     = ${q(o.Language)}`);
  lines.push(`    Release      = ${q(o.Release)}`);
  lines.push(`    Architecture = ${q(o.Architecture)}`);
  lines.push('');
  lines.push(`    Profile          = ${q(o.Profile)}`);
  lines.push('    Toggles          = @{}');
  lines.push(`    EnableCatalogId  = ${psdArray(enable)}`);
  lines.push(`    DisableCatalogId = ${psdArray(disable)}`);
  lines.push('');
  lines.push('    Autounattend = @{');
  lines.push('        Enabled     = $true');
  lines.push(`        AccountMode = ${q(o.AccountMode)}`);
  if (o.AccountMode === 'local') {
    lines.push(`        LocalAccountName = ${q(o.LocalAccountName || 'Admin')}`);
  }
  if (o.ProductKey.trim()) {
    lines.push(`        ProductKey  = ${q(o.ProductKey.trim())}`);
  } else if (!isHome) {
    lines.push("        # ProductKey required: only Home installs hands-off. Set a genuine key for a");
    lines.push("        # non-Home 24H2 build, or Setup stops at the product-key page.");
    lines.push("        ProductKey  = ''");
  } else {
    lines.push("        ProductKey  = ''  # Home installs hands-off without a key");
  }
  lines.push('    }');
  lines.push('');
  lines.push(`    BootTest = $${o.BootTest ? 'true' : 'false'}`);
  lines.push('}');
  return lines.join('\n');
}

function highlightPsd1(text) {
  return text.split('\n').map(highlightPsd1Line).join('\n');
}

function highlightPsd1Line(line) {
  // Locate a comment '#' that is not inside a single-quoted string (operate on the raw line).
  let inStr = false;
  let commentIdx = -1;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === "'") inStr = !inStr;
    else if (ch === '#' && !inStr) {
      commentIdx = i;
      break;
    }
  }
  const codePart = commentIdx === -1 ? line : line.slice(0, commentIdx);
  const commentPart = commentIdx === -1 ? '' : line.slice(commentIdx);

  let out = escapeHtml(codePart)
    .replace(/&#39;.*?&#39;/g, (m) => `<span class="s">${m}</span>`)
    .replace(/\$(true|false)\b/g, '<span class="n">$$$1</span>')
    .replace(/^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=)/, '$1<span class="k">$2</span>$3');
  if (commentPart) out += `<span class="c">${escapeHtml(commentPart)}</span>`;
  return out;
}

function updateConfigOutput() {
  const text = generateConfigText();
  $('#config-preview').innerHTML = `<code>${highlightPsd1(text)}</code>`;
  $('#config-preview').dataset.raw = text;
}

async function copyConfig() {
  const text = $('#config-preview').dataset.raw || generateConfigText();
  try {
    await navigator.clipboard.writeText(text);
    toast('Copied build.config.psd1');
  } catch {
    toast('Copy failed — select and copy manually');
  }
}

function downloadConfig() {
  const text = $('#config-preview').dataset.raw || generateConfigText();
  const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = el('a', { href: url, download: 'build.config.psd1' });
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
  toast('Downloaded build.config.psd1');
}
