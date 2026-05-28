/**
 * pgCK Display — NATS-only broadcast client using nats.ws (aligned with CK.Lib.Js patterns)
 *
 * Receives: theme, audio, message, task_upsert, board_snapshot from broadcast.demo.display
 * Emits: status updates to same subject (anonymous identity)
 *
 * Pure NATS protocol — no REST API dependencies
 */

// Import nats.ws (same as CK.Lib.Js does)
import { connect, JSONCodec } from "https://esm.sh/nats.ws@1.30.3";

const config = window.PGCK_DISPLAY_CONFIG;
const jc = JSONCodec();

const state = {
  nc: null,
  connected: false,
  audioEnabled: false,
  lastPayload: null,
};

const refs = {};

// DOM references
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
  connectNATS();
});

async function connectNATS() {
  try {
    setConnectionStatus("Connecting to NATS…", "warn");

    const nc = await connect({
      servers: config.nats_ws_url,
      maxReconnectAttempts: 10,
      reconnectTimeWait: 1000,
    });

    state.nc = nc;
    setConnectionStatus("Connected. Subscribing…", "warn");

    // Subscribe to broadcast subject
    const sub = nc.subscribe(config.nats_subject);
    state.connected = true;
    setConnectionStatus("Ready. Listening for broadcasts.", "ok");

    // Message loop
    (async () => {
      for await (const msg of sub) {
        try {
          const data = jc.decode(msg.data);
          state.lastPayload = data;
          refs.lastPayload.textContent = JSON.stringify(data, null, 2);

          // Dispatch based on kind
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
              console.warn("Unknown message kind:", data.kind);
          }
        } catch (err) {
          console.error("Error processing message:", err);
        }
      }
    })();

    // Watch connection state
    (async () => {
      for await (const status of nc.status()) {
        if (status.type === "disconnect") {
          setConnectionStatus("Disconnected. Reconnecting…", "error");
          state.connected = false;
        } else if (status.type === "reconnect") {
          setConnectionStatus("Reconnected.", "ok");
          state.connected = true;
        }
      }
    })();
  } catch (err) {
    setConnectionStatus(`Failed: ${err.message}`, "error");
    console.error("NATS connection error:", err);
    setTimeout(connectNATS, 3000);
  }
}

function applyTheme(theme) {
  if (!theme) return;
  const root = document.documentElement;
  root.style.setProperty("--color-bg", theme.background || "#07111f");
  root.style.setProperty("--color-fg", theme.foreground || "#f7fbff");
  root.style.setProperty("--color-accent", theme.accent || "#47d7ac");
  root.style.setProperty("--color-panel", theme.panel || "#10263f");
}

function playAudio(audio) {
  if (!state.audioEnabled || !audio) return;
  const player = refs.audioPlayer;
  player.src = audio.src;
  player.volume = audio.volume || 0.85;
  player.loop = audio.loop || false;
  player.play().catch((err) => console.error("Audio play failed:", err));
  refs.audioStatus.textContent = audio.title || "Playing…";
}

function displayMessage(msg) {
  if (!msg) return;
  console.log("Message:", msg);
  // Could render to a message log, toast, etc.
}

function handleTaskUpdate(data) {
  console.log("Task update received:", data);
  // Display task update notification
}

function handleBoardSnapshot(data) {
  console.log("Board snapshot received:", data);
  // Could update a live board view if needed
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
    const response = await fetch("/protocol");
    const payload = await response.json();
    refs.protocolOutput.textContent = payload.commands
      .map((command) => {
        return [
          `${command.kind.toUpperCase()}: ${command.description}`,
          command.publish_example,
          JSON.stringify(command.payload, null, 2),
        ].join("\n");
      })
      .join("\n\n");
  } catch (error) {
    refs.protocolOutput.textContent = `Failed to load protocol: ${error.message}`;
  }
}
