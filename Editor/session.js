const iframe = document.getElementById('doc');
const native = window.webkit?.messageHandlers?.wysi;

let canonical = null;
let mode = 'preview';
let flushTimer = null;

const agentSrc = (await (await fetch('wy-agent.js')).text()).replace(/<\/script/gi, '<\\/script');

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
  iframe.srcdoc = mode === 'edit' ? snapshot() + `<script>${agentSrc}</script>` : serialize();
}

function applyOps(ops) {
  for (const op of ops) {
    const n = nodeAtPath(canonical.body, op.path);
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
  else if (m.type === 'wy-flushed') flushDone();
  else if (m.type === 'wy-undo') notify({ type: 'undo' });
  else if (m.type === 'wy-redo') notify({ type: 'redo' });
  else if (m.type === 'wy-error') notify({ type: 'error', message: m.message });
});

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
  serialize: () => canonical && serialize(),
};

notify({ type: 'ready' });
