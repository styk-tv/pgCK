from __future__ import annotations

import json

from web_demo.service import PsqlPgckGateway


class FakeSqlRunner:
    def __init__(self, outputs: list[str]) -> None:
        self.outputs = outputs
        self.calls: list[str] = []

    def __call__(self, sql: str) -> str:
        self.calls.append(sql)
        return self.outputs.pop(0) if self.outputs else ""


def test_gateway_bootstrap_loads_core_and_goal_task_kernel() -> None:
    runner = FakeSqlRunner([""])
    gateway = PsqlPgckGateway(sql_runner=runner)

    gateway.bootstrap()

    assert "INSERT INTO ckp.config(k,v) VALUES ('kernel_graph_id','20')" in runner.calls[0]
    assert "CALL ckp.bootstrap_kernel();" in runner.calls[0]
    assert "CALL ckp.boot();" in runner.calls[0]
    assert "CALL ckp.load_kernel('/examples/goal-task-board.kernel.ttl', 'goal_task_board');" in runner.calls[0]


def test_gateway_ensure_goals_seals_missing_goals() -> None:
    runner = FakeSqlRunner(
        [
            json.dumps([]),
            "",
            "",
        ]
    )
    gateway = PsqlPgckGateway(sql_runner=runner)

    gateway.ensure_goals(
        [
            {
                "goal_id": "FC-G-0001",
                "title": "Fortify the fleet",
                "created_at": "2026-05-20T20:00:00Z",
                "detail": "seeded",
                "created_by": "seed",
            },
            {
                "goal_id": "FC-G-0002",
                "title": "Tighten operator feedback",
                "created_at": "2026-05-20T20:05:00Z",
                "detail": "seeded",
                "created_by": "seed",
            },
        ]
    )

    assert "body->>'https://conceptkernel.org/ontology/v3.7/goal_id'" in runner.calls[0]
    assert "SELECT ckp.seal('FC-G-0001'" in runner.calls[1]
    assert "SELECT ckp.seal('FC-G-0002'" in runner.calls[2]


def test_gateway_create_task_runs_seal_verify_and_returns_json() -> None:
    runner = FakeSqlRunner(
        [
            json.dumps({"next_task": "FC-T-0001", "next_queue": 1}),
            "\n".join(
                [
                    "goal_task_board",
                    "0a4a5d95f1d0cd4f7f460bdce39c2a61",
                    json.dumps(
                        {
                            "task_id": "FC-T-0001",
                            "title": "Rotate SPIFFE SVIDs",
                            "part_of_goal": "FC-G-0001",
                            "target_kernel": "CK.Task",
                            "lifecycle_state": "pending",
                            "priority": 4,
                            "queue_seq": 1,
                            "created_at": "2026-05-20T20:00:00Z",
                            "shape_valid": True,
                            "sealed": True,
                            "verified": True,
                            "proof_digest": "abc123",
                            "detail": "demo",
                            "created_by": "owner",
                        }
                    ),
                ]
            ),
        ]
    )
    gateway = PsqlPgckGateway(sql_runner=runner)

    task = gateway.create_task(
        {
            "goal_id": "FC-G-0001",
            "target_kernel": "CK.Task",
            "title": "Rotate SPIFFE SVIDs",
            "detail": "demo",
            "priority": 4,
        }
    )

    assert task["task_id"] == "FC-T-0001"
    assert "set_config('ckp.project', 'goal_task_board', false)" in runner.calls[1]
    assert "SELECT ckp.seal('FC-T-0001'" in runner.calls[1]
    assert "SELECT ckp.verify('FC-T-0001')" in runner.calls[1]


def test_gateway_create_task_verifies_only_after_seal() -> None:
    runner = FakeSqlRunner(
        [
            json.dumps({"next_task": "FC-T-0001", "next_queue": 1}),
            json.dumps({"task_id": "FC-T-0001", "verified": True}),
        ]
    )
    gateway = PsqlPgckGateway(sql_runner=runner)

    gateway.create_task(
        {
            "goal_id": "FC-G-0001",
            "target_kernel": "CK.Task",
            "title": "Rotate SPIFFE SVIDs",
            "detail": "demo",
            "priority": 4,
        }
    )

    assert "verified AS (" in runner.calls[1]
    assert "SELECT ckp.verify('FC-T-0001') AS verified FROM sealed" in runner.calls[1]


def test_gateway_list_tasks_uses_instance_alias_for_proof_lookup() -> None:
    runner = FakeSqlRunner(
        [
            json.dumps(
                [
                    {
                        "task_id": "FC-T-0001",
                        "title": "Rotate SPIFFE SVIDs",
                        "part_of_goal": "FC-G-0001",
                        "target_kernel": "CK.Task",
                        "lifecycle_state": "pending",
                        "priority": 4,
                        "queue_seq": 1,
                        "created_at": "2026-05-20T20:00:00Z",
                        "shape_valid": True,
                        "sealed": True,
                        "verified": True,
                        "proof_digest": "abc123",
                        "detail": "demo",
                        "created_by": "owner",
                    }
                ]
            )
        ]
    )
    gateway = PsqlPgckGateway(sql_runner=runner)

    tasks = gateway.list_tasks()

    assert tasks[0]["task_id"] == "FC-T-0001"
    assert "FROM ckp.instances AS i" in runner.calls[0]
    assert "WHERE p.about = i.id" in runner.calls[0]
