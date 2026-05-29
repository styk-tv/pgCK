from __future__ import annotations

import json
import os
from typing import Any

from web.board import DEFAULT_KERNELS, KernelColumn, TaskRecord, board_snapshot_payload, task_upsert_payload


DEFAULT_DISPLAY_KERNEL = "pgCK.Display"
DEFAULT_NATS_SUBJECT = f"event.{DEFAULT_DISPLAY_KERNEL}"  # short form, v1.2.x — deprecated in v2.0
DEFAULT_NATS_WS_SCHEME = "wss"
DEFAULT_NATS_WS_PORT = "443"
DEFAULT_NATS_WS_PATH = "/wss"
DEFAULT_AUDIO_PATH = "/assets/audio/chime.wav"


def short_form_subject(kernel: str) -> str:
    """v1.2.x short-form subject: event.<Kernel>.

    Retained alongside the long form during the CK.Lib.Js v1.3 dual-emit
    window. Removed when CKClient v2.0 drops the alias.
    """
    return f"event.{kernel}"


def long_form_subject(kernel: str, event: str = "broadcast") -> str:
    """CKP v3.8 canonical subject: event.kernel.<K>.<event>.

    `<K>` is the contributing kernel (URN-normalised). `<event>` is the
    event kind (e.g. ``task.upserted``, ``goal.upserted``, ``broadcast``
    for the display surface). See SPEC.PGCK.NATS-CK-LIB-JS-ALIGNMENT
    v0.1 §1.1.
    """
    return f"event.kernel.{kernel}.{event}"


def build_browser_config(hostname: str | None) -> dict[str, Any]:
    nats_ws_url = os.getenv("PGCK_BROWSER_NATS_URL")
    if not nats_ws_url:
        host = hostname or "pgck.localhost"
        scheme = os.getenv("PGCK_BROWSER_NATS_SCHEME", DEFAULT_NATS_WS_SCHEME)
        port = os.getenv("PGCK_BROWSER_NATS_PORT", DEFAULT_NATS_WS_PORT)
        path = os.getenv("PGCK_BROWSER_NATS_PATH", DEFAULT_NATS_WS_PATH)
        nats_ws_url = f"{scheme}://{host}:{port}{path}"

    kernel = os.getenv("PGCK_DISPLAY_KERNEL", DEFAULT_DISPLAY_KERNEL)
    short_subject = os.getenv("PGCK_BROWSER_NATS_SUBJECT", short_form_subject(kernel))
    long_subject = long_form_subject(kernel)

    return {
        "nats_ws_url": nats_ws_url,
        # Primary subject the browser currently subscribes to. CKClient v1.2 uses
        # the short form; CKClient v1.3 will accept ``extra_subjects`` and listen
        # on both via NATS wildcard expansion.
        "nats_subject": short_subject,
        # Both forms exposed for clients that want to subscribe to either; v1.3
        # clients can read ``nats_subject_long`` and pass it as an extraSubject.
        "nats_subject_long": long_subject,
        "display_kernel": kernel,
        "cklib_base": "/cklib",
        "protocol_version": 1,
    }


def protocol_commands(subject: str, audio_path: str = DEFAULT_AUDIO_PATH) -> list[dict[str, Any]]:
    task_example = task_upsert_payload(
        TaskRecord(
            task_id="FC-T-0001",
            title="Land v0.2 SQL plumbing draft",
            part_of_goal="FC-G-0001",
            target_kernel="CK.Task",
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
        "subject_long": config["nats_subject_long"],
        "nats_ws_url": config["nats_ws_url"],
        "commands": commands,
    }
