/* web2 shell · surface — hosts the active kernel's render surface. On activate
   it mounts the kernel once (cached element) and shows it; live events fan into
   every kernel that declares onEvent (so signage keeps its feed warm offline of
   the surface). Mount is lazy and idempotent. */
(function () {
  const mounted = {};   // id -> { el }

  function kernelById(id) { return (window.CKKernels || []).find((k) => k.id === id); }

  function show(id) {
    const host = document.getElementById("surface");
    if (!host) return;
    const k = kernelById(id);
    if (!k) return;
    if (!mounted[id]) {
      const el = document.createElement("div");
      el.style.height = "100%";
      mounted[id] = { el };
      host.appendChild(el);
      if (k.mount) k.mount(el);
    }
    for (const mid of Object.keys(mounted)) mounted[mid].el.style.display = mid === id ? "" : "none";
    if (k.onActivate) k.onActivate();
  }

  // fan live events into every kernel that wants them (kept warm even when hidden)
  function fanEvent(data, raw) {
    for (const k of (window.CKKernels || [])) if (k.onEvent) k.onEvent(data, raw);
  }

  window.Bus.on("kernel.activate", (p) => show(p.id));

  window.Shell = Object.assign(window.Shell || {}, { showSurface: show, fanEvent });
})();
