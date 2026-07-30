(function () {
  'use strict';

  let ACCENT = '#0a84ff';
  const MEDIA = new Set(['IMG', 'SVG', 'VIDEO', 'PICTURE', 'CANVAS', 'IFRAME']);
  const EDIT_BLOCKS = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'LI', 'TD', 'TH', 'DT', 'DD', 'BLOCKQUOTE', 'FIGCAPTION', 'CAPTION', 'PRE', 'SUMMARY']);
  const EDIT_INLINE = new Set(['A', 'BUTTON', 'LABEL', 'SPAN', 'CODE', 'EM', 'STRONG', 'SMALL', 'TIME', 'B', 'I']);
  const INLINE_LIMIT = 300 * 1024;
  const MAX_DIM = 1600;
  const MAX_DATA = 2.5 * 1024 * 1024;
  const GRIP_SIDES = { left: 'ew-resize', right: 'ew-resize', top: 'ns-resize', bottom: 'ns-resize' };
  const SEAM_TOL = 1.5;
  const MIN_SIZE = 24;

  let editingEl = null;
  let editOrigHtml = null;
  let ring = null;
  let replacePill = null;
  let pillImg = null;
  let filePicker = null;
  let dropImg = null;
  let moveHandle = null;
  let moveLine = null;
  let moveEl = null;
  let movingEl = null;
  let moveSpot = null;
  let moveOrigOpacity = '';
  let formatBar = null;
  let barTarget = null;
  let barBold = null;
  let barItalic = null;
  let barAlign = null;
  let barColorBtn = null;
  let barBgBtn = null;
  let barColorInput = null;
  let barBgInput = null;
  const grips = {};
  const gripModes = {};
  let gripEl = null;
  let resizing = null;

  function send(msg) {
    parent.postMessage(msg, '*');
  }

  function pathIn(root, node) {
    const path = [];
    let n = node;
    while (n && n !== root) {
      const p = n.parentNode;
      if (!p) return null;
      path.unshift([...p.childNodes].indexOf(n));
      n = p;
    }
    return n === root ? path : null;
  }

  function pathOf(node) {
    return pathIn(document.body, node);
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

  function hiddenish(el) {
    const cs = getComputedStyle(el);
    return cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.05;
  }

  function detectDeck() {
    const queue = [document.body];
    while (queue.length) {
      const el = queue.shift();
      const group = slideGroup(el);
      if (group) {
        const tag = group[0].tagName;
        if (group.every(k => getComputedStyle(k).position === 'absolute')) {
          const shown = group.filter(k => !hiddenish(k));
          if (group.length - shown.length >= group.length - 1
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
        } else if (group.filter(fillsViewport).length >= group.length - 1) {
          return { host: el, tag, stacked: false };
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
      s.style.setProperty('opacity', '1', 'important');
      s.style.setProperty('visibility', 'visible', 'important');
    }
    for (let n = slideDeck.host; n; n = n.parentElement) {
      n.style.setProperty('overflow', 'visible', 'important');
      n.style.setProperty('height', 'auto', 'important');
      if (getComputedStyle(n).position === 'fixed') n.style.setProperty('position', 'static', 'important');
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
      accent: ACCENT,
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

  function stepSlide(delta) {
    const members = deckMembers();
    if (!members.length) return false;
    const mid = innerHeight / 2;
    let cur = 0;
    let best = Infinity;
    members.forEach((el, i) => {
      const r = el.getBoundingClientRect();
      const d = Math.abs((r.top + r.bottom) / 2 - mid);
      if (d < best) { best = d; cur = i; }
    });
    members[Math.min(members.length - 1, Math.max(0, cur + delta))]
      .scrollIntoView({ block: 'center', behavior: 'smooth' });
    return true;
  }

  document.addEventListener('keydown', (e) => {
    if (editingEl || e.metaKey || e.ctrlKey || e.altKey) return;
    const fwd = e.key === 'ArrowDown' || e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ';
    const back = e.key === 'ArrowUp' || e.key === 'ArrowLeft' || e.key === 'PageUp';
    if (!fwd && !back) return;
    e.preventDefault();
    if (slideDeck && slideDeck.host.isConnected && stepSlide(fwd ? 1 : -1)) return;
    scrollBy({ top: (fwd ? 1 : -1) * innerHeight * 0.85, behavior: 'smooth' });
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') commitEdit();
  });

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
    showFormatBar(el);
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
    hideFormatBar();
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
    if (replacePill && replacePill.contains(e.target)) return;
    if (moveHandle && moveHandle.contains(e.target)) return;
    if (formatBar && formatBar.contains(e.target)) return;
    if (isGrip(e.target)) return;
    if (editingEl && editingEl.contains(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    const start = htmlAncestor(e.target);
    if (!start || mediaAncestor(start)) {
      hideFormatBar();
      return commitEdit();
    }
    const el = editTarget(start);
    if (el) {
      beginEdit(el, e.clientX, e.clientY);
    } else {
      hideFormatBar();
      commitEdit();
    }
  }, true);

  document.addEventListener('pointermove', (e) => {
    if (editingEl || movingEl || resizing) return;
    if (replacePill && replacePill.contains(e.target)) return;
    if (moveHandle && moveHandle.contains(e.target)) return;
    if (formatBar && formatBar.contains(e.target)) return;
    if (isGrip(e.target)) return;
    const t = htmlAncestor(e.target);
    if (!t) {
      hideRing();
      hideReplacePill();
      hideMoveHandle();
      hideGrips();
      return;
    }
    showMoveHandle(moveTarget(t));
    showGrips(boxTarget(t));
    const media = mediaAncestor(t);
    if (media) {
      showRing(media, false);
      showReplacePill(media);
      return;
    }
    hideReplacePill();
    const el = editTarget(t);
    if (el) showRing(el, false);
    else hideRing();
  });

  function ensureReplacePill() {
    if (replacePill) return replacePill;
    replacePill = document.createElement('button');
    replacePill.type = 'button';
    replacePill.textContent = '↺ replace';
    replacePill.setAttribute('style', 'position:fixed;z-index:2147483646;display:none;cursor:pointer;font:600 12px/1 ui-sans-serif,system-ui,-apple-system,sans-serif;letter-spacing:.03em;padding:.34rem .55rem;border-radius:6px;border:1px solid;color:#fff;box-shadow:0 2px 10px rgba(15,18,25,.3)');
    replacePill.addEventListener('mousedown', (e) => e.preventDefault());
    replacePill.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (pillImg) pickFileFor(pillImg);
    });
    document.documentElement.appendChild(replacePill);
    return replacePill;
  }

  function inViewport(r) {
    return r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
  }

  function showReplacePill(media) {
    if (media.tagName !== 'IMG') return hideReplacePill();
    const r = media.getBoundingClientRect();
    if (!r.width || !r.height || !inViewport(r)) return hideReplacePill();
    pillImg = media;
    const b = ensureReplacePill();
    b.style.background = ACCENT;
    b.style.borderColor = ACCENT;
    b.style.display = 'block';
    b.style.left = `${Math.max(6, r.left + 6)}px`;
    b.style.top = `${Math.max(6, r.top + 6)}px`;
  }

  function hideReplacePill() {
    pillImg = null;
    if (replacePill) replacePill.style.display = 'none';
  }

  function pickFileFor(img) {
    if (!filePicker) {
      filePicker = document.createElement('input');
      filePicker.type = 'file';
      filePicker.accept = 'image/*';
      filePicker.style.display = 'none';
      document.documentElement.appendChild(filePicker);
    }
    filePicker.onchange = () => {
      const f = filePicker.files[0];
      filePicker.value = '';
      if (f) replaceImage(img, f);
    };
    filePicker.click();
  }

  function imgAtPoint(x, y) {
    const n = document.elementFromPoint(x, y);
    const t = n && htmlAncestor(n);
    const media = t && mediaAncestor(t);
    return media && media.tagName === 'IMG' ? media : null;
  }

  document.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropImg = imgAtPoint(e.clientX, e.clientY);
    if (dropImg) {
      showRing(dropImg, true);
      e.dataTransfer.dropEffect = 'copy';
    } else {
      hideRing();
    }
  });

  document.addEventListener('drop', (e) => {
    e.preventDefault();
    const img = dropImg || imgAtPoint(e.clientX, e.clientY);
    dropImg = null;
    hideRing();
    const f = e.dataTransfer.files && e.dataTransfer.files[0];
    if (img && f) replaceImage(img, f);
  });

  async function replaceImage(img, file) {
    const dataUri = await encodeImage(file);
    if (!dataUri) return send({ type: 'wy-error', message: 'unsupported image, or too large after compression' });
    const picture = img.closest('picture');
    if (picture) {
      for (const s of [...picture.querySelectorAll('source')]) s.remove();
      img.src = dataUri;
      img.removeAttribute('srcset');
      img.removeAttribute('sizes');
      const path = pathOf(picture);
      if (path) sendOps([{ kind: 'setHTML', path, html: picture.innerHTML }]);
      return;
    }
    const path = pathOf(img);
    if (!path) return;
    const ops = [{ kind: 'setAttr', path, name: 'src', value: dataUri }];
    img.src = dataUri;
    for (const attr of ['srcset', 'sizes']) {
      if (img.hasAttribute(attr)) {
        img.removeAttribute(attr);
        ops.push({ kind: 'setAttr', path, name: attr, value: null });
      }
    }
    sendOps(ops);
  }

  function readAsDataUrl(file) {
    return new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(r.result);
      r.onerror = reject;
      r.readAsDataURL(file);
    });
  }

  async function encodeImage(file) {
    if (!/^image\//.test(file.type)) return null;
    if (file.type === 'image/svg+xml' || file.size < INLINE_LIMIT) {
      const uri = await readAsDataUrl(file);
      return uri.length <= MAX_DATA ? uri : null;
    }
    let bmp;
    try { bmp = await createImageBitmap(file); } catch { return null; }
    const scale = Math.min(1, MAX_DIM / Math.max(bmp.width, bmp.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(bmp.width * scale));
    canvas.height = Math.max(1, Math.round(bmp.height * scale));
    canvas.getContext('2d').drawImage(bmp, 0, 0, canvas.width, canvas.height);
    let out = canvas.toDataURL('image/webp', 0.85);
    if (!out.startsWith('data:image/webp')) out = canvas.toDataURL('image/jpeg', 0.85);
    return out.length <= MAX_DATA ? out : null;
  }

  function repeatedUnit(el) {
    return [...el.parentElement.children].filter(c => c.tagName === el.tagName).length >= 2;
  }

  function ancestorBox(start, ok) {
    for (let n = start; n && n !== document.body && n.parentElement; n = n.parentElement) {
      const r = n.getBoundingClientRect();
      if (r.width && r.height && ok(n)) return n;
    }
    return null;
  }

  function moveTarget(start) {
    return ancestorBox(start, repeatedUnit);
  }

  function boxTarget(start) {
    return ancestorBox(start, n => repeatedUnit(n) || /flex|grid/.test(getComputedStyle(n.parentElement).display));
  }

  function ensureMoveHandle() {
    if (moveHandle) return moveHandle;
    moveHandle = document.createElement('button');
    moveHandle.type = 'button';
    moveHandle.textContent = '✥';
    moveHandle.setAttribute('data-wy-handle', '');
    moveHandle.setAttribute('style', 'position:fixed;z-index:2147483646;display:none;cursor:grab;font:600 12px/1 ui-sans-serif,system-ui,-apple-system,sans-serif;width:22px;height:22px;padding:0;border-radius:6px;border:1px solid;color:#fff;box-shadow:0 2px 10px rgba(15,18,25,.3);touch-action:none');
    moveHandle.addEventListener('pointerenter', () => { if (moveEl) showRing(moveEl, true); });
    moveHandle.addEventListener('pointerdown', startMove);
    document.documentElement.appendChild(moveHandle);
    return moveHandle;
  }

  function showMoveHandle(el) {
    if (!el) return hideMoveHandle();
    const r = el.getBoundingClientRect();
    if (!inViewport(r)) return hideMoveHandle();
    moveEl = el;
    const h = ensureMoveHandle();
    h.style.background = ACCENT;
    h.style.borderColor = ACCENT;
    h.style.display = 'block';
    h.style.left = `${Math.min(innerWidth - 28, r.right - 28)}px`;
    h.style.top = `${Math.max(6, r.top + 6)}px`;
  }

  function hideMoveHandle() {
    moveEl = null;
    if (moveHandle) moveHandle.style.display = 'none';
  }

  function ensureMoveLine() {
    if (moveLine) return moveLine;
    moveLine = document.createElement('div');
    moveLine.setAttribute('style', 'position:fixed;pointer-events:none;z-index:2147483645;display:none;border-radius:1px');
    document.documentElement.appendChild(moveLine);
    return moveLine;
  }

  function showMoveLine(r, side) {
    const l = ensureMoveLine();
    l.style.background = ACCENT;
    if (side === 'left' || side === 'right') {
      l.style.width = '3px';
      l.style.height = `${r.height}px`;
      l.style.left = `${(side === 'left' ? r.left : r.right) - 1.5}px`;
      l.style.top = `${r.top}px`;
    } else {
      l.style.height = '3px';
      l.style.width = `${r.width}px`;
      l.style.top = `${(side === 'top' ? r.top : r.bottom) - 1.5}px`;
      l.style.left = `${r.left}px`;
    }
    l.style.display = 'block';
  }

  function hideMoveLine() {
    if (moveLine) moveLine.style.display = 'none';
  }

  function dropSpot(target, x, y) {
    const sibs = [...target.parentElement.children].filter(c => c.tagName === target.tagName && c !== target);
    let best = null;
    let bestD = Infinity;
    for (const s of sibs) {
      const r = s.getBoundingClientRect();
      const d = (x - r.left - r.width / 2) ** 2 + (y - r.top - r.height / 2) ** 2;
      if (d < bestD) { bestD = d; best = s; }
    }
    if (!best) return null;
    const r = best.getBoundingClientRect();
    const dx = (x - r.left - r.width / 2) / (r.width || 1);
    const dy = (y - r.top - r.height / 2) / (r.height || 1);
    const row = Math.abs(dx) > Math.abs(dy);
    const after = row ? dx > 0 : dy > 0;
    return {
      ref: after ? best.nextSibling : best,
      rect: r,
      side: row ? (after ? 'right' : 'left') : (after ? 'bottom' : 'top'),
    };
  }

  function startMove(e) {
    if (e.button !== 0 || !moveEl) return;
    e.preventDefault();
    movingEl = moveEl;
    moveSpot = null;
    try { moveHandle.setPointerCapture(e.pointerId); } catch {}
    moveOrigOpacity = movingEl.style.opacity;
    movingEl.style.opacity = '0.4';
    moveHandle.style.cursor = 'grabbing';
    hideRing();
    hideReplacePill();
    hideFormatBar();
    hideGrips();
    moveHandle.addEventListener('pointermove', onMoveDrag);
    moveHandle.addEventListener('pointerup', endMoveDrag);
    moveHandle.addEventListener('pointercancel', endMoveDrag);
  }

  function onMoveDrag(e) {
    moveSpot = dropSpot(movingEl, e.clientX, e.clientY);
    if (moveSpot) showMoveLine(moveSpot.rect, moveSpot.side);
    else hideMoveLine();
  }

  function endMoveDrag(e) {
    moveHandle.removeEventListener('pointermove', onMoveDrag);
    moveHandle.removeEventListener('pointerup', endMoveDrag);
    moveHandle.removeEventListener('pointercancel', endMoveDrag);
    const el = movingEl;
    const spot = e.type === 'pointerup' ? moveSpot : null;
    movingEl = null;
    moveSpot = null;
    hideMoveLine();
    hideMoveHandle();
    moveHandle.style.cursor = 'grab';
    el.style.opacity = moveOrigOpacity;
    if (!el.getAttribute('style')) el.removeAttribute('style');
    if (spot) commitMove(el, spot.ref);
  }

  function commitMove(el, ref) {
    if (ref === el || ref === el.nextSibling) return;
    const path = pathOf(el);
    const before = ref ? pathOf(ref) : null;
    if (!path || (ref && !before)) return;
    el.parentNode.insertBefore(el, ref);
    sendOps([{ kind: 'move', path, before }]);
  }

  function localScale(el) {
    return el.offsetWidth ? el.getBoundingClientRect().width / el.offsetWidth : 1;
  }

  function trackBands(parent, axis) {
    const cs = getComputedStyle(parent);
    const list = (axis === 'x' ? cs.gridTemplateColumns : cs.gridTemplateRows).split(' ').map(parseFloat);
    if (list.length < 2 || list.some(n => !isFinite(n))) return null;
    return { list, gap: parseFloat(axis === 'x' ? cs.columnGap : cs.rowGap) || 0 };
  }

  function seamAt(el, parent, side, axis) {
    const bands = trackBands(parent, axis);
    if (!bands) return null;
    const k = localScale(parent);
    const pr = parent.getBoundingClientRect();
    const pcs = getComputedStyle(parent);
    const r = el.getBoundingClientRect();
    const near = side === 'left' || side === 'top';
    const origin = axis === 'x'
      ? pr.left + (parseFloat(pcs.borderLeftWidth) + parseFloat(pcs.paddingLeft)) * k
      : pr.top + (parseFloat(pcs.borderTopWidth) + parseFloat(pcs.paddingTop)) * k;
    const edge = ((axis === 'x' ? (near ? r.left : r.right) : (near ? r.top : r.bottom)) - origin) / k;
    let at = 0;
    for (let i = 0; i < bands.list.length; i++) {
      if (near && i && Math.abs(edge - at) <= SEAM_TOL) return i - 1;
      at += bands.list[i];
      if (!near && i < bands.list.length - 1 && Math.abs(edge - at) <= SEAM_TOL) return i;
      at += bands.gap;
    }
    return null;
  }

  function resizeMode(el, side) {
    const parent = el.parentElement;
    const axis = side === 'left' || side === 'right' ? 'x' : 'y';
    const pos = getComputedStyle(el).position;
    const display = pos === 'absolute' || pos === 'fixed' ? '' : getComputedStyle(parent).display;
    if (/grid/.test(display)) {
      const seam = seamAt(el, parent, side, axis);
      return seam === null ? null : { kind: 'grid', axis, seam, parent };
    }
    if (side === 'left' || side === 'top') return null;
    const main = /flex/.test(display) && getComputedStyle(parent).flexDirection === (axis === 'x' ? 'row' : 'column');
    return { kind: main ? 'flex' : 'size', axis };
  }

  function isGrip(node) {
    return node instanceof Element && node.hasAttribute('data-wy-grip');
  }

  function ensureGrip(side) {
    if (grips[side]) return grips[side];
    const g = document.createElement('div');
    g.setAttribute('data-wy-grip', side);
    g.setAttribute('style', `position:fixed;z-index:2147483646;display:none;border-radius:3px;cursor:${GRIP_SIDES[side]};touch-action:none`);
    g.addEventListener('pointerenter', () => { if (gripEl) showRing(gripEl, true); });
    g.addEventListener('pointerdown', (e) => startResize(e, side));
    document.documentElement.appendChild(g);
    grips[side] = g;
    return g;
  }

  function placeGrip(side, r) {
    const horiz = side === 'left' || side === 'right';
    const g = grips[side];
    g.style.background = ACCENT;
    g.style.display = 'block';
    g.style.width = `${horiz ? 6 : 28}px`;
    g.style.height = `${horiz ? 28 : 6}px`;
    g.style.left = `${(horiz ? (side === 'left' ? r.left : r.right) : (r.left + r.right) / 2) - (horiz ? 3 : 14)}px`;
    g.style.top = `${(horiz ? (r.top + r.bottom) / 2 : (side === 'top' ? r.top : r.bottom)) - (horiz ? 14 : 3)}px`;
  }

  function showGrips(el) {
    if (!el) return hideGrips();
    const r = el.getBoundingClientRect();
    if (!inViewport(r)) return hideGrips();
    if (gripEl !== el) {
      gripEl = el;
      for (const side of Object.keys(GRIP_SIDES)) {
        ensureGrip(side);
        gripModes[side] = resizeMode(el, side);
      }
    }
    for (const side of Object.keys(GRIP_SIDES)) {
      if (gripModes[side]) placeGrip(side, r);
      else grips[side].style.display = 'none';
    }
  }

  function hideGrips() {
    gripEl = null;
    for (const g of Object.values(grips)) g.style.display = 'none';
  }

  function startResize(e, side) {
    const el = gripEl;
    const mode = gripModes[side];
    if (e.button !== 0 || !el || !mode) return;
    e.preventDefault();
    e.stopPropagation();
    const g = grips[side];
    try { g.setPointerCapture(e.pointerId); } catch {}
    resizing = {
      el,
      side,
      mode,
      moved: false,
      k: localScale(mode.kind === 'grid' ? mode.parent : el),
      from: mode.axis === 'x' ? e.clientX : e.clientY,
      bands: mode.kind === 'grid' ? trackBands(mode.parent, mode.axis) : null,
      base: mode.kind === 'grid' ? 0 : parseFloat(getComputedStyle(el)[mode.axis === 'x' ? 'width' : 'height']),
    };
    for (const s of Object.keys(GRIP_SIDES)) if (s !== side) grips[s].style.display = 'none';
    hideReplacePill();
    hideMoveHandle();
    hideFormatBar();
    showRing(el, true);
    g.addEventListener('pointermove', onResizeDrag);
    g.addEventListener('pointerup', endResize);
    g.addEventListener('pointercancel', endResize);
  }

  function applyResize(d) {
    const { el, mode, bands, base } = resizing;
    if (mode.kind === 'grid') {
      const list = bands.list.slice();
      const shift = Math.max(MIN_SIZE - list[mode.seam], Math.min(list[mode.seam + 1] - MIN_SIZE, d));
      list[mode.seam] += shift;
      list[mode.seam + 1] -= shift;
      const total = list.reduce((a, b) => a + b, 0);
      setInline(mode.parent, mode.axis === 'x' ? 'grid-template-columns' : 'grid-template-rows',
        list.map(n => `${+(n / total * list.length).toFixed(4)}fr`).join(' '));
      return;
    }
    const size = Math.max(MIN_SIZE, Math.round((base + d) * 2) / 2);
    if (mode.kind === 'flex') setInline(el, 'flex', `0 0 ${size}px`);
    else setInline(el, mode.axis === 'x' ? 'width' : 'height', `${size}px`);
  }

  function onResizeDrag(e) {
    const d = ((resizing.mode.axis === 'x' ? e.clientX : e.clientY) - resizing.from) / resizing.k;
    if (!resizing.moved && Math.abs(d) < 0.5) return;
    resizing.moved = true;
    applyResize(d);
    showRing(resizing.el, true);
    placeGrip(resizing.side, resizing.el.getBoundingClientRect());
  }

  function endResize() {
    const { el, mode, side, moved } = resizing;
    const g = grips[side];
    g.removeEventListener('pointermove', onResizeDrag);
    g.removeEventListener('pointerup', endResize);
    g.removeEventListener('pointercancel', endResize);
    resizing = null;
    hideRing();
    hideGrips();
    if (moved) emitStyle(mode.kind === 'grid' ? mode.parent : el);
  }

  function setInline(el, prop, value) {
    const before = getComputedStyle(el).getPropertyValue(prop);
    el.style.setProperty(prop, value);
    if (getComputedStyle(el).getPropertyValue(prop) === before) {
      el.style.setProperty(prop, value, 'important');
    }
  }

  function emitStyle(el) {
    const path = pathOf(el);
    if (!path) return;
    if (!el.getAttribute('style')) el.removeAttribute('style');
    sendOps([{ kind: 'setAttr', path, name: 'style', value: el.getAttribute('style') }]);
  }

  function toHex(c) {
    const h = (n) => Math.round(n).toString(16).padStart(2, '0');
    return `#${h(c.r)}${h(c.g)}${h(c.b)}`;
  }

  function toggleBold() {
    const el = barTarget;
    if (!el) return;
    const bold = parseInt(getComputedStyle(el).fontWeight, 10) >= 600;
    if (el.style.fontWeight) el.style.removeProperty('font-weight');
    else el.style.setProperty('font-weight', bold ? '400' : '700');
    emitStyle(el);
    refreshBar();
  }

  function toggleItalic() {
    const el = barTarget;
    if (!el) return;
    const italic = getComputedStyle(el).fontStyle === 'italic';
    if (el.style.fontStyle) el.style.removeProperty('font-style');
    else el.style.setProperty('font-style', italic ? 'normal' : 'italic');
    emitStyle(el);
    refreshBar();
  }

  function nudgeSize(factor) {
    const el = barTarget;
    if (!el) return;
    const size = parseFloat(getComputedStyle(el).fontSize) * factor;
    setInline(el, 'font-size', `${Math.round(size * 2) / 2}px`);
    emitStyle(el);
  }

  const ALIGN_NEXT = { left: 'center', start: 'center', center: 'right', right: 'left', end: 'left', justify: 'left' };

  function cycleAlign() {
    const el = barTarget;
    if (!el) return;
    setInline(el, 'text-align', ALIGN_NEXT[getComputedStyle(el).textAlign] || 'center');
    emitStyle(el);
    refreshBar();
  }

  function makeColorInput(prop) {
    const input = document.createElement('input');
    input.type = 'color';
    input.setAttribute('style', 'position:fixed;opacity:0;pointer-events:none');
    input.addEventListener('input', () => {
      if (!barTarget) return;
      setInline(barTarget, prop, input.value);
      refreshBar();
    });
    input.addEventListener('change', () => {
      if (!barTarget) return;
      setInline(barTarget, prop, input.value);
      emitStyle(barTarget);
      refreshBar();
    });
    formatBar.appendChild(input);
    return input;
  }

  function pickColor(input, btn, prop) {
    const el = barTarget;
    if (!el) return;
    const r = btn.getBoundingClientRect();
    input.style.left = `${r.left}px`;
    input.style.top = `${r.top}px`;
    input.style.width = `${r.width}px`;
    input.style.height = `${r.height}px`;
    input.value = toHex(normalizeColor(getComputedStyle(el).getPropertyValue(prop)) || { r: 0, g: 0, b: 0 });
    input.click();
  }

  function ensureFormatBar() {
    if (formatBar) return formatBar;
    formatBar = document.createElement('div');
    formatBar.setAttribute('data-wy-bar', '');
    formatBar.setAttribute('style', 'position:fixed;z-index:2147483646;display:none;gap:2px;padding:3px;border-radius:8px;background:#1c1c20;border:1px solid #3f3f46;box-shadow:0 4px 16px rgba(0,0,0,.35)');
    const mk = (label, title, action) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.textContent = label;
      b.title = title;
      b.setAttribute('style', 'width:26px;height:24px;padding:0;border:0;border-radius:5px;background:transparent;color:#e4e4e7;font:600 13px/1 ui-sans-serif,system-ui,-apple-system,sans-serif;cursor:pointer');
      b.addEventListener('mousedown', (e) => e.preventDefault());
      b.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        action();
      });
      formatBar.appendChild(b);
      return b;
    };
    barBold = mk('B', 'bold', toggleBold);
    barItalic = mk('I', 'italic', toggleItalic);
    barItalic.style.fontStyle = 'italic';
    mk('−', 'smaller', () => nudgeSize(1 / 1.1));
    mk('+', 'larger', () => nudgeSize(1.1));
    barAlign = mk('↤', 'alignment', cycleAlign);
    barColorInput = makeColorInput('color');
    barBgInput = makeColorInput('background-color');
    barColorBtn = mk('A', 'text color', () => pickColor(barColorInput, barColorBtn, 'color'));
    barBgBtn = mk('◼', 'background color', () => pickColor(barBgInput, barBgBtn, 'background-color'));
    document.documentElement.appendChild(formatBar);
    return formatBar;
  }

  function showFormatBar(el) {
    barTarget = el;
    ensureFormatBar().style.display = 'flex';
    positionFormatBar();
    refreshBar();
  }

  function positionFormatBar() {
    if (!barTarget || !formatBar || formatBar.style.display === 'none') return;
    const r = barTarget.getBoundingClientRect();
    const h = formatBar.offsetHeight || 32;
    const w = formatBar.offsetWidth || 220;
    const top = r.top - h - 8 >= 4 ? r.top - h - 8 : Math.min(innerHeight - h - 4, r.bottom + 8);
    formatBar.style.top = `${top}px`;
    formatBar.style.left = `${Math.max(4, Math.min(innerWidth - w - 4, r.left - 3))}px`;
  }

  function hideFormatBar() {
    barTarget = null;
    if (formatBar) formatBar.style.display = 'none';
  }

  function refreshBar() {
    if (!barTarget) return;
    const cs = getComputedStyle(barTarget);
    barBold.style.background = parseInt(cs.fontWeight, 10) >= 600 ? '#3f3f46' : 'transparent';
    barItalic.style.background = cs.fontStyle === 'italic' ? '#3f3f46' : 'transparent';
    barAlign.textContent = { center: '↔', right: '↦' }[cs.textAlign] || '↤';
    barColorBtn.style.color = cs.color;
    barBgBtn.style.color = cs.backgroundColor === 'rgba(0, 0, 0, 0)' ? '#e4e4e7' : cs.backgroundColor;
  }

  document.addEventListener('keydown', (e) => {
    if (!(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== 'z' || editingEl) return;
    e.preventDefault();
    send({ type: e.shiftKey ? 'wy-redo' : 'wy-undo' });
  });

  window.addEventListener('scroll', () => {
    if (editingEl) showRing(editingEl, true);
    else hideRing();
    hideReplacePill();
    hideMoveHandle();
    hideGrips();
    positionFormatBar();
  }, true);

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !editingEl) hideFormatBar();
  });

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
    else if (m.type === 'wy-theme-preview') themePreview(m.index, m.value);
    else if (m.type === 'wy-theme-commit') themeCommit(m.index, m.value);
    else if (m.type === 'wy-find') send({ type: 'wy-found', found: !!window.find(m.text, false, !!m.backwards, true, false, false, false) });
  });

  const THEME_PROPS = new Set(['font-family', 'color', 'background-color']);
  let themeEntries = [];
  let themePreviewStyle = null;
  const themePending = new Map();

  function collectRules(list, out) {
    for (const rule of list) {
      if (rule.style) out.push(rule);
      if (rule.cssRules && rule.cssRules.length) collectRules(rule.cssRules, out);
    }
    return out;
  }

  function normalizeColor(value) {
    const probe = document.createElement('div');
    probe.style.color = value;
    if (!probe.style.color) return null;
    probe.style.display = 'none';
    document.body.appendChild(probe);
    const rgb = getComputedStyle(probe).color;
    probe.remove();
    const m = rgb.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)/);
    return m ? { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] } : null;
  }

  function classifyTheme(prop, value) {
    if (/gradient\(/.test(value)) return null;
    if (/font|family/i.test(prop)) return { kind: 'font' };
    if (CSS.supports('color', value) || /^var\(/.test(value)) {
      const rgba = normalizeColor(value);
      if (rgba) return { kind: 'color', rgba };
    }
    if (/^-?[\d.]+(px|rem|em|vw|vh|%)$/.test(value)) return { kind: 'size' };
    return null;
  }

  function collectTheme() {
    const byProp = new Map();
    for (const styleEl of document.querySelectorAll('style:not([data-wy-ui])')) {
      let rules;
      try { rules = styleEl.sheet ? collectRules(styleEl.sheet.cssRules, []) : []; } catch { continue; }
      for (const rule of rules) {
        const selectors = (rule.selectorText || '').split(',').map(s => s.trim().toLowerCase());
        if (!selectors.some(s => s === ':root' || s === 'html' || s === 'body')) continue;
        for (let i = 0; i < rule.style.length; i++) {
          const prop = rule.style.item(i);
          if (!prop.startsWith('--') && !THEME_PROPS.has(prop)) continue;
          const value = rule.style.getPropertyValue(prop).trim();
          const cls = classifyTheme(prop, value);
          if (!cls) continue;
          byProp.set(prop, { el: styleEl, prop, value, kind: cls.kind, rgba: cls.rgba ?? null });
        }
      }
    }
    themeEntries = [...byProp.values()];
    send({
      type: 'wy-theme',
      entries: themeEntries.map((e, index) => ({ index, kind: e.kind, name: e.prop, value: e.value, rgba: e.rgba })),
    });
  }

  function renderThemePreview() {
    if (!themePreviewStyle) {
      themePreviewStyle = document.createElement('style');
      themePreviewStyle.setAttribute('data-wy-ui', '');
      document.head.appendChild(themePreviewStyle);
    }
    const root = [];
    const body = [];
    for (const [i, v] of themePending) {
      const e = themeEntries[i];
      if (!e) continue;
      if (e.prop.startsWith('--')) root.push(`${e.prop}: ${v}`);
      else body.push(`${e.prop}: ${v} !important`);
    }
    themePreviewStyle.textContent =
      (root.length ? `:root { ${root.join('; ')} }` : '') +
      (body.length ? ` body { ${body.join('; ')} }` : '');
  }

  function themePreview(index, value) {
    if (!themeEntries[index]) return;
    themePending.set(index, value);
    renderThemePreview();
  }

  function escapeRe(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function serializedCSSValue(prop, raw) {
    const probe = document.createElement('div');
    probe.style.cssText = `${prop}: ${raw}`;
    return probe.style.getPropertyValue(prop).trim();
  }

  function patchProp(text, sourceProp, value, matches) {
    const re = new RegExp(`(${escapeRe(sourceProp)}\\s*:\\s*)([^;}!]+)`, 'g');
    return text.replace(re, (match, head, raw) => (matches(raw.trim()) ? head + value : match));
  }

  function themeCommit(index, value) {
    const e = themeEntries[index];
    if (!e) return;
    themePending.delete(index);
    renderThemePreview();
    const text = e.el.textContent;
    const exact = new RegExp(`(${escapeRe(e.prop)}\\s*:\\s*)${escapeRe(e.value)}(?=\\s*(?:!important\\s*)?[;}])`, 'g');
    let patched = text.replace(exact, `$1${value}`);
    if (patched === text) {
      patched = patchProp(text, e.prop, value, (raw) => serializedCSSValue(e.prop, raw) === e.value);
    }
    if (patched === text && e.prop === 'background-color') {
      patched = patchProp(text, 'background', value, (raw) =>
        CSS.supports('color', raw) && serializedCSSValue(e.prop, raw) === e.value);
    }
    if (patched === text) return send({ type: 'wy-error', message: `could not update ${e.prop}` });
    e.el.textContent = patched;
    let root = 'head';
    let path = pathIn(document.head, e.el);
    if (!path) {
      root = 'body';
      path = pathOf(e.el);
    }
    if (path) send({ type: 'wy-ops', ops: [{ kind: 'setHTML', root, path, html: patched }] });
    scheduleSlides();
    collectTheme();
  }

  const placeholderStyle = document.createElement('style');
  placeholderStyle.setAttribute('data-wy-ui', '');
  document.head.appendChild(placeholderStyle);

  function luma(color) {
    const m = color.match(/\d+(\.\d+)?/g);
    if (!m || m.length < 3) return null;
    return (0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]) / 255;
  }

  function sampleAccent() {
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta && meta.content) return meta.content;
    const bgLuma = luma(getComputedStyle(document.body).backgroundColor) ?? 1;
    for (const sel of ['a[href]', 'h1', 'h2', 'strong']) {
      const el = document.querySelector(sel);
      if (!el) continue;
      const c = getComputedStyle(el).color;
      const l = luma(c);
      if (l !== null && Math.abs(l - bgLuma) > 0.2) return c;
    }
    return '#0a84ff';
  }

  function applyAccent() {
    ACCENT = sampleAccent();
    placeholderStyle.textContent = `img[data-wy-placeholder]{outline:2px dashed ${ACCENT};outline-offset:2px}`;
  }

  applyAccent();
  collectTheme();
  window.addEventListener('load', () => {
    applyAccent();
    collectTheme();
  });
  scheduleSlides();
})();
