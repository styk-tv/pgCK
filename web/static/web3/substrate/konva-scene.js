/* web3 substrate · Konva canvas — the next rung up the materialisation ladder.
   Renders the SAME governed kernel state as web2, but spatially: a Goal anchor,
   one landing-pad lane per kernel, Task cards that materialise live from the
   event stream. Event-sourced: each event.kernel.pgCK.<verb> upserts a node — no
   request/reply needed (a substrate is fundamentally an event-stream renderer).
   ckp:Substrate.KonvaJS — the next rung in the substrate-materialisation registry. */
(function () {
  const N = "https://conceptkernel.org/ontology/v3.7/";
  const COLORS = {
    planned:     { fill: "#f4f6fa", stroke: "#d7deea", ink: "#5a6a82" },
    in_progress: { fill: "#eaf2ff", stroke: "#bcd6ff", ink: "#2f6fe0" },
    done:        { fill: "#e8f8f1", stroke: "#bce8d4", ink: "#149b6a" },
    blocked:     { fill: "#fdeef0", stroke: "#f6c9cf", ink: "#d2455a" },
  };
  const LANE_W = 210, LANE_GAP = 18, LANE_X0 = 300, LANE_Y0 = 96;
  const CARD_H = 52, CARD_GAP = 10, GOAL_X = 30, GOAL_Y = 150;

  let stage, edges, lanesLayer, cardsLayer;
  const lanes = {};   // kernel -> { idx, x, header, pad, count }
  const tasks = {};   // id -> { group, kernel }
  let laneCount = 0;

  function mount(host) {
    host.innerHTML = `<div id="kstage" style="position:absolute;inset:0"></div>`;
    const box = host.querySelector("#kstage");
    stage = new Konva.Stage({ container: box, width: box.clientWidth || 1200, height: box.clientHeight || 700 });
    edges = new Konva.Layer();
    lanesLayer = new Konva.Layer();
    cardsLayer = new Konva.Layer();
    stage.add(edges); stage.add(lanesLayer); stage.add(cardsLayer);
    drawGoal();
    window.addEventListener("resize", fit);
    fit();
  }

  function fit() {
    if (!stage) return;
    const box = stage.container();
    stage.width(box.clientWidth || 1200);
    stage.height(box.clientHeight || 700);
    stage.batchDraw();
  }

  function drawGoal() {
    const g = new Konva.Group({ x: GOAL_X, y: GOAL_Y });
    g.add(new Konva.Rect({ width: 240, height: 96, cornerRadius: 16, fill: "#1b2533",
      shadowColor: "#1b2533", shadowBlur: 18, shadowOpacity: 0.18, shadowOffsetY: 4 }));
    g.add(new Konva.Text({ x: 18, y: 20, text: "DEV GOAL", fontSize: 11, fontStyle: "bold",
      fill: "#7e8ba3", fontFamily: "system-ui", letterSpacing: 1 }));
    g.add(new Konva.Text({ x: 18, y: 40, width: 204, text: "pgCK self-hosted board — every kernel materialised live",
      fontSize: 13, fill: "#eef2f8", fontFamily: "system-ui", lineHeight: 1.35 }));
    lanesLayer.add(g);
    lanesLayer.draw();
  }

  function ensureLane(kernel) {
    if (lanes[kernel]) return lanes[kernel];
    const idx = laneCount++;
    const x = LANE_X0 + idx * (LANE_W + LANE_GAP);
    const header = new Konva.Group({ x, y: 40 });
    header.add(new Konva.Rect({ width: LANE_W, height: 34, cornerRadius: 9, fill: "#fff", stroke: "#e7ebf1" }));
    header.add(new Konva.Text({ x: 12, y: 10, width: LANE_W - 24, text: kernel, fontSize: 13,
      fontStyle: "bold", fill: "#1b2533", fontFamily: "system-ui", ellipsis: true, wrap: "none" }));
    lanesLayer.add(header);
    // edge Goal -> lane header
    const line = new Konva.Line({
      points: [GOAL_X + 240, GOAL_Y + 48, x, 57],
      stroke: "#cfd8e6", strokeWidth: 1.5, bezier: true, tension: 0,
    });
    edges.add(line);
    edges.draw(); lanesLayer.draw();
    return (lanes[kernel] = { idx, x, header, count: 0 });
  }

  function stateOf(body, flat) {
    return (flat && flat.lifecycle_state) || body[N + "lifecycle_state"] || "planned";
  }

  function extract(data) {
    const flat = data.task || data.instance || {};
    // the event payload is a flat IRI-keyed object — fall back to `data` itself,
    // not the empty `flat`, so the ontology-prefixed fields resolve.
    const body = data.body || flat.body || data || {};
    const id = String(
      data.id || flat.id || body[N + "task_id"] || body[N + "id"] ||
      ("t" + Object.keys(tasks).length));
    const title = flat.title || body[N + "title"] || data.title || "(untitled task)";
    const kernel = flat.target_kernel || body[N + "target_kernel"] || data.kernel || data.target_kernel || "unsorted";
    const state = String(stateOf(body, flat)).toLowerCase();
    return { id, title, kernel, state };
  }

  function upsert(t) {
    const lane = ensureLane(t.kernel);
    const c = COLORS[t.state] || COLORS.planned;
    let node = tasks[t.id];

    if (!node) {
      const y = LANE_Y0 + lane.count * (CARD_H + CARD_GAP);
      lane.count++;
      const group = new Konva.Group({ x: lane.x, y, draggable: true, opacity: 0, scaleX: 0.85, scaleY: 0.85 });
      const rect = new Konva.Rect({ width: LANE_W, height: CARD_H, cornerRadius: 11, fill: c.fill, stroke: c.stroke,
        shadowColor: "#142036", shadowBlur: 9, shadowOpacity: 0.06, shadowOffsetY: 1, name: "rect" });
      const txt = new Konva.Text({ x: 12, y: 9, width: LANE_W - 24, height: CARD_H - 14, text: t.title,
        fontSize: 12, fill: c.ink, fontFamily: "system-ui", lineHeight: 1.3, ellipsis: true, name: "txt" });
      group.add(rect); group.add(txt);
      cardsLayer.add(group);
      group.to({ opacity: 1, scaleX: 1, scaleY: 1, duration: 0.28, easing: Konva.Easings.BackEaseOut });
      group.on("dragstart", () => group.moveToTop());
      tasks[t.id] = node = { group, kernel: t.kernel };
      window.Bus && window.Bus.emit("web3.materialised", { id: t.id, kernel: t.kernel });
    } else {
      // update state colour in place + pulse
      const rect = node.group.findOne(".rect");
      const txt = node.group.findOne(".txt");
      if (rect) { rect.fill(c.fill); rect.stroke(c.stroke); }
      if (txt) { txt.fill(c.ink); txt.text(t.title); }
      node.group.to({ scaleX: 1.05, scaleY: 1.05, duration: 0.12,
        onFinish: () => node.group.to({ scaleX: 1, scaleY: 1, duration: 0.12 }) });
    }
    cardsLayer.batchDraw();
  }

  function onEvent(data) {
    const t = extract(data);
    if (!t.kernel) return;
    upsert(t);
  }

  window.CKKernels = window.CKKernels || [];
  window.CKKernels.push({ id: "konva", icon: "▢", title: "konva", mount, onEvent });
  // also expose for the standalone web3 boot
  window.Web3Substrate = { mount, onEvent, stats: () => ({ lanes: Object.keys(lanes).length, tasks: Object.keys(tasks).length }) };
})();
