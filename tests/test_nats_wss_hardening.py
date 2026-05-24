from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def test_browser_app_connects_without_raw_nats_credentials() -> None:
    app_js = _read("web_demo/static/app.js")

    assert "nats_user" not in app_js
    assert "nats_password" not in app_js
    assert "connectPayload.user" not in app_js
    assert "connectPayload.pass" not in app_js


def test_compose_stack_uses_nats_config_for_auth() -> None:
    compose_text = _read("compose/compose.nats-wss.yml")

    assert "--user" not in compose_text
    assert "--pass" not in compose_text
    assert "NATS_USER:" in compose_text
    assert "NATS_PASSWORD:" in compose_text
    assert "PGCK_BROWSER_NATS_SUBJECT:" in compose_text


def test_nats_server_config_maps_websocket_clients_to_subscribe_only_user() -> None:
    config_text = _normalize(_read("compose/nats/nats-server.conf"))

    assert "authorization {" in config_text
    assert "no_auth_user: browser_wss" in config_text
    assert "user: browser_wss" in config_text
    assert "publish = []" in config_text
    assert 'subscribe = [$PGCK_BROWSER_NATS_SUBJECT]' in config_text
    assert "user: $NATS_USER" in config_text
    assert "password: $NATS_PASSWORD" in config_text
