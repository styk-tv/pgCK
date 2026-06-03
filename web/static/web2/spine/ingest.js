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

  // ---- authoritative snapshot via the web-protocol verb the kernel answers ----
  // snapshot.board returns the FULL board (kernels + sealed tasks). This is the
  // backfill: explorer/board show all existing governed state on connect, not
  // just post-connect seals. Live writes emit events; we debounce-refresh.
  async function snapshot() {
    if (!window.CKTransport || !window.CKTransport.connected()) return;
    try {
      const d = await window.CKTransport.call("snapshot.board");
      if (!d || !d.ok) return;
      const s = window.Bus.state;
      const kernels = (d.kernels || []).map((k) => ({ name: k.name, count: 0 }));
      const instances = {};
      for (const k of kernels) instances[k.name] = [];
      for (const t of (d.tasks || [])) {
        const kn = t.target_kernel || "unsorted";
        if (!instances[kn]) { instances[kn] = []; kernels.push({ name: kn, count: 0 }); }
        instances[kn].push({
          id: t.id, title: t.title, kernel: kn, type: "Task",
          state: String(t.lifecycle_state || "planned").toLowerCase(),
          verified: t.verified, proof_digest: t.proof_digest,
          body: {
            "type": "https://conceptkernel.org/ontology/v3.7/Task",
            [N + "title"]: t.title, [N + "target_kernel"]: kn,
            [N + "lifecycle_state"]: t.lifecycle_state, [N + "priority"]: t.priority,
            [N + "queue_seq"]: t.queue_seq, [N + "created_by"]: t.created_by,
            [N + "part_of_goal"]: t.part_of_goal,
          },
        });
      }
      for (const k of kernels) k.count = (instances[k.name] || []).length;
      s.kernels = kernels; s.instances = instances;
      window.Bus.emit("snapshot.done", { count: (d.tasks || []).length });
    } catch (e) { /* offline / not answering — surfaces keep prior state */ }
  }

  let _t = null;
  function refresh() { clearTimeout(_t); _t = setTimeout(snapshot, 350); }

  window.Ingest = { parse, snapshot, refresh };
})();
