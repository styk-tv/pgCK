/* web2 spine · bus — the event-sourced state tree (ported from asciinator).
   Every UI action emits a typed event; a reducer mutates the single state tree;
   render subscribers + experience listeners react. Nothing mutates state outside
   a reducer. The `log` is bounded and the tree is rebuildable from it. */
(function () {
  const state = {
    pinned: [],                 // [{id, icon, title}]  — kernels pinned in the rail
    active: null,               // active kernel id
    kernels: [],                // governed kernels (kernels.list)
    instances: {},              // kernelId -> [instance]
    selected: {},               // kernelId -> instance id
    events: [],                 // bounded live event feed (signage)
    transport: { connection: "offline", identity: "anon", url: "" },
    log: [],                    // last N events (event-sourced trace)
  };

  const reducers = {};          // type -> fn(state, payload, evt)
  const listeners = {};         // type -> [fn]  (experiences / side effects)
  const renderSubs = [];        // [fn(state, evt)]

  function reduce(type, fn) { reducers[type] = fn; }
  function on(type, fn) { (listeners[type] || (listeners[type] = [])).push(fn); }
  function subscribe(fn) { renderSubs.push(fn); }

  function emit(type, payload) {
    const evt = Object.assign({ type }, payload || {});
    const r = reducers[type];
    if (r) r(state, payload || {}, evt);
    state.log.push({ type, payload }); if (state.log.length > 200) state.log.shift();
    (listeners[type] || []).forEach((f) => f(payload || {}, evt));
    (listeners["*"] || []).forEach((f) => f(payload || {}, evt));
    for (const f of renderSubs) f(state, evt);
  }

  // ---- helpers on the tree ----
  const cur = () => state.active;
  const curInsts = () => state.instances[cur()] || [];
  const curSel = () => state.selected[cur()];

  window.Bus = { state, reduce, on, subscribe, emit, cur, curInsts, curSel };
})();
