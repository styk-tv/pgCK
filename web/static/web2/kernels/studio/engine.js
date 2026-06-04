/* web2 kernel · studio — the concept-kernel IDE. Five regions left→right:
     1. icons      — one per concept kernel
     2. params     — the kernel's exposed control parameters (live + schema)
     3. instances  — instances the kernel has produced
     4. main       — top: selected-instance metadata header; a canvas toolbar
                     (grid size · snap · align · arrange · links); below: a GRID
                     CANVAS where instances are arrangeable icon tiles (snap to
                     grid, drag, align, distribute). Still a connected graph —
                     selecting a tile lights its peers (same goal) + connectors.
     5. features   — edges · predicates · actions · proofs (the in/out surface).
   Materialises from the snapshot-backfilled Bus tree. */
(function () {
  const N = "https://conceptkernel.org/ontology/v3.7/";
  const LIFE = ["planned", "in_progress", "done"];
  const WORKERED = /pgCK|pgRDF|CK\.Lib|oci|web/i;
  const TILE_W = 78, TILE_H = 74;
  const STATE_COL = { planned: "#9aa7bd", in_progress: "#2f7bf6", done: "#15b886", blocked: "#d2455a" };

  let host = null, selKernel = null, selInstance = null;
  let stage = null, gridLayer = null, linkLayer = null, tileLayer = null;
  let gridSize = +localStorage.getItem("pgck.web2.studio.grid") || 92;
  let snap = localStorage.getItem("pgck.web2.studio.snap") !== "0";
  let showLinks = false;
  const multiSel = new Set();

  function mount(h) {
    host = h;
    h.innerHTML = `
      <div class="studio">
        <div class="st-icons" id="st-icons"></div>
        <div class="st-col st-params"><div class="st-ch">parameters</div><div id="st-params"></div></div>
        <div class="st-col st-insts"><div class="st-ch">instances</div><div id="st-insts"></div></div>
        <div class="st-main">
          <div class="st-header" id="st-header"></div>
          <div class="st-cbar" id="st-cbar"></div>
          <div class="st-canvas" id="st-canvas"></div>
        </div>
        <div class="st-col st-feat"><div class="st-ch" id="st-feat-h">features</div><div id="st-feat"></div></div>
      </div>`;
    renderToolbar();
    initCanvas();
    window.addEventListener("resize", fitCanvas);
    window.Bus.subscribe(() => { if (window.Bus.state.active === "studio") softRefresh(); });
  }

  function onActivate() {
    renderIcons();
    if (!selKernel) {
      const k = window.Bus.state.kernels.slice().sort((a, b) => b.count - a.count)[0];
      if (k) return selectKernel(k.name);
    }
    renderAll();
  }

  let _soft = null;
  function softRefresh() {
    clearTimeout(_soft);
    _soft = setTimeout(() => {
      if (!selKernel && window.Bus.state.kernels.length) {
        const k = window.Bus.state.kernels.slice().sort((a, b) => b.count - a.count)[0];
        return selectKernel(k.name);
      }
      renderIcons();
      if (selKernel) { renderInstances(); renderCanvas(); }
    }, 200);
  }

  // ---------- region 1 · concept-kernel icons ----------
  function iconFor(name) {
    const m = { pgCK: "◆", pgRDF: "▣", web2: "▤", web3: "◳", "parity-audit": "⚖", "oci-germination": "⬡" };
    if (m[name]) return m[name];
    if (/CK\.Lib/.test(name)) return "❑";
    return (name[0] || "?").toUpperCase();
  }
  function renderIcons() {
    const R = host.querySelector("#st-icons"); if (!R) return;
    const kernels = window.Bus.state.kernels.slice().sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
    R.innerHTML = "";
    for (const k of kernels) {
      const b = document.createElement("div");
      b.className = "kicon" + (selKernel === k.name ? " on" : "");
      b.title = k.name + " · " + k.count;
      b.innerHTML = `<span class="g">${iconFor(k.name)}</span><span class="c">${k.count}</span>`;
      b.onclick = () => selectKernel(k.name);
      R.appendChild(b);
    }
  }

  function selectKernel(name) { selKernel = name; selInstance = null; multiSel.clear(); renderAll(); }
  function selectInstance(id, additive) {
    if (additive) { if (multiSel.has(id)) multiSel.delete(id); else multiSel.add(id); }
    else { multiSel.clear(); multiSel.add(id); }
    selInstance = (window.Bus.state.instances[selKernel] || []).find((t) => t.id === id) || null;
    renderInstances(); renderParams(); renderHeader(); renderFeatures(); renderCanvas();
  }

  function renderAll() { renderIcons(); renderParams(); renderInstances(); renderHeader(); renderFeatures(); fitCanvas(); }

  // ---------- region 2 · kernel parameter surface ----------
  function renderParams() {
    const P = host.querySelector("#st-params"); if (!P) return;
    P.innerHTML = ""; if (!selKernel) return;
    const insts = window.Bus.state.instances[selKernel] || [];
    const preds = new Set(); insts.forEach((t) => Object.keys(t.body || {}).forEach((k) => preds.add(k)));
    const inst = selInstance;
    const ctrl = (label, node, hint) => { const r = document.createElement("div"); r.className = "prow"; r.innerHTML = `<div class="plbl">${label}${hint ? `<span class="phint">${hint}</span>` : ""}</div>`; r.appendChild(node); return r; };
    const seg = document.createElement("div"); seg.className = "seg";
    LIFE.forEach((s) => { const b = document.createElement("button"); b.className = (inst && inst.state === s) ? "on " + s : ""; b.textContent = s === "in_progress" ? "doing" : s; b.disabled = !inst; b.onclick = () => updateLifecycle(s); seg.appendChild(b); });
    P.appendChild(ctrl("lifecycle_state", seg, "live"));
    const pr = document.createElement("input"); pr.type = "range"; pr.min = 1; pr.max = 9; pr.value = inst ? (inst.body[N + "priority"] || 5) : 5; pr.disabled = !inst;
    const pv = document.createElement("span"); pv.className = "pval"; pv.textContent = "P" + pr.value;
    pr.oninput = () => { pv.textContent = "P" + pr.value; }; pr.onchange = () => updatePriority(pr.value);
    const pw = document.createElement("div"); pw.className = "pslide"; pw.append(pr, pv);
    P.appendChild(ctrl("priority", pw, "live"));
    [...preds].filter((k) => !/lifecycle_state|priority|title|^type$/.test(local(k))).sort().forEach((k) => {
      const v = document.createElement("div"); v.className = "pmeta"; v.textContent = inst ? String(inst.body[k] ?? "—") : "schema";
      P.appendChild(ctrl(local(k), v));
    });
    if (!inst) { const n = document.createElement("div"); n.className = "pnote"; n.textContent = "select an instance to bind these controls"; P.appendChild(n); }
  }

  // ---------- region 3 · instances ----------
  function renderInstances() {
    const L = host.querySelector("#st-insts"); if (!L) return; L.innerHTML = "";
    const insts = (window.Bus.state.instances[selKernel] || []).slice().sort((a, b) => (+b.body[N + "priority"] || 0) - (+a.body[N + "priority"] || 0));
    for (const t of insts) {
      const r = document.createElement("div"); r.className = "irow" + (multiSel.has(t.id) ? " sel" : "");
      r.innerHTML = `<span class="idot ${t.state}"></span><span class="it">${esc(t.title)}</span>`;
      r.onclick = (e) => selectInstance(t.id, e.shiftKey);
      L.appendChild(r);
    }
    if (!insts.length) L.innerHTML = `<div class="pnote">no instances yet</div>`;
  }

  // ---------- region 4a · header ----------
  function renderHeader() {
    const H = host.querySelector("#st-header"); if (!H) return;
    if (!selKernel) { H.innerHTML = `<div class="hhint">select a concept kernel</div>`; return; }
    if (!selInstance) { H.innerHTML = `<div class="hk">${esc(selKernel)}</div><div class="hsub">${(window.Bus.state.instances[selKernel] || []).length} instances · drag the icons to arrange · select one to focus</div>`; return; }
    const t = selInstance;
    H.innerHTML = `<div class="hrow"><div class="ht">${esc(t.title)}</div><span class="pill ${t.state}">${t.state.replace("_", " ")}</span>${t.verified ? `<span class="vbadge">✓ verified</span>` : ""}</div>` +
      `<div class="hmeta"><span class="urn">ckp://${t.type}#${esc(String(t.id))}</span>${t.proof_digest ? `<span class="hproof">proof ${String(t.proof_digest).slice(0, 12)}…</span>` : ""}${t.body[N + "created_by"] ? `<span class="hby">${esc(local(t.body[N + "created_by"]))}</span>` : ""}</div>`;
  }

  // ---------- region 4 toolbar ----------
  function renderToolbar() {
    const T = host.querySelector("#st-cbar"); if (!T) return;
    T.innerHTML = `
      <div class="cbgrp"><span class="cblbl">grid</span>
        <button class="cbtn gs" data-gs="72">S</button><button class="cbtn gs" data-gs="92">M</button><button class="cbtn gs" data-gs="120">L</button></div>
      <div class="cbgrp"><button class="cbtn tgl" id="cb-snap">⊞ snap</button><button class="cbtn tgl" id="cb-links">↳ links</button></div>
      <div class="cbgrp"><span class="cblbl">align</span>
        <button class="cbtn" id="cb-arrange" title="arrange all to grid">▦ arrange</button>
        <button class="cbtn" id="cb-alignL" title="align left">⊨</button>
        <button class="cbtn" id="cb-alignT" title="align top">⊤</button>
        <button class="cbtn" id="cb-distH" title="distribute horizontally">⇿</button>
        <button class="cbtn" id="cb-distV" title="distribute vertically">⤢</button></div>
      <div class="cbgrp cbsize"><span class="cblbl" id="cb-size">—</span></div>`;
    T.querySelectorAll(".gs").forEach((b) => b.onclick = () => setGrid(+b.dataset.gs));
    T.querySelector("#cb-snap").onclick = () => { snap = !snap; localStorage.setItem("pgck.web2.studio.snap", snap ? "1" : "0"); syncToggles(); };
    T.querySelector("#cb-links").onclick = () => { showLinks = !showLinks; syncToggles(); renderCanvas(); };
    T.querySelector("#cb-arrange").onclick = () => { arrangeGrid(); };
    T.querySelector("#cb-alignL").onclick = () => alignSel("left");
    T.querySelector("#cb-alignT").onclick = () => alignSel("top");
    T.querySelector("#cb-distH").onclick = () => distributeSel("h");
    T.querySelector("#cb-distV").onclick = () => distributeSel("v");
    syncToggles();
  }
  function syncToggles() {
    if (!host) return;
    host.querySelectorAll(".gs").forEach((b) => b.classList.toggle("on", +b.dataset.gs === gridSize));
    const sn = host.querySelector("#cb-snap"), lk = host.querySelector("#cb-links");
    if (sn) sn.classList.toggle("on", snap);
    if (lk) lk.classList.toggle("on", showLinks);
  }

  // ---------- region 4b · grid canvas of icon tiles ----------
  const posKey = () => "pgck.web2.studio.pos." + selKernel;
  function loadPos() { try { return JSON.parse(localStorage.getItem(posKey()) || "{}"); } catch (e) { return {}; } }
  function savePos(p) { localStorage.setItem(posKey(), JSON.stringify(p)); }

  function initCanvas() {
    const box = host.querySelector("#st-canvas");
    stage = new Konva.Stage({ container: box, width: box.clientWidth || 800, height: box.clientHeight || 500 });
    gridLayer = new Konva.Layer({ listening: false }); linkLayer = new Konva.Layer({ listening: false }); tileLayer = new Konva.Layer();
    stage.add(gridLayer); stage.add(linkLayer); stage.add(tileLayer);
    // click empty canvas → clear multi-select
    stage.on("click tap", (e) => { if (e.target === stage) { multiSel.clear(); if (selInstance) { selInstance = null; renderHeader(); renderFeatures(); renderParams(); } renderInstances(); renderCanvas(); } });
    setTimeout(fitCanvas, 0);
  }
  function fitCanvas() { if (!stage) return; const box = stage.container(); stage.width(box.clientWidth || 800); stage.height(box.clientHeight || 500); renderCanvas(); }

  function setGrid(g) { gridSize = g; localStorage.setItem("pgck.web2.studio.grid", g); syncToggles(); renderCanvas(); }

  function positionsFor(insts) {
    const saved = loadPos(); const pos = {};
    const cols = Math.max(1, Math.floor((stage.width() - 16) / gridSize));
    let i = 0;
    for (const t of insts) {
      if (saved[t.id]) pos[t.id] = saved[t.id];
      else { pos[t.id] = { x: 12 + (i % cols) * gridSize, y: 12 + Math.floor(i / cols) * gridSize }; }
      i++;
    }
    return pos;
  }

  function renderCanvas() {
    if (!stage || !selKernel) return;
    gridLayer.destroyChildren(); linkLayer.destroyChildren(); tileLayer.destroyChildren();
    const W = stage.width(), H = stage.height();
    const insts = (window.Bus.state.instances[selKernel] || []);
    // grid
    for (let x = 0; x <= W; x += gridSize) gridLayer.add(new Konva.Line({ points: [x, 0, x, H], stroke: "#eef2f7", strokeWidth: 1 }));
    for (let y = 0; y <= H; y += gridSize) gridLayer.add(new Konva.Line({ points: [0, y, W, y], stroke: "#eef2f7", strokeWidth: 1 }));
    gridLayer.batchDraw();

    const pos = positionsFor(insts);
    // links (optional): connect tiles sharing part_of_goal to the selected tile
    if (showLinks || selInstance) drawLinks(insts, pos);

    for (const t of insts) {
      const p = pos[t.id]; const g = buildTile(t, p);
      tileLayer.add(g);
    }
    updateSizeLabel(insts.length);
    tileLayer.batchDraw();
  }

  function drawLinks(insts, pos) {
    const center = (id) => ({ x: pos[id].x + TILE_W / 2, y: pos[id].y + 22 });
    if (selInstance) {
      const goal = selInstance.body[N + "part_of_goal"];
      const a = center(selInstance.id);
      insts.forEach((t) => {
        if (t.id === selInstance.id) return;
        if (showLinks ? sameGoal(t, goal) : sameGoal(t, goal)) {
          const b = center(t.id);
          linkLayer.add(new Konva.Line({ points: [a.x, a.y, b.x, b.y], stroke: "#cdd9ea", strokeWidth: 1.5, dash: [4, 3] }));
        }
      });
    }
    linkLayer.batchDraw();
  }
  const sameGoal = (t, goal) => goal && t.body[N + "part_of_goal"] === goal;

  function buildTile(t, p) {
    const col = STATE_COL[t.state] || STATE_COL.planned;
    const sel = multiSel.has(t.id);
    const g = new Konva.Group({ x: p.x, y: p.y, draggable: true });
    // icon
    g.add(new Konva.Rect({ x: (TILE_W - 44) / 2, y: 2, width: 44, height: 44, cornerRadius: 11, fill: "#fff", stroke: sel ? "#2f7bf6" : "#e2e8f1", strokeWidth: sel ? 2 : 1.2, shadowColor: "#142036", shadowBlur: sel ? 10 : 5, shadowOpacity: sel ? 0.14 : 0.06, shadowOffsetY: 1 }));
    g.add(new Konva.Rect({ x: (TILE_W - 44) / 2 + 7, y: 9, width: 6, height: 30, cornerRadius: 3, fill: col }));
    g.add(new Konva.Text({ x: (TILE_W - 44) / 2 + 18, y: 12, text: iconFor(selKernel), fontSize: 17, fill: "#46566f", fontFamily: "system-ui" }));
    // label (2 lines, ellipsis)
    g.add(new Konva.Text({ x: -3, y: 49, width: TILE_W + 6, height: 24, align: "center", text: t.title, fontSize: 9.5, lineHeight: 1.15, fill: sel ? "#1b2533" : "#5a6a82", fontFamily: "system-ui", ellipsis: true, wrap: "word" }));
    g.on("click tap", (e) => { e.cancelBubble = true; selectInstance(t.id, e.evt && e.evt.shiftKey); });
    g.on("mouseenter", () => { document.body.style.cursor = "pointer"; });
    g.on("mouseleave", () => { document.body.style.cursor = ""; });
    g.on("dragend", () => {
      let x = g.x(), y = g.y();
      if (snap) { x = Math.round(x / gridSize) * gridSize; y = Math.round(y / gridSize) * gridSize; g.position({ x, y }); }
      const saved = loadPos(); saved[t.id] = { x, y }; savePos(saved);
      renderCanvas();
    });
    return g;
  }

  function updateSizeLabel(n) { const el = host.querySelector("#cb-size"); if (el) el.textContent = `${n} tiles · ${stage.width()}×${stage.height()} · cell ${gridSize}`; }

  // ---------- alignment ----------
  function targetIds() { const insts = window.Bus.state.instances[selKernel] || []; const ids = multiSel.size > 1 ? [...multiSel] : insts.map((t) => t.id); return ids; }
  function arrangeGrid() {
    const insts = (window.Bus.state.instances[selKernel] || []).slice().sort((a, b) => (+b.body[N + "priority"] || 0) - (+a.body[N + "priority"] || 0));
    const cols = Math.max(1, Math.floor((stage.width() - 16) / gridSize));
    const saved = {}; insts.forEach((t, i) => { saved[t.id] = { x: 12 + (i % cols) * gridSize, y: 12 + Math.floor(i / cols) * gridSize }; });
    savePos(saved); renderCanvas();
  }
  function alignSel(edge) {
    const ids = targetIds(); const pos = loadPos(); if (!ids.length) return;
    const vals = ids.map((id) => pos[id] || { x: 12, y: 12 });
    if (edge === "left") { const m = Math.min(...vals.map((v) => v.x)); ids.forEach((id) => pos[id] = { ...(pos[id] || {}), x: m, y: (pos[id] || {}).y ?? 12 }); }
    if (edge === "top") { const m = Math.min(...vals.map((v) => v.y)); ids.forEach((id) => pos[id] = { x: (pos[id] || {}).x ?? 12, y: m }); }
    savePos(pos); renderCanvas();
  }
  function distributeSel(axis) {
    const ids = targetIds(); if (ids.length < 3) return; const pos = loadPos();
    const k = axis === "h" ? "x" : "y";
    const sorted = ids.slice().sort((a, b) => (pos[a] || {})[k] - (pos[b] || {})[k]);
    const lo = (pos[sorted[0]] || {})[k] ?? 12, hi = (pos[sorted[sorted.length - 1]] || {})[k] ?? 12;
    const step = (hi - lo) / (sorted.length - 1);
    sorted.forEach((id, i) => { pos[id] = pos[id] || { x: 12, y: 12 }; pos[id][k] = Math.round(lo + i * step); });
    savePos(pos); renderCanvas();
  }

  // ---------- region 5 · features ----------
  function renderFeatures() {
    const F = host.querySelector("#st-feat"); const Fh = host.querySelector("#st-feat-h"); if (!F) return;
    if (!selInstance) { Fh.textContent = "features"; F.innerHTML = `<div class="pnote">select an instance tile to expose its edges, predicates, actions &amp; proofs</div>`; return; }
    const t = selInstance; Fh.textContent = "features · " + t.type;
    const sec = (title, body) => `<div class="fsec"><div class="fsh">${title}</div>${body}</div>`;
    const goal = t.body[N + "part_of_goal"], tk = t.body[N + "target_kernel"];
    const edges = [tk && `<div class="fedge"><span class="ep">target_kernel</span> → <span class="en">${esc(tk)}</span></div>`, goal && `<div class="fedge"><span class="ep">part_of_goal</span> → <span class="en">${esc(local(goal))}</span></div>`].filter(Boolean).join("") || `<div class="pnote">no outbound edges</div>`;
    const preds = Object.entries(t.body || {}).map(([k, v]) => `<div class="fpred"><span class="pk">${esc(local(k))}</span><span class="pv">${esc(String(v))}</span></div>`).join("");
    const worker = WORKERED.test(selKernel);
    const acts = ["task.update", "task.create", "provenance"].map((a) => `<button class="fact" data-act="${a}">${a}</button>`).join("") + `<div class="pnote" style="margin-top:6px">${worker ? "external worker — NATS round-trip to trusted execution (SPIFFE node · workflow attestation)" : "pure-semantic kernel — no external worker"}</div>`;
    const proofs = (t.proof_digest ? `<div class="fpred"><span class="pk">proof</span><span class="pv">${String(t.proof_digest).slice(0, 28)}…</span></div>` : "") + `<div class="fpred"><span class="pk">verified</span><span class="pv">${t.verified ? "✓ true (HMAC chain)" : "✗"}</span></div>` + `<div id="st-ledger" class="pnote">loading ledger…</div>`;
    F.innerHTML = sec("edges", edges) + sec("predicates", preds) + sec("actions", acts) + sec("proofs", proofs);
    F.querySelectorAll(".fact").forEach((b) => b.onclick = () => { });
    loadLedger(t.id);
  }
  async function loadLedger(id) {
    try { const d = await window.CKTransport.call("provenance", { id }); const el = host.querySelector("#st-ledger"); if (!el) return;
      if (d && d.ok && (d.ledger || []).length) { el.className = "fledger"; el.innerHTML = d.ledger.map((r) => `<div class="lrow"><span>#${r.seq}${r.prev_seq ? " ← " + r.prev_seq : ""}</span><span>${(r.body_sha256 || "").slice(0, 14)}…</span></div>`).join(""); }
      else el.textContent = "no ledger rows";
    } catch (e) { const el = host.querySelector("#st-ledger"); if (el) el.textContent = "ledger unavailable"; }
  }

  // ---------- live actions ----------
  async function updateLifecycle(to) { if (!selInstance) return; selInstance.state = to; renderParams(); renderHeader(); renderCanvas(); try { await window.CKTransport.call("task.update", { id: selInstance.id, lifecycle_state: to }); } catch (e) { } }
  async function updatePriority(p) { if (!selInstance) return; selInstance.body[N + "priority"] = String(p); try { await window.CKTransport.call("task.update", { id: selInstance.id, priority: p }); } catch (e) { } renderInstances(); }

  const local = (v) => String(v || "").replace(/^.*[#/]/, "");
  const esc = (s) => String(s || "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  window.CKKernels.push({ id: "studio", icon: "❖", title: "studio", mount, onActivate });
})();
