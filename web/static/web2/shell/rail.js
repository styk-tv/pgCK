/* web2 shell · rail — pinned-kernel switcher. Kernels self-register into
   window.CKKernels; the rail pins them and setActive() switches the surface.
   One event stream underneath; renderers are swappable experiences. */
(function () {
  window.CKKernels = window.CKKernels || [];

  // reducer: which kernel is active
  window.Bus.reduce("kernel.activate", (s, p) => { s.active = p.id; });

  function render() {
    const rail = document.getElementById("rail");
    if (!rail) return;
    rail.innerHTML = "";
    for (const k of window.CKKernels) {
      const b = document.createElement("div");
      b.className = "rk" + (window.Bus.state.active === k.id ? " on" : "");
      b.innerHTML = `<span class="material-symbols-outlined ic">${k.icon}</span><span>${k.title}</span>`;
      b.title = k.title;
      b.onclick = () => setActive(k.id);
      rail.appendChild(b);
    }
  }

  function setActive(id) {
    if (window.Bus.state.active === id) return;
    window.Bus.emit("kernel.activate", { id });
  }

  // re-paint the rail selection on any activate
  window.Bus.on("kernel.activate", render);

  window.Shell = Object.assign(window.Shell || {}, { renderRail: render, setActive });
})();
