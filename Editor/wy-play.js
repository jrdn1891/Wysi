(function () {
  'use strict';

  addEventListener('message', (e) => {
    const m = e.data;
    if (!m || m.type !== 'wy-find') return;
    parent.postMessage({ type: 'wy-found', found: !!window.find(m.text, false, !!m.backwards, true, false, false, false) }, '*');
  });

  const HOLD_MS = 250;
  const MOVE_PX = 6;
  const FADE_MS = 1000;

  let canvas = null;
  let ctx = null;
  const strokes = [];
  let active = null;
  let pointerId = null;
  let downX = 0;
  let downY = 0;
  let lasering = false;
  let swallowClick = false;
  let holdTimer = null;
  let drawTimer = 0;
  let prevUserSelect = '';

  function ensureCanvas() {
    if (canvas) return;
    canvas = document.createElement('canvas');
    canvas.setAttribute('data-wy-laser', '');
    canvas.setAttribute('style', 'position:fixed;inset:0;pointer-events:none;z-index:2147483647');
    document.documentElement.appendChild(canvas);
    ctx = canvas.getContext('2d');
    size();
    addEventListener('resize', size);
  }

  function size() {
    const dpr = devicePixelRatio || 1;
    canvas.width = innerWidth * dpr;
    canvas.height = innerHeight * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function startLaser(x, y) {
    lasering = true;
    ensureCanvas();
    getSelection()?.removeAllRanges();
    prevUserSelect = document.documentElement.style.userSelect;
    document.documentElement.style.userSelect = 'none';
    active = { points: [{ x, y }], releasedAt: 0 };
    strokes.push(active);
    tick();
  }

  function endLaser() {
    document.documentElement.style.userSelect = prevUserSelect;
    if (active) active.releasedAt = performance.now();
    active = null;
    lasering = false;
    tick();
  }

  function tick() {
    if (!drawTimer) drawTimer = setTimeout(draw, 16);
  }

  function draw() {
    drawTimer = 0;
    const now = performance.now();
    ctx.clearRect(0, 0, innerWidth, innerHeight);
    for (let i = strokes.length - 1; i >= 0; i--) {
      const s = strokes[i];
      const alpha = s.releasedAt ? 1 - (now - s.releasedAt) / FADE_MS : 1;
      if (alpha <= 0) {
        strokes.splice(i, 1);
        continue;
      }
      paint(s, alpha);
    }
    if (strokes.length) tick();
  }

  function paint(s, alpha) {
    ctx.globalAlpha = alpha;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.shadowColor = 'rgba(255, 59, 48, 0.9)';
    ctx.shadowBlur = 8;
    ctx.strokeStyle = '#ff3b30';
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.moveTo(s.points[0].x, s.points[0].y);
    for (let i = 1; i < s.points.length; i++) ctx.lineTo(s.points[i].x, s.points[i].y);
    ctx.stroke();
    if (!s.releasedAt) {
      const head = s.points[s.points.length - 1];
      ctx.shadowBlur = 12;
      ctx.fillStyle = '#ff6259';
      ctx.beginPath();
      ctx.arc(head.x, head.y, 5, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    ctx.shadowBlur = 0;
  }

  document.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    pointerId = e.pointerId;
    downX = e.clientX;
    downY = e.clientY;
    swallowClick = false;
    holdTimer = setTimeout(() => startLaser(downX, downY), HOLD_MS);
  }, true);

  document.addEventListener('pointermove', (e) => {
    if (pointerId === null || e.pointerId !== pointerId) return;
    if (!lasering) {
      if (Math.hypot(e.clientX - downX, e.clientY - downY) < MOVE_PX) return;
      clearTimeout(holdTimer);
      startLaser(downX, downY);
    }
    active.points.push({ x: e.clientX, y: e.clientY });
    e.preventDefault();
    e.stopPropagation();
    tick();
  }, true);

  function up(e) {
    if (pointerId === null || e.pointerId !== pointerId) return;
    pointerId = null;
    clearTimeout(holdTimer);
    if (lasering) {
      swallowClick = true;
      endLaser();
    }
  }
  document.addEventListener('pointerup', up, true);
  document.addEventListener('pointercancel', up, true);

  document.addEventListener('click', (e) => {
    if (!swallowClick) return;
    swallowClick = false;
    e.preventDefault();
    e.stopPropagation();
  }, true);
})();
