const config = window.PGCK_DISPLAY_CONFIG;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const state = {
  socket: null,
  sid: 1,
  reconnectTimer: null,
  subscriptionSent: false,
  buffer: new Uint8Array(0),
  pendingMessage: null,
  pendingAudio: null,
  audioEnabled: false,
  board: { kernels: [], tasks: [] },
  goals: [],
  kernels: [],
  visibleKernelIds: new Set(),
  highlightTaskId: null,
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
  refs.goalSelect = document.getElementById("goal-select");
  refs.kernelSelect = document.getElementById("kernel-select");
  refs.titleInput = document.getElementById("title-input");
  refs.detailInput = document.getElementById("detail-input");
  refs.priorityInput = document.getElementById("priority-input");
  refs.taskForm = document.getElementById("task-form");
  refs.formStatus = document.getElementById("form-status");
  refs.kernelToggles = document.getElementById("kernel-toggles");
  refs.boardColumns = document.getElementById("board-columns");
  refs.slideText = document.getElementById("slide-text");
  refs.slideCaption = document.getElementById("slide-caption");

  refs.natsUrl.textContent = config.nats_ws_url;
  refs.natsSubject.textContent = config.nats_subject;

  refs.audioUnlock.addEventListener("click", enableAudio);
  refs.taskForm.addEventListener("submit", submitTask);

  loadProtocol();
  loadBoardData().finally(() => connect());
});

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

async function loadBoardData() {
  try {
    const [boardResponse, goalsResponse, kernelsResponse] = await Promise.all([
      fetch("/api/board"),
      fetch("/api/goals"),
      fetch("/api/kernels"),
    ]);

    if (!boardResponse.ok || !goalsResponse.ok || !kernelsResponse.ok) {
      throw new Error("board bootstrap request failed");
    }

    const boardPayload = await boardResponse.json();
    const goals = await goalsResponse.json();
    const kernels = await kernelsResponse.json();

    state.board = normalizeBoard(boardPayload.board || { kernels: [], tasks: [] });
    state.goals = goals;
    state.kernels = normalizeKernels(kernels.length ? kernels : state.board.kernels);

    if (state.visibleKernelIds.size === 0) {
      state.kernels
        .filter((kernel) => kernel.visible !== false)
        .forEach((kernel) => state.visibleKernelIds.add(kernel.kernel_id));
    }

    hydrateComposer();
    renderKernelToggles();
    renderBoard();
    setFormStatus("Board snapshot loaded.");
  } catch (error) {
    setFormStatus(`Failed to load board data: ${error.message}`, "error");
  }
}

function hydrateComposer() {
  refs.goalSelect.innerHTML = "";
  refs.kernelSelect.innerHTML = "";

  state.goals.forEach((goal) => {
    refs.goalSelect.appendChild(buildOption(goal.goal_id, `${goal.goal_id} · ${goal.title}`));
  });

  state.kernels.forEach((kernel) => {
    refs.kernelSelect.appendChild(buildOption(kernel.kernel_id, `${kernel.kernel_id} · ${kernel.title}`));
  });
}

function buildOption(value, label) {
  const option = document.createElement("option");
  option.value = value;
  option.textContent = label;
  return option;
}

function normalizeKernels(kernels) {
  return kernels.map((kernel) => ({
    kernel_id: kernel.kernel_id,
    title: kernel.title || kernel.kernel_id,
    icon: kernel.icon || "grid_view",
    color: kernel.color || "#38bdf8",
    launch_url: kernel.launch_url || "",
    visible: kernel.visible !== false,
  }));
}

function normalizeBoard(board) {
  return {
    kernels: normalizeKernels(board.kernels || []),
    tasks: (board.tasks || []).map(normalizeTask),
  };
}

