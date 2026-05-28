from web.board import (
    DEFAULT_KERNELS,
    GoalRecord,
    KernelColumn,
    TaskRecord,
    build_goal_body,
    build_task_body,
    board_snapshot_payload,
    goal_record_from_mapping,
    sort_tasks,
    task_upsert_payload,
)


def test_sort_tasks_prefers_priority_then_fifo() -> None:
    tasks = [
        TaskRecord(
            task_id="FC-T-0002",
            title="B",
            part_of_goal="FC-G-0001",
            target_kernel="CK.Task",
            lifecycle_state="pending",
            priority=2,
            queue_seq=9,
            created_at="2026-05-20T20:00:00Z",
            shape_valid=True,
            sealed=True,
            verified=True,
            proof_digest="b",
        ),
        TaskRecord(
            task_id="FC-T-0001",
            title="A",
            part_of_goal="FC-G-0001",
            target_kernel="CK.Task",
            lifecycle_state="pending",
            priority=5,
            queue_seq=12,
            created_at="2026-05-20T20:01:00Z",
            shape_valid=True,
            sealed=True,
            verified=True,
            proof_digest="a",
        ),
        TaskRecord(
            task_id="FC-T-0003",
            title="C",
            part_of_goal="FC-G-0001",
            target_kernel="CK.Task",
            lifecycle_state="pending",
            priority=5,
            queue_seq=3,
            created_at="2026-05-20T20:02:00Z",
            shape_valid=True,
            sealed=True,
            verified=True,
            proof_digest="c",
        ),
    ]

    ordered = sort_tasks(tasks)

    assert [task.task_id for task in ordered] == ["FC-T-0003", "FC-T-0001", "FC-T-0002"]


def test_build_task_body_uses_core_iris() -> None:
    body = build_task_body(
        task_id="FC-T-0001",
        title="Rotate SPIFFE SVIDs",
        part_of_goal="FC-G-0001",
        target_kernel="CK.Task",
        lifecycle_state="pending",
        priority=4,
        queue_seq=12,
        created_at="2026-05-20T20:00:00Z",
        detail="demo",
        created_by="owner",
    )

    assert body["type"].endswith("/Task")
    assert body["https://conceptkernel.org/ontology/v3.7/task_id"] == "FC-T-0001"
    assert body["https://conceptkernel.org/ontology/v3.7/target_kernel"] == "CK.Task"


def test_board_payload_helpers_emit_shared_subject_shapes() -> None:
    kernels = [KernelColumn(**DEFAULT_KERNELS[0])]
    tasks = [
        TaskRecord(
            task_id="FC-T-0001",
            title="Rotate SPIFFE SVIDs",
            part_of_goal="FC-G-0001",
            target_kernel=kernels[0].kernel_id,
            lifecycle_state="pending",
            priority=4,
            queue_seq=12,
            created_at="2026-05-20T20:00:00Z",
            shape_valid=True,
            sealed=True,
            verified=True,
            proof_digest="abc123",
        ),
    ]

    snapshot = board_snapshot_payload(kernels, tasks)
    upsert = task_upsert_payload(tasks[0])

    assert snapshot["kind"] == "board_snapshot"
    assert snapshot["board"]["kernels"][0]["kernel_id"] == kernels[0].kernel_id
    assert upsert["kind"] == "task_upsert"
    assert upsert["task"]["task_id"] == "FC-T-0001"


def test_build_goal_body_uses_core_iris() -> None:
    body = build_goal_body(
        goal_id="FC-G-0001",
        title="Fortify the fleet",
        created_at="2026-05-20T20:00:00Z",
        detail="Stabilise the kernel board slice and prove the governed path.",
        created_by="seed",
    )

    assert body["type"].endswith("/Goal")
    assert body["https://conceptkernel.org/ontology/v3.7/goal_id"] == "FC-G-0001"
    assert body["https://conceptkernel.org/ontology/v3.7/title"] == "Fortify the fleet"
    assert body["https://conceptkernel.org/ontology/v3.7/created_at"] == "2026-05-20T20:00:00Z"


def test_goal_record_from_mapping_handles_optional_fields() -> None:
    goal_data = {
        "goal_id": "FC-G-0001",
        "title": "Fortify the fleet",
        "created_at": "2026-05-20T20:00:00Z",
    }

    goal = goal_record_from_mapping(goal_data)

    assert goal.goal_id == "FC-G-0001"
    assert goal.title == "Fortify the fleet"
    assert goal.created_at == "2026-05-20T20:00:00Z"
    assert goal.detail == ""
    assert goal.created_by == ""


def test_goal_record_preserves_detail_and_created_by() -> None:
    goal_data = {
        "goal_id": "FC-G-0001",
        "title": "Fortify the fleet",
        "created_at": "2026-05-20T20:00:00Z",
        "detail": "Stabilise the kernel board slice.",
        "created_by": "owner",
    }

    goal = goal_record_from_mapping(goal_data)

    assert goal.detail == "Stabilise the kernel board slice."
    assert goal.created_by == "owner"


def test_goal_record_to_dict_produces_dataclass_fields() -> None:
    goal = GoalRecord(
        goal_id="FC-G-0001",
        title="Fortify the fleet",
        created_at="2026-05-20T20:00:00Z",
        detail="Stabilise the kernel board slice.",
        created_by="seed",
    )

    goal_dict = goal.to_dict()

    assert goal_dict["goal_id"] == "FC-G-0001"
    assert goal_dict["title"] == "Fortify the fleet"
    assert goal_dict["created_at"] == "2026-05-20T20:00:00Z"
    assert goal_dict["detail"] == "Stabilise the kernel board slice."
    assert goal_dict["created_by"] == "seed"
