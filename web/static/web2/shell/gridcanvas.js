/* web2 shell · GridCanvas — a reusable grid canvas of arrangeable icon tiles.
   Modular: a surface gives it items {id,label,color,glyph}, a position store, and
   selection callbacks; GridCanvas owns the Konva stage, the infinite grid,
   drag-to-snap, wheel pan + ctrl-wheel/pinch zoom, and arrange/align/distribute.
   The studio drives it with either instances or predicates — same component. */
window.GridCanvas = function (container, opts) {
  opts = opts || {};
  const TILE_W = 78, TILE_H = 74;
  const onSelect = opts.onSelect || function () { };
  const onClear = opts.onClear || function () { };
  const linksFor = opts.linksFor || null;   // (selId, items) -> [otherId,...]
  let store = opts.posStore || memStore();
  let gridSize = opts.gridSize || 92;
  let snap = opts.snap !== false;
  let showLinks = !!opts.showLinks;
  let items = [];
  let scale = 1;
  const multi = new Set();

  const stage = new Konva.Stage({ container, width: container.clientWidth || 800, height: container.clientHeight || 500 });
  const gridL = new Konva.Layer({ listening: false });
  const linkL = new Konva.Layer({ listening: false });
  const tileL = new Konva.Layer();
  stage.add(gridL); stage.add(linkL); stage.add(tileL);

  stage.on("click tap", (e) => { if (e.target === stage) { multi.clear(); onClear(); render(); } });

  // wheel: ctrl/⌘ (trackpad pinch) → zoom around pointer; else directional pan
  container.addEventListener("wheel", (ev) => {
    ev.preventDefault();
    if (ev.ctrlKey || ev.metaKey) {
      const old = scale;
      const ptr = stage.getPointerPosition() || { x: stage.width() / 2, y: stage.height() / 2 };
      const wx = (ptr.x - stage.x()) / old, wy = (ptr.y - stage.y()) / old;
      scale = Math.min(2.6, Math.max(0.3, old * (1 - ev.deltaY * 0.01)));
      stage.scale({ x: scale, y: scale });
      stage.position({ x: ptr.x - wx * scale, y: ptr.y - wy * scale });
    } else {
      stage.position({ x: stage.x() - ev.deltaX, y: stage.y() - ev.deltaY });
    }
    drawGrid(); linkL.batchDraw(); tileL.batchDraw();
    if (opts.onSize) opts.onSize({ n: items.length, w: stage.width(), h: stage.height(), grid: gridSize, scale });
  }, { passive: false });

  function memStore() { let m = {}; return { load: () => m, save: (p) => { m = p; } }; }

  function fit() {
    stage.width(container.clientWidth || 800);
    stage.height(container.clientHeight || 500);
    render();
  }

  function drawGrid() {
    gridL.destroyChildren();
    const inv = 1 / scale, sw = 1 / scale;
    const x0 = -stage.x() * inv, y0 = -stage.y() * inv;
    const x1 = x0 + stage.width() * inv, y1 = y0 + stage.height() * inv;
    for (let x = Math.floor(x0 / gridSize) * gridSize; x <= x1; x += gridSize) gridL.add(new Konva.Line({ points: [x, y0, x, y1], stroke: "#eef2f7", strokeWidth: sw }));
    for (let y = Math.floor(y0 / gridSize) * gridSize; y <= y1; y += gridSize) gridL.add(new Konva.Line({ points: [x0, y, x1, y], stroke: "#eef2f7", strokeWidth: sw }));
    gridL.batchDraw();
  }

  function positions() {
    const saved = store.load(); const pos = {};
    const cols = Math.max(1, Math.floor((stage.width() / scale - 16) / gridSize));
    items.forEach((it, i) => { pos[it.id] = saved[it.id] || { x: 12 + (i % cols) * gridSize, y: 12 + Math.floor(i / cols) * gridSize }; });
    return pos;
  }

  function drawLinks(pos, selId) {
    linkL.destroyChildren();
    if ((showLinks || selId) && linksFor && selId) {
      const c = (id) => ({ x: pos[id].x + TILE_W / 2, y: pos[id].y + 22 });
      const a = c(selId);
      (linksFor(selId, items) || []).forEach((oid) => { if (pos[oid]) { const b = c(oid); linkL.add(new Konva.Line({ points: [a.x, a.y, b.x, b.y], stroke: "#cdd9ea", strokeWidth: 1.5 / scale, dash: [4 / scale, 3 / scale] })); } });
    }
    linkL.batchDraw();
  }

  function tile(it, p) {
    const sel = multi.has(it.id);
    const g = new Konva.Group({ x: p.x, y: p.y, draggable: true });
    g.add(new Konva.Rect({ x: (TILE_W - 44) / 2, y: 2, width: 44, height: 44, cornerRadius: 11, fill: "#fff", stroke: sel ? "#2f7bf6" : "#e2e8f1", strokeWidth: sel ? 2 : 1.2, shadowColor: "#142036", shadowBlur: sel ? 10 : 5, shadowOpacity: sel ? 0.14 : 0.06, shadowOffsetY: 1 }));
    g.add(new Konva.Rect({ x: (TILE_W - 44) / 2 + 7, y: 9, width: 6, height: 30, cornerRadius: 3, fill: it.color || "#9aa7bd" }));
    if (it.glyph) g.add(new Konva.Text({ x: (TILE_W - 44) / 2 + 18, y: 13, width: 22, text: it.glyph, fontSize: 15, fill: "#46566f", fontFamily: "system-ui", align: "center" }));
    g.add(new Konva.Text({ x: -3, y: 49, width: TILE_W + 6, height: 24, align: "center", text: it.label, fontSize: 9.5, lineHeight: 1.15, fill: sel ? "#1b2533" : "#5a6a82", fontFamily: "system-ui", ellipsis: true, wrap: "word" }));
    g.on("click tap", (e) => { e.cancelBubble = true; select(it.id, e.evt && e.evt.shiftKey); });
    g.on("mouseenter", () => document.body.style.cursor = "pointer");
    g.on("mouseleave", () => document.body.style.cursor = "");
    g.on("dragend", () => {
      let x = g.x(), y = g.y();
      if (snap) { x = Math.round(x / gridSize) * gridSize; y = Math.round(y / gridSize) * gridSize; g.position({ x, y }); }
      const s = store.load(); s[it.id] = { x, y }; store.save(s); render();
    });
    return g;
  }

  function select(id, additive) {
    if (additive) { multi.has(id) ? multi.delete(id) : multi.add(id); }
    else { multi.clear(); multi.add(id); }
    onSelect(id, additive); render();
  }

  let _selId = null;
  function render(selId) {
    if (selId !== undefined) _selId = selId;
    drawGrid();
    const pos = positions();
    drawLinks(pos, _selId);
    tileL.destroyChildren();
    items.forEach((it) => tileL.add(tile(it, pos[it.id])));
    tileL.batchDraw();
    if (opts.onSize) opts.onSize({ n: items.length, w: stage.width(), h: stage.height(), grid: gridSize, scale });
  }

  // ---- alignment ----
  const targetIds = () => (multi.size > 1 ? [...multi] : items.map((i) => i.id));
  function arrange() {
    const cols = Math.max(1, Math.floor((stage.width() / scale - 16) / gridSize));
    const s = {}; items.forEach((it, i) => s[it.id] = { x: 12 + (i % cols) * gridSize, y: 12 + Math.floor(i / cols) * gridSize });
    store.save(s); render();
  }
  function align(edge) {
    const ids = targetIds(), pos = store.load(); if (!ids.length) return;
    const get = (id) => pos[id] || { x: 12, y: 12 };
    if (edge === "left") { const m = Math.min(...ids.map((i) => get(i).x)); ids.forEach((i) => pos[i] = { x: m, y: get(i).y }); }
    if (edge === "top") { const m = Math.min(...ids.map((i) => get(i).y)); ids.forEach((i) => pos[i] = { x: get(i).x, y: m }); }
    store.save(pos); render();
  }
  function distribute(axis) {
    const ids = targetIds(); if (ids.length < 3) return; const pos = store.load(); const k = axis === "h" ? "x" : "y";
    const sorted = ids.slice().sort((a, b) => (pos[a] || {})[k] - (pos[b] || {})[k]);
    const lo = (pos[sorted[0]] || {})[k] ?? 12, hi = (pos[sorted[sorted.length - 1]] || {})[k] ?? 12, step = (hi - lo) / (sorted.length - 1);
    sorted.forEach((id, i) => { pos[id] = pos[id] || { x: 12, y: 12 }; pos[id][k] = Math.round(lo + i * step); });
    store.save(pos); render();
  }

  function zoom(dir) { const ptr = { x: stage.width() / 2, y: stage.height() / 2 }; const old = scale; const wx = (ptr.x - stage.x()) / old, wy = (ptr.y - stage.y()) / old; scale = Math.min(2.6, Math.max(0.3, old * (dir > 0 ? 1.15 : 0.87))); stage.scale({ x: scale, y: scale }); stage.position({ x: ptr.x - wx * scale, y: ptr.y - wy * scale }); render(); }
  function resetView() { scale = 1; stage.scale({ x: 1, y: 1 }); stage.position({ x: 0, y: 0 }); render(); }

  setTimeout(fit, 0);
  return {
    setItems(arr) { items = arr || []; }, render, fit,
    setStore(s) { store = s; }, setGrid(n) { gridSize = n; render(); }, setSnap(b) { snap = b; },
    setLinks(b) { showLinks = b; render(); }, clearSel() { multi.clear(); },
    arrange, align, distribute, zoom, resetView,
    get scale() { return scale; },
  };
};
