const FILM_W = 168;

const iframe = document.getElementById('doc');
iframe.addEventListener('load', () => iframe.focus());
const native = window.webkit?.messageHandlers?.wysi;

let canonical = null;
let mode = 'preview';
let flushTimer = null;

const agentSrc = (await (await fetch('wy-agent.js')).text()).replace(/<\/script/gi, '<\\/script');
const playSrc = (await (await fetch('wy-play.js')).text()).replace(/<\/script/gi, '<\\/script');

function notify(msg) {
  if (native) native.postMessage(msg);
  else window.dispatchEvent(new CustomEvent('wysi-notify', { detail: msg }));
}

function parse(html) {
  return new DOMParser().parseFromString(html, 'text/html');
}

function serialize() {
  return '<!doctype html>' + canonical.documentElement.outerHTML;
}

function pausedClone() {
  const clone = canonical.cloneNode(true);
  for (const s of clone.querySelectorAll('script')) s.setAttribute('type', 'text/wy-paused');
  return clone;
}

function snapshot() {
  return '<!doctype html>' + pausedClone().documentElement.outerHTML;
}

function nodeAtPath(root, path) {
  let n = root;
  for (const i of path) {
    if (!n || !n.childNodes[i]) return null;
    n = n.childNodes[i];
  }
  return n;
}

function render() {
  if (!canonical) return;
  if (mode !== 'edit') hideFilm();
  iframe.srcdoc = mode === 'edit' ? snapshot() + `<script>${agentSrc}</script>` : serialize() + `<script>${playSrc}</script>`;
}

function applyOps(ops) {
  for (const op of ops) {
    const n = nodeAtPath(op.root === 'head' ? canonical.head : canonical.body, op.path);
    if (!n || n.nodeType !== 1) continue;
    if (op.kind === 'setHTML') n.innerHTML = op.html;
    else if (op.kind === 'remove') n.remove();
    else if (op.kind === 'setAttr') {
      if (op.value === null) n.removeAttribute(op.name);
      else n.setAttribute(op.name, op.value);
    } else if (op.kind === 'move') {
      const ref = op.before ? nodeAtPath(canonical.body, op.before) : null;
      if (op.before && !ref) continue;
      n.parentNode.insertBefore(n, ref);
    } else if (op.kind === 'duplicate') {
      n.parentNode.insertBefore(n.cloneNode(true), n.nextSibling);
    }
  }
  notify({ type: 'changed', html: serialize() });
}

function flushDone() {
  if (!flushTimer) return;
  clearTimeout(flushTimer);
  flushTimer = null;
  notify({ type: 'flushed' });
}

window.addEventListener('message', (e) => {
  if (e.source !== iframe.contentWindow) return;
  const m = e.data;
  if (!m || typeof m !== 'object') return;
  if (m.type === 'wy-ops') applyOps(m.ops);
  else if (m.type === 'wy-found') notify({ type: 'found', found: m.found });
  else if (m.type === 'wy-theme') notify({ type: 'theme', entries: m.entries });
  else if (m.type === 'wy-slides') onSlides(m);
  else if (m.type === 'wy-current') setCurrent(m.index);
  else if (m.type === 'wy-flushed') flushDone();
  else if (m.type === 'wy-undo') notify({ type: 'undo' });
  else if (m.type === 'wy-redo') notify({ type: 'redo' });
  else if (m.type === 'wy-error') notify({ type: 'error', message: m.message });
});

function post(msg) {
  iframe.contentWindow?.postMessage(msg, '*');
}

let filmEl = null;
let cellsEl = null;
let current = -1;
let dragCell = null;
let dragFromY = 0;
let dragging = false;
let suppressClick = false;

function onSlides(m) {
  if (mode !== 'edit' || !m.slides.length) return hideFilm();
  showFilm(m);
}

function setCurrent(i) {
  current = i;
  if (!filmEl || filmEl.hidden) return;
  [...cellsEl.children].forEach((c, j) => c.classList.toggle('wy-e-cur', j === i));
  cellsEl.children[i]?.scrollIntoView({ block: 'nearest' });
}

function cellPath(cell) {
  return cell.dataset.path.split(',').map(Number);
}

function dropBeforeAt(y) {
  for (const c of cellsEl.children) {
    if (c === dragCell) continue;
    const r = c.getBoundingClientRect();
    if (y < r.top + r.height / 2) return c;
  }
  return null;
}

function clearDrop() {
  for (const c of cellsEl.children) c.classList.remove('wy-e-drop-before', 'wy-e-drop-after');
}

function markDrop(before) {
  clearDrop();
  if (before) before.classList.add('wy-e-drop-before');
  else [...cellsEl.children].filter(c => c !== dragCell).pop()?.classList.add('wy-e-drop-after');
}

