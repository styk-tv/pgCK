/* web2 kernel · signage — the live governed-event monitor. Rides the event stream
   the all-in-one already emits (nats-relay: input.kernel.pgCK.action.> ->
   event.kernel.pgCK.<verb>, plus outbox seals). Bounded rolling feed: oldest row
   is removed when over the cap, so the DOM never grows unbounded (no leak).
   Works against the published image with zero Python. */
(function () {
  const CAP = 80;
  let feedEl = null;

  function mount(host) {
    host.innerHTML = `
      <div class="shead">
        <h2>signage</h2>
        <span class="sub">live governed events · event.kernel.pgCK.&gt;</span>
      </div>
      <div class="feed" id="sig-feed">
        <div class="fempty" id="sig-empty">waiting for the next governed event…</div>
      </div>`;
    feedEl = host.querySelector("#sig-feed");
  }

  function verbOf(data, raw) {
    const subj = (raw && (raw.subject || raw.subj)) || "";
    const m = subj.match(/event\.kernel\.pgCK\.(.+)$/);
    if (m) return m[1];
    return data.action || data.verb || data.kind || "event";
  }

  function summaryOf(data) {
    const t = data.task || data.instance || data.body || data;
    const title = t.title || t["https://conceptkernel.org/ontology/v3.7/title"];
    const tk = t.target_kernel || data.kernel || data.target_kernel;
    const id = data.id || t.id;
    return [title, tk && ("→ " + tk), id && ("#" + String(id).slice(0, 8))]
      .filter(Boolean).join("  ");
  }

  function onEvent(data, raw) {
    if (!feedEl) return;
    const empty = feedEl.querySelector("#sig-empty");
    if (empty) empty.remove();

    const verb = verbOf(data, raw);
    const row = document.createElement("div");
    row.className = "frow";
    const ts = new Date().toLocaleTimeString("en-GB", { hour12: false });
    const vparts = verb.split(".");
    const vhtml = vparts.length > 1
      ? `<span class="k">${vparts[0]}</span>.${vparts.slice(1).join(".")}`
      : verb;
    row.innerHTML = `<span class="ts">${ts}</span>`
      + `<span class="vb">${vhtml}</span>`
      + `<span class="sm">${escapeHtml(summaryOf(data))}</span>`;
    feedEl.insertBefore(row, feedEl.firstChild);

    // bounded: drop oldest beyond the cap — DOM-node displacement, no leak
    while (feedEl.children.length > CAP) feedEl.removeChild(feedEl.lastChild);
  }

  const escapeHtml = (s) => String(s || "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  window.CKKernels.push({ id: "signage", icon: "📡", title: "signage", mount, onEvent });
})();
