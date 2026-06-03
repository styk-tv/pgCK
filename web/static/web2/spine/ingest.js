/* web2 spine · ingest — turn the live governed event stream into Bus state.
   This is the asciinator principle done at the spine: ONE event stream, the
   reducer materialises `state.kernels` + `state.instances`, and every surface
   (explorer list, signage feed, konva canvas) renders from that one tree.
   Event-sourced, so it works against the published image with no request/reply
   (a sealed Task on event.kernel.pgCK.> upserts an instance here). */
(function () {
  const N = "https://conceptkernel.org/ontology/v3.7/";

  function parse(data) {
    if (!data || typeof data !== "object") return null;
    const flat = data.task || data.instance || {};
    const body = data.body || flat.body || data;          // payload is flat IRI-keyed
    const id = String(flat.id || body[N + "task_id"] || body[N + "id"] || data.id || "");
    const title = flat.title || body[N + "title"] || data.title || "(untitled)";
    const kernel = flat.target_kernel || body[N + "target_kernel"] || data.kernel || data.target_kernel || "unsorted";
    const state = String(flat.lifecycle_state || body[N + "lifecycle_state"] || "planned").toLowerCase();
    const type = (data.type || body.type || "").replace(/^.*[#/]/, "") || "Instance";
    if (!id) return null;
    return { id, title, kernel, state, type, body };
  }

  // reducer: upsert kernel + instance into the single tree
  window.Bus.reduce("event.in", (s, p) => {
    const t = parse(p.data);
    if (!t) return;
    let k = s.kernels.find((x) => x.name === t.kernel);
    if (!k) { k = { name: t.kernel, count: 0 }; s.kernels.push(k); s.instances[t.kernel] = []; }
    const arr = s.instances[t.kernel] || (s.instances[t.kernel] = []);
    const existing = arr.find((i) => i.id === t.id);
    if (existing) { Object.assign(existing, t); }
    else { arr.unshift(t); k.count++; }
    s._lastIngest = t;   // hint for renderers
  });

  window.Ingest = { parse };
})();
