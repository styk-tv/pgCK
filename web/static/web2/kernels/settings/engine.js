/* web2 kernel · settings — the substrate ladder as toggles. The same governed
   state can materialise in any substrate; the wired ones (HTML, Konva) open
   live, the extra libraries (Anime/Three/Babylon) are MOCKED toggles until
   their runtime lands — flipping records the preference and is forward-ready.
   Toggles, not forms (per the workbench aesthetic). */
(function () {
  const LADDER = [
    { id: "html",    name: "Plain HTML",  note: "server-rendered · full IRIs",        status: "active",    real: true },
    { id: "htmljs",  name: "HTML + JS",   note: "this workbench — list & detail",      status: "active",    real: true,  href: "/assets/web2/" },
    { id: "konva",   name: "Konva.js",    note: "canvas · spatial kernel lanes",       status: "available", real: true,  href: "/assets/web3/" },
    { id: "anime",   name: "Anime.js",    note: "timeline animation substrate",        status: "mocked",    real: false },
    { id: "three",   name: "Three.js",    note: "3D swimlanes · 60 fps scene graph",   status: "mocked",    real: false },
    { id: "babylon", name: "Babylon.js",  note: "physics-enabled scene + bodies",      status: "mocked",    real: false },
  ];
  const KEY = "pgck.web2.substrates";
  let host = null;

  const prefs = () => { try { return JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) { return {}; } };
  const savePref = (id, on) => { const p = prefs(); p[id] = on; localStorage.setItem(KEY, JSON.stringify(p)); };

  function mount(h) { host = h; render(); }

  function render() {
    const p = prefs();
    host.innerHTML = `
      <div class="shead">
        <h2>settings</h2>
        <span class="sub">substrate ladder · render the same governed state in any substrate</span>
      </div>
      <div class="spad">
        <div class="setlist" id="setlist"></div>
        <div class="setnote">Extra substrate runtimes are <b>mocked toggles</b> until wired — flipping records
          the preference; the live ones (<b>HTML</b>, <b>Konva</b>) open. One <code>event.kernel.pgCK.&gt;</code>
          stream underneath them all.</div>
      </div>`;
    const L = host.querySelector("#setlist");
    for (const s of LADDER) {
      const on = s.real ? true : !!p[s.id];
      const row = document.createElement("div"); row.className = "setrow";
      const info = document.createElement("div"); info.className = "si";
      info.innerHTML = `<div class="sn">${s.name} <span class="sbadge ${s.status}">${s.status}</span></div><div class="sd">${s.note}</div>`;
      const tg = document.createElement("div");
      tg.className = "tg" + (on ? " on" : "") + (s.status === "active" ? " lock" : "");
      tg.title = s.status === "available" ? "open " + s.name : (s.real ? "current substrate" : "mock toggle");
      tg.onclick = () => {
        if (s.status === "available" && s.href) { window.open(s.href, "_blank"); return; }
        if (s.real) return;                                  // active base → locked on
        const nv = !tg.classList.contains("on"); tg.classList.toggle("on", nv); savePref(s.id, nv);
        toast(`${s.name} — mocked substrate ${nv ? "enabled" : "disabled"} (runtime not wired yet)`);
      };
      row.append(info, tg); L.appendChild(row);
    }
  }

  let toastEl = null;
  function toast(t) {
    if (!toastEl) { toastEl = document.createElement("div"); toastEl.className = "toast"; document.body.appendChild(toastEl); }
    toastEl.textContent = t; toastEl.classList.add("show");
    clearTimeout(toast._t); toast._t = setTimeout(() => toastEl.classList.remove("show"), 1900);
  }

  window.CKKernels.push({ id: "settings", icon: "⚙", title: "settings", mount });
})();
