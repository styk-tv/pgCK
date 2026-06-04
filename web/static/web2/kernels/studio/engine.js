/* web2 kernel · studio — concept-kernel IDE. Regions: icons · parameters ·
   instances · main(header + canvas toolbar + GridCanvas) · features. The canvas
   is the modular shell/GridCanvas (grid · drag-snap · wheel-pan · pinch-zoom ·
   align). A mode toggle swaps the canvas between INSTANCES and PREDICATES — both
   as grid-aligned icon tiles. DOM chrome unified on Google Material Symbols. */
(function () {
  const N = "https://conceptkernel.org/ontology/v3.7/";
  const LIFE = ["planned", "in_progress", "done"];
  const WORKERED = /pgCK|pgRDF|CK\.Lib|oci|web/i;
  const STATE_COL = { planned: "#9aa7bd", in_progress: "#2f7bf6", done: "#15b886", blocked: "#d2455a" };
  const KMAT = { pgCK: "database", pgRDF: "share", web2: "grid_view", web3: "deployed_code", "parity-audit": "balance", "oci-germination": "package_2" };
  const kmat = (n) => KMAT[n] || (/CK\.Lib/.test(n) ? "library_books" : "hub");
  const mi = (n, cls) => `<span class="material-symbols-outlined${cls ? " " + cls : ""}">${n}</span>`;

  let host = null, selKernel = null, selInstance = null, mode = "instances", gc = null;

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
    gc = window.GridCanvas(host.querySelector("#st-canvas"), {
      gridSize: +localStorage.getItem("pgck.web2.studio.grid") || 92,
      snap: localStorage.getItem("pgck.web2.studio.snap") !== "0",
      onSelect: (id, additive) => onCanvasSelect(id, additive),
      onClear: () => { if (selInstance) { selInstance = null; renderHeader(); renderParams(); renderFeatures(); renderInstances(); } },
      linksFor: (selId) => linksFor(selId),
      onSize: (s) => { const el = host.querySelector("#cb-size"); if (el) el.textContent = `${s.n} ${mode} · ${Math.round(s.scale * 100)}% · cell ${s.grid}`; },
    });
    window.addEventListener("resize", () => gc && gc.fit());
    window.Bus.subscribe(() => { if (window.Bus.state.active === "studio") softRefresh(); });
  }

  function onActivate() { renderIcons(); if (!selKernel) { const k = top(); if (k) return selectKernel(k); } renderAll(); }
  const top = () => (window.Bus.state.kernels.slice().sort((a, b) => b.count - a.count)[0] || {}).name;
  let _s = null;
  function softRefresh() { clearTimeout(_s); _s = setTimeout(() => { if (!selKernel && window.Bus.state.kernels.length) return selectKernel(top()); renderIcons(); if (selKernel) { renderInstances(); feedCanvas(); } }, 200); }

  // region 1 · kernel icons (material)
  function renderIcons() {
    const R = host.querySelector("#st-icons"); if (!R) return; R.innerHTML = "";
    window.Bus.state.kernels.slice().sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)).forEach((k) => {
      const b = document.createElement("div"); b.className = "kicon" + (selKernel === k.name ? " on" : ""); b.title = k.name + " · " + k.count;
      b.innerHTML = `${mi(kmat(k.name), "g")}<span class="c">${k.count}</span>`;
      b.onclick = () => selectKernel(k.name); R.appendChild(b);
    });
  }
  function selectKernel(name) { selKernel = name; selInstance = null; gc && gc.clearSel(); renderAll(); }

  function renderAll() { renderIcons(); renderParams(); renderInstances(); renderHeader(); renderFeatures(); feedCanvas(); }

  // canvas feed (instances or predicates)
  function posStore(key) { return { load() { try { return JSON.parse(localStorage.getItem(key) || "{}"); } catch (e) { return {}; } }, save(p) { localStorage.setItem(key, JSON.stringify(p)); } }; }
  function instanceItems() { return (window.Bus.state.instances[selKernel] || []).slice().sort((a, b) => (+b.body[N + "priority"] || 0) - (+a.body[N + "priority"] || 0)).map((t) => ({ id: t.id, label: t.title, color: STATE_COL[t.state] || STATE_COL.planned, glyph: "" })); }
  function predicateItems() {
    if (selInstance) return Object.entries(selInstance.body || {}).map(([k, v], i) => ({ id: "p_" + i, label: local(k) + "\n" + String(v).slice(0, 22), color: "#8a6df0", glyph: "" }));
    const set = new Set(); (window.Bus.state.instances[selKernel] || []).forEach((t) => Object.keys(t.body || {}).forEach((k) => set.add(local(k))));
    return [...set].sort().map((p, i) => ({ id: "p_" + i, label: p, color: "#8a6df0", glyph: "" }));
  }
  function feedCanvas() {
    if (!gc || !selKernel) return;
    const key = `pgck.web2.studio.pos.${selKernel}.${mode}` + (mode === "predicates" && selInstance ? "." + selInstance.id : "");
    gc.setStore(posStore(key));
    gc.setItems(mode === "instances" ? instanceItems() : predicateItems());
    gc.render(mode === "instances" && selInstance ? selInstance.id : null);
  }
  function onCanvasSelect(id, additive) {
    if (mode !== "instances") return;
    selInstance = (window.Bus.state.instances[selKernel] || []).find((t) => t.id === id) || null;
    renderInstances(); renderParams(); renderHeader(); renderFeatures();
  }
  function linksFor(selId) { if (mode !== "instances") return []; const insts = window.Bus.state.instances[selKernel] || []; const me = insts.find((t) => t.id === selId); if (!me) return []; const goal = me.body[N + "part_of_goal"]; return insts.filter((t) => t.id !== selId && goal && t.body[N + "part_of_goal"] === goal).map((t) => t.id); }

  // region 2 · params
  function renderParams() {
    const P = host.querySelector("#st-params"); if (!P) return; P.innerHTML = ""; if (!selKernel) return;
    const insts = window.Bus.state.instances[selKernel] || []; const preds = new Set(); insts.forEach((t) => Object.keys(t.body || {}).forEach((k) => preds.add(k)));
    const inst = selInstance;
    const ctrl = (label, node, hint) => { const r = document.createElement("div"); r.className = "prow"; r.innerHTML = `<div class="plbl">${label}${hint ? `<span class="phint">${hint}</span>` : ""}</div>`; r.appendChild(node); return r; };
    const seg = document.createElement("div"); seg.className = "seg";
    LIFE.forEach((s) => { const b = document.createElement("button"); b.className = (inst && inst.state === s) ? "on " + s : ""; b.textContent = s === "in_progress" ? "doing" : s; b.disabled = !inst; b.onclick = () => updateLifecycle(s); seg.appendChild(b); });
    P.appendChild(ctrl("lifecycle_state", seg, "live"));
    const pr = document.createElement("input"); pr.type = "range"; pr.min = 1; pr.max = 9; pr.value = inst ? (inst.body[N + "priority"] || 5) : 5; pr.disabled = !inst;
    const pv = document.createElement("span"); pv.className = "pval"; pv.textContent = "P" + pr.value; pr.oninput = () => pv.textContent = "P" + pr.value; pr.onchange = () => updatePriority(pr.value);
    const pw = document.createElement("div"); pw.className = "pslide"; pw.append(pr, pv); P.appendChild(ctrl("priority", pw, "live"));
    [...preds].filter((k) => !/lifecycle_state|priority|title|^type$/.test(local(k))).sort().forEach((k) => { const v = document.createElement("div"); v.className = "pmeta"; v.textContent = inst ? String(inst.body[k] ?? "—") : "schema"; P.appendChild(ctrl(local(k), v)); });
    if (!inst) { const n = document.createElement("div"); n.className = "pnote"; n.textContent = "select an instance to bind these controls"; P.appendChild(n); }
  }

  // region 3 · instances
  function renderInstances() {
    const L = host.querySelector("#st-insts"); if (!L) return; L.innerHTML = "";
    const insts = (window.Bus.state.instances[selKernel] || []).slice().sort((a, b) => (+b.body[N + "priority"] || 0) - (+a.body[N + "priority"] || 0));
    insts.forEach((t) => { const r = document.createElement("div"); r.className = "irow" + (selInstance && selInstance.id === t.id ? " sel" : ""); r.innerHTML = `<span class="idot ${t.state}"></span><span class="it">${esc(t.title)}</span>`; r.onclick = () => { selInstance = t; renderInstances(); renderParams(); renderHeader(); renderFeatures(); feedCanvas(); }; L.appendChild(r); });
    if (!insts.length) L.innerHTML = `<div class="pnote">no instances yet</div>`;
  }

  // region 4a · header
  function renderHeader() {
    const H = host.querySelector("#st-header"); if (!H) return;
    if (!selKernel) { H.innerHTML = `<div class="hhint">select a concept kernel</div>`; return; }
    if (!selInstance) { H.innerHTML = `<div class="hk">${mi(kmat(selKernel))} ${esc(selKernel)}</div><div class="hsub">${(window.Bus.state.instances[selKernel] || []).length} instances · drag the icons · scroll to pan · ⌘-scroll to zoom</div>`; return; }
    const t = selInstance;
    H.innerHTML = `<div class="hrow"><div class="ht">${esc(t.title)}</div><span class="pill ${t.state}">${t.state.replace("_", " ")}</span>${t.verified ? `<span class="vbadge">${mi("verified", "vi")} verified</span>` : ""}</div><div class="hmeta"><span class="urn">ckp://${t.type}#${esc(String(t.id))}</span>${t.proof_digest ? `<span class="hproof">proof ${String(t.proof_digest).slice(0, 12)}…</span>` : ""}${t.body[N + "created_by"] ? `<span class="hby">${esc(local(t.body[N + "created_by"]))}</span>` : ""}</div>`;
  }

  // region 4 · toolbar (material)
  function renderToolbar() {
    const T = host.querySelector("#st-cbar"); if (!T) return;
    T.innerHTML = `
      <div class="cbgrp"><button class="cbtn mode on" id="cb-inst" title="instances">${mi("apps")}</button><button class="cbtn mode" id="cb-pred" title="predicates as grid">${mi("data_object")}</button></div>
      <div class="cbgrp"><span class="cblbl">grid</span><button class="cbtn gs" data-gs="72">S</button><button class="cbtn gs" data-gs="92">M</button><button class="cbtn gs" data-gs="120">L</button></div>
      <div class="cbgrp"><button class="cbtn tgl" id="cb-snap" title="snap to grid">${mi("grid_4x4")}</button><button class="cbtn tgl" id="cb-links" title="links">${mi("link")}</button></div>
      <div class="cbgrp"><span class="cblbl">align</span>
        <button class="cbtn" id="cb-arrange" title="arrange to grid">${mi("grid_view")}</button>
        <button class="cbtn" id="cb-alignL" title="align left">${mi("align_horizontal_left")}</button>
        <button class="cbtn" id="cb-alignT" title="align top">${mi("align_vertical_top")}</button>
        <button class="cbtn" id="cb-distH" title="distribute horizontally">${mi("horizontal_distribute")}</button>
        <button class="cbtn" id="cb-distV" title="distribute vertically">${mi("vertical_distribute")}</button></div>
      <div class="cbgrp"><button class="cbtn" id="cb-zin" title="zoom in">${mi("zoom_in")}</button><button class="cbtn" id="cb-zout" title="zoom out">${mi("zoom_out")}</button><button class="cbtn" id="cb-zfit" title="reset view">${mi("fit_screen")}</button></div>
      <div class="cbgrp cbsize"><span class="cblbl" id="cb-size">—</span></div>`;
    const on = (id, fn) => { const e = T.querySelector(id); if (e) e.onclick = fn; };
    T.querySelectorAll(".gs").forEach((b) => b.onclick = () => { localStorage.setItem("pgck.web2.studio.grid", b.dataset.gs); gc.setGrid(+b.dataset.gs); syncT(); });
    on("#cb-inst", () => setMode("instances")); on("#cb-pred", () => setMode("predicates"));
    on("#cb-snap", () => { const v = !host.querySelector("#cb-snap").classList.contains("on"); localStorage.setItem("pgck.web2.studio.snap", v ? "1" : "0"); gc.setSnap(v); syncT(); });
    on("#cb-links", () => { const v = !host.querySelector("#cb-links").classList.contains("on"); gc.setLinks(v); syncT(v); });
    on("#cb-arrange", () => gc.arrange()); on("#cb-alignL", () => gc.align("left")); on("#cb-alignT", () => gc.align("top"));
    on("#cb-distH", () => gc.distribute("h")); on("#cb-distV", () => gc.distribute("v"));
    on("#cb-zin", () => gc.zoom(1)); on("#cb-zout", () => gc.zoom(-1)); on("#cb-zfit", () => gc.resetView());
    syncT();
  }
  function syncT(linksOn) {
    if (!host) return;
    host.querySelectorAll(".gs").forEach((b) => b.classList.toggle("on", +b.dataset.gs === (+localStorage.getItem("pgck.web2.studio.grid") || 92)));
    host.querySelector("#cb-snap") && host.querySelector("#cb-snap").classList.toggle("on", localStorage.getItem("pgck.web2.studio.snap") !== "0");
    if (linksOn !== undefined) host.querySelector("#cb-links").classList.toggle("on", linksOn);
    host.querySelector("#cb-inst") && host.querySelector("#cb-inst").classList.toggle("on", mode === "instances");
    host.querySelector("#cb-pred") && host.querySelector("#cb-pred").classList.toggle("on", mode === "predicates");
  }
  function setMode(m) { mode = m; syncT(); feedCanvas(); }

  // region 5 · features (material section heads)
  function renderFeatures() {
    const F = host.querySelector("#st-feat"); const Fh = host.querySelector("#st-feat-h"); if (!F) return;
    if (!selInstance) { Fh.textContent = "features"; F.innerHTML = `<div class="pnote">select an instance tile to expose its edges, predicates, actions &amp; proofs</div>`; return; }
    const t = selInstance; Fh.textContent = "features · " + t.type;
    const sec = (icon, title, body) => `<div class="fsec"><div class="fsh">${mi(icon, "fi")} ${title}</div>${body}</div>`;
    const goal = t.body[N + "part_of_goal"], tk = t.body[N + "target_kernel"];
    const edges = [tk && `<div class="fedge"><span class="ep">target_kernel</span> → <span class="en">${esc(tk)}</span></div>`, goal && `<div class="fedge"><span class="ep">part_of_goal</span> → <span class="en">${esc(local(goal))}</span></div>`].filter(Boolean).join("") || `<div class="pnote">no outbound edges</div>`;
    const preds = Object.entries(t.body || {}).map(([k, v]) => `<div class="fpred"><span class="pk">${esc(local(k))}</span><span class="pv">${esc(String(v))}</span></div>`).join("");
    const worker = WORKERED.test(selKernel);
    const acts = ["task.update", "task.create", "provenance"].map((a) => `<button class="fact">${a}</button>`).join("") + `<div class="pnote" style="margin-top:6px">${worker ? "external worker — NATS round-trip to trusted execution (SPIFFE node · workflow attestation)" : "pure-semantic kernel — no external worker"}</div>`;
    const proofs = (t.proof_digest ? `<div class="fpred"><span class="pk">proof</span><span class="pv">${String(t.proof_digest).slice(0, 28)}…</span></div>` : "") + `<div class="fpred"><span class="pk">verified</span><span class="pv">${t.verified ? "✓ true (HMAC chain)" : "✗"}</span></div>` + `<div id="st-ledger" class="pnote">loading ledger…</div>`;
    F.innerHTML = sec("hub", "edges", edges) + sec("data_object", "predicates", preds) + sec("bolt", "actions", acts) + sec("verified_user", "proofs", proofs);
    loadLedger(t.id);
  }
  async function loadLedger(id) { try { const d = await window.CKTransport.call("provenance", { id }); const el = host.querySelector("#st-ledger"); if (!el) return; if (d && d.ok && (d.ledger || []).length) { el.className = "fledger"; el.innerHTML = d.ledger.map((r) => `<div class="lrow"><span>#${r.seq}${r.prev_seq ? " ← " + r.prev_seq : ""}</span><span>${(r.body_sha256 || "").slice(0, 14)}…</span></div>`).join(""); } else el.textContent = "no ledger rows"; } catch (e) { const el = host.querySelector("#st-ledger"); if (el) el.textContent = "ledger unavailable"; } }

  async function updateLifecycle(to) { if (!selInstance) return; selInstance.state = to; renderParams(); renderHeader(); feedCanvas(); try { await window.CKTransport.call("task.update", { id: selInstance.id, lifecycle_state: to }); } catch (e) { } }
  async function updatePriority(p) { if (!selInstance) return; selInstance.body[N + "priority"] = String(p); try { await window.CKTransport.call("task.update", { id: selInstance.id, priority: p }); } catch (e) { } renderInstances(); feedCanvas(); }

  const local = (v) => String(v || "").replace(/^.*[#/]/, "");
  const esc = (s) => String(s || "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  window.CKKernels.push({ id: "studio", icon: "dashboard", title: "studio", mount, onActivate });
})();
