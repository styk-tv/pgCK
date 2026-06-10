// Shared CK bridge — one CKClient over NATS WSS, exposed as window.CK so
// non-module UI frameworks (Alpine, etc.) can call the kernel. No build, no npm.
import { CKClient } from "/cklib/ck-client.js";

const ck = new CKClient({
  kernel: "pgCK",
  wssEndpoint: `${location.protocol === "http:" ? "ws" : "wss"}://${location.host}/wss`,
  subscribe: ["event", "result"],
  dictVersion: 0,
  clientId: "ck-browser",
});

const pending = new Map();
let seq = 0;
const statusFns = [];
const eventFns = [];

ck.on("result", (m) => {
  const d = m.data || {};
  const p = pending.get(d.req);
  if (p) { pending.delete(d.req); p(d); }
});
ck.on("status", ({ connection }) => statusFns.forEach((f) => f(connection)));
ck.on("event", (m) => eventFns.forEach((f) => f(m.data || {})));

window.CK = {
  connect: () => ck.connect().catch((e) => console.error("[CK] connect", e)),
  onStatus: (f) => statusFns.push(f),
  onEvent: (f) => eventFns.push(f),
  call: (action, extra = {}) =>
    new Promise((res, rej) => {
      const req = `f-${Date.now()}-${++seq}`;
      const to = setTimeout(() => { pending.delete(req); rej(new Error("Server temporarily unavailable — kernel dispatcher not responding (run VS Code task: pgck: dev dispatcher).")); }, 9000);
      pending.set(req, (d) => { clearTimeout(to); res(d); });
      ck.send({ action, req, ...extra });
    }),
};
// the consuming app owns a single connect() (see forge init)
