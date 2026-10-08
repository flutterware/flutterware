/// The page an export writes beside its JSON.
///
/// One file, no assets, no server — a `file://` open has to work, because the
/// person who most needs to look at this is a translator who was sent a zip.
/// That rules out fetching `keys.json` at runtime, so it is inlined.
///
/// The highlight is drawn here, from the rectangle, rather than burned into
/// the PNG. Same reason the export keeps whole frames: the pixels stay the
/// ones the run captured, and every consumer — this page, a translation
/// service — draws its own box from the same numbers.
library;

import 'dart:convert';

import 'package:flutterware/translations.dart';

String renderTranslationIndex(TranslationExport export) {
  // `<` escaped so a translated string containing `</script>` cannot close the
  // block it is sitting in. The rest of JSON is already HTML-safe here.
  var data = jsonEncode(export.toJson()).replaceAll('<', r'\u003c');
  return '''
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Translations</title>
<style>$_css</style>
<script type="application/json" id="data">$data</script>
<header>
  <h1>Translations</h1>
  <nav id="tabs"></nav>
</header>
<main>
  <aside>
    <input id="q" type="search" placeholder="Filter keys" autocomplete="off">
    <ol id="list"></ol>
  </aside>
  <section id="detail"></section>
</main>
<script>$_js</script>
''';
}

final _css =
    r'''
:root {
  --bg: #ffffff; --fg: #16181d; --dim: #6b7280; --line: #e5e7eb;
  --panel: #f7f8fa; --accent: #2563eb; --warn: #b45309; --bad: #b91c1c;
  --mark: #2563eb;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14161a; --fg: #e8eaed; --dim: #9aa1ab; --line: #2a2e35;
    --panel: #1b1e24; --accent: #7aa2f7; --warn: #d9a441; --bad: #f0797c;
    --mark: #7aa2f7;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 14px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif;
}
header {
  display: flex; align-items: baseline; gap: 24px; flex-wrap: wrap;
  padding: 12px 20px; border-bottom: 1px solid var(--line);
}
h1 { font-size: 15px; margin: 0; font-weight: 600; }
nav { display: flex; gap: 4px; flex-wrap: wrap; }
nav button {
  font: inherit; border: 0; border-radius: 6px; padding: 4px 10px;
  background: transparent; color: var(--dim); cursor: pointer;
}
nav button:hover { background: var(--panel); color: var(--fg); }
nav button[aria-selected="true"] { background: var(--panel); color: var(--fg); }
nav .count { color: var(--dim); font-variant-numeric: tabular-nums; }
nav button[aria-selected="true"] .count { color: var(--accent); }
main { display: flex; align-items: stretch; min-height: calc(100vh - 49px); }
aside {
  width: 300px; flex: none; border-right: 1px solid var(--line);
  display: flex; flex-direction: column; max-height: calc(100vh - 49px);
}
#q {
  font: inherit; margin: 10px; padding: 6px 10px; border-radius: 6px;
  border: 1px solid var(--line); background: var(--bg); color: var(--fg);
}
ol { list-style: none; margin: 0; padding: 0 8px 16px; overflow-y: auto; }
ol li {
  padding: 5px 10px; border-radius: 6px; cursor: pointer;
  display: flex; align-items: center; gap: 8px;
}
ol li:hover { background: var(--panel); }
ol li[aria-selected="true"] { background: var(--panel); color: var(--accent); }
ol .name {
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
}
ol .flag { margin-left: auto; font-size: 11px; color: var(--warn); }
ol .unseen { color: var(--dim); }
section { flex: 1; padding: 20px 24px; overflow-y: auto;
  max-height: calc(100vh - 49px); }
h2 {
  font-size: 16px; margin: 0 0 4px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
.sub { color: var(--dim); margin: 0 0 20px; }
.shot {
  position: relative; display: inline-block; line-height: 0;
  border: 1px solid var(--line); border-radius: 8px; overflow: hidden;
  background: var(--panel);
}
.shot img { max-width: 100%; max-height: 70vh; display: block; }
.box {
  position: absolute; border: 2px solid var(--mark); border-radius: 2px;
  box-shadow: 0 0 0 9999px rgba(0, 0, 0, .12), 0 0 0 1px rgba(255, 255, 255, .6);
}
.shots { display: flex; gap: 16px; flex-wrap: wrap; align-items: flex-start; }
figure { margin: 0; }
figcaption { color: var(--dim); font-size: 12px; padding-top: 6px;
  line-height: 1.4; }
table { border-collapse: collapse; width: 100%; margin: 8px 0 24px; }
th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--line);
  vertical-align: top; }
th { color: var(--dim); font-weight: 500; font-size: 12px; }
td.k, td.mono, th.k {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
}
.locale { color: var(--dim); width: 60px; }
.empty { color: var(--dim); padding: 24px 0; }
.tag {
  display: inline-block; font-size: 11px; padding: 1px 7px; border-radius: 99px;
  background: var(--panel); color: var(--dim); margin-left: 8px;
}
.tag.warn { color: var(--warn); }
.tag.bad { color: var(--bad); }
h3 { font-size: 13px; margin: 24px 0 4px; color: var(--dim);
  font-weight: 500; }
'''
        .trim();