function normalizeTask(task) {
  return {
    task_id: task.task_id,
    title: task.title || "Untitled task",
    part_of_goal: task.part_of_goal || "",
    target_kernel: task.target_kernel || "",
    lifecycle_state: task.lifecycle_state || "pending",
    priority: Number(task.priority ?? 0),
    queue_seq: Number(task.queue_seq ?? 0),
    created_at: task.created_at || "",
    shape_valid: Boolean(task.shape_valid),
    sealed: Boolean(task.sealed),
    verified: Boolean(task.verified),
    proof_digest: task.proof_digest || "",
    detail: task.detail || "",
    created_by: task.created_by || "",
  };
}

function renderKernelToggles() {
  refs.kernelToggles.innerHTML = "";

  state.kernels.forEach((kernel) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "kernel-toggle";
    if (state.visibleKernelIds.has(kernel.kernel_id)) {
      button.classList.add("active");
    }
    button.textContent = kernel.title;
    button.style.setProperty("--kernel-accent", kernel.color);
    button.addEventListener("click", () => {
      if (state.visibleKernelIds.has(kernel.kernel_id)) {
        state.visibleKernelIds.delete(kernel.kernel_id);
      } else {
        state.visibleKernelIds.add(kernel.kernel_id);
      }
      renderKernelToggles();
      renderBoard();
    });
    refs.kernelToggles.appendChild(button);
  });
}

function renderBoard() {
  refs.boardColumns.innerHTML = "";

  const visibleKernels = state.kernels.filter((kernel) => state.visibleKernelIds.has(kernel.kernel_id));
  if (visibleKernels.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty-board";
    empty.textContent = "No visible kernel columns.";
    refs.boardColumns.appendChild(empty);
    return;
  }

  visibleKernels.forEach((kernel) => {
    refs.boardColumns.appendChild(renderKernelColumn(kernel));
  });

  if (refs.slideText) {
    refs.slideText.textContent = `${state.board.tasks.length} task${state.board.tasks.length === 1 ? "" : "s"} live`;
  }
  if (refs.slideCaption) {
    refs.slideCaption.textContent = "Board snapshot and task upsert events arrive on the shared subject.";
  }

  if (state.highlightTaskId) {
    const card = refs.boardColumns.querySelector(`[data-task-id="${cssEscape(state.highlightTaskId)}"]`);
    if (card) {
      card.classList.add("fresh");
      window.setTimeout(() => card.classList.remove("fresh"), 1400);
    }
    state.highlightTaskId = null;
  }
}

function renderKernelColumn(kernel) {
  const column = document.createElement("section");
  column.className = "board-column";
  column.style.setProperty("--kernel-accent", kernel.color);

  const header = document.createElement("header");
  header.className = "column-header";

  const titleWrap = document.createElement("div");

  const title = document.createElement("h2");
  title.textContent = kernel.title;
  titleWrap.appendChild(title);

  const subtitle = document.createElement("p");
  subtitle.className = "column-subtitle";
  subtitle.textContent = kernel.kernel_id;
  titleWrap.appendChild(subtitle);

  header.appendChild(titleWrap);

  if (kernel.launch_url) {
    const link = document.createElement("a");
    link.className = "launch-link";
    link.href = kernel.launch_url;
    link.target = "_blank";
    link.rel = "noreferrer";
    link.textContent = "Launch";
    header.appendChild(link);
  }

  const list = document.createElement("div");
  list.className = "task-list";

  const tasks = state.board.tasks
    .filter((task) => task.target_kernel === kernel.kernel_id)
    .sort(sortTasks);

  if (tasks.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty-column";
    empty.textContent = "Queue is empty.";
    list.appendChild(empty);
  } else {
    tasks.forEach((task) => list.appendChild(renderTaskCard(task)));
  }

  column.appendChild(header);
  column.appendChild(list);
  return column;
}

