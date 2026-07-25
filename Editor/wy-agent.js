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

  function nodeFromPath(path) {
    let n = document.body;
    for (const i of path) {
      if (!n || !n.childNodes[i]) return null;
      n = n.childNodes[i];
    }
    return n;
  }

  function sendOps(ops) {
    const valid = ops.filter(o => o.path);
    if (valid.length) send({ type: 'wy-ops', ops: valid });
    scheduleSlides();
  }

  const SLIDE_SKIP = new Set(['SCRIPT', 'STYLE', 'LINK', 'TEMPLATE']);
  let slideDeck = null;
  let slidesTimer = null;
  let currentSent = -1;
  let currentPending = false;

  function slideKids(el) {
    return [...el.children].filter(c => !SLIDE_SKIP.has(c.tagName));
  }

  function slideGroup(el) {
    const byTag = new Map();
    for (const k of slideKids(el)) {
      if (!byTag.has(k.tagName)) byTag.set(k.tagName, []);
      byTag.get(k.tagName).push(k);
    }
    let best = [];
    for (const g of byTag.values()) if (g.length > best.length) best = g;
    return best.length >= 3 ? best : null;
  }

  function fillsViewport(el) {
    return el.getBoundingClientRect().height >= innerHeight * 0.7;
  }

  function detectDeck() {
    const queue = [document.body];
    while (queue.length) {
      const el = queue.shift();
      const group = slideGroup(el);
      if (group) {
        const tag = group[0].tagName;
        if (group.filter(fillsViewport).length >= group.length - 1) {
          return { host: el, tag, stacked: false };
        }
        const shown = group.filter(k => getComputedStyle(k).display !== 'none');
        if (group.length - shown.length >= group.length - 1
            && group.every(k => getComputedStyle(k).position === 'absolute')
            && (shown.length ? shown.every(fillsViewport) : fillsViewport(el))) {
          const cs = shown.length ? getComputedStyle(shown[0]) : null;
          return {
            host: el,
            tag,
            stacked: true,
            display: cs ? cs.display : 'block',
            flexDirection: cs ? cs.flexDirection : 'row',
          };
        }
      }
      queue.push(...slideKids(el));
    }
    return null;
  }

  function linearize(slides) {
    for (const s of slides) {
      s.style.setProperty('display', slideDeck.display, 'important');
      s.style.setProperty('flex-direction', slideDeck.flexDirection, 'important');
      s.style.setProperty('position', 'relative', 'important');
      s.style.setProperty('inset', 'auto', 'important');
      s.style.setProperty('height', '100vh', 'important');
    }
    for (let n = slideDeck.host; n; n = n.parentElement) {
      n.style.setProperty('overflow', 'visible', 'important');
      n.style.setProperty('height', 'auto', 'important');
    }
  }

  function deckMembers() {
    return slideKids(slideDeck.host).filter(k => k.tagName === slideDeck.tag);
  }

  function emitSlides() {
    if (!slideDeck || !slideDeck.host.isConnected) slideDeck = detectDeck();
    if (!slideDeck) return send({ type: 'wy-slides', slides: [] });
    const members = deckMembers();
    if (slideDeck.stacked) linearize(members);
    const slides = members.map(el => {
      const r = el.getBoundingClientRect();
      return { path: pathOf(el), top: r.top + scrollY, height: r.height };
    }).filter(s => s.path && s.height > 0);
    send({
      type: 'wy-slides',
      stacked: slideDeck.stacked,
      display: slideDeck.display,
      flexDirection: slideDeck.flexDirection,
      slides,
    });
    currentSent = -1;
    emitCurrent();
  }

  function emitCurrent() {
    if (!slideDeck) return;
    const mid = innerHeight / 2;
    let cur = -1;
    let best = Infinity;
    deckMembers().forEach((el, i) => {
      const r = el.getBoundingClientRect();
      const d = Math.abs((r.top + r.bottom) / 2 - mid);
      if (d < best) { best = d; cur = i; }
    });
    if (cur === currentSent) return;
    currentSent = cur;
    send({ type: 'wy-current', index: cur });
  }

  function scheduleSlides() {
    clearTimeout(slidesTimer);
    slidesTimer = setTimeout(emitSlides, 200);
  }

  function removeSlide(path) {
    const el = nodeFromPath(path);
    if (!el || el.nodeType !== 1) return;
    el.remove();
    sendOps([{ kind: 'remove', path }]);
  }

  function moveSlide(path, before) {
    const el = nodeFromPath(path);
    if (!el || el.nodeType !== 1) return;
    const ref = before ? nodeFromPath(before) : null;
    if (before && !ref) return;
    el.parentNode.insertBefore(el, ref);
    sendOps([{ kind: 'move', path, before }]);
  }

  function duplicateSlide(path) {
    const el = nodeFromPath(path);
    if (!el || el.nodeType !== 1) return;
    el.parentNode.insertBefore(el.cloneNode(true), el.nextSibling);
    sendOps([{ kind: 'duplicate', path }]);
  }

  function scrollToSlide(path) {
    const el = nodeFromPath(path);
    if (el && el.nodeType === 1) el.scrollIntoView({ block: 'center' });
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

  window.addEventListener('scroll', () => {
    if (currentPending) return;
    currentPending = true;
    requestAnimationFrame(() => {
      currentPending = false;
      emitCurrent();
    });
  }, true);

  window.addEventListener('resize', scheduleSlides);
  window.addEventListener('load', scheduleSlides);

  window.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || typeof m !== 'object') return;
    if (m.type === 'wy-flush') {
      commitEdit();
      send({ type: 'wy-flushed' });
    } else if (m.type === 'wy-remove') removeSlide(m.path);
    else if (m.type === 'wy-move') moveSlide(m.path, m.before);
    else if (m.type === 'wy-duplicate') duplicateSlide(m.path);
    else if (m.type === 'wy-scroll-to') scrollToSlide(m.path);
  });

  scheduleSlides();
})();
