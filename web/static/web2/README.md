# pgCK web2 — unified modular kernel workbench

A single-page, **no-build** browser app that renders pgCK's governed state over
NATS/WSS. Every tool is a **kernel module** on one event-sourced spine, in the
asciinator pattern: one stream, swappable render surfaces, light/minimal theme.

This is the app `web/` (the FastAPI slice) retires into — board, explorer, and
signage unified, running from pgCK over NATS.

## Layout

```
web2/
  index.html              assembles shell + ordered includes; offline-first boot
  spine/
    bus.js                event-sourced state tree (reduce/on/subscribe/emit)
    ingest.js             event.kernel.pgCK.>  ->  state.kernels + state.instances
    transport.js          CKClient over same-origin /wss (fixed; not re-pointable)
    props.js              SHACL shape -> property form
  shell/
    rail.js               pinned-kernel switcher
    surface.js            active-kernel surface host + event fan-out
    app.css               light theme (board aesthetic; no dark mode)
  kernels/                each self-registers into window.CKKernels
    explorer/             split list + governed instance detail (default surface)
    board/                training-tasks explorer — columns per kernel
    signage/              live event monitor (bounded rolling feed)
    settings/             substrate ladder as toggles (HTML/Konva live; rest mocked)
  vendor/                 (none yet; cklib is served at /cklib by the bundle)
```

## Runtime contract

- **Served** as static files at `/assets/web2/` (busybox httpd in the all-in-one).
- **Depends on** `/cklib/ck-client.js` (CK.Lib.Js, already in the bundle) and a
  same-origin `/wss` WebSocket bridge to the kernel's NATS.
- **Reads** are event-sourced from `event.kernel.pgCK.>` — work with only the
  outbound event stream. **Writes** (seal/cycle/upgrade) use `ckp.dispatch`
  request/reply over NATS and activate when inbound dispatch answers.
- **No Python, no build step.** Pure static assets.

## Substrate ladder

web2 is the HTML+JS rung. The same governed state materialises in richer
substrates (e.g. the Konva canvas at `/assets/web3/`); settings lists the ladder,
with un-wired runtimes shown as mocked toggles.
