/* web2 spine · transport — CKClient over same-origin /wss, mirroring the verified
   pgCK web/static/shared/ck.js. Offline-first: web2 boots on the local spine;
   CKTransport.connect() flips it live. The endpoint is FIXED to same-origin /wss
   (this domain's gateway -> the all-in-one). There is deliberately NO way to
   re-point it (no ?wss=, no setEndpoint) so it can never talk to another DB. */
import { CKClient } from "/cklib/ck-client.js";

const endpoint = `${location.protocol === "http:" ? "ws" : "wss"}://${location.host}/wss`;

let ck = null;
const pending = new Map();
let seq = 0;
const statusFns = [];
const eventFns = [];

function build() {
  ck = new CKClient({
    kernel: "pgCK",
    wssEndpoint: endpoint,
    subscribe: ["event", "result"],
    dictVersion: 0,
    clientId: "ck-web2",
  });
  ck.on("result", (m) => { const d = m.data || {}; const p = pending.get(d.req); if (p) { pending.delete(d.req); p(d); } });
  ck.on("event", (m) => eventFns.forEach((f) => f(m.data || {}, m)));
  ck.on("status", ({ connection }) => statusFns.forEach((f) => f(connection)));
}

window.CKTransport = {
  get endpoint() { return endpoint; },     // read-only; fixed to same-origin /wss
  onStatus: (f) => statusFns.push(f),
  onEvent: (f) => eventFns.push(f),
  connected: () => !!ck,
  async connect() { if (!ck) build(); await ck.connect(); return true; },
  call(action, extra = {}) {
    return new Promise((res, rej) => {
      if (!ck) return rej(new Error("not connected"));
      const req = `w2-${Date.now()}-${++seq}`;
      const to = setTimeout(() => { pending.delete(req); rej(new Error("kernel timeout — no inbound dispatcher answering (native ckp.dispatch request/reply over NATS)")); }, 9000);
      pending.set(req, (d) => { clearTimeout(to); res(d); });
      ck.send({ action, req, ...extra });
    });
  },
};
// announce readiness so the classic boot code can wire the shell + kernels
window.dispatchEvent(new Event("cktransport-ready"));
