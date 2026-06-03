/* web2 kernel · studio — the concept-kernel IDE. Five regions left→right:
     1. icons      — one per concept kernel (the rail of governed kernels)
     2. params     — the kernel's exposed control parameters (its knob surface)
     3. instances  — instances the kernel has produced
     4. main       — top: selected-instance metadata header; below: the canvas,
                     a live graph of the kernel + its instances + peer edges
     5. features   — per-selected-element: edges · predicates · actions · proofs;
                     the surface where a kernel connects in/out to peers (graph).
   Everything materialises from the one Bus tree (snapshot.board backfilled).
   The canvas is the kernel "design on screen"; selecting nodes drives 4 & 5. */
(function () {
  const N = "https://conceptkernel.org/ontology/v3.7/";
  const LIFE = ["planned", "in_progress", "done"];
  // kernels that carry an external worker/tool vs pure-semantic (illustrative
  // until each kernel declares ckp:Affordance.executor); shapes the actions tab.
  const WORKERED = /pgCK|pgRDF|CK\.Lib|oci|web/i;

  let host = null, selKernel = null, selInstance = null;
  let stage = null, gLayer = null, eLayer = null;

  function mount(h) {
    host = h;
    h.innerHTML = `
      <div class="studio">
        <div class="st-icons" id="st-icons"></div>
        <div class="st-col st-params"><div class="st-ch">parameters</div><div id="st-params"></div></div>
        <div class="st-col st-insts"><div class="st-ch">instances</div><div id="st-insts"></div></div>
        <div class="st-main">
          <div class="st-header" id="st-header"></div>
          <div class="st-canvas" id="st-canvas"></div>
        </div>
        <div class="st-col st-feat"><div class="st-ch" id="st-feat-h">features</div><div id="st-feat"></div></div>
      </div>`;
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
      // auto-select the busiest kernel once the snapshot lands
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

  function selectKernel(name) { selKernel = name; selInstance = null; renderAll(); }
  function selectInstance(id) {
    selInstance = (window.Bus.state.instances[selKernel] || []).find((t) => t.id === id) || null;
    renderInstances(); renderParams(); renderHeader(); renderFeatures(); highlightCanvas();
  }

  function renderAll() { renderIcons(); renderParams(); renderInstances(); renderHeader(); renderFeatures(); renderCanvas(); }

  // ---------- region 2 · kernel parameter surface ----------
  // distinct predicates across the kernel's instances = the kernel's exposed
  // controls. lifecycle/priority are live (task.update); others are the schema.
  function renderParams() {
    const P = host.querySelector("#st-params"); if (!P) return;
    P.innerHTML = "";
    if (!selKernel) return;
    const insts = window.Bus.state.instances[selKernel] || [];
    const preds = new Set();
    insts.forEach((t) => Object.keys(t.body || {}).forEach((k) => preds.add(k)));
    const inst = selInstance;
    const ctrl = (label, node, hint) => { const r = document.createElement("div"); r.className = "prow"; r.innerHTML = `<div class="plbl">${label}${hint ? `<span class="phint">${hint}</span>` : ""}</div>`; r.appendChild(node); return r; };

    // lifecycle (segmented · live)
    const seg = document.createElement("div"); seg.className = "seg";
    LIFE.forEach((s) => { const b = document.createElement("button"); b.className = (inst && inst.state === s) ? "on " + s : ""; b.textContent = s === "in_progress" ? "doing" : s; b.disabled = !inst; b.onclick = () => updateLifecycle(s); seg.appendChild(b); });
    P.appendChild(ctrl("lifecycle_state", seg, "live"));

    // priority (slider · live-ish)
    const pr = document.createElement("input"); pr.type = "range"; pr.min = 1; pr.max = 9; pr.value = inst ? (inst.body[N + "priority"] || 5) : 5; pr.disabled = !inst;
    const pv = document.createElement("span"); pv.className = "pval"; pv.textContent = "P" + pr.value;
    pr.oninput = () => { pv.textContent = "P" + pr.value; };
    pr.onchange = () => updatePriority(pr.value);
    const pw = document.createElement("div"); pw.className = "pslide"; pw.append(pr, pv);
    P.appendChild(ctrl("priority", pw, "live"));

    // remaining predicates = read-only schema knobs
    [...preds].filter((k) => !/lifecycle_state|priority|title|^type$/.test(local(k))).sort().forEach((k) => {
      const v = document.createElement("div"); v.className = "pmeta"; v.textContent = inst ? String(inst.body[k] ?? "—") : "schema";
      P.appendChild(ctrl(local(k), v));
    });
    if (!inst) { const n = document.createElement("div"); n.className = "pnote"; n.textContent = "select an instance to bind these controls"; P.appendChild(n); }
  }

  // ---------- region 3 · instances ----------
  function renderInstances() {
    const L = host.querySelector("#st-insts"); if (!L) return;
    L.innerHTML = "";
    const insts = (window.Bus.state.instances[selKernel] || []).slice().sort((a, b) => (+b.body[N + "priority"] || 0) - (+a.body[N + "priority"] || 0));
    for (const t of insts) {
      const r = document.createElement("div"); r.className = "irow" + (selInstance && selInstance.id === t.id ? " sel" : "");
      r.innerHTML = `<span class="idot ${t.state}"></span><span class="it">${esc(t.title)}</span>`;
      r.onclick = () => selectInstance(t.id);
      L.appendChild(r);
    }
    if (!insts.length) { L.innerHTML = `<div class="pnote">no instances yet</div>`; }
  }

  // ---------- region 4a · instance metadata header ----------
  function renderHeader() {
    const H = host.querySelector("#st-header"); if (!H) return;
    if (!selKernel) { H.innerHTML = `<div class="hhint">select a concept kernel</div>`; return; }
    if (!selInstance) { H.innerHTML = `<div class="hk">${esc(selKernel)}</div><div class="hsub">${(window.Bus.state.instances[selKernel] || []).length} instances · select one to focus the canvas</div>`; return; }
    const t = selInstance;
    H.innerHTML =
      `<div class="hrow"><div class="ht">${esc(t.title)}</div>` +
      `<span class="pill ${t.state}">${t.state.replace("_", " ")}</span>` +
      (t.verified ? `<span class="vbadge">✓ verified</span>` : "") + `</div>` +
      `<div class="hmeta"><span class="urn">ckp://${t.type}#${esc(String(t.id))}</span>` +
      (t.proof_digest ? `<span class="hproof">proof ${String(t.proof_digest).slice(0, 12)}…</span>` : "") +
      (t.body[N + "created_by"] ? `<span class="hby">${esc(local(t.body[N + "created_by"]))}</span>` : "") + `</div>`;
  }

  // ---------- region 4b · canvas (kernel graph) ----------
  function initCanvas() {
    const box = host.querySelector("#st-canvas");
    stage = new Konva.Stage({ container: box, width: box.clientWidth || 800, height: box.clientHeight || 500 });
    eLayer = new Konva.Layer(); gLayer = new Konva.Layer();
    stage.add(eLayer); stage.add(gLayer);
    setTimeout(fitCanvas, 0);
  }
  function fitCanvas() { if (!stage) return; const box = stage.container(); stage.width(box.clientWidth || 800); stage.height(box.clientHeight || 500); renderCanvas(); }

  function renderCanvas() {
    if (!stage || !selKernel) return;
    gLayer.destroyChildren(); eLayer.destroyChildren();
    const W = stage.width(), H = stage.height();
    const cx = Math.max(220, W * 0.32), cy = H / 2;
    const insts = (window.Bus.state.instances[selKernel] || []);

    // central kernel node
    const kg = new Konva.Group({ x: cx, y: cy });
    kg.add(new Konva.Circle({ radius: 46, fill: "#1b2533" }));
    kg.add(new Konva.Text({ x: -44, y: -8, width: 88, align: "center", text: selKernel, fontSize: 11, fontStyle: "bold", fill: "#eef2f8", fontFamily: "system-ui", ellipsis: true, wrap: "none" }));
    const worker = WORKERED.test(selKernel);
    kg.add(new Konva.Text({ x: -44, y: 8, width: 88, align: "center", text: worker ? "⚙ worker" : "semantic", fontSize: 9, fill: "#8b9ab2", fontFamily: "system-ui" }));

    // instance nodes in a ring
    const R = Math.min(H, W * 0.6) * 0.42;
    const n = Math.min(insts.length, 28);
    for (let i = 0; i < n; i++) {
      const t = insts[i];
      const a = (i / n) * Math.PI * 2 - Math.PI / 2;
      const x = cx + Math.cos(a) * R, y = cy + Math.sin(a) * R;
      const col = { planned: "#9aa7bd", in_progress: "#2f7bf6", done: "#15b886", blocked: "#d2455a" }[t.state] || "#9aa7bd";
      eLayer.add(new Konva.Line({ points: [cx, cy, x, y], stroke: "#e2e8f1", strokeWidth: 1 }));
      const g = new Konva.Group({ x, y });
      const sel = selInstance && selInstance.id === t.id;
      g.add(new Konva.Circle({ radius: sel ? 13 : 9, fill: col, stroke: sel ? "#1b2533" : "#fff", strokeWidth: sel ? 2 : 1.5, name: "node", id: "n_" + t.id }));
      g.on("click tap", () => selectInstance(t.id));
      g.on("mouseenter", () => { document.body.style.cursor = "pointer"; });
      g.on("mouseleave", () => { document.body.style.cursor = ""; });
      gLayer.add(g);
    }
    if (insts.length > n) gLayer.add(new Konva.Text({ x: cx - 40, y: cy + R + 14, width: 80, align: "center", text: "+" + (insts.length - n) + " more", fontSize: 10, fill: "#7b8aa0" }));
    gLayer.add(kg);
    eLayer.batchDraw(); gLayer.batchDraw();
  }
  function highlightCanvas() { renderCanvas(); }

  // ---------- region 5 · features (edges/predicates/actions/proofs) ----------
  function renderFeatures() {
    const F = host.querySelector("#st-feat"); const Fh = host.querySelector("#st-feat-h");
    if (!F) return;
    if (!selInstance) { Fh.textContent = "features"; F.innerHTML = `<div class="pnote">select an instance node to expose its edges, predicates, actions &amp; proofs</div>`; return; }
    const t = selInstance; Fh.textContent = "features · " + t.type;
    const sec = (title, body) => `<div class="fsec"><div class="fsh">${title}</div>${body}</div>`;
    // edges (graph connections in/out)
    const goal = t.body[N + "part_of_goal"], tk = t.body[N + "target_kernel"];
    const edges = [tk && `<div class="fedge"><span class="ep">target_kernel</span> → <span class="en">${esc(tk)}</span></div>`,
      goal && `<div class="fedge"><span class="ep">part_of_goal</span> → <span class="en">${esc(local(goal))}</span></div>`].filter(Boolean).join("") || `<div class="pnote">no outbound edges</div>`;
    // predicates (RDF body)
    const preds = Object.entries(t.body || {}).map(([k, v]) => `<div class="fpred"><span class="pk">${esc(local(k))}</span><span class="pv">${esc(String(v))}</span></div>`).join("");
    // actions (kernel affordances / verbs)
    const worker = WORKERED.test(selKernel);
    const acts = ["task.update", "task.create", "provenance"].map((a) => `<button class="fact" data-act="${a}">${a}</button>`).join("")
      + `<div class="pnote" style="margin-top:6px">${worker ? "external worker — NATS round-trip to trusted execution (SPIFFE node · workflow attestation)" : "pure-semantic kernel — no external worker"}</div>`;
    // proofs
    const proofs = (t.proof_digest ? `<div class="fpred"><span class="pk">proof</span><span class="pv">${String(t.proof_digest).slice(0, 28)}…</span></div>` : "")
      + `<div class="fpred"><span class="pk">verified</span><span class="pv">${t.verified ? "✓ true (HMAC chain)" : "✗"}</span></div>`
      + `<div id="st-ledger" class="pnote">loading ledger…</div>`;
    F.innerHTML = sec("edges", edges) + sec("predicates", preds) + sec("actions", acts) + sec("proofs", proofs);
    F.querySelectorAll(".fact").forEach((b) => b.onclick = () => actionClicked(b.dataset.act));
    loadLedger(t.id);
  }

  async function loadLedger(id) {
    try {
      const d = await window.CKTransport.call("provenance", { id });
      const el = host.querySelector("#st-ledger"); if (!el) return;
      if (d && d.ok && (d.ledger || []).length) {
        el.className = "fledger";
        el.innerHTML = d.ledger.map((r) => `<div class="lrow"><span>#${r.seq}${r.prev_seq ? " ← " + r.prev_seq : ""}</span><span>${(r.body_sha256 || "").slice(0, 14)}…</span></div>`).join("");
      } else { el.textContent = "no ledger rows"; }
    } catch (e) { const el = host.querySelector("#st-ledger"); if (el) el.textContent = "ledger unavailable"; }
  }

  // ---------- live actions ----------
  async function updateLifecycle(to) {
    if (!selInstance) return;
    selInstance.state = to; renderParams(); renderHeader(); renderCanvas();
    try { await window.CKTransport.call("task.update", { id: selInstance.id, lifecycle_state: to }); } catch (e) { }
  }
  async function updatePriority(p) {
    if (!selInstance) return;
    selInstance.body[N + "priority"] = String(p);
    try { await window.CKTransport.call("task.update", { id: selInstance.id, priority: p }); } catch (e) { }
    renderInstances();
  }
  function actionClicked(a) { /* surfaces the affordance; wiring per-verb is the next bite */ }

  const local = (v) => String(v || "").replace(/^.*[#/]/, "");
  const esc = (s) => String(s || "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  window.CKKernels.push({ id: "studio", icon: "❖", title: "studio", mount, onActivate });
})();