function renderTaskCard(task) {
  const card = document.createElement("article");
  card.className = "task-card";
  card.dataset.taskId = task.task_id;

  const title = document.createElement("h3");
  title.className = "task-title";
  title.textContent = task.title;
  card.appendChild(title);

  const meta = document.createElement("p");
  meta.className = "task-meta";
  meta.textContent = `${task.task_id} · goal ${task.part_of_goal} · ${task.lifecycle_state}`;
  card.appendChild(meta);

  const detail = document.createElement("p");
  detail.className = "task-detail";
  detail.textContent = task.detail || "No detail provided.";
  card.appendChild(detail);

  const statRow = document.createElement("div");
  statRow.className = "task-stats";
  statRow.appendChild(buildStat("Priority", String(task.priority)));
  statRow.appendChild(buildStat("Queue", String(task.queue_seq)));
  statRow.appendChild(buildStat("Proof", task.proof_digest ? task.proof_digest.slice(0, 12) : "pending"));
  card.appendChild(statRow);

  const chipRow = document.createElement("div");
  chipRow.className = "chip-row";
  chipRow.appendChild(buildChip("SHACL", task.shape_valid));
  chipRow.appendChild(buildChip("SEAL", task.sealed));
  chipRow.appendChild(buildChip("VERIFY", task.verified));
  card.appendChild(chipRow);

  return card;
}

function buildStat(label, value) {
  const wrap = document.createElement("div");
  wrap.className = "task-stat";

  const labelEl = document.createElement("span");
  labelEl.className = "task-stat-label";
  labelEl.textContent = label;
  wrap.appendChild(labelEl);

  const valueEl = document.createElement("strong");
  valueEl.className = "task-stat-value";
  valueEl.textContent = value;
  wrap.appendChild(valueEl);

  return wrap;
}

function buildChip(label, isOk) {
  const chip = document.createElement("span");
  chip.className = "chip";
  chip.classList.add(isOk ? "ok" : "error");
  chip.textContent = label;
  return chip;
}

function sortTasks(left, right) {
  if (right.priority !== left.priority) {
    return right.priority - left.priority;
  }
  if (left.queue_seq !== right.queue_seq) {
    return left.queue_seq - right.queue_seq;
  }
  return left.task_id.localeCompare(right.task_id);
}

