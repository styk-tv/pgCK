from __future__ import annotations

import json
import os
from typing import Any

from web_demo.board import DEFAULT_KERNELS, KernelColumn, TaskRecord, board_snapshot_payload, task_upsert_payload


DEFAULT_NATS_SUBJECT = "broadcast.demo.display"
DEFAULT_NATS_WS_SCHEME = "wss"
DEFAULT_NATS_WS_PORT = "8443"
DEFAULT_AUDIO_PATH = "/static/audio/chime.wav"
STATIC_ASSET_VERSION = "20260524a"


def build_browser_config(hostname: str | None) -> dict[str, Any]:
    nats_ws_url = os.getenv("PGCK_BROWSER_NATS_URL")
    if not nats_ws_url:
        host = hostname or "127.0.0.1"
        scheme = os.getenv("PGCK_BROWSER_NATS_SCHEME", DEFAULT_NATS_WS_SCHEME)
        port = os.getenv("PGCK_BROWSER_NATS_PORT", DEFAULT_NATS_WS_PORT)
        nats_ws_url = f"{scheme}://{host}:{port}"

    return {
        "nats_ws_url": nats_ws_url,
        "nats_subject": os.getenv("PGCK_BROWSER_NATS_SUBJECT", DEFAULT_NATS_SUBJECT),
        "protocol_version": 1,
    }


def protocol_commands(subject: str, audio_path: str = DEFAULT_AUDIO_PATH) -> list[dict[str, Any]]:
    task_example = task_upsert_payload(
        TaskRecord(
            task_id="FC-T-0001",
            title="Rotate SPIFFE SVIDs",
            part_of_goal="FC-G-0001",
            target_kernel="CK.ComplianceCheck",
            lifecycle_state="pending",
            priority=4,
            queue_seq=12,
            created_at="2026-05-20T20:00:00Z",
            shape_valid=True,
            sealed=True,
            verified=True,
            proof_digest="abc123",
        )
    )
    snapshot_example = board_snapshot_payload([KernelColumn(**DEFAULT_KERNELS[0])], [])

    commands: list[dict[str, Any]] = [
        {
            "kind": "theme",
            "description": "Change the shared colour theme for every connected browser.",
            "payload": {
                "kind": "theme",
                "theme": {
                    "background": "#07111f",
                    "foreground": "#f7fbff",
                    "accent": "#47d7ac",
                    "panel": "#10263f",
                },
            },
        },
        {
            "kind": "audio",
            "description": "Tell every browser to play an audio file. Browsers may require one click to arm audio first.",
            "payload": {
                "kind": "audio",
                "audio": {
                    "src": audio_path,
                    "title": "Local chime",
                    "loop": False,
                    "volume": 0.85,
                },
            },
        },
        {
            "kind": "task_upsert",
            "description": "Insert or update one task card in the matching kernel column.",
            "payload": task_example,
        },
        {
            "kind": "board_snapshot",
            "description": "Replace the current board state with a full kernel/task snapshot.",
            "payload": snapshot_example,
        },
    ]

    for command in commands:
        body = json.dumps(command["payload"], separators=(",", ":"))
        command["publish_example"] = f"nats pub '{subject}' '{body}'"

    return commands


def protocol_document(hostname: str | None) -> dict[str, Any]:
    config = build_browser_config(hostname)
    subject = config["nats_subject"]
    commands = protocol_commands(subject)
    return {
        "name": "pgCK goal task kernel board MVP",
        "direction": "server-to-browser",
        "subject": subject,
        "nats_ws_url": config["nats_ws_url"],
        "commands": commands,
    }


def _render_nav_menu() -> str:
    return """<nav class="nav-menu">
      <a href="/" class="nav-link display-link">Display</a>
      <a href="/tasks.html" class="nav-link board-link">Board</a>
    </nav>"""


def render_index(config: dict[str, Any]) -> str:
    config_json = json.dumps(config)
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>pgCK Display — NATS Messages</title>
    <link rel="stylesheet" href="/static/app.css?v={STATIC_ASSET_VERSION}" />
  </head>
  <body>
    {_render_nav_menu()}
    <script>
      window.PGCK_DISPLAY_CONFIG = {config_json};
    </script>

    <main class="shell">
      <section class="status-card">
        <div class="eyebrow">pgCK display — NATS messages</div>
        <div class="status-row">
          <span class="status-dot" id="connection-dot"></span>
          <span id="connection-status">Connecting…</span>
        </div>
        <dl class="meta">
          <div>
            <dt>NATS WS</dt>
            <dd id="nats-url"></dd>
          </div>
          <div>
            <dt>Subject</dt>
            <dd id="nats-subject"></dd>
          </div>
          <div>
            <dt>Audio</dt>
            <dd id="audio-status">Idle</dd>
          </div>
        </dl>
        <button class="audio-button" id="audio-unlock">Enable audio</button>
      </section>

      <section class="protocol-card">
        <div class="eyebrow">Protocol</div>
        <p>This page receives NATS broadcast messages: theme changes, audio, and live events.</p>
        <div id="protocol-output" class="protocol-output">Loading protocol…</div>
        <div class="eyebrow">Last payload</div>
        <pre id="last-payload" class="last-payload">No payload received yet.</pre>
      </section>
    </main>

    <audio id="audio-player" preload="auto"></audio>
    <script src="/static/app.js?v={STATIC_ASSET_VERSION}" defer></script>
  </body>
</html>
"""


def render_tasks_page(config: dict[str, Any]) -> str:
    config_json = json.dumps(config)
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>pgCK Kernel Board</title>
    <link rel="stylesheet" href="/static/app.css?v={STATIC_ASSET_VERSION}" />
  </head>
  <body>
    {_render_nav_menu()}
    <script>
      window.PGCK_DISPLAY_CONFIG = {config_json};
    </script>

    <main class="shell">
      <section class="composer-card">
        <div class="eyebrow">Create task</div>
        <h1>Owner composer</h1>
        <p class="composer-copy">Goal selector, kernel selector, priority, and detail drive governed task creation.</p>
        <p id="form-status" class="form-status">Ready to seal tasks.</p>
        <form id="task-form">
          <label class="field">
            <span>Goal selector</span>
            <select id="goal-select" name="goal_id"></select>
          </label>
          <label class="field">
            <span>Target kernel</span>
            <select id="kernel-select" name="target_kernel"></select>
          </label>
          <label class="field">
            <span>Title</span>
            <input id="title-input" name="title" type="text" maxlength="180" />
          </label>
          <label class="field">
            <span>Detail</span>
            <textarea id="detail-input" name="detail" rows="3"></textarea>
          </label>
          <label class="field">
            <span>Priority</span>
            <input id="priority-input" name="priority" type="number" min="0" max="9" value="1" />
          </label>
          <button class="submit-button" type="submit">Create task</button>
        </form>
      </section>

      <section class="board-card">
        <div class="board-toolbar">
          <div>
            <div class="eyebrow">Kernel board</div>
            <p class="board-copy">Tasks render into their ConceptKernel columns and live-sort by priority then queue sequence.</p>
          </div>
          <div id="kernel-toggles" class="kernel-toggles"></div>
        </div>
        <div id="board-columns" class="board-columns"></div>
      </section>
    </main>

    <audio id="audio-player" preload="auto"></audio>
    <script src="/static/app.js?v={STATIC_ASSET_VERSION}" defer></script>
  </body>
</html>
"""
