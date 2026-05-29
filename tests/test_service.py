from __future__ import annotations

import pytest

from web.service import BoardService


class FakeGateway:
    def __init__(self) -> None:
        self.bootstrap_calls = 0
        self.seed_calls: list[list[dict]] = []
        self.tasks = [
            {
                "task_id": "FC-T-0002",
                "title": "B",
                "part_of_goal": "FC-G-0001",
                "target_kernel": "CK.Task",
                "lifecycle_state": "pending",
                "priority": 2,
                "queue_seq": 9,
                "created_at": "2026-05-20T20:00:00Z",
                "shape_valid": True,
                "sealed": True,
                "verified": True,
                "proof_digest": "b",
            },
            {
                "task_id": "FC-T-0001",
                "title": "A",
                "part_of_goal": "FC-G-0001",
                "target_kernel": "CK.Task",
                "lifecycle_state": "pending",
                "priority": 5,
                "queue_seq": 3,
                "created_at": "2026-05-20T20:01:00Z",
                "shape_valid": True,
                "sealed": True,
                "verified": True,
                "proof_digest": "a",
            },
        ]

    def bootstrap(self) -> None:
        self.bootstrap_calls += 1

    def ensure_goals(self, goals: list[dict]) -> None:
        self.seed_calls.append(goals)

    def list_tasks(self) -> list[dict]:
        return list(self.tasks)

    def list_goals(self) -> list[dict]:
        return [{"goal_id": "FC-G-0001", "title": "Fortify the fleet"}]

    def create_task(self, payload: dict) -> dict:
        task = {
            "task_id": "FC-T-0003",
            "title": payload["title"],
            "part_of_goal": payload["goal_id"],
            "target_kernel": payload["target_kernel"],
            "lifecycle_state": "pending",
            "priority": payload["priority"],
            "queue_seq": 10,
            "created_at": "2026-05-20T20:02:00Z",
            "shape_valid": True,
            "sealed": True,
            "verified": True,
            "proof_digest": "c",
            "detail": payload.get("detail", ""),
            "created_by": "owner",
        }
        self.tasks.append(task)
        return task


class FakePublisher:
    def __init__(self, should_fail: bool = False) -> None:
        self.should_fail = should_fail
        self.payloads: list[dict] = []

    async def publish(self, payload: dict) -> None:
        self.payloads.append(payload)
        if self.should_fail:
            raise RuntimeError("publish failed")


@pytest.mark.asyncio
async def test_board_service_startup_bootstraps_gateway_and_seeds_goals() -> None:
    gateway = FakeGateway()
    publisher = FakePublisher()
    service = BoardService(gateway=gateway, publisher=publisher)

    await service.startup()

    assert gateway.bootstrap_calls == 1
    assert gateway.seed_calls
    assert gateway.seed_calls[0][0]["goal_id"] == "FC-G-0001"


def test_board_service_board_snapshot_sorts_tasks() -> None:
    gateway = FakeGateway()
    publisher = FakePublisher()
    service = BoardService(gateway=gateway, publisher=publisher)

    payload = service.board_snapshot()

    assert payload["kind"] == "board_snapshot"
    assert [task["task_id"] for task in payload["board"]["tasks"]] == ["FC-T-0001", "FC-T-0002"]


@pytest.mark.asyncio
async def test_board_service_create_task_publishes_task_upsert() -> None:
    gateway = FakeGateway()
    publisher = FakePublisher()
    service = BoardService(gateway=gateway, publisher=publisher)

    result = await service.create_task(
        {
            "goal_id": "FC-G-0001",
            "target_kernel": "CK.Task",
            "title": "Rotate SPIFFE SVIDs",
            "detail": "demo",
            "priority": 4,
        }
    )

    assert result["warnings"] == []
    assert publisher.payloads[0]["kind"] == "task_upsert"
    assert publisher.payloads[0]["task"]["task_id"] == "FC-T-0003"


@pytest.mark.asyncio
async def test_board_service_returns_warning_when_publish_fails() -> None:
    gateway = FakeGateway()
    publisher = FakePublisher(should_fail=True)
    service = BoardService(gateway=gateway, publisher=publisher)

    result = await service.create_task(
        {
            "goal_id": "FC-G-0001",
            "target_kernel": "CK.Task",
            "title": "Rotate SPIFFE SVIDs",
            "detail": "demo",
            "priority": 4,
        }
    )

    assert result["task"]["task_id"] == "FC-T-0003"
    assert result["warnings"] == ["task was sealed but live publish failed: publish failed"]


# ---------------------------------------------------------------------------
# CKA-7 — NatsEventPublisher dual-emit (short + long subject per payload)
# ---------------------------------------------------------------------------


def test_nats_publisher_derives_short_and_long_subjects() -> None:
    from web.service import NatsEventPublisher

    publisher = NatsEventPublisher(
        url="nats://test:4222",
        subject="event.pgCK.Display",
        long_subject_prefix="event.kernel.pgCK.Display",
    )

    short, long_ = publisher._derive_subjects({"kind": "task_upsert"})
    assert short == "event.pgCK.Display"
    assert long_ == "event.kernel.pgCK.Display.task_upsert"

    # theme / audio / board_snapshot all flow through the same derivation.
    for kind in ("theme", "audio", "board_snapshot"):
        s, l = publisher._derive_subjects({"kind": kind})
        assert s == "event.pgCK.Display"
        assert l == f"event.kernel.pgCK.Display.{kind}"

    # Missing or empty `kind` falls back to `broadcast`.
    _, long_default = publisher._derive_subjects({})
    assert long_default == "event.kernel.pgCK.Display.broadcast"
    _, long_empty = publisher._derive_subjects({"kind": ""})
    assert long_empty == "event.kernel.pgCK.Display.broadcast"


@pytest.mark.asyncio
async def test_nats_publisher_publishes_to_both_subjects(monkeypatch) -> None:
    from web.service import NatsEventPublisher

    captured: list[tuple[str, bytes]] = []

    class FakeClient:
        async def publish(self, subject: str, payload: bytes) -> None:
            captured.append((subject, payload))

        async def flush(self, timeout: float = 1.0) -> None:
            pass

        async def close(self) -> None:
            pass

    async def fake_connect(**kwargs):
        return FakeClient()

    import web.service as service_mod

    monkeypatch.setattr(service_mod.nats, "connect", fake_connect)

    publisher = NatsEventPublisher(
        url="nats://test:4222",
        subject="event.pgCK.Display",
        long_subject_prefix="event.kernel.pgCK.Display",
    )

    await publisher.publish({"kind": "task_upsert", "task": {"task_id": "T1"}})

    subjects = [subject for subject, _ in captured]
    assert subjects == ["event.pgCK.Display", "event.kernel.pgCK.Display.task_upsert"]
    # Same payload bytes on both subjects — CKA-7 acceptance "NATS
    # receives the same payload on both subjects".
    assert captured[0][1] == captured[1][1]
    body = captured[0][1].decode("utf-8")
    assert '"kind":"task_upsert"' in body
    assert '"task_id":"T1"' in body
