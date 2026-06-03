/* web2 kernel · explorer — the MAIN modular surface (asciinator port). A split
   experience over the one event-sourced tree: kernels on the left, the selected
   kernel's sealed instances on the right. Event-sourced via spine/ingest, so it
   shows live governed state today with no request/reply. As inbound ckp.dispatch
   lands, the same surface gains seal/verify actions — this is the surface web/
   (the FastAPI slice) retires into. */
(function () {
  const N = "https://conceptkernel.org/ontology/v3.7/";
  const PCT_KEY = "pgck.web2.explorer.split";
  let host = null, sel = null, filter = "", dirty = false;

  function mount(h) {
    host = h;
    h.innerHTML = `
      <div class="shead">
        <h2>explorer</h2>
        <span class="sub">event-sourced · live kernels &amp; sealed instances</span>
      </div>
      <div class="split" id="exp-split">
        <div class="pane" id="exp-left"></div>
        <div class="divider" id="exp-div"><div class="grip"></div></div>
        <div class="pane right" id="exp-right">
          <div class="hint">select a kernel — its sealed instances appear here</div>
        </div>
      </div>`;
    setupDivider();
    // re-render on any state change, but only while visible (cheap + correct)
    window.Bus.subscribe(() => { if (window.Bus.state.active === "explorer") render(); else dirty = true; });
  }

  function onActivate() { render(); }

  function setupDivider() {
    const left = host.querySelector("#exp-left");
    const div = host.querySelector("#exp-div");
    let pct = Math.min(70, Math.max(24, +localStorage.getItem(PCT_KEY) || 42));
    const apply = (p) => { left.style.flexBasis = p + "%"; };
    apply(pct);
    let drag = false;
    div.addEventListener("mousedown", (e) => { drag = true; e.preventDefault(); document.body.style.userSelect = "none"; });
    window.addEventListener("mousemove", (e) => {
      if (!drag) return;
      const split = host.querySelector("#exp-split");
      const r = split.getBoundingClientRect();
      pct = Math.min(70, Math.max(24, ((e.clientX - r.left) / r.width) * 100));
      apply(pct);
    });
    window.addEventListener("mouseup", () => { if (drag) { drag = false; document.body.style.userSelect = ""; localStorage.setItem(PCT_KEY, pct.toFixed(1)); } });
  }

  function render() {
    dirty = false;
    if (!host) return;
    renderLeft();
    renderRight();
  }

  function renderLeft() {
    const L = host.querySelector("#exp-left"); if (!L) return;
    const kernels = window.Bus.state.kernels.slice().sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
    L.innerHTML = "";
    const f = el("input", "filter"); f.placeholder = "filter kernels…"; f.value = filter;
    f.oninput = () => { filter = f.value; renderLeft(); };
    L.appendChild(f);
    const q = filter.toLowerCase();
    const list = el("div", "klist");
    let shown = 0;
    for (const k of kernels) {
      if (q && !k.name.toLowerCase().includes(q)) continue;
      shown++;
      const row = el("div", "krow" + (sel === k.name ? " sel" : ""));
      const box = el("div");
      const n = el("div", "kn"); n.textContent = k.name;
      const u = el("div", "ku"); u.textContent = "ckp://Kernel#" + slug(k.name);
      box.append(n, u);
      const c = el("span", "kc"); c.textContent = k.count;
      row.append(box, c);
      row.onclick = () => { sel = k.name; render(); };
      list.appendChild(row);
    }
    if (!shown) { const e = el("div", "hint"); e.style.marginTop = "30px"; e.textContent = window.Bus.state.kernels.length ? "no kernel matches the filter" : "waiting for the first sealed instance…"; list.appendChild(e); }
    L.appendChild(list);
  }

  function renderRight() {
    const R = host.querySelector("#exp-right"); if (!R) return;
    if (!sel) { R.innerHTML = `<div class="hint">select a kernel — its sealed instances appear here</div>`; return; }
    const insts = (window.Bus.state.instances[sel] || []);
    R.innerHTML = "";
    const head = el("div", "rk");
    const h3 = el("h3"); h3.textContent = sel;
    const urn = el("div", "urn"); urn.textContent = "ckp://Kernel#" + slug(sel) + " · " + insts.length + " instance" + (insts.length === 1 ? "" : "s");
    head.append(h3, urn); R.appendChild(head);
    for (const t of insts) R.appendChild(card(t));
  }

  function card(t) {
    const c = el("div", "inst open");
    const hd = el("div", "hd");
    const ti = el("div", "t"); ti.textContent = t.title;
    const u = el("div", "u"); u.textContent = "ckp://" + t.type + "#" + String(t.id).slice(0, 18);
    const pill = el("div", "pill " + t.state); pill.textContent = t.state.replace("_", " ");
    hd.append(ti, u, pill);
    hd.onclick = () => c.classList.toggle("open");
    c.appendChild(hd);
    const bd = el("div", "bd");
    bd.appendChild(lab("stored body (ckp.instances · IRI-keyed JSONB)"));
    bd.appendChild(pre(prettyBody(t.body)));
    c.appendChild(bd);
    return c;
  }

  function prettyBody(body) {
    return Object.entries(body || {}).map(([k, v]) => {
      const kk = k === "type" ? "type" : local(k);
      return `  <span class="bk">${esc(kk)}</span>: <span class="bv">${esc(String(v))}</span>`;
    }).join("\n");
  }

  const el = (t, c) => { const e = document.createElement(t); if (c) e.className = c; return e; };
  const lab = (t) => { const d = el("div", "lbl"); d.textContent = t; return d; };
  const pre = (html) => { const p = el("pre"); p.innerHTML = html; return p; };
  const slug = (s) => (s || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "anon";
  const local = (v) => String(v || "").replace(/^.*[#/]/, "");
  const esc = (s) => String(s || "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  window.CKKernels.push({ id: "explorer", icon: "🔎", title: "explorer", mount, onActivate });
})();