async function submitTask(event) {
  event.preventDefault();

  const payload = {
    goal_id: refs.goalSelect.value,
    target_kernel: refs.kernelSelect.value,
    title: refs.titleInput.value.trim(),
    detail: refs.detailInput.value.trim(),
    priority: Number(refs.priorityInput.value || 0),
  };

  if (!payload.goal_id || !payload.target_kernel || !payload.title) {
    setFormStatus("Goal, kernel, and title are required.", "error");
    return;
  }

  setFormStatus("Sealing task through the governed path…");

  try {
    const response = await fetch("/api/tasks", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    const result = await response.json();

    if (!response.ok) {
      throw new Error(result.detail || `request failed with ${response.status}`);
    }

    applyTaskUpsert(result.task);
    refs.titleInput.value = "";
    refs.detailInput.value = "";
    refs.priorityInput.value = "1";

    if (result.warnings.length > 0) {
      setFormStatus(result.warnings.join(" "), "warn");
    } else {
      setFormStatus(`Task ${result.task.task_id} sealed and queued.`);
    }
  } catch (error) {
    setFormStatus(`Task creation failed: ${error.message}`, "error");
  }
}

function applyTaskUpsert(task) {
  const normalizedTask = normalizeTask(task);
  const tasks = state.board.tasks.filter((existingTask) => existingTask.task_id !== normalizedTask.task_id);
  tasks.push(normalizedTask);
  state.board.tasks = tasks;
  state.highlightTaskId = normalizedTask.task_id;
  renderBoard();
  setConnectionState(`Live task update: ${normalizedTask.task_id}`, "ok");
}

function applyBoardSnapshot(board) {
  const normalizedBoard = normalizeBoard(board);
  state.board = normalizedBoard;

  if (normalizedBoard.kernels.length > 0) {
    state.kernels = normalizedBoard.kernels;
    if (state.visibleKernelIds.size === 0) {
      state.kernels
        .filter((kernel) => kernel.visible !== false)
        .forEach((kernel) => state.visibleKernelIds.add(kernel.kernel_id));
    }
    renderKernelToggles();
  }

  renderBoard();
  setConnectionState("Board snapshot refreshed.", "ok");
}

function setFormStatus(message, level = "ok") {
  refs.formStatus.textContent = message;
  refs.formStatus.dataset.level = level;
}

function connect() {
  clearTimeout(state.reconnectTimer);
  state.subscriptionSent = false;
  state.pendingMessage = null;
  state.buffer = new Uint8Array(0);

  setConnectionState("Connecting to NATS…", "warn");

  const socket = new WebSocket(config.nats_ws_url);
  socket.binaryType = "arraybuffer";
  socket.addEventListener("open", () => {
    setConnectionState("WebSocket open, waiting for NATS INFO…", "warn");
  });
  socket.addEventListener("message", (event) => {
    appendFrame(event.data);
  });
  socket.addEventListener("close", () => {
    setConnectionState("Disconnected. Reconnecting…", "error");
    scheduleReconnect();
  });
  socket.addEventListener("error", () => {
    setConnectionState("WebSocket error. Reconnecting…", "error");
  });

  state.socket = socket;
}

function scheduleReconnect() {
  clearTimeout(state.reconnectTimer);
  state.reconnectTimer = window.setTimeout(() => connect(), 1500);
}

function appendFrame(data) {
  state.buffer = concatBytes(state.buffer, toBytes(data));
  drainBuffer();
}

function drainBuffer() {
  while (true) {
    if (state.pendingMessage) {
      const needed = state.pendingMessage.byteLength + 2;
      if (state.buffer.length < needed) {
        return;
      }

      const payloadBytes = state.buffer.slice(0, state.pendingMessage.byteLength);
      state.buffer = state.buffer.slice(needed);
      const payloadText = decoder.decode(payloadBytes);
      state.pendingMessage = null;
      handlePayload(payloadText);
      continue;
    }

    const lineEnd = findCrlf(state.buffer);
    if (lineEnd < 0) {
      return;
    }

    const lineBytes = state.buffer.slice(0, lineEnd);
    state.buffer = state.buffer.slice(lineEnd + 2);
    handleControlLine(decoder.decode(lineBytes));
  }
}

function handleControlLine(line) {
  if (!line) {
    return;
  }

  if (line.startsWith("INFO ")) {
    if (!state.subscriptionSent) {
      sendConnectAndSubscribe();
    }
    return;
  }

  if (line === "PING") {
    sendLine("PONG");
    return;
  }

  if (line === "PONG") {
    setConnectionState(`Connected to ${config.nats_subject}`, "ok");
    return;
  }

  if (line.startsWith("+OK")) {
    return;
  }

  if (line.startsWith("-ERR")) {
    setConnectionState(line, "error");
    return;
  }

  if (line.startsWith("MSG ")) {
    const tokens = line.trim().split(/\s+/);
    const byteLength = Number(tokens[tokens.length - 1]);
    if (!Number.isFinite(byteLength)) {
      setConnectionState(`Bad NATS frame: ${line}`, "error");
      return;
    }

    state.pendingMessage = {
      subject: tokens[1] || config.nats_subject,
      byteLength,
    };
  }
}

function sendConnectAndSubscribe() {
  if (!state.socket || state.socket.readyState !== WebSocket.OPEN) {
    return;
  }

  const connectPayload = {
    verbose: false,
    pedantic: false,
    protocol: 1,
    lang: "browser",
    version: "pgck-board-1",
  };

  if (config.nats_user) {
    connectPayload.user = config.nats_user;
  }

  if (config.nats_password) {
    connectPayload.pass = config.nats_password;
  }

  sendProtocol(
    `CONNECT ${JSON.stringify(connectPayload)}\r\nSUB ${config.nats_subject} ${state.sid}\r\nPING\r\n`,
  );
  state.subscriptionSent = true;
  setConnectionState(`Subscribing to ${config.nats_subject}…`, "warn");
}

function sendLine(line) {
  if (state.socket && state.socket.readyState === WebSocket.OPEN) {
    sendProtocol(`${line}\r\n`);
  }
}

function sendProtocol(text) {
  if (state.socket && state.socket.readyState === WebSocket.OPEN) {
    state.socket.send(encoder.encode(text));
  }
}

function handlePayload(payloadText) {
  refs.lastPayload.textContent = payloadText;

  let message;
  try {
    message = JSON.parse(payloadText);
  } catch (error) {
    setConnectionState(`Bad JSON payload: ${error.message}`, "error");
    return;
  }

  const kind = message.kind || message.type;

  if (kind === "theme") {
    applyTheme(message.theme || message);
    return;
  }

  if (kind === "audio") {
    applyAudio(message.audio || message);
    return;
  }

  if (kind === "task_upsert") {
    applyTaskUpsert(message.task || {});
    return;
  }

  if (kind === "board_snapshot") {
    applyBoardSnapshot(message.board || { kernels: [], tasks: [] });
    return;
  }

  setConnectionState(`Unknown command kind: ${kind || "missing"}`, "error");
}

function applyTheme(theme) {
  document.documentElement.style.setProperty("--bg", theme.background || "#08101c");
  document.documentElement.style.setProperty("--fg", theme.foreground || "#f7fbff");
  document.documentElement.style.setProperty("--accent", theme.accent || "#7dcfff");
  document.documentElement.style.setProperty("--panel", theme.panel || "rgba(16, 31, 50, 0.82)");
  setConnectionState("Theme updated for all viewers.", "ok");
}

async function applyAudio(audio) {
  const src = audio.src;
  if (!src) {
    setConnectionState("Audio command missing src.", "error");
    return;
  }

  refs.audioPlayer.src = src;
  refs.audioPlayer.loop = Boolean(audio.loop);
  refs.audioPlayer.volume = clamp(audio.volume ?? 1, 0, 1);
  refs.audioStatus.textContent = audio.title || src;

  try {
    await refs.audioPlayer.play();
    state.pendingAudio = null;
    refs.audioUnlock.hidden = true;
    state.audioEnabled = true;
    setConnectionState("Audio playing for all viewers.", "ok");
  } catch (error) {
    state.pendingAudio = audio;
    refs.audioUnlock.hidden = false;
    setConnectionState("Audio is ready but this browser needs one click to enable playback.", "warn");
  }
}

async function enableAudio() {
  state.audioEnabled = true;
  refs.audioUnlock.hidden = true;

  if (!state.pendingAudio) {
    refs.audioStatus.textContent = "Audio unlocked";
    setConnectionState("Audio enabled for future commands.", "ok");
    return;
  }

  const pendingAudio = state.pendingAudio;
  state.pendingAudio = null;
  await applyAudio(pendingAudio);
}

function setConnectionState(message, status) {
  refs.connectionStatus.textContent = message;
  refs.connectionDot.classList.remove("ok", "error");

  if (status === "ok") {
    refs.connectionDot.classList.add("ok");
  } else if (status === "error") {
    refs.connectionDot.classList.add("error");
  }
}

function toBytes(data) {
  if (typeof data === "string") {
    return encoder.encode(data);
  }

  if (data instanceof ArrayBuffer) {
    return new Uint8Array(data);
  }

  if (ArrayBuffer.isView(data)) {
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  }

  return encoder.encode(String(data));
}

function concatBytes(left, right) {
  const combined = new Uint8Array(left.length + right.length);
  combined.set(left, 0);
  combined.set(right, left.length);
  return combined;
}

function findCrlf(bytes) {
  for (let index = 0; index < bytes.length - 1; index += 1) {
    if (bytes[index] === 13 && bytes[index + 1] === 10) {
      return index;
    }
  }
  return -1;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function cssEscape(value) {
  if (window.CSS && typeof window.CSS.escape === "function") {
    return window.CSS.escape(value);
  }
  return String(value).replace(/"/g, '\\"');
}
