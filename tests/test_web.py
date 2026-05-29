from __future__ import annotations

from fastapi.testclient import TestClient

from web.app import create_app
from web.service import BoardValidationError


class FakeBoardService:
    def __init__(self) -> None:
        self.created_payloads: list[dict] = []
        self.startup_calls = 0

    async def startup(self) -> None:
        self.startup_calls += 1

    def board_snapshot(self) -> dict:
        return {
            "kind": "board_snapshot",
            "board": {
                "kernels": [
                    {
                        "kernel_id": "CK.Task",
                        "title": "Task Kernel",
                        "icon": "assignment",
                        "color": "#22c55e",
                        "launch_url": "https://task.localhost",
                        "visible": True,
                    },
                ],
                "tasks": [],
            },
        }

    def list_goals(self) -> list[dict]:
        return [{"goal_id": "FC-G-0001", "title": "Fortify the fleet"}]

    def list_kernels(self) -> list[dict]:
        return self.board_snapshot()["board"]["kernels"]

    async def create_task(self, payload: dict) -> dict:
        self.created_payloads.append(payload)
        return {
            "task": {
                "task_id": "FC-T-0001",
                "title": payload["title"],
                "part_of_goal": payload["goal_id"],
                "target_kernel": payload["target_kernel"],
                "lifecycle_state": "pending",
                "priority": payload["priority"],
                "queue_seq": 1,
                "created_at": "2026-05-20T20:00:00Z",
                "shape_valid": True,
                "sealed": True,
                "verified": True,
                "proof_digest": "abc123",
                "detail": payload.get("detail", ""),
                "created_by": "test-owner",
            },
            "warnings": [],
        }


class RejectingBoardService(FakeBoardService):
    async def create_task(self, payload: dict) -> dict:
        raise BoardValidationError("unknown goal_id: BAD-G-9999")


def test_root_serves_static_display_shell() -> None:
    # U1: "/" is a static file (web/static/index.html), served by the root
    # StaticFiles mount — no FastAPI HTML rendering. Config is client-derived
    # in the page (no secrets injected).
    service = FakeBoardService()
    app = create_app(service)

    with TestClient(app) as client:
        response = client.get("/")

    assert response.status_code == 200
    assert service.startup_calls == 1
    assert "PGCK_DISPLAY_CONFIG" in response.text       # client-derived config block
    assert '"nats_user"' not in response.text
    assert '"nats_password"' not in response.text
    assert "pgCK display" in response.text              # display shell, not the board
    assert "/assets/display-app.js" in response.text


def test_tasks_serves_static_board_shell() -> None:
    # U1: "/tasks.html" is a static file (web/static/tasks.html).
    app = create_app(FakeBoardService())

    with TestClient(app) as client:
        response = client.get("/tasks.html")

    assert response.status_code == 200
    assert "PGCK_DISPLAY_CONFIG" in response.text
    assert "Create task" in response.text
    assert "Kernel board" in response.text
    assert "Goal selector" in response.text
    assert "/assets/board-app.js" in response.text


def test_protocol_doc_is_static_asset() -> None:
    # CKD-3: /protocol is no longer a FastAPI route. The protocol document is a
    # committed static asset (web/static/protocol.json) served by the /assets
    # StaticFiles mount — no Python handler computes it. The browser's live
    # config still arrives via window.PGCK_DISPLAY_CONFIG, so the static doc's
    # subject/url are illustrative defaults.
    app = create_app(FakeBoardService())

    with TestClient(app) as client:
        assert client.get("/protocol").status_code == 404  # dynamic endpoint removed
        response = client.get("/assets/protocol.json")      # static asset serves it

    assert response.status_code == 200
    payload = response.json()

    assert {command["kind"] for command in payload["commands"]} == {
        "theme",
        "audio",
        "task_upsert",
        "board_snapshot",
    }
    assert payload["subject"]  # illustrative default subject
    assert all(payload["subject"] in command["publish_example"] for command in payload["commands"])


def test_board_api_returns_snapshot() -> None:
    app = create_app(FakeBoardService())

    with TestClient(app) as client:
        response = client.get("/api/board")

    assert response.status_code == 200
    payload = response.json()
    assert payload["kind"] == "board_snapshot"
    assert payload["board"]["kernels"][0]["kernel_id"] == "CK.Task"


def test_supporting_apis_return_goals_and_kernels() -> None:
    app = create_app(FakeBoardService())

    with TestClient(app) as client:
        goals_response = client.get("/api/goals")
        kernels_response = client.get("/api/kernels")

    assert goals_response.status_code == 200
    assert kernels_response.status_code == 200
    assert goals_response.json()[0]["goal_id"] == "FC-G-0001"
    assert kernels_response.json()[0]["kernel_id"] == "CK.Task"


def test_create_task_posts_to_service() -> None:
    service = FakeBoardService()
    app = create_app(service)

    with TestClient(app) as client:
        response = client.post(
            "/api/tasks",
            json={
                "goal_id": "FC-G-0001",
                "target_kernel": "CK.Task",
                "title": "Rotate SPIFFE SVIDs",
                "detail": "demo",
                "priority": 4,
            },
        )

    assert response.status_code == 201
    assert service.created_payloads == [
        {
            "goal_id": "FC-G-0001",
            "target_kernel": "CK.Task",
            "title": "Rotate SPIFFE SVIDs",
            "detail": "demo",
            "priority": 4,
        },
    ]
    assert response.json()["task"]["task_id"] == "FC-T-0001"


def test_create_task_returns_400_for_validation_errors() -> None:
    app = create_app(RejectingBoardService())

    with TestClient(app) as client:
        response = client.post(
            "/api/tasks",
            json={
                "goal_id": "BAD-G-9999",
                "target_kernel": "CK.Task",
                "title": "Rotate SPIFFE SVIDs",
                "detail": "demo",
                "priority": 4,
            },
        )

    assert response.status_code == 400
    assert response.json() == {"detail": "unknown goal_id: BAD-G-9999"}


def test_browser_config_defaults_to_local_wss() -> None:
    config = build_browser_config("alice.local")

    assert config["nats_subject"] == "broadcast.demo.display"
    assert config["nats_ws_url"] == "wss://alice.local:8443"
    assert "nats_user" not in config
    assert "nats_password" not in config


def test_browser_config_supports_plain_ws_scheme_from_env(monkeypatch) -> None:
    monkeypatch.setenv("PGCK_BROWSER_NATS_SCHEME", "ws")

    config = build_browser_config("alice.local")

    assert config["nats_ws_url"] == "ws://alice.local:8443"
