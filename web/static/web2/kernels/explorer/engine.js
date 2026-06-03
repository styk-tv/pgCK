/* web2 kernel · explorer — governed instance browser on the native ckp.dispatch
   verbs (kernels.list · instances.list · provenance). Unlike the old explorer's
   Python-dispatcher composites (snapshot.board/kernel.detail), this rides only
   in-kernel governed verbs, so it lights up the moment inbound request/reply is
   answered natively in-kernel. Until then it surfaces the gap honestly. */
(function () {
  let hostEl = null;
  let loaded = false;

  function mount(host) {
    hostEl = host;
    host.innerHTML = `
      <div class="shead">
        <h2>explorer</h2>
        <span class="sub">governed kernels · ckp.dispatch kernels.list</span>
      </div>
      <div id="exp-body"><div class="klist" id="exp-list"></div></div>`;
  }

  async function onActivate() {
    if (loaded || !window.CKTransport || !window.CKTransport.connected()) return;
    await load();
  }

  async function load() {
    const list = hostEl && hostEl.querySelector("#exp-list");
    if (!list) return;
    list.innerHTML = `<div class="note">querying ckp.dispatch kernels.list…</div>`;
    try {
      const d = await window.CKTransport.call("kernels.list");
      if (!d || !d.ok) throw new Error((d && d.error) || "kernels.list returned not-ok");
      const kernels = d.kernels || [];
      window.Bus.emit("kernels.loaded", { kernels });
      loaded = true;
      renderKernels(list, kernels);
    } catch (e) {
      list.innerHTML =
        `<div class="note"><b>no inbound dispatcher answering.</b> The published all-in-one `
        + `relays <code>input.kernel.pgCK.action.&gt;</code> to events but does not yet answer `
        + `request/reply via <code>ckp.dispatch</code> over NATS. Signage works now; `
        + `explorer lights up once native inbound dispatch (or the dev dispatcher) responds.<br>`
        + `<small>${escapeHtml(e.message)}</small></div>`;
    }
  }

  function renderKernels(list, kernels) {
    list.innerHTML = "";
    if (!kernels.length) { list.innerHTML = `<div class="note">no kernels yet.</div>`; return; }
    for (const k of kernels) {
      const name = k.name || k.kernel || String(k);
      const cnt = k.count != null ? k.count : (k.instances != null ? k.instances : "");
      const row = document.createElement("div");
      row.className = "krow";
      row.innerHTML = `<div><div class="kn">${escapeHtml(name)}</div>`
        + `<div class="ku">ckp://Kernel#${slug(name)}</div></div>`
        + (cnt !== "" ? `<span class="kc">${cnt}</span>` : "");
      row.onclick = () => selectKernel(name);
      list.appendChild(row);
    }
  }

  async function selectKernel(name) {
    const list = hostEl.querySelector("#exp-list");
    [...list.querySelectorAll(".krow")].forEach((r) =>
      r.classList.toggle("sel", r.querySelector(".kn").textContent === name));
    try {
      const d = await window.CKTransport.call("instances.list", { kernel: name });
      window.Bus.emit("instances.loaded", { kernel: name, instances: (d && d.instances) || [] });
    } catch (e) { /* surfaced in feed/console; explorer detail pane is W2.1 */ }
  }

  const slug = (s) => (s || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "anon";
  const escapeHtml = (s) => String(s || "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  window.CKKernels.push({ id: "explorer", icon: "🔎", title: "explorer", mount, onActivate });
})();
