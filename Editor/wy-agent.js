(function () {
  'use strict';

  const ACCENT = '#0a84ff';
  const MEDIA = new Set(['IMG', 'SVG', 'VIDEO', 'PICTURE', 'CANVAS', 'IFRAME']);
  const EDIT_BLOCKS = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'LI', 'TD', 'TH', 'DT', 'DD', 'BLOCKQUOTE', 'FIGCAPTION', 'CAPTION', 'PRE', 'SUMMARY']);
  const EDIT_INLINE = new Set(['A', 'BUTTON', 'LABEL', 'SPAN', 'CODE', 'EM', 'STRONG', 'SMALL', 'TIME', 'B', 'I']);

  let editingEl = null;
  let editOrigHtml = null;
  let ring = null;

  function send(msg) {
    parent.postMessage(msg, '*');
  }

  function pathOf(node) {
    const path = [];
    let n = node;
    while (n && n !== document.body) {
      const p = n.parentNode;
      if (!p) return null;
      path.unshift([...p.childNodes].indexOf(n));
      n = p;
    }
    return n === document.body ? path : null;
  }

  function sendOps(ops) {
    const valid = ops.filter(o => o.path);
    if (valid.length) send({ type: 'wy-ops', ops: valid });
  }

  function htmlAncestor(node) {
    let n = node && node.nodeType === 1 ? node : node && node.parentElement;
    while (n && !(n instanceof HTMLElement)) n = n.parentElement;
    return n;
  }

  function mediaAncestor(el) {
    for (let n = el; n && n !== document.body && n.nodeType === 1; n = n.parentElement) {
      if (MEDIA.has(n.tagName.toUpperCase())) return n;
    }
    return null;
  }

  function hasDirectText(el) {
    return [...el.childNodes].some(c => c.nodeType === 3 && c.data.trim());
  }

  function editTarget(start) {
    for (let n = start; n && n !== document.body; n = n.parentElement) {
      if (EDIT_BLOCKS.has(n.tagName)) return n;
    }
    for (let n = start; n && n !== document.body; n = n.parentElement) {
      if (EDIT_INLINE.has(n.tagName) && n.textContent.trim()) return n;
    }
    for (let n = start; n && n !== document.body; n = n.parentElement) {
      if (hasDirectText(n)) return n;
    }
    return null;
  }

  function ensureRing() {
    if (ring) return ring;
    ring = document.createElement('div');
    ring.setAttribute('style', 'position:fixed;pointer-events:none;z-index:2147483640;display:none;border:1.5px dashed;border-radius:3px');
    document.documentElement.appendChild(ring);
    return ring;
  }

  function showRing(el, solid) {
    const r = el.getBoundingClientRect();
    if (!r.width && !r.height) return hideRing();
    const b = ensureRing();
    b.style.borderColor = ACCENT;
    b.style.borderStyle = solid ? 'solid' : 'dashed';
    b.style.left = `${r.left - 3}px`;
    b.style.top = `${r.top - 3}px`;
    b.style.width = `${r.width + 6}px`;
    b.style.height = `${r.height + 6}px`;
    b.style.display = 'block';
  }

  function hideRing() {
    if (ring) ring.style.display = 'none';
  }

  function beginEdit(el, x, y) {
    if (editingEl === el) return;
    commitEdit();
    editingEl = el;
    editOrigHtml = el.innerHTML;
    try { el.contentEditable = 'plaintext-only'; } catch { el.contentEditable = 'true'; }
    el.addEventListener('paste', plainPaste);
    el.addEventListener('focusout', commitEdit);
    el.addEventListener('keydown', onEditKeydown);
    el.focus();
    if (document.caretRangeFromPoint) {
      const range = document.caretRangeFromPoint(x, y);
      if (range) {
        const sel = getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }
    }
    showRing(el, true);
  }

  function teardownEdit(el) {
    el.removeAttribute('contenteditable');
    el.removeEventListener('paste', plainPaste);
    el.removeEventListener('focusout', commitEdit);
    el.removeEventListener('keydown', onEditKeydown);
    hideRing();
  }

  function commitEdit() {
    const el = editingEl;
    if (!el) return;
    editingEl = null;
    teardownEdit(el);
    if (el.innerHTML !== editOrigHtml) {
      const path = pathOf(el);
      if (path) sendOps([{ kind: 'setHTML', path, html: el.innerHTML }]);
    }
  }

  function cancelEdit() {
    const el = editingEl;
    if (!el) return;
    editingEl = null;
    el.innerHTML = editOrigHtml;
    teardownEdit(el);
  }

  function plainPaste(e) {
    e.preventDefault();
    const text = e.clipboardData.getData('text/plain');
    if (text) document.execCommand('insertText', false, text);
  }

  function onEditKeydown(e) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      cancelEdit();
    } else if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      commitEdit();
    }
  }

  document.addEventListener('click', (e) => {
    if (editingEl && editingEl.contains(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    const start = htmlAncestor(e.target);
    if (!start || mediaAncestor(start)) return commitEdit();
    const el = editTarget(start);
    if (el) beginEdit(el, e.clientX, e.clientY);
    else commitEdit();
  }, true);

  document.addEventListener('pointermove', (e) => {
    if (editingEl) return;
    const t = htmlAncestor(e.target);
    if (!t || mediaAncestor(t)) return hideRing();
    const el = editTarget(t);
    if (el) showRing(el, false);
    else hideRing();
  });

  document.addEventListener('keydown', (e) => {
    if (!(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== 'z' || editingEl) return;
    e.preventDefault();
    send({ type: e.shiftKey ? 'wy-redo' : 'wy-undo' });
  });

  window.addEventListener('scroll', () => {
    if (editingEl) showRing(editingEl, true);
    else hideRing();
  }, true);

  window.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || typeof m !== 'object') return;
    if (m.type === 'wy-flush') {
      commitEdit();
      send({ type: 'wy-flushed' });
    }
  });
})();