function commitDrop(y) {
  const before = dropBeforeAt(y);
  if (before === dragCell.nextElementSibling || (!before && !dragCell.nextElementSibling)) return;
  post({ type: 'wy-move', path: cellPath(dragCell), before: before ? cellPath(before) : null });
}

function slideDoc(paths, i, display, flexDirection) {
  const clone = pausedClone();
  paths.forEach((p, j) => {
    const n = nodeAtPath(clone.body, p);
    if (!n || n.nodeType !== 1) return;
    if (j === i) {
      n.style.setProperty('display', display, 'important');
      n.style.setProperty('flex-direction', flexDirection, 'important');
      n.style.setProperty('opacity', '1', 'important');
      n.style.setProperty('visibility', 'visible', 'important');
    } else {
      n.style.setProperty('display', 'none', 'important');
    }
  });
  return '<!doctype html>' + clone.documentElement.outerHTML;
}

function showFilm({ slides, stacked, display, flexDirection, accent }) {
  if (!filmEl) {
    injectFilmStyles();
    filmEl = document.createElement('div');
    filmEl.className = 'wy-e-film';
    cellsEl = document.createElement('div');
    const plusBtn = document.createElement('button');
    plusBtn.type = 'button';
    plusBtn.className = 'wy-e-plus';
    plusBtn.textContent = '+';
    plusBtn.title = 'duplicate current slide';
    plusBtn.addEventListener('click', () => {
      const cell = cellsEl.children[current] ?? cellsEl.lastElementChild;
      if (cell) post({ type: 'wy-duplicate', path: cellPath(cell) });
    });
    filmEl.append(cellsEl, plusBtn);
    document.body.appendChild(filmEl);
  }
  filmEl.hidden = false;
  if (accent) filmEl.style.setProperty('--wy-accent', accent);
  iframe.style.marginLeft = `${FILM_W}px`;
  iframe.style.width = `calc(100% - ${FILM_W}px)`;
  const mainW = iframe.getBoundingClientRect().width;
  const k = (FILM_W - 18) / mainW;
  const snap = stacked ? null : snapshot();
  const paths = slides.map(s => s.path);
  while (cellsEl.children.length > slides.length) cellsEl.lastChild.remove();
  slides.forEach((s, i) => {
    let cell = cellsEl.children[i];
    if (!cell) {
      cell = document.createElement('div');
      cell.className = 'wy-e-slide';
      cell.innerHTML = '<iframe class="wy-e-thumb" sandbox="" scrolling="no" tabindex="-1"></iframe><span class="wy-e-slide-n"></span><button type="button" class="wy-e-slide-d" title="duplicate this slide">⧉</button><button type="button" class="wy-e-slide-x" title="remove this slide">×</button>';
      cell.addEventListener('click', () => {
        if (suppressClick) { suppressClick = false; return; }
        post({ type: 'wy-scroll-to', path: cellPath(cell) });
      });
      cell.addEventListener('pointerdown', (e) => {
        if (e.button !== 0 || e.target.closest('button')) return;
        dragCell = cell;
        dragging = false;
        suppressClick = false;
        dragFromY = e.clientY;
        cell.setPointerCapture(e.pointerId);
      });
      cell.addEventListener('pointermove', (e) => {
        if (dragCell !== cell) return;
        if (!dragging) {
          if (Math.abs(e.clientY - dragFromY) < 4) return;
          dragging = true;
          cell.classList.add('wy-e-drag');
        }
        markDrop(dropBeforeAt(e.clientY));
        const r = filmEl.getBoundingClientRect();
        if (e.clientY < r.top + 28) filmEl.scrollTop -= 12;
        else if (e.clientY > r.bottom - 28) filmEl.scrollTop += 12;
      });
      const endDrag = (e) => {
        if (dragCell !== cell) return;
        if (dragging && e.type === 'pointerup') {
          suppressClick = true;
          commitDrop(e.clientY);
        }
        dragging = false;
        dragCell = null;
        cell.classList.remove('wy-e-drag');
        clearDrop();
      };
      cell.addEventListener('pointerup', endDrag);
      cell.addEventListener('pointercancel', endDrag);
      cell.querySelector('.wy-e-slide-x').addEventListener('click', (e) => {
        e.stopPropagation();
        post({ type: 'wy-remove', path: cellPath(cell) });
      });
      cell.querySelector('.wy-e-slide-d').addEventListener('click', (e) => {
        e.stopPropagation();
        post({ type: 'wy-duplicate', path: cellPath(cell) });
      });
      cellsEl.appendChild(cell);
    }
    cell.dataset.path = s.path.join(',');
    cell.style.height = `${s.height * k}px`;
    cell.querySelector('.wy-e-slide-n').textContent = i + 1;
    const thumb = cell.querySelector('.wy-e-thumb');
    thumb.style.width = `${mainW}px`;
    thumb.style.height = `${s.height}px`;
    thumb.style.transform = `scale(${k})`;
    const doc = (stacked
      ? slideDoc(paths, i, display, flexDirection)
      : snap + `<style>html{transform:translateY(-${s.top}px)}</style>`)
      + '<style>html,body{overflow:hidden!important}</style>';
    if (thumb.dataset.doc !== doc) {
      thumb.dataset.doc = doc;
      thumb.srcdoc = doc;
    }
  });
  setCurrent(current);
}

