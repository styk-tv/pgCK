/* web2 spine · props — ontology-driven property generator. Given a shape
   descriptor (the kernel's inShape) + an instance, build controls grouped by
   sh:group / sh:order. Every control emits a typed `param.set` event — it never
   writes the instance directly. Ported from asciinator, decoupled from any
   engine-specific preview (color-scheme is rendered from p.preview if provided). */
(function () {
  const E = (t, c) => { const e = document.createElement(t); if (c) e.className = c; return e; };

  function render(container, shape, inst, onImageDrop) {
    container.innerHTML = "";
    if (!inst) {
      const h = E("div"); h.style.cssText = "color:var(--mut);padding:24px 8px;text-align:center;font-size:11px";
      h.textContent = "no instance — create one to edit its properties";
      container.appendChild(h); return;
    }
    const groups = []; const byG = {};
    shape.props.forEach((p) => { if (!byG[p.group]) { byG[p.group] = []; groups.push(p.group); } byG[p.group].push(p); });
    for (const g of groups) {
      const gh = E("div", "pgroup");
      const hd = E("div", "pgroup-h"); hd.textContent = g; gh.appendChild(hd);
      byG[g].sort((a, b) => a.order - b.order).forEach((p) => gh.appendChild(row(shape, p, inst, onImageDrop)));
      container.appendChild(gh);
    }
  }

  function row(shape, p, inst, onImageDrop) {
    const key = shape.key(p);
    const r = E("div", "prow");
    const lbl = E("div", "lbl"); lbl.textContent = p.label; lbl.title = p.path; r.appendChild(lbl);
    const set = (v) => window.Bus.emit("param.set", { kernel: shape.kernel, id: window.Bus.curSel(), key, value: v });

    if (p.widget === "slider") {
      const inp = E("input"); inp.type = "range"; inp.min = p.min; inp.max = p.max; inp.step = p.step; inp.value = inst[key];
      const val = E("div", "val");
      const fmt = (v) => p.fmt ? p.fmt(v) : (~~v + (p.unit || ""));
      val.textContent = fmt(+inst[key]);
      inp.addEventListener("input", (e) => { val.textContent = fmt(+e.target.value); set(p.datatype === "integer" ? Math.round(+e.target.value) : +e.target.value); });
      r.appendChild(inp); r.appendChild(val); r._reflect = (v) => { inp.value = v; val.textContent = fmt(+v); };

    } else if (p.widget === "toggle") {
      const tg = E("div", "tg" + (inst[key] ? " on" : ""));
      tg.addEventListener("click", () => { const nv = !tg.classList.contains("on"); tg.classList.toggle("on", nv); set(nv); });
      r.appendChild(tg); r._reflect = (v) => tg.classList.toggle("on", !!v);

    } else if (p.widget === "segmented") {
      const seg = E("div", "seg");
      p.options.forEach((opt, i) => {
        const b = E("button"); b.textContent = opt; if (i === (+inst[key] | 0)) b.classList.add("on");
        b.addEventListener("click", () => { seg.querySelectorAll("button").forEach((x) => x.classList.remove("on")); b.classList.add("on"); set(i); });
        seg.appendChild(b);
      });
      r.appendChild(seg); r._reflect = (v) => seg.querySelectorAll("button").forEach((b, i) => b.classList.toggle("on", i === (+v | 0)));

    } else if (p.widget === "text") {
      const inp = E("input", "txt"); inp.value = inst[key] || ""; inp.placeholder = p.placeholder || "";
      inp.addEventListener("input", (e) => set(e.target.value));
      r.appendChild(inp); r._reflect = (v) => { if (document.activeElement !== inp) inp.value = v || ""; };
    }
    r.dataset.key = key;
    return r;
  }

  window.Props = { render };
})();