final _js =
    r'''
const data = JSON.parse(document.getElementById('data').textContent);
const keys = data.keys || [];
const f = data.findings || {};
const byId = new Map(keys.map(k => [k.catalog + '/' + k.key, k]));
const fallingBack = new Set((f.fallingBack || []).map(x => x.catalog + '/' + x.key));
const el = (t, c, x) => { const n = document.createElement(t);
  if (c) n.className = c; if (x != null) n.textContent = x; return n; };

const TABS = [
  ['keys', 'Keys', keys.length],
  ['fallingBack', 'Falling back', (f.fallingBack || []).length],
  ['disagrees', 'Disagrees', (f.disagrees || []).length],
  ['overflowing', 'Clipped', (f.overflowing || []).length],
  ['notReached', 'Not reached', (f.notReached || []).length],
  ['absentFromCatalog', 'Not in catalog', (f.absentFromCatalog || []).length],
  ['unkeyed', 'Unkeyed', (f.unkeyed || []).length],
];
// Probe-only tab: absent entirely when no max-length pass ran, because an
// empty list would read as "nothing breaks" where the truth is "nothing was
// asked".
if (data.maxLengths) {
  TABS.push(['expansionBreaks', 'Breaks under expansion',
    (f.expansionBreaks || []).length]);
}
let tab = 'keys';
let selected = keys.length ? keys[0].catalog + '/' + keys[0].key : null;

const nav = document.getElementById('tabs');
for (const [id, label, count] of TABS) {
  const b = el('button', null, label + ' ');
  b.appendChild(el('span', 'count', count));
  b.onclick = () => { tab = id; render(); };
  b.dataset.tab = id;
  nav.appendChild(b);
}

document.getElementById('q').addEventListener('input', renderList);

function renderList() {
  const q = document.getElementById('q').value.toLowerCase();
  const list = document.getElementById('list');
  list.textContent = '';
  for (const k of keys) {
    const id = k.catalog + '/' + k.key;
    const values = Object.values(k.values || {}).join(' ').toLowerCase();
    if (q && !id.toLowerCase().includes(q) && !values.includes(q)) continue;
    const li = el('li');
    li.appendChild(el('span', k.representative ? 'name' : 'name unseen', id));
    if (fallingBack.has(id)) li.appendChild(el('span', 'flag', 'fallback'));
    else if (!k.representative) li.appendChild(el('span', 'flag unseen', 'unseen'));
    li.setAttribute('aria-selected', String(id === selected && tab === 'keys'));
    li.onclick = () => { selected = id; tab = 'keys'; render(); };
    list.appendChild(li);
  }
}

function shotFigure(shot, caption) {
  const fig = el('figure');
  const wrap = el('div', 'shot');
  const img = el('img');
  img.src = shot.image;
  img.alt = '';
  img.loading = 'lazy';
  wrap.appendChild(img);
  if (shot.rect) {
    const box = el('div', 'box');
    wrap.appendChild(box);
    const place = () => {
      const w = img.naturalWidth, h = img.naturalHeight;
      if (!w || !h) return;
      box.style.left = (shot.rect.x / w * 100) + '%';
      box.style.top = (shot.rect.y / h * 100) + '%';
      box.style.width = (shot.rect.width / w * 100) + '%';
      box.style.height = (shot.rect.height / h * 100) + '%';
    };
    img.complete ? place() : img.addEventListener('load', place);
  }
  fig.appendChild(wrap);
  fig.appendChild(el('figcaption', null, caption));
  return fig;
}

function describe(shot) {
  let s = shot.scenario + ' — ' + shot.step;
  if (shot.locale) s += ' · ' + shot.locale;
  if (shot.device) s += ' · ' + shot.device;
  if (shot.overflowed) s += ' · clipped';
  if (shot.offstage) s += ' · offstage';
  return s;
}

function table(head, rows) {
  const t = el('table');
  const tr = el('tr');
  for (const h of head) tr.appendChild(el('th', null, h));
  t.appendChild(tr);
  for (const row of rows) {
    const r = el('tr');
    for (const cell of row) r.appendChild(el('td', 'mono', cell));
    t.appendChild(r);
  }
  return t;
}

function renderKey(host) {
  const k = selected && byId.get(selected);
  if (!k) { host.appendChild(el('p', 'empty', 'No key selected.')); return; }
  host.appendChild(el('h2', null, k.catalog + '/' + k.key));

  const values = Object.entries(k.values || {});
  if (values.length) {
    const t = el('table');
    for (const [locale, value] of values) {
      const r = el('tr');
      r.appendChild(el('td', 'locale', locale));
      r.appendChild(el('td', null, value));
      t.appendChild(r);
    }
    host.appendChild(t);
  } else {
    host.appendChild(el('p', 'sub', 'No catalog file defines this key.'));
  }

  if (k.maxLength) {
    const m = k.maxLength;
    const where = (m.screen ? ' on ' + m.screen.step : '') +
      (m.measuredOn ? ' (' + m.measuredOn + ')' : '');
    const sentence = m.clips
      ? 'Measured: ' + m.chars + ' characters fit' + where + '; ' +
        m.clips.chars + ' were cut off.'
      : 'Measured: at least ' + m.chars + ' characters fit' + where +
        ' \u2014 nothing tried was long enough to clip.';
    const p = el('p', 'sub');
    p.appendChild(el('span', m.clips ? 'tag warn' : 'tag',
      m.clips ? 'max ' + m.chars + ' ch' : '\u2265 ' + m.chars + ' ch'));
    p.appendChild(document.createTextNode(' ' + sentence));
    host.appendChild(p);
    if (m.fits && m.fits.text) {
      const how = el('p', 'sub');
      how.appendChild(document.createTextNode('Fit: \u201c' + m.fits.text +
        '\u201d' + (m.clips && m.clips.text
          ? ' \u00b7 cut off: \u201c' + m.clips.text + '\u201d' : '')));
      host.appendChild(how);
    }
    if (m.clipped) {
      host.appendChild(el('h3', null, 'The clip, photographed'));
      const shots = el('div', 'shots');
      shots.appendChild(shotFigure(m.clipped,
        'The padded string cut off in place \u00b7 ' + describe(m.clipped)));
      host.appendChild(shots);
    }
  }

  if (!k.representative) {
    host.appendChild(el('p', 'empty',
      'Declared, and no scenario in this run showed it.'));
    return;
  }
  host.appendChild(el('h3', null, 'In context'));
  const shots = el('div', 'shots');
  shots.appendChild(shotFigure(k.representative, describe(k.representative)));
  host.appendChild(shots);

  const others = (k.occurrences || []).filter(s =>
    s.image !== k.representative.image ||
    s.stepIndex !== k.representative.stepIndex);
  if (others.length) {
    host.appendChild(el('h3', null, 'Also seen on ' + others.length +
      (others.length === 1 ? ' other screen' : ' other screens')));
    const more = el('div', 'shots');
    for (const s of others) more.appendChild(shotFigure(s, describe(s)));
    host.appendChild(more);
  }
}

function renderFindings(host) {
  const rows = f[tab] || [];
  const label = TABS.find(t => t[0] === tab)[1];
  host.appendChild(el('h2', null, label));
  if (!rows.length) {
    host.appendChild(el('p', 'empty', 'Nothing to report.'));
    return;
  }
  if (tab === 'fallingBack' || tab === 'disagrees') {
    host.appendChild(el('p', 'sub', tab === 'fallingBack'
      ? 'The locale has no text, so the source language rendered instead.'
      : 'The catalog on disk is not what the app ran with.'));
    host.appendChild(table(['Key', 'Locale', 'Rendered', 'Expected'],
      rows.map(r => [r.catalog + '/' + r.key, r.locale, r.rendered,
        r.expected || '—'])));
  } else if (tab === 'overflowing') {
    host.appendChild(el('p', 'sub', 'The words did not fit their box.'));
    const shots = el('div', 'shots');
    for (const s of rows) shots.appendChild(shotFigure(s, describe(s)));
    host.appendChild(shots);
  } else if (tab === 'expansionBreaks') {
    host.appendChild(el('p', 'sub',
      'Screens that broke in the max-length probe, which grows every value ' +
      'on them at once, the way a verbose language would.'));
    host.appendChild(table(['Scenario', 'Step', 'At', 'What broke'],
      rows.map(r => [r.scenario, r.step || '—', '+' + r.level + '%',
        r.failure ? 'scenario failed: ' + r.failure
                  : r.overflows + ' overflow' + (r.overflows === 1 ? '' : 's')])));
  } else if (tab === 'unkeyed') {
    host.appendChild(el('p', 'sub',
      'Words on a screen that belonged to no catalog.'));
    host.appendChild(table(['Text', 'Built at', 'Scenario', 'Step'],
      rows.map(r => [r.text, r.source || '—', r.scenario, r.step])));
  } else {
    host.appendChild(el('p', 'sub', tab === 'notReached'
      ? 'Declared, and this run never asked for them. A key may still be ' +
        'in use on a screen no scenario covers.'
      : 'Read by the app, and no declared catalog defines them.'));
    host.appendChild(table(['Key'],
      rows.map(r => [r.catalog + '/' + r.key])));
  }
}

function render() {
  for (const b of nav.children) {
    b.setAttribute('aria-selected', String(b.dataset.tab === tab));
  }
  const host = document.getElementById('detail');
  host.textContent = '';
  tab === 'keys' ? renderKey(host) : renderFindings(host);
  renderList();
}

render();
'''
        .trim();