function hideFilm() {
  if (!filmEl) return;
  filmEl.hidden = true;
  iframe.style.marginLeft = '';
  iframe.style.width = '100%';
}

let filmStylesDone = false;

function injectFilmStyles() {
  if (filmStylesDone) return;
  filmStylesDone = true;
  const style = document.createElement('style');
  style.textContent = `
.wy-e-film{position:fixed;top:0;left:0;bottom:0;width:${FILM_W}px;box-sizing:border-box;z-index:100;background:#0a0a0a;border-right:1px solid #3f3f46;overflow-y:auto;padding:10px 9px;user-select:none;-webkit-user-select:none}
.wy-e-thumb{display:block;border:0;background:#fff;transform-origin:0 0;pointer-events:none}
.wy-e-slide{position:relative;overflow:hidden;margin-bottom:8px;cursor:pointer;border:1px solid #3f3f46;border-radius:3px;background:#fff}
.wy-e-slide:hover{border-color:var(--wy-accent, #0a84ff)}
.wy-e-slide-n{position:absolute;left:4px;bottom:3px;font:10px/1.4 ui-sans-serif,system-ui,-apple-system,sans-serif;color:#e4e4e7;background:rgba(10,10,10,.65);padding:0 4px;border-radius:3px}
.wy-e-slide-x,.wy-e-slide-d{position:absolute;top:3px;display:none;width:18px;height:18px;padding:0;background:#0a0a0a;color:#e4e4e7;border:1px solid #3f3f46;border-radius:3px;font:12px/1 ui-sans-serif,system-ui,-apple-system,sans-serif;cursor:pointer}
.wy-e-slide-x{right:3px}
.wy-e-slide-d{right:24px}
.wy-e-slide:hover .wy-e-slide-x,.wy-e-slide:hover .wy-e-slide-d{display:block}
.wy-e-slide-x:hover,.wy-e-slide-d:hover{background:var(--wy-accent, #0a84ff);border-color:var(--wy-accent, #0a84ff);color:#fff}
.wy-e-slide.wy-e-cur{border-color:var(--wy-accent, #0a84ff);box-shadow:0 0 0 1px var(--wy-accent, #0a84ff)}
.wy-e-slide.wy-e-cur .wy-e-slide-n{background:var(--wy-accent, #0a84ff);color:#fff}
.wy-e-slide.wy-e-drag{opacity:.4;cursor:grabbing}
.wy-e-slide.wy-e-drop-before{box-shadow:0 -5px 0 -2px var(--wy-accent, #0a84ff)}
.wy-e-slide.wy-e-drop-after{box-shadow:0 5px 0 -2px var(--wy-accent, #0a84ff)}
.wy-e-plus{width:100%;padding:.4rem 0;margin:2px 0 12px;background:#0a0a0a;color:#e4e4e7;border:1px dashed #3f3f46;border-radius:3px;font:16px/1 ui-sans-serif,system-ui,-apple-system,sans-serif;cursor:pointer}
.wy-e-plus:hover{border-color:var(--wy-accent, #0a84ff);color:#fff}
`;
  document.head.appendChild(style);
}

window.addEventListener('keydown', (e) => {
  if (!(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== 'z') return;
  e.preventDefault();
  notify({ type: e.shiftKey ? 'redo' : 'undo' });
});

window.wysi = {
  load(html, newMode) {
    canonical = parse(html);
    if (newMode) mode = newMode;
    render();
  },
  setMode(next) {
    if (next === mode) return;
    mode = next;
    render();
  },
  flush() {
    if (flushTimer) return;
    if (mode !== 'edit' || !iframe.contentWindow) return notify({ type: 'flushed' });
    flushTimer = setTimeout(flushDone, 1000);
    iframe.contentWindow.postMessage({ type: 'wy-flush' }, '*');
  },
  find(text, backwards) {
    post({ type: 'wy-find', text, backwards });
  },
  themePreview(index, value) {
    post({ type: 'wy-theme-preview', index, value });
  },
  themeCommit(index, value) {
    post({ type: 'wy-theme-commit', index, value });
  },
  serialize: () => canonical && serialize(),
};

notify({ type: 'ready' });
