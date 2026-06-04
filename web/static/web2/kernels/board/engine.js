/* web2 kernel · board — the training-tasks explorer, ported from web/tasks.html
   into the modular pattern. Columns per concept kernel, cards sorted by priority,
   lifecycle segments, inline composer, provenance drawer. READS are event-sourced
   from the one Bus tree (work today against the published image); WRITES (seal,
   cycle, add-kernel, upgrade) go over NATS via ckp.dispatch and light up when
   inbound request/reply lands — same wire, forward-compatible. This is the board
   web/tasks.html retires into; unified, running from pgCK over NATS. */
(function () {
  const N = "https://conceptkernel.org/ontology/v3.7/";
  const LIFE = ["planned", "in_progress", "done"];
  let host = null, composing = null, sub = null, subUrn = null;
  const anon = "anon-" + Math.random().toString(16).slice(2, 8);

  function mount(h) {
    host = h;
    h.innerHTML = `
      <div class="shead">
        <h2>board</h2>
        <span class="sub">training tasks · columns per kernel · sealed over NATS</span>
        <span style="flex:1"></span>
        <span id="bd-id" class="bd-id"></span>
      </div>
      <div class="board" id="bd-board"></div>
      <div class="drawer" id="bd-drawer"><button class="x" id="bd-x">×</button><div id="bd-dc"></div></div>`;
    host.querySelector("#bd-x").onclick = () => host.querySelector("#bd-drawer").classList.remove("open");
    window.Bus.subscribe(() => { if (window.Bus.state.active === "board") render(); });
  }
  function onActivate() { render(); }

  const pri = (t) => +(t.body[N + "priority"] || 0);
  const seqn = (t) => +(t.body[N + "queue_seq"] || 0);
  const who = () => sub || null;

  function render() {
    if (!host) return;
    renderId();
    const board = host.querySelector("#bd-board"); if (!board) return;
    const focusKey = document.activeElement && document.activeElement.dataset && document.activeElement.dataset.composer;
    board.innerHTML = "";
    const kernels = window.Bus.state.kernels.slice().sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
    for (const k of kernels) {
      const col = el("div", "col");
      const h = el("div", "colhead");
      const n = el("span", "name"); n.textContent = k.name;
      const insts = (window.Bus.state.instances[k.name] || []).slice().sort((a, b) => pri(b) - pri(a) || seqn(a) - seqn(b));
      const cnt = el("span", "count"); cnt.textContent = insts.length;
      const add = el("button", "add"); add.textContent = "+"; add.title = "add task"; add.onclick = () => { composing = k.name; render(); };
      h.append(n, cnt, add); col.append(h);
      if (composing === k.name) col.append(composer(k.name, focusKey === k.name));
      for (const t of insts) col.append(card(t));
      board.append(col);
    }
    const ac = el("div", "col addcol"); const g = el("div", "ghost"); g.textContent = "+ concept kernel";
    g.onclick = addKernelPrompt; ac.append(g); board.append(ac);
  }

  function renderId() {
    const b = host.querySelector("#bd-id"); if (!b) return; b.innerHTML = "";
    if (sub) { const c = el("span", "chip you"); c.textContent = "you · " + sub; c.title = subUrn; b.append(c); }
    else {
      const a = el("span", "chip"); a.textContent = "anon · " + anon;
      const u = el("span", "chip up"); u.textContent = "upgrade ↑"; u.onclick = upgrade;
      b.append(a, u);
    }
  }

  function card(t) {
    const c = el("div", "card");
    c.onclick = (e) => { if (e.target.closest(".seg")) return; openProv(t); };
    const ti = el("div", "t"); ti.textContent = t.title;
    const m = el("div", "meta");
    const seg = el("div", "seg");
    LIFE.forEach((s) => {
      const b = el("button", (s === t.state ? "on " + s : "")); b.textContent = s === "in_progress" ? "doing" : s;
      b.onclick = (ev) => { ev.stopPropagation(); cycle(t, s); };
      seg.append(b);
    });
    const p = el("span", "pri"); p.textContent = "P" + (t.body[N + "priority"] || "·");
    m.append(seg, p); c.append(ti, m); return c;
  }

  function composer(kernel, keepFocus) {
    const c = el("div", "composer");
    const title = el("input"); title.type = "text"; title.placeholder = "task title"; title.dataset.composer = kernel;
    const l1 = el("div", "clbl"); const ls = el("span"); ls.textContent = "priority"; const lv = el("span"); lv.textContent = "5"; l1.append(ls, lv);
    const r = el("input"); r.type = "range"; r.min = 1; r.max = 9; r.value = 5; r.oninput = () => lv.textContent = r.value;
    let life = "planned"; const seg = el("div", "seg");
    LIFE.forEach((s) => { const b = el("button", (s === life ? "on " + s : "")); b.textContent = s === "in_progress" ? "doing" : s; b.onclick = () => { life = s; [...seg.children].forEach((x, i) => x.className = (LIFE[i] === s ? "on " + LIFE[i] : "")); }; seg.append(b); });
    const go = el("div", "go"); const ok = el("button", "btn p"); ok.textContent = "seal →"; const no = el("button", "btn g"); no.textContent = "cancel";
    const submit = async () => {
      const t = title.value.trim(); if (!t) return; ok.disabled = true;
      try {
        const d = await window.CKTransport.call("task.create", { task: { target_kernel: kernel, title: t, priority: r.value, lifecycle_state: life }, sub: who() });
        if (d && d.ok) { toast("sealed · " + (d.proof_digest || "").slice(0, 10) + "…"); composing = null; }
        else toast("rejected: " + ((d && d.error) || "?"));
      } catch (e) { toast("seal pending — inbound dispatch not yet answering"); composing = null; render(); }
      ok.disabled = false;
    };
    ok.onclick = submit;
    title.onkeydown = (e) => { if (e.key === "Enter") submit(); if (e.key === "Escape") { composing = null; render(); } };
    no.onclick = () => { composing = null; render(); };
    go.append(no, ok); c.append(title, l1, r, seg, go);
    if (!keepFocus) setTimeout(() => title.focus(), 0);
    return c;
  }

  async function cycle(t, to) {
    // optimistic local update so the board is responsive immediately
    t.state = to; render();
    try {
      const d = await window.CKTransport.call("task.update", { id: t.id, lifecycle_state: to });
      if (d && d.ok) toast("updated · " + ((d.proof_digest || "").slice(0, 8)) + "…");
    } catch (e) { /* local optimistic stands; re-seal will reconcile when inbound lands */ }
  }

  async function addKernelPrompt() {
    const name = prompt("New concept kernel name"); if (!name || !name.trim()) return;
    try { const d = await window.CKTransport.call("kernel.create", { name: name.trim() }); if (d && d.ok) toast("kernel · " + name.trim()); }
    catch (e) { toast("kernel create pending — inbound dispatch not yet answering"); }
  }

  async function upgrade() {
    const name = prompt("Upgrade identity — your name"); if (!name || !name.trim()) return;
    try { const d = await window.CKTransport.call("participant.join", { name: name.trim() }); if (d && d.ok) { sub = d.sub; subUrn = d.urn; renderId(); toast("you are " + d.urn); } }
    catch (e) { toast("identity upgrade pending — inbound dispatch not yet answering"); }
  }

  // provenance drawer — event-sourced body shown immediately; enriched with
  // ledger/proof from ckp.dispatch when inbound answers.
  async function openProv(t) {
    const dr = host.querySelector("#bd-drawer"), c = host.querySelector("#bd-dc");
    dr.classList.add("open");
    c.innerHTML = "";
    const h = el("h2"); h.textContent = t.title; c.append(h);
    c.append(kv("URN", "ckp://" + t.type + "#" + t.id, true));
    c.append(kv("target_kernel →", t.kernel));
    c.append(kv("lifecycle · priority", t.state + "  ·  P" + (t.body[N + "priority"] || "·")));
    if (t.body[N + "created_by"]) c.append(kv("created_by →", t.body[N + "created_by"], true));
    const lh = el("div", "kv"); lh.innerHTML = "<b>stored body (ckp.instances · IRI-keyed)</b>"; c.append(lh);
    const pre = el("pre"); pre.textContent = Object.entries(t.body).map(([k, v]) => local(k) + ": " + v).join("\n"); c.append(pre);
    try {
      const d = await window.CKTransport.call("provenance", { id: t.id });
      if (d && d.ok && d.ledger) {
        const lg = el("div", "kv"); lg.innerHTML = "<b>ledger chain (append-only, signed)</b>"; c.append(lg);
        (d.ledger || []).forEach((r) => { const row = el("div", "ledrow"); row.innerHTML = `<span>#${r.seq}${r.prev_seq ? " ← " + r.prev_seq : ""}</span><span>${(r.body_sha256 || "").slice(0, 16)}…</span>`; c.append(row); });
      }
    } catch (e) { const n = el("div", "kv"); n.innerHTML = '<b style="color:var(--warn)">ledger/proof</b>live chain loads when inbound dispatch answers (event-sourced view above is authoritative for fields).'; c.append(n); }
  }

  // helpers
  const el = (t, c) => { const e = document.createElement(t); if (c) e.className = c; return e; };
  const local = (v) => String(v || "").replace(/^.*[#/]/, "");
  function kv(label, val, mono) { const d = el("div", "kv"); const b = el("b"); b.textContent = label; const v = el("div", mono ? "mono" : ""); v.textContent = val; d.append(b, v); return d; }
  let toastEl = null;
  function toast(t) { if (!toastEl) { toastEl = document.createElement("div"); toastEl.className = "toast"; document.body.appendChild(toastEl); } toastEl.textContent = t; toastEl.classList.add("show"); clearTimeout(toast._t); toast._t = setTimeout(() => toastEl.classList.remove("show"), 1900); }

  window.CKKernels.push({ id: "board", icon: "view_kanban", title: "board", mount, onActivate });
})();
