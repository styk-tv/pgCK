/* web2 kernel · rdf.js — every message over WSS is typed, so every message is a
   set of RDF quads. This captures the live governed stream into an in-browser
   quad store: sealed instance bodies are IRI-keyed (expanded JSON-LD), so the
   subject is the instance URN and each IRI key is a predicate. Shows the store
   size, distinct types/predicates, and a live triple feed.

   NOTE: this is a PLACEHOLDER quad store. The real RDF/JS (@rdfjs/data-model + N3)
   integration + typed-message envelope is requested from CK.Lib.Js via
   _WIP/NOTIFIES.CK.Lib.Js.v1.3.11.rdfjs-typed-message-store.md — when that lands,
   this migrates to CK.toQuads()/CK.rdf.store. */
(function () {
  const N = "https://conceptkernel.org/ontology/v3.7/";
  const CAP = 4000;
  const store = { quads: [], byPred: {}, byType: {}, subjects: new Set() };
  window.RdfStore = store;
  let host = null;

  function local(v) { return String(v || "").replace(/^.*[#/]/, ""); }

  function toQuads(data, raw) {
    if (!data || typeof data !== "object") return [];
    const type = data.type || data["@type"] || "Instance";
    const id = data[N + "task_id"] || data.id || (data.body && (data.body[N + "task_id"])) || "anon";
    // prefer the self-identifying @id (stamped at ckp.seal projection); fall back
    // to composing the subject from type + id for pre-@id bodies.
    const subj = data["@id"] || ("ckp://" + local(type) + "#" + String(id));
    const subjFull = (raw && (raw.subject || raw.subj)) || "";
    const out = [];
    for (const [k, v] of Object.entries(data)) {
      if (k === "@id") continue;
      if (k === "type" || k === "@type") out.push({ s: subj, p: "a", o: local(type), wssSubject: subjFull });
      else if (v != null && typeof v !== "object") out.push({ s: subj, p: k, o: String(v), wssSubject: subjFull });
    }
    return out;
  }

  function onEvent(data, raw) {
    const quads = toQuads(data, raw);
    if (!quads.length) return;
    for (const q of quads) {
      store.quads.push(q);
      store.byPred[q.p] = (store.byPred[q.p] || 0) + 1;
      if (q.p === "a") store.byType[q.o] = (store.byType[q.o] || 0) + 1;
      store.subjects.add(q.s);
    }
    while (store.quads.length > CAP) store.quads.shift();
    if (host && window.Bus.state.active === "rdfjs") render();
  }

  function mount(h) { host = h; render(); }

  function render() {
    if (!host) return;
    const preds = Object.entries(store.byPred).sort((a, b) => b[1] - a[1]);
    const types = Object.entries(store.byType).sort((a, b) => b[1] - a[1]);
    const recent = store.quads.slice(-40).reverse();
    host.innerHTML = `
      <div class="shead">
        <h2>rdf.js</h2>
        <span class="sub">typed WSS messages → quad store · ${store.quads.length} quads · ${store.subjects.size} subjects</span>
      </div>
      <div class="rdf-wrap">
        <div class="rdf-cols">
          <div class="rdf-col"><div class="rdf-h">types <span>${types.length}</span></div>${types.map(([t, c]) => `<div class="rdf-row"><span class="rk-t">${esc(t)}</span><span class="rk-c">${c}</span></div>`).join("") || `<div class="pnote">none yet</div>`}</div>
          <div class="rdf-col"><div class="rdf-h">predicates <span>${preds.length}</span></div>${preds.slice(0, 18).map(([p, c]) => `<div class="rdf-row"><span class="rk-p">${esc(p === "a" ? "rdf:type" : local(p))}</span><span class="rk-c">${c}</span></div>`).join("") || `<div class="pnote">none yet</div>`}</div>
        </div>
        <div class="rdf-feed-h">live triples</div>
        <div class="rdf-feed">${recent.map(q => `<div class="tq"><span class="ts">${esc(short(q.s))}</span><span class="tp">${esc(q.p === "a" ? "a" : local(q.p))}</span><span class="to">${esc(String(q.o).slice(0, 40))}</span></div>`).join("") || `<div class="pnote">waiting for the next governed message…</div>`}</div>
      </div>`;
  }

  const short = (s) => String(s || "").replace(/^ckp:\/\//, "");
  const esc = (s) => String(s || "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  // lib:"rdfjs" → the rail shows it only when the library is enabled (settings)
  window.CKKernels.push({ id: "rdfjs", icon: "account_tree", title: "rdf.js", lib: "rdfjs", mount, onEvent });
})();
