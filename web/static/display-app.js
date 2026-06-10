/**
 * pgCK Display — NATS-only broadcast client backed by CK.Lib.Js CKClient.
 *
 * Subscribes to event.<display_kernel> via CKClient and renders broadcast
 * messages (theme, audio, message, task_upsert, board_snapshot). All transport
 * lives inside CKClient; this module is pure UI orchestration.
 *
 * Forward-compatible with CK.Lib.Js v1.3 (binary codec) — when CKClient swaps
 * its codec the dispatch surface here (kind/payload) stays unchanged.
 */

import { CKClient } from "/cklib/ck-client.js";

const config = window.PGCK_DISPLAY_CONFIG;

const state = {
  ck: null,
  audioEnabled: false,
};

const refs = {};

window.addEventListener("DOMContentLoaded", () => {
  refs.connectionDot = document.getElementById("connection-dot");
  refs.connectionStatus = document.getElementById("connection-status");
  refs.natsUrl = document.getElementById("nats-url");
  refs.natsSubject = document.getElementById("nats-subject");
  refs.audioUnlock = document.getElementById("audio-unlock");
  refs.audioStatus = document.getElementById("audio-status");
  refs.audioPlayer = document.getElementById("audio-player");
  refs.protocolOutput = document.getElementById("protocol-output");
  refs.lastPayload = document.getElementById("last-payload");

  refs.natsUrl.textContent = config.nats_ws_url;
  refs.natsSubject.textContent = config.nats_subject;
  refs.audioUnlock.addEventListener("click", enableAudio);

  loadProtocol();
  startCKClient();
});

async function startCKClient() {
  setConnectionStatus("Connecting to NATS via CKClient…", "warn");

  // v1.3 alignment (CKA-8 / CKD-4):
  //  - subscribe: ['event']      → opt out of the dead result.<Kernel> sub
  //  - dictVersion: 0            → bootstrap Ck-Dict-V handshake (server snapshot if behind)
  //  - clientId: 'ck-browser'    → v1.3 default; pinned here so the realm is unambiguous
  const ck = new CKClient({
    kernel: config.display_kernel,
    wssEndpoint: config.nats_ws_url,
    subscribe: ["event"],
    // also monitor the whole governed pgCK event flow (CSVC: extraSubjects -> 'broadcast')
    extraSubjects: ["event.kernel.pgCK.>"],
    dictVersion: 0,
    clientId: "ck-browser",
    maxReconnectAttempts: 10,
    reconnectDelay: 1000,
  });

  state.ck = ck;

  ck.on("status", ({ connection, error }) => {
    if (connection === "connecting") {
      setConnectionStatus("Connecting…", "warn");
    } else if (connection === "connected") {
      setConnectionStatus(`Subscribed to ${config.nats_subject}`, "ok");
    } else if (connection === "disconnected") {
      setConnectionStatus("Disconnected. Reconnecting…", "error");
    } else if (connection === "error") {
      setConnectionStatus(`Error: ${error?.message || "unknown"}`, "error");
    }
  });

  ck.on("event", (msg) => { logEvent(msg); dispatchBroadcast(msg.data); });
  ck.on("broadcast", (msg) => { logEvent(msg); dispatchBroadcast(msg.data); });
  ck.on("error", (err) => console.error("[display] CKClient error:", err));

  try {
    await ck.connect();
  } catch (err) {
    setConnectionStatus(`Connect failed: ${err.message}`, "error");
    console.error("[display] CKClient connect failed:", err);
    setTimeout(startCKClient, 3000);
  }
}

// Rolling, bounded live event feed. Fixed-size displacement (oldest DOM node
// removed once over FEED_MAX) so a constant flow never grows memory.
const FEED_MAX = 60;
function logEvent(msg) {
  const feed = document.getElementById("event-feed");
  if (!feed) return;
  const d = msg && msg.data;
  let summary = "";
  if (d && typeof d === "object") summary = d.kind || d.id || d.title || Object.keys(d).slice(0, 4).join(", ");
  else if (d != null) summary = String(d);
  const subj = (msg.subject || "").replace(/^event\.(kernel\.)?/, "").replace(/^pgCK\./, "");
  const line = document.createElement("div");
  line.className = "evt";
  const t = document.createElement("span"); t.className = "t"; t.textContent = new Date().toLocaleTimeString();
  const s = document.createElement("span"); s.className = "s"; s.textContent = subj || "event";
  const dd = document.createElement("span"); dd.className = "d"; dd.textContent = summary;
  line.append(t, s, dd);
  feed.prepend(line);
  while (feed.childElementCount > FEED_MAX) feed.removeChild(feed.lastElementChild);
}

function dispatchBroadcast(data) {
  if (!data || typeof data !== "object") return;
  refs.lastPayload.textContent = JSON.stringify(data, null, 2);

  switch (data.kind) {
    case "theme":
      applyTheme(data.theme);
      break;
    case "audio":
      playAudio(data.audio);
      break;
    case "message":
      displayMessage(data.message);
      break;
    case "task_upsert":
      handleTaskUpdate(data);
      break;
    case "board_snapshot":
      handleBoardSnapshot(data);
      break;
    default:
      console.warn("[display] unknown broadcast kind:", data.kind);
  }
}

function applyTheme(theme) {
  if (!theme) return;
  const root = document.documentElement;
  if (theme.background) root.style.setProperty("--bg", theme.background);
  if (theme.foreground) root.style.setProperty("--fg", theme.foreground);
  if (theme.accent) root.style.setProperty("--accent", theme.accent);
  if (theme.panel) root.style.setProperty("--panel", theme.panel);
}

function playAudio(audio) {
  if (!state.audioEnabled || !audio) return;
  const player = refs.audioPlayer;
  player.src = audio.src;
  player.volume = audio.volume || 0.85;
  player.loop = audio.loop || false;
  player.play().catch((err) => console.error("[display] audio play failed:", err));
  refs.audioStatus.textContent = audio.title || "Playing…";
}

function displayMessage(msg) {
  if (!msg) return;
  console.log("[display] message:", msg);
}

function handleTaskUpdate(data) {
  console.log("[display] task update:", data);
}

function handleBoardSnapshot(data) {
  console.log("[display] board snapshot:", data);
}

function enableAudio() {
  state.audioEnabled = true;
  refs.audioUnlock.textContent = "Audio enabled";
  refs.audioUnlock.disabled = true;
  refs.audioStatus.textContent = "Armed";
}

function setConnectionStatus(status, level) {
  refs.connectionStatus.textContent = status;
  refs.connectionStatus.className = `connection-status status-${level}`;
  refs.connectionDot.className = `status-dot dot-${level}`;
}

async function loadProtocol() {
  try {
    const response = await fetch("/assets/protocol.json");
    const payload = await response.json();
    refs.protocolOutput.textContent = payload.commands
      .map((command) => [
        `${command.kind.toUpperCase()}: ${command.description}`,
        command.publish_example,
        JSON.stringify(command.payload, null, 2),
      ].join("\n"))
      .join("\n\n");
  } catch (error) {
    refs.protocolOutput.textContent = `Failed to load protocol: ${error.message}`;
  }
}
